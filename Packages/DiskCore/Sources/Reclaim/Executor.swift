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
    let log: (String) -> Void

    public init(store: Store?, force: Bool = false, log: @escaping (String) -> Void = { print($0) }) {
        self.store = store
        self.force = force
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

    func check(_ path: String, isCommandTarget: Bool = false) -> String? {
        if Guards.isDenied(path) { return L("受保护的位置", "protected location") }
        var st = stat()
        guard lstat(path, &st) == 0 else { return L("已经不存在", "no longer exists") }
        if (st.st_mode & S_IFMT) == S_IFLNK { return L("是符号链接", "is a symlink") }
        if Guards.hasTrackedFiles(path) { return L("里面有 git 跟踪的文件", "contains git-tracked files") }
        if !force, let d = Guards.lastChange(path), Date().timeIntervalSince(d) < 7 * 86400 {
            return L("7 天内有改动（加 --force 可强制）", "changed in the last 7 days (use --force)")
        }
        return nil
    }

    func runOne(_ item: ReclaimItem) -> Outcome {
        for p in Self.paths(item.action) {
            if let why = check(p) {
                return finish(item, .skipped, 0, "\(Text.home(p)): \(why)", before: 0, after: 0)
            }
        }
        var detail: [String] = []
        // Record what a venv contained before it goes, so it can be rebuilt faithfully.
        for p in Self.paths(item.action) where FileManager.default.fileExists(atPath: p + "/pyvenv.cfg") {
            detail.append(venvSnapshot(p))
        }
        let before = VolumeInfo.freeBytes()
        let error = perform(item.action)
        let after = VolumeInfo.freeBytes()
        if let error { detail.append(error) }
        return finish(item, error == nil ? .done : .failed, Int64(after) - Int64(before),
                      error ?? "", before: before, after: after, detail: detail.joined(separator: "\n"))
    }

    func perform(_ a: ReclaimAction) -> String? {
        switch a {
        case .delete(let p):
            log("  rm  " + Text.home(p))
            let rc = removefile(p, nil, removefile_flags_t(REMOVEFILE_RECURSIVE))
            return rc == 0 ? nil : "removefile: \(String(cString: strerror(errno)))"
        case .deleteAll(let ps):
            for p in ps where FileManager.default.fileExists(atPath: p) {
                if let e = perform(.delete(path: p)) { return e }
            }
            return nil
        case .trash(let p):
            log("  trash  " + Text.home(p))
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
                return nil
            } catch { return "\(error.localizedDescription)" }
        case .command(let argv, let cwd):
            log("  $ " + argv.joined(separator: " "))
            let r = Shell.run(argv, cwd: cwd, timeout: 3600, stream: true)
            return r.ok ? nil : "exit \(r.status): \(r.stderr.suffix(400))"
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
