import AppKit
import DiskIndex

/// `smd`, the command line, is inside the app (Contents/Helpers/smd), so it comes with every
/// install and updates with the app. Homebrew's cask links it into Homebrew's bin folder; for a
/// copy dragged from the disk image, Settings links it into /usr/local/bin, which every shell
/// searches (/etc/paths), with an administrator password.
@MainActor @Observable
final class CommandLineTool {
    /// The link Settings makes and removes.
    static let link = "/usr/local/bin/smd"

    /// An `smd` a shell may find.
    struct Copy: Identifiable, Equatable {
        enum Kind {
            /// A link to the program inside a SuckMyDisk app.
            case app
            /// Homebrew's separate `smd` formula: it doesn't update with the app.
            case formula
            /// A program put there by hand, from the CLI download: it doesn't update either.
            case other
        }

        let path: String
        let kind: Kind
        /// A link to something that is no longer there, such as an app that was moved.
        let broken: Bool
        var id: String { path }
        var current: Bool { kind == .app && !broken }
    }

    /// The program inside this app; nil in a build without it.
    let bundled: String?
    private(set) var copies: [Copy] = []
    private(set) var isWorking = false
    /// Why installing or removing failed.
    private(set) var problem: String?

    init() {
        let p = Bundle.main.bundleURL.appending(path: "Contents/Helpers/smd").path
        bundled = FileManager.default.isExecutableFile(atPath: p) ? p : nil
        refresh()
    }

    /// Homebrew's bin on Apple silicon, the one in /etc/paths (and Homebrew's on Intel), and ~/.local/bin.
    private static var places: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"].map { $0 + "/smd" }
    }

    /// The copy that updates with the app, if a shell can find one.
    var installed: Copy? { copies.first(where: \.current) }

    /// Run from the disk image or from Downloads (App Translocation), the app sits at a path that
    /// goes away: a link to it would break.
    var appIsInPlace: Bool {
        let p = Bundle.main.bundlePath
        return !p.contains("/AppTranslocation/") && !p.hasPrefix("/Volumes/")
    }

    /// Installing replaces what is at /usr/local/bin/smd, except Homebrew's own link there (Intel Macs).
    var canInstall: Bool {
        bundled != nil && appIsInPlace && copies.first { $0.path == Self.link }?.kind != .formula
    }

    func refresh() {
        let fm = FileManager.default
        copies = Self.places.compactMap { path in
            let target = try? fm.destinationOfSymbolicLink(atPath: path)
            guard target != nil || fm.fileExists(atPath: path) else { return nil }
            let broken = target != nil && !fm.fileExists(atPath: path)
            let real = broken ? target! : URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let kind: Copy.Kind = real.hasSuffix(".app/Contents/Helpers/smd") ? .app
                : real.contains("/Cellar/smd/") ? .formula : .other
            return Copy(path: path, kind: kind, broken: broken)
        }
    }

    func install() {
        guard let bundled, canInstall else { return }
        run("/bin/mkdir -p /usr/local/bin && /bin/ln -sfn \(Self.quote(bundled)) \(Self.link)",
            prompt: L("SuckMyDisk 要在 /usr/local/bin 放一个 smd 命令行的链接。",
                      "SuckMyDisk wants to link its smd command line into /usr/local/bin."))
    }

    /// Only the link to an app's smd: a program someone put there by hand stays.
    func remove() {
        guard let here = copies.first(where: { $0.path == Self.link }), here.kind == .app else { return }
        run("if [ -L \(Self.link) ]; then /bin/rm \(Self.link); fi",
            prompt: L("SuckMyDisk 要删掉 /usr/local/bin 里的 smd 链接。",
                      "SuckMyDisk wants to remove the smd link from /usr/local/bin."))
    }

    /// macOS asks for the password; nothing of SuckMyDisk runs as root. The script and prompt go in
    /// as arguments, so nothing in them needs AppleScript quoting.
    private func run(_ script: String, prompt: String) {
        isWorking = true
        problem = nil
        Task {
            let r = await Task.detached {
                Shell.run(["/usr/bin/osascript", "-e", "on run argv", "-e",
                           "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
                           "-e", "end run", script, prompt], timeout: 300)
            }.value
            // -128: they pressed Cancel.
            if !r.ok, !r.stderr.contains("-128") {
                problem = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            isWorking = false
            refresh()
        }
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
