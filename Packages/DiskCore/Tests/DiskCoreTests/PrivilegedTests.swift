import Darwin
import Foundation
import Security
import Testing
@testable import Privileged
@testable import Reclaim
import Recognizers

/// The helper's rules, run here as an ordinary user on made-up folders.
@Suite struct PrivilegedTests {
    /// A made-up /Applications and home, with no symlink on the way (`/var` is one).
    final class Box {
        let root: String
        var apps: String { root + "/Applications" }
        var home: String { root + "/home" }
        var bin: String { home + "/.Trash" }

        init() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("smd-priv-" + UUID().uuidString).path
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            root = try #require(realpath(tmp, nil).map { p in defer { free(p) }; return String(cString: p) })
            for d in [apps, bin] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        }

        deinit { try? FileManager.default.removeItem(atPath: root) }

        @discardableResult
        func app(_ rel: String, id: String = "com.example.app") throws -> String {
            let p = apps + "/" + rel
            try FileManager.default.createDirectory(atPath: p + "/Contents/MacOS", withIntermediateDirectories: true)
            let info: NSDictionary = ["CFBundleIdentifier": id]
            #expect(info.write(toFile: p + "/Contents/Info.plist", atomically: true))
            return p
        }

        func mover(admin: Bool = true, running: Bool = false) -> AppMover {
            let home = home
            return AppMover(folders: [apps], isAdmin: { _ in admin }, home: { _ in home }, isRunning: { _ in running })
        }
    }

    static func exists(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0
    }

    @Test func movesAnAppToTheTrash() throws {
        let box = try Box()
        let app = try box.app("Foo.app")
        let dest = try box.mover().trash(app, for: getuid()).get()
        #expect(dest == box.bin + "/Foo.app")
        #expect(!Self.exists(app))
        #expect(Self.exists(dest + "/Contents/Info.plist"))
        // One folder down counts too.
        let inner = try box.app("Vendor/Bar.app")
        #expect(try box.mover().trash(inner, for: getuid()).get() == box.bin + "/Bar.app")
    }

    @Test func neverReplacesWhatIsInTheTrash() throws {
        let box = try Box()
        let first = try box.app("Foo.app")
        _ = try box.mover().trash(first, for: getuid()).get()
        try "old".write(toFile: box.bin + "/Foo.app/mark", atomically: true, encoding: .utf8)
        let second = try box.app("Foo.app")
        let dest = try box.mover().trash(second, for: getuid()).get()
        #expect(dest != box.bin + "/Foo.app")
        #expect(dest.hasPrefix(box.bin + "/Foo ") && dest.hasSuffix(".app"))
        #expect(Self.exists(box.bin + "/Foo.app/mark"))
    }

    @Test func onlyAppsInAnApplicationsFolder() throws {
        let m = AppMover()
        #expect(m.shapeProblem("/Applications/Foo.app") == nil)
        #expect(m.shapeProblem("/Applications/Adobe Photoshop/Photoshop.app") == nil)
        for bad in ["/Applications", "/Applications/", "/Applications/Foo", "/Applications/.app", "/Applications/.Hidden.app",
                    "/Applications/Utilities/Terminal.app", "/Applications/Foo.app/Contents/Helpers/Bar.app",
                    "/Applications/a/b/Foo.app", "/Applications/../Library/Foo.app", "/Applications/./Foo.app",
                    "/Applications//Foo.app", "/Applications/Foo.app/", "Applications/Foo.app", "/Library/Foo.app",
                    "/System/Applications/Mail.app", "/Users/someone/Applications/Foo.app", "/ApplicationsX/Foo.app",
                    "/Applications/Foo.app\0/x", ""] {
            #expect(m.shapeProblem(bad) != nil, "\(bad)")
        }
    }

    @Test func refusesWhatItShould() throws {
        let box = try Box()
        let app = try box.app("Foo.app")
        func refused(_ r: Result<String, AppMover.Refusal>, _ part: String) -> Bool {
            if case .failure(let e) = r { return e.description.contains(part) }
            return false
        }
        #expect(refused(box.mover(admin: false).trash(app, for: getuid()), "administrator"))
        #expect(refused(box.mover().trash(app, for: 0), "administrator"))
        #expect(refused(box.mover(running: true).trash(app, for: getuid()), "running"))
        #expect(refused(box.mover().trash(box.apps + "/Gone.app", for: getuid()), "no longer exists"))
        // Not an app inside, SuckMyDisk itself, a plain file.
        try FileManager.default.createDirectory(atPath: box.apps + "/Empty.app", withIntermediateDirectories: true)
        #expect(refused(box.mover().trash(box.apps + "/Empty.app", for: getuid()), "not an app"))
        let me = try box.app("Me.app", id: Privileged.appID)
        #expect(refused(box.mover().trash(me, for: getuid()), "itself"))
        try "x".write(toFile: box.apps + "/File.app", atomically: true, encoding: .utf8)
        #expect(refused(box.mover().trash(box.apps + "/File.app", for: getuid()), "not a folder"))
        // The Trash must be the person's own real folder.
        #expect(refused(box.mover().trash(app, for: getuid() + 1), "no Trash"))
        #expect(Self.exists(app))
    }

    @Test func symlinksAreNeverFollowed() throws {
        let box = try Box()
        let fm = FileManager.default
        // The app is a symlink to a real app somewhere else.
        let real = box.root + "/elsewhere/Real.app"
        try fm.createDirectory(atPath: real + "/Contents", withIntermediateDirectories: true)
        #expect((["CFBundleIdentifier": "com.example.real"] as NSDictionary).write(toFile: real + "/Contents/Info.plist", atomically: true))
        try fm.createSymbolicLink(atPath: box.apps + "/Link.app", withDestinationPath: real)
        if case .success = box.mover().trash(box.apps + "/Link.app", for: getuid()) { Issue.record("moved a symlink") }
        #expect(Self.exists(real))

        // A folder on the way is a symlink: the checks pass through it, the move must not.
        try fm.createSymbolicLink(atPath: box.apps + "/Vendor", withDestinationPath: box.root + "/elsewhere")
        if case .success = box.mover().trash(box.apps + "/Vendor/Real.app", for: getuid()) { Issue.record("moved through a symlink") }
        #expect(Self.exists(real))

        // The Trash is a symlink to somewhere else.
        let app = try box.app("Foo.app")
        try fm.removeItem(atPath: box.bin)
        try fm.createDirectory(atPath: box.root + "/target", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: box.bin, withDestinationPath: box.root + "/target")
        if case .success = box.mover().trash(app, for: getuid()) { Issue.record("moved into a symlinked Trash") }
        #expect(Self.exists(app))
        #expect(try fm.contentsOfDirectory(atPath: box.root + "/target").isEmpty)
    }

    @Test func requirementOnlyTakesATeamID() {
        #expect(Privileged.requirement(identifier: Privileged.appID, team: "HMDAVG9B8J")
                == "identifier \"com.kadaliao.SuckMyDisk\" and anchor apple generic and certificate leaf[subject.OU] = \"HMDAVG9B8J\"")
        for bad in ["", "short", "hmdavg9b8j", "HMDAVG9B8J\" or \"", "HMDAVG9B8JX"] {
            #expect(Privileged.requirement(identifier: Privileged.appID, team: bad) == nil, "\(bad)")
        }
        // The requirement must be one the system can read.
        var req: SecRequirement?
        let text = Privileged.requirement(identifier: Privileged.helperID, team: "HMDAVG9B8J")!
        #expect(SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess)
    }

    /// The executor asks the helper only for an app it couldn't move itself, and goes on to
    /// Finder when the helper can't either.
    @Test func executorAsksTheHelperForAnAppItCannotMove() throws {
        let box = try Box()
        // A folder nobody may write to makes `trashItem` fail, like an app that belongs to root.
        let locked = box.root + "/locked"
        let app = locked + "/Foo.app"
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        #expect(chmod(app, 0o555) == 0 && chmod(locked, 0o555) == 0)
        defer { chmod(locked, 0o755); chmod(app, 0o755) }

        final class Calls: @unchecked Sendable { var paths: [String] = [] }
        let calls = Calls()
        let item = ReclaimItem(id: "t", label: "t", path: app, bytes: 1, tier: .yours, action: .trash(path: app),
                               reason: "", preselected: false)
        // The helper "moves" it: the executor believes that only if the app is gone.
        let ex = Executor(store: nil, force: true, log: { _ in }, elevate: { p in
            calls.paths.append(p)
            chmod(locked, 0o755); chmod(app, 0o755)
            try? FileManager.default.removeItem(atPath: app)
            return nil
        })
        let out = ex.run([item])
        #expect(calls.paths == [app])
        #expect(out.first?.status == .done)

    }
}
