import CFastScan
import Foundation

public typealias NodeID = UInt32

public struct ScanOptions: Sendable {
    public var threads: Int = 0
    public var bigFileThreshold: UInt64 = 1 << 20
    public var wantPrivate = false
    public var collectShared = false
    public var noCollapse = false
    public init() {}
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
        if let hit = findRaw(std) { return hit }
        let data = Firmlinks.dataPath(std)
        return data == std ? nil : findRaw(data)
    }

    private func findRaw(_ target: String) -> NodeID? {
        for r in children(Self.root) {
            let rp = name(r)
            if target == rp { return r }
            let prefix = rp.hasSuffix("/") ? rp : rp + "/"
            guard target.hasPrefix(prefix) else { continue }
            var cur = r
            for comp in target.dropFirst(prefix.count).split(separator: "/") {
                let want = String(comp)
                guard let next = children(cur).first(where: { name($0) == want }) else { return nil }
                cur = next
            }
            return cur
        }
        return nil
    }

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

    // MARK: scanning

    /// Blocking scan. `progress` is called roughly every 100 ms from a helper thread.
    public static func scan(
        roots: [String], options: ScanOptions = ScanOptions(),
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) -> ScanTree? {
        var o = sm_scan_opts()
        o.threads = Int32(options.threads)
        o.big_file_threshold = options.bigFileThreshold
        o.want_private = options.wantPrivate
        o.collect_shared = options.collectShared
        o.no_collapse = options.noCollapse
        guard let scanner = sm_scanner_create(&o) else { return nil }
        defer { sm_scanner_free(scanner) }

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
        let tree = ptrs.withUnsafeBufferPointer { sm_scanner_run(scanner, $0.baseAddress, Int32(roots.count)) }
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
