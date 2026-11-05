import AppKit
import SwiftUI

struct FinderOpenPreferences: Sendable {
    let automatic: Bool
    let mode: ExtractionMode
    init(defaults: UserDefaults = .standard) {
        automatic = defaults.bool(forKey: "automaticExtraction")
        mode = ExtractionMode(rawValue: defaults.string(forKey: "extractionMode") ?? "folder") ?? .folder
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = ApplicationController()
    private var receivedDocuments = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No SwiftUI WindowGroup is created on launch. File-open events are
        // handled directly, allowing successful automatic extraction with no UI.
        if FinderOpenPreferences().automatic { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            if !receivedDocuments { controller.showMainWindow() }
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        receivedDocuments = true
        controller.openDocuments(urls)
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller.showMainWindow()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
final class ApplicationController: NSObject, ObservableObject, NSWindowDelegate {
    let model = ExtractorModel()
    let compression = CompressionModel()
    @Published var mode = 0
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var hasVisibleWindows: Bool { window?.isVisible == true || settingsWindow?.isVisible == true }
    private var queue: [(URL, FinderOpenPreferences)] = []
    private var processing = false

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 820),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "MacRar"
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.contentView = NSHostingView(rootView: MainContentView(controller: self, model: model, compression: compression))
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func showSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        if settingsWindow == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
            created.title = "Configurações do MacRar"
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.contentView = NSHostingView(rootView: ExtractionSettingsView())
            created.center()
            settingsWindow = created
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func selectFiles() {
        showMainWindow()
        guard !model.busy, !compression.busy else { return }
        if mode == 0 { model.selectFiles() } else { compression.select() }
    }
    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let otherVisible = [window, settingsWindow].compactMap { $0 }.contains { $0 !== closing && $0.isVisible }
        if FinderOpenPreferences().automatic && !otherVisible { NSApp.setActivationPolicy(.accessory) }
    }
    func openDocuments(_ urls: [URL]) {
        let preferences = FinderOpenPreferences()
        queue.append(contentsOf: urls.filter(\.isFileURL).map { ($0, preferences) })
        guard !processing else { return }
        processing = true
        Task {
            while !queue.isEmpty {
                // File-open events received during another operation are queued.
                while model.busy || compression.busy {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let (url, preferences) = queue.removeFirst()
                if !preferences.automatic {
                    mode = 0
                    model.add([url])
                    showMainWindow()
                    continue
                }
                await extractAutomatically(url, preferences: preferences)
            }
            processing = false
            if !hasVisibleWindows && FinderOpenPreferences().automatic {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
    private func extractAutomatically(_ source: URL, preferences: FinderOpenPreferences) async {
        let flag = model.beginAutomatic()
        defer { model.finishAutomatic() }
        var password = ""
        while true {
            let passphrase = password
            let result = await Task.detached(priority: .userInitiated) {
                ExtractorModel.unpack(source: source, parent: source.deletingLastPathComponent(), password: passphrase, token: flag, mode: preferences.mode)
            }.value
            switch result {
            case .success(let output):
                if let index = model.items.firstIndex(where: { $0.source == source }) {
                    model.items[index].output = output
                    model.items[index].status = "Extraído com sucesso"
                    model.items[index].failed = false
                } else {
                    var item = ExtractionItem(source: source)
                    item.output = output
                    item.status = "Extraído com sucesso"
                    model.items.append(item)
                }
                return
            case .failure(let error):
                if flag.isCancelled { return }
                if error.domain == "MacRar" && error.code == -2 {
                    guard let entered = requestPassword(for: source, retry: !password.isEmpty) else { return }
                    password = entered
                    continue
                }
                presentFailure(error, source: source)
                return
            }
        }
    }
    private func requestPassword(for source: URL, retry: Bool) -> String? {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = retry ? "Confira a senha" : "Este arquivo precisa de senha"
        alert.informativeText = "Informe a senha para extrair \(source.lastPathComponent)."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "Senha do arquivo"
        alert.accessoryView = field
        alert.addButton(withTitle: "Extrair")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
    private func presentFailure(_ error: NSError, source: URL) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Não foi possível extrair \(source.lastPathComponent)"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Abrir MacRar")
        alert.addButton(withTitle: "Fechar")
        if alert.runModal() == .alertFirstButtonReturn {
            if let index = model.items.firstIndex(where: { $0.source == source }) {
                model.items[index].output = nil
                model.items[index].failed = true
                model.items[index].status = error.localizedDescription
            } else {
                var item = ExtractionItem(source: source)
                item.failed = true
                item.status = error.localizedDescription
                model.items.append(item)
            }
            mode = 0
            showMainWindow()
        }
    }
}

struct ExtractionSettingsView: View {
    @AppStorage("automaticExtraction") private var automatic = false
    @AppStorage("extractionMode") private var mode = ExtractionMode.folder.rawValue
    var body: some View {
        Form {
            Section {
                Toggle("Extrair automaticamente ao abrir pelo Finder", isOn: $automatic)
                Text("Ao dar dois cliques em um arquivo associado ao MacRar, a extração começa sem abrir a janela principal. Se precisar de senha, aparece apenas o pedido de senha. Erros também são informados.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Picker("Modo de extração", selection: $mode) {
                    ForEach(ExtractionMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("Este modo vale para a tela de extração e para a extração automática. Pelo Finder, o destino é sempre a pasta do arquivo compactado.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Extrair aqui mantém as pastas que já estão dentro do arquivo, sem criar uma pasta externa adicional. Itens existentes não são substituídos; em caso de conflito, a operação é interrompida.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(16).frame(width: 560, height: 340)
    }
}
