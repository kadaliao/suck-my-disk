import CFastScan
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DiskIndex
@testable import Insights
@testable import Recognizers
@testable import Reclaim

/// A scratch folder on the data volume (APFS, so clones work).
final class Fixture {
    let root: String
    init(_ name: String = #function) throws {
        let base = NSTemporaryDirectory() + "smd-tests/" + UUID().uuidString.prefix(8)
        root = base + "/" + name.filter { $0.isLetter || $0.isNumber }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }

    func path(_ rel: String) -> String { root + "/" + rel }

    @discardableResult
    func file(_ rel: String, mb: Int = 0, text: String? = nil) throws -> String {
        let p = path(rel)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let text {
            try text.write(toFile: p, atomically: true, encoding: .utf8)
        } else {
            var bytes = [UInt8](repeating: 0, count: max(1, mb) << 20)
            for i in stride(from: 0, to: bytes.count, by: 4096) { bytes[i] = UInt8.random(in: 1...255) }
            FileManager.default.createFile(atPath: p, contents: Data(bytes))
        }
        return p
    }

    func clone(_ src: String, _ dst: String) throws {
        let d = path(dst)
        try FileManager.default.createDirectory(atPath: (d as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        #expect(clonefile(path(src), d, 0) == 0)
    }

    func hardlink(_ src: String, _ dst: String) throws {
        let d = path(dst)
        try FileManager.default.createDirectory(atPath: (d as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        #expect(link(path(src), d) == 0)
    }

    /// Makes everything look untouched for `days`.
    func age(days: Int) {
        let date = Date().addingTimeInterval(-Double(days) * 86400)
        let e = FileManager.default.enumerator(atPath: root)
        var all = [root]
        while let rel = e?.nextObject() as? String { all.append(root + "/" + rel) }
        for p in all.reversed() { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: p) }
    }

    func scan() -> ScanTree { ScanTree.scan(roots: [root])! }

    func png(_ rel: String, width: Int = 64, height: Int = 36, cameraMake: String? = nil) throws {
        let p = path(rel)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: .random(in: 0...1), green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let type = cameraMake == nil ? UTType.png : UTType.jpeg
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: p) as CFURL, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let cameraMake { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: cameraMake] }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }
}

@Suite struct ScannerTests {
    @Test func clonesAndHardLinksAreCountedOnce() throws {
        let f = try Fixture()
        try f.file("a.bin", mb: 4)
        try f.clone("a.bin", "b.bin")
        try f.clone("a.bin", "c.bin")
        try f.hardlink("a.bin", "hl.bin")
        try f.file("d.bin", mb: 2)
        let t = f.scan()
        let mb = 1 << 20
        // 4 MiB shared group counted once + 2 MiB unique file.
        #expect(t.uniqueTotal >= UInt64(6 * mb) && t.uniqueTotal < UInt64(6 * mb + 200_000))
        // Fair shares add up to the same total.
        let root = t.children(ScanTree.root)[0]
        let size = t.size(root)
        #expect(abs(Int64(size) - Int64(t.uniqueTotal)) < Int64(mb / 2))
    }

    @Test func dependencyTreesAreFoldedAndMarkersFound() throws {
        let f = try Fixture()
        try f.file("app/package.json", text: "{}")
        try f.file("app/pnpm-lock.yaml", text: "lock")
        for i in 0..<30 { try f.file("app/node_modules/pkg\(i)/lib/index.js", text: "x") }
        try f.file("app/node_modules/big/blob.bin", mb: 2)
        let t = f.scan()
        let app = try #require(t.find(f.path("app")))
        #expect(t.has(app, marker: SM_M_PACKAGE_JSON))
        #expect(t.has(app, marker: SM_M_LOCK_PNPM))
        let nm = try #require(t.find(f.path("app/node_modules")))
        #expect(t.has(nm, flag: SM_F_COLLAPSED))
        #expect(t.children(nm).isEmpty)
        #expect(t.size(nm) >= 2 << 20)
        #expect(t.node(nm).pointee.t_files == 31)
    }

    @Test func snapshotRoundTrip() throws {
        let f = try Fixture()
        try f.file("x/y/z.bin", mb: 2)
        let t = f.scan()
        let url = URL(fileURLWithPath: f.path("index.bin"))
        try t.save(to: url)
        let u = try ScanTree.load(from: url)
        #expect(u.count == t.count)
        #expect(u.uniqueTotal == t.uniqueTotal)
        #expect(u.find(f.path("x/y/z.bin")) != nil)
    }

