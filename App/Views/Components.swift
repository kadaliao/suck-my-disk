import DiskIndex
import Recognizers
import SwiftUI

struct Segment: Identifiable {
    var id: String
    var title: String
    var bytes: UInt64
    var color: Color
}

extension AppModel {
    /// The capacity bar: recognized kinds, the rest of used space, and free space.
    var segments: [Segment] {
        var segs: [Segment] = []
        var known: UInt64 = 0
        for k in [ThingKind.project, .media, .devCache, .model, .appData] {
            let b = occupied(k)
            known += b
            segs.append(Segment(id: k.rawValue, title: k.title, bytes: b, color: k.color))
        }
        if userFiles > 0 {
            segs.append(Segment(id: "files", title: L("你的文件", "Your files"), bytes: userFiles, color: .green))
            known += userFiles
        }
        if applications > 0 {
            segs.append(Segment(id: "apps", title: L("应用程序", "Applications"), bytes: applications, color: .indigo))
            known += applications
        }
        let system = occupied(.system)
        segs.append(Segment(id: "system", title: ThingKind.system.title, bytes: system, color: .gray))
        let used = volume.used
        let other = used > known + system ? used - known - system : 0
        segs.append(Segment(id: "other", title: L("其他", "Other"), bytes: other, color: Color(nsColor: .tertiaryLabelColor)))
        return segs
    }
}

struct CapacityBar: View {
    var segments: [Segment]
    var total: UInt64
    var height: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments.filter { $0.bytes > 0 }) { s in
                    Rectangle()
                        .fill(s.color.gradient)
                        .frame(width: max(2, geo.size.width * CGFloat(Double(s.bytes) / Double(max(total, 1)))))
                        .help("\(s.title) · \(Fmt.bytes(s.bytes))")
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: height / 2.6, style: .continuous))
        }
        .frame(height: height)
    }
}

struct Legend: View {
    var segments: [Segment]
    var free: UInt64

    var body: some View {
        FlowLayout(spacing: 18, lineSpacing: 8) {
            ForEach(segments.filter { $0.bytes > 0 }) { s in item(s.color, s.title, s.bytes) }
            item(Color.primary.opacity(0.12), L("可用", "Free"), free)
        }
        .font(.callout)
    }

    private func item(_ c: Color, _ t: String, _ b: UInt64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(t).foregroundStyle(.secondary)
            Text(Fmt.bytes(b)).monospacedDigit()
        }
        .fixedSize()
    }
}

/// Wraps its children onto new lines when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            lineH = max(lineH, s.height)
        }
        return CGSize(width: maxX, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}

struct BigNumber: View {
    var bytes: UInt64
    var size: CGFloat = 56

    var body: some View {
        let parts = Fmt.bytes(bytes).split(separator: " ")
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(String(parts.first ?? ""))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(bytes)))
            Text(String(parts.count > 1 ? parts[1] : ""))
                .font(.system(size: size * 0.42, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .animation(.spring(duration: 0.8), value: bytes)
    }
}

