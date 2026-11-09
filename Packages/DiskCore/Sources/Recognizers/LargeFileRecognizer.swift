import CFastScan
import CoreServices
import DiskIndex
import Foundation
import Insights

/// Big files nothing else explains: installers left in Downloads, videos, disk images and
/// virtual machines, archives, model weights outside the model stores, apps outside
/// Applications. Only what the other recognizers didn't already list, only in the home folder
/// (not its Library or dot folders, which belong to apps and tools) and /Users/Shared.
///
/// They are your files: listed largest first per kind, never preselected, moved to the Trash.
/// Files git tracks are left out, since the executor would refuse them anyway.
public enum LargeFileRecognizer {
    public enum Group: String, CaseIterable, Sendable {
        case installer, vm, video, audio, archive, model, app, other

        public var title: String {
            switch self {
            case .installer: return L("安装包和磁盘映像", "Installers and disk images")
            case .vm: return L("虚拟机", "Virtual machines")
            case .video: return L("视频", "Videos")
            case .audio: return L("音频", "Audio")
            case .archive: return L("压缩包", "Archives")
            case .model: return L("模型权重", "Model weights")
            case .app: return L("「应用程序」以外的应用", "Apps outside Applications")
            case .other: return L("其他大文件", "Other large files")
            }
        }
    }

