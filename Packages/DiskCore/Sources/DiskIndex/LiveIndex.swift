import CFastScan
import CoreServices
import Foundation

/// Watches the data volume with FSEvents and collects the directories that changed.
///
/// FSEvents reports directories (not files), with user-visible paths
/// (/Users/...); they are mapped back to data-volume paths here.
public final class DiskWatcher: @unchecked Sendable {
    public struct Batch: Sendable {
        /// Changed directories (data-volume paths) and their FSEvents flags.
        public var paths: [String: UInt32] = [:]
        /// The newest event id included.
        public var lastID: UInt64 = 0
        /// Events were lost or ids were reset: only a full rescan is correct.
        public var rescanAll: String?
        public var isEmpty: Bool { paths.isEmpty && rescanAll == nil }
    }

    private let lock = NSLock()
    private var pending = Batch()
    private var replayDone = false
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "SuckMyDisk.fsevents", qos: .utility)
    private let since: UInt64
    /// Called on a background queue after new events arrive.
    public var onEvents: (@Sendable () -> Void)?

    /// Starts from `since` (events after it are replayed first), or from now if 0.
    public init(since: UInt64) {
        self.since = since
        pending.lastID = since
    }

    deinit { stop() }

    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    public static var dataDevice: UInt32 {
        var st = stat()
        return stat(Firmlinks.dataRoot, &st) == 0 ? UInt32(bitPattern: st.st_dev) : 0
    }

    /// Identifies the FSEvents database of the data volume; event ids are only valid with the same UUID.
    public static func databaseUUID() -> UUID? {
        var st = stat()
        guard stat(Firmlinks.dataRoot, &st) == 0,
              let u = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        let b = CFUUIDGetUUIDBytes(u)
        return UUID(uuid: (b.byte0, b.byte1, b.byte2, b.byte3, b.byte4, b.byte5, b.byte6, b.byte7,
                           b.byte8, b.byte9, b.byte10, b.byte11, b.byte12, b.byte13, b.byte14, b.byte15))
    }

    /// True once events from before the start have all been delivered.
    public var caughtUp: Bool { lock.withLock { replayDone } }

    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let me = Unmanaged<DiskWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            me.receive(count: count, paths: list, flags: flags, ids: ids)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot |
                                             kFSEventStreamCreateFlagFullHistory)
        let from = since == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : since
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [Firmlinks.dataRoot] as CFArray, from, 1.0, flags) else {
            return false
        }
        if since == 0 { lock.withLock { replayDone = true } }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// Takes everything collected so far.
    public func drain() -> Batch {
        lock.withLock {
            let b = pending
            pending = Batch()
            pending.lastID = b.lastID
            return b
        }
    }

    /// Puts paths back that were not handled yet.
    public func requeue(_ paths: [String: UInt32]) {
        guard !paths.isEmpty else { return }
        lock.withLock {
            for (p, f) in paths { pending.paths[p, default: 0] |= f }
        }
    }

    public var pendingCount: Int { lock.withLock { pending.paths.count } }

    private func receive(count: Int, paths: NSArray, flags: UnsafePointer<FSEventStreamEventFlags>,
                         ids: UnsafePointer<FSEventStreamEventId>) {
        let dataRoot = Firmlinks.dataRoot
        lock.lock()
        for i in 0..<count {
            let f = flags[i]
            if ids[i] > pending.lastID { pending.lastID = ids[i] }
            if f & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { replayDone = true; continue }
            if f & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 { pending.rescanAll = "event ids wrapped"; continue }
            if f & UInt32(kFSEventStreamEventFlagRootChanged) != 0 { pending.rescanAll = "watched root changed"; continue }
            if f & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                pending.rescanAll = "events were dropped"
                continue
            }
            if f & UInt32(kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 { continue }
            guard var p = paths[i] as? String else { continue }
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            p = Firmlinks.dataPath(p)
            guard p == dataRoot || p.hasPrefix(dataRoot + "/") else { continue }
            pending.paths[p, default: 0] |= f
        }
        lock.unlock()
        onEvents?()
    }
}

