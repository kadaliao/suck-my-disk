import CFastScan
import DiskIndex
import Insights
import Foundation

/// Global developer caches. Wherever a tool has its own cleanup command we use
/// it, because the tool knows its internal references.
public enum DevCacheRecognizer {
    public static func recognize(_ ctx: RecognizeContext, venvs: [VenvRef], preselectedVenvIDs: Set<String>,
                                 log: (String) -> Void = { _ in }) -> [Thing] {
        var things: [Thing] = []
        let h = ctx.home
        if let t = uv(ctx, venvs: venvs, preselectedVenvIDs: preselectedVenvIDs, log: log) { things.append(t) }

        func simple(_ id: String, _ title: String, _ path: String, tool: String?, argv: [String]?,
                    reason: String, preselect: Bool, restore: String? = nil) {
            let bytes = ctx.size(path)
            guard bytes >= 50_000_000 else { return }
            let action: ReclaimAction
            if let argv, let tool, Shell.which(tool) != nil { action = .command(argv: argv, cwd: nil) }
            else { action = .delete(path: path) }
            things.append(Thing(id: "cache:" + id, kind: .devCache, title: title, path: path, bytes: bytes, items: [
                ReclaimItem(id: "cache:" + id, label: title, path: path, bytes: bytes, tier: .regenerable,
                            action: action, restore: restore, reason: reason, preselected: preselect),
            ]))
        }
        simple("npm", "npm cache", h + "/.npm/_cacache", tool: "npm", argv: ["npm", "cache", "clean", "--force"],
               reason: L("npm 下载缓存，需要时会重新下载", "npm download cache, re-downloaded on demand"), preselect: true)
        simple("bun", "bun cache", h + "/.bun/install/cache", tool: "bun", argv: ["bun", "pm", "cache", "rm"],
               reason: L("bun 下载缓存", "bun download cache"), preselect: true)
        simple("yarn", "Yarn cache", h + "/Library/Caches/Yarn", tool: "yarn", argv: ["yarn", "cache", "clean"],
               reason: L("Yarn 下载缓存", "Yarn download cache"), preselect: true)
        simple("pip", "pip cache", h + "/Library/Caches/pip", tool: nil, argv: nil,
               reason: L("pip 下载缓存", "pip download cache"), preselect: true)
        simple("brew", "Homebrew cache", h + "/Library/Caches/Homebrew", tool: "brew",
               argv: ["brew", "cleanup", "--prune=all", "-s"],
               reason: L("Homebrew 下载过的安装包", "downloaded Homebrew bottles"), preselect: true)
        simple("cargo-registry", "Cargo registry", h + "/.cargo/registry", tool: nil, argv: nil,
               reason: L("crate 源码和压缩包，编译时会重新下载", "crate sources, re-downloaded when building"),
               preselect: false)
        simple("puppeteer", "Puppeteer browsers", h + "/.cache/puppeteer", tool: nil, argv: nil,
               reason: L("Puppeteer 下载的浏览器，需要时会重新下载", "browsers downloaded by Puppeteer"), preselect: false)
        if let pnpm = Shell.which("pnpm") {
            let store = Shell.run([pnpm, "store", "path"], timeout: 10).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !store.isEmpty {
                let bytes = ctx.size(store)
                if bytes >= 100_000_000 {
                    var it = ReclaimItem(id: "cache:pnpm", label: "pnpm store prune", path: store, bytes: bytes, estimate: 0,
                                         tier: .regenerable, action: .command(argv: ["pnpm", "store", "prune"], cwd: nil),
                                         reason: L("只删除没有项目在用的包", "removes only packages no project references"),
                                         preselected: true)
                    it.estimateIsLowerBound = true
                    things.append(Thing(id: "cache:pnpm", kind: .devCache, title: "pnpm store", path: store, bytes: bytes, items: [it]))
                }
            }
        }
        if let t = simulators(ctx) { things.append(t) }
        if let t = derivedData(ctx) { things.append(t) }
        if let t = docker(ctx) { things.append(t) }
        return things
    }

    // MARK: uv

