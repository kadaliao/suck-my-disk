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

    /// One thing's size on one day, as `writeHistory` recorded it.
    public struct ThingPoint: Sendable {
        public var day: String
        public var thingID: String
        public var kind: String
        public var title: String
        public var bytes: UInt64

        public init(day: String, thingID: String, kind: String, title: String, bytes: UInt64) {
            self.day = day
            self.thingID = thingID
            self.kind = kind
            self.title = title
            self.bytes = bytes
        }
    }

    /// A thing on a chosen day next to the last day before it with a record.
    public struct ThingChange: Sendable, Identifiable {
        public var id: String { thingID }
        public var thingID: String
        public var kind: String
        public var title: String
        /// On the day; nil when it was recorded the day before but not anymore.
        public var bytes: UInt64?
        /// On the day before; nil when it is new.
        public var before: UInt64?
        public var change: Int64 { Int64(bytes ?? 0) - Int64(before ?? 0) }
    }

    public struct DayDetail: Sendable {
        public var day: String
        /// The last day before `day` with a record; nil on the first one.
        public var previousDay: String?
        /// By how much they changed, up or down, then by size: what grew and what went come first.
        public var things: [ThingChange]
    }

    /// Each thing on `day`, and what changed since the last day before it with a record.
    public static func detail(day: String) -> DayDetail {
        guard let store = try? Store() else { return DayDetail(day: day, previousDay: nil, things: []) }
        return detail(day: day, in: store)
    }

    public static func detail(day: String, in store: Store) -> DayDetail {
        let previous = (try? store.query("SELECT MAX(day) FROM history WHERE day < ?", [.text(day)]))?.first?.first?.text
        let rows = (try? store.query("SELECT day, thing_id, kind, title, bytes FROM history WHERE day = ? OR day = ?",
                                     [.text(day), .text(previous)])) ?? []
        return detail(day: day, rows: rows.map {
            ThingPoint(day: $0[0].text ?? "", thingID: $0[1].text ?? "", kind: $0[2].text ?? "",
                       title: $0[3].text ?? "", bytes: UInt64(max(0, $0[4].int)))
        })
    }

    /// The same from rows of any days; demo mode keeps its made-up history in memory.
    public static func detail(day: String, rows: [ThingPoint]) -> DayDetail {
        let previous = rows.lazy.map(\.day).filter { $0 < day }.max()
        var byID: [String: ThingChange] = [:]
        for r in rows where r.day == previous {
            byID[r.thingID] = ThingChange(thingID: r.thingID, kind: r.kind, title: r.title, bytes: nil, before: r.bytes)
        }
        // The day's own title and kind win: a thing can be renamed.
        for r in rows where r.day == day {
            byID[r.thingID] = ThingChange(thingID: r.thingID, kind: r.kind, title: r.title, bytes: r.bytes,
                                          before: byID[r.thingID]?.before)
        }
        let things = byID.values.sorted { a, b in
            if a.change.magnitude != b.change.magnitude { return a.change.magnitude > b.change.magnitude }
            if (a.bytes ?? 0) != (b.bytes ?? 0) { return (a.bytes ?? 0) > (b.bytes ?? 0) }
            return (a.title, a.thingID) < (b.title, b.thingID)
        }
        return DayDetail(day: day, previousDay: previous, things: things)
    }
}
