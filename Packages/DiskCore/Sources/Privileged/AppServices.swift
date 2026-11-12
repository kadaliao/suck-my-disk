import Darwin
import Foundation

/// What an app leaves running after its window is closed (launchd daemons and agents, helper
/// programs), and how that is stopped before the app is uninstalled. Nobody can quit these by
/// hand, so an uninstall that waited for them would wait for ever.
///
/// The app stops what belongs to the person; the helper, as root, stops the rest.
public enum AppServices {
    /// A launchd job whose program is inside the app.
    public struct Job: Sendable, Equatable {
        public var label: String
        /// Its file in a LaunchDaemons or LaunchAgents folder.
        public var plist: String
        /// Runs for the whole system (as root, usually) rather than for the person logged in.
        public var daemon: Bool
    }

    /// The jobs in these folders that run a program from inside `app`.
    public static func jobs(of app: String, daemons: [String], agents: [String]) -> [Job] {
        var out: [Job] = []
        for (folders, daemon) in [(daemons, true), (agents, false)] {
            for folder in folders {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                for name in names.sorted() where name.hasSuffix(".plist") {
                    let path = folder + "/" + name
                    var st = stat()
                    guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size < 1_000_000,
                          let d = NSDictionary(contentsOfFile: path) as? [String: Any],
                          let label = d["Label"] as? String, isPlain(label),
                          let program = d["Program"] as? String ?? (d["ProgramArguments"] as? [Any])?.first as? String,
                          program.hasPrefix(app + "/") else { continue }
                    out.append(Job(label: label, plist: path, daemon: daemon))
                }
            }
        }
        return out
    }

    /// A label that can only name one job when put after "system/" or "gui/501/".
    static func isPlain(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.count <= 200
            && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    /// Every running program's file, or nil if they can't be listed.
    static func programs() -> [(pid: pid_t, path: String)]? {
        var pids = [pid_t](repeating: 0, count: 16384)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var out: [(pid_t, String)] = []
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            if len > 0 { out.append((pid, String(decoding: buf.prefix(Int(len)), as: UTF8.self))) }
        }
        return out
    }

    /// The programs running from inside `app`, or nil if that can't be told.
    public static func running(in app: String) -> [pid_t]? {
        programs().map { $0.filter { $0.path.hasPrefix(app + "/") }.map(\.pid) }
    }

    /// True if the app itself is open (its main program runs), or if that can't be told.
    /// Its owner can quit it, and may have unsaved work in it: it is never stopped here.
    public static func isOpen(_ app: String) -> Bool {
        guard let all = programs() else { return true }
        let info = [app + "/Contents/Info.plist", app + "/WrappedBundle/Info.plist"]
            .lazy.compactMap { NSDictionary(contentsOfFile: $0) as? [String: Any] }.first
        guard let exe = info?["CFBundleExecutable"] as? String, !exe.isEmpty else {
            return all.contains { $0.path.hasPrefix(app + "/Contents/MacOS/") }
        }
        return all.contains { $0.path == app + "/Contents/MacOS/" + exe }
    }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }

    private static func wait(_ seconds: TimeInterval, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { usleep(100_000) }
    }

    /// Unloads `jobs` so launchd doesn't start them again, then ends every program running from
    /// `app` that this process may end: asked first, killed after `grace` seconds. Daemons are
    /// only unloaded by root. Returns the programs still running (somebody else's, when this
    /// isn't root), or nil if that can't be told.
    public static func stop(_ app: String, jobs: [Job], user uid: uid_t, grace: TimeInterval = 3) -> [pid_t]? {
        for j in jobs {
            if !j.daemon {
                launchctl(["bootout", "gui/\(uid)/" + j.label])
            } else if geteuid() == 0 {
                launchctl(["bootout", "system/" + j.label])
            }
        }
        end(in: app, grace: grace)
        return running(in: app)
    }

    /// Ends the programs running from `folder` that this process may end.
    public static func end(in folder: String, grace: TimeInterval = 3) {
        func ours(_ signal: Int32) -> Set<pid_t> {
            Set((running(in: folder) ?? []).filter { kill($0, signal) == 0 })
        }
        func gone(_ pids: Set<pid_t>) -> Bool {
            pids.isEmpty || (running(in: folder) ?? []).allSatisfy { !pids.contains($0) }
        }
        let asked = ours(SIGTERM)
        wait(grace) { gone(asked) }
        let killed = ours(SIGKILL)
        wait(2) { gone(killed) }
    }
}
