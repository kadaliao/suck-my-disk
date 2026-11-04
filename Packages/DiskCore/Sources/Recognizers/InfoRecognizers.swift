import CFastScan
import DiskIndex
import Insights
import Foundation

/// Models, app data and system space: mostly explained, rarely deleted by us.
public enum ModelRecognizer {
    public static func recognize(_ ctx: RecognizeContext) -> [Thing] {
        var things: [Thing] = []
        let h = ctx.home
        let tree = ctx.tree

        // Ollama: manifests list layers by digest; shared blobs are counted once.
        let ollama = h + "/.ollama/models"
        if FileManager.default.fileExists(atPath: ollama + "/manifests"), Shell.which("ollama") != nil {
            var items: [ReclaimItem] = []
            if let e = FileManager.default.enumerator(atPath: ollama + "/manifests") {
                var seen: Set<String> = []
                while let rel = e.nextObject() as? String {
                    let p = ollama + "/manifests/" + rel
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
                          let data = FileManager.default.contents(atPath: p),
                          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let layers = j["layers"] as? [[String: Any]] else { continue }
                    var size: UInt64 = 0
                    for l in layers {
                        guard let dg = l["digest"] as? String, let s = l["size"] as? NSNumber else { continue }
                        if seen.insert(dg).inserted { size += s.uint64Value }
                    }
                    let parts = rel.split(separator: "/")
                    guard parts.count >= 2 else { continue }
                    let name = parts.count >= 3 && parts[parts.count - 3] != "library"
                        ? "\(parts[parts.count - 3])/\(parts[parts.count - 2]):\(parts.last!)"
                        : "\(parts[parts.count - 2]):\(parts.last!)"
                    let pulled = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
                    items.append(ReclaimItem(
                        id: "ollama:" + name, label: name, path: nil, bytes: size, tier: .regenerable,
                        action: .command(argv: ["ollama", "rm", name], cwd: nil),
                        restore: "ollama pull \(name)",
                        reason: L("下载于 \(Fmt.ago(pulled))，可以重新 pull", "pulled \(Fmt.ago(pulled)), can be pulled again"),
                        preselected: false))
                }
            }
            if !items.isEmpty {
                things.append(Thing(id: "model:ollama", kind: .model, title: "Ollama", path: ollama,
                                    bytes: ctx.size(ollama), items: items.sorted { $0.bytes > $1.bytes }))
            }
        }

        // Hugging Face hub: one folder per repo (models--org--name).
        for (id, title, base) in [("hf", "Hugging Face", h + "/.cache/huggingface/hub"),
                                  ("modelscope", "ModelScope", h + "/.cache/modelscope/hub")] {
            guard let node = tree.find(base) else { continue }
            var items: [ReclaimItem] = []
            tree.walk(from: node) { j in
                let name = tree.name(j)
                if j != node, tree.size(j) >= 100_000_000,
                   name.hasPrefix("models--") || name.hasPrefix("datasets--") || (id == "modelscope" && tree.parent(j) != node) {
                    let label = name.replacingOccurrences(of: "models--", with: "").replacingOccurrences(of: "datasets--", with: "")
                        .replacingOccurrences(of: "--", with: "/")
                    let path = tree.path(j)
                    let action: ReclaimAction = id == "hf" && Shell.which("hf") != nil
                        ? .command(argv: ["hf", "cache", "rm", label, "-y"], cwd: nil) : .delete(path: path)
                    items.append(ReclaimItem(id: "\(id):" + label, label: label, path: path, bytes: tree.size(j),
                                             tier: .regenerable, action: action, restore: L("用到时会重新下载", "re-downloaded when used"),
                                             reason: L("最后改动 \(Fmt.ago(tree.newest(j)))", "last changed \(Fmt.ago(tree.newest(j)))"),
                                             preselected: false))
                    return false
                }
                return j == node || id == "modelscope"
            }
            if !items.isEmpty {
                things.append(Thing(id: "model:" + id, kind: .model, title: title, path: base, bytes: tree.size(node),
                                    items: items.sorted { $0.bytes > $1.bytes }))
            }
        }

        // LM Studio and any other big weight files elsewhere.
        let lms = h + "/.lmstudio/models"
        if let node = tree.find(lms), tree.size(node) >= 100_000_000 {
            var items: [ReclaimItem] = []
            for pub in tree.children(node) {
                for repo in tree.children(pub) where tree.size(repo) >= 100_000_000 {
                    let path = tree.path(repo)
                    items.append(ReclaimItem(id: "lms:" + path, label: tree.name(pub) + "/" + tree.name(repo), path: path,
                                             bytes: tree.size(repo), tier: .yours, action: .trash(path: path),
                                             reason: L("LM Studio 模型", "LM Studio model"), preselected: false))
                }
            }
            if !items.isEmpty {
                things.append(Thing(id: "model:lmstudio", kind: .model, title: "LM Studio", path: lms,
                                    bytes: tree.size(node), items: items.sorted { $0.bytes > $1.bytes }))
            }
        }
        return things
    }
}

public enum AppDataRecognizer {
    struct Known { var path: String; var title: String; var advice: (zh: String, en: String) }

