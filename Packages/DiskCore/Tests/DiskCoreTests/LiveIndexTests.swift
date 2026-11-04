import CFastScan
import Foundation
import Testing
@testable import DiskIndex

/// Every reachable node by path (relative to the scan root) with all its values.
private func signature(_ t: ScanTree) -> [String: String] {
    var out: [String: String] = [:]
    let root = t.children(ScanTree.root)[0]
    let rootPath = t.rawPath(root)
    t.walk(from: root) { i in
        let n = t.node(i).pointee
        let rel = String(t.rawPath(i).dropFirst(rootPath.count))
        out[rel.isEmpty ? "/" : rel] = "f=\(n.flags) m=\(n.markers) own=\(n.alloc)/\(n.shared)/\(n.logical)/\(n.nfiles) "
            + "img=\(n.img_count)/\(n.img_bytes) av=\(n.vid_bytes)/\(n.aud_bytes)/\(n.model_bytes) "
            + "t=\(n.t_alloc)/\(n.t_shared)/\(n.t_logical)/\(n.t_files) mt=\(n.mtime) new=\(n.t_newest) ino=\(n.ino)"
        return true
    }
    return out
}

private func expectSame(_ a: ScanTree, _ b: ScanTree) {
    let sa = signature(a), sb = signature(b)
    for k in Set(sa.keys).union(sb.keys).sorted() where sa[k] != sb[k] {
        Issue.record("\(k)\n  live:  \(sa[k] ?? "missing")\n  fresh: \(sb[k] ?? "missing")")
    }
    #expect(a.size(ScanTree.root) == b.size(ScanTree.root))
}

/// The fixture root as the data-volume path FSEvents reports (/System/Volumes/Data/private/var/...).
private func dataRoot(_ f: Fixture) -> String {
    // Not URL.resolvingSymlinksInPath: it strips /private again.
    guard let real = realpath(f.root, nil) else { return f.root }
    defer { free(real) }
    return Firmlinks.dataPath(String(cString: real))
}

private func scan(_ root: String) -> ScanTree { ScanTree.scan(roots: [root])! }

private func update(_ tree: ScanTree, _ live: LiveIndex, root: String, _ rels: [String]) -> LiveIndex.Summary {
    live.watcher.requeue(Dictionary(uniqueKeysWithValues: rels.map { (root + ($0.isEmpty ? "" : "/" + $0), UInt32(0)) }))
    let plan = live.prepare(tree, mode: .catchUp)
    #expect(plan.rescanAll == nil)
    let out = live.perform(plan)
    #expect(!out.failed)
    return live.apply(tree, out)
}

private func write(_ path: String, mb: Int = 0, text: String = "x") throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if mb > 0 {
        var bytes = [UInt8](repeating: 0, count: mb << 20)
        for i in stride(from: 0, to: bytes.count, by: 4096) { bytes[i] = UInt8.random(in: 1...255) }
        FileManager.default.createFile(atPath: path, contents: Data(bytes))
    } else {
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }
}

@Suite(.serialized) struct LiveIndexTests {
    @Test func patchedTreeMatchesAFreshScan() throws {
        let f = try Fixture()
        let r = dataRoot(f)
        let fm = FileManager.default
        try write(r + "/a/small.txt")
        try write(r + "/a/big.bin", mb: 2)
        try write(r + "/a/sub/x.txt")
        try write(r + "/a/sub/deeper/y.bin", mb: 2)
        try write(r + "/proj/package.json", text: "{}")
        try write(r + "/proj/package-lock.json", text: "{}")
        try write(r + "/proj/node_modules/lib/index.js")
        try write(r + "/proj/node_modules/lib/big.bin", mb: 2)
        try write(r + "/gone/z.txt")
        try write(r + "/repl/old.bin", mb: 2)
        try write(r + "/ren/r.txt")
        try write(r + "/v/lib/x.py")
        try write(r + "/中文 目录/e\u{301}.txt")

        let tree = scan(r)
        let live = LiveIndex(since: 0)

        try write(r + "/a/new.txt")
        try fm.removeItem(atPath: r + "/a/big.bin")
        try write(r + "/a/big2.bin", mb: 3)
        try fm.removeItem(atPath: r + "/a/sub/deeper")
        try write(r + "/proj/node_modules/lib/extra.bin", mb: 2)
        try fm.removeItem(atPath: r + "/gone")
        try fm.removeItem(atPath: r + "/repl")
        try write(r + "/repl/new.bin", mb: 2)
        try fm.moveItem(atPath: r + "/ren", toPath: r + "/ren2")
        try write(r + "/newdir/n1/n2/f.bin", mb: 2)
        try write(r + "/newdir/node_modules/m/i.js")
        try write(r + "/v/pyvenv.cfg", text: "home = /usr/bin")
        try write(r + "/中文 目录/e\u{301}.txt", text: "longer text now")

        // What FSEvents would report: every directory whose entries changed, including removed ones.
        let s = update(tree, live, root: r, ["", "a", "a/sub", "a/sub/deeper", "proj/node_modules/lib", "gone",
                                            "repl", "ren", "ren2", "newdir/n1/n2", "v", "中文 目录"])
        #expect(s.changed > 0)
        #expect(tree.detachedCount > 0)
        expectSame(tree, scan(r))
    }

