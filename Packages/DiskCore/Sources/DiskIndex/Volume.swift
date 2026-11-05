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

/// A mounted disk other than the startup disk: a USB or Thunderbolt drive, an SD card,
/// a writable disk image.
public struct ExternalVolume: Sendable, Hashable, Identifiable {
    public var id: String { uuid }
    public var name: String
    /// Mount point, e.g. /Volumes/Backup.
    public var path: String
    public var uuid: String
    public var total: UInt64
    public var free: UInt64
    public var used: UInt64 { total > free ? total - free : 0 }

    public init(name: String, path: String, uuid: String, total: UInt64, free: UInt64) {
        self.name = name
        self.path = path
        self.uuid = uuid
        self.total = total
        self.free = free
    }
}

public enum ExternalVolumes {
    /// Local, writable, visible volumes under /Volumes. Network shares, read-only disk
    /// images and hidden volumes (Time Machine) are left out. Only volume attributes are
    /// read, never folder contents, so this never raises a privacy prompt.
    public static func list() -> [ExternalVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
                                      .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var out: [ExternalVolume] = []
        for url in urls {
            let path = url.path
            guard path.hasPrefix("/Volumes/"), let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsLocal == true, v.volumeIsReadOnly != true, v.volumeIsBrowsable != false,
                  v.volumeIsRootFileSystem != true, let uuid = v.volumeUUIDString else { continue }
            out.append(ExternalVolume(name: v.volumeName ?? url.lastPathComponent, path: path, uuid: uuid,
                                      total: UInt64(v.volumeTotalCapacity ?? 0),
                                      free: UInt64(v.volumeAvailableCapacity ?? 0)))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Where the volume holding `path` is mounted (/System/Volumes/Data for the home folder).
    public static func mountPoint(of path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return withUnsafeBytes(of: &s.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
}
