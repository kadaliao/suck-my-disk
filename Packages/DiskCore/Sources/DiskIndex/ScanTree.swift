import CFastScan
import Foundation

public typealias NodeID = UInt32

public struct ScanOptions: Sendable {
    public var threads: Int = 0
    public var bigFileThreshold: UInt64 = 1 << 20
    public var wantPrivate = false
    public var collectShared = false
    public var noCollapse = false
    /// Worker threads run at utility QoS (live updates).
    public var background = false
    /// If set, roots on another device become mount-point nodes instead of being scanned.
    public var rootDevice: UInt32 = 0
    /// Folders never opened (recorded as unreadable): see `Privacy`.
    public var skip: [String] = []
    public init() {}

    /// Default options that leave privacy-prompting folders alone without Full Disk Access.
    public static func respectingPrivacy() -> ScanOptions {
        var o = ScanOptions()
        o.skip = Privacy.rootsToSkip()
        return o
    }
}

/// Stops a running scan from another thread; the scan then returns nil.
public final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var scanner: OpaquePointer?
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.withLock {
            cancelled = true
            if let scanner { sm_scanner_cancel(scanner) }
        }
    }

    /// Returns false if the scan was cancelled before it started.
    fileprivate func attach(_ s: OpaquePointer?) -> Bool {
        lock.withLock {
            scanner = s
            return !cancelled
        }
    }
}

public struct ScanProgress: Sendable {
    public var files: UInt64
    public var dirs: UInt64
    public var bytes: UInt64
    public var denied: UInt64
}

/// The whole-disk (or targeted) size tree produced by the C scanner.
public final class ScanTree: @unchecked Sendable {
    let raw: OpaquePointer

    init(raw: OpaquePointer) { self.raw = raw }
    deinit { sm_tree_free(raw) }

    public static let root: NodeID = 0

    public var count: Int { Int(sm_tree_count(raw)) }

    public var stats: sm_tree_stats {
        var s = sm_tree_stats()
        sm_tree_get_stats(raw, &s)
        return s
    }

    @inline(__always)
    public func node(_ i: NodeID) -> UnsafeMutablePointer<sm_node> { sm_tree_node(raw, i) }

    public func name(_ i: NodeID) -> String {
        let n = node(i).pointee
        guard let p = n.name, n.name_len > 0 else { return "" }
        return p.withMemoryRebound(to: UInt8.self, capacity: Int(n.name_len)) {
            String(decoding: UnsafeBufferPointer(start: $0, count: Int(n.name_len)), as: UTF8.self)
        }
    }

    /// The path as users see it (/Users/... rather than /System/Volumes/Data/Users/...).
    public func path(_ i: NodeID) -> String { Firmlinks.userPath(rawPath(i)) }