    static func uv(_ ctx: RecognizeContext, venvs: [VenvRef], preselectedVenvIDs: Set<String>, log: (String) -> Void) -> Thing? {
        var dir = ctx.home + "/.cache/uv"
        if Shell.which("uv") != nil {
            let r = Shell.run(["uv", "cache", "dir"], timeout: 10)
            let d = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.ok, !d.isEmpty { dir = d }
        }
        guard let node = ctx.tree.find(dir) else { return nil }
        let bytes = ctx.tree.size(node)
        guard bytes >= 200_000_000 else { return nil }
        let tree = ctx.tree
        var items: [ReclaimItem] = []

        // Old-version buckets (simple-v22 next to simple-v27) are what prune always drops.
        var buckets: [String: [(Int, NodeID)]] = [:]
        for c in tree.children(node) {
            let name = tree.name(c)
            guard let r = name.range(of: "-v", options: .backwards), let v = Int(name[r.upperBound...]) else { continue }
            buckets[String(name[..<r.lowerBound]), default: []].append((v, c))
        }
        var stale: UInt64 = 0
        for (_, vs) in buckets where vs.count > 1 {
            let maxV = vs.map(\.0).max()!
            for (v, c) in vs where v < maxV { stale += tree.size(c) }
        }
        var prune = ReclaimItem(
            id: "uv:prune", label: "uv cache prune", path: dir, bytes: bytes, estimate: stale, tier: .regenerable,
            action: .command(argv: ["uv", "cache", "prune"], cwd: nil),
            reason: L("删除旧版本格式的缓存和没人引用的条目", "drops old-format buckets and unreferenced entries"),
            preselected: true)
        prune.estimateIsLowerBound = true

        // Real numbers need clone accounting: uv links files into venvs as APFS clones.
        log(L("正在计算 uv 缓存和 \(venvs.count) 个 .venv 的共享数据…", "Measuring data shared between the uv cache and \(venvs.count) venvs…"))
        let roots = [dir] + venvs.map(\.path)
        let acct = SharedAccounting(roots: roots)
        let cacheOnly = acct?.freed(deleting: [0])
        let sleepingIdx = venvs.enumerated().filter { preselectedVenvIDs.contains($0.element.itemID) }.map { $0.offset + 1 }
        let combo = acct?.freed(deleting: Set([0] + sleepingIdx))
        let venvOwn = sleepingIdx.reduce(UInt64(0)) { $0 + (acct?.ownBytes[$1] ?? 0) }

        var clean = ReclaimItem(
            id: "uv:clean", label: "uv cache clean", path: dir, bytes: bytes, estimate: cacheOnly?.total ?? bytes,
            tier: .regenerable, action: .command(argv: ["uv", "cache", "clean"], cwd: nil),
            reason: L("清空整个 uv 缓存，以后装包会重新下载", "empties the whole uv cache; packages are re-downloaded later"),
            preselected: false)
        clean.covers = ["uv:prune"]
        if let c = cacheOnly, c.trapped > 0 {
            clean.warnings.append(L("其中 \(Text.bytes(c.trapped)) 被现有 .venv 克隆引用，单清缓存腾不出来",
                                    "\(Text.bytes(c.trapped)) is cloned into existing venvs and stays until they go too"))
        }
        items.append(prune)
        items.append(clean)

        if !sleepingIdx.isEmpty, let combo {
            let sleepingVenvs = sleepingIdx.map { venvs[$0 - 1] }
            var actions: [ReclaimAction] = [.command(argv: ["uv", "cache", "clean"], cwd: nil)]
            actions += sleepingVenvs.map { .delete(path: $0.path) }
            var it = ReclaimItem(
                id: "uv:combo", label: L("uv cache clean + \(sleepingVenvs.count) 个沉睡项目的 .venv",
                                         "uv cache clean + \(sleepingVenvs.count) sleeping-project venvs"),
                path: dir, bytes: bytes + sleepingVenvs.reduce(UInt64(0)) { $0 + ctx.size($1.path) },
                estimate: combo.total, tier: .regenerable, action: .compound(actions: actions),
                restore: L("在各项目里运行 uv sync", "run uv sync in each project"),
                reason: L("缓存和沉睡项目的环境一起清，克隆共享的数据才会真正释放",
                          "clearing the cache together with sleeping venvs frees the cloned data too"),
                preselected: combo.total > (cacheOnly?.total ?? 0) + venvOwn + 1_000_000_000)
            it.covers = ["uv:prune", "uv:clean"] + sleepingVenvs.map(\.itemID)
            if combo.trapped > 0 {
                it.warnings.append(L("仍有 \(Text.bytes(combo.trapped)) 被活跃项目的 .venv 引用", "\(Text.bytes(combo.trapped)) stays referenced by active venvs"))
            }
            items.append(it)
            if it.preselected { items[0].preselected = false }
        }
        let detail = cacheOnly.map {
            L("单清缓存实际腾出 \(Text.bytes($0.total))；\(Text.bytes($0.trapped)) 与 .venv 共享",
              "clearing alone frees \(Text.bytes($0.total)); \(Text.bytes($0.trapped)) is shared with venvs")
        }
        return Thing(id: "cache:uv", kind: .devCache, title: "uv cache", path: dir, bytes: bytes, detail: detail, items: items)
    }

