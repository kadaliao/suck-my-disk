import AVFoundation
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

    /// `count` numbered PNG frames of 170 KB each, so 300 of them pass the 50 MB bar.
    func frames(_ dir: String, count: Int) throws {
        let ctx = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(ctx.bytesPerRow * 180) { px[i] = .random(in: 0...255) }   // noise doesn't compress
        let png = NSMutableData()
        let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        try FileManager.default.createDirectory(atPath: path(dir), withIntermediateDirectories: true)
        for i in 0..<count { FileManager.default.createFile(atPath: path(dir + String(format: "/%05d.png", i)), contents: png as Data) }
    }

    /// An H.264 video with exactly `frames` frames at `fps`.
    func video(_ rel: String, frames: Int, fps: Int32 = 24) async throws {
        let p = path(rel)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let w = try AVAssetWriter(outputURL: URL(fileURLWithPath: p), fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 36,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 36,
        ])
        w.add(input)
        #expect(w.startWriting())
        w.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buf)
            #expect(adaptor.append(buf!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)))
        }
        input.markAsFinished()
        w.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
        await w.finishWriting()
        #expect(w.status == .completed, "\(String(describing: w.error))")
    }

    /// Starts a program whose command line names `rel`, like an MCP server npx runs. Stop it with terminate().
    func runningProgram(using rel: String) throws -> Process {
        try file(rel, text: "")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        p.arguments = ["-f", path(rel)]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        return p
    }
}

@Suite struct ScannerTests {
    /// Ejecting a disk cancels its scan, so the scan must stop and return nothing.
    @Test func scansCanBeCancelled() throws {
        let f = try Fixture()
        try f.file("a/b.bin", mb: 2)
        let stop = ScanCancellation()
        #expect(ScanTree.scan(roots: [f.root], cancellation: ScanCancellation()) != nil)
        stop.cancel()
        #expect(ScanTree.scan(roots: [f.root], cancellation: stop) == nil)
    }

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

    /// An external disk: projects anywhere on it, but not in its top-level dot folders
    /// (.vscode-server moved off the home folder is full of package.json + node_modules).
    @Test func externalDiskProjects() async throws {
        let f = try Fixture()
        try f.file("package.json", text: "{}")   // the disk itself is not a project
        try f.file("work/proj/.git/HEAD", text: "ref")
        try f.file("work/proj/package.json", text: "{}")
        try f.file("work/proj/package-lock.json", text: "{}")
        try f.file("work/proj/node_modules/x/big.bin", mb: 30)
        try f.file(".vscode-server/extensions/ext/package.json", text: "{}")
        try f.file(".vscode-server/extensions/ext/package-lock.json", text: "{}")
        try f.file(".vscode-server/extensions/ext/node_modules/y/big.bin", mb: 30)
        try f.file("Offload/bun/install/global/package.json", text: "{}")
        try f.file("Offload/bun/install/global/bun.lock", text: "{}")
        try f.file("Offload/bun/install/global/node_modules/z/big.bin", mb: 30)
        f.age(days: 120)
        let disk = ExternalVolume(name: "Test", path: f.root, uuid: "test", total: 0, free: 0)
        let report = await Recognize.external(tree: f.scan(), volume: disk)
        let projects = report.things.filter { $0.kind == .project }
        #expect(projects.map(\.path) == [f.path("work/proj")])
        #expect(projects.first?.items.first?.preselected == true)
        #expect(report.things.allSatisfy { $0.kind == .project || $0.kind == .media })
    }

    /// Frames match only the video rendered from them. Each case below matched under the old
    /// rule (frame count within 3% of any video found going up to the project folder).
    @Test func framesMatchOnlyTheirOwnVideo() async throws {
        let f = try Fixture()
        try f.frames("show/ep1/frames", count: 320)
        try f.frames("show/ep2/frames", count: 321)    // its own video is gone; ep1's is one frame off
        try f.frames("pix/frames", count: 330)
        try f.frames("solo/render", count: 310)
        try await f.video("show/ep1/ep1.mp4", frames: 320)
        try await f.video("solo/render/final.mp4", frames: 310)     // saved among its own frames
        try await f.video("pix/out/near.mp4", frames: 340)          // 2.9% off
        try f.file("wbd/repo/.git/HEAD", text: "ref")
        try await f.video("wbd/repo/build/body.mp4", frames: 330)   // same count, but another project's
        let things = await FrameSequenceRecognizer.recognize(context(f.scan()))
        func tier(_ rel: String) -> Tier? {
            things.flatMap(\.items).first { $0.path == f.path(rel) }?.tier
        }
        #expect(tier("show/ep1/frames") == .regenerable)
        #expect(things.flatMap(\.items).first { $0.path == f.path("show/ep1/frames") }?.reason.contains("ep1.mp4") == true)
        #expect(tier("solo/render") == .regenerable)
        #expect(tier("show/ep2/frames") == .yours)
        #expect(tier("pix/frames") == .yours)
    }

