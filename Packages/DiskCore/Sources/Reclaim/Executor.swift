import Darwin
import DiskIndex
import Foundation
import Recognizers

/// Carries out reclaim items one by one, re-checking every safety rule right
/// before acting, and records what really happened in the journal.
public final class Executor {
    public struct Outcome: Sendable {
        public var item: ReclaimItem
        public var status: Status
        public var freed: Int64
        public var message: String
    }

    /// `stopped`: the run was stopped while this item was being done, so part of it may be left.
    public enum Status: String, Sendable { case done, skipped, failed, stopped }

    let store: Store?
    let force: Bool
    let chosen: Set<String>
    let log: (String) -> Void
    /// Told when a step waits for the person (Finder asking for a password); nil sends it to `log`.
    let note: ((String) -> Void)?
    /// Asked before every step and while a command runs: true stops the run there.
    let isCancelled: () -> Bool
    /// Rows the current item's `.erase` actions removed.
    private var erased = 0
    /// The current item was cut short by `isCancelled`, after `finished` of its steps.
    private var stopped = false
    private var finished = 0

    /// `force` lifts the 7-day rule for every item. `chosen` holds the items the person picked
    /// themselves: the regenerable ones among them skip the rule too, since they asked for it and
    /// nothing is lost that can't be rebuilt. Preselected items keep it, so anything that changed
    /// after the scan is left alone.
    public init(store: Store?, force: Bool = false, chosen: Set<String> = [],
                log: @escaping (String) -> Void = { print($0) },
                note: ((String) -> Void)? = nil,
                isCancelled: @escaping () -> Bool = { false }) {
        self.store = store
        self.force = force
        self.chosen = chosen
        self.log = log
        self.note = note
        self.isCancelled = isCancelled
    }

    /// Items whose turn hadn't come when the run was stopped have no outcome.
    public func run(_ items: [ReclaimItem]) -> [Outcome] {
        var out: [Outcome] = []
        for item in items {
            if isCancelled() { break }
            out.append(runOne(item))
        }
        return out
    }

    /// Paths an action would remove.
    public static func paths(_ a: ReclaimAction) -> [String] { a.paths }

    /// Commands an action would run.
    static func commands(_ a: ReclaimAction) -> [[String]] {
        switch a {
        case .command(let argv, _): return [argv]
        case .compound(let acts): return acts.flatMap(commands)
        default: return []
        }
    }

    /// Tools whose cache commands wait for every running copy to exit:
    /// `uv cache prune` sits on the cache lock for up to 5 minutes, then fails.
    static let lockingTools: Set<String> = ["uv", "uvx"]

    /// A running copy of the tool `argv` runs, if that tool waits for its other copies.
    static func busy(_ argv: [String], programs: [Guards.Program]) -> Guards.Program? {
        guard let tool = argv.first.map({ ($0 as NSString).lastPathComponent }), lockingTools.contains(tool) else { return nil }
        return programs.first { lockingTools.contains($0.name) }
    }

    /// `programs`: what is running, nil if that couldn't be read.
    func check(_ path: String, programs: [Guards.Program]?, recentOK: Bool) -> String? {
        if Guards.isDenied(path) { return L("受保护的位置", "protected location") }
        var st = stat()
        guard lstat(path, &st) == 0 else { return L("已经不存在", "no longer exists") }
        if (st.st_mode & S_IFMT) == S_IFLNK { return L("是符号链接", "is a symlink") }
        if st.st_flags & UInt32(SF_RESTRICTED) != 0 { return L("受 macOS 系统完整性保护", "protected by System Integrity Protection") }
        if Guards.hasTrackedFiles(path) { return L("里面有 git 跟踪的文件", "contains git-tracked files") }
        // Fails closed, like the git check.
        guard let programs else { return L("没法确认有没有程序在用", "can't tell whether a program is using it") }
        if let p = Guards.program(using: path, in: programs) {
            return L("\(p.summary)（PID \(p.pid)）正在用", "in use by \(p.summary) (PID \(p.pid))")
        }
        if !recentOK, let d = Guards.recentChange(path) { return Guards.waitNote(changed: d) }
        return nil
    }

    /// A database whose records an item erases: it stays, so only where it is and who names it matter.
    func check(database path: String, programs: [Guards.Program]?) -> String? {
        if Guards.isDenied(path) { return L("受保护的位置", "protected location") }
        var st = stat()
        guard lstat(path, &st) == 0 else { return L("已经不存在", "no longer exists") }
        if (st.st_mode & S_IFMT) != S_IFREG { return L("不是普通文件", "is not a regular file") }
        guard let programs else { return L("没法确认有没有程序在用", "can't tell whether a program is using it") }
        if let p = Guards.program(using: path, in: programs) {
            return L("\(p.summary)（PID \(p.pid)）正在用", "in use by \(p.summary) (PID \(p.pid))")
        }
        return nil
    }