    public static func recognize(_ ctx: RecognizeContext) -> [Thing] {
        let h = ctx.home
        let known: [Known] = [
            Known(path: h + "/Library/Containers/com.tencent.xinWeChat", title: L("微信", "WeChat"),
                  advice: ("在微信里打开 设置 → 通用 → 存储空间 清理聊天文件", "In WeChat: Settings → General → Storage")),
            Known(path: h + "/Library/Application Support/Google/Chrome", title: "Chrome",
                  advice: ("在 Chrome 设置 → 隐私 → 清除浏览数据 里清缓存；不要直接删这个文件夹", "Use Chrome's Clear browsing data; don't delete the folder")),
            Known(path: h + "/Library/Application Support/Claude/vm_bundles", title: L("Claude 虚拟机镜像", "Claude VM bundles"),
                  advice: ("Claude 桌面版运行代码用的虚拟机，删了会重新下载", "VM images used by the Claude app; re-downloaded if removed")),
            Known(path: h + "/Library/Group Containers/HUAQ24HBR6.dev.orbstack", title: L("OrbStack 虚拟机", "OrbStack VM"),
                  advice: ("在“开发缓存”里清 Docker 构建缓存和悬空镜像；~/OrbStack 是它的挂载点，不另占空间",
                           "Prune Docker build cache under Dev caches; ~/OrbStack is a mount, not extra space")),
            Known(path: h + "/Library/Application Support/LarkShell", title: L("飞书", "Lark"),
                  advice: ("在飞书 设置 → 通用 → 清理缓存", "In Lark: Settings → General → Clear cache")),
            Known(path: h + "/Library/Application Support/Notion", title: "Notion",
                  advice: ("在 Notion 设置里清缓存，或退出后删 Partitions 下的 Cache", "Clear cache in Notion settings")),
            Known(path: h + "/Library/Application Support/MobileSync/Backup", title: L("iPhone 备份", "iPhone backups"),
                  advice: ("在 访达 → 你的 iPhone → 管理备份 里删除旧备份", "Finder → your iPhone → Manage Backups")),
        ]
        var things: [Thing] = []
        for k in known {
            let bytes = ctx.size(k.path)
            guard bytes >= 1_000_000_000 else { continue }
            things.append(Thing(id: "app:" + k.path, kind: .appData, title: k.title, path: k.path, bytes: bytes,
                                detail: L(k.advice.zh, k.advice.en),
                                items: [ReclaimItem(id: "app:" + k.path, label: k.title, path: k.path, bytes: bytes,
                                                    tier: .guide, action: .none, reason: L(k.advice.zh, k.advice.en),
                                                    preselected: false)]))
        }
        return things.sorted { $0.bytes > $1.bytes }
    }
}

public enum SystemRecognizer {
    public static func recognize(_ ctx: RecognizeContext, volume: VolumeInfo) -> [Thing] {
        var things: [Thing] = []
        let trash = ctx.home + "/.Trash"
        let tb = ctx.size(trash)
        if tb >= 100_000_000 {
            things.append(Thing(id: "system:trash", kind: .system, title: L("废纸篓", "Trash"), path: trash, bytes: tb,
                                detail: L("放进废纸篓的东西还占着空间，清空后才会腾出", "items in the Trash still use space until it is emptied"),
                                items: [ReclaimItem(id: "system:trash", label: L("清空废纸篓", "Empty Trash"), path: trash, bytes: tb,
                                                    tier: .yours, action: .command(argv: ["osascript", "-e", "tell application \"Finder\" to empty trash"], cwd: nil),
                                                    reason: L("这些是你之前删掉的文件", "files you deleted earlier"), preselected: false)]))
        }
        let snaps = Shell.run(["tmutil", "listlocalsnapshots", "/"], timeout: 10).stdout
            .split(separator: "\n").filter { $0.hasPrefix("com.apple") }
        if !snaps.isEmpty {
            things.append(Thing(id: "system:snapshots", kind: .system, title: L("本地快照", "Local snapshots"), path: nil, bytes: 0,
                                detail: L("\(snaps.count) 个系统快照（更新或时间机器创建）。快照占用的空间扫描不到；有快照时，删掉文件也不会立刻腾出空间。",
                                          "\(snaps.count) system snapshots. Their space can't be measured by scanning, and deleted files stay allocated while a snapshot holds them."),
                                items: []))
        }
        let scanned = ctx.tree.uniqueTotal
        let hidden = volume.dataUsed > scanned ? volume.dataUsed - scanned : 0
        things.append(Thing(id: "system:hidden", kind: .system, title: L("数据卷里扫描不到的部分", "Not visible to the scan"), path: nil,
                            bytes: hidden,
                            detail: L("数据卷已用 \(Fmt.bytes(volume.dataUsed)) − 扫描到 \(Fmt.bytes(scanned))：快照占用、没有权限读的目录（\(ctx.tree.stats.denied_dirs) 个）等。可清除空间约 \(Fmt.bytes(volume.purgeable))，macOS 需要时会自动释放。",
                                      "data volume used \(Fmt.bytes(volume.dataUsed)) − scanned \(Fmt.bytes(scanned)): snapshot space, unreadable folders (\(ctx.tree.stats.denied_dirs)), etc. About \(Fmt.bytes(volume.purgeable)) is purgeable; macOS frees it when needed."),
                            items: []))
        if volume.otherVolumes > 0 {
            things.append(Thing(id: "system:volumes", kind: .system, title: L("系统卷和虚拟内存", "System, VM and other volumes"), path: nil,
                                bytes: volume.otherVolumes,
                                detail: L("同一块盘上的 macOS 系统卷、交换文件、Preboot、Recovery 等，由系统管理",
                                          "the sealed macOS volume, swap, Preboot, Recovery…, managed by macOS"),
                                items: []))
        }
        return things
    }
}