    @Test func npxPackages() throws {
        let f = try Fixture()
        func install(_ hash: String, _ dep: String, _ version: String) throws {
            try f.file("npx/\(hash)/package.json", text: #"{"dependencies":{"\#(dep)":"*"}}"#)
            try f.file("npx/\(hash)/node_modules/\(dep)/package.json", text: #"{"version":"\#(version)"}"#)
            try f.file("npx/\(hash)/node_modules/\(dep)/big.bin", mb: 20)
        }
        try install("aaa", "cowsay", "1.6.0")
        try install("bbb", "cowsay", "1.5.0")
        try install("ccc", "some-mcp-server", "2.0.0")
        // Asked for several packages at once: named after the one with a command.
        try f.file("npx/ddd/package.json", text: #"{"dependencies":{"a-plugin":"*","the-tool":"*"}}"#)
        try f.file("npx/ddd/node_modules/a-plugin/package.json", text: #"{"version":"1.0.0"}"#)
        try f.file("npx/ddd/node_modules/the-tool/package.json", text: #"{"version":"3.1.0","bin":{"the-tool":"cli.js"}}"#)
        try f.file("npx/ddd/node_modules/the-tool/big.bin", mb: 20)
        let server = try f.runningProgram(using: "npx/ccc/node_modules/some-mcp-server/index.js")
        defer { server.terminate() }
        let tree = f.scan()
        let later = RecognizeContext(tree: tree, activity: ActivityIndex(), now: Date().addingTimeInterval(30 * 86400))
        let t = try #require(DevCacheRecognizer.npx(later, base: f.path("npx")))
        let cowsay = try #require(t.items.first { $0.label == "cowsay" })
        #expect(t.items.count == 2)   // the running one is left out
        #expect(t.items.contains { $0.label.hasPrefix("the-tool ") && $0.reason.contains("3.1.0") })
        guard case .deleteAll(let paths) = cowsay.action else { Issue.record("one item for both versions"); return }
        #expect(Set(paths) == [f.path("npx/aaa"), f.path("npx/bbb")])
        #expect(cowsay.reason.contains("1.5.0, 1.6.0") || cowsay.reason.contains("1.5.0、1.6.0"))
        #expect(cowsay.preselected)
        // Installed just now: Clean Up would skip them, so nothing is offered.
        #expect(DevCacheRecognizer.npx(context(tree), base: f.path("npx")) == nil)
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
        #expect(Guards.isDenied("/Volumes"))
        #expect(Guards.isDenied(Firmlinks.dataRoot))   // a disk's root folder
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

    @Test func runningProgramsKeepTheirFiles() throws {
        let f = try Fixture()
        try f.file("npx/ccc/node_modules/x.bin", mb: 1)
        let server = try f.runningProgram(using: "npx/ccc/node_modules/server.js")
        defer { server.terminate() }
        let item = ReclaimItem(id: "n", label: "npx", path: f.path("npx/ccc"), bytes: 1, tier: .regenerable,
                               action: .delete(path: f.path("npx/ccc")), reason: "", preselected: true)
        let o = Executor(store: nil, force: true, chosen: ["n"], log: { _ in }).run([item])[0]
        #expect(o.status == .skipped)
        #expect(o.message.contains("tail") && o.message.contains("PID \(server.processIdentifier)"))   // says who
        #expect(FileManager.default.fileExists(atPath: f.path("npx/ccc/node_modules/x.bin")))
        // A folder whose name only starts the same is not in use.
        #expect(Guards.program(using: f.path("npx/cc"), in: Guards.runningPrograms() ?? []) == nil)
    }

    @Test func recentChangesNeedForce() throws {
        let f = try Fixture()
        try f.file("p/node_modules/x.bin", mb: 1)
        let item = ReclaimItem(id: "r", label: "nm", path: f.path("p/node_modules"), bytes: 1, tier: .regenerable,
                               action: .delete(path: f.path("p/node_modules")), reason: "", preselected: true)
        let o = Executor(store: nil, force: false, log: { _ in }).run([item])[0]
        #expect(o.status == .skipped)
        // Says when it can go, and nothing about a flag the app doesn't have.
        let changed = try #require(Guards.lastChange(f.path("p/node_modules")))
        #expect(o.message.contains(Fmt.stamp(changed + Guards.quietPeriod)) && !o.message.contains("--force"))
        #expect(FileManager.default.fileExists(atPath: f.path("p/node_modules")))
    }

    /// Ticked by hand, a regenerable item goes even if it changed this week; your own files don't.
    @Test func handPickedRegenerableSkipsTheWait() throws {
        let f = try Fixture()
        try f.file("p/target/x.bin", mb: 1)
        try f.file("mine/clip.mov", mb: 1)
        let build = ReclaimItem(id: "b", label: "target", path: f.path("p/target"), bytes: 1, tier: .regenerable,
                                action: .delete(path: f.path("p/target")), reason: "", preselected: false)
        let mine = ReclaimItem(id: "m", label: "clip", path: f.path("mine"), bytes: 1, tier: .yours,
                               action: .trash(path: f.path("mine")), reason: "", preselected: false)
        let out = Executor(store: nil, chosen: ["b", "m"], log: { _ in }).run([build, mine])
        #expect(out[0].status == .done)
        #expect(!FileManager.default.fileExists(atPath: f.path("p/target")))
        #expect(out[1].status == .skipped)
        #expect(FileManager.default.fileExists(atPath: f.path("mine/clip.mov")))
    }

    /// A long `uv run` holds the cache lock: say so at once instead of waiting 5 minutes for it.
    @Test func uvWaitsForNoOne() {
        let running = [Guards.Program(pid: 7, command: "/bin/zsh -c uv run x"),
                       Guards.Program(pid: 29866, command: "uv run --frozen app --config config.yaml")]
        #expect(Executor.busy(["uv", "cache", "prune"], programs: running)?.pid == 29866)
        #expect(Executor.busy(["uv", "cache", "prune"], programs: [running[0]]) == nil)   // a shell that mentions uv
        #expect(Executor.busy(["npm", "cache", "clean", "--force"], programs: running) == nil)
        #expect(running[1].summary == "uv run --frozen app --config config.yaml")
        #expect(Guards.Program(pid: 1, command: "/Users/me/x/target/release/mytool serve --stdio").summary == "mytool serve --stdio")
    }

    /// npm is `#!/usr/bin/env node`; launched from Finder, the app's PATH has no node.
    @Test func scriptsFindTheInterpreterNextToThem() throws {
        let f = try Fixture()
        let interp = try f.file("bin/smd-fake-node", text: "#!/bin/sh\necho interpreter-ran\n")
        let tool = try f.file("bin/tool", text: "#!/usr/bin/env smd-fake-node\n")
        for p in [interp, tool] { chmod(p, 0o755) }
        #expect(!Shell.searchDirs.contains(f.path("bin")))
        let r = Shell.run([tool])
        #expect(r.ok, "\(r.stderr)")
        #expect(r.stdout.contains("interpreter-ran"))
    }
}

@Suite struct AppTests {
    /// An app bundle with an Info.plist and a binary big enough to show in the index.
    func app(_ f: Fixture, _ rel: String, id: String, name: String? = nil) throws {
        var plist = ["CFBundleIdentifier": id]
        if let name { plist["CFBundleName"] = name }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try f.file(rel + "/Contents/Info.plist", text: String(decoding: data, as: UTF8.self))
        try f.file(rel + "/Contents/MacOS/bin", mb: 2)
    }

    func paths(_ a: ReclaimAction) -> Set<String> { Set(Executor.paths(a)) }

    @Test func appsAndTheirData() throws {
        let f = try Fixture()
        try app(f, "Applications/Foo.app", id: "com.example.foo")
        try app(f, "Applications/Foo Pro.app", id: "com.example.foo.pro")      // extends Foo's id: gets its own data
        try app(f, "Applications/Vendor/Baz.app", id: "org.other.baz")          // a vendor folder
        try app(f, "Applications/Utilities/Qux.app", id: "com.example.qux")     // left out
        try app(f, "Applications/SuckMyDisk.app", id: "com.kadaliao.SuckMyDisk")
        #expect(symlink(f.path("Applications/Foo.app"), f.path("Applications/Link.app")) == 0)
        let lib = "Library/"
        try f.file(lib + "Caches/com.example.foo/blob", mb: 2)
        try f.file(lib + "Caches/com.example.foo.ShipIt/update", mb: 1)
        try f.file(lib + "Caches/com.example.foo.pro/blob", mb: 1)
        try f.file(lib + "Caches/com.example/shared", mb: 1)                     // the vendor's, not Foo's
        try f.file(lib + "Logs/Foo/today.log", text: "log")
        try f.file(lib + "Saved Application State/com.example.foo.savedState/windows.plist", text: "w")
        try f.file(lib + "Application Support/Foo/Cache/data_0", mb: 1)
        try f.file(lib + "Application Support/Foo/notes.db", mb: 1)
        try f.file(lib + "Application Support/Code/settings.json", text: "{}")   // too generic for anyone
        try f.file(lib + "Containers/com.example.foo.Extension/Data/Library/Caches/x", mb: 1)
        try f.file(lib + "Group Containers/ABCDE12345.com.example.foo/shared.db", text: "db")
        try f.file(lib + "Preferences/com.example.foo.plist", text: "p")
        try f.file(lib + "Preferences/com.example.plist", text: "p")
        try f.file("Caskroom/foo/.metadata/INSTALL_RECEIPT.json", text: #"{"uninstall_artifacts":[{"app":["Foo.app"]}]}"#)
        try f.file("System/com.example.foo.helper.plist", text: "")
        try f.file("System/org.other.daemon.plist", text: "")                    // Baz's developer has no other app here
        try f.file("System/com.example.updater.plist", text: "")                 // shared by two apps' developer: nobody's

        let ctx = RecognizeContext(tree: f.scan(), activity: ActivityIndex())
        let things = AppRecognizer.recognize(ctx, appFolders: [f.path("Applications")], library: f.path("Library"),
                                             systemFolders: [f.path("System")], caskrooms: [f.path("Caskroom")])
        #expect(Set(things.map(\.title)) == ["Foo", "Foo Pro", "Baz"])
        #expect(things.allSatisfy { $0.kind == .app && $0.items.allSatisfy { !$0.preselected } })

        let foo = try #require(things.first { $0.title == "Foo" })
        let uninstall = try #require(foo.items.first)
        #expect(uninstall.tier == .yours && uninstall.action.isTrashOnly && uninstall.app == f.path("Applications/Foo.app"))
        let l = f.path(lib)
        #expect(paths(uninstall.action) == [f.path("Applications/Foo.app"), l + "Caches/com.example.foo", l + "Caches/com.example.foo.ShipIt",
                                             l + "Logs/Foo", l + "Saved Application State/com.example.foo.savedState",
                                             l + "Application Support/Foo", l + "Containers/com.example.foo.Extension",
                                             l + "Group Containers/ABCDE12345.com.example.foo", l + "Preferences/com.example.foo.plist"])
        if case .compound(let acts) = uninstall.action, case .trash(let first) = acts.first {
            #expect(first == f.path("Applications/Foo.app"))   // the app goes first: if it can't move, nothing else does
        } else { Issue.record("uninstall is a list of moves to the Trash") }
        let caches = try #require(foo.items.last)
        #expect(caches.tier == .regenerable && uninstall.covers == [caches.id])
        #expect(paths(caches.action) == [l + "Caches/com.example.foo", l + "Caches/com.example.foo.ShipIt", l + "Logs/Foo",
                                          l + "Saved Application State/com.example.foo.savedState", l + "Application Support/Foo/Cache",
                                          l + "Containers/com.example.foo.Extension/Data/Library/Caches"])
        #expect(uninstall.warnings.contains { $0.contains("brew uninstall --cask foo") } && uninstall.restore == "brew install --cask foo")
        #expect(uninstall.warnings.contains { $0.contains("com.example.foo.helper.plist") && !$0.contains("updater") })
        #expect(foo.bytes >= 8_000_000 && foo.reclaimable == uninstall.estimate)

        let pro = try #require(things.first { $0.title == "Foo Pro" })
        #expect(paths(pro.items[0].action) == [f.path("Applications/Foo Pro.app"), l + "Caches/com.example.foo.pro"])
        let baz = try #require(things.first { $0.title == "Baz" })
        #expect(baz.items.count == 1)   // no caches to offer
        #expect(baz.items[0].warnings.contains { $0.contains("org.other.daemon.plist") })
    }

    /// Nothing of a running app is touched; quit, its caches go, the app stays.
    @Test func runningAppsAreLeftAlone() throws {
        let f = try Fixture()
        let bundle = f.path("Apps/Runner.app")
        try app(f, "Apps/Runner.app", id: "com.example.runner")
        try f.file("Library/Caches/com.example.runner/blob", mb: 1)
        let caches = ReclaimItem(id: "c", label: "caches", path: nil, bytes: 1, tier: .regenerable,
                                 action: .deleteAll(paths: [f.path("Library/Caches/com.example.runner"), f.path("Library/Logs/gone")]),
                                 reason: "", preselected: false, app: bundle)
        let runner = try f.runningProgram(using: "Apps/Runner.app/Contents/Resources/helper")
        let o = Executor(store: nil, chosen: ["c"], log: { _ in }).run([caches])[0]
        runner.terminate()
        runner.waitUntilExit()
        #expect(o.status == .skipped && o.message.contains("Runner") && o.message.contains("PID \(runner.processIdentifier)"))
        #expect(FileManager.default.fileExists(atPath: f.path("Library/Caches/com.example.runner/blob")))
        // A copy macOS runs from elsewhere (App Translocation) counts too.
        let moved = [Guards.Program(pid: 9, command: "/private/var/folders/x/AppTranslocation/ABC/d/Runner.app/Contents/MacOS/Runner")]
        #expect(Guards.program(inApp: bundle, in: moved)?.pid == 9)

        // Changed just now and picked by hand: goes, and the folder that vanished meanwhile doesn't stop it.
        let done = Executor(store: nil, chosen: ["c"], log: { _ in }).run([caches])[0]
        #expect(done.status == .done, "\(done.message)")
        #expect(!FileManager.default.fileExists(atPath: f.path("Library/Caches/com.example.runner")))
        #expect(FileManager.default.fileExists(atPath: bundle + "/Contents/MacOS/bin"))
    }

    /// An app's items picked by hand skip the 7-day rule; preselected or not picked, they wait.
    @Test func handPickedAppItemsSkipTheWait() throws {
        let f = try Fixture()
        let bundle = f.path("Apps/Fresh.app")
        try app(f, "Apps/Fresh.app", id: "com.example.fresh")
        try f.file("Library/Application Support/Fresh/state.db", mb: 1)
        // A delete stands in for the Trash here, so the test leaves nothing in your Trash.
        let item = ReclaimItem(id: "u", label: "data", path: bundle, bytes: 1, tier: .yours,
                               action: .deleteAll(paths: [f.path("Library/Application Support/Fresh")]),
                               reason: "", preselected: false, app: bundle)
        #expect(Executor(store: nil, log: { _ in }).run([item])[0].status == .skipped)
        #expect(Executor(store: nil, chosen: ["u"], log: { _ in }).run([item])[0].status == .done)
        // The app itself gone: reported, not quietly half-done.
        try FileManager.default.removeItem(atPath: bundle)
        try f.file("Library/Application Support/Fresh/state.db", mb: 1)
        let gone = Executor(store: nil, chosen: ["u"], log: { _ in }).run([item])[0]
        #expect(gone.status == .skipped)
        #expect(FileManager.default.fileExists(atPath: f.path("Library/Application Support/Fresh/state.db")))
    }

    @Test func sharedFoldersAreProtected() {
        let h = NSHomeDirectory()
        for p in ["/Applications", h + "/Applications", h + "/Library/Caches", h + "/Library/Containers",
                  h + "/Library/Application Support/", "/Library/LaunchDaemons/com.x.plist", "/Applications/Utilities/Terminal.app"] {
            #expect(Guards.isDenied(p), "\(p)")
        }
        #expect(!Guards.isDenied(h + "/Library/Caches/com.example.foo"))
        #expect(!Guards.isDenied("/Applications/Foo.app"))
        #expect(ReclaimAction.compound(actions: [.trash(path: "/a"), .trash(path: "/b")]).isTrashOnly)
        #expect(!ReclaimAction.compound(actions: [.trash(path: "/a"), .delete(path: "/b")]).isTrashOnly)
    }
}
