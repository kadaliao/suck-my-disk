import Foundation
import SQLite3
import Testing
@testable import DiskIndex
@testable import Insights
@testable import Recognizers
@testable import Reclaim

/// A small SQLite database made from statements, standing in for a browser's.
@discardableResult
func makeDB(_ path: String, _ sql: String) throws -> String {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    var err: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(db, sql, nil, nil, &err)
    #expect(rc == SQLITE_OK, "\(err.map { String(cString: $0) } ?? "")")
    return path
}

func rows(_ path: String, _ table: String, where w: String? = nil) -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_close(db) }
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \(table)" + (w.map { " WHERE " + $0 } ?? ""), -1, &st, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_finalize(st) }
    return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : -1
}

@Suite struct LargeFileTests {
    func context(_ tree: ScanTree) -> RecognizeContext {
        var c = RecognizeContext(tree: tree, activity: ActivityIndex())
        c.allowAnyPath = true
        return c
    }

    /// Only big files nothing else lists: not in dot folders, folded dependencies, git, or other items;
    /// a sharded model as one folder; vault chunks never.
    @Test func onlyWhatNothingElseLists() throws {
        let f = try Fixture()
        try f.file("Downloads/Foo-1.2.3-arm64.dmg", mb: 3)
        try f.file("Downloads/notes.txt", text: "small")
        try f.file("Movies/clip.mov", mb: 3)
        try f.file("Movies/Old.app/Contents/MacOS/old", mb: 3)
        try f.file(".tool/disk.img", mb: 3)                          // a tool's own data
        try f.file("proj/package.json", text: "{}")
        try f.file("proj/node_modules/x/blob.bin", mb: 3)            // folded
        try f.file("proj/data/tracked.bin", mb: 3)
        try f.file("proj/data/untracked.bin", mb: 3)
        #expect(Shell.run(["git", "init", "-q", f.path("proj")]).ok)
        #expect(Shell.run(["git", "-C", f.path("proj"), "add", "data/tracked.bin"]).ok)
        try f.file("render/frames/0001.bin", mb: 3)                  // another recognizer's item
        try f.file("models/sd/model_index.json", text: "{}")
        try f.file("models/sd/unet/a.safetensors", mb: 3)
        try f.file("models/sd/vae/b.safetensors", mb: 3)
        try f.file("models/lone.gguf", mb: 3)
        try f.file("vault/d/AB/x.c9r", mb: 3)                         // a Cryptomator chunk

        let foo = AppRecognizer.App(path: "/Applications/Foo.app", id: "com.example.foo", name: "Foo", folderNames: ["Foo"],
                                    appStore: false, movable: true)
        let things = LargeFileRecognizer.recognize(context(f.scan()), covered: [f.path("render/frames")], apps: [foo],
                                                   minBytes: 2_000_000, minInstallerBytes: 2_000_000)
        let byGroup = Dictionary(things.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let listed = Set(things.flatMap(\.items).compactMap(\.path))
        #expect(listed == [f.path("Downloads/Foo-1.2.3-arm64.dmg"), f.path("Movies/clip.mov"), f.path("Movies/Old.app"),
                           f.path("proj/data/untracked.bin"), f.path("models/sd"), f.path("models/lone.gguf")])
        #expect(byGroup["large:installer"]?.items.first?.reason.contains("Foo") == true)   // already installed
        #expect(byGroup["large:model"]?.items.count == 2)
        #expect(byGroup["large:app"]?.items.count == 1)
        // Your files: to the Trash, never preselected.
        let all = things.flatMap(\.items)
        #expect(all.allSatisfy { !$0.preselected && $0.tier == .yours && $0.action.isTrashOnly })
        #expect(things.allSatisfy { $0.kind == .largeFile })
    }

    @Test func installersNameTheirApp() {
        let installed = LargeFileRecognizer.installedNames([
            AppRecognizer.App(path: "/Applications/Google Chrome.app", id: "com.google.Chrome", name: "Google Chrome",
                              folderNames: ["Google Chrome", "Chrome"], appStore: false, movable: true),
            AppRecognizer.App(path: "/Applications/Cursor.app", id: "x", name: "Cursor", folderNames: ["Cursor"], appStore: false, movable: true),
            AppRecognizer.App(path: "/Applications/OrbStack.app", id: "y", name: "OrbStack", folderNames: ["OrbStack"], appStore: false, movable: true),
        ])
        #expect(LargeFileRecognizer.installedApp(for: "googlechrome.dmg", installed) == "Google Chrome")
        #expect(LargeFileRecognizer.installedApp(for: "Google Chrome.dmg", installed) == "Google Chrome")
        #expect(LargeFileRecognizer.installedApp(for: "Cursor-darwin-universal.dmg", installed) == "Cursor")
        #expect(LargeFileRecognizer.installedApp(for: "OrbStack_v1.9.2_19123_arm64.dmg", installed) == "OrbStack")
        #expect(LargeFileRecognizer.installedApp(for: "Cursors-Pack.dmg", installed) == nil)
        #expect(LargeFileRecognizer.installedApp(for: "Archive.dmg", installed) == nil)
    }
}

