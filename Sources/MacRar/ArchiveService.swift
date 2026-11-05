import Foundation
import CryptoKit
import ArchiveBridge

final class CancellationFlag: @unchecked Sendable {
    let pointer: OpaquePointer?
    private let lock = NSLock()
    private var requested = false
    init() { pointer = macrar_cancel_new() }
    deinit { macrar_cancel_free(pointer) }
    func cancel() {
        lock.lock()
        requested = true
        macrar_cancel(pointer)
        lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
    func check() throws { if isCancelled { throw ArchiveFailure(message: "Operação cancelada.") } }
}

struct ArchiveFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

func bridgeError(_ buffer: [CChar]) -> ArchiveFailure {
    ArchiveFailure(message: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
}

enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case zip = "ZIP", sevenZip = "7z", tar = "TAR", gzip = "TAR.GZ", bzip = "TAR.BZ2", xz = "TAR.XZ"
    var id: String { rawValue }
    var suffix: String { rawValue.lowercased() }
    var engine: String { self == .zip ? "zip" : self == .sevenZip ? "7zip" : "paxr" }
    var filter: String {
        switch self { case .gzip: "gzip"; case .bzip: "bzip2"; case .xz: "xz"; default: "" }
    }
}

enum CompressionLevel: Int, CaseIterable, Identifiable, Sendable {
    case fast = 1, balanced = 6, maximum = 9
    var id: Int { rawValue }
    var label: String {
        switch self { case .fast: "Rápida"; case .balanced: "Equilibrada"; case .maximum: "Máxima" }
    }
}

struct CompressionOptions: Sendable {
    let format: ArchiveFormat
    let level: CompressionLevel
    let password: String
    let includeHidden: Bool
    let verify: Bool
    let volumeMB: Int
}

struct CompressionResult: Sendable {
    let outputs: [URL]
    let inputBytes: Int64
    let outputBytes: Int64
    let entries: Int
}

struct ArchiveMember: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let size: Int64
    let directory: Bool
}

private final class MemberCollector {
    var members: [ArchiveMember] = []
    var total = 0
}

struct PreparedArchive {
    let url: URL
    let temporaryDirectory: URL?
    func cleanup() { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }
}

// All methods run on a worker task; no archive work blocks the main thread.
enum ArchiveService {
    typealias Progress = @Sendable (String, Double) -> Void
    private struct PartsManifest: Codable {
        let version: Int
        let count: Int
        let totalBytes: Int64
        let sha256: String
    }
    private struct Input {
        let url: URL
        let name: String
        let bytes: Int64
    }

    static func inspect(_ source: URL, password: String, verify: Bool, token: CancellationFlag) throws -> [ArchiveMember] {
        let prepared = try prepare(source, token: token)
        defer { prepared.cleanup() }
        let collector = MemberCollector()
        var error = [CChar](repeating: 0, count: 4096)
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let result = macrar_inspect(prepared.url.path, password, verify ? 1 : 0, { path, size, directory, context in
            guard let path, let context else { return }
            let collector = Unmanaged<MemberCollector>.fromOpaque(context).takeUnretainedValue()
            collector.total += 1
            // Keep browsing bounded even for archives containing millions of entries.
            if collector.members.count < 100_000 {
                collector.members.append(ArchiveMember(path: String(cString: path), size: max(0, size), directory: directory != 0))
            }
        }, context, token.pointer, &error, error.count)
        guard result == 0 else { throw bridgeError(error) }
        if collector.total > collector.members.count {
            collector.members.append(ArchiveMember(path: "Lista limitada aos primeiros 100.000 itens.", size: 0, directory: false))
        }
        return collector.members
    }