/// Keeps a ScanTree in step with the disk: FSEvents batches become one-level
/// directory rescans, rescans of folded subtrees, and scans of new folders.
///
/// Each update has three steps so the tree is never read while it is changed:
/// `prepare` reads the tree, `perform` only touches the disk, `apply` changes the tree.
///
/// Work that is put off (a big folded subtree such as a Photos library, or a
/// busy folder relisted moments ago) marks its node SM_F_STALE. The flag is
/// saved with the index, so the event id can move on without losing it.
public final class LiveIndex: @unchecked Sendable {
    public enum Mode: Sendable {
        /// Running in the app: cooldowns spread the cost of busy and big folders over time.
        case live
        /// One-shot catch-up (command line): everything except big folded subtrees, now.
        case catchUp
    }

    public let watcher: DiskWatcher
    public let device: UInt32
    public let eventsUUID: UUID?
    /// Folded subtrees (node_modules, .git, ...) are rescanned at most this often.
    public var foldedCooldown: TimeInterval = 60
    /// A folder is relisted at most this often: the first change shows at once, a folder
    /// that apps rewrite every second (caches, logs) costs a fraction.
    public var dirCooldown: TimeInterval = 5
    /// Folders with more entries than this are relisted at most this often.
    public var largeDirCooldown: TimeInterval = 20
    public var largeDirEntries = 5_000
    /// Work that reads more files than this is "big" (a Photos library, a browser cache
    /// with 100k entries): never done during a catch-up, and in the app at most every
    /// `files / 250` seconds, so it costs about 1% of one core.
    public var bigFiles: UInt64 = 20_000

    /// Folders never read (see `Privacy`); set from `Privacy.rootsToSkip()`.
    public var skip: [String] = []

    private var lastRefresh: [NodeID: Date] = [:]
    /// Seconds the last read of a folder took, when it was slow.
    private var slowness: [NodeID: Double] = [:]
    private var stale: Set<NodeID> = []
    private var adopted = false

    public init(since: UInt64) {
        watcher = DiskWatcher(since: since)
        device = DiskWatcher.dataDevice
        eventsUUID = DiskWatcher.databaseUUID()
    }

    /// Whether `tree` can be caught up from FSEvents rather than rescanned.
    public static func canResume(_ tree: ScanTree) -> Bool {
        tree.eventID != 0 && tree.eventsUUID != nil && tree.eventsUUID == DiskWatcher.databaseUUID()
    }

    /// Nodes waiting for a deferred refresh.
    public var staleCount: Int { stale.count }

    func bigCooldown(_ files: UInt64, base: TimeInterval) -> TimeInterval {
        min(3600, max(base, Double(files) / 250))
    }

    // MARK: step 1: plan (reads the tree)

    struct Child { var ino: UInt64; var isDir: Bool }

    enum Work {
        case listing(node: NodeID, path: String, ino: UInt64, folded: UInt32, depth: Int, children: [String: Child])
        case rescan(node: NodeID, path: String, flags: UInt32, depth: Int)

        var node: NodeID {
            switch self {
            case .listing(let n, _, _, _, _, _), .rescan(let n, _, _, _): return n
            }
        }
    }

    public final class Plan: @unchecked Sendable {
        var work: [Work] = []
        /// Put off until later: marked stale.
        var deferred: [NodeID] = []
        public var rescanAll: String?
        public var lastID: UInt64 = 0
        public var isEmpty: Bool { work.isEmpty && deferred.isEmpty && rescanAll == nil }
        public var count: Int { work.count }
        /// What will be read: (path, whole subtree?) — for diagnostics.
        public var targets: [(path: String, subtree: Bool)] {
            work.map {
                switch $0 {
                case .listing(_, let p, _, _, _, _): return (p, false)
                case .rescan(_, let p, _, _): return (p, true)
                }
            }
        }
    }