@Suite struct BrowserTests {
    func context(_ tree: ScanTree) -> RecognizeContext {
        var c = RecognizeContext(tree: tree, activity: ActivityIndex())
        c.allowAnyPath = true
        return c
    }

    /// A Chromium profile: what its History, Cookies and Web Data hold, as Chrome lays them out.
    func chromeProfile(_ f: Fixture, _ rel: String, urls: Int) throws {
        let p = f.path(rel)
        let inserts = (0..<urls).map { "INSERT INTO urls(url) VALUES('https://example.com/\($0)'); INSERT INTO visits(url) VALUES(\($0 + 1));" }
        try makeDB(p + "/History", """
            CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('version', '70');
            CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER);
            CREATE TABLE keyword_search_terms(term TEXT); INSERT INTO keyword_search_terms VALUES('secret');
            CREATE TABLE downloads(id INTEGER PRIMARY KEY, target TEXT); INSERT INTO downloads(target) VALUES('/x.dmg');
            CREATE TABLE downloads_url_chains(id INTEGER, url TEXT); INSERT INTO downloads_url_chains VALUES(1, 'https://x');
            CREATE TABLE history_sync_metadata(id INTEGER); INSERT INTO history_sync_metadata VALUES(1);
            \(inserts.joined(separator: "\n"))
            """)
        try makeDB(p + "/Cookies", """
            CREATE TABLE meta(key TEXT, value TEXT); CREATE TABLE cookies(host TEXT);
            INSERT INTO cookies VALUES('a'); INSERT INTO cookies VALUES('b'); INSERT INTO cookies VALUES('c');
            """)
        try makeDB(p + "/Web Data", """
            CREATE TABLE autocomplete(name TEXT, value TEXT); INSERT INTO autocomplete VALUES('email', 'me@example.com');
            CREATE TABLE credit_cards(n TEXT); INSERT INTO credit_cards VALUES('card');
            CREATE TABLE keywords(k TEXT); INSERT INTO keywords VALUES('my search engine');
            """)
        try makeDB(p + "/Top Sites", "CREATE TABLE meta(key TEXT); INSERT INTO meta VALUES('v'); CREATE TABLE top_sites(url TEXT); INSERT INTO top_sites VALUES('x');")
        try f.file(rel + "/Visited Links", text: "hashes")
        try f.file(rel + "/Sessions/Session_1", text: "tabs")
        try f.file(rel + "/Bookmarks", text: "{}")
        try f.file(rel + "/Login Data", text: "passwords")
        try f.file(rel + "/GPUCache/data_0", mb: 2)
    }

    @Test func chromiumProfilesErasedAsAsked() throws {
        let f = try Fixture()
        try f.file("support/Google/Chrome/Local State",
                   text: #"{"profile":{"info_cache":{"Default":{"name":"Me"},"Profile 1":{"name":"Work"}}}}"#)
        try chromeProfile(f, "support/Google/Chrome/Default", urls: 2)
        try chromeProfile(f, "support/Google/Chrome/Profile 1", urls: 1)
        try f.file("caches/Google/Chrome/Default/Cache/data_1", mb: 2)
        try f.file("support/Google/Chrome/GrShaderCache/s", mb: 1)
        let things = BrowserRecognizer.recognize(context(f.scan()), apps: [], support: f.path("support"),
                                                 caches: f.path("caches"), safari: f.path("none"))
        #expect(things.map(\.title) == ["Google Chrome · Me", "Google Chrome · Work"])
        let me = try #require(things.first)
        #expect(me.kind == .browser && me.detail != nil)   // no Chrome installed here: left behind
        let items = Dictionary(me.items.map { ($0.id.split(separator: ":")[1], $0) }, uniquingKeysWith: { a, _ in a })
        #expect(Set(items.keys) == ["history", "downloads", "cookies", "forms", "sessions", "cache"])
        #expect(items["history"]?.records == 2 && items["cookies"]?.records == 3 && items["forms"]?.records == 1)
        #expect(me.items.allSatisfy { !$0.preselected })
        #expect(items["cache"]?.tier == .regenerable && items["cookies"]?.tier == .erase)
        let cache = Set(items["cache"]!.action.paths)
        #expect(cache == [f.path("support/Google/Chrome/Default/GPUCache"), f.path("caches/Google/Chrome/Default"),
                          f.path("support/Google/Chrome/GrShaderCache")])
        // Nothing is ever erased by default, even if an item claimed to be preselected.
        var pre = me
        pre.items = pre.items.map { var i = $0; i.preselected = true; return i }
        #expect(Planner.plan(things: [pre], selected: nil).items.allSatisfy { $0.tier != .erase })

