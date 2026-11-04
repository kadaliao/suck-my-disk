import CFastScan
import DiskIndex
import Foundation
import Insights

/// A Python virtualenv found inside a project; the uv plan combines these with the uv cache.
public struct VenvRef: Sendable {
    public var path: String
    public var project: String
    public var sleeping: Bool
    public var itemID: String
}

/// Finds projects (git repos or package manifests) and their rebuildable artifacts.
public enum ProjectRecognizer {
    static let manifestMask: UInt32 = SM_M_GIT | SM_M_PACKAGE_JSON | SM_M_PYPROJECT | SM_M_CARGO_TOML |
        SM_M_GO_MOD | SM_M_PACKAGE_SWIFT | SM_M_XCODEPROJ | SM_M_POM_XML | SM_M_GRADLE | SM_M_SETUP_PY |
        SM_M_GEMFILE | SM_M_PUBSPEC | SM_M_CMAKE

    static let smallCacheNames: Set<String> = ["__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache"]
    static let jsBuildCaches: Set<String> = [".next", ".nuxt", ".turbo", ".svelte-kit", ".parcel-cache", ".angular"]
    static let genericOutputs: Set<String> = ["build", "dist", "out"]

    struct Artifact {
        var node: NodeID
        var kind: String
        var restore: String?
        var strong: Bool        // evidence is good enough to preselect
        var warnings: [String] = []
        var needsGitCheck = false
    }

    struct Project {
        var node: NodeID
        var path: String
        var artifacts: [Artifact] = []
        var smallCaches: [NodeID] = []
        var newestSource: Int64 = 0
    }

    public static func recognize(_ ctx: RecognizeContext) -> (things: [Thing], venvs: [VenvRef]) {
        let tree = ctx.tree
        var projects: [NodeID: Project] = [:]
        let home = ctx.home

        // Walk with an explicit stack that carries the owning project.
        var stack: [(NodeID, NodeID?)] = tree.children(ScanTree.root).map { ($0, nil) }
        while let (i, owner) = stack.popLast() {
            let n = tree.node(i).pointee
            guard n.flags & SM_F_DIR != 0 else {
                if let owner { bumpSource(&projects[owner]!, n.mtime) }
                continue
            }
            let path = tree.path(i)
            if !ctx.allowAnyPath, isExcluded(path, home: home) { continue }
            if ctx.isOffLimits(path) { continue }
            var owner = owner
            let name = tree.name(i)

            if let o = owner, let art = artifact(tree, i, name: name, owner: projects[o]!) {
                if smallCacheNames.contains(name) {
                    projects[o]!.smallCaches.append(i)
                } else {
                    projects[o]!.artifacts.append(art)
                }
                continue  // never look inside artifacts
            }
            if n.flags & SM_F_COLLAPSED != 0 {
                if let o = owner, name == ".git" { bumpSource(&projects[o]!, n.t_newest) }
                continue
            }
            let isGit = n.markers & SM_M_GIT != 0
            if path != home, (isGit || (owner == nil && n.markers & manifestMask != 0)) {
                projects[i] = Project(node: i, path: path)
                owner = i
            }
            if let o = owner { bumpSource(&projects[o]!, n.mtime) }
            var c = n.first_child
            while c != SM_NONE {
                stack.append((c, owner))
                c = tree.node(c).pointee.next_sibling
            }
        }

        // git checks cost two subprocesses each: only for artifacts big enough to list, in parallel.
        var checks: [(node: NodeID, path: String, project: String)] = []
        for p in projects.values {
            for a in p.artifacts where a.needsGitCheck && tree.size(a.node) >= 1_000_000 {
                checks.append((a.node, tree.path(a.node), p.path))
            }
        }
        let gitResults = gitStatuses(checks)

        let allPaths = Set(projects.values.map(\.path))
        var things: [Thing] = []
        var venvs: [VenvRef] = []
        for p in projects.values {
            guard !p.artifacts.isEmpty || !p.smallCaches.isEmpty else { continue }
            var activity = ctx.activity.lastActivity(forProject: p.path, allProjects: allPaths)
            if p.newestSource > 0 {
                let d = Date(timeIntervalSince1970: TimeInterval(p.newestSource))
                if activity == nil || d > activity!.date { activity = ActivitySignal(date: d, source: L("文件改动", "file changes")) }
            }
            let days = ctx.daysSince(activity?.date) ?? Int.max
            let sleeping = days >= ctx.sleepAfterDays
            var items: [ReclaimItem] = []
            for a in p.artifacts {
                let n = tree.node(a.node).pointee
                let path = tree.path(a.node)
                var a = a
                if a.needsGitCheck {
                    guard let g = gitResults[a.node] else { continue }   // too small to list
                    a = gitChecked(a, g)
                }
                let recent = n.t_newest > 0 && ctx.now.timeIntervalSince1970 - Double(n.t_newest) < 7 * 86400
                var item = ReclaimItem(
                    id: "art:" + path, label: a.kind, path: path, bytes: tree.size(a.node),
                    estimate: n.t_alloc, tier: .regenerable, action: .delete(path: path),
                    restore: a.restore, reason: reason(for: a.kind),
                    preselected: sleeping && a.strong && !recent, warnings: a.warnings)
                if n.t_shared > 0 { item.estimateIsLowerBound = true }
                if item.estimate < 1_000_000 {
                    item.preselected = false
                    if n.t_shared > 0 {
                        item.warnings.append(L("数据几乎都和别处共享（如 pnpm store），单删腾不出空间",
                                               "nearly all data is shared (e.g. with the pnpm store); deleting this alone frees nothing"))
                    }
                }
                if a.needsGitCheck && !a.strong { continue }   // not a build output after all
                if item.bytes < 1_000_000 { continue }
                if recent { item.warnings.append(L("7 天内有改动", "changed in the last 7 days")) }
                if a.kind == "venv" {
                    venvs.append(VenvRef(path: path, project: p.path, sleeping: sleeping, itemID: item.id))
                }
                items.append(item)
            }
            let smallBytes = p.smallCaches.reduce(UInt64(0)) { $0 + tree.size($1) }
            if smallBytes >= 1 << 20 {
                let paths = p.smallCaches.map { tree.path($0) }
                items.append(ReclaimItem(
                    id: "pycache:" + p.path, label: L("Python 缓存 ×\(paths.count)", "Python caches ×\(paths.count)"),
                    path: nil, bytes: smallBytes, tier: .regenerable, action: .deleteAll(paths: paths),
                    restore: nil, reason: L("运行时自动重建", "rebuilt automatically when code runs"),
                    preselected: sleeping))
            }
            let reclaim = items.reduce(UInt64(0)) { $0 + $1.bytes }
            guard reclaim >= 20_000_000 else { continue }
            items.sort { $0.bytes > $1.bytes }
            things.append(Thing(
                id: "project:" + p.path, kind: .project, title: (p.path as NSString).lastPathComponent,
                path: p.path, bytes: tree.size(p.node), lastActive: activity?.date,
                activitySource: activity?.source,
                detail: sleeping ? L("沉睡 \(days == Int.max ? "很久" : "\(days) 天")", "asleep for \(days == Int.max ? "a long time" : "\(days) days")") : nil,
                items: items))
        }
        things.sort { $0.reclaimable > $1.reclaimable }
        return (things, venvs)
    }

