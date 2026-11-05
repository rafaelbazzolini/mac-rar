import XCTest
import SwiftUI
import AppKit
@testable import MacRar

final class DocumentationScreenshots: XCTestCase {
    func testRenderDocumentation() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACRAR_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set MACRAR_SCREENSHOT_DIR to render the settings screenshot.")
        }
        try await MainActor.run {
            _ = NSApplication.shared
            NSApp.appearance = NSAppearance(named: .darkAqua)
            let destination = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: ExtractionSettingsView().environment(\.colorScheme, .dark))
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: destination.appendingPathComponent("settings.png"))
        }
    }
}
