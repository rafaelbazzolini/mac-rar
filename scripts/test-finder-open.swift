// macOS integration smoke test. Temporarily changes this app's preferences,
// restores them on exit, and leaves the rebuilt app open for manual inspection.
import AppKit
import CoreGraphics
import Foundation

let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let defaults = UserDefaults(suiteName: "com.macrar.app")!
let oldAutomatic = defaults.object(forKey: "automaticExtraction")
let oldMode = defaults.object(forKey: "extractionMode")
let root = appURL.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".build/finder-smoke-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func pump(_ seconds: TimeInterval) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
}
func stopApp() throws {
    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == appURL }
    for app in apps { app.terminate() }
    let deadline = Date().addingTimeInterval(5)
    while apps.contains(where: { !$0.isTerminated }) && Date() < deadline { pump(0.1) }
    if apps.contains(where: { !$0.isTerminated }) { throw NSError(domain: "smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Old app did not terminate"] ) }
}
func saveDefaults(_ automatic: Bool, _ mode: String) {
    defaults.set(automatic, forKey: "automaticExtraction")
    defaults.set(mode, forKey: "extractionMode")
    defaults.synchronize()
}
func launch(_ file: URL?, newInstance: Bool = true) throws -> NSRunningApplication {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = file == nil
    configuration.createsNewApplicationInstance = newInstance
    var started: NSRunningApplication?
    var launchError: Error?
    if let file {
        NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: configuration) { app, error in
            started = app
            launchError = error
        }
    } else {
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            started = app
            launchError = error
        }
    }
    let deadline = Date().addingTimeInterval(10)
    while started == nil && launchError == nil && Date() < deadline { pump(0.1) }
    if let launchError { throw launchError }
    guard let started else { throw NSError(domain: "smoke", code: 2) }
    return started
}
func visibleWindows(_ app: NSRunningApplication) -> Int {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }.count
}
func restore() {
    if let oldAutomatic { defaults.set(oldAutomatic, forKey: "automaticExtraction") }
    else { defaults.removeObject(forKey: "automaticExtraction") }
    if let oldMode { defaults.set(oldMode, forKey: "extractionMode") }
    else { defaults.removeObject(forKey: "extractionMode") }
    defaults.synchronize()
}

do {
    try stopApp()
    for mode in ["folder", "here"] {
        let working = root.appendingPathComponent(mode)
        let input = working.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try Data("Finder open test".utf8).write(to: input.appendingPathComponent("report.txt"))
        let zip = working.appendingPathComponent("material.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", input.path, zip.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "smoke", code: 3) }
        try FileManager.default.removeItem(at: input)
        saveDefaults(true, mode)
        let app = try launch(zip)
        let expected = working.appendingPathComponent(mode == "here" ? "input/report.txt" : "material/input/report.txt")
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: expected.path) && Date() < deadline { pump(0.1) }
        guard FileManager.default.fileExists(atPath: expected.path) else { throw NSError(domain: "smoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "Auto extraction did not finish: \(mode)"]) }
        pump(1)
        guard visibleWindows(app) == 0 else { throw NSError(domain: "smoke", code: 5, userInfo: [NSLocalizedDescriptionKey: "Auto extraction opened a window: \(mode)"]) }
        print("PASS Finder open: \(mode), extracted successfully with no visible app window")
        let second = working.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try Data("Warm Finder open".utf8).write(to: second.appendingPathComponent("report.txt"))
        let extra = working.appendingPathComponent("extra.zip")
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        pack.arguments = ["-c", "-k", "--keepParent", second.path, extra.path]
        try pack.run()
        pack.waitUntilExit()
        guard pack.terminationStatus == 0 else { throw NSError(domain: "smoke", code: 7) }
        try FileManager.default.removeItem(at: second)
        let warm = try launch(extra, newInstance: false)
        let warmExpected = working.appendingPathComponent(mode == "here" ? "second/report.txt" : "extra/second/report.txt")
        let warmDeadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: warmExpected.path) && Date() < warmDeadline { pump(0.1) }
        pump(0.5)
        guard warm.processIdentifier == app.processIdentifier,
              FileManager.default.fileExists(atPath: warmExpected.path), visibleWindows(warm) == 0 else {
            throw NSError(domain: "smoke", code: 8, userInfo: [NSLocalizedDescriptionKey: "Warm automatic launch failed: \(mode)"])
        }
        print("PASS Finder open with app already running: \(mode), no visible window")
        try stopApp()
    }
    saveDefaults(false, "folder")
    let manual = try launch(nil)
    pump(1)
    guard visibleWindows(manual) > 0 else { throw NSError(domain: "smoke", code: 6, userInfo: [NSLocalizedDescriptionKey: "Manual launch has no window"]) }
    print("PASS manual launch opens the main window")
    try stopApp()
    restore()
    _ = try launch(nil)
    try? FileManager.default.removeItem(at: root)
    print("Preferences restored; updated app opened.")
} catch {
    try? stopApp()
    restore()
    _ = try? launch(nil)
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