    static func bumpSource(_ p: inout Project, _ t: Int64) {
        if t > p.newestSource { p.newestSource = t }
    }

    static func isExcluded(_ path: String, home: String) -> Bool {
        if path == Firmlinks.dataRoot || path == "/" || path == "/Users" { return false }
        guard path.hasPrefix("/Users/") else { return true }
        if path.hasPrefix(home + "/") {
            let rel = path.dropFirst(home.count + 1)
            return rel.hasPrefix(".") || rel.hasPrefix("Library")
        }
        return false
    }

    /// Lock markers from the artifact's directory up to the project root (monorepos keep one at the top).
    static func locks(_ tree: ScanTree, from dir: NodeID, to root: NodeID) -> UInt32 {
        var m: UInt32 = 0
        var cur: NodeID? = dir
        while let c = cur {
            m |= tree.node(c).pointee.markers
            if c == root { break }
            cur = tree.parent(c)
        }
        return m
    }

    static func artifact(_ tree: ScanTree, _ i: NodeID, name: String, owner: Project) -> Artifact? {
        let n = tree.node(i).pointee
        guard let parent = tree.parent(i) else { return nil }
        let pm = tree.node(parent).pointee.markers
        if n.flags & SM_F_PACKAGE != 0 { return nil }

        if smallCacheNames.contains(name) {
            return Artifact(node: i, kind: name, restore: nil, strong: true)
        }
        if name == "node_modules", pm & SM_M_PACKAGE_JSON != 0 {
            let m = locks(tree, from: parent, to: owner.node)
            let restore: String
            if m & SM_M_LOCK_PNPM != 0 { restore = "pnpm install" }
            else if m & SM_M_LOCK_BUN != 0 { restore = "bun install" }
            else if m & SM_M_LOCK_YARN != 0 { restore = "yarn install" }
            else if m & SM_M_LOCK_NPM != 0 { restore = "npm ci" }
            else { restore = "npm install" }
            let locked = m & (SM_M_LOCK_PNPM | SM_M_LOCK_BUN | SM_M_LOCK_YARN | SM_M_LOCK_NPM) != 0
            var a = Artifact(node: i, kind: "node_modules", restore: restore, strong: locked)
            if !locked { a.warnings.append(L("没有锁文件，重装后的版本可能不同", "no lockfile: reinstall may resolve different versions")) }
            return a
        }
        if n.markers & SM_M_PYVENV_CFG != 0 {
            let m = locks(tree, from: parent, to: owner.node)
            let rel = name
            let restore: String
            if m & SM_M_LOCK_UV != 0 { restore = "uv sync" }
            else if m & SM_M_LOCK_POETRY != 0 { restore = "poetry install" }
            else if m & SM_M_PYPROJECT != 0 { restore = "uv sync" }
            else if m & SM_M_REQUIREMENTS != 0 { restore = "python3 -m venv \(rel) && \(rel)/bin/pip install -r requirements.txt" }
            else { restore = "python3 -m venv \(rel)" }
            let locked = m & (SM_M_LOCK_UV | SM_M_LOCK_POETRY) != 0
            var a = Artifact(node: i, kind: "venv", restore: restore, strong: locked)
            if !locked { a.warnings.append(L("没有 uv.lock / poetry.lock，重建的依赖版本可能不同", "no uv.lock / poetry.lock: rebuilt versions may differ")) }
            return a
        }
        if name == "target", n.markers & SM_M_CACHEDIR_TAG != 0 || pm & (SM_M_CARGO_TOML | SM_M_POM_XML) != 0 {
            let restore = pm & SM_M_POM_XML != 0 ? "mvn package" : "cargo build"
            return Artifact(node: i, kind: "target", restore: restore, strong: n.markers & SM_M_CACHEDIR_TAG != 0 || pm & SM_M_CARGO_TOML != 0)
        }
        if jsBuildCaches.contains(name), pm & SM_M_PACKAGE_JSON != 0 {
            return Artifact(node: i, kind: name, restore: "npm run build", strong: true)
        }
        if name == ".build", pm & SM_M_PACKAGE_SWIFT != 0 {
            return Artifact(node: i, kind: ".build", restore: "swift build", strong: true)
        }
        if name == ".gradle", pm & SM_M_GRADLE != 0 {
            return Artifact(node: i, kind: ".gradle", restore: "./gradlew build", strong: true)
        }
        if name == ".dart_tool", pm & SM_M_PUBSPEC != 0 {
            return Artifact(node: i, kind: ".dart_tool", restore: "flutter pub get", strong: true)
        }
        if genericOutputs.contains(name),
           pm & (SM_M_PACKAGE_JSON | SM_M_CMAKE | SM_M_SETUP_PY | SM_M_PYPROJECT | SM_M_GRADLE) != 0,
           tree.node(owner.node).pointee.markers & SM_M_GIT != 0 {
            // Only with ecosystem evidence, and only if git ignores it and tracks nothing in it.
            if subtreeHasMedia(tree, i) { return nil }
            var a = Artifact(node: i, kind: name, restore: pm & SM_M_PACKAGE_JSON != 0 ? "npm run build" : nil, strong: false)
            a.needsGitCheck = true
            return a
        }
        return nil
    }