    @Test func syntheticTreeFromFolderSizes() throws {
        let root = "/nonexistent/smd-demo"
        let t = try #require(ScanTree.synthetic(
            root: root,
            folders: [root + "/code/app/node_modules": 300, root + "/code/app": 50, root + "/Movies": 1000],
            folded: [root + "/code/app/node_modules"]))
        let app = try #require(t.find(root + "/code/app"))
        let nm = try #require(t.find(root + "/code/app/node_modules"))
        #expect(t.size(app) == 350)
        #expect(t.size(try #require(t.find(root))) == 1350)
        #expect(t.uniqueTotal == 1350)
        #expect(t.has(nm, flag: SM_F_COLLAPSED))
        #expect(!t.has(app, flag: SM_F_COLLAPSED))
        #expect(t.path(nm) == root + "/code/app/node_modules")
        #expect(t.sortedChildren(try #require(t.find(root))).map { t.name($0) } == ["Movies", "code"])
    }

    @Test func firmlinkPaths() {
        #expect(Firmlinks.userPath("/System/Volumes/Data/Users/a/b") == "/Users/a/b")
        #expect(Firmlinks.dataPath("/Users/a/b") == "/System/Volumes/Data/Users/a/b")
        #expect(Firmlinks.userPath("/System/Volumes/Data/.Spotlight-V100") == "/System/Volumes/Data/.Spotlight-V100")
    }
}

@Suite struct AccountingTests {
    @Test func cacheAndVenvFreeTogether() throws {
        let f = try Fixture()
        try f.file("cache/archive/w1.so", mb: 3)
        try f.file("cache/archive/only-cache.so", mb: 1)
        try f.clone("cache/archive/w1.so", "venv/lib/w1.so")
        try f.file("venv/lib/own.py", mb: 1)
        let acct = try #require(SharedAccounting(roots: [f.path("cache"), f.path("venv")]))
        let mb = UInt64(1 << 20)
        let cacheOnly = acct.freed(deleting: [0])
        #expect(cacheOnly.total >= mb && cacheOnly.total < 2 * mb)       // only the unshared file
        #expect(cacheOnly.trapped >= 3 * mb)
        let both = acct.freed(deleting: [0, 1])
        #expect(both.total >= 5 * mb && both.trapped == 0)
    }
}

@Suite struct RecognizerTests {
    func context(_ tree: ScanTree, sleep: Int = 30) -> RecognizeContext {
        var c = RecognizeContext(tree: tree, activity: ActivityIndex(), sleepAfterDays: sleep)
        c.allowAnyPath = true
        return c
    }

    @Test func projectArtifactsAndRestoreCommands() throws {
        let f = try Fixture()
        try f.file("proj/.git/HEAD", text: "ref")
        try f.file("proj/package.json", text: "{}")
        try f.file("proj/pnpm-lock.yaml", text: "lock")
        try f.file("proj/node_modules/x/big.bin", mb: 30)
        try f.file("proj/py/pyproject.toml", text: "[project]")
        try f.file("proj/py/uv.lock", text: "lock")
        try f.file("proj/py/.venv/pyvenv.cfg", text: "home = /usr/bin")
        try f.file("proj/py/.venv/lib/site.bin", mb: 30)
        try f.file("proj/rs/Cargo.toml", text: "[package]")
        try f.file("proj/rs/target/CACHEDIR.TAG", text: "Signature: 8a477f597d28d172789f06886806bc55")
        try f.file("proj/rs/target/debug/app", mb: 30)
        try f.file("proj/other/target/data.bin", mb: 30)   // not a Rust project: keep
        f.age(days: 120)
        let (things, venvs) = ProjectRecognizer.recognize(context(f.scan()))
        let p = try #require(things.first)
        let byKind = Dictionary(p.items.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byKind["node_modules"]?.restore == "pnpm install")
        #expect(byKind["venv"]?.restore == "uv sync")
        #expect(byKind["target"]?.restore == "cargo build")
        #expect(p.items.filter { $0.label == "target" }.count == 1)
        let allPre = p.items.allSatisfy { $0.preselected }
        #expect(allPre)
        #expect(venvs.count == 1)
    }

    @Test func activeProjectsAreNotPreselected() throws {
        let f = try Fixture()
        try f.file("proj/.git/HEAD", text: "ref")
        try f.file("proj/package.json", text: "{}")
        try f.file("proj/package-lock.json", text: "{}")
        try f.file("proj/node_modules/x/big.bin", mb: 30)
        let (things, _) = ProjectRecognizer.recognize(context(f.scan()))
        let anyPre = things.first?.items.contains { $0.preselected } ?? false
        #expect(!anyPre)
    }

