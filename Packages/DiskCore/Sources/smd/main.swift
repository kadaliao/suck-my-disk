import CFastScan
import DiskIndex
import Foundation
import Insights
import Recognizers
import Reclaim

// smd — SuckMyDisk command line.
//
//   smd scan [paths…] [--threads N]      full scan (default: whole data volume), saves the index
//   smd top [path] [-n N]                biggest items under a path, from the index
//   smd things [--rescan] [--json]       what is using space and what can be reclaimed
//   smd reclaim [--select 1,2] [--add 3] [--remove 4] [--yes] [--force]
//   smd hibernate <project> [--yes]      delete a project's rebuildable artifacts
//   smd wake <project>                   show how to restore a hibernated project
//   smd journal                          what was done
//   smd bench [path]                     scanner speed by thread count

setvbuf(stdout, nil, _IOLBF, 0)

struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("-") {
                let key = a.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                let takesValue = ["threads", "n", "select", "add", "remove", "days"].contains(key)
                if takesValue, i + 1 < argv.count { values[key] = argv[i + 1]; i += 1 } else { flags.insert(key) }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func has(_ f: String) -> Bool { flags.contains(f) }
    func ints(_ k: String) -> [Int] { values[k]?.split(separator: ",").compactMap { Int($0) } ?? [] }
}

let argv = Array(CommandLine.arguments.dropFirst())
let command = argv.first ?? "help"
let args = Args(Array(argv.dropFirst()))
let volume = VolumeInfo.of()
let indexURL = AppPaths.indexURL(volumeUUID: volume.uuid)
let reportURL = AppPaths.supportDir.appendingPathComponent("last-report.json")

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func fmtCount(_ n: UInt64) -> String {
    if n >= 10_000 { return Text.isChinese ? String(format: "%.0f 万", Double(n) / 1e4) : String(format: "%.1fM", Double(n) / 1e6) }
    return "\(n)"
}

func scanWithProgress(_ roots: [String], threads: Int = 0) -> ScanTree? {
    var o = ScanOptions()
    o.threads = threads
    let start = Date()
    let isTTY = isatty(STDERR_FILENO) != 0
    let tree = ScanTree.scan(roots: roots, options: o) { p in
        guard isTTY else { return }
        let t = Date().timeIntervalSince(start)
        err("\u{1B}[2K\r" + L("扫描中 \(fmtCount(p.files)) 个文件 · \(Text.bytes(p.bytes)) · \(String(format: "%.0f", t)) 秒",
                              "Scanning \(fmtCount(p.files)) files · \(Text.bytes(p.bytes)) · \(String(format: "%.0f", t))s") + "\u{1B}[1A")
    }
    if isTTY { err("\u{1B}[2K\r") }
    return tree
}

func fullScan() -> ScanTree? {
    let tree = scanWithProgress([Firmlinks.dataRoot])
    if let tree {
        let s = tree.stats
        err(L("扫描完成：\(fmtCount(s.files)) 个文件，\(fmtCount(s.dirs)) 个目录，\(String(format: "%.1f", s.scan_seconds)) 秒",
              "Scanned \(fmtCount(s.files)) files, \(fmtCount(s.dirs)) folders in \(String(format: "%.1f", s.scan_seconds))s"))
        do {
            try AppPaths.ensure()
            try tree.save(to: indexURL)
        } catch {
            err(L("索引没能保存：\(error)", "Could not save the index: \(error)"))
        }
    }
    return tree
}

/// Loads the saved index if it is recent enough, otherwise scans.
func loadTree(maxAge: TimeInterval = 3600, rescan: Bool = false) -> ScanTree? {
    if !rescan, let t = try? ScanTree.load(from: indexURL) {
        let age = Date().timeIntervalSince1970 - t.stats.created_at
        if age < maxAge {
            err(L("使用 \(Int(age / 60)) 分钟前的索引（--rescan 重新扫描）", "Using the index from \(Int(age / 60)) min ago (--rescan to refresh)"))
            return t
        }
    }
    return fullScan()
}

