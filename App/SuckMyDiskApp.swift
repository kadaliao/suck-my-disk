import DiskIndex
import Recognizers
import SwiftUI

@main
struct SuckMyDiskApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("SuckMyDisk", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    model.start()
                    Snapshotter.runIfRequested(model)
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button(L("重新扫描", "Rescan")) { Task { await model.rescan() } }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy)
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
            List(selection: $model.section) {
                ForEach([Section.overview], id: \.self) { s in sidebarRow(s) }
                SwiftUI.Section(L("可以清理", "Reclaim")) {
                    ForEach([Section.project, .media, .devCache, .model, .appData], id: \.self) { s in sidebarRow(s) }
                }
                SwiftUI.Section(L("透视", "Explore")) {
                    ForEach([Section.disk, .timeline], id: \.self) { s in sidebarRow(s) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.rescan() }
                        } label: {
                            Label(L("重新扫描", "Rescan"), systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isBusy)
                        .help(L("重新扫描整个磁盘", "Rescan the whole disk"))
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
        .tag(s)
    }

    @ViewBuilder
    private var detail: some View {
        if model.report == nil {
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
