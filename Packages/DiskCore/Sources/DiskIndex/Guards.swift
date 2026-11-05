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

    /// Newest of mtime / ctime for the item itself (its own inode).
    public static func lastChange(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let m = TimeInterval(st.st_mtimespec.tv_sec), c = TimeInterval(st.st_ctimespec.tv_sec)
        return Date(timeIntervalSince1970: max(m, c))
    }
}