    static func exists(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0
    }

    /// An app's caches and data folders come and go while it runs (window state, logs), so the
    /// ones gone since the scan are dropped instead of failing the whole item. `keep` (the app
    /// itself) stays, so a missing app is still reported.
    static func existing(_ a: ReclaimAction, keep: String?) -> ReclaimAction {
        switch a {
        case .deleteAll(let ps): return .deleteAll(paths: ps.filter { $0 == keep || exists($0) })
        case .compound(let acts):
            return .compound(actions: acts.compactMap { x in
                switch x {
                case .trash(let p), .delete(let p): return p == keep || exists(p) ? x : nil
                default: return existing(x, keep: keep)
                }
            })
        default: return a
        }
    }

    func runOne(_ original: ReclaimItem) -> Outcome {
        var item = original
        if item.app != nil { item.action = Self.existing(item.action, keep: item.path) }
        let paths = Self.paths(item.action), argvs = Self.commands(item.action), dbs = item.action.databases
        let acts = !paths.isEmpty || !argvs.isEmpty || !dbs.isEmpty
        // The list is older than the disk: an app removed meanwhile is reported, not half cleaned.
        if let app = item.app, !Self.exists(app) || !acts {
            return finish(item, .skipped, 0, L("\(Fmt.home(app)) 已经不在了", "\(Fmt.home(app)) is no longer there"), before: 0, after: 0)
        }
        let programs = acts ? Guards.runningPrograms() : []
        // Picked by hand, rebuildable items, erased records and an app's items don't wait out the 7-day rule:
        // a browser's history always changed this week.
        let recentOK = force || (chosen.contains(item.id) && (item.tier == .regenerable || item.tier == .erase || item.app != nil))
        if let app = item.app {
            let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
            guard let programs else {
                return finish(item, .skipped, 0, L("没法确认 \(name) 有没有在运行", "can't tell whether \(name) is running"), before: 0, after: 0)
            }
            if let p = Guards.program(inApp: app, in: programs) {
                return finish(item, .skipped, 0,
                              L("\(name) 正在运行（\(p.summary)，PID \(p.pid)），先退出它",
                                "\(name) is running (\(p.summary), PID \(p.pid)); quit it first"),
                              before: 0, after: 0)
            }
        }
        for p in paths {
            if let why = check(p, programs: programs, recentOK: recentOK) {
                return finish(item, .skipped, 0, "\(Fmt.home(p)): \(why)", before: 0, after: 0)
            }
        }
        for db in dbs {
            if let why = check(database: db, programs: programs) {
                return finish(item, .skipped, 0, "\(Fmt.home(db)): \(why)", before: 0, after: 0)
            }
        }
        for argv in argvs {
            if let p = programs.flatMap({ Self.busy(argv, programs: $0) }) {
                return finish(item, .skipped, 0,
                              L("\(p.summary)（PID \(p.pid)）还在运行，\(argv[0]) 要等它退出才能清缓存",
                                "\(p.summary) (PID \(p.pid)) is still running; \(argv[0]) can't clean its cache until it exits"),
                              before: 0, after: 0)
            }
        }
        var detail: [String] = []
        // Record what a venv contained before it goes, so it can be rebuilt faithfully.
        for p in Self.paths(item.action) where FileManager.default.fileExists(atPath: p + "/pyvenv.cfg") {
            detail.append(venvSnapshot(p))
        }
        // Measure the disk the item is on: it may be an external one.
        let disk = Self.paths(item.action).lazy.compactMap(ExternalVolumes.mountPoint).first ?? Firmlinks.dataRoot
        let before = VolumeInfo.freeBytes(disk)
        erased = 0
        stopped = false
        finished = 0
        var error = perform(item.action)
        let after = VolumeInfo.freeBytes(disk)
        // Say so when part of the item already went: an app in the Trash with its data still in place.
        if stopped, finished > 0 {
            error = L("已停止，这一项只做了一部分（\(finished) 步）", "stopped; only part of this item was done (\(finished) steps)")
        }
        if erased > 0 { detail.append(L("清除了 \(erased) 条记录", "erased \(erased) records")) }
        if let error { detail.append(error) }
        return finish(item, error == nil ? .done : stopped ? .stopped : .failed, Int64(after) - Int64(before),
                      error ?? "", before: before, after: after, detail: detail.joined(separator: "\n"))
    }

    private func halt() -> String {
        stopped = true
        return L("已停止", "stopped")
    }

    /// One action, unless the run was stopped; counts the steps that went through.
    func perform(_ a: ReclaimAction) -> String? {
        if isCancelled() { return halt() }
        let error = step(a)
        switch a {
        case .delete, .trash, .command, .erase: if error == nil { finished += 1 }
        default: break
        }
        return error
    }

