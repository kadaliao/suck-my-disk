import DiskIndex
import Foundation

/// Where the last report and the index live, shared by the CLI and the app.
public enum ReportStore {
    public static var reportURL: URL { AppPaths.supportDir.appendingPathComponent("last-report.json") }
    public static var indexURL: URL { AppPaths.indexURL(volumeUUID: VolumeInfo.of().uuid) }

    /// An external disk's report; its index is `AppPaths.indexURL(volumeUUID:)` like the startup disk's.
    public static func reportURL(volume uuid: String) -> URL {
        AppPaths.supportDir.appendingPathComponent("report-\(uuid).json")
    }

    public static func save(_ r: Report, to url: URL = reportURL) {
        try? AppPaths.ensure()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(r) { try? d.write(to: url, options: .atomic) }
    }

    public static func load(from url: URL = reportURL) -> Report? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(Report.self, from: d)
    }

    public static func loadIndex(from url: URL = indexURL) -> ScanTree? { try? ScanTree.load(from: url) }

    public static func saveIndex(_ t: ScanTree, to url: URL = indexURL) throws {
        try AppPaths.ensure()
        try t.save(to: url)
    }

    /// After deleting things the report no longer matches the disk. The index stays:
    /// it catches up from FSEvents.
    public static func invalidate() {
        try? FileManager.default.removeItem(at: reportURL)
    }

    public static func writeHistory(_ r: Report) {
        guard let store = try? Store() else { return }
        let day = Store.today()
        for t in r.things where t.bytes > 0 {
            try? store.run("INSERT OR REPLACE INTO history(day, thing_id, kind, title, bytes, reclaimable) VALUES(?,?,?,?,?,?)",
                           [.text(day), .text(t.id), .text(t.kind.rawValue), .text(t.title), .int(Int64(t.bytes)), .int(Int64(t.reclaimable))])
        }
        let v = VolumeInfo.of()
        try? store.run("INSERT OR REPLACE INTO volume_history(day, used, free, scanned) VALUES(?,?,?,?)",
                       [.text(day), .int(Int64(v.dataUsed)), .int(Int64(v.free)), .int(Int64(r.scanned))])
    }

    public struct DayPoint: Sendable, Identifiable {
        public var id: String { day + kind }
        public var day: String
        public var kind: String
        public var bytes: UInt64

        public init(day: String, kind: String, bytes: UInt64) {
            self.day = day
            self.kind = kind
            self.bytes = bytes
        }
    }

    /// Bytes per kind per day, plus a "free" series.
    public static func history() -> [DayPoint] {
        guard let store = try? Store() else { return [] }
        var out: [DayPoint] = []
        if let rows = try? store.query("SELECT day, kind, SUM(bytes) FROM history GROUP BY day, kind ORDER BY day") {
            out += rows.map { DayPoint(day: $0[0].text ?? "", kind: $0[1].text ?? "", bytes: UInt64(max(0, $0[2].int))) }
        }
        if let rows = try? store.query("SELECT day, free FROM volume_history ORDER BY day") {
            out += rows.map { DayPoint(day: $0[0].text ?? "", kind: "free", bytes: UInt64(max(0, $0[1].int))) }
        }
        return out
    }
}
