import DiskIndex
import Insights
import Foundation

public enum ThingKind: String, Codable, Sendable, CaseIterable {
    case project, media, devCache, model, app, appData, system

    public var title: String {
        switch self {
        case .project: return L("项目", "Projects")
        case .media: return L("作品", "Media")
        case .devCache: return L("开发缓存", "Dev caches")
        case .model: return L("模型", "Models")
        case .app: return L("应用", "Apps")
        case .appData: return L("应用数据", "App data")
        case .system: return L("系统", "System")
        }
    }
}

/// How an item may be reclaimed, from safest to most personal.
public enum Tier: Int, Codable, Sendable, Comparable {
    case lossless = 0     // nothing is lost (clone merge)
    case regenerable = 1  // can be rebuilt / re-downloaded
    case yours = 2        // your own files: goes to the Trash
    case guide = 3        // we only explain how to clean it

    public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .lossless: return L("无损", "lossless")
        case .regenerable: return L("可再生", "regenerable")
        case .yours: return L("你的文件", "yours")
        case .guide: return L("仅指引", "guide only")
        }
    }
}

public enum ReclaimAction: Codable, Sendable, Equatable {
    case delete(path: String)          // removed directly (regenerable)
    case deleteAll(paths: [String])    // several small regenerable dirs
    case trash(path: String)           // moved to the Trash
    case command(argv: [String], cwd: String?)
    indirect case compound(actions: [ReclaimAction])
    case none

    /// Everything it removes goes to the Trash: an app being uninstalled, your own files.
    public var isTrashOnly: Bool {
        switch self {
        case .trash: return true
        case .compound(let acts): return !acts.isEmpty && acts.allSatisfy(\.isTrashOnly)
        default: return false
        }
    }
}

public struct ReclaimItem: Codable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var path: String?
    public var bytes: UInt64           // occupied
    public var estimate: UInt64        // what we expect to free (may be lower)
    public var estimateIsLowerBound = false
    public var tier: Tier
    public var action: ReclaimAction
    public var restore: String?
    public var reason: String
    public var preselected: Bool
    public var warnings: [String] = []
    /// Items this one already includes; selecting it makes them redundant.
    public var covers: [String] = []
    /// The installed app (its bundle path) this item belongs to. Clean Up skips the item while
    /// anything runs from that app. Picked by hand, it doesn't wait out the 7-day rule:
    /// "not running" is the check that matters for an app, and what goes is rebuilt or trashed.
    public var app: String?

    public init(id: String, label: String, path: String?, bytes: UInt64, estimate: UInt64? = nil,
                tier: Tier, action: ReclaimAction, restore: String? = nil, reason: String,
                preselected: Bool, warnings: [String] = [], app: String? = nil) {
        self.id = id
        self.label = label
        self.path = path
        self.bytes = bytes
        self.estimate = estimate ?? bytes
        self.tier = tier
        self.action = action
        self.restore = restore
        self.reason = reason
        self.preselected = preselected
        self.warnings = warnings
        self.app = app
    }
}

public struct Thing: Codable, Sendable, Identifiable {
    public var id: String
    public var kind: ThingKind
    public var title: String
    public var path: String?
    public var bytes: UInt64
    public var lastActive: Date?
    public var activitySource: String?
    public var detail: String?
    public var items: [ReclaimItem]

    /// Best case for this thing: items another item already includes are not added twice.
    public var reclaimable: UInt64 {
        let covered = Set(items.flatMap(\.covers))
        return items.filter { $0.tier < .guide && !covered.contains($0.id) }.reduce(0) { $0 + $1.estimate }
    }
    public var preselectedBytes: UInt64 { items.filter(\.preselected).reduce(0) { $0 + $1.estimate } }

    public init(id: String, kind: ThingKind, title: String, path: String?, bytes: UInt64,
                lastActive: Date? = nil, activitySource: String? = nil, detail: String? = nil,
                items: [ReclaimItem] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.bytes = bytes
        self.lastActive = lastActive
        self.activitySource = activitySource
        self.detail = detail
        self.items = items
    }
}

/// Everything recognizers need, shared across them.
public struct RecognizeContext: @unchecked Sendable {
    public let tree: ScanTree
    public let activity: ActivityIndex
    public let now: Date
    public let sleepAfterDays: Int
    public let home = NSHomeDirectory()
    /// Look everywhere in the tree, not just the home folder: external disks, and test fixtures.
    public var allowAnyPath = false
    /// Folders recognizers must not read files in (user-visible paths): see `Privacy`.
    public var offLimits: [String] = []

    public func isOffLimits(_ path: String) -> Bool { Privacy.isInside(path, offLimits) }

    public init(tree: ScanTree, activity: ActivityIndex, now: Date = Date(), sleepAfterDays: Int = 30) {
        self.tree = tree
        self.activity = activity
        self.now = now
        self.sleepAfterDays = sleepAfterDays
    }

    public func size(_ path: String) -> UInt64 {
        tree.find(path).map { tree.size($0) } ?? 0
    }

    public func daysSince(_ d: Date?) -> Int? {
        d.map { Int(now.timeIntervalSince($0) / 86400) }
    }
}
