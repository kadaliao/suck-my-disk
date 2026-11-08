import DiskIndex
import Foundation
import Recognizers

/// `--demo`: made-up projects, renders, caches and models, for screenshots and for
/// trying the app. Nothing is read from or written to the disk, and Clean Up only
/// pretends. Paths sit under the real home folder so they show as `~/…`.
struct DemoData {
    var report: Report
    var tree: ScanTree?
    var history: [ReportStore.DayPoint]
    var volume: VolumeInfo
    var userFiles: UInt64
    var applications: UInt64
    /// A made-up external disk.
    var external: (volume: ExternalVolume, report: Report, tree: ScanTree?)

    static func make(now: Date = Date()) -> DemoData {
        var b = Builder(now: now)
        b.projects()
        b.media()
        b.devCaches()
        b.models()
        b.apps()
        b.appData()

        var volume = VolumeInfo.of()
        volume.uuid = "demo"
        volume.total = 994_662_584_320
        volume.free = gb(61.4)
        volume.importantFree = volume.free + gb(12.8)
        let otherVolumes = gb(30.9)
        volume.dataUsed = volume.used - otherVolumes
        let hidden = gb(17.6)
        b.system(volume: volume, hidden: hidden, otherVolumes: otherVolumes)

        let report = Report(createdAt: now.addingTimeInterval(-4 * 60), volumeTotal: volume.total,
                            volumeFree: volume.free, scanned: volume.dataUsed - hidden, things: b.things)
        return DemoData(report: report, tree: b.tree(), history: b.history(free: volume.free), volume: volume,
                        userFiles: gb(262), applications: gb(62), external: externalDisk(now: now))
    }

    /// "Studio SSD": old client projects and a film's render frames among footage and photos.
    static func externalDisk(now: Date) -> (volume: ExternalVolume, report: Report, tree: ScanTree?) {
        let root = "/Volumes/Studio SSD"
        let v = ExternalVolume(name: "Studio SSD", path: root, uuid: "demo-studio-ssd", total: 2_000_189_177_856, free: gb(612))
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        func art(_ path: String, _ kind: String, _ size: Double, restore: String, pre: Bool, reason: String) -> ReclaimItem {
            ReclaimItem(id: "art:" + path, label: kind, path: path, bytes: gb(size), tier: .regenerable,
                        action: .delete(path: path), restore: restore, reason: reason, preselected: pre)
        }
        let npm = L("npm 依赖，可以按锁文件重新安装", "npm dependencies, reinstallable from the lockfile")
        let rust = L("Rust/Java 编译产物，重新编译即可", "Rust/Java build output, rebuilt by compiling")
        let py = L("Python 虚拟环境，可以重建", "Python virtualenv, can be recreated")
        let p = root + "/Projects/"
        let film = root + "/Films/harbor-documentary"
        var things = [
            Thing(id: "project:" + p + "client-portal-2024", kind: .project, title: "client-portal-2024", path: p + "client-portal-2024",
                  bytes: gb(6.8), lastActive: ago(412), activitySource: L("文件改动", "file changes"),
                  detail: L("沉睡 412 天", "asleep for 412 days"), items: [
                      art(p + "client-portal-2024/node_modules", "node_modules", 4.1, restore: "npm ci", pre: true, reason: npm),
                      art(p + "client-portal-2024/dist", "dist", 0.9, restore: "npm run build", pre: true,
                          reason: L("构建输出，被 git 忽略", "build output ignored by git")),
                  ]),
            Thing(id: "project:" + p + "tile-engine", kind: .project, title: "tile-engine", path: p + "tile-engine",
                  bytes: gb(14.2), lastActive: ago(198), activitySource: "Claude Code",
                  detail: L("沉睡 198 天", "asleep for 198 days"), items: [
                      art(p + "tile-engine/target", "target", 12.6, restore: "cargo build", pre: true, reason: rust),
                  ]),
            Thing(id: "project:" + p + "speech-dataset-tools", kind: .project, title: "speech-dataset-tools",
                  path: p + "speech-dataset-tools", bytes: gb(5.3), lastActive: ago(12), activitySource: "Codex", items: [
                      art(p + "speech-dataset-tools/.venv", "venv", 4.4, restore: "uv sync", pre: false, reason: py),
                  ]),
        ]
        things.append(Thing(id: "media:" + film, kind: .media,
                            title: L("渲染中间帧 · harbor-documentary", "Render frames · harbor-documentary"),
                            path: film, bytes: gb(48.6), detail: L("1 组帧序列", "1 frame folders"), items: [
            ReclaimItem(id: "frames:" + film + "/render/frames", label: L("渲染帧 14400 张", "14,400 rendered frames"),
                        path: film + "/render/frames", bytes: gb(48.6), tier: .regenerable,
                        action: .delete(path: film + "/render/frames"),
                        restore: L("用原工程重新渲染", "re-render from the source project"),
                        reason: L("成片已存在：\(film)/harbor-final.mov（帧数与时长 × 帧率吻合）",
                                  "final video exists: \(film)/harbor-final.mov (frame count matches duration × fps)"),
                        preselected: true),
        ]))
        var folders: [String: UInt64] = [root + "/Footage": gb(742), root + "/Photos": gb(318), root + "/Backups": gb(166),
                                         root + "/Films": gb(61), root + "/Projects": gb(3)]
        var folded: Set<String> = []
        for t in things {
            var rest = t.bytes
            for i in t.items {
                guard let ip = i.path else { continue }
                folders[ip, default: 0] += i.bytes
                rest -= min(rest, i.bytes)
                if ["node_modules", "venv", "target"].contains(i.label) { folded.insert(ip) }
            }
            if let tp = t.path { folders[tp, default: 0] += rest }
        }
        let tree = ScanTree.synthetic(root: root, folders: folders, folded: folded, modified: ago(3))
        let report = Report(createdAt: now.addingTimeInterval(-20 * 60), volumeTotal: v.total, volumeFree: v.free,
                            scanned: v.used, things: things)
        return (v, report, tree)
    }
}