func invalidateIndex() { try? FileManager.default.removeItem(at: indexURL) }

// MARK: printing

let tierMark: [Tier: String] = [.lossless: "◆", .regenerable: "●", .yours: "○", .guide: "·"]

struct Numbered {
    var number: Int
    var item: ReclaimItem
    var thing: Thing
}

func numberItems(_ report: Report) -> [Numbered] {
    var out: [Numbered] = []
    var n = 1
    for t in report.things {
        for i in t.items where i.tier < .guide {
            out.append(Numbered(number: n, item: i, thing: t))
            n += 1
        }
    }
    return out
}

func printReport(_ report: Report, verbose: Bool) {
    let used = report.volumeTotal - report.volumeFree
    print(L("磁盘 \(Text.bytes(report.volumeTotal)) · 已用 \(Text.bytes(used)) · 可用 \(Text.bytes(report.volumeFree))",
            "Disk \(Text.bytes(report.volumeTotal)) · used \(Text.bytes(used)) · free \(Text.bytes(report.volumeFree))"))
    let plan = Planner.plan(things: report.things, selected: nil)
    print(L("预选可腾出 ≈ \(Text.bytes(plan.freed))（\(plan.items.count) 项，按共享数据实算）",
            "Preselected to free ≈ \(Text.bytes(plan.freed)) (\(plan.items.count) items, shared data accounted)"))
    print("")
    let numbered = numberItems(report)
    let numberOf = Dictionary(numbered.map { ($0.item.id + "|" + $0.thing.id, $0.number) }, uniquingKeysWith: { a, _ in a })
    for kind in ThingKind.allCases {
        let things = report.things.filter { $0.kind == kind }
        guard !things.isEmpty else { continue }
        let total = things.reduce(UInt64(0)) { $0 + $1.reclaimable }
        print("━━ \(kind.title)" + (total > 0 ? L("  可腾出 \(Text.bytes(total))", "  reclaimable \(Text.bytes(total))") : ""))
        let shown = verbose ? things : Array(things.prefix(kind == .project ? 15 : 10))
        for t in shown {
            var head = "  \(t.title)  \(Text.bytes(t.bytes))"
            if let d = t.lastActive { head += "  · " + L("活跃于 \(Text.ago(d))", "active \(Text.ago(d))") + (t.activitySource.map { "（\($0)）" } ?? "") }
            if let p = t.path { head += "  " + Text.home(p) }
            print(head)
            if let d = t.detail { print("     " + d) }
            let items = verbose ? t.items : Array(t.items.prefix(6))
            for i in items {
                let num = numberOf[i.id + "|" + t.id].map { String(format: "%3d", $0) } ?? "   "
                let box = i.tier == .guide ? "   " : (i.preselected ? "[x]" : "[ ]")
                var line = "    \(num) \(box) \(tierMark[i.tier]!) \(i.label)  \(Text.bytes(i.estimate))\(i.estimateIsLowerBound ? "+" : "")"
                if i.estimate != i.bytes, i.tier != .guide { line += L("（占用 \(Text.bytes(i.bytes))）", " (occupies \(Text.bytes(i.bytes)))") }
                if let p = i.path, i.label != t.title, !(t.path.map { p == $0 } ?? false) { line += "  " + Text.home(p) }
                print(line)
                if verbose || i.tier != .guide { print("          " + i.reason + (i.restore.map { L("  · 恢复：", "  · restore: ") + $0 } ?? "")) }
                for w in i.warnings { print("          ⚠ " + w) }
            }
            if t.items.count > items.count { print(L("        … 还有 \(t.items.count - items.count) 项（-v 查看全部）", "        … \(t.items.count - items.count) more (-v)")) }
        }
        if things.count > shown.count { print(L("  … 还有 \(things.count - shown.count) 个（-v 查看全部）", "  … \(things.count - shown.count) more (-v)")) }
        print("")
    }
    print(L("● 可再生，直接删除并记录恢复方法   ○ 你的文件，移到废纸篓   [x] 预选",
            "● regenerable, deleted with a restore note   ○ yours, moved to the Trash   [x] preselected"))
    print(L("下一步：smd reclaim（先预演）· smd reclaim --add 12 --remove 3 · 确认后加 --yes",
            "Next: smd reclaim (dry run) · smd reclaim --add 12 --remove 3 · add --yes to run"))
}

