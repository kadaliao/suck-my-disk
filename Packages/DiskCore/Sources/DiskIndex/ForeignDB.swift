import Foundation
import SQLite3

/// Another program's SQLite database: a browser's history, cookies or form entries.
///
/// Reading only counts rows; nothing is read out of them. Erasing runs in one exclusive
/// transaction, so the database is either fully erased or left as it was, and fails at
/// once if the program still holds it open.
public enum ForeignDB {
    public enum Failure: Error, CustomStringConvertible {
        case open(String)
        /// Another program holds a lock on it: the browser is still running.
        case busy
        case sql(String)

        public var description: String {
            switch self {
            case .open(let m): return L("打不开数据库：\(m)", "can't open the database: \(m)")
            case .busy: return L("数据库正被占用，浏览器可能还开着", "the database is in use; is the browser still open?")
            case .sql(let m): return "SQLite: \(m)"
            }
        }
    }

    /// Opens read-only without taking any lock: Chrome holds its databases locked while it
    /// runs, and a count may be slightly stale then, which is fine for showing a number.
    static func openSnapshot(_ path: String) -> OpaquePointer? {
        guard let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:" + enc + "?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    static func names(_ db: OpaquePointer?) -> Set<String>? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        var out: Set<String> = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
            out.insert(String(cString: c))
        }
    }

    /// The database's tables, or nil if it can't be read (missing, not SQLite, no access).
    public static func tables(_ path: String) -> Set<String>? {
        guard FileManager.default.isReadableFile(atPath: path), let db = openSnapshot(path) else { return nil }
        defer { sqlite3_close(db) }
        return names(db)
    }

    /// Rows in `table`, or nil if it can't be read.
    public static func count(_ path: String, table: String, where condition: String? = nil) -> Int? {
        guard FileManager.default.isReadableFile(atPath: path), let db = openSnapshot(path) else { return nil }
        defer { sqlite3_close(db) }
        guard names(db)?.contains(table) == true else { return nil }
        var st: OpaquePointer?
        let sql = "SELECT count(*) FROM \(quote(table))" + (condition.map { " WHERE " + $0 } ?? "")
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : nil
    }

    /// "DELETE FROM \"table\"".
    public static func deleteAll(_ table: String) -> String { "DELETE FROM \(quote(table))" }

    public static func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    /// Runs `statements` in one exclusive transaction and returns the rows they changed.
    /// A statement on a table this version of the program doesn't have is skipped; any other
    /// error rolls everything back. Deleted rows are overwritten (secure_delete) and the file
    /// is compacted afterwards, so the records don't linger in free pages.
    @discardableResult
    public static func erase(_ path: String, statements: [String]) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
            sqlite3_close(db)
            throw Failure.open(m)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 0)
        func exec(_ sql: String) -> Int32 { sqlite3_exec(db, sql, nil, nil, nil) }
        func message() -> String { String(cString: sqlite3_errmsg(db)) }

        _ = exec("PRAGMA secure_delete = ON")
        let begin = exec("BEGIN EXCLUSIVE")
        if begin == SQLITE_BUSY || begin == SQLITE_LOCKED { throw Failure.busy }
        guard begin == SQLITE_OK else { throw Failure.sql(message()) }
        var changed = 0
        for sql in statements {
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &st, nil) != SQLITE_OK {
                let m = message()
                sqlite3_finalize(st)
                // Another version of the program: a table or column it doesn't have.
                if m.hasPrefix("no such table") || m.hasPrefix("no such column") { continue }
                _ = exec("ROLLBACK")
                throw Failure.sql(m)
            }
            let rc = sqlite3_step(st)
            sqlite3_finalize(st)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                let m = message()
                _ = exec("ROLLBACK")
                throw rc == SQLITE_BUSY ? Failure.busy : Failure.sql(m)
            }
            changed += Int(sqlite3_changes(db))
        }
        guard exec("COMMIT") == SQLITE_OK else {
            let m = message()
            _ = exec("ROLLBACK")
            throw Failure.sql(m)
        }
        // Compacting is a bonus: the rows are already gone.
        _ = exec("VACUUM")
        return changed
    }
}
