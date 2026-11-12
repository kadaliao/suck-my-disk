import Darwin
import DiskIndex
import Foundation
import Insights

/// Installed apps and the data they keep in ~/Library. Each app can be uninstalled (the app
/// and all its data go to the Trash) or kept, deleting only what it rebuilds itself: caches,
/// logs and saved window state. Nothing is preselected.
///
/// Data is matched to an app by bundle id: `com.tinyspeck.slackmacgap`, and names that extend
/// it such as `….ShipIt` or an extension's `….FinderSync`, which go to the app with the longest
/// matching id. In Application Support, Caches and Logs a folder named exactly like the app
/// counts too, unless the name is generic or two apps share it.
public enum AppRecognizer {
    public struct App: Sendable {
        public var path: String
        public var id: String
        /// As Finder shows it.
        public var name: String
        /// Names its folders may use: the file name and `CFBundleName`.
        public var folderNames: [String]
        public var appStore: Bool
        /// Can be moved without an administrator's password.
        public var movable: Bool
    }

    /// One of an app's folders or files in ~/Library.
    struct Place {
        var path: String
        var bytes: UInt64
        var cache: Bool
        /// Inside another of the app's places (an Electron cache inside Application Support).
        var inside = false
    }

    static let selfID = "com.kadaliao.SuckMyDisk"

    /// On an app that belongs to the system. The app leaves it out once its helper is on.
    public static var passwordWarning: String {
        L("移到废纸篓时，访达会要管理员密码", "Finder will ask for an administrator password to move it to the Trash")
    }

    /// Folder names too generic to belong to one app.
    static let genericNames: Set<String> = ["google", "microsoft", "adobe", "apple", "python", "java", "electron",
                                            "code", "helper", "settings", "preferences", "updater", "installer",
                                            "uninstaller", "launcher", "setup", "default", "data", "cache", "logs"]

