import CFastScan
import Foundation

/// Answers "if I delete these roots, how much space really comes back?" for
/// trees that share data through APFS clones or hard links (uv cache + .venv,
/// pnpm store + node_modules, ...). A shared group is only freed when every
/// member of it is deleted.
public final class SharedAccounting: @unchecked Sendable {
    public let roots: [String]
    /// Own (unshared) bytes per root.
    public private(set) var ownBytes: [UInt64]
    /// Bytes per root that live in shared groups (as seen from that root).
    public private(set) var sharedBytes: [UInt64]

    private struct Group { var alloc: UInt64; var refs: UInt32; var start: Int32; var count: Int16 }
    private var groups: [Group] = []
    private var members: [(root: Int32, count: Int32)] = []

    public struct Freed: Sendable {
        public var own: UInt64        // unshared data in the deleted roots
        public var shared: UInt64     // shared groups whose members are all deleted
        public var trapped: UInt64    // shared data still referenced elsewhere
        public var total: UInt64 { own + shared }
    }

    public init?(roots: [String]) {
        self.roots = roots
        var o = ScanOptions()
        o.collectShared = true
        guard let tree = ScanTree.scan(roots: roots, options: o) else { return nil }
        let rootNodes = tree.children(ScanTree.root)
        var rootIndex: [NodeID: Int32] = [:]
        for r in rootNodes {
            if let idx = roots.firstIndex(of: tree.name(r)) { rootIndex[r] = Int32(idx) }
        }
        ownBytes = Array(repeating: 0, count: roots.count)
        sharedBytes = Array(repeating: 0, count: roots.count)
        for (r, idx) in rootIndex {
            ownBytes[Int(idx)] = tree.node(r).pointee.t_alloc
            sharedBytes[Int(idx)] = tree.node(r).pointee.t_shared
        }
        // Map every record's node to its root, then group by key.
        var nodeRoot: [NodeID: Int32] = [:]
        var recs: [(key: UInt64, ino: UInt64, alloc: UInt64, refs: UInt32, root: Int32)] = []
        recs.reserveCapacity(tree.sharedRecords.count)
        for r in tree.sharedRecords {
            let root: Int32
            if let c = nodeRoot[r.node] { root = c } else {
                root = rootIndex[tree.scanRoot(of: r.node)] ?? -1
                nodeRoot[r.node] = root
            }
            recs.append((r.key, r.ino, r.alloc, r.refs, root))
        }
        recs.sort { $0.key != $1.key ? $0.key < $1.key : $0.ino < $1.ino }
        let hlTag: UInt64 = 1 << 63
        var i = 0
        while i < recs.count {
            var j = i
            while j < recs.count, recs[j].key == recs[i].key { j += 1 }
            let isHardLink = recs[i].key & hlTag != 0
            var perRoot: [Int32: Int32] = [:]
            var lastIno: UInt64 = 0
            for k in i..<j {
                // Clones count distinct inodes; plain hard links count names.
                if !isHardLink, k > i, recs[k].ino == lastIno { continue }
                lastIno = recs[k].ino
                perRoot[recs[k].root, default: 0] += 1
            }
            let start = Int32(members.count)
            for (root, c) in perRoot { members.append((root, c)) }
            groups.append(Group(alloc: recs[i].alloc, refs: recs[i].refs, start: start, count: Int16(perRoot.count)))
            i = j
        }
    }

    public func freed(deleting rootIdx: Set<Int>) -> Freed {
        var f = Freed(own: 0, shared: 0, trapped: 0)
        for r in rootIdx where r < ownBytes.count { f.own += ownBytes[r] }
        for g in groups {
            var inSet: Int32 = 0
            var touched = false
            for m in members[Int(g.start)..<Int(g.start) + Int(g.count)] where rootIdx.contains(Int(m.root)) {
                inSet += m.count
                touched = true
            }
            guard touched else { continue }
            if g.refs > 0 && UInt32(inSet) >= g.refs { f.shared += g.alloc } else { f.trapped += g.alloc }
        }
        return f
    }
}
