import AppKit
import DiskIndex

/// Light, dark, or whatever the system uses. Applies to every window at once.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: L("跟随系统", "System")
        case .light: L("浅色", "Light")
        case .dark: L("深色", "Dark")
        }
    }

    static var saved: Appearance {
        UserDefaults.standard.string(forKey: key).flatMap(Appearance.init) ?? .system
    }

    @MainActor static func apply(_ a: Appearance = saved) {
        NSApp.appearance = switch a {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The app's language. macOS reads a per-app choice from `AppleLanguages` in the app's own
/// preferences at launch (System Settings → Language & Region → Applications writes the same key),
/// so a change shows after the app reopens. The `smd` command keeps following the system.
enum Language: String, CaseIterable, Identifiable {
    case system, zh, en

    private static let key = "AppleLanguages"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: L("跟随系统", "System")
        case .zh: "简体中文"
        case .en: "English"
        }
    }

    static var saved: Language {
        let mine = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key]
        guard let first = (mine as? [String])?.first else { return .system }
        return first.hasPrefix("zh") ? .zh : .en
    }

    static func save(_ l: Language) {
        switch l {
        case .system: UserDefaults.standard.removeObject(forKey: key)
        case .zh: UserDefaults.standard.set(["zh-Hans"], forKey: key)
        case .en: UserDefaults.standard.set(["en"], forKey: key)
        }
    }

    /// Whether the app shows Chinese once it reopens with this choice.
    var isChinese: Bool {
        switch self {
        case .zh: return true
        case .en: return false
        case .system:
            let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[Self.key]
            return ((system as? [String])?.first ?? "en").hasPrefix("zh")
        }
    }
}
