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
            case .cleaning(let cur, let done, let total):
                pill(L("正在清理 \(done + 1)/\(total) · \(cur)", "Cleaning \(done + 1)/\(total) · \(cur)"))
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

    var body: some View {
        let plan = disk.map(model.plan(for:)) ?? model.plan
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("已选 \(plan.items.count) 项", "\(plan.items.count) selected"))
                    .font(.callout.weight(.medium))
                Text(L("预计腾出 \(Fmt.bytes(plan.freed))", "frees about \(Fmt.bytes(plan.freed))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button {
                model.confirmCleanUp(disk)
            } label: {
                Text(L("清理…", "Clean Up…")).padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(plan.items.isEmpty || model.isBusy || (disk?.isBusy ?? false))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(16)
    }
}

struct CleanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let plan = model.cleanPlan
        let groups: [(String, String, [ReclaimItem])] = [
            (L("直接删除", "Delete"), L("能重新生成，恢复方法记在日志里", "rebuildable; restore steps are logged"),
             plan.items.filter { if case .delete = $0.action { return true }; if case .deleteAll = $0.action { return true }; if case .compound = $0.action { return true }; return false }),
            (L("运行工具自带的清理命令", "Run the tool's own cleanup"), L("工具自己知道哪些还在用", "the tool knows what is still in use"),
             plan.items.filter { if case .command = $0.action { return true }; return false }),
            (L("移到废纸篓", "Move to Trash"), L("你的文件，可以从废纸篓找回", "your files; recoverable from the Trash"),
             plan.items.filter { if case .trash = $0.action { return true }; return false }),
        ]
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(plan.items.count)).font(.title2.weight(.semibold))
                Spacer()
                Text(L("约腾出 \(Fmt.bytes(plan.freed))", "≈ \(Fmt.bytes(plan.freed))")).font(.title3).monospacedDigit().foregroundStyle(.secondary)
            }
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
                                    if let p = i.path {
                                        Text(Fmt.home(p)).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(Fmt.bytes(i.estimate)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            Text(L("iCloud、照片、git 跟踪的文件和 7 天内改过的东西不会被碰，执行前每一项都会再检查一遍。",
                   "iCloud, Photos, git-tracked files and anything changed in the last 7 days are never touched; every item is re-checked first."))
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

struct ResultSheet: View {
    var result: CleanResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let failed = !result.failed.isEmpty
        VStack(spacing: 14) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(failed ? .orange : .green)
            Text(L("腾出了", "Freed")).foregroundStyle(.secondary)
            BigNumber(bytes: result.freed, size: 48)
            Text(summary).foregroundStyle(.secondary)
            if failed { list(L("没清掉", "Failed"), result.failed, .orange) }
            if !result.skipped.isEmpty { list(L("跳过", "Skipped"), result.skipped, .secondary) }
            Button(L("好", "Done")) { dismiss() }.keyboardShortcut(.defaultAction).padding(.top, 6)
        }
        .padding(28)
        .frame(width: 400)
    }

    private var summary: String {
        var parts = [L("完成 \(result.done) 项", "\(result.done) done")]
        if !result.failed.isEmpty { parts.append(L("\(result.failed.count) 项没清掉", "\(result.failed.count) failed")) }
        if !result.skipped.isEmpty { parts.append(L("\(result.skipped.count) 项跳过", "\(result.skipped.count) skipped")) }
        return parts.joined(separator: L("，", ", "))
    }

    private func list(_ title: String, _ rows: [(String, String)], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, x in
                Text(x.0 + L("：", ": ") + x.1).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
