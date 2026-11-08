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
        // --snapshot-appearance light|dark
        if let j = args.firstIndex(of: "--snapshot-appearance"), j + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[j + 1] == "dark" ? .darkAqua : .aqua)
        }
        // --snapshot-size 1440x900 sets the window's content size.
        var size: CGSize?
        if let j = args.firstIndex(of: "--snapshot-size"), j + 1 < args.count {
            let p = args[j + 1].split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { size = CGSize(width: p[0], height: p[1]) }
        }
        Task {
            if let size {
                // Before anything is laid out: resizing a laid-out split view leaves it blank.
                for _ in 0..<50 where NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) {
                    w.setContentSize(size)
                    w.center()
                }
            }
            // Settled: results shown, following the disk, no background refresh half done (or 2 minutes).
            let deadline = Date().addingTimeInterval(120)
            while model.report == nil || model.phase != .idle || model.liveState != .live || model.refreshing {
                if Date() > deadline { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            NSApp.activate()
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) {
                // Above other apps' windows while the screen region is captured.
                w.level = .screenSaver
                w.orderFrontRegardless()
            }
            for s in Section.allCases {
                model.section = s
                try? await Task.sleep(for: .milliseconds(1500))
                await capture(to: dir.appendingPathComponent("\(s.rawValue).png"))
            }
            if let d = model.externals.first {
                model.page = .disk(d.id)
                try? await Task.sleep(for: .milliseconds(1500))
                await capture(to: dir.appendingPathComponent("external.png"))
                model.showDiskMap = true
                try? await Task.sleep(for: .milliseconds(1500))
                await capture(to: dir.appendingPathComponent("external-map.png"))
                model.showDiskMap = false
            }
            model.section = .overview
            model.confirmCleanUp()
            try? await Task.sleep(for: .milliseconds(900))
            await capture(to: dir.appendingPathComponent("clean-sheet.png"), sheet: true)
            model.confirming = false
            exit(0)
        }
    }

    static func capture(to url: URL, sheet: Bool = false) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }) else { return }
        let target = sheet ? (window.attachedSheet ?? window) : window
        // --snapshot-external: launched through LaunchServices (Liquid Glass renders properly only then),
        // so another process takes the shot: we write "<png>.region" (x,y,w,h, top-left origin) and wait.
        if CommandLine.arguments.contains("--snapshot-external") {
            let f = window.frame
            let top = (NSScreen.screens.first ?? NSScreen.main)!.frame.maxY - f.maxY
            let region = url.path + ".region"
            try? "\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))".write(toFile: region, atomically: true, encoding: .utf8)
            for _ in 0..<150 where !FileManager.default.fileExists(atPath: url.path) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? FileManager.default.removeItem(atPath: region)
            return
        }
        // The window's screen region when screen recording is allowed: Liquid Glass needs what is
        // behind the window, which a single-window capture leaves white. Otherwise a plain redraw.
        if CGPreflightScreenCaptureAccess(), let screen = window.screen ?? NSScreen.main {
            let f = window.frame
            let top = (NSScreen.screens.first ?? screen).frame.maxY - f.maxY
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))", url.path]
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return }
        }
        guard let view = target.contentView?.superview ?? target.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