    @Test func frameSequenceVersusCameraBurst() throws {
        let f = try Fixture()
        for i in 0..<320 { try f.png(String(format: "render/frames/%05d.png", i)) }
        #expect(FrameSequenceRecognizer.inspect(f.path("render/frames"))?.count == 320)
        for i in 0..<320 { try f.png(String(format: "photos/IMG_%04d.jpg", i), cameraMake: "Apple") }
        #expect(FrameSequenceRecognizer.inspect(f.path("photos")) == nil)
        for i in 0..<320 { try f.png(String(format: "comfy/ComfyUI_%05d_.png", i)) }
        #expect(FrameSequenceRecognizer.inspect(f.path("comfy")) == nil)
    }
}

@Suite struct SafetyTests {
    @Test func deniedLocations() {
        let h = NSHomeDirectory()
        #expect(Guards.isDenied(h + "/Library/Mobile Documents/com~apple~CloudDocs/a"))
        #expect(Guards.isDenied(h + "/Pictures/Photos Library.photoslibrary"))
        #expect(Guards.isDenied(h + "/workspace/x/.git"))
        #expect(Guards.isDenied(h))
        #expect(!Guards.isDenied(h + "/workspace/x/node_modules"))
    }

    @Test func coveredItemsAreNotCountedTwice() {
        var a = ReclaimItem(id: "a", label: "a", path: nil, bytes: 10, tier: .regenerable, action: .none, reason: "", preselected: true)
        let b = ReclaimItem(id: "b", label: "b", path: nil, bytes: 5, tier: .regenerable, action: .none, reason: "", preselected: true)
        a.covers = ["b"]
        let t = Thing(id: "t", kind: .devCache, title: "t", path: nil, bytes: 10, items: [a, b])
        #expect(t.reclaimable == 10)
        #expect(Planner.plan(things: [t], selected: nil).freed == 10)
    }

    @Test func executorRefusesProtectedAndTrackedPaths() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(atPath: f.path("repo"), withIntermediateDirectories: true)
        #expect(Shell.run(["git", "init", "-q", f.path("repo")]).ok)
        try f.file("repo/out/final.mp4", mb: 1)
        #expect(Shell.run(["git", "-C", f.path("repo"), "add", "out/final.mp4"]).ok)
        let item = ReclaimItem(id: "x", label: "out", path: f.path("repo/out"), bytes: 1, tier: .regenerable,
                               action: .delete(path: f.path("repo/out")), reason: "", preselected: true)
        let o = Executor(store: nil, force: true, log: { _ in }).run([item])[0]
        #expect(o.status == .skipped)
        #expect(FileManager.default.fileExists(atPath: f.path("repo/out/final.mp4")))

        // A broken repo must also block deletion.
        try f.file("broken/.git/HEAD", text: "garbage")
        try f.file("broken/out/x.bin", mb: 1)
        let item2 = ReclaimItem(id: "y", label: "out", path: f.path("broken/out"), bytes: 1, tier: .regenerable,
                                action: .delete(path: f.path("broken/out")), reason: "", preselected: true)
        #expect(Executor(store: nil, force: true, log: { _ in }).run([item2])[0].status == .skipped)

        // Untracked, old, regenerable: deleted, and the space is measured.
        try f.file("plain/node_modules/x.bin", mb: 2)
        let item3 = ReclaimItem(id: "z", label: "nm", path: f.path("plain/node_modules"), bytes: 1, tier: .regenerable,
                                action: .delete(path: f.path("plain/node_modules")), reason: "", preselected: true)
        #expect(Executor(store: nil, force: true, log: { _ in }).run([item3])[0].status == .done)
        #expect(!FileManager.default.fileExists(atPath: f.path("plain/node_modules")))
    }

    @Test func recentChangesNeedForce() throws {
        let f = try Fixture()
        try f.file("p/node_modules/x.bin", mb: 1)
        let item = ReclaimItem(id: "r", label: "nm", path: f.path("p/node_modules"), bytes: 1, tier: .regenerable,
                               action: .delete(path: f.path("p/node_modules")), reason: "", preselected: true)
        #expect(Executor(store: nil, force: false, log: { _ in }).run([item])[0].status == .skipped)
        #expect(FileManager.default.fileExists(atPath: f.path("p/node_modules")))
    }
}
