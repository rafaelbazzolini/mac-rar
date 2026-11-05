import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveBridge

@main
struct MacRarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { ExtractionSettingsView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Configurações…") { appDelegate.controller.showSettingsWindow() }
                        .keyboardShortcut(",")
                }
                CommandGroup(replacing: .newItem) {
                    Button("Abrir arquivos…") { appDelegate.controller.selectFiles() }
                        .keyboardShortcut("o")
                    Button("Mostrar MacRar") { appDelegate.controller.showMainWindow() }
                        .keyboardShortcut("1")
                }
            }
    }
}

struct MainContentView: View {
    @ObservedObject var controller: ApplicationController
    @ObservedObject var model: ExtractorModel
    @ObservedObject var compression: CompressionModel
    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MacRar").font(.largeTitle.bold())
                    Text("Menos espaço. Mais possibilidades.").foregroundStyle(.secondary)
                }
                Spacer()
                Button { controller.showSettingsWindow() } label: {
                    Image(systemName: "gearshape")
                }.help("Configurações")
            }
            Picker("Modo", selection: $controller.mode) {
                Text("Extrair arquivos").tag(0)
                Text("Criar arquivo compactado").tag(1)
            }.pickerStyle(.segmented).disabled(model.busy || compression.busy)
            if controller.mode == 0 { ContentView(model: model) }
            else { CompressionView(model: compression) }
        }
        .padding(26).frame(minWidth: 740, minHeight: 760)
        .sheet(isPresented: $model.showContents) { ArchiveContentsView(model: model) }
        .alert("MacRar", isPresented: $model.showMessage) {
            Button("OK", role: .cancel) { }
        } message: { Text(model.message) }
    }
}

struct ExtractionItem: Identifiable {
    let id = UUID()
    let source: URL
    var status = "Pronto para extrair"
    var output: URL?
    var failed = false
}

@MainActor
final class ExtractorModel: ObservableObject {
    @Published var items: [ExtractionItem] = []
    @Published var destination: URL?
    @Published var busy = false
    @Published var completed = 0
    @Published var password = ""
    @Published var members: [ArchiveMember] = []
    @Published var contentsTitle = ""
    @Published var showContents = false
    @Published var showMessage = false
    @Published var message = ""
    private var token: CancellationFlag?

    func cancel() { token?.cancel() }
    func beginAutomatic() -> CancellationFlag {
        let flag = CancellationFlag()
        token = flag
        busy = true
        return flag
    }
    func finishAutomatic() {
        token = nil
        busy = false
    }

    func inspect(_ source: URL, verify: Bool) {
        guard !busy else { return }
        busy = true
        let flag = CancellationFlag()
        token = flag
        let passphrase = password
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ArchiveService.inspect(source, password: passphrase, verify: verify, token: flag) }
            }.value
            busy = false
            token = nil
            switch result {
            case .success(let entries):
                if verify {
                    message = "Integridade verificada: \(entries.count) itens lidos sem erros."
                    showMessage = true
                } else {
                    members = entries
                    contentsTitle = source.lastPathComponent
                    showContents = true
                }
            case .failure(let error):
                message = error.localizedDescription
                showMessage = true
            }
        }
    }

    func add(_ urls: [URL]) {
        guard !busy else { return }
        for url in urls where url.isFileURL {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue,
                  !items.contains(where: { $0.source == url }) else { continue }
            items.append(ExtractionItem(source: url))
        }
    }

    func selectFiles() {
        let panel = NSOpenPanel()
        panel.title = "Escolha os arquivos compactados"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func selectDestination() {
        let panel = NSOpenPanel()
        panel.title = "Escolha onde extrair"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { destination = panel.url }
    }

    func extract(mode: ExtractionMode = .folder) {
        guard !busy, !items.isEmpty else { return }
        busy = true
        completed = 0
        let flag = CancellationFlag()
        token = flag
        let passphrase = password
        Task {
            for index in items.indices {
                if flag.isCancelled { break }
                if items[index].output != nil { completed += 1; continue }
                items[index].status = "Extraindo…"
                items[index].failed = false
                let source = items[index].source
                let parent = destination ?? source.deletingLastPathComponent()
                let result = await Task.detached(priority: .userInitiated) {
                    Self.unpack(source: source, parent: parent, password: passphrase, token: flag, mode: mode)
                }.value
                switch result {
                case .success(let folder):
                    items[index].status = "Extraído com sucesso"
                    items[index].output = folder
                case .failure(let error):
                    items[index].status = error.localizedDescription
                    items[index].failed = true
                }
                completed += 1
            }
            busy = false
            token = nil
            password = ""
        }
    }

    nonisolated static func unpack(source: URL, parent: URL, password: String = "", token: CancellationFlag = CancellationFlag(), mode: ExtractionMode = .folder) -> Result<URL, NSError> {
        do { return .success(try ArchiveService.extract(source, parent: parent, mode: mode, password: password, token: token)) }
        catch { return .failure(error as NSError) }
    }

}

