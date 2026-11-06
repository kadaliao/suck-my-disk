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

    public enum Status: String, Sendable { case done, skipped, failed }

    let store: Store?
    let force: Bool
    let chosen: Set<String>
    let log: (String) -> Void

    /// `force` lifts the 7-day rule for every item. `chosen` holds the items the person picked
    /// themselves: the regenerable ones among them skip the rule too, since they asked for it and
    /// nothing is lost that can't be rebuilt. Preselected items keep it, so anything that changed
    /// after the scan is left alone.
    public init(store: Store?, force: Bool = false, chosen: Set<String> = [],
                log: @escaping (String) -> Void = { print($0) }) {
        self.store = store
        self.force = force
        self.chosen = chosen
        self.log = log
    }

    public func run(_ items: [ReclaimItem]) -> [Outcome] {
        items.map(runOne)
    }

    /// Paths an action would remove.
    static func paths(_ a: ReclaimAction) -> [String] {
        switch a {
        case .delete(let p), .trash(let p): return [p]
        case .deleteAll(let ps): return ps
        case .compound(let acts): return acts.flatMap(paths)
        case .command, .none: return []
        }
    }

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
        if Guards.hasTrackedFiles(path) { return L("里面有 git 跟踪的文件", "contains git-tracked files") }
        // Fails closed, like the git check.
        guard let programs else { return L("没法确认有没有程序在用", "can't tell whether a program is using it") }
        if let p = Guards.program(using: path, in: programs) {
            return L("\(p.summary)（PID \(p.pid)）正在用", "in use by \(p.summary) (PID \(p.pid))")
        }
        if !recentOK, let d = Guards.recentChange(path) { return Guards.waitNote(changed: d) }
        return nil
    }

    func runOne(_ item: ReclaimItem) -> Outcome {
        let paths = Self.paths(item.action), argvs = Self.commands(item.action)
        let programs = paths.isEmpty && argvs.isEmpty ? [] : Guards.runningPrograms()
        let recentOK = force || (item.tier == .regenerable && chosen.contains(item.id))
        for p in paths {
            if let why = check(p, programs: programs, recentOK: recentOK) {
                return finish(item, .skipped, 0, "\(Fmt.home(p)): \(why)", before: 0, after: 0)
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
        let error = perform(item.action)
        let after = VolumeInfo.freeBytes(disk)
        if let error { detail.append(error) }
        return finish(item, error == nil ? .done : .failed, Int64(after) - Int64(before),
                      error ?? "", before: before, after: after, detail: detail.joined(separator: "\n"))
    }

    func perform(_ a: ReclaimAction) -> String? {
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
            } catch { return "\(error.localizedDescription)" }
        case .command(let argv, let cwd):
            log("  $ " + argv.joined(separator: " "))
            // If a uv starts after the check above, give up on its lock in 30 s rather than 5 minutes.
            let env = Self.lockingTools.contains((argv[0] as NSString).lastPathComponent) ? ["UV_LOCK_TIMEOUT": "30"] : [:]
            let r = Shell.run(argv, cwd: cwd, timeout: 3600, stream: true, env: env)
            return r.ok ? nil : "exit \(r.status): \(r.stderr.suffix(400).trimmingCharacters(in: .whitespacesAndNewlines))"
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
        case .command(let argv, _): actionName = "command"; command = argv.joined(separator: " ")
        case .compound: actionName = "compound"
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
