import Foundation

/// Hard safety rules that no recognizer can override.
public enum Guards {
    static let home = NSHomeDirectory()

    static let deniedPrefixes: [String] = [
        home + "/Library/Mobile Documents",   // iCloud Drive: deleting here deletes in the cloud
        home + "/Library/CloudStorage",       // Dropbox, OneDrive, Google Drive, ...
        home + "/Library/Mail",
        home + "/Library/Messages",
        home + "/Library/Keychains",
        home + "/.ssh",
        home + "/.gnupg",
        "/System", "/usr", "/bin", "/sbin",
        "/Library",                           // every user's: apps' system components, fonts, ...
        "/Applications/Utilities",
    ]
    /// Folders that hold many apps' data or many apps: never removed as a whole.
    static let deniedFolders: Set<String> = Set(["/Applications", home + "/Applications"] + [
        "Application Support", "Caches", "Containers", "Group Containers", "Preferences", "Saved Application State",
        "HTTPStorages", "WebKit", "Logs", "Cookies", "LaunchAgents",
    ].map { home + "/Library/" + $0 })
    static let deniedSuffixes = [".photoslibrary", ".musiclibrary", ".tvlibrary", ".imovielibrary", ".fcpbundle"]

    /// True if the path must never be deleted or trashed by SuckMyDisk.
    public static func isDenied(_ path: String) -> Bool {
        let p = Firmlinks.userPath((path as NSString).standardizingPath)
        if p == home || p == "/" || p == "/Users" || p == home + "/Library" || p == "/Volumes" || deniedFolders.contains(p) { return true }
        // A disk's own root folder.
        if ExternalVolumes.mountPoint(of: p).map({ Firmlinks.userPath($0) == p }) ?? false { return true }
        for d in deniedPrefixes where p == d || p.hasPrefix(d + "/") { return true }
        for comp in p.split(separator: "/") {
            if comp == ".git" { return true }
            for s in deniedSuffixes where comp.hasSuffix(s) { return true }
        }
        return false
    }

    /// The git work tree containing `path`, if any.
    public static func gitRoot(of path: String) -> String? {
        var cur = (path as NSString).deletingLastPathComponent
        while cur.count > 1 {
            if FileManager.default.fileExists(atPath: cur + "/.git") { return cur }
            cur = (cur as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// True if git tracks any file at or below `path`. Fails closed: if git
    /// can't answer for a folder inside a repo, we assume it tracks something.
    public static func hasTrackedFiles(_ path: String) -> Bool {
        guard let root = gitRoot(of: path) else { return false }
        let r = Shell.run(["git", "-C", root, "ls-files", "--", path], timeout: 30)
        if !r.ok { return true }
        return r.stdout.contains(where: { !$0.isWhitespace })
    }

    /// A running program, as `ps` shows it.
    public struct Program: Sendable {
        public var pid: Int32
        public var command: String
        /// Whose it is. The person can't stop somebody else's (root's daemon).
        public var uid: uid_t = getuid()

        /// The program's file name, like `uv` or `node`.
        public var name: String { (command.split(separator: " ").first.map(String.init).map { ($0 as NSString).lastPathComponent }) ?? "" }

        /// The command line with folders left out, short enough for a message: `mytool serve --stdio`.
        public var summary: String {
            let s = command.split(separator: " ")
                .map { $0.hasPrefix("/") ? (String($0) as NSString).lastPathComponent : String($0) }
                .joined(separator: " ")
            return s.count > 48 ? s.prefix(47) + "…" : s
        }
    }

    /// The running programs, or nil if they can't be read.
    public static func runningPrograms() -> [Program]? {
        let r = Shell.run(["ps", "-axww", "-o", "pid=,uid=,command="], timeout: 10)
        guard r.ok else { return nil }
        return r.stdout.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), let uid = uid_t(f[1]) else { return nil }
            return Program(pid: pid, command: String(f[2]), uid: uid)
        }
    }

    /// A running program that was started from inside `path` or was handed a path inside it,
    /// like an MCP server that npx runs from ~/.npm/_npx, or ffmpeg reading a frames folder.
    public static func program(using path: String, in programs: [Program]) -> Program? {
        let p = Firmlinks.userPath((path as NSString).standardizingPath)
        return programs.first { $0.command.contains(p + "/") || $0.command.contains(p + " ") || $0.command.hasSuffix(p) }
    }

    /// A running program from the app at `path`, or from a copy of it that macOS runs from
    /// somewhere else (App Translocation runs downloaded apps from a hidden folder).
    public static func program(inApp path: String, in programs: [Program]) -> Program? {
        self.programs(inApp: path, in: programs).first
    }

    /// Every running program from the app at `path`, a copy run from somewhere else included.
    public static func programs(inApp path: String, in programs: [Program]) -> [Program] {
        let p = Firmlinks.userPath((path as NSString).standardizingPath)
        let inside = "/" + (path as NSString).lastPathComponent + "/Contents/"
        return programs.filter {
            $0.command.contains(p + "/") || $0.command.contains(p + " ") || $0.command.hasSuffix(p) || $0.command.contains(inside)
        }
    }

    /// The app itself among `programs` (its main program, the one its owner can quit), as
    /// against the daemons and helpers it leaves running in the background.
    public static func mainProgram(ofApp path: String, in programs: [Program]) -> Program? {
        let file = (path as NSString).lastPathComponent
        let info = [path + "/Contents/Info.plist", path + "/WrappedBundle/Info.plist"]
            .lazy.compactMap { NSDictionary(contentsOfFile: $0) as? [String: Any] }.first
        let exe = (info?["CFBundleExecutable"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ""
        let tail = "/" + file + "/Contents/MacOS/" + exe
        return programs.first { exe.isEmpty ? $0.command.contains(tail) : $0.command.hasSuffix(tail) || $0.command.contains(tail + " ") }
    }

    /// Something changed this recently is still being worked on: recognizers don't tick it
    /// by default. Once ticked, by them or by the person, it is cleaned like anything else.
    public static let quietPeriod: TimeInterval = 7 * 86400

    /// Newest of mtime / ctime for the item itself (its own inode).
    public static func lastChange(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let m = TimeInterval(st.st_mtimespec.tv_sec), c = TimeInterval(st.st_ctimespec.tv_sec)
        return Date(timeIntervalSince1970: max(m, c))
    }

    /// When `path` was last changed, if that is within the quiet period.
    public static func recentChange(_ path: String, now: Date = Date()) -> Date? {
        guard let d = lastChange(path), now.timeIntervalSince(d) < quietPeriod else { return nil }
        return d
    }

    /// "changed 10-31 18:07": a warning on an item you may still be working on.
    public static func recentNote(changed d: Date) -> String {
        L("\(Fmt.stamp(d)) 刚改过，确认不再用了再勾", "changed \(Fmt.stamp(d)); make sure you are done with it")
    }
}
