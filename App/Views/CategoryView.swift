import AppKit
import DiskIndex
import Recognizers
import SwiftUI

struct CategoryView: View {
    @Environment(AppModel.self) private var model
    var kind: ThingKind
    @State private var expanded: Set<String> = []
    @State private var query = ""

    var body: some View {
        let things = model.things(kind).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.path ?? "").localizedCaseInsensitiveContains(query) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 8)
                ForEach(things) { t in
                    ThingRow(thing: t, expanded: expanded.contains(t.id)) {
                        withAnimation(.snappy) {
                            if expanded.contains(t.id) { expanded.remove(t.id) } else { expanded.insert(t.id) }
                        }
                    }
                    Divider().opacity(0.5)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 90)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .searchable(text: $query, placement: .toolbar, prompt: L("搜索", "Search"))
        .safeAreaInset(edge: .bottom) {
            if kind != .appData { SelectionBar(kind: kind) }
        }
        .navigationTitle(kind.title)
        .onAppear {
            // Open the first few groups so the list never looks empty.
            if expanded.isEmpty { expanded = Set(model.things(kind).prefix(kind == .project ? 3 : 2).map(\.id)) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                BigNumber(bytes: kind == .appData ? model.occupied(kind) : model.reclaimable(kind), size: 40)
                Text(kind == .appData ? L("被应用数据占用", "used by app data") : L("可以腾出", "reclaimable"))
                    .foregroundStyle(.secondary)
            }
            Text(blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }

    private var blurb: String {
        switch kind {
        case .project: return L("很久没动的项目，它们的依赖和构建产物可以先删掉，源码和 git 不碰；要接着做时运行一条命令就能装回来。",
                                "Projects you haven't touched in a while: their dependencies and build output can go. Source and git stay; one command brings them back.")
        case .media: return L("渲染视频时生成的中间帧。只有找到了对应成片（帧数和成片时长 × 帧率吻合）的才会勾选。",
                              "Frames rendered on the way to a video. Only folders whose final video was found (frame count matches duration × fps) are selected.")
        case .devCache: return L("各种工具的下载缓存。能用工具自己的清理命令就用它，它最清楚哪些还在用。",
                                 "Download caches of developer tools. When a tool has its own cleanup command we use it: it knows what is still in use.")
        case .model: return L("本地模型。删掉以后可以重新下载，默认都不勾。", "Local models. They can be downloaded again; nothing is preselected.")
        case .appData: return L("这些数据属于各个应用，直接删会出问题。这里告诉你在应用里怎么清。", "This data belongs to apps and must be cleaned from inside them. Here's how.")
        case .system: return ""
        }
    }
}

struct ThingRow: View {
    @Environment(AppModel.self) private var model
    var thing: Thing
    var expanded: Bool
    var toggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleExpand) {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    groupCheck
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(thing.title).font(.body.weight(.medium)).lineLimit(1)
                            if let d = thing.detail, thing.kind == .project {
                                Text(d)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.indigo.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.indigo)
                            }
                        }
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.bytes(thing.kind == .appData ? thing.bytes : thing.reclaimable))
                            .font(.body.weight(.medium)).monospacedDigit()
                        if thing.kind != .appData, thing.bytes != thing.reclaimable {
                            Text(L("占用 \(Fmt.bytes(thing.bytes))", "uses \(Fmt.bytes(thing.bytes))"))
                                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    if thing.kind == .appData || thing.kind == .devCache, let d = thing.detail {
                        Text(d).font(.callout).foregroundStyle(.secondary).padding(.leading, 56).padding(.bottom, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if thing.kind != .appData {
                        ForEach(thing.items) { ItemRow(item: $0) }
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .contextMenu {
            if let p = thing.path {
                Button(L("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let d = thing.lastActive {
            parts.append(L("活跃于 \(Fmt.ago(d))", "active \(Fmt.ago(d))") + (thing.activitySource.map { " · \($0)" } ?? ""))
        }
        if let p = thing.path { parts.append(Fmt.home(p)) }
        return parts.joined(separator: "  ·  ")
    }

    private var selectable: [ReclaimItem] { thing.items.filter { $0.tier < .guide } }

    @ViewBuilder
    private var groupCheck: some View {
        let n = selectable.filter { model.selection.contains($0.id) }.count
        if selectable.isEmpty {
            Image(systemName: "lightbulb").foregroundStyle(.teal).frame(width: 18)
        } else {
            Button {
                model.setSelected(selectable.map(\.id), n != selectable.count)
            } label: {
                Image(systemName: n == 0 ? "circle" : (n == selectable.count ? "checkmark.circle.fill" : "minus.circle.fill"))
                    .font(.title3)
                    .foregroundStyle(n == 0 ? Color.secondary : thing.kind.color)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .frame(width: 18)
        }
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    var item: ReclaimItem

    var body: some View {
        let on = model.selection.contains(item.id)
        HStack(alignment: .top, spacing: 10) {
            Button { model.toggle(item) } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(item.tier == .guide)
            .opacity(item.tier == .guide ? 0 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.label).lineLimit(1)
                    tierBadge
                }
                Text(item.reason + (item.restore.map { L(" · 恢复：", " · restore: ") + $0 } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let p = item.path, p != itemParentPath {
                    Text(Fmt.home(p)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                ForEach(item.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).labelStyle(.titleAndIcon)
                }
            }
            Spacer()
            Text(Fmt.bytes(item.estimate) + (item.estimateIsLowerBound ? "+" : ""))
                .monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.leading, 56)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { if item.tier != .guide { model.toggle(item) } }
        .contextMenu {
            if let p = item.path {
                Button(L("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            }
        }
    }

    private var itemParentPath: String? { nil }

    @ViewBuilder
    private var tierBadge: some View {
        let (text, color): (String, Color) = {
            switch item.tier {
            case .lossless: return (L("无损", "lossless"), .green)
            case .regenerable: return (L("可再生", "rebuildable"), .blue)
            case .yours: return (L("进废纸篓", "to Trash"), .orange)
            case .guide: return (L("指引", "guide"), .teal)
            }
        }()
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.13), in: Capsule())
            .foregroundStyle(color)
    }
}
