import CFastScan
import DiskIndex
import Foundation
import Insights

/// What browsers keep about where you've been: history, download lists, cookies, form
/// entries, the last session's tabs, and their caches. One group per browser profile.
///
/// Records are erased from the browser's own databases (`.erase`, never preselected, only
/// while the browser is closed: the item carries the app, and the database must not be
/// locked). Caches are deleted like any rebuildable cache. Saved passwords, bookmarks,
/// addresses, cards, extensions and their settings are never touched. Local Storage and
/// IndexedDB are left alone too: extensions keep their settings there.
///
/// Safari is guidance only, apart from its cache: it syncs history through iCloud, and only
/// Safari's own Clear History removes it on your other devices as well.
public enum BrowserRecognizer {
    struct Chromium: Sendable {
        var title: String
        var ids: [String]
        /// User data folder, under Application Support.
        var data: String
        /// Its cache folder, under ~/Library/Caches.
        var caches: String
    }

    static let chromium: [Chromium] = [
        Chromium(title: "Google Chrome", ids: ["com.google.Chrome"], data: "Google/Chrome", caches: "Google/Chrome"),
        Chromium(title: "Chrome Beta", ids: ["com.google.Chrome.beta"], data: "Google/Chrome Beta", caches: "Google/Chrome Beta"),
        Chromium(title: "Chrome Canary", ids: ["com.google.Chrome.canary"], data: "Google/Chrome Canary", caches: "Google/Chrome Canary"),
        Chromium(title: "Chromium", ids: ["org.chromium.Chromium"], data: "Chromium", caches: "Chromium"),
        Chromium(title: "Microsoft Edge", ids: ["com.microsoft.edgemac"], data: "Microsoft Edge", caches: "Microsoft Edge"),
        Chromium(title: "Brave", ids: ["com.brave.Browser"], data: "BraveSoftware/Brave-Browser", caches: "BraveSoftware/Brave-Browser"),
        Chromium(title: "Arc", ids: ["company.thebrowser.Browser"], data: "Arc/User Data", caches: "Arc/User Data"),
        Chromium(title: "Dia", ids: ["company.thebrowser.dia"], data: "Dia/User Data", caches: "Dia/User Data"),
        Chromium(title: "Vivaldi", ids: ["com.vivaldi.Vivaldi"], data: "Vivaldi", caches: "Vivaldi"),
        Chromium(title: "Opera", ids: ["com.operasoftware.Opera"], data: "com.operasoftware.Opera", caches: "com.operasoftware.Opera"),
        Chromium(title: "Comet", ids: ["ai.perplexity.comet"], data: "Comet", caches: "Comet"),
        Chromium(title: "Yandex", ids: ["ru.yandex.desktop.yandex-browser"], data: "Yandex/YandexBrowser", caches: "Yandex/YandexBrowser"),
    ]

    struct Gecko: Sendable {
        var title: String
        var ids: [String]
        /// The folder with profiles.ini, under Application Support.
        var data: String
        var caches: String
    }

    static let gecko: [Gecko] = [
        Gecko(title: "Firefox", ids: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"],
              data: "Firefox", caches: "Firefox"),
        Gecko(title: "Zen", ids: ["app.zen-browser.zen"], data: "zen", caches: "zen"),
        Gecko(title: "LibreWolf", ids: ["io.gitlab.librewolf-community"], data: "librewolf", caches: "librewolf"),
        Gecko(title: "Waterfox", ids: ["net.waterfox.waterfox"], data: "Waterfox", caches: "Waterfox"),
        Gecko(title: "Floorp", ids: ["one.ablaze.floorp"], data: "Floorp", caches: "Floorp"),
    ]