    public func rawPath(_ i: NodeID) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let len = sm_tree_path(raw, i, &buf, buf.count)
        return buf.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: len) {
                String(decoding: UnsafeBufferPointer(start: $0, count: len), as: UTF8.self)
            }
        }
    }

    public func parent(_ i: NodeID) -> NodeID? {
        let p = node(i).pointee.parent
        return p == SM_NONE ? nil : p
    }

    public func children(_ i: NodeID) -> [NodeID] {
        var out: [NodeID] = []
        var c = node(i).pointee.first_child
        while c != SM_NONE {
            out.append(c)
            c = node(c).pointee.next_sibling
        }
        return out
    }

    /// Children sorted by occupied size, largest first.
    public func sortedChildren(_ i: NodeID) -> [NodeID] {
        children(i).sorted { size($0) > size($1) }
    }

    /// Occupied bytes; data shared by clones / hard links is split evenly across its members.
    public func size(_ i: NodeID) -> UInt64 {
        let n = node(i).pointee
        return n.t_alloc + n.t_shared
    }

    public func isDir(_ i: NodeID) -> Bool { node(i).pointee.flags & UInt32(SM_F_DIR) != 0 }
    /// Removed by a live update; such nodes are unreachable but keep their index.
    public func isDetached(_ i: NodeID) -> Bool { node(i).pointee.flags & SM_F_DETACHED != 0 }
    public func has(_ i: NodeID, flag: UInt32) -> Bool { node(i).pointee.flags & flag != 0 }
    public func has(_ i: NodeID, marker: UInt32) -> Bool { node(i).pointee.markers & marker != 0 }

    public func newest(_ i: NodeID) -> Date? {
        let t = node(i).pointee.t_newest
        return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
    }

    /// Total for the whole tree with shared data counted once.
    public var uniqueTotal: UInt64 { node(Self.root).pointee.t_alloc + stats.shared_unique }

    /// Finds the node for an absolute path, if the path lies inside a scan root.
    public func find(_ path: String) -> NodeID? {
        let std = (path as NSString).standardizingPath
        if let hit = nearest(std), hit.exact { return hit.node }
        let data = Firmlinks.dataPath(std)
        guard data != std, let hit = nearest(data), hit.exact else { return nil }
        return hit.node
    }

    /// The deepest node on a raw (data-volume) path, and whether it is the path itself.
    public func nearest(_ rawPath: String) -> (node: NodeID, exact: Bool)? {
        var exact = false
        var p = rawPath
        let n = p.withUTF8 { b in
            b.withMemoryRebound(to: CChar.self) { sm_tree_find(raw, $0.baseAddress, b.count, &exact) }
        }
        return n == SM_NONE ? nil : (n, exact)
    }

    public func depth(_ i: NodeID) -> Int {
        var d = 0
        var cur = i
        while let p = parent(cur) { d += 1; cur = p }
        return d
    }

    // MARK: live-update state

    /// The FSEvents id this tree is current up to (0: unknown, e.g. an older index).
    public var eventID: UInt64 { stats.event_id }

    public var eventsUUID: UUID? {
        var s = stats
        let u = withUnsafeBytes(of: &s.events_uuid) { UUID(uuid: $0.load(as: uuid_t.self)) }
        return u == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) ? nil : u
    }

    public func setEvents(id: UInt64, uuid: UUID?) {
        var bytes = (uuid ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))).uuid
        withUnsafeBytes(of: &bytes) { sm_tree_set_events(raw, id, $0.bindMemory(to: UInt8.self).baseAddress) }
    }

    /// Records that the tree matches the disk as of now.
    public func touch() { sm_tree_touch(raw) }

    /// Nodes left unreachable by live updates (dropped when the tree is saved).
    public var detachedCount: UInt64 { stats.detached }

    /// When the tree last matched the disk.
    public var updatedAt: Date { Date(timeIntervalSince1970: stats.created_at) }

    /// Depth-first walk. Return false from the visitor to skip a node's children.
    public func walk(from start: NodeID, _ visit: (NodeID) -> Bool) {
        var stack: [NodeID] = [start]
        while let i = stack.popLast() {
            guard visit(i) else { continue }
            var c = node(i).pointee.first_child
            while c != SM_NONE {
                stack.append(c)
                c = node(c).pointee.next_sibling
            }
        }
    }

    public var sharedRecords: UnsafeBufferPointer<sm_shared_rec> {
        UnsafeBufferPointer(start: sm_tree_shared(raw), count: sm_tree_shared_count(raw))
    }

    /// The scan root (depth-1 node) that contains `i`.
    public func scanRoot(of i: NodeID) -> NodeID {
        var cur = i
        while let p = parent(cur), p != Self.root { cur = p }
        return cur
    }

    // MARK: persistence

    public func save(to url: URL) throws {
        let rc = sm_tree_save(raw, url.path)
        if rc != 0 { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO) }
    }

    public static func load(from url: URL) throws -> ScanTree {
        var out: OpaquePointer?
        let rc = sm_tree_load(url.path, &out)
        guard rc == 0, let out else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO) }
        return ScanTree(raw: out)
    }

    // MARK: synthetic trees

    /// A tree made from folder sizes instead of a scan; nothing is read from disk.
    /// Used for the app's demo mode and for tests.
    ///
    /// `folders` maps absolute paths inside `root` to the bytes held directly in each
    /// folder; missing parent folders are created. Folders in `folded` are one block,
    /// like `node_modules` in a real scan.
    public static func synthetic(root: String, folders: [String: UInt64], folded: Set<String> = [],
                                 modified: Date = Date()) -> ScanTree? {
        let root = (root as NSString).standardizingPath
        var own: [String: UInt64] = [root: 0]
        var kids: [String: Set<String>] = [:]
        for (path, bytes) in folders {
            var p = (path as NSString).standardizingPath
            guard p.hasPrefix(root + "/") else { continue }
            own[p, default: 0] += bytes
            while p != root {
                let parent = (p as NSString).deletingLastPathComponent
                kids[parent, default: []].insert((p as NSString).lastPathComponent)
                if own[parent] == nil { own[parent] = 0 }
                p = parent
            }
        }
        guard let raw = root.withCString({ r -> OpaquePointer? in
            var roots: [UnsafePointer<CChar>?] = [r]
            return sm_tree_create(&roots, 1)
        }) else { return nil }
        let tree = ScanTree(raw: raw)
        let mtime = Int64(modified.timeIntervalSince1970)
        var ino: UInt64 = 1
        var queue = [root]
        while let dir = queue.popLast() {
            guard let hit = tree.nearest(dir), hit.exact else { continue }
            let names = (kids[dir] ?? []).sorted()
            let cnames = names.map { strdup($0)! }
            defer { cnames.forEach { free($0) } }
            var subs = zip(names, cnames).map { name, c in
                ino += 1
                var e = sm_entry()
                e.name = UnsafePointer(c)
                e.name_len = UInt32(name.utf8.count)
                e.flags = UInt32(SM_F_DIR) | (folded.contains(dir + "/" + name) ? SM_F_COLLAPSED : 0)
                e.ino = ino
                e.mtime = mtime
                return e
            }
            let bytes = own[dir] ?? 0
            var l = sm_listing()
            l.ino = ino
            l.self_mtime = mtime
            l.alloc = bytes
            l.logical = bytes
            l.nfiles = bytes > 0 ? 1 : 0
            l.mtime = mtime
            subs.withUnsafeMutableBufferPointer { b in
                l.subs = b.baseAddress
                l.nsubs = b.count
                sm_tree_apply_listing(raw, hit.node, &l, nil, nil)
            }
            queue += names.map { dir + "/" + $0 }
        }
        return tree
    }

    // MARK: scanning

    /// Blocking scan. `progress` is called roughly every 100 ms from a helper thread.
    /// `rootFlags[i]` may hold SM_F_COLLAPSED / SM_F_PACKAGE to scan that root folded.
    public static func scan(
        roots: [String], rootFlags: [UInt32]? = nil, options: ScanOptions = ScanOptions(),
        cancellation: ScanCancellation? = nil, progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) -> ScanTree? {
        var o = sm_scan_opts()
        o.threads = Int32(options.threads)
        o.big_file_threshold = options.bigFileThreshold
        o.want_private = options.wantPrivate
        o.collect_shared = options.collectShared
        o.no_collapse = options.noCollapse
        o.background = options.background
        o.root_dev = options.rootDevice
        let skip = options.skip.map { strdup($0) }
        defer { skip.forEach { free($0) } }
        let skipPtrs: [UnsafePointer<CChar>?] = skip.map { UnsafePointer($0) }
        return skipPtrs.withUnsafeBufferPointer { sp in
            o.skip = sp.isEmpty ? nil : sp.baseAddress
            o.nskip = Int32(sp.count)
            return run(o, roots: roots, rootFlags: rootFlags, cancellation: cancellation, progress: progress)
        }
    }

    private static func run(
        _ opts: sm_scan_opts, roots: [String], rootFlags: [UInt32]?, cancellation: ScanCancellation?,
        progress: (@Sendable (ScanProgress) -> Void)?
    ) -> ScanTree? {
        var o = opts
        guard let scanner = sm_scanner_create(&o) else { return nil }
        defer {
            _ = cancellation?.attach(nil)
            sm_scanner_free(scanner)
        }
        if let cancellation, !cancellation.attach(scanner) { return nil }

        let box = ScannerBox(scanner)
        let done = DoneFlag()
        var monitor: Thread?
        if let progress {
            monitor = Thread {
                while !done.value {
                    var p = sm_progress()
                    sm_scanner_progress(box.ptr, &p)
                    progress(ScanProgress(files: p.files, dirs: p.dirs, bytes: p.bytes, denied: p.denied))
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            monitor?.start()
        }
        let cstrs = roots.map { strdup($0) }
        defer { cstrs.forEach { free($0) } }
        let ptrs: [UnsafePointer<CChar>?] = cstrs.map { UnsafePointer($0) }
        let tree = ptrs.withUnsafeBufferPointer { p in
            if let rootFlags {
                rootFlags.withUnsafeBufferPointer { sm_scanner_run_ex(scanner, p.baseAddress, $0.baseAddress, Int32(roots.count)) }
            } else {
                sm_scanner_run(scanner, p.baseAddress, Int32(roots.count))
            }
        }
        done.value = true
        return tree.map { ScanTree(raw: $0) }
    }
}

private final class ScannerBox: @unchecked Sendable {
    let ptr: OpaquePointer
    init(_ p: OpaquePointer) { ptr = p }
}

final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

public extension sm_node {
    var isDir: Bool { flags & UInt32(SM_F_DIR) != 0 }
}
