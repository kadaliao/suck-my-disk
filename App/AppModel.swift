import DiskIndex
import Foundation
import Observation
import Recognizers
import Reclaim
import SwiftUI

enum Section: String, CaseIterable, Identifiable, Hashable {
    case overview, project, media, devCache, model, appData, disk, timeline
    var id: String { rawValue }

    var kind: ThingKind? {
        switch self {
        case .project: return .project
        case .media: return .media
        case .devCache: return .devCache
        case .model: return .model
        case .appData: return .appData
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .overview: return L("概览", "Overview")
        case .disk: return L("全盘", "Whole Disk")
        case .timeline: return L("时间线", "Timeline")
        default: return kind!.title
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .project: return "hammer"
        case .media: return "film.stack"
        case .devCache: return "shippingbox"
        case .model: return "cpu"
        case .appData: return "square.stack.3d.up"
        case .disk: return "square.grid.3x3.square"
        case .timeline: return "chart.xyaxis.line"
        }
    }
}

extension ThingKind {
    var color: Color {
        switch self {
        case .project: return .blue
        case .media: return .pink
        case .devCache: return .orange
        case .model: return .purple
        case .appData: return .teal
        case .system: return .gray
        }
    }
}

enum Phase: Equatable {
    case idle
    case loading
    case scanning(files: UInt64, bytes: UInt64)
    case recognizing(String)
    case cleaning(current: String, done: Int, total: Int)
}

struct CleanResult: Identifiable {
    let id = UUID()
    var done: Int
    var skipped: [(String, String)]
    var failed: [(String, String)]
    var freed: UInt64
}

@MainActor @Observable
final class AppModel {
    var report: Report?
    var tree: ScanTree?
    var volume = VolumeInfo.of()
    var selection: Set<String> = []
    var phase: Phase = .idle
    var section: Section = .overview
    var lastResult: CleanResult?
    var history: [ReportStore.DayPoint] = []
    /// Documents, Downloads, Pictures… minus the things already counted inside them.
    var userFiles: UInt64 = 0
    var applications: UInt64 = 0
    var confirming = false
    var scanStarted: Date?

    var things: [Thing] { report?.things ?? [] }

    func things(_ kind: ThingKind) -> [Thing] {
        things.filter { $0.kind == kind }.sorted { $0.reclaimable == $1.reclaimable ? $0.bytes > $1.bytes : $0.reclaimable > $1.reclaimable }
    }

    var plan: Planner.Plan { Planner.plan(things: things, selected: selection) }

    func selectedBytes(_ kind: ThingKind) -> UInt64 {
        Planner.plan(things: things(kind), selected: selection).freed
    }

    func reclaimable(_ kind: ThingKind) -> UInt64 { things(kind).reduce(0) { $0 + $1.reclaimable } }

    func occupied(_ kind: ThingKind) -> UInt64 { things(kind).reduce(0) { $0 + $1.bytes } }

    var isBusy: Bool { phase != .idle }

    // MARK: loading

    func start() {
        phase = .loading
        Task {
            let (report, tree) = await Task.detached(priority: .userInitiated) {
                (ReportStore.load(), ReportStore.loadIndex())
            }.value
            self.tree = tree
            self.history = ReportStore.history()
            if let report {
                self.report = report
                apply(report)
                phase = .idle
                if tree == nil { await rescan() }
            } else {
                await rescan()
            }
        }
    }

    private func apply(_ r: Report) {
        report = r
        selection = Set(r.things.flatMap(\.items).filter(\.preselected).map(\.id))
        volume = VolumeInfo.of()
        measureFolders()
    }

    func measureFolders() {
        guard let tree else { return }
        let h = NSHomeDirectory()
        let dirs = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"].map { h + "/" + $0 }
        var total: UInt64 = 0
        for d in dirs { total += tree.find(d).map { tree.size($0) } ?? 0 }
        for t in things where t.kind != .system && t.kind != .appData {
            if let p = t.path, dirs.contains(where: { p.hasPrefix($0 + "/") }) { total -= min(total, t.bytes) }
        }
        userFiles = total
        applications = tree.find("/Applications").map { tree.size($0) } ?? 0
    }

    /// Reclaimable but not selected: things waiting for the user's decision.
    var undecided: UInt64 {
        let all = things.reduce(UInt64(0)) { $0 + $1.reclaimable }
        let chosen = plan.freed
        return all > chosen ? all - chosen : 0
    }

    func rescan() async {
        scanStarted = Date()
        phase = .scanning(files: 0, bytes: 0)
        let progress = ProgressRelay()
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                if case .scanning = phase, let p = progress.value { phase = .scanning(files: p.files, bytes: p.bytes) }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        let tree = await Task.detached(priority: .userInitiated) {
            ScanTree.scan(roots: [Firmlinks.dataRoot]) { progress.value = $0 }
        }.value
        poll.cancel()
        guard let tree else { phase = .idle; return }
        try? ReportStore.saveIndex(tree)
        self.tree = tree
        phase = .recognizing(L("正在识别项目、渲染帧和缓存…", "Recognizing projects, frames and caches…"))
        let relay = LogRelay()
        let logPoll = Task { @MainActor in
            while !Task.isCancelled {
                if case .recognizing = phase, let m = relay.value { phase = .recognizing(m) }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        let report = await Recognize.all(tree: tree) { relay.value = $0 }
        logPoll.cancel()
        ReportStore.save(report)
        ReportStore.writeHistory(report)
        apply(report)
        history = ReportStore.history()
        phase = .idle
    }

    // MARK: cleaning

    func toggle(_ item: ReclaimItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func clean() async {
        let items = plan.items
        guard !items.isEmpty else { return }
        let before = VolumeInfo.freeBytes()
        var done = 0
        var skipped: [(String, String)] = []
        var failed: [(String, String)] = []
        var doneIDs: Set<String> = []
        let store = try? Store()
        for (n, item) in items.enumerated() {
            phase = .cleaning(current: item.label, done: n, total: items.count)
            let outcome = await Task.detached(priority: .userInitiated) {
                Executor(store: store, force: false, log: { _ in }).run([item])[0]
            }.value
            switch outcome.status {
            case .done: done += 1; doneIDs.insert(item.id); doneIDs.formUnion(item.covers)
            case .skipped: skipped.append((item.label, outcome.message))
            case .failed: failed.append((item.label, outcome.message))
            }
        }
        let after = VolumeInfo.freeBytes()
        // Drop what is gone so the UI reflects it at once; the index is rebuilt on the next scan.
        if var r = report {
            for t in r.things.indices { r.things[t].items.removeAll { doneIDs.contains($0.id) } }
            r.things.removeAll { $0.items.isEmpty && $0.kind != .system && $0.kind != .appData }
            report = r
            ReportStore.save(r)
        }
        try? FileManager.default.removeItem(at: ReportStore.indexURL)
        tree = nil
        selection.subtract(doneIDs)
        withAnimation(.spring(duration: 0.8)) { volume = VolumeInfo.of() }
        lastResult = CleanResult(done: done, skipped: skipped, failed: failed, freed: after > before ? after - before : 0)
        phase = .idle
    }
}

/// Hands values from background threads to the main actor's polling loop.
final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var v: ScanProgress?
    var value: ScanProgress? {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

final class LogRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var v: String?
    var value: String? {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