    /// Where Electron and Chromium apps keep caches inside their Application Support folder.
    static let innerCaches = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
                              "GrShaderCache", "ShaderCache", "CachedData", "Service Worker/CacheStorage",
                              "Service Worker/ScriptCache", "logs"]

    /// - Parameters:
    ///   - appFolders: where apps are installed; default /Applications and ~/Applications (and one folder down).
    ///   - library: the Library folder their data is in; default ~/Library.
    ///   - systemFolders: where apps put components for every user, which uninstalling here leaves alone.
    ///   - caskrooms: Homebrew's record of the apps it installed.
    public static func recognize(_ ctx: RecognizeContext, appFolders: [String]? = nil, library: String? = nil,
                                 systemFolders: [String] = ["/Library/LaunchDaemons", "/Library/LaunchAgents",
                                                            "/Library/PrivilegedHelperTools"],
                                 caskrooms: [String] = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]) -> [Thing] {
        let apps = installed(in: appFolders ?? ["/Applications", ctx.home + "/Applications"])
        guard !apps.isEmpty else { return [] }
        let places = data(for: apps, ctx: ctx, library: library ?? ctx.home + "/Library")
        let system = systemFolders.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        let casks = caskApps(caskrooms)
        var vendors: [String: Int] = [:]
        for a in apps { if let v = vendor(a.id) { vendors[v, default: 0] += 1 } }

        return apps.indices.map { i in
            let app = apps[i]
            let own = places[i]
            let top = own.filter { !$0.inside }
            let caches = own.filter(\.cache)
            let appBytes = ctx.size(app.path)
            let dataBytes = top.reduce(UInt64(0)) { $0 + $1.bytes }
            let cacheBytes = caches.reduce(UInt64(0)) { $0 + $1.bytes }
            let file = (app.path as NSString).lastPathComponent

            var warnings: [String] = []
            if !app.movable {
                warnings.append(passwordWarning)
            }
            // Components for every user (daemons, privileged helpers): named after the app, or
            // after its developer when no other installed app comes from them.
            let low = app.id.lowercased()
            let parts = system.filter { n in
                let k = n.lowercased()
                return k.hasPrefix(low) || (vendor(app.id).map { vendors[$0] == 1 && k.hasPrefix($0 + ".") } ?? false)
            }
            if !parts.isEmpty {
                let names = parts.prefix(2).joined(separator: L("、", ", ")) + (parts.count > 2 ? "…" : "")
                warnings.append(L("它在系统里还装了组件（\(names)），这里卸载不会动它们；有自带的卸载程序的话最好用它",
                                  "It installed system components (\(names)) that uninstalling here leaves in place; use its own uninstaller if it has one"))
            }
            if let token = casks[file] {
                warnings.append(L("用 Homebrew 装的：卸载后再运行 brew uninstall --cask \(token)，Homebrew 才会忘掉它，命令行链接也会删掉",
                                  "Installed with Homebrew: run brew uninstall --cask \(token) afterwards so Homebrew forgets it and removes its command-line links"))
            }
            if app.path.contains("/Applications/Setapp/") {
                warnings.append(L("Setapp 管理的应用：在 Setapp 里卸载更好，不然它可能会再装回来",
                                  "Managed by Setapp: uninstall it there, or Setapp may install it again"))
            }
            let restore = app.appStore ? L("从 App Store 重新安装；数据可以从废纸篓放回", "reinstall from the App Store; put the data back from the Trash")
                : casks[file].map { "brew install --cask \($0)" } ?? L("从废纸篓放回", "put back from the Trash")
            let reason = top.isEmpty
                ? L("应用移到废纸篓；资源库里没找到它的数据", "the app goes to the Trash; none of its data was found in your Library")
                : L("应用 \(Fmt.bytes(appBytes))，连同资源库里 \(top.count) 处数据 \(Fmt.bytes(dataBytes))，一起移到废纸篓",
                    "the app (\(Fmt.bytes(appBytes))) and its data in \(top.count) places in your Library (\(Fmt.bytes(dataBytes))) go to the Trash")
            var uninstall = ReclaimItem(
                id: "apps:uninstall:" + app.path, label: L("卸载 \(app.name)", "Uninstall \(app.name)"), path: app.path,
                bytes: appBytes + dataBytes, tier: .yours,
                action: .compound(actions: [.trash(path: app.path)] + top.map { .trash(path: $0.path) }),
                restore: restore, reason: reason, preselected: false, warnings: warnings, app: app.path)
            var items = [uninstall]
            if cacheBytes >= 1_000_000 {
                let c = ReclaimItem(
                    id: "apps:caches:" + app.path, label: L("\(app.name) 的缓存", "\(app.name) caches"), path: nil,
                    bytes: cacheBytes, tier: .regenerable, action: .deleteAll(paths: caches.map(\.path)),
                    restore: L("应用下次打开时会重建", "rebuilt when the app next runs"),
                    reason: L("缓存、日志和窗口状态，删掉后应用会自己重建；应用和你的数据都留着",
                              "caches, logs and saved window state, which the app rebuilds; the app and your data stay"),
                    preselected: false, app: app.path)
                uninstall.covers = [c.id]
                items = [uninstall, c]
            }
            let opened = lastOpened(app.path)
            let idle = ctx.daysSince(opened).flatMap { $0 >= 90 ? $0 : nil }
            return Thing(id: "apps:" + app.path, kind: .app, title: app.name, path: app.path, bytes: appBytes + dataBytes,
                         lastActive: opened, detail: idle.map { L("\($0) 天没打开", "unused for \($0) days") }, items: items)
        }
    }

    // MARK: apps

    /// The apps in `folders` and in their subfolders (vendor folders such as "Adobe Photoshop"),
    /// except Utilities, symlinks, apps macOS protects, and SuckMyDisk itself.
    public static func installed(in folders: [String]) -> [App] {
        let fm = FileManager.default
        var out: [App] = []
        var seen: Set<String> = []
        func add(_ path: String) {
            if seen.insert(path).inserted, let a = read(path) { out.append(a) }
        }
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for n in names.sorted() where !n.hasPrefix(".") {
                let p = folder + "/" + n
                if n.hasSuffix(".app") { add(p); continue }
                guard n != "Utilities", isDir(p), let inner = try? fm.contentsOfDirectory(atPath: p) else { continue }
                for m in inner.sorted() where m.hasSuffix(".app") && !m.hasPrefix(".") { add(p + "/" + m) }
            }
        }
        return out
    }

    static func isDir(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func read(_ path: String) -> App? {
        var st = stat()
        // Symlinks (Safari in /Applications is one) and anything System Integrity Protection guards are left out.
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_flags & UInt32(SF_RESTRICTED) == 0 else { return nil }
        // iPhone and iPad apps keep their Info.plist in a wrapper.
        guard let info = [path + "/Contents/Info.plist", path + "/WrappedBundle/Info.plist"]
                .lazy.compactMap({ NSDictionary(contentsOfFile: $0) as? [String: Any] }).first,
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty, id != selfID else { return nil }
        let fm = FileManager.default
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var names = [file]
        if let n = info["CFBundleName"] as? String, !n.isEmpty, n != file { names.append(n) }
        var shown = fm.displayName(atPath: path)
        if shown.hasSuffix(".app") { shown = String(shown.dropLast(4)) }
        let parent = (path as NSString).deletingLastPathComponent
        return App(path: path, id: id, name: shown.isEmpty ? file : shown, folderNames: names,
                   appStore: fm.fileExists(atPath: path + "/Contents/_MASReceipt") || fm.fileExists(atPath: path + "/Wrapper"),
                   movable: access(path, W_OK) == 0 && access(parent, W_OK) == 0)
    }

    /// When the app was last opened: the date Finder and the Dock record on it, or Spotlight's.
    static func lastOpened(_ path: String) -> Date? {
        var ts = timespec()
        let n = getxattr(path, "com.apple.lastuseddate#PS", &ts, MemoryLayout<timespec>.size, 0, 0)
        let xattr = n >= MemoryLayout<Int>.size && ts.tv_sec > 0 ? Date(timeIntervalSince1970: TimeInterval(ts.tv_sec)) : nil
        let spotlight = ActivityIndex.spotlightLastUsed(path)
        return [xattr, spotlight].compactMap { $0 }.max()
    }

    /// "com.vendor" for "com.vendor.app"; nil for ids too short to have a vendor part.
    static func vendor(_ id: String) -> String? {
        let p = id.lowercased().split(separator: ".")
        return p.count >= 3 ? p.prefix(2).joined(separator: ".") : nil
    }

    // MARK: data

    /// Each app's places in `library`, in the order of `apps`. A place belongs to one app at most.
    static func data(for apps: [App], ctx: RecognizeContext, library: String) -> [[Place]] {
        let tree = ctx.tree
        var byID: [String: Int] = [:]
        for (i, a) in apps.enumerated() where byID[a.id.lowercased()] == nil { byID[a.id.lowercased()] = i }
        var byName: [String: Int] = [:]
        var shared: Set<String> = []
        for (i, a) in apps.enumerated() {
            for n in Set(a.folderNames.map { $0.lowercased() }) where n.count >= 3 && !genericNames.contains(n) {
                if let j = byName[n], j != i { shared.insert(n) } else { byName[n] = i }
            }
        }
        for n in shared { byName[n] = nil }

        /// The app whose id is `key`, or the longest id `key` extends (`com.a.app.helper` → `com.a.app`).
        func owner(_ key: String) -> Int? {
            var k = key.lowercased()
            if let i = byID[k] { return i }
            while let dot = k.lastIndex(of: ".") {
                k = String(k[..<dot])
                guard k.split(separator: ".").count >= 3 else { return nil }   // an app's id, never just a vendor's
                if let i = byID[k] { return i }
            }
            return nil
        }

        struct Entry { var name: String; var path: String; var bytes: UInt64 }
        /// Folders, from the index: no disk reads, and privacy-protected ones are simply absent.
        func folders(_ rel: String) -> [Entry] {
            let base = library + "/" + rel
            guard !ctx.isOffLimits(base), let node = tree.find(base) else { return [] }
            return tree.children(node).filter { tree.isDir($0) && !tree.isDetached($0) }
                .map { Entry(name: tree.name($0), path: tree.path($0), bytes: tree.size($0)) }
        }
        /// Small files, which the index leaves out: preferences, cookies, launch agents.
        func files(_ rel: String, suffix: String) -> [Entry] {
            let base = library + "/" + rel
            guard !ctx.isOffLimits(base), let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
            return names.filter { $0.hasSuffix(suffix) }.compactMap { n in
                var st = stat()
                let p = base + "/" + n
                guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
                return Entry(name: n, path: p, bytes: UInt64(st.st_blocks) * 512)
            }
        }
        func strip(_ s: String, _ suffix: String) -> String { s.hasSuffix(suffix) ? String(s.dropLast(suffix.count)) : s }
        /// Group containers are named "<team id>.<bundle id>" or "group.<bundle id>".
        func groupKey(_ n: String) -> String {
            if n.hasPrefix("group.") { return String(n.dropFirst(6)) }
            let p = n.split(separator: ".", maxSplits: 1)
            if p.count == 2, p[0].count == 10, p[0].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) { return String(p[1]) }
            return n
        }

        // (entries, key from name, matched by app name too, cache)
        let sources: [([Entry], (String) -> String, Bool, Bool)] = [
            (folders("Caches"), { $0 }, true, true),
            (folders("Logs"), { $0 }, true, true),
            (folders("Saved Application State"), { strip($0, ".savedState") }, false, true),
            (folders("Application Support"), { $0 }, true, false),
            (folders("Containers"), { $0 }, false, false),
            (folders("Group Containers"), groupKey, false, false),
            (folders("HTTPStorages") + files("HTTPStorages", suffix: ".binarycookies"), { strip($0, ".binarycookies") }, false, false),
            (folders("WebKit"), { $0 }, false, false),
            (files("Preferences", suffix: ".plist"), { strip($0, ".plist") }, false, false),
            (files("Cookies", suffix: ".binarycookies"), { strip($0, ".binarycookies") }, false, false),
            (files("LaunchAgents", suffix: ".plist"), { strip($0, ".plist") }, false, false),
        ]
        var out = [[Place]](repeating: [], count: apps.count)
        for (entries, key, byAppName, cache) in sources {
            for e in entries {
                guard let i = owner(key(e.name)) ?? (byAppName ? byName[e.name.lowercased()] : nil) else { continue }
                out[i].append(Place(path: e.path, bytes: e.bytes, cache: cache))
                guard !cache else { continue }
                // Caches inside the app's own data: Electron's in Application Support, a sandboxed app's in its container.
                let inner = e.path.contains("/Containers/") ? ["Data/Library/Caches"] : innerCaches
                for rel in inner {
                    if let n = tree.find(e.path + "/" + rel), tree.isDir(n), tree.size(n) > 0 {
                        out[i].append(Place(path: e.path + "/" + rel, bytes: tree.size(n), cache: true, inside: true))
                    }
                }
            }
        }
        return out
    }

    /// App file names Homebrew installed, mapped to their cask: "Godot.app" → "godot".
    static func caskApps(_ caskrooms: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for room in caskrooms {
            for token in (try? FileManager.default.contentsOfDirectory(atPath: room)) ?? [] {
                guard let d = FileManager.default.contents(atPath: room + "/" + token + "/.metadata/INSTALL_RECEIPT.json"),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let arts = j["uninstall_artifacts"] as? [[String: Any]] else { continue }
                for a in arts {
                    for v in a["app"] as? [Any] ?? [] {
                        if let s = v as? String { out[(s as NSString).lastPathComponent] = token }
                    }
                }
            }
        }
        return out
    }
}