        // History: visits, addresses and searches go; downloads, sync bookkeeping and the schema stay.
        let p = f.path("support/Google/Chrome/Default")
        let picked = Set(me.items.map(\.id))
        let ex = Executor(store: nil, log: { _ in })
        let h = ex.run([items["history"]!])[0]
        #expect(h.status == .done, "\(h.message)")
        #expect(rows(p + "/History", "urls") == 0 && rows(p + "/History", "visits") == 0)
        #expect(rows(p + "/History", "keyword_search_terms") == 0)
        #expect(rows(p + "/History", "downloads") == 1 && rows(p + "/History", "history_sync_metadata") == 1)
        #expect(rows(p + "/History", "meta") == 1)
        #expect(rows(p + "/Top Sites", "top_sites") == 0 && rows(p + "/Top Sites", "meta") == 1)
        #expect(!FileManager.default.fileExists(atPath: p + "/Visited Links"))
        // Form entries go; cards and search engines stay. Bookmarks and passwords are never touched.
        #expect(ex.run([items["forms"]!])[0].status == .done)
        #expect(rows(p + "/Web Data", "autocomplete") == 0 && rows(p + "/Web Data", "credit_cards") == 1 && rows(p + "/Web Data", "keywords") == 1)
        #expect(ex.run([items["downloads"]!])[0].status == .done)
        #expect(rows(p + "/History", "downloads") == 0 && rows(p + "/History", "downloads_url_chains") == 0)
        #expect(FileManager.default.fileExists(atPath: p + "/Bookmarks") && FileManager.default.fileExists(atPath: p + "/Login Data"))
        // The other profile is untouched.
        #expect(rows(f.path("support/Google/Chrome/Profile 1/History"), "urls") == 1)
    }

    /// A browser that still has its database open: nothing is erased, and the reason says why.
    @Test func lockedDatabaseIsLeftAlone() throws {
        let f = try Fixture()
        try chromeProfile(f, "support/Chromium/Default", urls: 1)
        let things = BrowserRecognizer.recognize(context(f.scan()), apps: [], support: f.path("support"),
                                                 caches: f.path("caches"), safari: f.path("none"))
        let cookies = try #require(things.first?.items.first { $0.id.hasPrefix("browser:cookies:") })
        var db: OpaquePointer?
        #expect(sqlite3_open(f.path("support/Chromium/Default/Cookies"), &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE; SELECT count(*) FROM cookies;", nil, nil, nil) == SQLITE_OK)
        let o = Executor(store: nil, log: { _ in }).run([cookies])[0]
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        sqlite3_close(db)
        #expect(o.status == .failed && o.message.contains(L("占用", "in use")))
        #expect(rows(f.path("support/Chromium/Default/Cookies"), "cookies") == 3)
    }

    /// While the browser runs, none of its items run, whatever they are.
    @Test func runningBrowserIsLeftAlone() throws {
        let f = try Fixture()
        try chromeProfile(f, "support/Google/Chrome/Default", urls: 1)
        let bundle = f.path("Apps/Google Chrome.app")
        try f.file("Apps/Google Chrome.app/Contents/MacOS/Google Chrome", mb: 1)
        let chrome = AppRecognizer.App(path: bundle, id: "com.google.Chrome", name: "Google Chrome", folderNames: ["Google Chrome"],
                                       appStore: false, movable: true)
        let things = BrowserRecognizer.recognize(context(f.scan()), apps: [chrome], support: f.path("support"),
                                                 caches: f.path("caches"), safari: f.path("none"))
        let t = try #require(things.first)
        #expect(t.detail == nil && t.items.allSatisfy { $0.app == bundle })
        let history = try #require(t.items.first { $0.id.hasPrefix("browser:history:") })
        let running = try f.runningProgram(using: "Apps/Google Chrome.app/Contents/Frameworks/helper")
        let o = Executor(store: nil, log: { _ in }).run([history])[0]
        running.terminate()
        running.waitUntilExit()
        #expect(o.status == .skipped && o.message.contains("Google Chrome"))
        #expect(rows(f.path("support/Google/Chrome/Default/History"), "urls") == 1)
    }

    /// Firefox: visits go, pages go unless bookmarked, bookmarks stay.
    @Test func firefoxHistoryKeepsBookmarks() throws {
        let f = try Fixture()
        try f.file("support/Firefox/profiles.ini", text: """
            [Install4F96D1932A9F858E]
            Default=Profiles/abc.default-release

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/abc.default-release
            """)
        let p = f.path("support/Firefox/Profiles/abc.default-release")
        try makeDB(p + "/places.sqlite", """
            CREATE TABLE moz_origins(id INTEGER PRIMARY KEY, host TEXT);
            INSERT INTO moz_origins VALUES(1, 'kept.org'); INSERT INTO moz_origins VALUES(2, 'gone.org');
            CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER, last_visit_date INTEGER,
                                    foreign_count INTEGER, origin_id INTEGER);
            INSERT INTO moz_places VALUES(1, 'https://kept.org', 3, 100, 1, 1);
            INSERT INTO moz_places VALUES(2, 'https://gone.org', 2, 200, 0, 2);
            CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, place_id INTEGER);
            INSERT INTO moz_historyvisits(place_id) VALUES(1); INSERT INTO moz_historyvisits(place_id) VALUES(2);
            CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, fk INTEGER); INSERT INTO moz_bookmarks(fk) VALUES(1);
            CREATE TABLE moz_annos(id INTEGER PRIMARY KEY, place_id INTEGER); INSERT INTO moz_annos(place_id) VALUES(2);
            CREATE TABLE moz_inputhistory(place_id INTEGER, input TEXT); INSERT INTO moz_inputhistory VALUES(2, 'go');
            """)
        try makeDB(p + "/cookies.sqlite", "CREATE TABLE moz_cookies(host TEXT); INSERT INTO moz_cookies VALUES('a');")
        try makeDB(p + "/formhistory.sqlite", "CREATE TABLE moz_formhistory(v TEXT); INSERT INTO moz_formhistory VALUES('a');")
        try f.file("caches/Firefox/Profiles/abc.default-release/cache2/entries/x", mb: 2)
        let things = BrowserRecognizer.recognize(context(f.scan()), apps: [], support: f.path("support"),
                                                 caches: f.path("caches"), safari: f.path("none"))
        let t = try #require(things.first)
        #expect(t.title == "Firefox")
        let history = try #require(t.items.first { $0.id.hasPrefix("browser:history:") })
        #expect(history.records == 2)
        #expect(t.items.contains { $0.id.hasPrefix("browser:cache:") && $0.tier == .regenerable })
        let o = Executor(store: nil, log: { _ in }).run([history])[0]
        #expect(o.status == .done, "\(o.message)")
        let places = p + "/places.sqlite"
        #expect(rows(places, "moz_historyvisits") == 0 && rows(places, "moz_inputhistory") == 0 && rows(places, "moz_annos") == 0)
        #expect(rows(places, "moz_places") == 1 && rows(places, "moz_places", where: "id = 1 AND visit_count = 0") == 1)
        #expect(rows(places, "moz_bookmarks") == 1 && rows(places, "moz_origins") == 1)
    }

    /// Erase is its own tier: reports keep their raw values, and it sorts before guide-only items.
    @Test func eraseTier() throws {
        #expect(Tier.erase < .guide && Tier.yours < .erase)
        let i = ReclaimItem(id: "e", label: "e", path: nil, bytes: 0, tier: .erase,
                            action: .erase(db: "/x", sql: ["DELETE FROM t"]), reason: "", preselected: false, records: 5)
        let back = try JSONDecoder().decode(ReclaimItem.self, from: JSONEncoder().encode(i))
        #expect(back.tier == .erase && back.records == 5 && back.action == i.action)
        #expect(i.action.paths.isEmpty && i.action.databases == ["/x"])
        // Older items without a record count still load.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(i)) as! [String: Any]
        old["records"] = nil
        #expect(try JSONDecoder().decode(ReclaimItem.self, from: JSONSerialization.data(withJSONObject: old)).records == nil)
    }
}
