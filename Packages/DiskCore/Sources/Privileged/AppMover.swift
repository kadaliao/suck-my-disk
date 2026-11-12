import Darwin
import Foundation

/// The helper's whole job, kept apart from XPC so it can be tested without root.
///
/// It runs as root on a path that a program of the person's sent, so it trusts nothing about
/// that path: it must name an app directly in an applications folder (or one folder down),
/// and the move itself refuses symlinks anywhere on either path and never replaces anything.
public struct AppMover: Sendable {
    public struct Refusal: Error, CustomStringConvertible, Sendable {
        public var description: String
        init(_ s: String) { description = s }
    }

    /// Where apps may be taken from.
    public var folders: [String]
    /// Apps that are never moved: SuckMyDisk itself.
    public var keptIDs: Set<String>
    /// Whether the person may remove apps here: Finder asks an administrator too.
    public var isAdmin: @Sendable (uid_t) -> Bool
    public var home: @Sendable (uid_t) -> String?
    /// Whether a program is running from the app.
    public var isRunning: @Sendable (String) -> Bool

    public init(folders: [String] = ["/Applications"], keptIDs: Set<String> = [Privileged.appID],
                isAdmin: @escaping @Sendable (uid_t) -> Bool = AppMover.isAdmin,
                home: @escaping @Sendable (uid_t) -> String? = AppMover.home,
                isRunning: @escaping @Sendable (String) -> Bool = AppMover.isRunning) {
        self.folders = folders
        self.keptIDs = keptIDs
        self.isAdmin = isAdmin
        self.home = home
        self.isRunning = isRunning
    }

    /// Why `path` can't be an app this helper moves, judged from the text alone.
    public func shapeProblem(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < Int(PATH_MAX) else { return "not a full path" }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return "not a plain path" }
        guard let folder = folders.first(where: { path.hasPrefix($0 + "/") }) else { return "not in an applications folder" }
        let rest = path.dropFirst(folder.count + 1).split(separator: "/")
        guard rest.count == 1 || rest.count == 2, let name = rest.last else { return "not an app in an applications folder" }
        guard name.hasSuffix(".app"), name.count > 4, !name.hasPrefix(".") else { return "not an app" }
        if rest.count == 2 {
            // One folder down ("Adobe Photoshop/…"), but never Utilities and never inside another app.
            let sub = rest[0]
            guard sub != "Utilities", !sub.hasPrefix("."), !sub.hasSuffix(".app") else { return "not an app in an applications folder" }
        }
        return nil
    }

    /// Moves the app at `path` to the Trash of user `uid`; returns where it went.
    public func trash(_ path: String, for uid: uid_t) -> Result<String, Refusal> {
        func no(_ s: String) -> Result<String, Refusal> { .failure(Refusal(s)) }
        if let why = shapeProblem(path) { return no(why) }
        guard uid != 0, isAdmin(uid) else { return no("only an administrator can remove this app") }

        var st = stat()
        guard lstat(path, &st) == 0 else { return no("no longer exists") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return no("not a folder") }
        guard st.st_flags & UInt32(SF_RESTRICTED) == 0 else { return no("protected by System Integrity Protection") }
        // iPhone and iPad apps keep their Info.plist in a wrapper.
        guard let info = [path + "/Contents/Info.plist", path + "/WrappedBundle/Info.plist"]
                .lazy.compactMap({ NSDictionary(contentsOfFile: $0) as? [String: Any] }).first,
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else { return no("not an app") }
        guard !keptIDs.contains(id) else { return no("SuckMyDisk doesn't remove itself") }
        guard !isRunning(path) else { return no("the app is running") }

        guard let home = home(uid) else { return no("no home folder for user \(uid)") }
        let bin = home + "/.Trash"
        var tst = stat()
        guard lstat(bin, &tst) == 0, (tst.st_mode & S_IFMT) == S_IFDIR, tst.st_uid == uid else { return no("no Trash folder") }
        guard tst.st_dev == st.st_dev else { return no("the Trash is on another disk") }

        let file = (path as NSString).lastPathComponent
        let base = (file as NSString).deletingPathExtension
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH.mm.ss"
        // Like Finder: a second "Foo.app" in the Trash gets the time in its name.
        let names = [file, "\(base) \(f.string(from: Date())).app"] + (2...9).map { "\(base) \($0).app" }
        for name in names {
            let dest = bin + "/" + name
            // Never replaces what is there, and fails if any folder on either path is a symlink,
            // so nothing swapped in after the checks above can send the move somewhere else.
            if renameatx_np(AT_FDCWD, path, AT_FDCWD, dest, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 { return .success(dest) }
            if errno != EEXIST { return no("rename: \(String(cString: strerror(errno))) (\(errno))") }
        }
        return no("the Trash already has apps with this name")
    }

    // MARK: the real machine

    private static let lock = NSLock()

    /// A member of the `admin` group.
    public static func isAdmin(_ uid: uid_t) -> Bool {
        lock.withLock {
            guard let pw = getpwuid(uid) else { return false }
            var groups = [Int32](repeating: 0, count: 128)
            var n = Int32(groups.count)
            guard getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &groups, &n) >= 0 else { return false }
            return groups.prefix(Int(n)).contains(80)
        }
    }

    public static func home(_ uid: uid_t) -> String? {
        lock.withLock {
            guard let pw = getpwuid(uid), let dir = pw.pointee.pw_dir else { return nil }
            let s = String(cString: dir)
            return s.hasPrefix("/") && s.count > 1 ? s : nil
        }
    }

    /// True if any program's file is inside `app`, or if the programs can't be listed.
    public static func isRunning(_ app: String) -> Bool {
        var pids = [pid_t](repeating: 0, count: 16384)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return true }
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            guard len > 0 else { continue }
            if String(decoding: buf.prefix(Int(len)), as: UTF8.self).hasPrefix(app + "/") { return true }
        }
        return false
    }
}