    // MARK: Simulators

    static func simulators(_ ctx: RecognizeContext) -> Thing? {
        guard Shell.which("xcrun") != nil else { return nil }
        let r = Shell.run(["xcrun", "simctl", "list", "devices", "--json"], timeout: 30)
        guard r.ok, let data = r.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return nil }
        let base = ctx.home + "/Library/Developer/CoreSimulator/Devices"
        var unavailable: UInt64 = 0, unavailableCount = 0
        var stale: [(udid: String, bytes: UInt64)] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (_, list) in devices {
            for d in list {
                guard let udid = d["udid"] as? String else { continue }
                let bytes = ctx.size(base + "/" + udid)
                if (d["isAvailable"] as? Bool) == false {
                    unavailable += bytes
                    unavailableCount += 1
                    continue
                }
                let last = (d["lastBootedAt"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                let days = ctx.daysSince(last) ?? Int.max
                if days >= 180, bytes >= 200_000_000 { stale.append((udid, bytes)) }
            }
        }
        var items: [ReclaimItem] = []
        if unavailableCount > 0, unavailable > 0 {
            items.append(ReclaimItem(
                id: "sim:unavailable", label: L("\(unavailableCount) 个不可用的模拟器", "\(unavailableCount) unavailable simulators"),
                path: nil, bytes: unavailable, tier: .regenerable,
                action: .command(argv: ["xcrun", "simctl", "delete", "unavailable"], cwd: nil),
                reason: L("对应的系统版本已经不存在，无法再启动", "their runtime is gone; they can't boot anymore"),
                preselected: true))
        }
        if !stale.isEmpty {
            let total = stale.reduce(UInt64(0)) { $0 + $1.bytes }
            items.append(ReclaimItem(
                id: "sim:stale", label: L("\(stale.count) 个半年没启动的模拟器", "\(stale.count) simulators unused for 6 months"),
                path: nil, bytes: total, tier: .regenerable,
                action: .command(argv: ["xcrun", "simctl", "delete"] + stale.map(\.udid), cwd: nil),
                restore: L("Xcode 里可随时重新创建", "recreate any time in Xcode"),
                reason: L("模拟器可以重建，但里面装的 App 和数据会丢", "simulators can be recreated, but their apps and data are lost"),
                preselected: false))
        }
        guard !items.isEmpty else { return nil }
        return Thing(id: "cache:simulators", kind: .devCache, title: L("iOS 模拟器", "iOS Simulators"),
                     path: base, bytes: ctx.size(base), items: items)
    }

    // MARK: Xcode DerivedData

    static func derivedData(_ ctx: RecognizeContext) -> Thing? {
        let base = ctx.home + "/Library/Developer/Xcode/DerivedData"
        guard let node = ctx.tree.find(base) else { return nil }
        var items: [ReclaimItem] = []
        for c in ctx.tree.children(node) {
            let path = ctx.tree.path(c)
            let bytes = ctx.tree.size(c)
            guard bytes >= 50_000_000 else { continue }
            let plist = NSDictionary(contentsOfFile: path + "/info.plist")
            let ws = plist?["WorkspacePath"] as? String
            let gone = ws.map { !FileManager.default.fileExists(atPath: $0) } ?? false
            let days = ctx.daysSince(ctx.tree.newest(c)) ?? Int.max
            items.append(ReclaimItem(
                id: "dd:" + path, label: ws.map { ($0 as NSString).lastPathComponent } ?? ctx.tree.name(c),
                path: path, bytes: bytes, tier: .regenerable, action: .delete(path: path),
                restore: L("Xcode 下次编译时重建", "rebuilt by Xcode on the next build"),
                reason: gone ? L("对应的工程已经不在了", "its project no longer exists")
                             : L("Xcode 编译缓存，\(Text.ago(ctx.tree.newest(c)))用过", "Xcode build cache, last used \(Text.ago(ctx.tree.newest(c)))"),
                preselected: gone || days >= ctx.sleepAfterDays))
        }
        guard !items.isEmpty else { return nil }
        return Thing(id: "cache:deriveddata", kind: .devCache, title: "Xcode DerivedData", path: base,
                     bytes: ctx.tree.size(node), items: items.sorted { $0.bytes > $1.bytes })
    }

    // MARK: Docker / OrbStack

    static func docker(_ ctx: RecognizeContext) -> Thing? {
        guard Shell.which("docker") != nil else { return nil }
        let info = Shell.run(["docker", "system", "df", "--format", "{{json .}}"], timeout: 8)
        guard info.ok else { return nil }
        var buildCache: UInt64 = 0
        for line in info.stdout.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = d["Type"] as? String else { continue }
            if type == "Build Cache" { buildCache = parseDockerSize(d["Reclaimable"] as? String ?? "") }
        }
        let dangling = Shell.run(["docker", "images", "-f", "dangling=true", "--format", "{{.Size}}"], timeout: 8)
            .stdout.split(separator: "\n").reduce(UInt64(0)) { $0 + parseDockerSize(String($1)) }
        var items: [ReclaimItem] = []
        let note = L("宿主机上的磁盘镜像会稍后才缩小，执行后实测", "the VM disk image on the Mac shrinks later; measured after running")
        if buildCache > 50_000_000 {
            items.append(ReclaimItem(id: "docker:builder", label: "docker builder prune", path: nil, bytes: buildCache,
                                     tier: .regenerable, action: .command(argv: ["docker", "builder", "prune", "-f"], cwd: nil),
                                     reason: L("镜像构建缓存，下次构建会重新生成", "image build cache, rebuilt on the next build"),
                                     preselected: true, warnings: [note]))
        }
        if dangling > 50_000_000 {
            items.append(ReclaimItem(id: "docker:dangling", label: L("悬空镜像", "dangling images"), path: nil, bytes: dangling,
                                     tier: .regenerable, action: .command(argv: ["docker", "image", "prune", "-f"], cwd: nil),
                                     reason: L("没有标签、也没有容器在用的旧镜像层", "untagged layers no container uses"),
                                     preselected: true, warnings: [note]))
        }
        guard !items.isEmpty else { return nil }
        return Thing(id: "cache:docker", kind: .devCache, title: "Docker / OrbStack", path: nil,
                     bytes: items.reduce(0) { $0 + $1.bytes },
                     detail: L("不会运行 docker system prune：它会删掉停止的容器和本地构建的镜像",
                               "never runs docker system prune: it deletes stopped containers and local images"),
                     items: items)
    }

    static func parseDockerSize(_ s: String) -> UInt64 {
        // "1.234GB", "512MB (40%)", "0B"
        let t = s.split(separator: " ").first.map(String.init) ?? s
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (u, m) in units where t.hasSuffix(u) {
            return UInt64((Double(t.dropLast(u.count)) ?? 0) * m)
        }
        return 0
    }
}