    /// Drains the watcher and decides what to rescan now and what to put off.
    public func prepare(_ tree: ScanTree, mode: Mode = .live, now: Date = Date()) -> Plan {
        if !adopted {
            adopted = true
            for i in 1..<NodeID(tree.count) where tree.node(i).pointee.flags & (SM_F_STALE | SM_F_DETACHED) == SM_F_STALE {
                stale.insert(i)
            }
        }
        let batch = watcher.drain()
        let plan = Plan()
        plan.lastID = batch.lastID
        if let r = batch.rescanAll { plan.rescanAll = r; return plan }
        if batch.paths.count > 400_000 { plan.rescanAll = "too many changes (\(batch.paths.count))"; return plan }

        let mustScanSub = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        // node → (subtree rescan?, required by FSEvents?)
        var targets: [NodeID: (subtree: Bool, forced: Bool)] = [:]
        for (path, flags) in batch.paths {
            if !skip.isEmpty, Privacy.isInside(path, skip) { continue }
            guard let n = tree.nearest(path)?.node else { continue }
            let x = tree.node(n).pointee
            var target = n
            let forced = flags & mustScanSub != 0
            var subtree = forced
            if x.flags & UInt32(SM_F_MOUNTPOINT) != 0 { continue }
            if x.flags & UInt32(SM_F_COLLAPSED) != 0 {
                subtree = true
            } else if x.flags & UInt32(SM_F_DIR) == 0 {
                guard let p = tree.parent(n) else { continue }
                target = p
            }
            if subtree, tree.parent(target) == ScanTree.root || target == ScanTree.root {
                plan.rescanAll = "the whole volume needs a rescan"
                return plan
            }
            let have = targets[target]
            targets[target] = ((have?.subtree ?? false) || subtree, (have?.forced ?? false) || forced)
        }
        for s in stale where targets[s] == nil && !tree.isDetached(s) {
            targets[s] = (tree.node(s).pointee.flags & UInt32(SM_F_COLLAPSED) != 0, false)
        }

        // Now, or later?
        var due: [NodeID: Bool] = [:]
        for (node, t) in targets {
            let x = tree.node(node).pointee
            let whole = t.subtree || x.flags & UInt32(SM_F_COLLAPSED) != 0
            let cost = whole ? x.t_files : UInt64(x.nfiles)
            var base = whole ? foldedCooldown : (Int(x.nfiles) > largeDirEntries ? largeDirCooldown : dirCooldown)
            // A folder that took seconds to read waits a hundred times as long before the next read.
            if let slow = slowness[node] { base = min(3600, max(base, slow * 100)) }
            var later = false
            if t.forced {
                later = false
            } else if cost > bigFiles {
                if mode == .catchUp {
                    later = true
                } else if let last = lastRefresh[node] {
                    later = now.timeIntervalSince(last) < bigCooldown(cost, base: base)
                } else {
                    lastRefresh[node] = now   // start the clock; first refresh after one cooldown
                    later = true
                }
            } else if mode == .live, let last = lastRefresh[node] {
                later = now.timeIntervalSince(last) < base
            }
            if later {
                if !stale.contains(node) { plan.deferred.append(node) }
            } else {
                due[node] = t.subtree
            }
        }

        // A subtree rescan covers everything below it.
        let subtreeNodes = Set(due.filter { $0.value }.map(\.key))
        for (node, subtree) in due {
            var covered = false
            var cur = tree.parent(node)
            while let c = cur, c != ScanTree.root {
                if subtreeNodes.contains(c) { covered = true; break }
                cur = tree.parent(c)
            }
            if covered { stale.remove(node); continue }
            let x = tree.node(node).pointee
            let depth = tree.depth(node)
            let path = tree.rawPath(node)
            if !skip.isEmpty, Privacy.isInside(path, skip) { stale.remove(node); continue }
            let foldFlags = x.flags & UInt32(SM_F_COLLAPSED | SM_F_PACKAGE)
            if subtree {
                plan.work.append(.rescan(node: node, path: path, flags: foldFlags, depth: depth))
            } else {
                var kids: [String: Child] = [:]
                var c = x.first_child
                while c != SM_NONE {
                    let y = tree.node(c).pointee
                    if y.flags & UInt32(SM_F_DIR) != 0 { kids[tree.name(c)] = Child(ino: y.ino, isDir: true) }
                    c = y.next_sibling
                }
                plan.work.append(.listing(node: node, path: path, ino: x.ino, folded: foldFlags, depth: depth, children: kids))
            }
        }
        return plan
    }

    // MARK: step 2: read the disk (no tree access)

    final class Listing: @unchecked Sendable {
        var raw = sm_listing()
        var code: Int32 = 0
        var seconds = 0.0
        deinit { sm_listing_free(&raw) }
    }

    enum Result {
        case listing(node: NodeID, depth: Int, Listing, sources: [UInt32]?)
        case replace(node: NodeID, depth: Int, source: UInt32?)
        case gone(node: NodeID, depth: Int)
    }

    public final class Outcome: @unchecked Sendable {
        var results: [Result] = []
        var handled: [NodeID] = []
        public internal(set) var deferred: [NodeID] = []
        var src: ScanTree?
        public var lastID: UInt64 = 0
        public var listed = 0
        public var scannedRoots = 0
        /// The subtree scan could not run; nothing was applied and a full rescan is needed.
        public var failed = false
        /// Folders that took over a second to read (diagnostics).
        public var slow: [(path: String, seconds: Double)] = []
    }

