import DiskIndex
import Recognizers
import SwiftUI

/// Clean Up, full window: a ring that fills in item by item, the space freed so far, and
/// every item with what happened to it. When the run ends the page becomes its result.
struct CleanRunView: View {
    @Environment(AppModel.self) private var model
    var run: CleanRun

    var body: some View {
        GeometryReader { geo in
            let ring = min(250, max(168, geo.size.height * 0.32))
            VStack(spacing: 0) {
                CleanRing(run: run, size: ring)
                headline.padding(.top, 30)
                CleanRunList(run: run, maxHeight: max(120, min(420, geo.size.height - ring - 270)))
                    .frame(maxWidth: 580)
                    .padding(.top, 26)
                buttons.padding(.top, 26)
            }
            .padding(.horizontal, 40)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(.rect)
        .ignoresSafeArea()
    }

    private var headline: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if run.finished, run.trashed > 0 {
                Label(L("移到废纸篓的约 \(Fmt.bytes(run.trashed)) 要清空废纸篓后才会腾出来",
                        "About \(Fmt.bytes(run.trashed)) moved to the Trash comes back when you empty it"),
                      systemImage: "trash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .multilineTextAlignment(.center)
        .animation(.smooth, value: title)
    }

    private var title: String {
        guard run.finished else {
            return run.current.map { L("正在清理「\($0.item.label)」", "Cleaning “\($0.item.label)”") }
                ?? L("正在准备…", "Getting ready…")
        }
        if run.done == 0 { return L("什么都没清理", "Nothing was cleaned") }
        if run.notRun > 0 { return L("已停止", "Stopped") }
        if run.failed > 0 { return L("清理完成，有 \(run.failed) 项没清掉", "Done, but \(run.failed) failed") }
        return L("清理完成", "All clean")
    }

    private var subtitle: String {
        guard let end = run.finishedAt else {
            let n = min(run.settled + 1, run.rows.count)
            var s = L("第 \(n) 项，共 \(run.rows.count) 项", "Item \(n) of \(run.rows.count)")
            if let d = run.diskName { s += L(" · 「\(d)」", " · “\(d)”") }
            if run.stopping { s += L(" · 做完这一项就停", " · stopping after this one") }
            return s
        }
        var parts = [L("完成 \(run.done) 项", "\(run.done) done")]
        if run.failed > 0 { parts.append(L("\(run.failed) 项没清掉", "\(run.failed) failed")) }
        if run.skipped > 0 { parts.append(L("\(run.skipped) 项跳过", "\(run.skipped) skipped")) }
        if run.notRun > 0 { parts.append(L("\(run.notRun) 项没运行", "\(run.notRun) not run")) }
        let s = max(1, Int(end.timeIntervalSince(run.started).rounded()))
        parts.append(s < 60 ? L("用时 \(s) 秒", "took \(s) s") : L("用时 \(s / 60) 分 \(s % 60) 秒", "took \(s / 60) min \(s % 60) s"))
        return parts.joined(separator: L("，", ", "))
    }

    @ViewBuilder
    private var buttons: some View {
        if run.finished {
            Button { model.closeCleanRun() } label: {
                Text(L("完成", "Done")).frame(minWidth: 110)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        } else {
            Button { run.stopping = true } label: {
                Text(run.stopping ? L("正在停止…", "Stopping…") : L("停止", "Stop")).frame(minWidth: 110)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(run.stopping || run.rows.count - run.settled <= 1)
            .help(L("做完正在清理的这一项就停下，剩下的不动", "Finishes the item being cleaned, then leaves the rest alone"))
        }
    }
}

/// One arc per item, sized by what it should free; each lights up in its kind's color once done.
private struct CleanRing: View {
    var run: CleanRun
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let line = max(10, size * 0.055)
        let arcs = Self.arcs(run.rows.map(\.item.estimate))
        ZStack {
            Circle().stroke(Color.primary.opacity(0.07), lineWidth: line)
            ForEach(Array(run.rows.enumerated()), id: \.element.id) { i, row in
                RingArc(row: row, arc: arcs[i], line: line)
            }
            CleanRunCenter(run: run, size: size)
        }
        .padding(line / 2)
        .frame(width: size, height: size)
        .background { glow }
    }

    /// A soft light behind the ring in the color of the item being cleaned, breathing while it runs.
    @ViewBuilder
    private var glow: some View {
        let tint = run.finished ? (run.failed > 0 ? Color.orange : .green) : (run.current?.color ?? .accentColor)
        let light = Circle()
            .fill(tint)
            .frame(width: size * 2.2, height: size * 2.2)
            .blur(radius: size * 0.55)
            .opacity(scheme == .dark ? 0.26 : 0.15)
            .animation(.easeInOut(duration: 1.2), value: tint)
            .allowsHitTesting(false)
        if run.finished {
            light
        } else {
            light.phaseAnimator([0.92, 1.06]) { v, s in v.scaleEffect(s) } animation: { _ in .easeInOut(duration: 2.6) }
        }
    }

    /// Where each item's arc starts and ends, as fractions of the ring. Small items get a
    /// minimum share so every one is visible; neighbors are kept apart by a small gap.
    static func arcs(_ sizes: [UInt64]) -> [ClosedRange<Double>] {
        guard !sizes.isEmpty else { return [] }
        let floor = max(Double(sizes.reduce(0, +)), 1) / Double(sizes.count * 4)
        let w = sizes.map { max(Double($0), floor) }
        let sum = w.reduce(0, +)
        let shortest = (w.min() ?? 0) / sum
        let gap = sizes.count > 1 ? min(0.004, shortest * 0.3) : 0
        var out: [ClosedRange<Double>] = []
        var a = 0.0
        for x in w {
            let len = x / sum
            out.append((a + gap / 2)...max(a + gap / 2, a + len - gap / 2))
            a += len
        }
        return out
    }
}

private struct RingArc: View {
    var row: CleanRun.Row
    var arc: ClosedRange<Double>
    var line: CGFloat

    var body: some View {
        let lit = row.state != .waiting && row.state != .running && row.state != .notRun
        ZStack {
            if row.state == .running {
                Circle()
                    .trim(from: arc.lowerBound, to: arc.upperBound)
                    .stroke(row.color, lineWidth: line)
                    .phaseAnimator([0.15, 0.5]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 0.9) }
                    .transition(.opacity)
            }
            Circle()
                .trim(from: arc.lowerBound, to: lit ? arc.upperBound : arc.lowerBound)
                .stroke(color, lineWidth: line)
                .animation(.easeOut(duration: 0.6), value: lit)
        }
        .rotationEffect(.degrees(-90))
    }

    /// Colored means freed: what didn't go is gray (orange is already dev caches' color).
    private var color: Color {
        switch row.state {
        case .failed, .skipped: return .gray.opacity(0.4)
        default: return row.color
        }
    }
}

/// Its own view: the number ticks twice a second and redraws only this.
private struct CleanRunCenter: View {
    var run: CleanRun
    var size: CGFloat

    var body: some View {
        VStack(spacing: size * 0.02) {
            if run.finished {
                Image(systemName: run.failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: size * 0.13))
                    .foregroundStyle(run.failed > 0 ? .orange : .green)
                    .transition(.symbolEffect(.drawOn))
            }
            Text(run.finished ? L("腾出了", "Freed") : L("已腾出", "Freed so far"))
                .font(.callout)
                .foregroundStyle(.secondary)
            BigNumber(bytes: run.freed, size: size * 0.19)
            Text(L("预计约 \(Fmt.bytes(run.estimate))", "about \(Fmt.bytes(run.estimate)) expected"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CleanRunList: View {
    var run: CleanRun
    var maxHeight: CGFloat

    var body: some View {
        ViewThatFits(in: .vertical) {
            rows
            ScrollViewReader { proxy in
                ScrollView { rows }
                    .onChange(of: run.current?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: run.finished) { _, done in
                        // What needs a look: the first item that didn't go.
                        guard done, let r = run.rows.first(where: { $0.state.message != nil }) else { return }
                        withAnimation(.smooth) { proxy.scrollTo(r.id, anchor: .center) }
                    }
            }
        }
        .frame(maxHeight: maxHeight)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 18, style: .continuous))
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
    }

    // Not lazy: a run has tens of rows, and rows change height when a reason appears.
    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(run.rows) { row in
                CleanRunRow(row: row).id(row.id)
                if row.id != run.rows.last?.id { Divider().opacity(0.5).padding(.leading, 46) }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct CleanRunRow: View {
    var row: CleanRun.Row

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(row.item.label).lineLimit(1)
                    if let p = row.item.path {
                        Text(Fmt.home(p))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let why = row.state.message {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(row.state == .failed(why) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            Text(Fmt.bytes(row.item.estimate))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .opacity(row.state == .waiting || row.state == .notRun ? 0.5 : 1)
        .animation(.smooth, value: row.state)
    }

    @ViewBuilder
    private var icon: some View {
        switch row.state {
        case .waiting:
            Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: 13, height: 13)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(row.color).transition(.symbolEffect(.drawOn))
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .notRun:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        }
    }
}
