import AppKit
import SwiftUI

/// `--snapshot <dir>`: renders every section of the main window to PNG and quits.
/// Used to check the UI without screen-recording permission.
@MainActor
enum Snapshotter {
    static func runIfRequested(_ model: AppModel) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task {
            while model.report == nil || model.phase != .idle { try? await Task.sleep(for: .milliseconds(200)) }
            for s in Section.allCases {
                model.section = s
                try? await Task.sleep(for: .milliseconds(900))
                capture(to: dir.appendingPathComponent("\(Section.allCases.firstIndex(of: s)!)-\(s.rawValue).png"))
            }
            model.section = .overview
            model.confirming = true
            try? await Task.sleep(for: .milliseconds(900))
            capture(to: dir.appendingPathComponent("9-clean-sheet.png"), sheet: true)
            model.confirming = false
            exit(0)
        }
    }

    static func capture(to url: URL, sheet: Bool = false) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }) else { return }
        let target = sheet ? (window.attachedSheet ?? window) : window
        guard let view = target.contentView?.superview ?? target.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
