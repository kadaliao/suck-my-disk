import AppKit
import DiskIndex
import Observation
import os
import Update

private let log = Logger(subsystem: "com.kadaliao.SuckMyDisk", category: "update")

/// Keeps SuckMyDisk current from GitHub Releases. It checks about once a day, downloads a newer
/// version in the background, and installs it when nobody is looking (or on quit).
@MainActor @Observable
final class Updater {
    enum State: Equatable {
        case idle
        /// A newer version, not downloaded yet.
        case available(Release)
        case downloading(Release)
        /// Downloaded and checked: installing is a rename.
        case ready(Release, archive: URL)
        case installing(Release)
        /// On disk already; this process is the old version until it relaunches.
        case installed(Release)
    }

    var state: State = .idle
    var checking = false
    /// Why the version on offer didn't install, shown on the card.
    var problem: String?
    /// Asked to relaunch while a scan or cleanup ran: relaunches when it ends.
    var relaunchPending = false
    var checksAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: "updates.check")
            if checksAutomatically { nextCheck = .now }
        }
    }
    var installsAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(installsAutomatically, forKey: "updates.install")
            if installsAutomatically { nextCheck = .now }
        }
    }
    private(set) var lastCheck: Date? {
        didSet { UserDefaults.standard.set(lastCheck, forKey: "updates.lastCheck") }
    }

    let current: AppVersion
    /// Release builds update themselves; Xcode builds, demo and screenshot runs don't.
    let enabled: Bool
    /// Why this copy can't replace itself (running from a disk image, no permission), or nil.
    let blocker: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var nextCheck = Date.now
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// A version that failed its checks or its install: the background leaves it alone.
    @ObservationIgnored private var gaveUpOn: AppVersion?

    private static let interval: TimeInterval = 24 * 3600
    private static let retry: TimeInterval = 3600

    private var userAgent: String { "SuckMyDisk/\(current) (macOS)" }
    private var installed: URL { Bundle.main.bundleURL }
    private var downloads: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.kadaliao.SuckMyDisk/Updates", isDirectory: true)
    }

    init(enabled: Bool) {
        let d = UserDefaults.standard
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        current = version.flatMap(AppVersion.init) ?? AppVersion("0")!
        self.enabled = enabled && Updates.isReleaseBuild
        blocker = Updates.blocker(for: Bundle.main.bundleURL)
        checksAutomatically = d.object(forKey: "updates.check") as? Bool ?? true
        installsAutomatically = d.object(forKey: "updates.install") as? Bool ?? true
        lastCheck = d.object(forKey: "updates.lastCheck") as? Date
    }

    /// The version on offer, while there is one.
    var release: Release? {
        switch state {
        case .available(let r), .downloading(let r), .ready(let r, _), .installing(let r), .installed(let r): r
        case .idle: nil
        }
    }

    var isWorking: Bool {
        switch state {
        case .downloading, .installing: true
        default: checking
        }
    }

    /// Both switches on: downloads and installs happen without asking.
    private var installsOnItsOwn: Bool { checksAutomatically && installsAutomatically }

    func start(_ model: AppModel) {
        self.model = model
        guard enabled, loop == nil else { return }
        nextCheck = lastCheck.map { $0.addingTimeInterval(Self.interval) } ?? .now
        let dir = downloads, current = current
        Task.detached(priority: .utility) { Updates.pruneDownloads(in: dir, keepingNewerThan: current) }
        loop = Task {
            // Let the launch settle (index load, live catch-up) first.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func tick() async {
        if checksAutomatically, Date.now >= nextCheck, !isWorking { await check(userInitiated: false) }
        forgetMissingDownload()
        if relaunchPending { relaunch(); return }
        guard installsOnItsOwn, isUnattended else { return }
        if case .ready(let r, _) = state, gaveUpOn != r.version { await install(asked: false) }
        // Installing took a moment: only relaunch if still nobody is looking.
        if case .installed = state, isUnattended { relaunch() }
    }

    /// The download lives in Caches, which Clean Up can empty: then it has to be fetched again.
    private func forgetMissingDownload() {
        if case .ready(let r, let archive) = state, !FileManager.default.fileExists(atPath: archive.path) {
            state = .available(r)
            if installsAutomatically { nextCheck = .now }
        }
    }

    // MARK: checking

    /// Looks for a newer release. Asked from the menu, it says what it found and offers to install.
    func check(userInitiated: Bool) async {
        guard enabled else {
            if userInitiated {
                alert(L("这个版本不会自己更新", "This copy doesn't update itself"),
                      L("只有从 GitHub Releases 下载的正式版本会自己更新。", "Only release builds downloaded from GitHub update themselves."))
            }
            return
        }
        guard !isWorking else { return }
        if case .installed(let r) = state {
            if userInitiated { offer(r) }
            return
        }
        checking = true
        defer { checking = false }
        let r: Release
        do {
            r = try await Updates.latest(userAgent: userAgent)
        } catch {
            log.error("check failed: \(error.localizedDescription, privacy: .public)")
            nextCheck = Date.now.addingTimeInterval(Self.retry)
            if userInitiated { failed(error) }
            return
        }
        lastCheck = .now
        nextCheck = Date.now.addingTimeInterval(Self.interval)
        guard r.version > current else {
            state = .idle
            if userInitiated {
                alert(L("已经是最新版本", "You're up to date"),
                      L("SuckMyDisk \(current) 是最新版本。", "SuckMyDisk \(current) is the newest version."))
            }
            return
        }
        if release?.version != r.version { problem = nil }
        if case .ready(let have, let archive) = state, have.version == r.version,
           FileManager.default.fileExists(atPath: archive.path) {
            if userInitiated { offer(r) }
        } else if blocker != nil || (!userInitiated && (!installsOnItsOwn || gaveUpOn == r.version)) {
            state = .available(r)
            if userInitiated { offer(r) }
        } else if await download(r, asked: userInitiated), userInitiated {
            offer(r)
        }
    }

    /// Downloads and checks the update, so a bad one is never left waiting to be installed.
    private func download(_ r: Release, asked: Bool) async -> Bool {
        state = .downloading(r)
        do {
            let archive = try await Updates.download(r, to: downloads, userAgent: userAgent)
            let installed = installed
            try await Task.detached(priority: .utility) {
                let app = try Updates.unpack(archive, version: r.version, near: installed)
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
            }.value
            log.notice("\(r.version, privacy: .public) downloaded and checked")
            state = .ready(r, archive: archive)
            problem = nil
            return true
        } catch {
            state = .available(r)
            note(error, for: r, asked: asked)
            return false
        }
    }

    // MARK: installing

    /// The card's and the alert's button: download if needed, install, reopen.
    func update() async {
        if blocker != nil { NSWorkspace.shared.open(Updates.releasesPage); return }
        forgetMissingDownload()
        if case .available(let r) = state, await !download(r, asked: true) { return }
        if case .ready = state { await install(asked: true) }
        relaunch()
    }

    private func install(asked: Bool) async {
        guard case .ready(let r, let archive) = state else { return }
        state = .installing(r)
        let installed = installed
        do {
            try await Task.detached(priority: .userInitiated) {
                try Updates.install(archive, version: r.version, over: installed)
            }.value
            log.notice("installed \(r.version, privacy: .public)")
            state = .installed(r)
            problem = nil
        } catch {
            state = .available(r)
            note(error, for: r, asked: asked)
        }
    }

    /// Reopens as the installed version, after any scan or cleanup in progress. Reopened with no
    /// window open, it stays in the menu bar.
    private func relaunch() {
        guard case .installed = state else { relaunchPending = false; return }
        guard !isBusy else { relaunchPending = true; return }
        relaunchPending = false
        do {
            try Updates.relaunch(installed, arguments: hasOpenWindow ? [] : ["--hidden"])
            NSApp.terminate(nil)
        } catch {
            failed(error)
        }
    }

    /// Quitting with an update downloaded installs it, so the next launch is the new version.
    func installOnQuit() {
        guard enabled, installsOnItsOwn, case .ready(let r, let archive) = state, gaveUpOn != r.version else { return }
        do {
            try Updates.install(archive, version: r.version, over: installed)
            log.notice("installed \(r.version, privacy: .public) on quit")
        } catch {
            log.error("install on quit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Network trouble is retried in an hour. A version that fails its own checks is left alone
    /// until a newer one comes out or you ask again.
    private func note(_ error: Error, for r: Release, asked: Bool) {
        log.error("update to \(r.version, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        nextCheck = Date.now.addingTimeInterval(Self.retry)
        switch error as? UpdateError {
        case .signature, .wrongApp, .unpack, .cannotReplace:
            gaveUpOn = r.version
            problem = error.localizedDescription
        default:
            break
        }
        if asked { failed(error) }
    }

    /// Something is running that a relaunch would cut short.
    var isBusy: Bool {
        guard let m = model else { return false }
        return m.isBusy || m.refreshing || m.confirming || m.externals.contains(where: \.isBusy)
    }

    /// Nobody would notice a relaunch: the app is in the background, not hidden, with no window,
    /// and nothing is running.
    private var isUnattended: Bool {
        !isBusy && !NSApp.isActive && !NSApp.isHidden && NSApp.keyWindow == nil && !hasOpenWindow
    }

    private var hasOpenWindow: Bool {
        NSApp.windows.contains { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
    }

    // MARK: alerts

    private func offer(_ r: Release) {
        let a = NSAlert()
        if case .installed = state {
            a.messageText = L("SuckMyDisk \(r.version) 已经装好", "SuckMyDisk \(r.version) is installed")
        } else {
            a.messageText = L("SuckMyDisk \(r.version) 可以更新了", "SuckMyDisk \(r.version) is available")
        }
        if let blocker {
            a.informativeText = L("你现在用的是 \(current)。", "You have \(current). ") + blocker
            a.addButton(withTitle: L("打开下载页", "Open Download Page"))
        } else {
            a.informativeText = L("你现在用的是 \(current)。重新打开只要一两秒，扫描结果都会保留。",
                                  "You have \(current). Relaunching takes a second or two, and scan results are kept.")
                + (installsOnItsOwn ? L("选「稍后」的话，下次退出时装上。", " If you choose Later, it installs when you quit.") : "")
            a.addButton(withTitle: L("重新打开并更新", "Relaunch and Update"))
        }
        a.addButton(withTitle: L("稍后", "Later"))
        a.addButton(withTitle: L("更新内容", "Release Notes"))
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn: Task { await update() }
        case .alertThirdButtonReturn: NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    private func failed(_ error: Error) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("没能更新", "Couldn't update")
        a.informativeText = error.localizedDescription
        a.addButton(withTitle: L("好", "OK"))
        a.addButton(withTitle: L("打开下载页", "Open Download Page"))
        NSApp.activate()
        if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Updates.releasesPage) }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }
}
