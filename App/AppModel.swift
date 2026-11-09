import DiskIndex
import Foundation
import Observation
import OSLog
import Recognizers
import Reclaim
import SwiftUI

enum Section: String, CaseIterable, Identifiable, Hashable {
    case overview, project, media, devCache, model, apps, appData, disk, timeline
    var id: String { rawValue }

    var kind: ThingKind? {
        switch self {
        case .project: return .project
        case .media: return .media
        case .devCache: return .devCache
        case .model: return .model
        case .apps: return .app
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
        case .apps: return "macwindow"
        case .appData: return "square.stack.3d.up"
        case .disk: return "square.grid.3x3.square"
        case .timeline: return "chart.xyaxis.line"
        }
    }
}

/// What the window shows: a section about the startup disk, or an external disk.
enum Page: Hashable {
    case section(Section)
    /// An external disk, by volume UUID.
    case disk(String)
}

extension ThingKind {
    var color: Color {
        switch self {
        case .project: return .blue
        case .media: return .pink
        case .devCache: return .orange
        case .model: return .purple
        case .app: return .indigo
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

/// Whether the index follows the disk.
enum LiveState: Equatable {
    case off
    /// Replaying what changed while the app was not running.
    case catchingUp
    case live
}

/// One Clean Up run. The window shows it full size from the first item until it is closed.
@MainActor @Observable
final class CleanRun {
    enum State: Equatable {
        case waiting, running, done
        case skipped(String), failed(String)
        /// Stopped before its turn came.
        case notRun

        var message: String? {
            switch self {
            case .skipped(let m), .failed(let m): return m
            default: return nil
            }
        }
    }

    struct Row: Identifiable {
        let item: ReclaimItem
        let color: Color
        var state: State = .waiting
        var id: String { item.id }
    }

    var rows: [Row]
    /// The external disk being cleaned; nil is the startup disk.
    let diskName: String?
    /// What the plan expects to free.
    let estimate: UInt64
    let started = Date()
    /// Measured from the volume's free space, not estimated. It only grows, so other
    /// programs writing meanwhile don't make it jump back.
    private(set) var freed: UInt64 = 0
    /// The running item finishes; the rest don't start.
    var stopping = false
    private(set) var finishedAt: Date?

    init(items: [ReclaimItem], kinds: [String: ThingKind], diskName: String?) {
        rows = items.map { Row(item: $0, color: kinds[$0.id]?.color ?? .accentColor) }
        self.diskName = diskName
        estimate = items.reduce(0) { $0 + $1.estimate }
    }

    var finished: Bool { finishedAt != nil }
    var current: Row? { rows.first { $0.state == .running } }
    /// Items whose turn is over.
    var settled: Int { rows.count { $0.state != .waiting && $0.state != .running } }
    var done: Int { rows.count { $0.state == .done } }
    var skipped: Int { rows.count { if case .skipped = $0.state { true } else { false } } }
    var failed: Int { rows.count { if case .failed = $0.state { true } else { false } } }
    var notRun: Int { rows.count { $0.state == .notRun } }
    /// Done items that went to the Trash: that space comes back when the Trash is emptied.
    var trashed: UInt64 {
        rows.filter { $0.state == .done && $0.item.action.isTrashOnly }.reduce(0) { $0 + $1.item.estimate }
    }

    func measure(free now: UInt64, before: UInt64) {
        if now > before, now - before > freed { freed = now - before }
    }

    /// Demo mode: nothing is measured.
    func add(_ bytes: UInt64) { freed += bytes }

    func finish() {
        for i in rows.indices where rows[i].state == .waiting { rows[i].state = .notRun }
        finishedAt = Date()
    }
}

private let log = Logger(subsystem: "com.kadaliao.SuckMyDisk", category: "live")

@MainActor @Observable
final class AppModel {
    /// What the recognizers found, adjusted to the current index (see `refreshDerived`).
    var report: Report?
    var tree: ScanTree?
    /// Bumped whenever the index changes in place.
    var treeRevision = 0
    var volume = VolumeInfo.of()
    var selection: Set<String> = []
    var phase: Phase = .idle
    var page: Page = .section(.overview)
    /// The startup-disk section on screen; setting it shows that section.
    var section: Section {
        get { if case .section(let s) = page { return s } else { return .overview } }
        set { page = .section(newValue) }
    }
    /// Mounted external disks, each with its own scan and findings.
    var externals: [ExternalDisk] = []
    /// The disk Clean Up is about to work on; nil is the startup disk.
    var cleanDisk: ExternalDisk?
    /// External disk pages show the map instead of the list.
    var showDiskMap = false
    /// The Clean Up run on screen. It stays after the run ends, as the result, until closed.
    var cleanRun: CleanRun?
    var history: [ReportStore.DayPoint] = []
    /// Documents, Downloads, Pictures… minus the things already counted inside them.
    var userFiles: UInt64 = 0
    var applications: UInt64 = 0
    var confirming = false
    var scanStarted: Date?

    var liveState: LiveState = .off
    /// Without it, folders macOS guards with a consent dialog are left alone.
    var hasFullDiskAccess = Privacy.hasFullDiskAccess
    /// Recognizers are running in the background.
    var refreshing = false
    /// When the index last changed because files changed.
    var lastChange: Date?
    /// `--demo`: made-up data; nothing is read from or written to the disk.
    @ObservationIgnored private(set) var demo: DemoData?

    /// The last recognition result, as it was; `report` is derived from it.
    @ObservationIgnored private var baseReport: Report?
    /// Index sizes of each item / thing path when `baseReport` was made.
    @ObservationIgnored private var baseline: [String: UInt64] = [:]
    /// Boxes the user ticked or unticked themselves; kept across refreshes.
    @ObservationIgnored var userOn: Set<String> = []
    @ObservationIgnored var userOff: Set<String> = []
    @ObservationIgnored private var cleaned: (at: Date, ids: Set<String>)?

    @ObservationIgnored private var live: LiveIndex?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var wake: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var changedSinceRecognition: UInt64 = 0
    /// Size changes not shown yet: the UI redraws for a megabyte or more, or every 15 s.
    @ObservationIgnored private var unshownDelta: Int64 = 0
    @ObservationIgnored private var lastRedraw = Date()

    var things: [Thing] { report?.things ?? [] }

    func things(_ kind: ThingKind) -> [Thing] {
        things.filter { $0.kind == kind }.sorted { $0.reclaimable == $1.reclaimable ? $0.bytes > $1.bytes : $0.reclaimable > $1.reclaimable }
    }

    var plan: Planner.Plan { Planner.plan(things: things, selected: selection) }

    func plan(for disk: ExternalDisk) -> Planner.Plan { Planner.plan(things: disk.things, selected: selection) }

    /// What the Clean Up sheet shows and runs.
    var cleanPlan: Planner.Plan { cleanDisk.map(plan(for:)) ?? plan }

    func confirmCleanUp(_ disk: ExternalDisk? = nil) {
        cleanDisk = disk
        confirming = true
    }

    var currentDisk: ExternalDisk? {
        guard case .disk(let id) = page else { return nil }
        return externals.first { $0.id == id }
    }

    /// The toolbar's Rescan: the disk on screen.
    func rescanCurrent() async {
        if let d = currentDisk { await scan(d, interactive: true) } else { await rescan() }
    }

    /// Ticks: what the recognizers preselected plus the user's own choices, on every disk.
    func resetSelection() {
        let items = ((baseReport?.things ?? []) + externals.flatMap(\.things)).flatMap(\.items)
        let pre = Set(items.filter(\.preselected).map(\.id))
        selection = pre.union(userOn).subtracting(userOff).intersection(Set(items.map(\.id)))
    }

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
            self.history = ReportStore.history()
            guard let tree, LiveIndex.canResume(tree) else {
                log.notice("no resumable index (index: \(tree != nil, privacy: .public)); full scan")
                if let report { setReport(report, tree: nil) }
                await rescan()
                return
            }
            self.tree = tree
            if let report { setReport(report, tree: tree) }
            phase = .idle
            // Catch up on what changed while the app was closed; the loop recognizes afterwards.
            startLive(since: tree.eventID)
        }
        // Screenshot runs never read other disks.
        if !Privacy.alwaysSkip { watchExternalDisks() }
    }

    /// Shows made-up data instead of the disk. Rescans, saving and Clean Up are off.
    func startDemo() {
        let d = DemoData.make()
        demo = d
        volume = d.volume
        tree = d.tree
        history = d.history
        hasFullDiskAccess = true
        let disk = ExternalDisk(d.external.volume)
        disk.report = d.external.report
        disk.tree = d.external.tree
        externals = [disk]
        setReport(d.report, tree: d.tree)
        liveState = .live
        phase = .idle
    }

    func measureFolders() {
        if let demo {
            userFiles = demo.userFiles
            applications = demo.applications
            return
        }
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
    /// Apps are left out: uninstalling every app is not a decision anyone is waiting to make.
    var undecided: UInt64 {
        let all = things.filter { $0.kind != .app }.reduce(UInt64(0)) { $0 + $1.reclaimable }
        let chosen = Planner.plan(things: things.filter { $0.kind != .app }, selected: selection).freed
        return all > chosen ? all - chosen : 0
    }

    func rescan() async {
        guard demo == nil else { return }
        await stopLive()
        scanStarted = Date()
        phase = .scanning(files: 0, bytes: 0)
        let progress = ProgressRelay()
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                if case .scanning = phase, let p = progress.value { phase = .scanning(files: p.files, bytes: p.bytes) }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        // Changes made while scanning are replayed from here afterwards.
        let startID = DiskWatcher.currentEventID
        let tree = await Task.detached(priority: .userInitiated) {
            ScanTree.scan(roots: [Firmlinks.dataRoot], options: .respectingPrivacy()) { progress.value = $0 }
        }.value
        poll.cancel()
        guard let tree else { phase = .idle; return }
        LiveIndex.stamp(tree, startedAt: startID)
        await Task.detached(priority: .utility) { try? ReportStore.saveIndex(tree) }.value
        lastSave = Date()
        self.tree = tree
        treeRevision += 1
        await recognize(background: false)
        startLive(since: startID)
    }

    /// Runs the recognizers over the current index. Callers make sure nothing changes the tree meanwhile.
    private func recognize(background: Bool) async {
        guard let tree else { return }
        let started = Date()
        if background {
            refreshing = true
        } else {
            phase = .recognizing(L("正在识别项目、渲染帧和缓存…", "Recognizing projects, frames and caches…"))
        }
        let relay = LogRelay()
        let logPoll = Task { @MainActor in
            while !Task.isCancelled {
                if case .recognizing = phase, let m = relay.value { phase = .recognizing(m) }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        var report = await Recognize.all(tree: tree, skip: Privacy.rootsToSkip()) { relay.value = $0 }
        logPoll.cancel()
        // Items cleaned while this ran are gone, whatever the older index said.
        if let c = cleaned, c.at > started {
            for t in report.things.indices { report.things[t].items.removeAll { c.ids.contains($0.id) } }
        }
        let saved = report
        await Task.detached(priority: .utility) {
            ReportStore.save(saved)
            ReportStore.writeHistory(saved)
        }.value
        setReport(report, tree: tree)
        history = ReportStore.history()
        changedSinceRecognition = 0
        if background { refreshing = false } else { phase = .idle }
    }

    /// Takes a fresh recognition result and remembers the index sizes it was based on.
    private func setReport(_ r: Report, tree: ScanTree?) {
        baseReport = r
        baseline = [:]
        if let tree {
            for t in r.things {
                if let p = t.path, let n = tree.find(p) { baseline[t.id] = tree.size(n) }
                for i in t.items { if let p = i.path, let n = tree.find(p) { baseline[i.id] = tree.size(n) } }
            }
        }
        refreshDerived()
        resetSelection()
    }

    /// Brings sizes up to date from the index without running the recognizers:
    /// things that are gone disappear, things that grew or shrank show it.
    private func refreshDerived() {
        guard var r = baseReport else { report = nil; return }
        if let tree {
            r.things = r.things.compactMap { t in
                var t = t
                let hadItems = !t.items.isEmpty
                t.items = t.items.compactMap { item in
                    guard let p = item.path else { return item }
                    // Gone from the index: gone. An app outside the index (demo mode) was never in it.
                    guard let n = tree.find(p) else { return item.app != nil && baseline[item.id] == nil ? item : nil }
                    // An app's item counts its data too, not just the bundle at its path.
                    guard item.app == nil, let old = baseline[item.id], old > 0 else { return item }
                    let now = tree.size(n)
                    guard now != old else { return item }
                    var i = item
                    i.bytes = now
                    i.estimate = min(now, UInt64(Double(item.estimate) * Double(now) / Double(old)))
                    return i
                }
                if hadItems, t.items.isEmpty, t.kind != .system, t.kind != .appData { return nil }
                if let p = t.path, let old = baseline[t.id] {
                    guard let n = tree.find(p) else { return t.kind == .system || t.kind == .appData ? t : nil }
                    let now = tree.size(n)
                    t.bytes = now >= old ? t.bytes + (now - old) : t.bytes - min(t.bytes, old - now)
                }
                return t
            }
            r.scanned = tree.uniqueTotal
        }
        report = r
        let ids = Set((r.things + externals.flatMap(\.things)).flatMap(\.items).map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        measureFolders()
    }

    // MARK: live updates

    private func startLive(since: UInt64) {
        guard liveTask == nil, tree != nil else { return }
        let live = LiveIndex(since: since)
        live.skip = Privacy.rootsToSkip()
        hasFullDiskAccess = Privacy.hasFullDiskAccess
        let (stream, cont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        live.watcher.onEvents = { cont.yield() }
        guard live.watcher.start() else {
            log.error("FSEvents stream did not start")
            liveState = .off
            return
        }
        log.notice("following the disk from event \(since, privacy: .public)")
        self.live = live
        wake = cont
        cont.yield()
        liveState = since == 0 ? .live : .catchingUp
        liveTask = Task { [weak self] in
            await self?.liveLoop(live, stream)
        }
    }

    private func stopLive() async {
        guard let task = liveTask else { return }
        task.cancel()
        wake?.finish()
        await task.value
        live?.watcher.stop()
        live = nil
        liveTask = nil
        wake = nil
        liveState = .off
    }

    private func liveLoop(_ live: LiveIndex, _ stream: AsyncStream<Void>) async {
        // Wake up on events, and every half minute for put-off work and the volume numbers.
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                wake?.yield()
            }
        }
        defer { ticker.cancel() }
        var first = true
        for await _ in stream {
            if Task.isCancelled { break }
            // Let a burst of changes settle into one batch.
            if !first { try? await Task.sleep(for: .milliseconds(1200)) }
            first = false
            guard !Task.isCancelled, let tree, tree === self.tree else { break }
            await step(live, tree)
        }
    }

    private func step(_ live: LiveIndex, _ tree: ScanTree) async {
        let t0 = Date()
        let plan = await Task.detached(priority: .utility) { live.prepare(tree, mode: .live) }.value
        guard !Task.isCancelled, tree === self.tree else { return }
        if let why = plan.rescanAll {
            log.notice("full rescan: \(why, privacy: .public)")
            Task { await rescan() }
            return
        }
        let out = await Task.detached(priority: .utility) { live.perform(plan) }.value
        guard !Task.isCancelled, tree === self.tree else { return }
        if out.failed {
            Task { await rescan() }
            return
        }
        for x in out.slow {
            log.notice("slow folder: \(Fmt.home(Firmlinks.userPath(x.path)), privacy: .public) took \(x.seconds, format: .fixed(precision: 1), privacy: .public) s")
        }
        let s = live.apply(tree, out)
        if s.changed > 0 || !out.deferred.isEmpty {
            log.info("batch: \(plan.count) read, \(s.changed) changed, \(out.deferred.count) put off, Δ \(s.delta) B, \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(live.staleCount) stale")
        }
        if s.changed > 0 { dirty = true }
        if s.delta != 0 {
            lastChange = Date()
            changedSinceRecognition += s.delta.magnitude
            unshownDelta += s.delta
        }
        // Background churn (logs, caches) moves sizes by kilobytes all the time; redraw only when it shows.
        if unshownDelta.magnitude >= 1_000_000 || (unshownDelta != 0 && Date().timeIntervalSince(lastRedraw) > 15) {
            unshownDelta = 0
            lastRedraw = Date()
            treeRevision += 1
            refreshDerived()
        }
        // Access granted in System Settings: scan again to count what was left out.
        if !hasFullDiskAccess, Privacy.hasFullDiskAccess {
            hasFullDiskAccess = true
            log.notice("Full Disk Access granted; rescanning")
            Task { await rescan() }
            for d in externals { Task { await scan(d) } }
            return
        }
        let v = VolumeInfo.of()
        if v.free.distance(to: volume.free).magnitude >= 10_000_000 || v.total != volume.total {
            withAnimation(.spring(duration: 0.8)) { volume = v }
        }
        if liveState == .catchingUp, live.watcher.caughtUp, live.watcher.pendingCount == 0 {
            liveState = .live
            // Back after a while: recognize again with what changed meanwhile.
            if let r = baseReport {
                if Date().timeIntervalSince(r.createdAt) > 600 || changedSinceRecognition >= 50_000_000 {
                    await recognize(background: true)
                }
            } else {
                await recognize(background: false)
            }
        }
        await maybeRecognize()
        await maybeSave(tree)
    }

    /// Recognizers take seconds, so they run again only when enough has changed.
    private func maybeRecognize() async {
        guard liveState == .live, phase == .idle, let r = baseReport else { return }
        let age = Date().timeIntervalSince(r.createdAt)
        let quiet = lastChange.map { Date().timeIntervalSince($0) > 5 } ?? true
        if (changedSinceRecognition >= 1_000_000_000 && age > 120 && quiet) ||
            (changedSinceRecognition >= 50_000_000 && age > 1800) {
            await recognize(background: true)
        }
    }

    private func maybeSave(_ tree: ScanTree) async {
        guard dirty, Date().timeIntervalSince(lastSave) > 600 else { return }
        await Task.detached(priority: .utility) { try? ReportStore.saveIndex(tree) }.value
        lastSave = Date()
        dirty = false
    }

    /// Called when the app quits: the next launch catches up from here.
    func saveNow() {
        guard demo == nil, let tree, liveState != .off else { return }
        try? ReportStore.saveIndex(tree)
        dirty = false
    }

    // MARK: cleaning

    func toggle(_ item: ReclaimItem) {
        setSelected([item.id], !selection.contains(item.id))
    }

    func setSelected(_ ids: [String], _ on: Bool) {
        for id in ids {
            if on {
                selection.insert(id)
                userOn.insert(id)
                userOff.remove(id)
            } else {
                selection.remove(id)
                userOff.insert(id)
                userOn.remove(id)
            }
        }
    }

    func clean() async {
        let disk = cleanDisk
        let items = cleanPlan.items
        guard !items.isEmpty else { return }
        let kinds = Dictionary((disk?.things ?? things).flatMap { t in t.items.map { ($0.id, t.kind) } },
                               uniquingKeysWith: { a, _ in a })
        let run = CleanRun(items: items, kinds: kinds, diskName: disk?.volume.name)
        withAnimation(.smooth(duration: 0.45)) { cleanRun = run }
        // Demo items point at made-up paths and real tools: never hand them to the executor.
        if demo != nil { return await cleanDemo(run, disk: disk) }
        let mount = disk?.volume.path ?? Firmlinks.dataRoot
        let before = VolumeInfo.freeBytes(mount)
        // Twice a second, so the number grows while a big folder goes.
        let meter = Task { @MainActor in
            while !Task.isCancelled {
                run.measure(free: VolumeInfo.freeBytes(mount), before: before)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        var doneIDs: Set<String> = []
        let store = try? Store()
        let chosen = userOn   // ticked by hand, not preselected
        for (n, item) in items.enumerated() {
            if run.stopping { break }
            phase = .cleaning(current: item.label, done: n, total: items.count)
            run.rows[n].state = .running
            let outcome = await Task.detached(priority: .userInitiated) {
                Executor(store: store, chosen: chosen, log: { _ in }).run([item])[0]
            }.value
            switch outcome.status {
            case .done:
                run.rows[n].state = .done
                doneIDs.insert(item.id)
                doneIDs.formUnion(item.covers)
            case .skipped: run.rows[n].state = .skipped(outcome.message)
            case .failed: run.rows[n].state = .failed(outcome.message)
            }
        }
        meter.cancel()
        run.measure(free: VolumeInfo.freeBytes(mount), before: before)
        if let disk {
            // External disks are not followed live: drop what is gone, then scan again for the map.
            disk.drop(doneIDs, save: true)
            if !doneIDs.isEmpty { Task { await scan(disk) } }
        } else {
            // Drop what is gone at once; the index itself follows from FSEvents.
            cleaned = (Date(), doneIDs)
            if var r = baseReport {
                for t in r.things.indices { r.things[t].items.removeAll { doneIDs.contains($0.id) } }
                r.things.removeAll { $0.items.isEmpty && $0.kind != .system && $0.kind != .appData }
                baseReport = r
                ReportStore.save(r)
                refreshDerived()
            }
            withAnimation(.spring(duration: 0.8)) { volume = VolumeInfo.of() }
        }
        selection.subtract(doneIDs)
        userOn.subtract(doneIDs)
        withAnimation(.smooth(duration: 0.6)) { run.finish() }
        phase = .idle
        if disk == nil { wake?.yield() }
    }

    /// Back to the window from a finished run.
    func closeCleanRun() {
        guard cleanRun?.finished == true else { return }
        withAnimation(.smooth(duration: 0.4)) { cleanRun = nil }
    }
}

extension AppModel {
    /// Clean Up in demo mode: the items leave the lists and free space grows; nothing runs.
    private func cleanDemo(_ run: CleanRun, disk: ExternalDisk?) async {
        var ids: Set<String> = []
        for n in run.rows.indices {
            if run.stopping { break }
            let item = run.rows[n].item
            phase = .cleaning(current: item.label, done: n, total: run.rows.count)
            run.rows[n].state = .running
            // Slow enough to watch; bigger items take a little longer.
            try? await Task.sleep(for: .milliseconds(500 + Int(min(item.estimate / 20_000_000, 900))))
            run.rows[n].state = .done
            ids.insert(item.id)
            ids.formUnion(item.covers)
            // What goes to the Trash still takes space, as in a real run.
            if !item.action.isTrashOnly { run.add(item.estimate) }
        }
        let freed = run.freed
        if let disk {
            disk.drop(ids, save: false)
            withAnimation(.spring(duration: 0.8)) { disk.volume.free += freed }
        } else if var r = report {
            for t in r.things.indices { r.things[t].items.removeAll { ids.contains($0.id) } }
            r.things.removeAll { $0.items.isEmpty && $0.kind != .system && $0.kind != .appData }
            setReport(r, tree: tree)
            withAnimation(.spring(duration: 0.8)) { volume.free += freed }
        }
        selection.subtract(ids)
        withAnimation(.smooth(duration: 0.6)) { run.finish() }
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