    static func subtreeHasMedia(_ tree: ScanTree, _ i: NodeID) -> Bool {
        var found = false
        tree.walk(from: i) { j in
            let n = tree.node(j).pointee
            if n.vid_bytes > 0 || n.aud_bytes > 10_000_000 { found = true }
            return !found
        }
        return found
    }

    struct GitStatus: Sendable {
        var ignored = false
        var tracked = false
    }

    static func gitStatuses(_ checks: [(node: NodeID, path: String, project: String)]) -> [NodeID: GitStatus] {
        final class Slot: @unchecked Sendable { var v = GitStatus() }
        let slots = checks.map { _ in Slot() }
        DispatchQueue.concurrentPerform(iterations: checks.count) { i in
            let c = checks[i]
            slots[i].v.ignored = Shell.run(["git", "-C", c.project, "check-ignore", "-q", c.path], timeout: 10).ok
            slots[i].v.tracked = Shell.run(["git", "-C", c.project, "ls-files", "--", c.path], timeout: 20).stdout
                .contains(where: { !$0.isWhitespace })
        }
        var out: [NodeID: GitStatus] = [:]
        for (c, s) in zip(checks, slots) { out[c.node] = s.v }
        return out
    }

    static func gitChecked(_ a: Artifact, _ g: GitStatus) -> Artifact {
        var a = a
        let ignored = g.ignored, tracked = g.tracked
        if ignored && !tracked {
            a.strong = true
        } else {
            a.strong = false
            a.warnings.append(tracked ? L("里面有 git 跟踪的文件，不会删", "contains git-tracked files")
                                      : L("没有被 git 忽略，可能不是构建产物", "not ignored by git: may not be a build output"))
        }
        return a
    }

    static func reason(for kind: String) -> String {
        switch kind {
        case "node_modules": return L("npm 依赖，可以按锁文件重新安装", "npm dependencies, reinstallable from the lockfile")
        case "venv": return L("Python 虚拟环境，可以重建", "Python virtualenv, can be recreated")
        case "target": return L("Rust/Java 编译产物，重新编译即可", "Rust/Java build output, rebuilt by compiling")
        case ".build": return L("SwiftPM 编译产物", "SwiftPM build output")
        case ".gradle": return L("Gradle 缓存", "Gradle cache")
        case ".dart_tool": return L("Dart/Flutter 工具缓存", "Dart/Flutter tool cache")
        default:
            if jsBuildCaches.contains(kind) { return L("前端构建缓存", "front-end build cache") }
            return L("构建输出，被 git 忽略", "build output ignored by git")
        }
    }
}
