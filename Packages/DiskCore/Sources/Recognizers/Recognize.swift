import DiskIndex
import Foundation
import Insights

public struct Report: Codable, Sendable {
    public var createdAt: Date
    public var volumeTotal: UInt64
    public var volumeFree: UInt64
    public var scanned: UInt64
    public var things: [Thing]

    public var preselected: UInt64 {
        Planner.plan(things: things, selected: nil).freed
    }
}

/// Runs every recognizer over a tree.
public enum Recognize {
    public static func all(tree: ScanTree, sleepAfterDays: Int = 30, log: @escaping (String) -> Void = { _ in }) async -> Report {
        let volume = VolumeInfo.of()
        log(L("读取活跃度信号（Claude Code、Codex、shell 历史）…", "Reading activity signals (Claude Code, Codex, shell history)…"))
        let activity = ActivityIndex()
        let ctx = RecognizeContext(tree: tree, activity: activity, sleepAfterDays: sleepAfterDays)
        log(L("识别项目…", "Finding projects…"))
        let (projects, venvs) = ProjectRecognizer.recognize(ctx)
        let preVenvs = Set(projects.flatMap(\.items).filter { $0.preselected && $0.label == "venv" }.map(\.id))
        log(L("识别渲染帧…", "Finding render frames…"))
        let media = await FrameSequenceRecognizer.recognize(ctx)
        log(L("识别开发缓存…", "Finding dev caches…"))
        let caches = DevCacheRecognizer.recognize(ctx, venvs: venvs, preselectedVenvIDs: preVenvs, log: log)
        let models = ModelRecognizer.recognize(ctx)
        let apps = AppDataRecognizer.recognize(ctx)
        let system = SystemRecognizer.recognize(ctx, volume: volume)
        var all = projects + media + caches + models + apps + system
        log(L("精确计算含共享数据的大项…", "Measuring items that share data…"))
        refineShared(&all)
        return Report(createdAt: Date(), volumeTotal: volume.total, volumeFree: volume.free,
                      scanned: tree.uniqueTotal, things: all)
    }

    /// Items whose data is partly shared (clones / hard links) get an exact
    /// "what deleting this alone frees" by scanning just that item.
    static func refineShared(_ things: inout [Thing]) {
        for t in things.indices {
            for i in things[t].items.indices {
                let item = things[t].items[i]
                guard item.estimateIsLowerBound, case .delete(let path) = item.action,
                      item.bytes > item.estimate + 50_000_000,
                      let acct = SharedAccounting(roots: [path]) else { continue }
                let f = acct.freed(deleting: [0])
                things[t].items[i].estimate = f.total
                things[t].items[i].estimateIsLowerBound = false
                if f.total < 1_000_000 { things[t].items[i].preselected = false }
                if f.trapped > 0 {
                    things[t].items[i].warnings.append(L(
                        "其中 \(Text.bytes(f.trapped)) 和别处共享（克隆或硬链接），单删这一项腾不出来",
                        "\(Text.bytes(f.trapped)) is shared with other places and stays allocated"))
                }
            }
        }
    }
}

/// Turns a selection into concrete steps, removing items another selected item already covers.
public enum Planner {
    public struct Plan: Sendable {
        public var items: [ReclaimItem]
        public var freed: UInt64
    }

    /// `selected == nil` means "the preselected items".
    public static func plan(things: [Thing], selected: Set<String>?) -> Plan {
        let all = things.flatMap(\.items).filter { $0.tier < .guide }
        var chosen = all.filter { item in selected.map { $0.contains(item.id) } ?? item.preselected }
        let covered = Set(chosen.flatMap(\.covers))
        chosen.removeAll { covered.contains($0.id) }
        return Plan(items: chosen, freed: chosen.reduce(0) { $0 + $1.estimate })
    }
}
