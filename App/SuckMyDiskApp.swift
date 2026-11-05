import DiskIndex
import Recognizers
import SwiftUI

/// Starts the model at launch (the main window may not be open), and saves the
/// index on quit so the next launch only replays what changed since.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let model = Self.model else { return }
            if CommandLine.arguments.contains("--demo") { model.startDemo() } else { model.start() }
            Snapshotter.runIfRequested(model)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.model?.saveNow() }
    }
}

@main
struct SuckMyDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        // Screenshot and demo runs never read folders macOS would ask about.
        if CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--demo") { Privacy.alwaysSkip = true }
        let m = AppModel()
        _model = State(initialValue: m)
        AppDelegate.model = m
    }

    var body: some Scene {
        Window("SuckMyDisk", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button(L("重新扫描", "Rescan")) { Task { await model.rescanCurrent() } }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy || (model.currentDisk?.isBusy ?? false))
            }
        }

        MenuBarExtra {
            MenuBarPanel().environment(model)
        } label: {
            Label(Fmt.bytes(model.volume.free), systemImage: "internaldrive")
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.page) {
                ForEach([Section.overview], id: \.self) { s in sidebarRow(s) }
                SwiftUI.Section(L("可以清理", "Reclaim")) {
                    ForEach([Section.project, .media, .devCache, .model, .appData], id: \.self) { s in sidebarRow(s) }
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
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail
                .toolbar {
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
                .overlay(alignment: .bottom) { StatusPill() }
        }
        .sheet(isPresented: $model.confirming) { CleanSheet() }
        .sheet(item: $model.lastResult) { r in ResultSheet(result: r) }
    }

    @ViewBuilder
    private func sidebarRow(_ s: Section) -> some View {
        Label {
            HStack {
                Text(s.title)
                Spacer()
                if let k = s.kind, model.reclaimable(k) > 0 {
                    Text(Fmt.bytes(model.reclaimable(k)))
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
            default: CategoryView(kind: model.section.kind!)
            }
        }
    }
}
