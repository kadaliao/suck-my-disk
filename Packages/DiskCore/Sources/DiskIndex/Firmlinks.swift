import Foundation

/// Maps between data-volume paths (/System/Volumes/Data/Users/...) and the
/// paths users see (/Users/...).
public enum Firmlinks {
    public static let dataRoot = "/System/Volumes/Data"

    /// (user-visible prefix, data-relative prefix), longest first.
    static let table: [(user: String, data: String)] = {
        var t: [(String, String)] = []
        if let s = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) {
            for line in s.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                if parts.count == 2 { t.append((String(parts[0]), String(parts[1]))) }
            }
        }
        if t.isEmpty { t = [("/Users", "Users"), ("/Applications", "Applications"), ("/Library", "Library"),
                            ("/private", "private"), ("/opt", "opt"), ("/usr/local", "usr/local")] }
        return t.sorted { $0.1.count > $1.1.count }
    }()

    public static func userPath(_ p: String) -> String {
        guard p.hasPrefix(dataRoot + "/") else { return p }
        let rel = p.dropFirst(dataRoot.count + 1)
        for (user, data) in table where rel == data || rel.hasPrefix(data + "/") {
            return user + rel.dropFirst(data.count)
        }
        return p
    }

    public static func dataPath(_ p: String) -> String {
        if p.hasPrefix(dataRoot) { return p }
        for (user, data) in table where p == user || p.hasPrefix(user + "/") {
            return dataRoot + "/" + data + p.dropFirst(user.count)
        }
        return p
    }
}
