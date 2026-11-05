import XCTest
@testable import MacRar

final class ExtractionTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("material")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("my report".utf8).write(to: folder.appendingPathComponent("report.txt"))
        try body(root, folder)
    }
    private func archive(_ source: URL, to output: URL, password: String = "") throws {
        let options = CompressionOptions(format: .zip, level: .balanced, password: password, includeHidden: true, verify: true, volumeMB: 0)
        _ = try ArchiveService.compress([source], destination: output, options: options, token: CancellationFlag()) { _, _ in }
    }
    func testExtractHereAvoidsExtraFolderAndMergesDirectories() throws {
        try fixture { root, source in
            let zip = root.appendingPathComponent("material.zip")
            try archive(source, to: zip)
            let destination = root.appendingPathComponent("output")
            let existing = destination.appendingPathComponent("material")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: existing.appendingPathComponent("existing.txt"))
            let result = try ExtractorModel.unpack(source: zip, parent: destination, mode: .here).get()
            XCTAssertEqual(result, destination)
            XCTAssertEqual(try String(contentsOf: existing.appendingPathComponent("report.txt"), encoding: .utf8), "my report")
            XCTAssertEqual(try String(contentsOf: existing.appendingPathComponent("existing.txt"), encoding: .utf8), "keep")
            XCTAssertFalse(FileManager.default.fileExists(atPath: existing.appendingPathComponent("material").path))
        }
    }
    func testConflictPreservesExistingFilesAndLeavesNoPartialOutput() throws {
        try fixture { root, source in
            try Data("new".utf8).write(to: source.appendingPathComponent("another.txt"))
            let zip = root.appendingPathComponent("material.zip")
            try archive(source, to: zip)
            let destination = root.appendingPathComponent("output")
            let existing = destination.appendingPathComponent("material")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            let report = existing.appendingPathComponent("report.txt")
            try Data("original".utf8).write(to: report)
            XCTAssertThrowsError(try ExtractorModel.unpack(source: zip, parent: destination, mode: .here).get())
            XCTAssertEqual(try String(contentsOf: report, encoding: .utf8), "original")
            XCTAssertFalse(FileManager.default.fileExists(atPath: existing.appendingPathComponent("another.txt").path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["material"])
        }
    }
    func testExistingSymlinkCannotRedirectExtractionHere() throws {
        try fixture { root, source in
            let zip = root.appendingPathComponent("material.zip")
            try archive(source, to: zip)
            let destination = root.appendingPathComponent("output")
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("material"), withDestinationURL: outside)
            XCTAssertThrowsError(try ExtractorModel.unpack(source: zip, parent: destination, mode: .here).get())
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }
    func testNormalModeKeepsUniqueFolderBehavior() throws {
        try fixture { root, source in
            let zip = root.appendingPathComponent("material.zip")
            try archive(source, to: zip)
            let result = try ExtractorModel.unpack(source: zip, parent: root).get()
            XCTAssertEqual(result.lastPathComponent, "material (2)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent("material/report.txt").path))
        }
    }
    func testPasswordIsClassifiedAndRetryDoesNotLeavePartialFiles() throws {
        try fixture { root, source in
            let zip = root.appendingPathComponent("encrypted.zip")
            try archive(source, to: zip, password: "secret")
            let destination = root.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for password in ["", "wrong"] {
                let result = ExtractorModel.unpack(source: zip, parent: destination, password: password, mode: .here)
                if case .failure(let error) = result { XCTAssertEqual(error.code, -2) }
                else { XCTFail("Expected password error") }
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
            }
            _ = try ExtractorModel.unpack(source: zip, parent: destination, password: "secret", mode: .here).get()
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("material/report.txt").path))
        }
    }
    func testFinderPreferencesDefaultAndPersistence() throws {
        let suite = "MacRarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(FinderOpenPreferences(defaults: defaults).automatic)
        XCTAssertEqual(FinderOpenPreferences(defaults: defaults).mode, .folder)
        defaults.set(true, forKey: "automaticExtraction")
        defaults.set("here", forKey: "extractionMode")
        XCTAssertTrue(FinderOpenPreferences(defaults: defaults).automatic)
        XCTAssertEqual(FinderOpenPreferences(defaults: defaults).mode, .here)
    }
}
