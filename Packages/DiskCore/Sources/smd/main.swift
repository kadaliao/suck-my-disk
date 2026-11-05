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
//   smd things [disk] [--rescan] [--json] what is using space and what can be reclaimed
//   smd reclaim [disk] [--select 1,2] [--add 3] [--remove 4] [--yes] [--force]
//                                        disk: an external disk's mount point, /Volumes/<name>
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

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func fmtCount(_ n: UInt64) -> String {
    if n >= 10_000 { return Fmt.isChinese ? String(format: "%.0f 万", Double(n) / 1e4) : String(format: "%.1fM", Double(n) / 1e6) }
    return "\(n)"
}

func scanWithProgress(_ roots: [String], threads: Int = 0) -> ScanTree? {
    var o = ScanOptions.respectingPrivacy()
    o.threads = threads
    let start = Date()
    let isTTY = isatty(STDERR_FILENO) != 0
    let tree = ScanTree.scan(roots: roots, options: o) { p in
        guard isTTY else { return }
        let t = Date().timeIntervalSince(start)
        err("\u{1B}[2K\r" + L("扫描中 \(fmtCount(p.files)) 个文件 · \(Fmt.bytes(p.bytes)) · \(String(format: "%.0f", t)) 秒",
                              "Scanning \(fmtCount(p.files)) files · \(Fmt.bytes(p.bytes)) · \(String(format: "%.0f", t))s") + "\u{1B}[1A")
    }
    if isTTY { err("\u{1B}[2K\r") }
    return tree
}

