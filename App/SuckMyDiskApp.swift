import DiskIndex
import Recognizers
import SwiftUI
import Update

/// Starts the model at launch (the main window may not be open), and saves the
/// index on quit so the next launch only replays what changed since.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    @MainActor static var updater: Updater?
    @MainActor static var helper: Helper?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window shows. `--snapshot-appearance` overrides it later.
        MainActor.assumeIsolated { Appearance.apply() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let model = Self.model else { return }
            if CommandLine.arguments.contains("--demo") { model.startDemo() } else { model.start() }
            Self.updater?.start(model)
            Snapshotter.runIfRequested(model)
        }
    }

    /// Back from System Settings, where the helper is allowed or turned off.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { Self.helper?.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.model?.saveNow()
            Self.updater?.installOnQuit()
        }
    }
}

@main
struct SuckMyDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @State private var updater: Updater
    @State private var helper: Helper
    /// Reopened by an update while its window was closed: stay in the menu bar.
    private let hidden = CommandLine.arguments.contains("--hidden")

    init() {
        // Screenshot and demo runs never read folders macOS would ask about, and never update.
        let staged = CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--demo")
        if staged { Privacy.alwaysSkip = true }
        let m = AppModel()
        _model = State(initialValue: m)
        AppDelegate.model = m
        let u = Updater(enabled: !staged)
        _updater = State(initialValue: u)
        AppDelegate.updater = u
        let h = Helper(enabled: !staged)
        _helper = State(initialValue: h)
        AppDelegate.helper = h
    }

    var body: some Scene {
        Window("SuckMyDisk", id: "main") {
            RootView()
                .environment(model)
                .environment(updater)
                .environment(helper)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(hidden ? .suppressed : .automatic)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L("检查更新…", "Check for Updates…")) { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.isWorking)
            }
            CommandGroup(after: .newItem) {
                Button(L("重新扫描", "Rescan")) { Task { await model.rescanCurrent() } }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy || (model.currentDisk?.isBusy ?? false))
            }
        }

        Settings {
            SettingsView().environment(updater).environment(helper)
        }

        MenuBarExtra {
            MenuBarPanel().environment(model).environment(updater).environment(helper)
        } label: {
            Label(Fmt.bytes(model.volume.free), systemImage: "internaldrive")
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.page) {
                ForEach([Section.overview], id: \.self) { s in sidebarRow(s) }
                SwiftUI.Section(L("可以清理", "Reclaim")) {
                    ForEach([Section.project, .media, .devCache, .model, .largeFiles, .apps, .appData], id: \.self) { s in sidebarRow(s) }
                }
                SwiftUI.Section(L("隐私", "Privacy")) {
                    sidebarRow(.browsers)
                }
                SwiftUI.Section(L("透视", "Explore")) {
                    ForEach([Section.disk, .timeline], id: \.self) { s in sidebarRow(s) }
                }
                if !model.externals.isEmpty {
                    SwiftUI.Section(L("外接磁盘", "External Disks")) {
                        ForEach(model.externals) { d in diskRow(d) }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { UpdateCard() }
            .animation(.smooth, value: updater.release)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .toolbar(removing: model.cleanRun == nil ? nil : .sidebarToggle)
        } detail: {
            detail
                .toolbar {
                    if model.cleanRun == nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                Task { await model.rescanCurrent() }
                            } label: {
                                Label(L("重新扫描", "Rescan"), systemImage: "arrow.clockwise")
                            }
                            .disabled(model.isBusy || (model.currentDisk?.isBusy ?? false))
                            .help(model.currentDisk.map { L("重新扫描「\($0.volume.name)」", "Rescan “\($0.volume.name)”") }
                                  ?? L("重新扫描整个磁盘", "Rescan the whole disk"))
                        }
                    }
                }
                .overlay(alignment: .bottom) { StatusPill() }
        }
        // Clean Up takes the whole window, from the first item to the result. The toolbar
        // stays (hiding it hides the window buttons too); only its items go.
        .toolbar(removing: model.cleanRun == nil ? nil : .title)
        .toolbarBackgroundVisibility(model.cleanRun == nil ? .automatic : .hidden, for: .windowToolbar)
        .overlay {
            if let run = model.cleanRun {
                CleanRunView(run: run).transition(.opacity)
            }
        }
        .sheet(isPresented: $model.confirming) { CleanSheet() }
    }

    @ViewBuilder
    private func sidebarRow(_ s: Section) -> some View {
        Label {
            HStack {
                Text(s.title)
                Spacer()
                // Apps: what they take up; uninstalling all of them is not "reclaimable".
                // Browsers: how many; what they hold is records more than space.
                if s == .browsers, case let n = model.things(.browser).count, n > 0 {
                    Text("\(n)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else if let k = s.kind, case let b = k == .app ? model.occupied(k) : model.reclaimable(k), b > 0 {
                    Text(Fmt.bytes(b))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: s.symbol)
                .foregroundStyle(s.kind?.color ?? .accentColor)
        }
        .tag(Page.section(s))
    }

    private func diskRow(_ d: ExternalDisk) -> some View {
        Label {
            HStack {
                Text(d.volume.name).lineLimit(1)
                Spacer()
                if d.isBusy {
                    ProgressView().controlSize(.mini)
                } else if d.reclaimable > 0 {
                    Text(Fmt.bytes(d.reclaimable))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "externaldrive").foregroundStyle(Color.accentColor)
        }
        .tag(Page.disk(d.id))
    }

    @ViewBuilder
    private var detail: some View {
        if let d = model.currentDisk {
            ExternalDiskView(disk: d).id(d.id)
        } else if model.report == nil {
            FirstScanView()
        } else {
            switch model.section {
            case .overview: OverviewView()
            case .disk: TreemapView()
            case .timeline: TimelineView()
            // Each list starts fresh: its own groups open, its own search.
            default: CategoryView(kind: model.section.kind!).id(model.section)
            }
        }
    }
}