    private func step(_ a: ReclaimAction) -> String? {
        switch a {
        case .delete(let p):
            log("  rm  " + Fmt.home(p))
            let rc = removefile(p, nil, removefile_flags_t(REMOVEFILE_RECURSIVE))
            return rc == 0 ? nil : "removefile: \(String(cString: strerror(errno)))"
        case .deleteAll(let ps):
            for p in ps where FileManager.default.fileExists(atPath: p) {
                if let e = perform(.delete(path: p)) { return e }
            }
            return nil
        case .trash(let p):
            log("  trash  " + Fmt.home(p))
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
                return nil
            } catch {
                // An app installed by the App Store or an installer belongs to root: Finder moves it,
                // asking for an administrator's password as when you drag it to the Trash.
                guard p.hasSuffix(".app") else { return "\(error.localizedDescription)" }
                log("  finder  " + Fmt.home(p))
                let waiting = L("正在请访达把它移到废纸篓：访达可能会要管理员密码，或者先问要不要允许控制访达",
                                "Asking Finder to move it to the Trash: Finder may ask for an administrator password, or first for permission to control Finder")
                if let note { note(waiting) } else { log("  " + waiting) }
                // Two minutes to answer Finder: after that nobody is at the dialog.
                let r = Shell.run(["osascript", "-e", "on run argv", "-e",
                                   "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)",
                                   "-e", "end run", p], timeout: 120, isCancelled: isCancelled)
                if r.ok, !Self.exists(p) { return nil }
                if isCancelled() { return halt() }
                return L("\(error.localizedDescription)；交给访达也没成功，可以在访达里把它拖到废纸篓",
                         "\(error.localizedDescription); Finder couldn't move it either. Drag it to the Trash in Finder")
            }
        case .command(let argv, let cwd):
            log("  $ " + argv.joined(separator: " "))
            // If a uv starts after the check above, give up on its lock in 30 s rather than 5 minutes.
            let env = Self.lockingTools.contains((argv[0] as NSString).lastPathComponent) ? ["UV_LOCK_TIMEOUT": "30"] : [:]
            let r = Shell.run(argv, cwd: cwd, timeout: 3600, stream: true, env: env, isCancelled: isCancelled)
            if !r.ok, isCancelled() { return halt() }
            return r.ok ? nil : "exit \(r.status): \(r.stderr.suffix(400).trimmingCharacters(in: .whitespacesAndNewlines))"
        case .erase(let db, let sql):
            log("  erase  " + Fmt.home(db))
            do {
                erased += try ForeignDB.erase(db, statements: sql)
                return nil
            } catch let e as ForeignDB.Failure {
                return e.description
            } catch {
                return "\(error)"
            }
        case .compound(let acts):
            for x in acts { if let e = perform(x) { return e } }
            return nil
        case .none:
            return L("这一项只提供指引", "guide-only item")
        }
    }

    func venvSnapshot(_ venv: String) -> String {
        var out = "venv " + venv + "\n"
        if let cfg = try? String(contentsOfFile: venv + "/pyvenv.cfg", encoding: .utf8) { out += cfg }
        let py = venv + "/bin/python"
        var r = Shell.run(["uv", "pip", "freeze", "--python", py], timeout: 60)
        if !r.ok { r = Shell.run([py, "-m", "pip", "freeze"], timeout: 60) }
        if r.ok { out += "--- freeze\n" + r.stdout }
        return out
    }

    func finish(_ item: ReclaimItem, _ status: Status, _ freed: Int64, _ msg: String,
                before: UInt64, after: UInt64, detail: String = "") -> Outcome {
        let actionName: String
        var command: String?
        switch item.action {
        case .delete, .deleteAll: actionName = "delete"
        case .trash: actionName = "trash"
        case .erase: actionName = "erase"
        case .command(let argv, _): actionName = "command"; command = argv.joined(separator: " ")
        case .compound(let acts):
            actionName = item.app != nil && item.action.isTrashOnly ? "uninstall" : "compound"
            command = Self.commands(.compound(actions: acts)).map { $0.joined(separator: " ") }.first
        case .none: actionName = "none"
        }
        try? store?.run("""
            INSERT INTO journal(ts, action, item_id, path, command, estimated, free_before, free_after, restore, status, detail)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [.real(Date().timeIntervalSince1970), .text(actionName), .text(item.id), .text(item.path), .text(command),
                  .int(Int64(item.estimate)), .int(Int64(before)), .int(Int64(after)), .text(item.restore),
                  .text(status.rawValue), .text(detail.isEmpty ? msg : detail)])
        return Outcome(item: item, status: status, freed: freed, message: msg)
    }
}