    static let fileGroups: [Group: Set<String>] = [
        .installer: ["dmg", "iso", "img", "pkg", "mpkg", "xip", "ipsw", "sparseimage", "cdr", "toast"],
        .vm: ["vmdk", "vdi", "qcow2", "vhd", "vhdx", "ova", "hdd"],
        .video: ["mp4", "mov", "m4v", "mkv", "avi", "webm", "flv", "wmv", "mts", "m2ts", "mpg", "mpeg", "3gp", "mxf"],
        .audio: ["wav", "aif", "aiff", "flac", "mp3", "m4a", "aac", "ogg", "caf", "ape"],
        .archive: ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "7z", "rar", "lz4", "lzma"],
        .model: ["gguf", "safetensors", "ckpt", "pt", "pth", "onnx", "mlmodel", "npz", "h5"],
    ]
    /// Bundles worth listing as one file. Libraries (Photos, Final Cut…) are never touched.
    static let packageGroups: [String: Group] = [
        "app": .app, "sparsebundle": .installer, "pvm": .vm, "vmwarevm": .vm, "utm": .vm,
    ]

    /// Pieces of something bigger that are useless, or harmful, to remove one by one:
    /// an encrypted Cryptomator vault's chunks.
    static let pieces: Set<String> = ["c9r", "c9s"]

    /// The group a file or bundle belongs to; nil for what isn't listed.
    public static func group(of name: String, package: Bool) -> Group? {
        let ext = (name as NSString).pathExtension.lowercased()
        if package { return packageGroups[ext] }
        if pieces.contains(ext) { return nil }
        return fileGroups.first { $0.value.contains(ext) }?.key ?? .other
    }

    /// Kept per group, largest first, so an expanded group stays a reasonable length.
    static let perGroup = 50

    /// - Parameters:
    ///   - covered: paths other recognizers already offer; nothing inside them is listed.
    ///   - apps: installed apps, to tell which installers were already used.
    ///   - minBytes: smallest file listed; installers are listed from `minInstallerBytes`.
    public static func recognize(_ ctx: RecognizeContext, covered: [String], apps: [AppRecognizer.App]? = nil,
                                 minBytes: UInt64 = 100_000_000, minInstallerBytes: UInt64 = 20_000_000) -> [Thing] {
        let tree = ctx.tree
        let roots: [NodeID] = ctx.allowAnyPath
            ? tree.children(ScanTree.root)
            : [ctx.home, "/Users/Shared"].compactMap { tree.find($0) }
        let skip = Set(covered.compactMap { tree.find($0) } + [tree.find(ctx.home + "/Library")].compactMap { $0 })
        let floor = min(minBytes, minInstallerBytes)

        typealias Hit = (node: NodeID, group: Group)
        var hits: [Hit] = []
        for r in roots {
            tree.walk(from: r) { j in
                if j == r { return true }
                let n = tree.node(j).pointee
                // Nothing big enough below: the cheap test first.
                guard n.t_alloc + n.t_shared >= floor else { return false }
                if n.flags & (SM_F_DETACHED | SM_F_MOUNTPOINT | SM_F_DENIED | SM_F_DATALESS) != 0 || skip.contains(j) { return false }
                let name = tree.name(j)
                if name.hasPrefix(".") { return false }   // dot folders belong to tools
                let size = n.t_alloc + n.t_shared
                if n.flags & SM_F_FILE != 0 {
                    if let g = group(of: name, package: false), size >= (g == .installer ? minInstallerBytes : minBytes) {
                        hits.append((j, g))
                    }
                    return false
                }
                if n.flags & SM_F_PACKAGE != 0 {
                    if let g = group(of: name, package: true), size >= minBytes { hits.append((j, g)) }
                    return false
                }
                return n.flags & SM_F_COLLAPSED == 0
            }
        }
        // A model split into shards goes as one folder: trashing a single shard breaks it.
        var models: [NodeID: Bool] = [:]
        for h in hits where h.group == .model {
            if let m = modelFolder(tree, h.node, stops: Set(roots).union(skip), hits: hits) { models[m] = true }
        }
        if !models.isEmpty {
            hits.removeAll { h in
                var cur: NodeID? = h.node
                while let c = cur, c != ScanTree.root { if models[c] != nil { return true }; cur = tree.parent(c) }
                return false
            }
            hits += models.keys.map { ($0, .model) }
        }
        // Leave out what can't be moved anyway: protected places, privacy-guarded folders, git-tracked files.
        hits.removeAll { h in
            let p = tree.path(h.node)
            return Guards.isDenied(p) || ctx.isOffLimits(p)
        }
        let tracked = trackedByGit(tree, hits.map(\.node))
        hits.removeAll { tracked.contains($0.node) }

        let installed = installedNames(apps ?? AppRecognizer.installed(in: ["/Applications", ctx.home + "/Applications"]))
        var things: [Thing] = []
        for g in Group.allCases {
            let all = hits.filter { $0.group == g }.sorted { tree.size($0.node) > tree.size($1.node) }
            guard !all.isEmpty else { continue }
            let shown = all.prefix(perGroup)
            let items = shown.map { item(ctx, $0.node, group: g, installed: installed) }
            let rest = all.dropFirst(perGroup)
            var detail = L("\(all.count) 个", all.count == 1 ? "1 item" : "\(all.count) items")
            if g == .other {
                detail += L("，类型认不出来，可能是别的程序在用的数据", "; types not recognized, so they may be another program's data")
            }
            if !rest.isEmpty {
                let b = rest.reduce(UInt64(0)) { $0 + tree.size($1.node) }
                detail += L("，列出最大的 \(shown.count) 个，其余 \(rest.count) 个共 \(Fmt.bytes(b))",
                            "; the largest \(shown.count) listed, the other \(rest.count) add up to \(Fmt.bytes(b))")
            }
            things.append(Thing(id: "large:" + g.rawValue, kind: .largeFile, title: g.title, path: nil,
                                bytes: items.reduce(0) { $0 + $1.bytes }, detail: detail, items: items))
        }
        return things.sorted { $0.bytes > $1.bytes }
    }

    static func item(_ ctx: RecognizeContext, _ j: NodeID, group g: Group, installed: [String: String]) -> ReclaimItem {
        let tree = ctx.tree
        let n = tree.node(j).pointee
        let path = tree.path(j)
        let name = tree.name(j)
        var parts: [String] = []
        if g == .installer, let app = installedApp(for: name, installed) {
            parts.append(L("已经装了 \(app)", "\(app) is already installed"))
        }
        if g == .app { parts.append(L("不在「应用程序」文件夹里", "not in the Applications folder")) }
        let meta = MDItemCreate(kCFAllocatorDefault, path as CFString)
        if let meta, let used = MDItemCopyAttribute(meta, kMDItemLastUsedDate) as? Date {
            parts.append(L("上次打开 \(Fmt.ago(used, now: ctx.now))", "last opened \(Fmt.ago(used, now: ctx.now))"))
        }
        if let meta, let from = (MDItemCopyAttribute(meta, kMDItemWhereFroms) as? [String])?.lazy.compactMap({ host($0) }).first {
            parts.append(L("下载自 \(from)", "downloaded from \(from)"))
        }
        let changed = tree.newest(j)
        parts.append(L("修改于 \(Fmt.ago(changed, now: ctx.now))", "modified \(Fmt.ago(changed, now: ctx.now))"))

        var warnings: [String] = []
        if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            warnings.append(L("在 iCloud 云盘里：移到废纸篓会从你所有的设备上删掉", "In iCloud Drive: moving it to the Trash removes it from all your devices"))
        }
        if ["/Music/Music/Media", "/Music/iTunes/iTunes Media", "/Movies/TV/Media"].contains(where: { path.contains($0) }) {
            warnings.append(L("「音乐」或「视频」App 资料库里的文件：在 App 里删，资料库才不会留下找不到的条目",
                              "Part of the Music or TV library: delete it in the app so the library doesn't keep a broken entry"))
        }
        if g == .vm {
            warnings.append(L("虚拟机的整块磁盘：确认里面没有要留的东西", "A whole virtual machine disk: make sure nothing in it is still needed"))
        }
        // Your files keep the 7-day rule even when ticked.
        if let d = Guards.recentChange(path, now: ctx.now) { warnings.append(Guards.waitNote(changed: d)) }

        var item = ReclaimItem(id: "large:" + path, label: name, path: path, bytes: tree.size(j), estimate: n.t_alloc,
                               tier: .yours, action: .trash(path: path), restore: L("从废纸篓放回", "put back from the Trash"),
                               reason: parts.joined(separator: " · "), preselected: false, warnings: warnings)
        item.estimateIsLowerBound = n.t_shared > 0
        return item
    }

    static func host(_ url: String) -> String? {
        guard let h = URL(string: url)?.host, !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    // MARK: models

    /// The folder a model's weights belong to: a diffusers pipeline (model_index.json), or a
    /// Hugging Face style folder with config.json next to its shards. Nil when the file stands
    /// alone, when the folder is a project, or when weights are less than half of it.
    static func modelFolder(_ tree: ScanTree, _ file: NodeID, stops: Set<NodeID>, hits: [(node: NodeID, group: Group)]) -> NodeID? {
        var found: NodeID?
        var cur = tree.parent(file)
        for depth in 0..<4 {
            guard let c = cur, c != ScanTree.root, !stops.contains(c) else { break }
            if tree.node(c).pointee.markers & ProjectRecognizer.manifestMask != 0 { break }
            let p = tree.path(c)
            if FileManager.default.fileExists(atPath: p + "/model_index.json") { found = c; break }
            if depth == 0, FileManager.default.fileExists(atPath: p + "/config.json") { found = c }
            cur = tree.parent(c)
        }
        guard let f = found else { return nil }
        let prefix = tree.path(f) + "/"
        let weights = hits.filter { $0.group == .model && tree.path($0.node).hasPrefix(prefix) }
            .reduce(UInt64(0)) { $0 + tree.size($1.node) }
        return weights * 2 >= tree.size(f) ? f : nil
    }

    // MARK: installers

    /// "googlechrome" → "Google Chrome": installed apps by their names with only letters and digits.
    static func installedNames(_ apps: [AppRecognizer.App]) -> [String: String] {
        var out: [String: String] = [:]
        for a in apps {
            for n in [a.name] + a.folderNames {
                let k = squash(n)
                if k.count >= 3, out[k] == nil { out[k] = a.name }
            }
        }
        return out
    }

    static func squash(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The installed app an installer is for, by its file name: "Cursor-darwin-arm64.dmg",
    /// "OrbStack_v1.9.2_arm64.dmg" and "googlechrome.dmg" all name their app in the first words.
    static func installedApp(for file: String, _ installed: [String: String]) -> String? {
        var base = file
        while true {   // "x.tar.gz" → "x"
            let ext = (base as NSString).pathExtension
            guard !ext.isEmpty, ext.count <= 4, ext.allSatisfy(\.isLetter) else { break }
            base = (base as NSString).deletingPathExtension
        }
        let words = base.lowercased().split(whereSeparator: { " -_.()[]+".contains($0) })
        var key = ""
        for w in words {
            // Version numbers and platform tags end the name.
            if w.first?.isNumber == true || (w.first == "v" && w.dropFirst().first?.isNumber == true) { break }
            key += squash(String(w))
            if key.count >= 3, let app = installed[key] { return app }
        }
        return nil
    }

    // MARK: git

    /// The hits git tracks: one `git ls-files` per repository, in parallel.
    static func trackedByGit(_ tree: ScanTree, _ nodes: [NodeID]) -> Set<NodeID> {
        var byRepo: [NodeID: [NodeID]] = [:]
        for j in nodes {
            var cur = tree.parent(j)
            while let c = cur, c != ScanTree.root {
                if tree.has(c, marker: SM_M_GIT) { byRepo[c, default: []].append(j); break }
                cur = tree.parent(c)
            }
        }
        let repos = Array(byRepo)
        final class Slot: @unchecked Sendable { var v: Set<NodeID> = [] }
        let slots = repos.map { _ in Slot() }
        // Paths relative to the repository: git compares absolute ones with its resolved root
        // (/private/var for /var), and would call them outside the repository.
        let paths = repos.map { r in
            let root = tree.path(r.key)
            return (root, r.value.map { (node: $0, rel: String(tree.path($0).dropFirst(root.count + 1))) })
        }
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            let (root, files) = paths[i]
            let r = Shell.run(["git", "-C", root, "ls-files", "-z", "--"] + files.map { ":(literal)" + $0.rel }, timeout: 30)
            // Fails closed: if git can't answer, treat them all as tracked.
            guard r.ok else { slots[i].v = Set(files.map(\.node)); return }
            let listed = r.stdout.split(separator: "\0").map(String.init)
            for f in files where listed.contains(where: { $0 == f.rel || $0.hasPrefix(f.rel + "/") }) {
                slots[i].v.insert(f.node)
            }
        }
        return slots.reduce(into: Set<NodeID>()) { $0.formUnion($1.v) }
    }
}
