import Foundation
import SQLite3

/// Where SuckMyDisk keeps its index, history and journal.
public enum AppPaths {
    public static var supportDir: URL {
        if let o = ProcessInfo.processInfo.environment["SMD_HOME"] { return URL(fileURLWithPath: o) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SuckMyDisk", isDirectory: true)
    }

    public static func ensure() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }

    public static func indexURL(volumeUUID: String) -> URL {
        supportDir.appendingPathComponent("index-\(volumeUUID).bin")
    }

    public static var databaseURL: URL { supportDir.appendingPathComponent("smd.sqlite") }
}

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String {
        switch self { case .sqlite(let m): return "SQLite: \(m)" }
    }
}

/// Thin SQLite wrapper: history of sizes per thing, and the action journal.
public final class Store: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL = AppPaths.databaseURL) throws {
        try AppPaths.ensure()
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        try exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS history(
            day TEXT NOT NULL, thing_id TEXT NOT NULL, kind TEXT NOT NULL,
            title TEXT NOT NULL, bytes INTEGER NOT NULL, reclaimable INTEGER NOT NULL,
            PRIMARY KEY(day, thing_id));
        CREATE TABLE IF NOT EXISTS volume_history(
            day TEXT PRIMARY KEY, used INTEGER NOT NULL, free INTEGER NOT NULL, scanned INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS journal(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, action TEXT NOT NULL,
            item_id TEXT NOT NULL, path TEXT, command TEXT, estimated INTEGER NOT NULL,
            free_before INTEGER NOT NULL, free_after INTEGER NOT NULL, restore TEXT,
            status TEXT NOT NULL, detail TEXT);
        """)
    }

    deinit { sqlite3_close(db) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sqlite(m)
        }
    }

    public enum Value { case int(Int64), real(Double), text(String?) }

    public func run(_ sql: String, _ args: [Value] = []) throws {
        try lock.withLock {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
                throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(st) }
            bind(st, args)
            let rc = sqlite3_step(st)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func query(_ sql: String, _ args: [Value] = []) throws -> [[Value]] {
        try lock.withLock {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
                throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(st) }
            bind(st, args)
            var rows: [[Value]] = []
            while sqlite3_step(st) == SQLITE_ROW {
                var row: [Value] = []
                for c in 0..<sqlite3_column_count(st) {
                    switch sqlite3_column_type(st, c) {
                    case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(st, c)))
                    case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(st, c)))
                    case SQLITE_NULL: row.append(.text(nil))
                    default: row.append(.text(String(cString: sqlite3_column_text(st, c))))
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    private func bind(_ st: OpaquePointer?, _ args: [Value]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .real(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v?): sqlite3_bind_text(st, idx, v, -1, transient)
            case .text(nil): sqlite3_bind_null(st, idx)
            }
        }
    }

    public static func today(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

public extension Store.Value {
    var int: Int64 { if case .int(let v) = self { return v }; if case .real(let d) = self { return Int64(d) }; return 0 }
    var real: Double { if case .real(let v) = self { return v }; if case .int(let i) = self { return Double(i) }; return 0 }
    var text: String? { if case .text(let v) = self { return v }; return nil }
}
