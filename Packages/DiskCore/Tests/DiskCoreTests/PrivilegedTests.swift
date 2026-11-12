import Darwin
import Foundation
import Security
import Testing
@testable import Privileged
@testable import Reclaim
import Recognizers
@testable import DiskIndex

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

        var daemons: String { root + "/LaunchDaemons" }

        func mover(admin: Bool = true) -> AppMover {
            let home = home
            return AppMover(folders: [apps], isAdmin: { _ in admin }, home: { _ in home },
                            daemonFolders: [daemons], agentFolders: [])
        }

        /// Starts a program whose file is inside the app, like a daemon the app installed.
        func run(_ rel: String, in app: String) throws -> Process {
            let exe = app + "/" + rel
            try FileManager.default.createDirectory(atPath: (exe as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: exe)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["600"]
            try p.run()
            return p
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

    /// An app that is open is the person's to quit. What it left running in the background
    /// nobody can quit: that is stopped, and its launchd job goes to the Trash with the app.
    @Test func stopsBackgroundProgramsButNotAnOpenApp() throws {
        let box = try Box()
        let fm = FileManager.default
        let app = try box.app("Foo.app")
        #expect((["CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "Foo"] as NSDictionary)
            .write(toFile: app + "/Contents/Info.plist", atomically: true))
        try fm.createDirectory(atPath: box.daemons, withIntermediateDirectories: true)
        let job: NSDictionary = ["Label": "com.example.daemon", "ProgramArguments": [app + "/Contents/Resources/bin/daemon", "/sub"]]
        #expect(job.write(toFile: box.daemons + "/sec.plist", atomically: true))
        // Somebody else's job, and one whose label could name more than a job: both stay.
        let other: NSDictionary = ["Label": "com.other.daemon", "Program": box.apps + "/Foo.app.other/x"]
        #expect(other.write(toFile: box.daemons + "/other.plist", atomically: true))
        let odd: NSDictionary = ["Label": "a/../b", "Program": app + "/Contents/Resources/bin/daemon"]
        #expect(odd.write(toFile: box.daemons + "/odd.plist", atomically: true))
        #expect(AppServices.jobs(of: app, daemons: [box.daemons], agents: [])
                == [AppServices.Job(label: "com.example.daemon", plist: box.daemons + "/sec.plist", daemon: true)])

        let main = try box.run("Contents/MacOS/Foo", in: app)
        let daemon = try box.run("Contents/Resources/bin/daemon", in: app)
        defer { main.terminate(); daemon.terminate() }
        #expect(AppServices.isOpen(app))
        if case .failure(let e) = box.mover().trash(app, for: getuid()) { #expect(e.description.contains("open")) }
        else { Issue.record("moved an app that is open") }
        #expect(daemon.isRunning && Self.exists(app))

        main.terminate()
        main.waitUntilExit()
        #expect(!AppServices.isOpen(app))
        #expect(AppServices.running(in: app) == [daemon.processIdentifier])
        let dest = try box.mover().trash(app, for: getuid()).get()
        daemon.waitUntilExit()
        #expect(!Self.exists(app) && Self.exists(dest))
        #expect(!Self.exists(box.daemons + "/sec.plist") && Self.exists(box.bin + "/sec.plist"))
        #expect(Self.exists(box.daemons + "/other.plist") && Self.exists(box.daemons + "/odd.plist"))
    }

    /// Uninstalling stops what the app left running; without the helper, a service that runs
    /// as somebody else keeps the app where it is, and the message says what to turn on.
    @Test func executorStopsBackgroundProgramsWhenUninstalling() throws {
        let box = try Box()
        let app = try box.app("Foo.app")
        try FileManager.default.createDirectory(atPath: box.root + "/data", withIntermediateDirectories: true)
        // A delete stands in for the Trash here, so the test leaves nothing in your Trash.
        let uninstall = ReclaimItem(id: "u", label: "u", path: app, bytes: 1, tier: .yours,
                                    action: .deleteAll(paths: [app, box.root + "/data"]), reason: "", preselected: false, app: app)
        let caches = ReclaimItem(id: "c", label: "c", path: nil, bytes: 1, tier: .regenerable,
                                 action: .deleteAll(paths: [box.root + "/data"]), reason: "", preselected: false, app: app)
        let daemon = try box.run("Contents/Resources/bin/daemon", in: app)
        defer { daemon.terminate() }
        let ex = Executor(store: nil, log: { _ in }, agentFolders: [])
        // Its caches alone are no reason to stop anything.
        #expect(ex.run([caches])[0].status == .skipped)
        #expect(daemon.isRunning)
        let out = ex.run([uninstall])[0]
        #expect(out.status == .done, "\(out.message)")
        daemon.waitUntilExit()
        #expect(!Self.exists(app) && !Self.exists(box.root + "/data"))

        // Root's daemon, as `ps` would show it.
        let theirs = [Guards.Program(pid: 826, command: app + "/Contents/Resources/bin/ctEAO /subclient", uid: 0)]
        #expect(Guards.programs(inApp: app, in: theirs).count == 1 && Guards.mainProgram(ofApp: app, in: theirs) == nil)
        let open = [Guards.Program(pid: 9, command: "/Applications/Foo.app/Contents/MacOS/Foo -psn")]
        #expect(Guards.mainProgram(ofApp: "/Applications/Foo.app", in: open)?.pid == 9)
        let listed = try #require(Guards.runningPrograms())
        #expect(listed.contains { $0.pid == getpid() && $0.uid == getuid() } && listed.contains { $0.pid == 1 && $0.uid == 0 })
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
        let ex = Executor(store: nil, log: { _ in }, elevate: { p in
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