struct ContentView: View {
    @ObservedObject var model: ExtractorModel
    @State private var targeted = false
    @AppStorage("extractionMode") private var extractionMode = ExtractionMode.folder.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button(action: model.selectFiles) {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 31, weight: .light))
                    Text("Arraste seus arquivos aqui").font(.headline)
                    Text("ou clique para escolher • seleção de vários arquivos").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 25)
                .background(targeted ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.busy)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
                guard !model.busy else { return false }
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.add([url]) } }
                    }
                }
                return true
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DESTINO").font(.caption2.bold()).foregroundStyle(.secondary)
                    Text(model.destination?.path ?? "Na mesma pasta do arquivo original")
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Alterar…", action: model.selectDestination).disabled(model.busy)
            }

            Picker("Como extrair", selection: $extractionMode) {
                ForEach(ExtractionMode.allCases) { Text($0.label).tag($0.rawValue) }
            }.pickerStyle(.segmented).disabled(model.busy)

            SecureField("Senha do arquivo, se houver", text: $model.password)
                .textFieldStyle(.roundedBorder).disabled(model.busy)

            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Text("Tudo pronto para começar").font(.headline)
                    Text(extractionMode == ExtractionMode.here.rawValue
                         ? "Extrai direto no destino, mantendo as pastas do arquivo e preservando os itens existentes."
                         : "Cada arquivo será extraído em uma nova pasta, sem substituir as existentes.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.items) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.failed ? "exclamationmark.triangle.fill" : item.output == nil ? "doc.zipper" : "checkmark.circle.fill")
                                    .foregroundStyle(item.failed ? .red : item.output == nil ? .secondary : .green)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.source.lastPathComponent).fontWeight(.medium).lineLimit(1)
                                    Text(item.status).font(.caption).foregroundStyle(item.failed ? .red : .secondary).textSelection(.enabled)
                                }
                                Spacer()
                                if item.output == nil {
                                    Button { model.inspect(item.source, verify: false) } label: { Image(systemName: "list.bullet.rectangle") }
                                        .help("Ver conteúdo").disabled(model.busy)
                                    Button { model.inspect(item.source, verify: true) } label: { Image(systemName: "checkmark.shield") }
                                        .help("Testar integridade").disabled(model.busy)
                                }
                                if let folder = item.output {
                                    Button("Ver no Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                                }
                            }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }

            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text("Processando…").font(.caption).foregroundStyle(.secondary)
                    Button("Cancelar", action: model.cancel)
                } else if !model.items.isEmpty {
                    Button("Limpar lista") { model.items.removeAll() }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.extract(mode: ExtractionMode(rawValue: extractionMode) ?? .folder) } label: {
                    Label(model.busy ? "Extraindo…" : extractionMode == ExtractionMode.here.rawValue ? "Extrair aqui" : "Extrair arquivos", systemImage: "archivebox")
                        .padding(.horizontal, 10).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || model.items.isEmpty || model.items.allSatisfy { $0.output != nil })
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


struct ArchiveContentsView: View {
    @ObservedObject var model: ExtractorModel
    @State private var query = ""
    var visible: [ArchiveMember] {
        model.members.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.contentsTitle).font(.title2.bold()).lineLimit(1)
                    Text("\(model.members.count) itens • Prévia dos nomes, sem extrair").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fechar") { model.showContents = false }.keyboardShortcut(.cancelAction)
            }
            TextField("Buscar no conteúdo", text: $query).textFieldStyle(.roundedBorder)
            List(visible) { entry in
                HStack {
                    Image(systemName: entry.directory ? "folder.fill" : "doc").foregroundStyle(entry.directory ? .orange : .secondary)
                    Text(entry.path).textSelection(.enabled)
                    Spacer()
                    if !entry.directory {
                        Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(24).frame(width: 700, height: 520)
    }
}
