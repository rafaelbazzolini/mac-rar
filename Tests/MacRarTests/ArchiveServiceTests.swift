import XCTest
@testable import MacRar

final class ArchiveServiceTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func options(format: ArchiveFormat = .zip, hidden: Bool = false, volumes: Int = 0) -> CompressionOptions {
        CompressionOptions(format: format, level: .balanced, password: "", includeHidden: hidden, verify: true, volumeMB: volumes)
    }
    func testHiddenFilesAndEmptyFolders() throws {
        try fixture { root in
            let folder = root.appendingPathComponent("input")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try Data("visible".utf8).write(to: folder.appendingPathComponent("hello.txt"))
            try Data("hidden".utf8).write(to: folder.appendingPathComponent(".secret"))
            let zip = root.appendingPathComponent("test.zip")
            _ = try ArchiveService.compress([folder], destination: zip, options: options(), token: CancellationFlag()) { _, _ in }
            let members = try ArchiveService.inspect(zip, password: "", verify: true, token: CancellationFlag())
            XCTAssertTrue(members.contains { $0.path == "input/hello.txt" })
            XCTAssertTrue(members.contains { $0.path.hasPrefix("input/empty") && $0.directory })
            XCTAssertFalse(members.contains { $0.path.contains(".secret") })
            let withHidden = root.appendingPathComponent("hidden.zip")
            _ = try ArchiveService.compress([folder], destination: withHidden, options: options(hidden: true), token: CancellationFlag()) { _, _ in }
            XCTAssertTrue(try ArchiveService.inspect(withHidden, password: "", verify: true, token: CancellationFlag()).contains { $0.path == "input/.secret" })
        }
    }
    func testSplitJoinMissingAndCorruptedParts() throws {
        try fixture { root in
            let archive = root.appendingPathComponent("input.zip")
            let payload = Data((0..<5000).map { UInt8($0 % 251) })
            try payload.write(to: archive)
            let parts = try ArchiveService.split(archive, bytesPerPart: 1000, token: CancellationFlag())
            XCTAssertEqual(parts.count, 6) // five parts plus the SHA-256 manifest
            let prepared = try ArchiveService.prepare(parts[0], token: CancellationFlag())
            defer { prepared.cleanup() }
            XCTAssertEqual(try Data(contentsOf: prepared.url), payload)
            // Missing final parts must fail even if the remaining numbering is continuous.
            try FileManager.default.removeItem(at: parts[4])
            XCTAssertThrowsError(try ArchiveService.prepare(parts[0], token: CancellationFlag()))
            try payload.suffix(1000).write(to: parts[4])
            try Data(repeating: 42, count: 1000).write(to: parts[1])
            XCTAssertThrowsError(try ArchiveService.prepare(parts[0], token: CancellationFlag()))
        }
    }
    func testDestinationAndDuplicateProtection() throws {
        try fixture { root in
            let folder = root.appendingPathComponent("input")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let file = folder.appendingPathComponent("hello.txt")
            try Data("hello".utf8).write(to: file)
            XCTAssertThrowsError(try ArchiveService.compress([folder], destination: folder.appendingPathComponent("self.zip"), options: options(), token: CancellationFlag()) { _, _ in })
            let existing = root.appendingPathComponent("exists.zip")
            let original = Data("preserve this".utf8)
            try original.write(to: existing)
            XCTAssertThrowsError(try ArchiveService.compress([file], destination: existing, options: options(), token: CancellationFlag()) { _, _ in })
            XCTAssertEqual(try Data(contentsOf: existing), original)
            let other = root.appendingPathComponent("hello.txt")
            try Data("other".utf8).write(to: other)
            XCTAssertThrowsError(try ArchiveService.compress([file, other], destination: root.appendingPathComponent("duplicate.zip"), options: options(), token: CancellationFlag()) { _, _ in })
        }
    }
    func testMultipartPublicationRollbackAndExtraction() throws {
        try fixture { root in
            let source = root.appendingPathComponent("hello.txt")
            let payload = Data("multipart round trip".utf8)
            try payload.write(to: source)
            let zip = root.appendingPathComponent("multipart.zip")
            let manifest = URL(fileURLWithPath: zip.path + ".parts.json")
            let original = Data("existing manifest".utf8)
            try original.write(to: manifest)
            XCTAssertThrowsError(try ArchiveService.compress([source], destination: zip, options: options(volumes: 10), token: CancellationFlag()) { _, _ in })
            XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path + ".001"))
            XCTAssertEqual(try Data(contentsOf: manifest), original)
            try FileManager.default.removeItem(at: manifest)
            let created = try ArchiveService.compress([source], destination: zip, options: options(volumes: 10), token: CancellationFlag()) { _, _ in }
            XCTAssertEqual(created.outputs.count, 2)
            let result = ExtractorModel.unpack(source: created.outputs[0], parent: root)
            let folder = try result.get()
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("hello.txt")), payload)
        }
    }
    func testCancelledJobDoesNotPublish() throws {
        try fixture { root in
            let source = root.appendingPathComponent("input.txt")
            try Data("hello".utf8).write(to: source)
            let flag = CancellationFlag()
            flag.cancel()
            let output = root.appendingPathComponent("cancelled.zip")
            XCTAssertThrowsError(try ArchiveService.compress([source], destination: output, options: options(), token: flag) { _, _ in })
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }
}
