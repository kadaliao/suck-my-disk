import CFastScan
import Foundation

public struct VolumeInfo: Sendable {
    public var uuid: String
    public var total: UInt64
    public var free: UInt64            // statfs available
    public var importantFree: UInt64   // includes purgeable space macOS can reclaim
    public var dataUsed: UInt64        // blocks used by this volume itself
    /// Used space in the whole APFS container (all volumes share it).
    public var used: UInt64 { total > free ? total - free : 0 }
    /// System, VM, Preboot and other volumes in the same container.
    public var otherVolumes: UInt64 { used > dataUsed ? used - dataUsed : 0 }
    public var purgeable: UInt64 { importantFree > free ? importantFree - free : 0 }

    public static func of(_ path: String = "/System/Volumes/Data") -> VolumeInfo {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let v = try? url.resourceValues(forKeys: keys)
        let dataUsed = sm_volume_space_used(path)
        return VolumeInfo(
            uuid: v?.volumeUUIDString ?? "unknown",
            total: UInt64(v?.volumeTotalCapacity ?? 0),
            free: UInt64(v?.volumeAvailableCapacity ?? 0),
            importantFree: UInt64(v?.volumeAvailableCapacityForImportantUsage ?? 0),
            dataUsed: dataUsed)
    }

    /// Free bytes as statfs reports them; used to measure what an action really freed.
    public static func freeBytes(_ path: String = "/System/Volumes/Data") -> UInt64 {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return 0 }
        return UInt64(s.f_bavail) * UInt64(s.f_bsize)
    }
}