func saveReport(_ r: Report) {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .secondsSince1970
    if let d = try? enc.encode(r) { try? d.write(to: reportURL, options: .atomic) }
}

func loadReport() -> Report? {
    guard let d = try? Data(contentsOf: reportURL) else { return nil }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .secondsSince1970
    return try? dec.decode(Report.self, from: d)
}

func writeHistory(_ r: Report) {
    guard let store = try? Store() else { return }
    let day = Store.today()
    for t in r.things where t.bytes > 0 {
        try? store.run("INSERT OR REPLACE INTO history(day, thing_id, kind, title, bytes, reclaimable) VALUES(?,?,?,?,?,?)",
                       [.text(day), .text(t.id), .text(t.kind.rawValue), .text(t.title), .int(Int64(t.bytes)), .int(Int64(t.reclaimable))])
    }
    try? store.run("INSERT OR REPLACE INTO volume_history(day, used, free, scanned) VALUES(?,?,?,?)",
                   [.text(day), .int(Int64(r.volumeTotal - r.volumeFree)), .int(Int64(r.volumeFree)), .int(Int64(r.scanned))])
}

func makeReport(rescan: Bool) async -> Report? {
    guard let tree = loadTree(rescan: rescan) else { return nil }
    let days = Int(args.values["days"] ?? "") ?? 30
    let report = await Recognize.all(tree: tree, sleepAfterDays: days) { err($0) }
    saveReport(report)
    writeHistory(report)
    return report
}

func currentReport() async -> Report? {
    if !args.has("rescan"), let r = loadReport(), Date().timeIntervalSince(r.createdAt) < 3600 { return r }
    return await makeReport(rescan: args.has("rescan"))
}

func runPlan(_ items: [ReclaimItem], execute: Bool) {
    let total = items.reduce(UInt64(0)) { $0 + $1.estimate }
    print(L("计划腾出 ≈ \(Text.bytes(total))，共 \(items.count) 项：", "Plan frees ≈ \(Text.bytes(total)) in \(items.count) items:"))
    for i in items {
        let how: String
        switch i.action {
        case .delete, .deleteAll: how = L("删除", "delete")
        case .trash: how = L("废纸篓", "trash")
        case .command(let argv, _): how = "$ " + argv.joined(separator: " ")
        case .compound: how = L("组合", "combined")
        case .none: how = "-"
        }
        print("  \(tierMark[i.tier]!) \(i.label)  \(Text.bytes(i.estimate))  [\(how)]" + (i.path.map { "  " + Text.home($0) } ?? ""))
    }
    guard execute else {
        print("")
        print(L("这是预演，什么都没删。确认无误后加 --yes 执行。", "Dry run: nothing was deleted. Add --yes to run it."))
        return
    }
    print("")
    let store = try? Store()
    let ex = Executor(store: store, force: args.has("force"))
    let before = VolumeInfo.freeBytes()
    var done = 0
    for o in ex.run(items) {
        switch o.status {
        case .done:
            done += 1
            print("  ✓ \(o.item.label)  " + L("实际腾出 \(Text.bytes(UInt64(max(0, o.freed))))", "freed \(Text.bytes(UInt64(max(0, o.freed))))"))
        case .skipped: print("  – \(o.item.label)  " + L("跳过：", "skipped: ") + o.message)
        case .failed: print("  ✗ \(o.item.label)  " + L("失败：", "failed: ") + o.message)
        }
    }
    let after = VolumeInfo.freeBytes()
    print("")
    print(L("完成 \(done)/\(items.count) 项，可用空间 \(Text.bytes(before)) → \(Text.bytes(after))（+\(Text.bytes(after > before ? after - before : 0))）",
            "Done \(done)/\(items.count). Free space \(Text.bytes(before)) → \(Text.bytes(after)) (+\(Text.bytes(after > before ? after - before : 0)))"))
    invalidateIndex()
    try? FileManager.default.removeItem(at: reportURL)
}