    public func perform(_ plan: Plan) -> Outcome {
        let out = Outcome()
        out.lastID = plan.lastID
        out.deferred = plan.deferred
        out.handled = plan.work.map(\.node)
        let work = plan.work
        let dev = device

        // One-level listings, in parallel.
        let listings = (0..<work.count).map { _ in Listing() }
        DispatchQueue.concurrentPerform(iterations: work.count) { i in
            guard case .listing(_, let path, _, _, _, _) = work[i] else { return }
            let l = listings[i]
            let t0 = DispatchTime.now().uptimeNanoseconds
            l.code = sm_list_dir(path, dev, &l.raw)
            l.seconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        }
        out.listed = work.count

        // Everything that needs a full subtree scan, scanned in one run.
        var roots: [String] = []
        var rootFlags: [UInt32] = []
        var rootIndex: [String: Int] = [:]
        func addRoot(_ path: String, _ flags: UInt32) {
            if rootIndex[path] == nil {
                rootIndex[path] = roots.count
                roots.append(path)
                rootFlags.append(flags)
            }
        }
        enum Pending {
            case listing(NodeID, Int, Listing, [String?])
            case replace(NodeID, Int, String)
            case gone(NodeID, Int)
        }
        var pending: [Pending] = []
        for (i, w) in work.enumerated() {
            switch w {
            case .rescan(let node, let path, let flags, let depth):
                addRoot(path, flags)
                pending.append(.replace(node, depth, path))
            case .listing(let node, let path, let ino, let folded, let depth, let kids):
                if listings[i].seconds > 1 { out.slow.append((path, listings[i].seconds)) }
                let rc = listings[i].code
                if rc == ENOENT || rc == ENOTDIR || rc == ELOOP {
                    pending.append(.gone(node, depth))
                    continue
                }
                guard rc == 0 else { continue }   // denied, another device, ...
                let l = listings[i]
                if l.raw.ino != ino || l.raw.collapse_self {
                    // Replaced by another folder, or it turned out to be a venv: rescan it whole.
                    addRoot(path, l.raw.collapse_self ? UInt32(SM_F_COLLAPSED) | folded : folded)
                    pending.append(.replace(node, depth, path))
                    continue
                }
                var subRoots: [String?] = []
                for k in 0..<l.raw.nsubs {
                    let e = l.raw.subs[k]
                    let name = String(decoding: UnsafeRawBufferPointer(start: e.name, count: Int(e.name_len)), as: UTF8.self)
                    if e.flags & UInt32(SM_F_DATALESS) != 0 { subRoots.append(nil); continue }
                    if let old = kids[name], old.isDir, old.ino == e.ino { subRoots.append(nil); continue }
                    let p = path == "/" ? "/" + name : path + "/" + name
                    if !skip.isEmpty, Privacy.isInside(p, skip) { subRoots.append(nil); continue }
                    addRoot(p, e.flags & UInt32(SM_F_COLLAPSED | SM_F_PACKAGE))
                    subRoots.append(p)
                }
                pending.append(.listing(node, depth, l, subRoots))
            }
        }

        var srcNode: [String: UInt32] = [:]
        if !roots.isEmpty {
            var o = ScanOptions()
            o.background = true
            o.rootDevice = dev
            o.skip = skip
            o.threads = min(4, max(2, roots.count))
            guard let src = ScanTree.scan(roots: roots, rootFlags: rootFlags, options: o) else {
                out.failed = true
                return out
            }
            out.src = src
            for r in src.children(ScanTree.root) { srcNode[src.name(r)] = r }
            out.scannedRoots = roots.count
        }
        for p in pending {
            switch p {
            case .listing(let node, let depth, let l, let subRoots):
                let sources = subRoots.contains { $0 != nil } ? subRoots.map { $0.flatMap { srcNode[$0] } ?? SM_NONE } : nil
                out.results.append(.listing(node: node, depth: depth, l, sources: sources))
            case .replace(let node, let depth, let path):
                out.results.append(.replace(node: node, depth: depth, source: srcNode[path]))
            case .gone(let node, let depth):
                out.results.append(.gone(node: node, depth: depth))
            }
        }
        return out
    }

    // MARK: step 3: change the tree

    public struct Summary: Sendable {
        public var changed = 0
        /// Change in the scanned total, in bytes (signed).
        public var delta: Int64 = 0
    }

