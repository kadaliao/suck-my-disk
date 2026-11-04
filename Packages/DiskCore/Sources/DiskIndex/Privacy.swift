import Foundation

/// macOS asks the user before an app reads some folders: Desktop, Documents,
/// Downloads, iCloud Drive, other apps' data, removable and network volumes.
/// Without Full Disk Access, SuckMyDisk leaves those alone instead of raising
/// a dialog — during scans and, above all, during live updates.
public enum Privacy {
    /// Checked without a prompt: reading TCC's own database never asks, it just fails.
    public static var hasFullDiskAccess: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Data-volume paths that may raise a consent dialog when read.
    public static let promptingRoots: [String] = {
        let h = NSHomeDirectory()
        return [h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/Library/Mobile Documents",
                h + "/Library/CloudStorage", h + "/Library/Containers", h + "/Library/Group Containers", "/Volumes"]
            .map(Firmlinks.dataPath)
    }()

    /// Leave the prompting folders alone even with Full Disk Access (screenshot runs).
    nonisolated(unsafe) public static var alwaysSkip = false

    /// Folders to leave alone right now: none with Full Disk Access.
    public static func rootsToSkip() -> [String] { hasFullDiskAccess && !alwaysSkip ? [] : promptingRoots }

    public static func isInside(_ rawPath: String, _ roots: [String]) -> Bool {
        roots.contains { rawPath == $0 || rawPath.hasPrefix($0 + "/") }
    }
}