private func gb(_ x: Double) -> UInt64 { UInt64(x * 1e9) }

private struct Builder {
    let now: Date
    let h = NSHomeDirectory()
    var things: [Thing] = []
    /// The apps' folders in ~/Library and their sizes, for the index.
    var appFolders: [String: UInt64] = [:]

    func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }

    // MARK: projects

    func artifact(_ path: String, _ kind: String, _ size: Double, estimate: Double? = nil, restore: String?,
                  pre: Bool, warnings: [String] = []) -> ReclaimItem {
        let reason: String
        switch kind {
        case "node_modules": reason = L("npm 依赖，可以按锁文件重新安装", "npm dependencies, reinstallable from the lockfile")
        case "venv": reason = L("Python 虚拟环境，可以重建", "Python virtualenv, can be recreated")
        case "target": reason = L("Rust/Java 编译产物，重新编译即可", "Rust/Java build output, rebuilt by compiling")
        case ".build": reason = L("SwiftPM 编译产物", "SwiftPM build output")
        case ".next": reason = L("前端构建缓存", "front-end build cache")
        default: reason = L("构建输出，被 git 忽略", "build output ignored by git")
        }
        return ReclaimItem(id: "art:" + path, label: kind, path: path, bytes: gb(size), estimate: estimate.map(gb),
                           tier: .regenerable, action: .delete(path: path), restore: restore, reason: reason,
                           preselected: pre, warnings: warnings)
    }

    func shared(_ size: Double) -> String {
        L("其中 \(Fmt.bytes(gb(size))) 和别处共享（克隆或硬链接），单删这一项腾不出来",
          "\(Fmt.bytes(gb(size))) is shared with other places and stays allocated")
    }

    var recent: String {
        let d = Fmt.stamp(Date().addingTimeInterval(-2 * 86400 - 3 * 3600))
        return L("\(d) 还有改动，所以没预选", "changed \(d), so not preselected")
    }

    mutating func project(_ name: String, _ size: Double, days: Int, _ source: String, _ items: [ReclaimItem]) {
        let path = h + "/workspace/" + name
        things.append(Thing(id: "project:" + path, kind: .project, title: name, path: path, bytes: gb(size),
                            lastActive: ago(Double(days) + 0.3), activitySource: source,
                            detail: days >= 30 ? L("沉睡 \(days) 天", "asleep for \(days) days") : nil,
                            items: items))
    }

    mutating func projects() {
        let w = h + "/workspace/"
        let files = L("文件改动", "file changes")
        project("pixel-forge", 22.9, days: 74, "Claude Code", [
            artifact(w + "pixel-forge/target", "target", 18.4, restore: "cargo build", pre: true),
            artifact(w + "pixel-forge/web/node_modules", "node_modules", 1.3, restore: "pnpm install", pre: true),
            artifact(w + "pixel-forge/web/.next", ".next", 0.62, restore: "npm run build", pre: true),
        ])
        project("voice-clone-lab", 8.1, days: 46, "Codex", [
            artifact(w + "voice-clone-lab/.venv", "venv", 7.2, estimate: 1.9, restore: "uv sync", pre: true,
                     warnings: [shared(5.3)]),
            ReclaimItem(id: "pycache:" + w + "voice-clone-lab", label: L("Python 缓存 ×23", "Python caches ×23"), path: nil,
                        bytes: gb(0.21), tier: .regenerable, action: .deleteAll(paths: []), restore: nil,
                        reason: L("运行时自动重建", "rebuilt automatically when code runs"), preselected: true),
        ])
        project("rag-notes", 3.6, days: 58, "Claude Code", [
            artifact(w + "rag-notes/.venv", "venv", 3.1, estimate: 0.4, restore: "uv sync", pre: true,
                     warnings: [shared(2.7)]),
        ])
        project("storyboard-ai", 4.6, days: 2, "Claude Code", [
            artifact(w + "storyboard-ai/node_modules", "node_modules", 2.3, restore: "pnpm install", pre: false, warnings: [recent]),
            artifact(w + "storyboard-ai/.next", ".next", 1.1, restore: "npm run build", pre: false, warnings: [recent]),
        ])
        project("comfy-workflows", 5.1, days: 9, "Claude Code", [
            artifact(w + "comfy-workflows/.venv", "venv", 4.6, restore: "uv sync", pre: false),
        ])
        project("habit-tracker-ios", 4.0, days: 133, files, [
            artifact(w + "habit-tracker-ios/.build", ".build", 3.4, restore: "swift build", pre: true),
        ])
        project("agent-playground", 2.0, days: 0, "Claude Code", [
            artifact(w + "agent-playground/node_modules", "node_modules", 1.6, restore: "bun install", pre: false,
                     warnings: [recent]),
        ])
        project("landing-page-2025", 1.3, days: 210, "shell", [
            artifact(w + "landing-page-2025/node_modules", "node_modules", 0.98, restore: "npm install", pre: false,
                     warnings: [L("没有锁文件，重装后的版本可能不同", "no lockfile: reinstall may resolve different versions")]),
            artifact(w + "landing-page-2025/dist", "dist", 0.12, restore: "npm run build", pre: true),
        ])
    }

    // MARK: media

    mutating func media() {
        func frames(_ path: String, _ count: Int, _ size: Double, video: String, pre: Bool, warnings: [String] = []) -> ReclaimItem {
            ReclaimItem(id: "frames:" + path, label: L("渲染帧 \(count) 张", "\(count) rendered frames"), path: path,
                        bytes: gb(size), tier: .regenerable, action: .delete(path: path),
                        restore: L("用原工程重新渲染", "re-render from the source project"),
                        reason: L("成片已存在：\(Fmt.home(video))（帧数与时长 × 帧率吻合）",
                                  "final video exists: \(Fmt.home(video)) (frame count matches duration × fps)"),
                        preselected: pre, warnings: warnings)
        }
        let promo = h + "/Movies/promo-video"
        let stills = promo + "/stills"
        things.append(Thing(id: "media:" + promo, kind: .media, title: L("渲染中间帧 · promo-video", "Render frames · promo-video"),
                            path: promo, bytes: gb(24.7), detail: L("2 组帧序列", "2 frame folders"), items: [
            frames(promo + "/frames", 7304, 21.6, video: promo + "/promo-final.mp4", pre: true),
            ReclaimItem(id: "frames:" + stills, label: L("图片序列 1800 张", "1800-image sequence"), path: stills,
                        bytes: gb(3.1), tier: .yours, action: .trash(path: stills), restore: nil,
                        reason: L("像渲染帧，但没找到对应的成片，按你的文件处理", "looks like frames, but no matching final video was found"),
                        preselected: false),
        ]))
        let ep = h + "/workspace/explainer-ep3"
        things.append(Thing(id: "media:" + ep, kind: .media, title: L("渲染中间帧 · explainer-ep3", "Render frames · explainer-ep3"),
                            path: ep, bytes: gb(8.2), detail: L("1 组帧序列", "1 frame folders"), items: [
            frames(ep + "/out/frames", 2910, 8.2, video: ep + "/out/explainer-ep3.mp4", pre: false,
                   warnings: [{ let d = Fmt.stamp(Date().addingTimeInterval(-86400 - 5 * 3600))
                                return L("\(d) 刚渲染过，所以没预选", "rendered \(d), so not preselected") }()]),
        ]))
    }

    // MARK: dev caches

    mutating func cache(_ id: String, _ title: String, _ path: String, _ size: Double, _ action: ReclaimAction,
                        _ reason: String, pre: Bool) {
        things.append(Thing(id: "cache:" + id, kind: .devCache, title: title, path: path, bytes: gb(size), items: [
            ReclaimItem(id: "cache:" + id, label: title, path: path, bytes: gb(size), tier: .regenerable,
                        action: action, reason: reason, preselected: pre),
        ]))
    }

    mutating func devCaches() {
        let uv = h + "/.cache/uv"
        let venvs = [h + "/workspace/voice-clone-lab/.venv", h + "/workspace/rag-notes/.venv"]
        var prune = ReclaimItem(id: "uv:prune", label: "uv cache prune", path: uv, bytes: gb(31.5), estimate: gb(4.8),
                                tier: .regenerable, action: .command(argv: ["uv", "cache", "prune"], cwd: nil),
                                reason: L("删除旧版本格式的缓存和没人引用的条目", "drops old-format buckets and unreferenced entries"),
                                preselected: false)
        prune.estimateIsLowerBound = true
        var clean = ReclaimItem(id: "uv:clean", label: "uv cache clean", path: uv, bytes: gb(31.5), estimate: gb(9.6),
                                tier: .regenerable, action: .command(argv: ["uv", "cache", "clean"], cwd: nil),
                                reason: L("清空整个 uv 缓存，以后装包会重新下载", "empties the whole uv cache; packages are re-downloaded later"),
                                preselected: false,
                                warnings: [L("其中 14.2 GB 被现有 .venv 克隆引用，单清缓存腾不出来",
                                             "14.2 GB is cloned into existing venvs and stays until they go too")])
        clean.covers = ["uv:prune"]
        var combo = ReclaimItem(
            id: "uv:combo", label: L("uv cache clean + 2 个沉睡项目的 .venv", "uv cache clean + 2 sleeping-project venvs"),
            path: uv, bytes: gb(41.8), estimate: gb(26.4), tier: .regenerable,
            action: .compound(actions: [.command(argv: ["uv", "cache", "clean"], cwd: nil)] + venvs.map { .delete(path: $0) }),
            restore: L("在各项目里运行 uv sync", "run uv sync in each project"),
            reason: L("缓存和沉睡项目的环境一起清，克隆共享的数据才会真正释放",
                      "clearing the cache together with sleeping venvs frees the cloned data too"),
            preselected: true,
            warnings: [L("仍有 3.1 GB 被活跃项目的 .venv 引用", "3.1 GB stays referenced by active venvs")])
        combo.covers = ["uv:prune", "uv:clean"] + venvs.map { "art:" + $0 }
        things.append(Thing(id: "cache:uv", kind: .devCache, title: "uv cache", path: uv, bytes: gb(31.5),
                            detail: L("单清缓存实际腾出 9.6 GB；14.2 GB 与 .venv 共享",
                                      "clearing alone frees 9.6 GB; 14.2 GB is shared with venvs"),
                            items: [prune, clean, combo]))

        var pnpm = ReclaimItem(id: "cache:pnpm", label: "pnpm store prune", path: h + "/Library/pnpm/store", bytes: gb(12.3),
                               estimate: gb(3.2), tier: .regenerable, action: .command(argv: ["pnpm", "store", "prune"], cwd: nil),
                               reason: L("只删除没有项目在用的包", "removes only packages no project references"), preselected: true)
        pnpm.estimateIsLowerBound = true
        things.append(Thing(id: "cache:pnpm", kind: .devCache, title: "pnpm store", path: h + "/Library/pnpm/store",
                            bytes: gb(12.3), items: [pnpm]))
        cache("npm", "npm cache", h + "/.npm/_cacache", 4.1, .command(argv: ["npm", "cache", "clean", "--force"], cwd: nil),
              L("npm 下载缓存，需要时会重新下载", "npm download cache, re-downloaded on demand"), pre: true)
        cache("brew", "Homebrew cache", h + "/Library/Caches/Homebrew", 2.7,
              .command(argv: ["brew", "cleanup", "--prune=all", "-s"], cwd: nil),
              L("Homebrew 下载过的安装包", "downloaded Homebrew bottles"), pre: true)
        cache("cargo-registry", "Cargo registry", h + "/.cargo/registry", 1.9, .delete(path: h + "/.cargo/registry"),
              L("crate 源码和压缩包，编译时会重新下载", "crate sources, re-downloaded when building"), pre: false)
        cache("puppeteer", "Puppeteer browsers", h + "/.cache/puppeteer", 1.1, .delete(path: h + "/.cache/puppeteer"),
              L("Puppeteer 下载的浏览器，需要时会重新下载", "browsers downloaded by Puppeteer"), pre: false)

        let dd = h + "/Library/Developer/Xcode/DerivedData"
        func derived(_ name: String, _ folder: String, _ size: Double, gone: Bool = false, days: Double) -> ReclaimItem {
            let path = dd + "/" + folder
            return ReclaimItem(id: "dd:" + path, label: name, path: path, bytes: gb(size), tier: .regenerable,
                               action: .delete(path: path), restore: L("Xcode 下次编译时重建", "rebuilt by Xcode on the next build"),
                               reason: gone ? L("对应的工程已经不在了", "its project no longer exists")
                                            : L("Xcode 编译缓存，\(Fmt.ago(ago(days)))用过", "Xcode build cache, last used \(Fmt.ago(ago(days)))"),
                               preselected: gone || days >= 30)
        }
        things.append(Thing(id: "cache:deriveddata", kind: .devCache, title: "Xcode DerivedData", path: dd, bytes: gb(14.6), items: [
            derived("HabitTracker.xcodeproj", "HabitTracker-bxkqhzdjmfplowaeodfvqurlcpcz", 6.2, gone: true, days: 140),
            derived("Weather.xcworkspace", "Weather-gzhcwqbyxlnfdmaoeksjtiuvrpqa", 5.3, days: 3),
            derived("PixelForgeMac.xcodeproj", "PixelForgeMac-dqfmlwzhxkcnbtaoyerpsujgvivh", 3.1, days: 65),
        ]))

        things.append(Thing(id: "cache:simulators", kind: .devCache, title: L("iOS 模拟器", "iOS Simulators"),
                            path: h + "/Library/Developer/CoreSimulator/Devices", bytes: gb(22.8), items: [
            ReclaimItem(id: "sim:unavailable", label: L("4 个不可用的模拟器", "4 unavailable simulators"), path: nil,
                        bytes: gb(8.9), tier: .regenerable,
                        action: .command(argv: ["xcrun", "simctl", "delete", "unavailable"], cwd: nil),
                        reason: L("对应的系统版本已经不存在，无法再启动", "their runtime is gone; they can't boot anymore"),
                        preselected: true),
            ReclaimItem(id: "sim:stale", label: L("3 个半年没启动的模拟器", "3 simulators unused for 6 months"), path: nil,
                        bytes: gb(11.2), tier: .regenerable,
                        action: .command(argv: ["xcrun", "simctl", "delete", "demo-1", "demo-2", "demo-3"], cwd: nil),
                        restore: L("Xcode 里可随时重新创建", "recreate any time in Xcode"),
                        reason: L("模拟器可以重建，但里面装的 App 和数据会丢", "simulators can be recreated, but their apps and data are lost"),
                        preselected: false),
        ]))

        let note = L("宿主机上的磁盘镜像会稍后才缩小，执行后实测", "the VM disk image on the Mac shrinks later; measured after running")
        things.append(Thing(id: "cache:docker", kind: .devCache, title: "Docker / OrbStack", path: nil, bytes: gb(9.6),
                            detail: L("不会运行 docker system prune：它会删掉停止的容器和本地构建的镜像",
                                      "never runs docker system prune: it deletes stopped containers and local images"), items: [
            ReclaimItem(id: "docker:builder", label: "docker builder prune", path: nil, bytes: gb(7.4), tier: .regenerable,
                        action: .command(argv: ["docker", "builder", "prune", "-f"], cwd: nil),
                        reason: L("镜像构建缓存，下次构建会重新生成", "image build cache, rebuilt on the next build"),
                        preselected: true, warnings: [note]),
            ReclaimItem(id: "docker:dangling", label: L("悬空镜像", "dangling images"), path: nil, bytes: gb(2.2),
                        tier: .regenerable, action: .command(argv: ["docker", "image", "prune", "-f"], cwd: nil),
                        reason: L("没有标签、也没有容器在用的旧镜像层", "untagged layers no container uses"),
                        preselected: true, warnings: [note]),
        ]))
    }

    // MARK: models

    mutating func models() {
        func ollama(_ name: String, _ size: Double, days: Double) -> ReclaimItem {
            ReclaimItem(id: "ollama:" + name, label: name, path: nil, bytes: gb(size), tier: .regenerable,
                        action: .command(argv: ["ollama", "rm", name], cwd: nil), restore: "ollama pull \(name)",
                        reason: L("下载于 \(Fmt.ago(ago(days)))，可以重新 pull", "pulled \(Fmt.ago(ago(days))), can be pulled again"),
                        preselected: false)
        }
        let ol = h + "/.ollama/models"
        things.append(Thing(id: "model:ollama", kind: .model, title: "Ollama", path: ol, bytes: gb(37.5), items: [
            ollama("qwen3:32b", 20.2, days: 95), ollama("gemma3:27b", 17.0, days: 150),
            ollama("nomic-embed-text:latest", 0.27, days: 240),
        ]))
        let hub = h + "/.cache/huggingface/hub"
        func hf(_ repo: String, _ size: Double, days: Double) -> ReclaimItem {
            let path = hub + "/models--" + repo.replacingOccurrences(of: "/", with: "--")
            return ReclaimItem(id: "hf:" + repo, label: repo, path: path, bytes: gb(size), tier: .regenerable,
                               action: .command(argv: ["hf", "cache", "rm", repo, "-y"], cwd: nil),
                               restore: L("用到时会重新下载", "re-downloaded when used"),
                               reason: L("最后改动 \(Fmt.ago(ago(days)))", "last changed \(Fmt.ago(ago(days)))"), preselected: false)
        }
        things.append(Thing(id: "model:hf", kind: .model, title: "Hugging Face", path: hub, bytes: gb(27.0), items: [
            hf("black-forest-labs/FLUX.1-dev", 23.8, days: 120), hf("openai/whisper-large-v3", 3.1, days: 64),
        ]))
        let lms = h + "/.lmstudio/models"
        let qwen = lms + "/lmstudio-community/Qwen3-14B-GGUF"
        things.append(Thing(id: "model:lmstudio", kind: .model, title: "LM Studio", path: lms, bytes: gb(9.0), items: [
            ReclaimItem(id: "lms:" + qwen, label: "lmstudio-community/Qwen3-14B-GGUF", path: qwen, bytes: gb(9.0),
                        tier: .yours, action: .trash(path: qwen), reason: L("LM Studio 模型", "LM Studio model"),
                        preselected: false),
        ]))
    }

    // MARK: apps

    /// A made-up installed app: `data` are folders under ~/Library (GB), the ones in `caches` it rebuilds itself.
    mutating func app(_ name: String, _ file: String, size: Double, days: Double?, data: [(String, Double)],
                      caches: [(String, Double)], appStore: Bool = false, warnings: [String] = []) {
        let path = "/Applications/" + file
        let lib = h + "/Library/"
        let dataBytes = data.reduce(0) { $0 + gb($1.1) }
        for (rel, g) in data { appFolders[lib + rel, default: 0] += gb(g) }
        // A cache inside a data folder is part of it, not extra.
        for (rel, g) in caches where !data.contains(where: { $0.0 == rel }) {
            if let outer = data.first(where: { rel.hasPrefix($0.0 + "/") }) {
                appFolders[lib + outer.0, default: 0] -= min(appFolders[lib + outer.0] ?? 0, gb(g))
            }
            appFolders[lib + rel, default: 0] += gb(g)
        }
        var uninstall = ReclaimItem(
            id: "apps:uninstall:" + path, label: L("卸载 \(name)", "Uninstall \(name)"), path: path, bytes: gb(size) + dataBytes,
            tier: .yours, action: .compound(actions: [.trash(path: path)] + data.map { .trash(path: lib + $0.0) }),
            restore: appStore ? L("从 App Store 重新安装；数据可以从废纸篓放回", "reinstall from the App Store; put the data back from the Trash")
                              : L("从废纸篓放回", "put back from the Trash"),
            reason: L("应用 \(Fmt.bytes(gb(size)))，连同资源库里 \(data.count) 处数据 \(Fmt.bytes(dataBytes))，一起移到废纸篓",
                      "the app (\(Fmt.bytes(gb(size)))) and its data in \(data.count) places in your Library (\(Fmt.bytes(dataBytes))) go to the Trash"),
            preselected: false, warnings: warnings, app: path)
        var items = [uninstall]
        if !caches.isEmpty {
            let c = ReclaimItem(
                id: "apps:caches:" + path, label: L("\(name) 的缓存", "\(name) caches"), path: nil,
                bytes: caches.reduce(0) { $0 + gb($1.1) }, tier: .regenerable, action: .deleteAll(paths: caches.map { lib + $0.0 }),
                restore: L("应用下次打开时会重建", "rebuilt when the app next runs"),
                reason: L("缓存、日志和窗口状态，删掉后应用会自己重建；应用和你的数据都留着",
                          "caches, logs and saved window state, which the app rebuilds; the app and your data stay"),
                preselected: false, app: path)
            uninstall.covers = [c.id]
            items = [uninstall, c]
        }
        let idle = days.flatMap { $0 >= 90 ? Int($0) : nil }
        things.append(Thing(id: "apps:" + path, kind: .app, title: name, path: path, bytes: gb(size) + dataBytes,
                            lastActive: days.map { ago($0 + 0.2) },
                            detail: idle.map { L("\($0) 天没打开", "unused for \($0) days") }, items: items))
    }

    mutating func apps() {
        app("Docker", "Docker.app", size: 2.1, days: 41, data: [
            ("Containers/com.docker.docker", 38.4), ("Group Containers/group.com.docker", 0.02), ("Caches/com.docker.docker", 0.31),
            ("Preferences/com.docker.docker.plist", 0.0001),
        ], caches: [("Caches/com.docker.docker", 0.31)], warnings: [
            L("它在系统里还装了组件（com.docker.vmnetd.plist、com.docker.socket），这里卸载不会动它们；有自带的卸载程序的话最好用它",
              "It installed system components (com.docker.vmnetd.plist, com.docker.socket) that uninstalling here leaves in place; use its own uninstaller if it has one"),
        ])
        app("Steam", "Steam.app", size: 0.03, days: 263, data: [
            ("Application Support/Steam", 27.3), ("Logs/Steam", 0.04), ("Saved Application State/com.valvesoftware.steam.savedState", 0.0001),
        ], caches: [("Logs/Steam", 0.04), ("Saved Application State/com.valvesoftware.steam.savedState", 0.0001)])
        app("Final Cut Pro", "Final Cut Pro.app", size: 5.9, days: 158, data: [
            ("Containers/com.apple.FinalCut", 1.6), ("Caches/com.apple.FinalCut", 0.92), ("Preferences/com.apple.FinalCut.plist", 0.0001),
        ], caches: [("Caches/com.apple.FinalCut", 0.92)], appStore: true,
            warnings: [L("移到废纸篓时，访达会要管理员密码", "Finder will ask for an administrator password to move it to the Trash")])
        app("Slack", "Slack.app", size: 0.52, days: 0, data: [
            ("Application Support/Slack", 2.4), ("Caches/com.tinyspeck.slackmacgap.ShipIt", 0.25),
            ("HTTPStorages/com.tinyspeck.slackmacgap", 0.002), ("Preferences/com.tinyspeck.slackmacgap.plist", 0.0001),
        ], caches: [("Application Support/Slack/Cache", 0.96), ("Application Support/Slack/Code Cache", 0.31),
                    ("Caches/com.tinyspeck.slackmacgap.ShipIt", 0.25)])
        app("Visual Studio Code", "Visual Studio Code.app", size: 0.62, days: 1, data: [
            ("Application Support/Code", 1.8), ("Caches/com.microsoft.VSCode.ShipIt", 0.21), ("Preferences/com.microsoft.VSCode.plist", 0.0001),
        ], caches: [("Application Support/Code/CachedData", 0.64), ("Application Support/Code/Cache", 0.18),
                    ("Caches/com.microsoft.VSCode.ShipIt", 0.21)], warnings: [
            L("用 Homebrew 装的：卸载后再运行 brew uninstall --cask visual-studio-code，Homebrew 才会忘掉它，命令行链接也会删掉",
              "Installed with Homebrew: run brew uninstall --cask visual-studio-code afterwards so Homebrew forgets it and removes its command-line links"),
        ])
        app("Blender", "Blender.app", size: 1.9, days: 133, data: [
            ("Application Support/Blender", 0.42), ("Caches/org.blenderfoundation.blender", 0.06),
        ], caches: [("Caches/org.blenderfoundation.blender", 0.06)])
        app("Zoom", "zoom.us.app", size: 0.61, days: 214, data: [
            ("Application Support/zoom.us", 0.88), ("Logs/zoom.us", 0.12), ("Caches/us.zoom.xos", 0.19),
            ("Preferences/us.zoom.xos.plist", 0.0001),
        ], caches: [("Logs/zoom.us", 0.12), ("Caches/us.zoom.xos", 0.19)])
        app("Figma", "Figma.app", size: 0.45, days: 6, data: [
            ("Application Support/Figma", 1.1), ("Preferences/com.figma.Desktop.plist", 0.0001),
        ], caches: [("Application Support/Figma/Cache", 0.52), ("Application Support/Figma/GPUCache", 0.03)])
        app("Unity Hub", "Unity Hub.app", size: 0.41, days: 301, data: [
            ("Application Support/UnityHub", 0.23), ("Logs/Unity", 0.02),
        ], caches: [("Logs/Unity", 0.02)])
    }

    // MARK: app data and system

    mutating func appData() {
        let apps: [(String, String, Double, String, String)] = [
            ("/Library/Containers/com.tencent.xinWeChat", L("微信", "WeChat"), 48.2,
             "在微信里打开 设置 → 通用 → 存储空间 清理聊天文件", "In WeChat: Settings → General → Storage"),
            ("/Library/Application Support/MobileSync/Backup", L("iPhone 备份", "iPhone backups"), 31.7,
             "在 访达 → 你的 iPhone → 管理备份 里删除旧备份", "Finder → your iPhone → Manage Backups"),
            ("/Library/Application Support/Claude/vm_bundles", L("Claude 虚拟机镜像", "Claude VM bundles"), 9.8,
             "Claude 桌面版运行代码用的虚拟机，删了会重新下载", "VM images used by the Claude app; re-downloaded if removed"),
            ("/Library/Application Support/Google/Chrome", "Chrome", 6.4,
             "在 Chrome 设置 → 隐私 → 清除浏览数据 里清缓存；不要直接删这个文件夹", "Use Chrome's Clear browsing data; don't delete the folder"),
            ("/Library/Application Support/LarkShell", L("飞书", "Lark"), 4.3,
             "在飞书 设置 → 通用 → 清理缓存", "In Lark: Settings → General → Clear cache"),
        ]
        for (rel, title, size, zh, en) in apps {
            let path = h + rel
            things.append(Thing(id: "app:" + path, kind: .appData, title: title, path: path, bytes: gb(size),
                                detail: L(zh, en), items: [
                ReclaimItem(id: "app:" + path, label: title, path: path, bytes: gb(size), tier: .guide, action: .none,
                            reason: L(zh, en), preselected: false),
            ]))
        }
    }

    mutating func system(volume: VolumeInfo, hidden: UInt64, otherVolumes: UInt64) {
        let trash = h + "/.Trash"
        things.append(Thing(id: "system:trash", kind: .system, title: L("废纸篓", "Trash"), path: trash, bytes: gb(3.2),
                            detail: L("放进废纸篓的东西还占着空间，清空后才会腾出", "items in the Trash still use space until it is emptied"),
                            items: [ReclaimItem(id: "system:trash", label: L("清空废纸篓", "Empty Trash"), path: trash, bytes: gb(3.2),
                                                tier: .yours, action: .command(argv: ["true"], cwd: nil),
                                                reason: L("这些是你之前删掉的文件", "files you deleted earlier"), preselected: false)]))
        things.append(Thing(id: "system:snapshots", kind: .system, title: L("本地快照", "Local snapshots"), path: nil, bytes: 0,
                            detail: L("2 个系统快照（更新或时间机器创建）。快照占用的空间扫描不到；有快照时，删掉文件也不会立刻腾出空间。",
                                      "2 system snapshots. Their space can't be measured by scanning, and deleted files stay allocated while a snapshot holds them.")))
        let scanned = volume.dataUsed - hidden
        things.append(Thing(id: "system:hidden", kind: .system, title: L("数据卷里扫描不到的部分", "Not visible to the scan"), path: nil,
                            bytes: hidden,
                            detail: L("数据卷已用 \(Fmt.bytes(volume.dataUsed)) − 扫描到 \(Fmt.bytes(scanned))：快照占用、没有权限读的目录（12 个）等。可清除空间约 \(Fmt.bytes(volume.purgeable))，macOS 需要时会自动释放。",
                                      "data volume used \(Fmt.bytes(volume.dataUsed)) − scanned \(Fmt.bytes(scanned)): snapshot space, unreadable folders (12), etc. About \(Fmt.bytes(volume.purgeable)) is purgeable; macOS frees it when needed.")))
        things.append(Thing(id: "system:volumes", kind: .system, title: L("系统卷和虚拟内存", "System, VM and other volumes"), path: nil,
                            bytes: otherVolumes,
                            detail: L("同一块盘上的 macOS 系统卷、交换文件、Preboot、Recovery 等，由系统管理",
                                      "the sealed macOS volume, swap, Preboot, Recovery…, managed by macOS")))
    }

    // MARK: index and history

    /// The home folder as a tree: every thing and item with a path, plus the usual folders.
    func tree() -> ScanTree? {
        var folders: [String: UInt64] = [
            h + "/Pictures/Photos Library.photoslibrary": gb(118), h + "/Downloads": gb(57), h + "/Documents": gb(41),
            h + "/Movies": gb(24), h + "/Desktop": gb(14), h + "/Music": gb(8),
            h + "/Library/Application Support": gb(38), h + "/Library/Group Containers": gb(12),
            h + "/Library/Caches": gb(9), h + "/workspace": gb(6),
        ]
        var folded: Set<String> = [h + "/Pictures/Photos Library.photoslibrary"]
        for (p, b) in appFolders { folders[p, default: 0] += b }
        for t in things where t.kind != .app {
            let inside = t.items.filter { i in
                guard let p = i.path, let tp = t.path else { return false }
                return p.hasPrefix(tp + "/")
            }
            for i in inside {
                folders[i.path!, default: 0] += i.bytes
                let name = (i.path! as NSString).lastPathComponent
                if [".venv", "node_modules", ".next", ".build"].contains(name) || i.id.hasPrefix("dd:") { folded.insert(i.path!) }
            }
            if let tp = t.path {
                let rest = t.bytes - min(t.bytes, inside.reduce(0) { $0 + $1.bytes })
                folders[tp, default: 0] += rest
            }
        }
        return ScanTree.synthetic(root: h, folders: folders, folded: folded, modified: ago(1))
    }

    /// Two weeks of growth, ending at today's numbers.
    func history(free: UInt64) -> [ReportStore.DayPoint] {
        let kinds: [ThingKind] = [.project, .media, .devCache, .model, .appData]
        var out: [ReportStore.DayPoint] = []
        let days = 14
        for d in 0..<days {
            let day = Store.today(ago(Double(days - 1 - d)))
            let f = Double(d) / Double(days - 1)
            for (k, kind) in kinds.enumerated() {
                let total = things.filter { $0.kind == kind }.reduce(UInt64(0)) { $0 + $1.bytes }
                let wobble = 0.03 * sin(Double(d * (k + 2)))
                out.append(.init(day: day, kind: kind.rawValue, bytes: UInt64(Double(total) * (0.74 + 0.26 * f + wobble))))
            }
            let freeGB = Double(free) / 1e9 + 78 * (1 - f) + 4 * sin(Double(d))
            out.append(.init(day: day, kind: "free", bytes: UInt64(freeGB * 1e9)))
        }
        return out
    }
}
