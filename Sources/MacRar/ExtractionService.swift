import Foundation
import Darwin
import ArchiveBridge

enum ExtractionMode: String, CaseIterable, Identifiable, Sendable {
    case folder, here
    var id: String { rawValue }
    var label: String { self == .folder ? "Em uma nova pasta" : "Extrair aqui" }
    static var preferred: ExtractionMode {
        ExtractionMode(rawValue: UserDefaults.standard.string(forKey: "extractionMode") ?? "folder") ?? .folder
    }
}

extension ArchiveService {
    static func extract(_ source: URL, parent: URL, mode: ExtractionMode,
                        password: String, token: CancellationFlag) throws -> URL {
        try token.check()
        let manager = FileManager.default
        let prepared = try prepare(source, token: token)
        defer { prepared.cleanup() }
        // Always decode in a private staging directory first: a wrong password,
        // cancellation or corrupt archive never leaves half-extracted files here.
        let stage = parent.appendingPathComponent(".MacRar-extract-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = macrar_extract_options(prepared.url.path, stage.path, password, token.pointer, &buffer, buffer.count)
        if result != 0 {
            let detail = bridgeError(buffer).message
            let lower = detail.lowercased()
            let passwordRequired = (lower.contains("passphrase") || lower.contains("password")) && !lower.contains("not supported") && !lower.contains("unsupported")
            throw NSError(domain: "MacRar", code: passwordRequired ? -2 : -1,
                          userInfo: [NSLocalizedDescriptionKey: "Não foi possível extrair: \(detail)"])
        }
        try token.check()
        if mode == .here {
            try publishHere(stage, destination: parent, token: token)
            return parent
        }
        let stem = archiveStem(prepared.url.lastPathComponent)
        // renameatx_np with RENAME_EXCL atomically publishes without replacement.
        // Unlike moveItem, an existing directory is never mistaken for a target.
        var number = 1
        while true {
            try token.check()
            let folder = parent.appendingPathComponent(number == 1 ? stem : "\(stem) (\(number))", isDirectory: true)
            if renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, folder.path, UInt32(RENAME_EXCL)) == 0 { return folder }
            if errno == EEXIST { number += 1; continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func archiveStem(_ name: String) -> String {
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        let value = (name as NSString).deletingPathExtension
        return value.isEmpty || value == "." || value == ".." ? "Extraído" : value
    }

    private static func publishHere(_ stage: URL, destination: URL, token: CancellationFlag) throws {
        let manager = FileManager.default
        var scanError: Error?
        guard let enumerator = manager.enumerator(at: stage, includingPropertiesForKeys: [.isDirectoryKey], errorHandler: { _, error in
            scanError = error
            return false
        }) else { throw ArchiveFailure(message: "Não foi possível listar os arquivos extraídos.") }
        var entries: [(source: URL, target: URL, directory: Bool)] = []
        for case let file as URL in enumerator {
            try token.check()
            let relative = file.pathComponents.suffix(enumerator.level).joined(separator: "/")
            let target = destination.appendingPathComponent(relative)
            let directory = try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            // Check with lstat semantics: even a dangling symlink counts as a collision.
            if let attributes = try? manager.attributesOfItem(atPath: target.path) {
                guard directory && attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw ArchiveFailure(message: "Já existe um item chamado \(relative). Nada foi substituído. Use uma nova pasta ou escolha outro destino.")
                }
            }
            entries.append((file, target, directory))
        }
        if let scanError { throw scanError }
        var newFiles: [URL] = []
        var newDirectories: [URL] = []
        do {
            // Parents precede children; existing directory permissions are untouched.
            for entry in entries.sorted(by: { $0.target.pathComponents.count < $1.target.pathComponents.count }) {
                try token.check()
                if entry.directory {
                    do {
                        try manager.createDirectory(at: entry.target, withIntermediateDirectories: false)
                        newDirectories.append(entry.target)
                    } catch {
                        let attributes = try manager.attributesOfItem(atPath: entry.target.path)
                        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw error }
                    }
                } else {
                    // Atomic, no-overwrite publication on the same filesystem.
                    try manager.linkItem(at: entry.source, to: entry.target)
                    newFiles.append(entry.target)
                }
            }
        } catch {
            for file in newFiles.reversed() { try? manager.removeItem(at: file) }
            // Only remove empty directories created by this operation.
            for folder in newDirectories.reversed() { _ = rmdir(folder.path) }
            throw error
        }
    }
}
