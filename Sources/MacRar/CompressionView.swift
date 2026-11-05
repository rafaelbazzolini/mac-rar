import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class CompressionModel: ObservableObject {
    @Published var sources: [URL] = []
    @Published var format: ArchiveFormat = .zip
    @Published var level: CompressionLevel = .balanced
    @Published var password = ""
    @Published var confirmation = ""
    @Published var includeHidden = false
    @Published var verify = true
    @Published var volumeMB = 0
    @Published var busy = false
    @Published var status = ""
    @Published var progress = 0.0
    @Published var result: CompressionResult?
    @Published var failed = false
    private var token: CancellationFlag?

    func add(_ urls: [URL]) {
        guard !busy else { return }
        result = nil
        status = ""
        for url in urls where url.isFileURL && FileManager.default.fileExists(atPath: url.path) {
            let normalized = url.standardizedFileURL
            if sources.contains(where: { normalized.path == $0.path || normalized.path.hasPrefix($0.path + "/") }) { continue }
            sources.removeAll { $0.path.hasPrefix(normalized.path + "/") }
            sources.append(normalized)
        }
    }
    func select() {
        let panel = NSOpenPanel()
        panel.title = "Escolha arquivos e pastas para compactar"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func cancel() { token?.cancel(); status = "Cancelando…" }
    func create() {
        guard !busy, !sources.isEmpty else { return }
        failed = false
        result = nil
        guard format != .zip || password == confirmation else {
            status = "As senhas não coincidem."
            failed = true
            return
        }
        let panel = NSSavePanel()
        panel.title = "Salvar arquivo compactado"
        panel.nameFieldStringValue = (sources.count == 1 ? sources[0].deletingPathExtension().lastPathComponent : "Arquivo") + "." + format.suffix
        panel.canCreateDirectories = true
        panel.message = volumeMB > 0 ? "Serão criadas partes numeradas (.001, .002…). Arquivos existentes serão preservados." : "Escolha um nome novo. Arquivos existentes serão preservados."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let destination = chosen.lastPathComponent.lowercased().hasSuffix("." + format.suffix) ? chosen : chosen.appendingPathExtension(format.suffix)
        let options = CompressionOptions(format: format, level: level, password: password,
                                         includeHidden: includeHidden, verify: verify, volumeMB: volumeMB)
        let inputs = sources
        let flag = CancellationFlag()
        token = flag
        busy = true
        progress = 0
        status = "Preparando arquivos…"
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    try ArchiveService.compress(inputs, destination: destination, options: options, token: flag) { message, fraction in
                        Task { @MainActor in
                            guard self.busy else { return }
                            self.status = message
                            self.progress = fraction
                        }
                    }
                }
            }.value
            switch outcome {
            case .success(let created):
                result = created
                status = "\(created.entries) itens compactados com sucesso"
                progress = 1
            case .failure(let error):
                status = error.localizedDescription
                failed = !flag.isCancelled
            }
            password = ""
            confirmation = ""
            busy = false
            token = nil
        }
    }
}

struct CompressionView: View {
    @ObservedObject var model: CompressionModel
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: model.select) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 28)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Adicione arquivos e pastas").font(.headline)
                        Text("Arraste aqui ou clique para escolher").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.orange)
                }
                .padding(20).background(targeted ? Color.orange.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5])))
            }.buttonStyle(.plain).disabled(model.busy)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
                guard !model.busy else { return false }
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.add([url]) } }
                    }
                }
                return true
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    if model.sources.isEmpty {
                        Text("Selecione o que deseja reunir em um arquivo compactado.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
                    }
                    ForEach(model.sources, id: \.self) { source in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: source.path)).resizable().frame(width: 22, height: 22)
                            Text(source.lastPathComponent).lineLimit(1)
                            Spacer()
                            Button { model.sources.removeAll { $0 == source }; model.result = nil } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain).disabled(model.busy).help("Remover da seleção")
                        }.padding(9).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }.frame(minHeight: 75, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 20) {
                    Picker("Formato", selection: $model.format) {
                        ForEach(ArchiveFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Compressão", selection: $model.level) {
                        ForEach(CompressionLevel.allCases) { Text($0.label).tag($0) }
                    }.disabled(model.format == .tar)
                }
                HStack {
                    SecureField("Senha (opcional, ZIP)", text: $model.password)
                    SecureField("Confirme a senha", text: $model.confirmation)
                }.textFieldStyle(.roundedBorder).disabled(model.format != .zip)
                if model.format == .zip && !model.password.isEmpty {
                    Text("ZIP com AES-256. A senha protege o conteúdo; os nomes continuam visíveis.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Dividir em partes", selection: $model.volumeMB) {
                    Text("Não dividir").tag(0)
                    Text("10 MB").tag(10)
                    Text("100 MB").tag(100)
                    Text("700 MB").tag(700)
                    Text("4 GB").tag(4096)
                }
                if model.volumeMB > 0 {
                    Text("Partes .001, .002… com manifesto SHA-256. Guarde também o .parts.json e abra a .001 no MacRar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 22) {
                    Toggle("Incluir arquivos ocultos", isOn: $model.includeHidden)
                    Toggle("Verificar após criar", isOn: $model.verify)
                }.font(.callout)
            }
            .disabled(model.busy)
            .padding(16).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))

            if !model.status.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.status).font(.callout).foregroundStyle(model.failed ? .red : .primary).lineLimit(3).textSelection(.enabled)
                    if model.busy { ProgressView(value: model.progress) }
                    if let result = model.result {
                        HStack {
                            Text("\(ByteCountFormatter.string(fromByteCount: result.inputBytes, countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: result.outputBytes, countStyle: .file)) · \(result.outputs.count) arquivo(s)")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Ver no Finder") { NSWorkspace.shared.activateFileViewerSelecting(result.outputs) }
                        }
                    }
                }
            }
            HStack {
                if model.busy { Button("Cancelar", action: model.cancel) }
                else if !model.sources.isEmpty {
                    Button("Limpar seleção") { model.sources.removeAll(); model.result = nil; model.status = "" }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.create) {
                    Label(model.busy ? "Compactando…" : "Criar arquivo…", systemImage: "archivebox.fill")
                        .padding(.horizontal, 10).padding(.vertical, 4)
                }.buttonStyle(.borderedProminent).tint(.orange)
                .disabled(model.busy || model.sources.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}