// MARK: commands

switch command {
case "scan":
    let roots = args.positional.isEmpty ? [Firmlinks.dataRoot] : args.positional.map { ($0 as NSString).expandingTildeInPath }
    let tree: ScanTree?
    if args.positional.isEmpty { tree = fullScan() } else { tree = scanWithProgress(roots, threads: Int(args.values["threads"] ?? "") ?? 0) }
    guard let tree else { exit(1) }
    let s = tree.stats
    print(L("合计 \(Text.bytes(tree.uniqueTotal))（克隆和硬链接只算一次；其中共享数据 \(Text.bytes(s.shared_unique))）",
            "Total \(Text.bytes(tree.uniqueTotal)) (clones and hard links counted once; \(Text.bytes(s.shared_unique)) shared)"))
    print(L("\(fmtCount(s.files)) 个文件 · \(fmtCount(s.dirs)) 个目录 · \(String(format: "%.1f", s.scan_seconds)) 秒 · \(s.threads) 线程 · \(s.denied_dirs) 个目录无权限",
            "\(fmtCount(s.files)) files · \(fmtCount(s.dirs)) folders · \(String(format: "%.1f", s.scan_seconds))s · \(s.threads) threads · \(s.denied_dirs) unreadable"))
    if args.positional.isEmpty {
        let hidden = volume.dataUsed > tree.uniqueTotal ? volume.dataUsed - tree.uniqueTotal : 0
        print(L("数据卷已用 \(Text.bytes(volume.dataUsed))，扫描不到 \(Text.bytes(hidden))（快照、无权限目录）；系统卷和虚拟内存另占 \(Text.bytes(volume.otherVolumes))",
                "Data volume used \(Text.bytes(volume.dataUsed)); \(Text.bytes(hidden)) not visible (snapshots, unreadable); system & VM volumes use \(Text.bytes(volume.otherVolumes))"))
    }

case "top":
    guard let tree = loadTree(maxAge: .infinity) else { exit(1) }
    let target = args.positional.first.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
    guard let node = tree.find(target) else { err(L("索引里没有这个路径：\(target)", "Not in the index: \(target)")); exit(1) }
    let n = Int(args.values["n"] ?? "") ?? 25
    print("\(Text.home(tree.path(node)))  \(Text.bytes(tree.size(node)))")
    for c in tree.sortedChildren(node).prefix(n) {
        let x = tree.node(c).pointee
        var tags: [String] = []
        if x.flags & SM_F_COLLAPSED != 0 { tags.append(L("整体", "folded")) }
        if x.flags & SM_F_MOUNTPOINT != 0 { tags.append(L("其他卷", "other volume")) }
        if x.flags & SM_F_DENIED != 0 { tags.append(L("无权限", "unreadable")) }
        if x.flags & SM_F_SPARSE != 0 { tags.append(L("稀疏", "sparse")) }
        if x.t_shared > 0 { tags.append(L("共享 \(Text.bytes(x.t_shared))", "shared \(Text.bytes(x.t_shared))")) }
        let name = tree.name(c) + (x.flags & SM_F_DIR != 0 ? "/" : "")
        print(String(format: "  %10@  ", Text.bytes(tree.size(c))) + name + (tags.isEmpty ? "" : "  [" + tags.joined(separator: ", ") + "]"))
    }

case "things":
    guard let report = await makeReport(rescan: args.has("rescan")) else { exit(1) }
    if args.has("json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        print(String(decoding: try! enc.encode(report), as: UTF8.self))
    } else {
        printReport(report, verbose: args.has("v"))
    }

case "reclaim":
    guard let report = await currentReport() else { exit(1) }
    let numbered = numberItems(report)
    var selected: Set<String>
    if let sel = args.values["select"] {
        let nums = Set(sel.split(separator: ",").compactMap { Int($0) })
        selected = Set(numbered.filter { nums.contains($0.number) }.map(\.item.id))
    } else {
        selected = Set(numbered.filter(\.item.preselected).map(\.item.id))
    }
    for n in args.ints("add") { if let x = numbered.first(where: { $0.number == n }) { selected.insert(x.item.id) } }
    for n in args.ints("remove") { if let x = numbered.first(where: { $0.number == n }) { selected.remove(x.item.id) } }
    let plan = Planner.plan(things: report.things, selected: selected)
    runPlan(plan.items, execute: args.has("yes"))

case "hibernate":
    guard let target = args.positional.first.map({ (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }) else {
        err("smd hibernate <project>"); exit(2)
    }
    guard let report = await currentReport() else { exit(1) }
    guard let project = report.things.first(where: { $0.kind == .project && $0.path == target }) else {
        err(L("没找到这个项目，或者它没有可再生的产物：\(target)", "No project with rebuildable artifacts at \(target)")); exit(1)
    }
    let items = project.items.filter { $0.tier == .regenerable }
    print(L("休眠 \(project.title)：删除可再生的产物，源码和 git 不动。", "Hibernating \(project.title): rebuildable artifacts only; source and git stay."))
    runPlan(items, execute: args.has("yes"))

case "wake":
    guard let target = args.positional.first.map({ (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }) else {
        err("smd wake <project>"); exit(2)
    }
    let store = try Store()
    let rows = try store.query("SELECT path, restore, ts FROM journal WHERE status='done' AND path LIKE ? ORDER BY ts", [.text(target + "%")])
    if rows.isEmpty { print(L("日志里没有这个项目的休眠记录。", "No hibernation records for this project.")) }
    var seen: Set<String> = []
    for r in rows {
        guard let p = r[0].text else { continue }
        let dir = (p as NSString).deletingLastPathComponent
        let restore = r[1].text ?? "-"
        if seen.insert(dir + restore).inserted { print("cd \(Text.home(dir)) && \(restore)") }
    }

case "journal":
    let store = try Store()
    let rows = try store.query("SELECT ts, status, action, item_id, estimated, free_before, free_after, restore FROM journal ORDER BY ts DESC LIMIT 50")
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    for r in rows {
        let freed = r[6].int - r[5].int
        print("\(f.string(from: Date(timeIntervalSince1970: r[0].real)))  \(r[1].text ?? "")  \(r[2].text ?? "")  \(Text.bytes(UInt64(max(0, freed))))  \(Text.home(r[3].text ?? ""))")
    }

case "bench":
    let root = args.positional.first.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory() + "/workspace"
    for t in [4, 8, 16, 32] {
        var o = ScanOptions()
        o.threads = t
        guard let tree = ScanTree.scan(roots: [root], options: o) else { continue }
        let s = tree.stats
        print(String(format: "threads=%2d  %.2fs  %@ files  %.0f files/s  total %@", t, s.scan_seconds, fmtCount(s.files),
                     Double(s.files) / s.scan_seconds, Text.bytes(tree.uniqueTotal)))
    }

default:
    print("""
    smd — SuckMyDisk

      smd things [--rescan] [-v] [--json] [--days 30]   \(L("看看空间被谁占了、能腾出多少", "what uses space and what can go"))
      smd reclaim [--add 3,5] [--remove 2] [--yes]      \(L("按预选清理（默认只预演）", "reclaim the preselection (dry run by default)"))
      smd hibernate <project> [--yes]                   \(L("让一个项目休眠", "hibernate one project"))
      smd wake <project>                                \(L("显示恢复命令", "show restore commands"))
      smd scan [paths…]                                 \(L("全盘扫描并保存索引", "full scan, saves the index"))
      smd top [path] [-n 25]                            \(L("某个目录下最大的东西", "biggest items under a path"))
      smd journal                                       \(L("清理记录", "what was done"))
      smd bench [path]                                  \(L("扫描速度测试", "scanner benchmark"))
    """)
}