struct StatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .idle: EmptyView()
            case .loading: pill(L("正在载入…", "Loading…"))
            case .scanning(let files, let bytes):
                pill(L("正在扫描 \(files.formatted()) 个文件 · \(Fmt.bytes(bytes))", "Scanning \(files.formatted()) files · \(Fmt.bytes(bytes))"))
            case .recognizing(let m): pill(m)
            // Clean Up has its own page.
            case .cleaning: EmptyView()
            }
        }
        .padding(.bottom, 16)
        .animation(.smooth, value: model.phase)
    }

    private func pill(_ s: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(s).font(.callout).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct FirstScanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            Text(L("第一次需要扫描整块磁盘", "The first run scans the whole disk"))
                .font(.title2.weight(.semibold))
            Text(L("大约一分钟。之后它跟着磁盘实时更新，打开就是最新结果。",
                   "About a minute. After that it follows the disk live, so results are current whenever you open it."))
                .foregroundStyle(.secondary)
            if case .scanning(let files, let bytes) = model.phase {
                VStack(spacing: 6) {
                    BigNumber(bytes: bytes, size: 40)
                    Text(L("\(files.formatted()) 个文件", "\(files.formatted()) files")).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bottom bar shown in reclaim lists.
struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    var kind: ThingKind?
    /// An external disk's list; nil is the startup disk.
    var disk: ExternalDisk?
    @State private var showList = false

    private var waitReason: String? {
        if let disk, disk.isBusy {
            return L("正在更新外接盘的扫描结果，完成后可清理", "Updating the external disk scan. Cleanup will be available when it finishes.")
        }
        switch model.phase {
        case .idle: return nil
        case .loading, .scanning, .recognizing:
            return L("正在更新启动盘的扫描结果，完成后可清理", "Updating the startup disk scan. Cleanup will be available when it finishes.")
        case .cleaning:
            return L("请等待当前清理结束", "Waiting for the current cleanup to finish.")
        }
    }

    var body: some View {
        let plan = disk.map(model.plan(for:)) ?? model.plan
        let reason = waitReason
        HStack(spacing: 14) {
            Button { showList.toggle() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(L("已选 \(plan.items.count) 项", "\(plan.items.count) selected"))
                        Image(systemName: "chevron.up")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showList ? 180 : 0))
                    }
                    .font(.callout.weight(.medium))
                    Text(L("预计腾出 \(Fmt.bytes(plan.freed))", "frees about \(Fmt.bytes(plan.freed))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(plan.items.isEmpty)
            .help(L("看看勾了哪些，不想清的可以在这里取消", "See what is ticked; untick anything you want to keep"))
            .popover(isPresented: $showList, arrowEdge: .top) {
                SelectedList(things: disk?.things ?? model.things, navigates: disk == nil)
                    .frame(width: 480)
                    .padding(16)
            }
            Spacer()
            if !plan.items.isEmpty, let reason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.confirmCleanUp(disk)
            } label: {
                Text(L("清理…", "Clean Up…")).padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(plan.items.isEmpty || reason != nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(16)
    }
}

/// What is ticked, grouped by the thing it belongs to, so a total can be checked before cleaning
/// and anything worth keeping unticked. A row unticked here stays (unticked) while the list is
/// open, so a slip is one click to undo.
struct SelectedList: View {
    @Environment(AppModel.self) private var model
    var things: [Thing]
    /// Group titles open their list. Off for an external disk, whose list is the page itself.
    var navigates = true
    var maxHeight: CGFloat = 380
    @State private var seen: Set<String> = []

    private var planIDs: Set<String> {
        Set(Planner.plan(things: things, selected: model.selection).items.map(\.id))
    }

    var body: some View {
        let ids = planIDs
        let shown = seen.union(ids)
        let groups: [(thing: Thing, items: [ReclaimItem], freed: UInt64)] = things.compactMap { t in
            let items = t.items.filter { shown.contains($0.id) }.sorted { $0.estimate > $1.estimate }
            guard !items.isEmpty else { return nil }
            return (t, items, items.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.estimate })
        }
        .sorted { $0.freed == $1.freed ? $0.thing.title < $1.thing.title : $0.freed > $1.freed }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(groups, id: \.thing.id) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        header(g.thing, freed: g.freed)
                        ForEach(g.items) { i in row(i, in: g.thing, on: ids.contains(i.id)) }
                    }
                }
            }
            .padding(.trailing, 8)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { seen = ids }
        .onChange(of: ids) { _, new in seen.formUnion(new) }
    }

    @ViewBuilder
    private func header(_ t: Thing, freed: UInt64) -> some View {
        let section = Section.allCases.first { $0.kind == t.kind }
        HStack(spacing: 6) {
            Image(systemName: section?.symbol ?? "circle").foregroundStyle(t.kind.color).frame(width: 18)
            if navigates, let section {
                Button { model.section = section } label: {
                    HStack(spacing: 3) {
                        Text(t.title).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .help(L("在「\(section.title)」里查看", "Show in \(section.title)"))
            } else {
                Text(t.title).lineLimit(1)
            }
            Spacer()
            Text(Fmt.bytes(freed)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout.weight(.medium))
    }

    private func row(_ i: ReclaimItem, in t: Thing, on: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { model.toggle(i) } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(i.label).lineLimit(1).foregroundStyle(on ? .primary : .secondary)
                if let p = i.path, p != t.path {
                    Text(Fmt.home(p)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(ItemRow.amount(i)).monospacedDigit().foregroundStyle(.secondary)
                .strikethrough(!on)
        }
        .font(.callout)
        .padding(.leading, 24)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(i) }
        .contextMenu {
            if let p = i.path {
                Button(L("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            }
        }
        .help(i.reason)
    }
}

struct CleanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let plan = model.cleanPlan
        let groupOf = Dictionary((model.cleanDisk?.things ?? model.things).flatMap { t in t.items.map { ($0.id, t.title) } },
                                 uniquingKeysWith: { a, _ in a })
        let uninstall = plan.items.filter { $0.app != nil && $0.action.isTrashOnly }
        let erase = plan.items.filter { $0.tier == .erase }
        let rest = plan.items.filter { !($0.app != nil && $0.action.isTrashOnly) && $0.tier != .erase }
        let groups: [(String, String, [ReclaimItem])] = [
            (L("永久清除浏览器记录", "Erase browser records"), L("清掉就找不回来；浏览器开着的会跳过", "gone for good; skipped while the browser is open"),
             erase),
            (L("卸载应用", "Uninstall apps"), L("应用和它的数据移到废纸篓，可以放回", "each app and its data go to the Trash; you can put them back"),
             uninstall),
            (L("直接删除", "Delete"), L("能重新生成，恢复方法记在日志里", "rebuildable; restore steps are logged"),
             rest.filter { if case .delete = $0.action { return true }; if case .deleteAll = $0.action { return true }; if case .compound = $0.action { return !$0.action.isTrashOnly }; return false }),
            (L("运行工具自带的清理命令", "Run the tool's own cleanup"), L("工具自己知道哪些还在用", "the tool knows what is still in use"),
             rest.filter { if case .command = $0.action { return true }; return false }),
            (L("移到废纸篓", "Move to Trash"), L("你的文件，可以从废纸篓找回", "your files; recoverable from the Trash"),
             rest.filter { $0.action.isTrashOnly }),
        ]
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(plan.items.count)).font(.title2.weight(.semibold))
                Spacer()
                Text(L("约腾出 \(Fmt.bytes(plan.freed))", "≈ \(Fmt.bytes(plan.freed))")).font(.title3).monospacedDigit().foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups.filter { !$0.2.isEmpty }, id: \.0) { g in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(g.0).font(.headline)
                                    Text(g.1).font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(g.2) { i in
                                    HStack {
                                        Text(i.label).lineLimit(1)
                                        if let w = i.path.map(Fmt.home) ?? groupOf[i.id] {
                                            Text(w).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        Text(ItemRow.amount(i)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                    .background {
                                        // The item just added from the map: easy to find among the ticked ones.
                                        if i.id == model.cleanFocus {
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .fill(Color.accentColor.opacity(0.18))
                                                .padding(.horizontal, -6)
                                                .padding(.vertical, -3)
                                        }
                                    }
                                    .id(i.id)
                                }
                            }
                        }
                    }
                    // Room for the mark around a row; the list itself stays lined up with the title.
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                }
                .padding(.horizontal, -6)
                .frame(maxHeight: 360)
                .onAppear {
                    // It may be in the last group, below what the list shows at first.
                    guard let id = model.cleanFocus else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Text(L("iCloud、照片和 git 跟踪的文件受保护。遇到程序占用时，可跳过该项，或在提示中确认退出程序后继续。",
                   "iCloud, Photos and git-tracked files are protected. If a program is using an item, you can skip it or confirm a request to quit the program."))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("清理", "Clean Up")) {
                    dismiss()
                    Task { await model.clean() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func title(_ n: Int) -> String {
        guard let d = model.cleanDisk else { return L("清理 \(n) 项", "Clean up \(n) items") }
        return L("清理「\(d.volume.name)」上的 \(n) 项", "Clean up \(n) items on “\(d.volume.name)”")
    }
}

/// Shows whether numbers follow the disk live.
struct LiveBadge: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            switch model.liveState {
            case .live:
                Circle().fill(.green).frame(width: 7, height: 7)
                    .shadow(color: .green.opacity(0.6), radius: 3)
                Text(L("实时", "Live"))
            case .catchingUp:
                ProgressView().controlSize(.mini)
                Text(L("正在追上离开期间的改动…", "Catching up on changes…"))
            case .off:
                Circle().fill(.secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text(L("未在跟踪", "Not following"))
            }
            if compact {
                EmptyView()
            } else if model.refreshing {
                Text("·")
                ProgressView().controlSize(.mini)
                Text(L("重新识别中", "re-recognizing"))
            } else if let r = model.report, model.liveState != .catchingUp {
                Text("·")
                Text(L("识别于 ", "recognized ") + r.createdAt.formatted(
                    .relative(presentation: .named).locale(Locale(identifier: Fmt.isChinese ? "zh_Hans" : "en"))))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(L("文件一变，这里的数字几秒内跟着变；识别（项目、缓存等）在后台按需重跑。",
                "Numbers follow file changes within seconds; recognition (projects, caches…) reruns in the background when needed."))
    }
}

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("可用空间", "Free space")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                LiveBadge(compact: true)
            }
            BigNumber(bytes: model.volume.free, size: 34)
            CapacityBar(segments: model.segments, total: model.volume.total, height: 10)
            Divider()
            HStack {
                Text(L("可以再腾出", "Can still free"))
                Spacer()
                Text(Fmt.bytes(model.plan.freed)).monospacedDigit()
            }
            .font(.callout)
            UpdateMenuRow()
            Button(L("打开 SuckMyDisk", "Open SuckMyDisk")) {
                openWindow(id: "main")
                NSApp.activate()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 280)
    }
}