func fullScan() -> ScanTree? {
    // Events from here on are replayed next time, so changes made during the scan are not lost.
    let startID = DiskWatcher.currentEventID
    let tree = scanWithProgress([Firmlinks.dataRoot])
    if let tree {
        LiveIndex.stamp(tree, startedAt: startID)
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

func ageText(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    if m < 60 { return L("\(m) 分钟前", "\(m) min ago") }
    if m < 48 * 60 { return L("\(m / 60) 小时前", "\(m / 60) h ago") }
    return L("\(m / 1440) 天前", "\(m / 1440) days ago")
}

/// Loads the saved index and brings it up to date from FSEvents; scans if that is not possible.
func loadTree(maxAge: TimeInterval = 3600, rescan: Bool = false) -> ScanTree? {
    if !rescan, let t = try? ScanTree.load(from: indexURL) {
        let age = Date().timeIntervalSince1970 - t.stats.created_at
        if LiveIndex.canResume(t) {
            let start = Date()
            switch LiveIndex.catchUp(t) {
            case .current(let changed):
                err(L("索引（\(ageText(age))）已按文件系统事件更新 \(changed) 处，用时 \(String(format: "%.1f", Date().timeIntervalSince(start))) 秒",
                      "Index from \(ageText(age)) caught up with \(changed) changes in \(String(format: "%.1f", Date().timeIntervalSince(start)))s"))
                try? t.save(to: indexURL)
                return t
            case .needsRescan(let why):
                err(L("索引没法增量更新（\(why)），重新扫描", "Cannot update the index incrementally (\(why)); rescanning"))
                return fullScan()
            }
        }
        if age < maxAge {
            err(L("使用 \(Int(age / 60)) 分钟前的索引（--rescan 重新扫描）", "Using the index from \(Int(age / 60)) min ago (--rescan to refresh)"))
            return t
        }
    }
    return fullScan()
}


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

func printReport(_ report: Report, verbose: Bool, disk: ExternalVolume? = nil) {
    let used = report.volumeTotal - report.volumeFree
    print(L("磁盘 \(Fmt.bytes(report.volumeTotal)) · 已用 \(Fmt.bytes(used)) · 可用 \(Fmt.bytes(report.volumeFree))",
            "Disk \(Fmt.bytes(report.volumeTotal)) · used \(Fmt.bytes(used)) · free \(Fmt.bytes(report.volumeFree))"))
    let plan = Planner.plan(things: report.things, selected: nil)
    print(L("预选可腾出 ≈ \(Fmt.bytes(plan.freed))（\(plan.items.count) 项，按共享数据实算）",
            "Preselected to free ≈ \(Fmt.bytes(plan.freed)) (\(plan.items.count) items, shared data accounted)"))
    print("")
    let numbered = numberItems(report)
    let numberOf = Dictionary(numbered.map { ($0.item.id + "|" + $0.thing.id, $0.number) }, uniquingKeysWith: { a, _ in a })
    for kind in ThingKind.allCases {
        let things = report.things.filter { $0.kind == kind }
        guard !things.isEmpty else { continue }
        let total = things.reduce(UInt64(0)) { $0 + $1.reclaimable }
        print("━━ \(kind.title)" + (total > 0 ? L("  可腾出 \(Fmt.bytes(total))", "  reclaimable \(Fmt.bytes(total))") : ""))
        let shown = verbose ? things : Array(things.prefix(kind == .project ? 15 : 10))
        for t in shown {
            var head = "  \(t.title)  \(Fmt.bytes(t.bytes))"
            if let d = t.lastActive { head += "  · " + L("活跃于 \(Fmt.ago(d))", "active \(Fmt.ago(d))") + (t.activitySource.map { "（\($0)）" } ?? "") }
            if let p = t.path { head += "  " + Fmt.home(p) }
            print(head)
            if let d = t.detail { print("     " + d) }
            let items = verbose ? t.items : Array(t.items.prefix(6))
            for i in items {
                let num = numberOf[i.id + "|" + t.id].map { String(format: "%3d", $0) } ?? "   "
                let box = i.tier == .guide ? "   " : (i.preselected ? "[x]" : "[ ]")
                var line = "    \(num) \(box) \(tierMark[i.tier]!) \(i.label)  \(Fmt.bytes(i.estimate))\(i.estimateIsLowerBound ? "+" : "")"
                if i.estimate != i.bytes, i.tier != .guide { line += L("（占用 \(Fmt.bytes(i.bytes))）", " (occupies \(Fmt.bytes(i.bytes)))") }
                if let p = i.path, i.label != t.title, !(t.path.map { p == $0 } ?? false) { line += "  " + Fmt.home(p) }
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
    let reclaim = "smd reclaim" + (disk.map { " " + shellQuote($0.path) } ?? "")
    print(L("下一步：\(reclaim)（先预演）· \(reclaim) --add 12 --remove 3 · 确认后加 --yes",
            "Next: \(reclaim) (dry run) · \(reclaim) --add 12 --remove 3 · add --yes to run"))
    if disk == nil {
        for v in ExternalVolumes.list() {
            print(L("外接磁盘 \(v.name)：smd things \(shellQuote(v.path))", "External disk \(v.name): smd things \(shellQuote(v.path))"))
        }
    }
}

func shellQuote(_ s: String) -> String {
    s.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The external disk named by the first argument (its mount point), if any.
func externalDisk() -> ExternalVolume? {
    guard let p = args.positional.first else { return nil }
    let path = ((p as NSString).expandingTildeInPath as NSString).standardizingPath
    guard let v = ExternalVolumes.list().first(where: { $0.path == path }) else {
        err(L("\(p) 不是已挂载的外接磁盘", "\(p) is not a mounted external disk"))
        exit(2)
    }
    return v
}

/// Scans an external disk (or reuses its index from the last hour) and recognizes what is on it.
func externalReport(_ v: ExternalVolume, rescan: Bool) async -> Report? {
    let url = AppPaths.indexURL(volumeUUID: v.uuid)
    var tree: ScanTree?
    if !rescan, let t = ReportStore.loadIndex(from: url) {
        let age = Date().timeIntervalSince1970 - t.stats.created_at
        if age < 3600 {
            err(L("使用 \(Int(age / 60)) 分钟前的索引（--rescan 重新扫描）", "Using the index from \(Int(age / 60)) min ago (--rescan to refresh)"))
            tree = t
        }
    }
    if tree == nil {
        tree = scanWithProgress([v.path])
        if let tree { try? ReportStore.saveIndex(tree, to: url) }
    }
    guard let tree else { return nil }
    let days = Int(args.values["days"] ?? "") ?? 30
    let report = await Recognize.external(tree: tree, volume: v, sleepAfterDays: days) { err($0) }
    ReportStore.save(report, to: ReportStore.reportURL(volume: v.uuid))
    return report
}

func makeReport(rescan: Bool) async -> Report? {
    guard let tree = loadTree(rescan: rescan) else { return nil }
    let days = Int(args.values["days"] ?? "") ?? 30
    let report = await Recognize.all(tree: tree, sleepAfterDays: days, skip: Privacy.rootsToSkip()) { err($0) }
    ReportStore.save(report)
    ReportStore.writeHistory(report)
    return report
}

func currentReport() async -> Report? {
    if !args.has("rescan"), let r = ReportStore.load(), Date().timeIntervalSince(r.createdAt) < 3600 { return r }
    return await makeReport(rescan: args.has("rescan"))
}

func runPlan(_ items: [ReclaimItem], execute: Bool, disk: ExternalVolume? = nil) {
    let total = items.reduce(UInt64(0)) { $0 + $1.estimate }
    print(L("计划腾出 ≈ \(Fmt.bytes(total))，共 \(items.count) 项：", "Plan frees ≈ \(Fmt.bytes(total)) in \(items.count) items:"))
    for i in items {
        let how: String
        switch i.action {
        case .delete, .deleteAll: how = L("删除", "delete")
        case .trash: how = L("废纸篓", "trash")
        case .command(let argv, _): how = "$ " + argv.joined(separator: " ")
        case .compound: how = L("组合", "combined")
        case .none: how = "-"
        }
        print("  \(tierMark[i.tier]!) \(i.label)  \(Fmt.bytes(i.estimate))  [\(how)]" + (i.path.map { "  " + Fmt.home($0) } ?? ""))
    }
    guard execute else {
        print("")
        print(L("这是预演，什么都没删。确认无误后加 --yes 执行。", "Dry run: nothing was deleted. Add --yes to run it."))
        return
    }
    print("")
    let store = try? Store()
    let ex = Executor(store: store, force: args.has("force"))
    let mount = disk?.path ?? Firmlinks.dataRoot
    let before = VolumeInfo.freeBytes(mount)
    var done = 0
    for o in ex.run(items) {
        switch o.status {
        case .done:
            done += 1
            print("  ✓ \(o.item.label)  " + L("实际腾出 \(Fmt.bytes(UInt64(max(0, o.freed))))", "freed \(Fmt.bytes(UInt64(max(0, o.freed))))"))
        case .skipped: print("  – \(o.item.label)  " + L("跳过：", "skipped: ") + o.message)
        case .failed: print("  ✗ \(o.item.label)  " + L("失败：", "failed: ") + o.message)
        }
    }
    let after = VolumeInfo.freeBytes(mount)
    print("")
    print(L("完成 \(done)/\(items.count) 项，可用空间 \(Fmt.bytes(before)) → \(Fmt.bytes(after))（+\(Fmt.bytes(after > before ? after - before : 0))）",
            "Done \(done)/\(items.count). Free space \(Fmt.bytes(before)) → \(Fmt.bytes(after)) (+\(Fmt.bytes(after > before ? after - before : 0)))"))
    ReportStore.invalidate()   // the index catches up from FSEvents next time
}

// MARK: commands

switch command {
case "scan":
    let roots = args.positional.isEmpty ? [Firmlinks.dataRoot] : args.positional.map { ($0 as NSString).expandingTildeInPath }
    let tree: ScanTree?
    if args.positional.isEmpty { tree = fullScan() } else { tree = scanWithProgress(roots, threads: Int(args.values["threads"] ?? "") ?? 0) }
    guard let tree else { exit(1) }
    let s = tree.stats
    print(L("合计 \(Fmt.bytes(tree.uniqueTotal))（克隆和硬链接只算一次；其中共享数据 \(Fmt.bytes(s.shared_unique))）",
            "Total \(Fmt.bytes(tree.uniqueTotal)) (clones and hard links counted once; \(Fmt.bytes(s.shared_unique)) shared)"))
    print(L("\(fmtCount(s.files)) 个文件 · \(fmtCount(s.dirs)) 个目录 · \(String(format: "%.1f", s.scan_seconds)) 秒 · \(s.threads) 线程 · \(s.denied_dirs) 个目录无权限",
            "\(fmtCount(s.files)) files · \(fmtCount(s.dirs)) folders · \(String(format: "%.1f", s.scan_seconds))s · \(s.threads) threads · \(s.denied_dirs) unreadable"))
    if args.positional.isEmpty {
        let hidden = volume.dataUsed > tree.uniqueTotal ? volume.dataUsed - tree.uniqueTotal : 0
        print(L("数据卷已用 \(Fmt.bytes(volume.dataUsed))，扫描不到 \(Fmt.bytes(hidden))（快照、无权限目录）；系统卷和虚拟内存另占 \(Fmt.bytes(volume.otherVolumes))",
                "Data volume used \(Fmt.bytes(volume.dataUsed)); \(Fmt.bytes(hidden)) not visible (snapshots, unreadable); system & VM volumes use \(Fmt.bytes(volume.otherVolumes))"))
    }

case "top":
    guard let tree = loadTree(maxAge: .infinity) else { exit(1) }
    let target = args.positional.first.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
    guard let node = tree.find(target) else { err(L("索引里没有这个路径：\(target)", "Not in the index: \(target)")); exit(1) }
    let n = Int(args.values["n"] ?? "") ?? 25
    print("\(Fmt.home(tree.path(node)))  \(Fmt.bytes(tree.size(node)))")
    for c in tree.sortedChildren(node).prefix(n) {
        let x = tree.node(c).pointee
        var tags: [String] = []
        if x.flags & SM_F_COLLAPSED != 0 { tags.append(L("整体", "folded")) }
        if x.flags & SM_F_MOUNTPOINT != 0 { tags.append(L("其他卷", "other volume")) }
        if x.flags & SM_F_DENIED != 0 { tags.append(L("无权限", "unreadable")) }
        if x.flags & SM_F_SPARSE != 0 { tags.append(L("稀疏", "sparse")) }
        if x.t_shared > 0 { tags.append(L("共享 \(Fmt.bytes(x.t_shared))", "shared \(Fmt.bytes(x.t_shared))")) }
        let name = tree.name(c) + (x.flags & SM_F_DIR != 0 ? "/" : "")
        print(String(format: "  %10@  ", Fmt.bytes(tree.size(c))) + name + (tags.isEmpty ? "" : "  [" + tags.joined(separator: ", ") + "]"))
    }

case "things":
    let disk = externalDisk()
    let made = if let disk { await externalReport(disk, rescan: args.has("rescan")) } else { await makeReport(rescan: args.has("rescan")) }
    guard let report = made else { exit(1) }
    if args.has("json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        print(String(decoding: try! enc.encode(report), as: UTF8.self))
    } else {
        printReport(report, verbose: args.has("v"), disk: disk)
    }

case "reclaim":
    let disk = externalDisk()
    let current: Report?
    if let disk {
        let saved = args.has("rescan") ? nil : ReportStore.load(from: ReportStore.reportURL(volume: disk.uuid))
        current = if let saved, Date().timeIntervalSince(saved.createdAt) < 3600 { saved } else { await externalReport(disk, rescan: args.has("rescan")) }
    } else {
        current = await currentReport()
    }
    guard let report = current else { exit(1) }
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
    runPlan(plan.items, execute: args.has("yes"), disk: disk)

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
        if seen.insert(dir + restore).inserted { print("cd \(Fmt.home(dir)) && \(restore)") }
    }

case "journal":
    let store = try Store()
    let rows = try store.query("SELECT ts, status, action, item_id, estimated, free_before, free_after, restore FROM journal ORDER BY ts DESC LIMIT 50")
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    for r in rows {
        let freed = r[6].int - r[5].int
        print("\(f.string(from: Date(timeIntervalSince1970: r[0].real)))  \(r[1].text ?? "")  \(r[2].text ?? "")  \(Fmt.bytes(UInt64(max(0, freed))))  \(Fmt.home(r[3].text ?? ""))")
    }

case "bench":
    let root = args.positional.first.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory() + "/workspace"
    for t in [4, 8, 16, 32] {
        var o = ScanOptions()
        o.threads = t
        guard let tree = ScanTree.scan(roots: [root], options: o) else { continue }
        let s = tree.stats
        print(String(format: "threads=%2d  %.2fs  %@ files  %.0f files/s  total %@", t, s.scan_seconds, fmtCount(s.files),
                     Double(s.files) / s.scan_seconds, Fmt.bytes(tree.uniqueTotal)))
    }

default:
    print("""
    smd — SuckMyDisk

      smd things [--rescan] [-v] [--json] [--days 30]   \(L("看看空间被谁占了、能腾出多少", "what uses space and what can go"))
      smd reclaim [--add 3,5] [--remove 2] [--yes]      \(L("按预选清理（默认只预演）", "reclaim the preselection (dry run by default)"))
      smd things /Volumes/<disk>                        \(L("外接磁盘上的项目和渲染帧", "projects and render frames on an external disk"))
      smd reclaim /Volumes/<disk> [--yes]               \(L("清理外接磁盘上的预选项", "reclaim the preselection on an external disk"))
      smd hibernate <project> [--yes]                   \(L("让一个项目休眠", "hibernate one project"))
      smd wake <project>                                \(L("显示恢复命令", "show restore commands"))
      smd scan [paths…]                                 \(L("全盘扫描并保存索引", "full scan, saves the index"))
      smd top [path] [-n 25]                            \(L("某个目录下最大的东西", "biggest items under a path"))
      smd journal                                       \(L("清理记录", "what was done"))
      smd bench [path]                                  \(L("扫描速度测试", "scanner benchmark"))
    """)
}