    @Test func savedPatchedTreeKeepsGrowing() throws {
        let f = try Fixture()
        let r = dataRoot(f)
        for i in 0..<50 { try write(r + "/d\(i)/f.txt") }
        try write(r + "/keep/big.bin", mb: 2)
        let tree = scan(r)
        let live = LiveIndex(since: 0)
        try FileManager.default.removeItem(atPath: r + "/d3")
        try write(r + "/added/x.bin", mb: 2)
        _ = update(tree, live, root: r, ["", "d3"])
        tree.setEvents(id: 42, uuid: UUID())

        let url = URL(fileURLWithPath: f.root + "/../index.bin")
        try tree.save(to: url)
        let loaded = try ScanTree.load(from: url)
        #expect(loaded.detachedCount == 0)
        #expect(loaded.eventID == 42)
        #expect(loaded.eventsUUID == tree.eventsUUID)
        expectSame(loaded, tree)

        // The loaded tree must accept new nodes past its last loaded chunk.
        for i in 0..<30 { try write(r + "/more\(i)/sub/f.bin", mb: 1) }
        try FileManager.default.removeItem(atPath: r + "/keep")
        _ = update(loaded, live, root: r, ["", "keep"])
        expectSame(loaded, scan(r))
    }

    @Test func bigFoldedFoldersWaitTheirTurn() throws {
        let f = try Fixture()
        let r = dataRoot(f)
        try write(r + "/app/package.json", text: "{}")
        for i in 0..<12 { try write(r + "/app/node_modules/m\(i)/i.js") }
        try write(r + "/small/node_modules/x/i.js")
        let tree = scan(r)
        let live = LiveIndex(since: 0)
        live.bigFiles = 5
        live.foldedCooldown = 0

        try write(r + "/app/node_modules/m0/extra.bin", mb: 2)
        try write(r + "/small/node_modules/x/extra.bin", mb: 2)
        _ = update(tree, live, root: r, ["app/node_modules/m0", "small/node_modules/x"])
        let big = try #require(tree.find(r + "/app/node_modules"))
        let small = try #require(tree.find(r + "/small/node_modules"))
        #expect(tree.node(big).pointee.flags & SM_F_STALE != 0)
        #expect(tree.node(small).pointee.flags & SM_F_STALE == 0)
        #expect(tree.size(small) > 2_000_000)
        #expect(tree.size(big) < 1_000_000)
        #expect(live.staleCount == 1)

        // The flag survives a save, so the event id may move on.
        let url = URL(fileURLWithPath: f.root + "/../stale.bin")
        try tree.save(to: url)
        let loaded = try ScanTree.load(from: url)
        let big2 = try #require(loaded.find(r + "/app/node_modules"))
        #expect(loaded.node(big2).pointee.flags & SM_F_STALE != 0)

        // In the app, the first sighting starts the clock; once it runs out, the folder is rescanned.
        let app = LiveIndex(since: 0)
        app.bigFiles = 5
        app.foldedCooldown = 0
        var plan = app.prepare(loaded, mode: .live)
        #expect(plan.count == 0)
        _ = app.apply(loaded, app.perform(plan))
        Thread.sleep(forTimeInterval: 0.1)
        plan = app.prepare(loaded, mode: .live)
        #expect(plan.count == 1)
        _ = app.apply(loaded, app.perform(plan))
        #expect(app.staleCount == 0)
        expectSame(loaded, scan(r))
    }

    @Test func privacyPromptingFoldersAreNeverOpened() throws {
        let f = try Fixture()
        let r = dataRoot(f)
        try write(r + "/Downloads/a.bin", mb: 2)
        try write(r + "/ok/b.txt")
        var o = ScanOptions()
        o.skip = [r + "/Downloads"]
        let tree = ScanTree.scan(roots: [r], options: o)!
        let dl = try #require(tree.find(r + "/Downloads"))
        #expect(tree.node(dl).pointee.flags & SM_F_DENIED != 0)
        #expect(tree.size(dl) == 0)

        let live = LiveIndex(since: 0)
        live.skip = [r + "/Downloads", r + "/Later"]
        try write(r + "/Downloads/c.bin", mb: 2)
        try write(r + "/Later/d.bin", mb: 2)
        try write(r + "/ok/e.bin", mb: 2)
        _ = update(tree, live, root: r, ["", "Downloads", "Later", "ok"])
        #expect(tree.size(dl) == 0)
        #expect(tree.find(r + "/Later").map { tree.size($0) } == 0)
        #expect(tree.find(r + "/ok").map { tree.size($0) } ?? 0 > 2_000_000)
    }

    @Test func fsEventsDriveTheUpdate() async throws {
        let f = try Fixture()
        let r = dataRoot(f)
        try write(r + "/one/a.txt")
        try write(r + "/two/b.bin", mb: 2)
        let tree = scan(r)
        let live = LiveIndex(since: 0)
        #expect(live.watcher.start())
        defer { live.watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try write(r + "/one/new.bin", mb: 2)
        try FileManager.default.removeItem(atPath: r + "/two")
        try write(r + "/three/deep/c.bin", mb: 2)

        // FSEvents latency is one second; wait for our folders to show up.
        var plan: LiveIndex.Plan?
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            if live.watcher.pendingCount > 0 {
                let p = live.prepare(tree, mode: .catchUp)
                if p.count > 0 { plan = p; break }
            }
        }
        let p = try #require(plan)
        _ = live.apply(tree, live.perform(p))
        // Late events for the same changes are harmless: apply whatever else arrives.
        try await Task.sleep(for: .milliseconds(1500))
        _ = live.apply(tree, live.perform(live.prepare(tree, mode: .catchUp)))
        expectSame(tree, scan(r))
        #expect(tree.eventID > 0)
    }
}