    static func compress(_ sources: [URL], destination: URL, options: CompressionOptions,
                         token: CancellationFlag, progress: Progress) throws -> CompressionResult {
        let manager = FileManager.default
        let output = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !sources.isEmpty else { throw ArchiveFailure(message: "Selecione arquivos ou pastas.") }
        for source in sources {
            let path = source.standardizedFileURL.resolvingSymlinksInPath().path
            if output.path == path || output.path.hasPrefix(path + "/") {
                throw ArchiveFailure(message: "Escolha um destino fora dos arquivos e pastas selecionados.")
            }
        }
        if options.volumeMB > 0 {
            let prefix = output.lastPathComponent + "."
            let siblings = try manager.contentsOfDirectory(at: output.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            if siblings.contains(where: { url in
                guard url.lastPathComponent.hasPrefix(prefix) else { return false }
                let suffix = String(url.lastPathComponent.dropFirst(prefix.count))
                return suffix == "parts.json" || (suffix.count >= 3 && suffix.allSatisfy { $0.isASCII && $0.isNumber })
            }) {
                throw ArchiveFailure(message: "Já existem partes com esse nome no destino. Escolha outro nome.")
            }
        }
        progress("Preparando arquivos…", 0)
        let inputs = try plan(sources, includeHidden: options.includeHidden, token: token)
        let totalBytes = inputs.reduce(Int64(0)) { $0 + $1.bytes }
        let work = output.deletingLastPathComponent().appendingPathComponent(".MacRar-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: work) }
        let temporary = work.appendingPathComponent(output.lastPathComponent)
        var error = [CChar](repeating: 0, count: 4096)
        let password = options.format == .zip ? options.password : ""
        guard let writer = macrar_writer_open(temporary.path, options.format.engine, options.format.filter,
                                             options.format == .tar ? -1 : Int32(options.level.rawValue),
                                             password, token.pointer, &error, error.count) else { throw bridgeError(error) }
        var writerOpen = true
        defer { if writerOpen { macrar_writer_abort(writer) } }
        var completedBytes: Int64 = 0
        var lastUpdate = Date.distantPast
        for (index, input) in inputs.enumerated() {
            try token.check()
            if Date().timeIntervalSince(lastUpdate) > 0.1 {
                let fraction = totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : Double(index) / Double(max(inputs.count, 1))
                progress("Compactando \(input.name)", fraction * 0.8)
                lastUpdate = Date()
            }
            guard macrar_writer_add(writer, input.url.path, input.name, &error, error.count) == 0 else { throw bridgeError(error) }
            completedBytes += input.bytes
        }
        progress("Finalizando o arquivo…", 0.8)
        let closeResult = macrar_writer_close(writer, &error, error.count)
        writerOpen = false
        guard closeResult == 0 else { throw bridgeError(error) }
        try token.check()
        if options.verify {
            progress("Verificando integridade…", 0.85)
            guard macrar_inspect(temporary.path, password, 1, nil, nil, token.pointer, &error, error.count) == 0 else { throw bridgeError(error) }
        }
        let outputBytes = (try manager.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        let staged: [URL]
        if options.volumeMB > 0 {
            progress("Dividindo em partes…", 0.9)
            staged = try split(temporary, bytesPerPart: Int64(options.volumeMB) * 1024 * 1024, token: token)
        } else { staged = [temporary] }
        // Hard-link publication is atomic and fails if a destination already exists.
        // Roll back only files published by this job if a multi-part operation fails.
        var published: [URL] = []
        do {
            for file in staged {
                try token.check()
                let target = output.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent)
                try manager.linkItem(at: file, to: target)
                published.append(target)
            }
        } catch {
            for target in published { try? manager.removeItem(at: target) }
            throw error
        }
        progress("Concluído", 1)
        return CompressionResult(outputs: published, inputBytes: totalBytes, outputBytes: outputBytes, entries: inputs.count)
    }

    private static func plan(_ sources: [URL], includeHidden: Bool, token: CancellationFlag) throws -> [Input] {
        let manager = FileManager.default
        var names = Set<String>()
        var inputs: [Input] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        func append(_ url: URL, name: String) throws {
            try token.check()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true && (values.isRegularFile == true || values.isDirectory == true) else {
                throw ArchiveFailure(message: "Links e arquivos especiais não são compactados: \(name)")
            }
            inputs.append(Input(url: url, name: name, bytes: values.isRegularFile == true ? Int64(values.fileSize ?? 0) : 0))
        }
        for source in sources {
            let name = source.lastPathComponent
            guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ArchiveFailure(message: "Há itens com o mesmo nome: \(name). Renomeie um deles antes de compactar.")
            }
            try append(source, name: name)
            if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                var enumerationError: Error?
                guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: Array(keys),
                    options: includeHidden ? [] : [.skipsHiddenFiles], errorHandler: { _, error in
                        enumerationError = error
                        return false
                    }) else { throw ArchiveFailure(message: "Não foi possível listar \(name).") }
                for case let child as URL in enumerator {
                    let relative = child.pathComponents.suffix(enumerator.level).joined(separator: "/")
                    try append(child, name: name + "/" + relative)
                }
                if let enumerationError { throw enumerationError }
            }
        }
        return inputs
    }

    static func split(_ archive: URL, bytesPerPart: Int64, token: CancellationFlag) throws -> [URL] {
        guard bytesPerPart > 0 else { throw ArchiveFailure(message: "Tamanho de parte inválido.") }
        let reader = try FileHandle(forReadingFrom: archive)
        defer { try? reader.close() }
        var parts: [URL] = []
        var digest = SHA256()
        var totalBytes: Int64 = 0
        var eof = false
        while !eof {
            try token.check()
            guard let first = try reader.read(upToCount: Int(min(1024 * 1024, bytesPerPart))), !first.isEmpty else { break }
            let part = URL(fileURLWithPath: archive.path + String(format: ".%03d", parts.count + 1))
            guard FileManager.default.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ArchiveFailure(message: "Não foi possível criar uma parte do arquivo.")
            }
            let writer = try FileHandle(forWritingTo: part)
            do {
                try writer.write(contentsOf: first)
                digest.update(data: first)
                totalBytes += Int64(first.count)
                var written = Int64(first.count)
                while written < bytesPerPart {
                    try token.check()
                    guard let data = try reader.read(upToCount: Int(min(1024 * 1024, bytesPerPart - written))), !data.isEmpty else { eof = true; break }
                    try writer.write(contentsOf: data)
                    digest.update(data: data)
                    totalBytes += Int64(data.count)
                    written += Int64(data.count)
                }
                try writer.close()
            } catch { try? writer.close(); throw error }
            parts.append(part)
        }
        let manifest = PartsManifest(version: 1, count: parts.count, totalBytes: totalBytes,
                                     sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
        let manifestURL = URL(fileURLWithPath: archive.path + ".parts.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        return parts + [manifestURL]
    }

    static func prepare(_ source: URL, token: CancellationFlag) throws -> PreparedArchive {
        guard source.pathExtension == "001" else { return PreparedArchive(url: source, temporaryDirectory: nil) }
        let manager = FileManager.default
        let prefix = source.deletingPathExtension().lastPathComponent + "."
        let siblings = try manager.contentsOfDirectory(at: source.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let parts: [(Int, URL)] = siblings.compactMap { url in
            guard url.lastPathComponent.hasPrefix(prefix) else { return nil }
            let suffix = String(url.lastPathComponent.dropFirst(prefix.count))
            guard suffix.count >= 3, suffix.allSatisfy({ $0.isASCII && $0.isNumber }), let index = Int(suffix), index > 0 else { return nil }
            return (index, url)
        }.sorted { $0.0 < $1.0 }
        guard !parts.isEmpty, parts.enumerated().allSatisfy({ $0.offset + 1 == $0.element.0 }) else {
            throw ArchiveFailure(message: "Faltam partes do arquivo. Coloque todas (.001, .002…) na mesma pasta.")
        }
        let manifestURL = URL(fileURLWithPath: source.deletingPathExtension().path + ".parts.json")
        let manifest: PartsManifest?
        if manager.fileExists(atPath: manifestURL.path) {
            let attributes = try manager.attributesOfItem(atPath: manifestURL.path)
            guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) < 64 * 1024 else {
                throw ArchiveFailure(message: "Manifesto de partes inválido.")
            }
            manifest = try JSONDecoder().decode(PartsManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest?.version == 1, manifest?.count == parts.count else {
                throw ArchiveFailure(message: "O conjunto está incompleto. Confira as partes e o arquivo .parts.json.")
            }
        } else { manifest = nil }
        let work = manager.temporaryDirectory.appendingPathComponent("MacRar-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let joined = work.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
        do {
            guard manager.createFile(atPath: joined.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ArchiveFailure(message: "Não foi possível criar o arquivo temporário.")
            }
            let writer = try FileHandle(forWritingTo: joined)
            defer { try? writer.close() }
            var digest = SHA256()
            var totalBytes: Int64 = 0
            for (_, part) in parts {
                try token.check()
                let reader = try FileHandle(forReadingFrom: part)
                do {
                    while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty {
                        try token.check()
                        try writer.write(contentsOf: data)
                        digest.update(data: data)
                        totalBytes += Int64(data.count)
                    }
                    try reader.close()
                } catch { try? reader.close(); throw error }
            }
            if let manifest {
                let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
                guard totalBytes == manifest.totalBytes, hash == manifest.sha256 else {
                    throw ArchiveFailure(message: "As partes estão danificadas ou incompletas (verificação SHA-256 falhou).")
                }
            }
            return PreparedArchive(url: joined, temporaryDirectory: work)
        } catch { try? manager.removeItem(at: work); throw error }
    }
}