    /// Inside a Chromium profile: caches the browser rebuilds as you browse.
    static let profileCaches = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
                                "Service Worker/CacheStorage", "Service Worker/ScriptCache"]
    /// Next to the profiles, shared by all of them.
    static let sharedCaches = ["GrShaderCache", "ShaderCache", "GraphiteDawnCache", "GPUPersistentCache"]
    /// History tables that stay with the downloads list, and sync bookkeeping that stays put.
    static let downloadTables = ["downloads", "downloads_url_chains", "downloads_slices", "downloads_reroute_info"]

    /// - Parameters:
    ///   - covered: cache folders already offered elsewhere (an app's own caches item).
    ///   - support, caches, safari: where to look; the user's Library by default (tests use fixtures).
    public static func recognize(_ ctx: RecognizeContext, apps: [AppRecognizer.App]? = nil, covered: [String] = [],
                                 support: String? = nil, caches: String? = nil, safari: String? = nil) -> [Thing] {
        let lib = ctx.home + "/Library"
        let support = support ?? lib + "/Application Support"
        let caches = caches ?? lib + "/Caches"
        let installed = apps ?? AppRecognizer.installed(in: ["/Applications", ctx.home + "/Applications"])
        func app(_ ids: [String]) -> String? { installed.first { ids.contains($0.id) }?.path }

        var things: [Thing] = []
        for b in chromium {
            let dir = support + "/" + b.data
            guard !ctx.isOffLimits(dir), isDir(dir) else { continue }
            let profiles = chromiumProfiles(dir)
            for (n, p) in profiles.enumerated() {
                let title = profiles.count > 1 ? "\(b.title) · \(p.name)" : b.title
                var cache = profileCaches.map { p.path + "/" + $0 } + [caches + "/" + b.caches + "/" + p.folder]
                if n == 0 { cache += sharedCaches.map { dir + "/" + $0 } }
                if let t = chromiumThing(ctx, title: title, profile: p.path, cache: cache, app: app(b.ids), covered: covered) {
                    things.append(t)
                }
            }
        }
        for b in gecko {
            let dir = support + "/" + b.data
            guard !ctx.isOffLimits(dir), isDir(dir) else { continue }
            let profiles = geckoProfiles(dir)
            for p in profiles {
                let title = profiles.count > 1 ? "\(b.title) · \(p.name)" : b.title
                let cache = caches + "/" + b.caches + "/Profiles/" + (p.path as NSString).lastPathComponent
                if let t = geckoThing(ctx, title: title, profile: p.path, cache: cache, app: app(b.ids), covered: covered) {
                    things.append(t)
                }
            }
        }
        if let t = safariThing(ctx, folder: safari ?? lib + "/Safari", caches: caches, covered: covered) { things.append(t) }
        return things
    }

    // MARK: Chromium

    struct Profile { var path: String; var folder: String; var name: String }

    /// Profiles named in "Local State", or the usual folder names; only those with a history or cookies.
    static func chromiumProfiles(_ dir: String) -> [Profile] {
        // Opera keeps its one profile in the folder itself.
        if FileManager.default.fileExists(atPath: dir + "/History") {
            return [Profile(path: dir, folder: "", name: (dir as NSString).lastPathComponent)]
        }
        var names: [String: String] = [:]
        if let d = FileManager.default.contents(atPath: dir + "/Local State"),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let cache = (j["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (folder, v) in cache { names[folder] = ((v as? [String: Any])?["name"] as? String) ?? folder }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let candidates = Set(names.keys).union(folders.filter { $0 == "Default" || $0.hasPrefix("Profile ") })
        return candidates.sorted { a, b in
            // Default first, then Profile 2 before Profile 10.
            a == "Default" || (b != "Default" && a.localizedStandardCompare(b) == .orderedAscending)
        }.compactMap { folder in
            let p = dir + "/" + folder
            let fm = FileManager.default
            guard ["History", "Cookies", "Network/Cookies"].contains(where: { fm.fileExists(atPath: p + "/" + $0) }) else { return nil }
            return Profile(path: p, folder: folder, name: names[folder] ?? folder)
        }
    }

    static func chromiumThing(_ ctx: RecognizeContext, title: String, profile p: String, cache: [String],
                              app: String?, covered: [String]) -> Thing? {
        var items: [ReclaimItem] = []
        let sync = L("只清这台 Mac 上的；开了同步的话，账号里的记录要在网上另外删", "only on this Mac; with sync on, delete your account's copy online too")
        let history = p + "/History"
        if let tables = ForeignDB.tables(history) {
            let urls = ForeignDB.count(history, table: "urls") ?? 0
            if urls > 0 {
                let wipe = tables.filter { !downloadTables.contains($0) && $0 != "meta" && !$0.hasPrefix("sqlite_") && !$0.hasSuffix("_sync_metadata") }
                var acts: [ReclaimAction] = [.erase(db: history, sql: wipe.sorted().map(ForeignDB.deleteAll))]
                // Built from history: top sites, address-bar shortcuts, typing predictions, history search.
                for side in ["Top Sites", "Shortcuts", "Network Action Predictor", "HistoryEmbeddings"] {
                    guard let t = ForeignDB.tables(p + "/" + side) else { continue }
                    let rows = t.filter { $0 != "meta" && !$0.hasPrefix("sqlite_") }.sorted()
                    if !rows.isEmpty { acts.append(.erase(db: p + "/" + side, sql: rows.map(ForeignDB.deleteAll))) }
                }
                if FileManager.default.fileExists(atPath: p + "/Visited Links") { acts.append(.delete(path: p + "/Visited Links")) }
                items.append(ReclaimItem(
                    id: "browser:history:" + p, label: L("浏览记录", "Browsing history"), path: nil, bytes: 0,
                    tier: .erase, action: .compound(actions: acts),
                    reason: L("\(Fmt.count(urls)) 个网址的访问记录，还有搜索词、常去的网站和地址栏建议",
                              "visits to \(Fmt.count(urls)) addresses, plus search terms, top sites and address-bar suggestions"),
                    preselected: false, warnings: [sync], app: app, records: urls))
            }
            let downloads = ForeignDB.count(history, table: "downloads") ?? 0
            if downloads > 0 {
                items.append(ReclaimItem(
                    id: "browser:downloads:" + p, label: L("下载记录", "Download history"), path: nil, bytes: 0, tier: .erase,
                    action: .erase(db: history, sql: downloadTables.filter(tables.contains).map(ForeignDB.deleteAll)),
                    reason: L("下载列表里的 \(Fmt.count(downloads)) 条记录；下载下来的文件不动", "\(Fmt.count(downloads)) entries in the downloads list; the files themselves stay"),
                    preselected: false, app: app, records: downloads))
            }
        }
        for db in [p + "/Network/Cookies", p + "/Cookies"] {
            guard let n = ForeignDB.count(db, table: "cookies") else { continue }
            if n > 0 {
                items.append(ReclaimItem(
                    id: "browser:cookies:" + p, label: "Cookie", path: nil, bytes: 0, tier: .erase,
                    action: .erase(db: db, sql: [ForeignDB.deleteAll("cookies")]),
                    reason: L("网站存在浏览器里的 \(Fmt.count(n)) 个 Cookie，用来记住登录和跟踪访问", "\(Fmt.count(n)) cookies websites keep to remember logins and follow visits"),
                    preselected: false, warnings: [L("清掉后所有网站都要重新登录", "signs you out of every website")], app: app, records: n))
            }
            break
        }
        let webData = p + "/Web Data"
        if let tables = ForeignDB.tables(webData) {
            // Newer versions call the form entries table "autocomplete".
            let forms = ["autocomplete", "autofill"].filter(tables.contains)
            let n = forms.reduce(0) { $0 + (ForeignDB.count(webData, table: $1) ?? 0) }
            if n > 0 {
                items.append(ReclaimItem(
                    id: "browser:forms:" + p, label: L("表单自动填充记录", "Autofill form entries"), path: nil, bytes: 0, tier: .erase,
                    action: .erase(db: webData, sql: forms.map(ForeignDB.deleteAll)),
                    reason: L("在网页表单里输过的 \(Fmt.count(n)) 条内容；保存的密码、地址和银行卡不动",
                              "\(Fmt.count(n)) things typed into web forms; saved passwords, addresses and cards stay"),
                    preselected: false, app: app, records: n))
            }
        }
        let sessions = ["Sessions", "Sessions_Encrypted", "Current Session", "Current Tabs", "Last Session", "Last Tabs"]
            .map { p + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
        if !sessions.isEmpty {
            items.append(sessionItem(ctx, profile: p, paths: sessions, app: app))
        }
        if let c = cacheItem(ctx, profile: p, paths: cache, app: app, covered: covered) { items.append(c) }
        return thing(ctx, title: title, profile: p, cache: cache, lastUsed: history, app: app, items: items)
    }

    // MARK: Firefox and its relatives

    /// Profiles listed in profiles.ini.
    static func geckoProfiles(_ dir: String) -> [Profile] {
        guard let ini = try? String(contentsOfFile: dir + "/profiles.ini", encoding: .utf8) else { return [] }
        var out: [Profile] = []
        var section: [String: String] = [:]
        func flush() {
            guard let path = section["Path"] else { return }
            let full = section["IsRelative"] == "0" ? path : dir + "/" + path
            if FileManager.default.fileExists(atPath: full + "/places.sqlite") || FileManager.default.fileExists(atPath: full + "/cookies.sqlite") {
                out.append(Profile(path: full, folder: (full as NSString).lastPathComponent, name: section["Name"] ?? (full as NSString).lastPathComponent))
            }
        }
        for line in ini.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") {
                if !section.isEmpty { flush() }
                section = [:]
            } else if let eq = l.firstIndex(of: "=") {
                section[String(l[..<eq])] = String(l[l.index(after: eq)...])
            }
        }
        flush()
        var seen: Set<String> = []
        return out.filter { seen.insert($0.path).inserted }
    }

    /// What Firefox's own Clear History does: visits go, pages go unless bookmarked, and what
    /// was derived from them (typed input, page annotations such as downloads, origins).
    static let placesErase = [
        "DELETE FROM moz_historyvisits",
        "DELETE FROM moz_historyvisits_extra",
        "DELETE FROM moz_inputhistory",
        "DELETE FROM moz_places_metadata",
        "DELETE FROM moz_places_metadata_search_queries",
        "DELETE FROM moz_annos",
        "DELETE FROM moz_places WHERE foreign_count = 0",
        "UPDATE moz_places SET visit_count = 0, last_visit_date = NULL",
        "DELETE FROM moz_places_extra WHERE place_id NOT IN (SELECT id FROM moz_places)",
        "DELETE FROM moz_origins WHERE id NOT IN (SELECT origin_id FROM moz_places)",
    ]

    static func geckoThing(_ ctx: RecognizeContext, title: String, profile p: String, cache: String,
                           app: String?, covered: [String]) -> Thing? {
        var items: [ReclaimItem] = []
        let places = p + "/places.sqlite"
        if let n = ForeignDB.count(places, table: "moz_places", where: "visit_count > 0"), n > 0 {
            items.append(ReclaimItem(
                id: "browser:history:" + p, label: L("浏览和下载记录", "Browsing and download history"), path: nil, bytes: 0,
                tier: .erase, action: .erase(db: places, sql: placesErase),
                reason: L("\(Fmt.count(n)) 个网址的访问记录，包括下载列表；书签不动", "visits to \(Fmt.count(n)) addresses, the downloads list included; bookmarks stay"),
                preselected: false, warnings: [L("只清这台 Mac 上的；开了同步的话，其他设备上的不受影响", "only on this Mac; with sync on, your other devices keep theirs")],
                app: app, records: n))
        }
        if let n = ForeignDB.count(p + "/cookies.sqlite", table: "moz_cookies"), n > 0 {
            items.append(ReclaimItem(
                id: "browser:cookies:" + p, label: "Cookie", path: nil, bytes: 0, tier: .erase,
                action: .erase(db: p + "/cookies.sqlite", sql: [ForeignDB.deleteAll("moz_cookies")]),
                reason: L("网站存在浏览器里的 \(Fmt.count(n)) 个 Cookie，用来记住登录和跟踪访问", "\(Fmt.count(n)) cookies websites keep to remember logins and follow visits"),
                preselected: false, warnings: [L("清掉后所有网站都要重新登录", "signs you out of every website")], app: app, records: n))
        }
        if let n = ForeignDB.count(p + "/formhistory.sqlite", table: "moz_formhistory"), n > 0 {
            items.append(ReclaimItem(
                id: "browser:forms:" + p, label: L("表单自动填充记录", "Autofill form entries"), path: nil, bytes: 0, tier: .erase,
                action: .erase(db: p + "/formhistory.sqlite", sql: [ForeignDB.deleteAll("moz_formhistory")]),
                reason: L("在网页表单和搜索框里输过的 \(Fmt.count(n)) 条内容；保存的密码不动", "\(Fmt.count(n)) things typed into web forms and search boxes; saved passwords stay"),
                preselected: false, app: app, records: n))
        }
        let sessions = ["sessionstore.jsonlz4", "sessionstore-backups"].map { p + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
        if !sessions.isEmpty { items.append(sessionItem(ctx, profile: p, paths: sessions, app: app)) }
        if let c = cacheItem(ctx, profile: p, paths: [cache], app: app, covered: covered) { items.append(c) }
        return thing(ctx, title: title, profile: p, cache: [cache], lastUsed: places, app: app, items: items)
    }

    // MARK: Safari

    static func safariThing(_ ctx: RecognizeContext, folder: String, caches: String, covered: [String]) -> Thing? {
        let bundle = "/Applications/Safari.app"
        let app = exists(bundle) ? bundle : nil
        var items: [ReclaimItem] = []
        let cache = [caches + "/com.apple.Safari", ctx.home + "/Library/Containers/com.apple.Safari/Data/Library/Caches"]
        if let c = cacheItem(ctx, profile: folder, paths: cache, app: app, covered: covered) { items.append(c) }
        let history = folder + "/History.db"
        let sites = ForeignDB.count(history, table: "history_items")
        if sites.map({ $0 > 0 }) ?? FileManager.default.fileExists(atPath: history) {
            items.append(ReclaimItem(
                id: "browser:history:" + folder, label: L("浏览记录", "Browsing history"), path: nil, bytes: 0, tier: .guide, action: .none,
                reason: L("在 Safari 里清：「历史记录」→「清除历史记录…」。开了 iCloud 里的 Safari 同步，你其他设备上的也会一起清掉",
                          "In Safari: History → Clear History…. With Safari in iCloud on, it clears your other devices too"),
                preselected: false, records: sites))
            items.append(ReclaimItem(
                id: "browser:cookies:" + folder, label: L("Cookie 和网站数据", "Cookies and website data"), path: nil, bytes: 0,
                tier: .guide, action: .none,
                reason: L("在 Safari 里清：「设置」→「隐私」→「管理网站数据…」→「全部移除」",
                          "In Safari: Settings → Privacy → Manage Website Data… → Remove All"),
                preselected: false))
        }
        return thing(ctx, title: "Safari", profile: folder, cache: cache, lastUsed: history, app: app, items: items, builtIn: true)
    }

    /// lstat, so a symlink (Safari in /Applications is one) counts.
    static func exists(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0
    }

    // MARK: shared

    static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    static func sessionItem(_ ctx: RecognizeContext, profile p: String, paths: [String], app: String?) -> ReclaimItem {
        ReclaimItem(
            id: "browser:sessions:" + p, label: L("上次打开的标签页", "Last session's tabs"), path: nil,
            bytes: paths.reduce(0) { $0 + ctx.size($1) }, tier: .erase, action: .deleteAll(paths: paths),
            reason: L("浏览器用来恢复上次的窗口、标签页和最近关闭的标签页", "what the browser uses to reopen your last windows, tabs and recently closed tabs"),
            preselected: false, warnings: [L("下次打开浏览器不会再恢复上次的标签页", "the browser won't reopen your last tabs")], app: app)
    }

    /// The cache folders that exist (in the index), aren't privacy-guarded and aren't offered elsewhere.
    static func cacheItem(_ ctx: RecognizeContext, profile p: String, paths: [String], app: String?, covered: [String]) -> ReclaimItem? {
        let tree = ctx.tree
        let found = paths.filter { c in
            !ctx.isOffLimits(c) && !covered.contains { c == $0 || c.hasPrefix($0 + "/") } && (tree.find(c).map { tree.size($0) > 0 } ?? false)
        }
        let bytes = found.reduce(UInt64(0)) { $0 + ctx.size($1) }
        guard bytes >= 1_000_000 else { return nil }
        let shared = found.reduce(UInt64(0)) { s, c in s + (tree.find(c).map { tree.node($0).pointee.t_shared } ?? 0) }
        var item = ReclaimItem(
            id: "browser:cache:" + p, label: L("缓存", "Cache"), path: nil, bytes: bytes, estimate: bytes - shared,
            tier: .regenerable, action: .deleteAll(paths: found), restore: L("浏览网页时会重新下载", "downloaded again as you browse"),
            reason: L("网页的图片、脚本和离线缓存；登录状态和设置都不受影响", "images, scripts and offline caches of web pages; logins and settings stay"),
            preselected: false, app: app)
        item.estimateIsLowerBound = shared > 0
        return item
    }

    static func thing(_ ctx: RecognizeContext, title: String, profile p: String, cache: [String], lastUsed: String,
                      app: String?, items: [ReclaimItem], builtIn: Bool = false) -> Thing? {
        guard !items.isEmpty else { return nil }
        let used = (try? FileManager.default.attributesOfItem(atPath: lastUsed))?[.modificationDate] as? Date
        let bytes = ([p] + cache.filter { !$0.hasPrefix(p + "/") && !ctx.isOffLimits($0) }).reduce(UInt64(0)) { $0 + ctx.size($1) }
        let gone = app == nil && !builtIn
        return Thing(id: "browser:" + p, kind: .browser, title: title, path: p, bytes: bytes, lastActive: used,
                     detail: gone ? L("应用已经删掉，这些是它留下的", "the app is gone; this is what it left") : nil,
                     items: items.map { var i = $0; i.app = app; return i })
    }
}
