import Foundation
import Testing
@testable import DiskIndex
@testable import Recognizers

@Suite struct HistoryTests {
    private func gb(_ x: Double) -> UInt64 { UInt64(x * 1e9) }

    /// A history like `writeHistory` leaves: one row per thing per day, with a day missing.
    private func store(in f: Fixture) throws -> Store {
        let store = try Store(url: URL(fileURLWithPath: f.path("smd.sqlite")))
        let rows: [(String, String, ThingKind, Double)] = [
            ("2026-11-01", "project:a", .project, 10), ("2026-11-01", "cache:b", .devCache, 5),
            ("2026-11-01", "model:old", .model, 2),
            ("2026-11-03", "project:a", .project, 13), ("2026-11-03", "cache:b", .devCache, 5),
            ("2026-11-03", "cache:gone", .devCache, 4),
            ("2026-11-05", "project:a", .project, 12), ("2026-11-05", "cache:b", .devCache, 5),
            ("2026-11-05", "model:new", .model, 1),
            ("2026-11-06", "project:later", .project, 9),
        ]
        for (day, id, kind, size) in rows {
            try store.run("INSERT INTO history(day, thing_id, kind, title, bytes, reclaimable) VALUES(?,?,?,?,?,?)",
                          [.text(day), .text(id), .text(kind.rawValue), .text(id), .int(Int64(gb(size))), .int(0)])
        }
        return store
    }

    @Test func dayIsComparedWithTheLastDayBeforeItWithARecord() throws {
        let f = try Fixture()
        let d = ReportStore.detail(day: "2026-11-05", in: try store(in: f))
        #expect(d.previousDay == "2026-11-03")
        // Biggest change first, either way; a tie goes to the bigger thing.
        #expect(d.things.map(\.thingID) == ["cache:gone", "project:a", "model:new", "cache:b"])
        let by = Dictionary(uniqueKeysWithValues: d.things.map { ($0.thingID, $0) })
        #expect(by["project:a"]?.change == -Int64(gb(1)))
        #expect(by["cache:b"]?.change == 0)
        #expect(by["model:new"]?.before == nil)
        #expect(by["model:new"]?.bytes == gb(1))
        #expect(by["cache:gone"]?.bytes == nil)
        #expect(by["cache:gone"]?.before == gb(4))
        #expect(by["cache:gone"]?.kind == ThingKind.devCache.rawValue)
        // Only the two days: neither older things nor later ones show up.
        #expect(by["model:old"] == nil)
        #expect(by["project:later"] == nil)
    }

    @Test func aDayWithoutRecordsIsPassedOver() throws {
        let f = try Fixture()
        let d = ReportStore.detail(day: "2026-11-03", in: try store(in: f))
        #expect(d.previousDay == "2026-11-01")
        let by = Dictionary(uniqueKeysWithValues: d.things.map { ($0.thingID, $0) })
        #expect(by["project:a"]?.change == Int64(gb(3)))
        #expect(by["model:old"]?.bytes == nil)
        #expect(by["cache:gone"]?.before == nil)
    }

    @Test func theFirstDayHasNothingToCompareWith() throws {
        let f = try Fixture()
        let d = ReportStore.detail(day: "2026-11-01", in: try store(in: f))
        #expect(d.previousDay == nil)
        #expect(d.things.map(\.thingID) == ["project:a", "cache:b", "model:old"])
        #expect(d.things.allSatisfy { $0.before == nil })
    }
}
