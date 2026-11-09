import Foundation

/// Bilingual text: picks Chinese when the user's first preferred language is Chinese.
public func L(_ zh: String, _ en: String) -> String {
    Fmt.isChinese ? zh : en
}

public enum Fmt {
    public static let isChinese: Bool = {
        if let forced = ProcessInfo.processInfo.environment["SMD_LANG"] {
            return forced.hasPrefix("zh")
        }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
    }()

    /// "zh" or "en": what `L` picks in this process.
    public static var language: String { isChinese ? "zh" : "en" }

    /// Decimal units, like Finder.
    public static func bytes(_ v: UInt64) -> String {
        let d = Double(v)
        if d >= 1e12 { return String(format: "%.2f TB", d / 1e12) }
        if d >= 1e9 { return String(format: d >= 1e11 ? "%.0f GB" : "%.1f GB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.0f MB", d / 1e6) }
        if d >= 1e3 { return String(format: "%.0f KB", d / 1e3) }
        return "\(v) B"
    }

    /// "17,685" / "1.8 万".
    public static func count(_ n: Int) -> String {
        if isChinese, n >= 10_000 {
            let s = String(format: "%.1f", Double(n) / 1e4)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + " 万"
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    public static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return L("未知", "unknown") }
        let days = Int(now.timeIntervalSince(date) / 86400)
        if days <= 0 { return L("今天", "today") }
        if days < 60 { return L("\(days) 天前", "\(days)d ago") }
        if days < 730 { return L("\(days / 30) 个月前", "\(days / 30)mo ago") }
        return L("\(days / 365) 年前", "\(days / 365)y ago")
    }

    /// "10-31 18:07" / "Oct 31, 18:07", with the year when it is not this year.
    public static func stamp(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let year = Calendar.current.component(.year, from: date) != Calendar.current.component(.year, from: now)
        f.dateFormat = isChinese ? (year ? "yyyy-MM-dd HH:mm" : "MM-dd HH:mm") : (year ? "MMM d yyyy, HH:mm" : "MMM d, HH:mm")
        return f.string(from: date)
    }

    public static func home(_ path: String) -> String {
        let h = NSHomeDirectory()
        return path.hasPrefix(h) ? "~" + path.dropFirst(h.count) : path
    }
}
