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
    ]
    static let deniedSuffixes = [".photoslibrary", ".musiclibrary", ".tvlibrary", ".imovielibrary", ".fcpbundle"]

    /// True if the path must never be deleted or trashed by SuckMyDisk.
    public static func isDenied(_ path: String) -> Bool {
        let p = Firmlinks.userPath((path as NSString).standardizingPath)
        if p == home || p == "/" || p == "/Users" || p == home + "/Library" || p == "/Volumes" { return true }
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
        let r = Shell.run(["ps", "-axww", "-o", "pid=,command="], timeout: 10)
        guard r.ok else { return nil }
        return r.stdout.split(separator: "\n").compactMap { line in
            let t = line.drop { $0 == " " }
            guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { return nil }
            return Program(pid: pid, command: String(t[sp...].dropFirst()))
        }
    }

    /// A running program that was started from inside `path` or was handed a path inside it,
    /// like an MCP server that npx runs from ~/.npm/_npx, or ffmpeg reading a frames folder.
    public static func program(using path: String, in programs: [Program]) -> Program? {
        let p = Firmlinks.userPath((path as NSString).standardizingPath)
        return programs.first { $0.command.contains(p + "/") || $0.command.contains(p + " ") || $0.command.hasSuffix(p) }
    }

    /// A change this recent keeps an item from being cleaned, unless the person picked
    /// a regenerable one themselves.
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

    /// "changed 10-31 18:07; can be cleaned after 11-07 18:07"
    public static func waitNote(changed d: Date) -> String {
        L("\(Fmt.stamp(d)) 改过，\(Fmt.stamp(d + quietPeriod)) 之后才能清",
          "changed \(Fmt.stamp(d)); can be cleaned after \(Fmt.stamp(d + quietPeriod))")
    }
}