    public func apply(_ tree: ScanTree, _ out: Outcome, now: Date = Date()) -> Summary {
        var s = Summary()
        let before = tree.size(ScanTree.root)
        let results = out.results.sorted { depthOf($0) < depthOf($1) }
        let src = out.src
        for r in results {
            switch r {
            case .listing(let node, _, let l, let sources):
                guard !tree.isDetached(node) else { continue }
                if let sources {
                    sources.withUnsafeBufferPointer { sm_tree_apply_listing(tree.raw, node, &l.raw, src?.raw, $0.baseAddress) }
                } else {
                    sm_tree_apply_listing(tree.raw, node, &l.raw, nil, nil)
                }
                lastRefresh[node] = now
                if l.seconds > 0.5 { slowness[node] = l.seconds } else { slowness[node] = nil }
                s.changed += 1
            case .replace(let node, _, let source):
                guard !tree.isDetached(node), tree.parent(node) != ScanTree.root else { continue }
                if let source, let src {
                    sm_tree_replace(tree.raw, node, src.raw, source)
                    if tree.node(node).pointee.flags & UInt32(SM_F_COLLAPSED) != 0 { lastRefresh[node] = now }
                } else {
                    sm_tree_remove(tree.raw, node)
                }
                s.changed += 1
            case .gone(let node, _):
                guard !tree.isDetached(node), tree.parent(node) != ScanTree.root else { continue }
                sm_tree_remove(tree.raw, node)
                s.changed += 1
            }
        }
        for n in out.handled where !tree.isDetached(n) {
            tree.node(n).pointee.flags &= ~SM_F_STALE
        }
        stale.subtract(out.handled)
        for n in out.deferred where !tree.isDetached(n) {
            tree.node(n).pointee.flags |= SM_F_STALE
            stale.insert(n)
        }
        if stale.count > 1000 { stale = stale.filter { !tree.isDetached($0) } }
        if out.lastID > tree.eventID { tree.setEvents(id: out.lastID, uuid: eventsUUID) }
        tree.touch()
        s.delta = Int64(bitPattern: tree.size(ScanTree.root) &- before)
        if lastRefresh.count > 5_000 {
            // Short cooldowns are long over after a minute; big work keeps its clock for up to an hour.
            lastRefresh = lastRefresh.filter { node, t in
                let age = now.timeIntervalSince(t)
                guard age >= 60, !tree.isDetached(node) else { return age < 60 }
                let x = tree.node(node).pointee
                return (x.t_files > bigFiles || UInt64(x.nfiles) > bigFiles) && age < 3600
            }
        }
        return s
    }

    private func depthOf(_ r: Result) -> Int {
        switch r {
        case .listing(_, let d, _, _), .replace(_, let d, _), .gone(_, let d): return d
        }
    }

    /// Records where a fresh full scan starts, so events during the scan are replayed afterwards.
    public static func stamp(_ tree: ScanTree, startedAt eventID: UInt64) {
        tree.setEvents(id: eventID, uuid: DiskWatcher.databaseUUID())
    }

    // MARK: catching up (command line)

    public enum CatchUp {
        case current(changed: Int)
        case needsRescan(String)
    }

    /// Replays the events since the tree was saved and applies them, synchronously.
    public static func catchUp(_ tree: ScanTree, timeout: TimeInterval = 30) -> CatchUp {
        guard canResume(tree) else { return .needsRescan("the index has no usable event history") }
        let live = LiveIndex(since: tree.eventID)
        live.skip = Privacy.rootsToSkip()
        guard live.watcher.start() else { return .needsRescan("FSEvents could not start") }
        let deadline = Date().addingTimeInterval(timeout)
        while !live.watcher.caughtUp {
            if Date() > deadline { live.watcher.stop(); return .needsRescan("replaying events took too long") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        live.watcher.stop()
        var changed = 0
        while true {
            let plan = live.prepare(tree, mode: .catchUp)
            if let r = plan.rescanAll { return .needsRescan(r) }
            if plan.isEmpty {
                if plan.lastID > tree.eventID { tree.setEvents(id: plan.lastID, uuid: live.eventsUUID) }
                tree.touch()
                break
            }
            let out = live.perform(plan)
            if out.failed { return .needsRescan("a folder scan failed") }
            changed += live.apply(tree, out).changed
        }
        return .current(changed: changed)
    }
}
