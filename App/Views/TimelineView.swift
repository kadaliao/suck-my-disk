import Charts
import DiskIndex
import Recognizers
import SwiftUI

struct TimelineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Apps overlap app data and the rest, so stacking them would count space twice; so do large
        // files (your files) and browsers (app data).
        let kinds: [ThingKind] = [.project, .media, .devCache, .model, .appData]
        let stacked = Set(kinds.map(\.rawValue))
        let points = model.history.filter { stacked.contains($0.kind) }
        let free = model.history.filter { $0.kind == "free" }
        let days = Set(model.history.map(\.day)).count
        let chosen = model.dayDetail?.day
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("谁在吃磁盘", "What is eating the disk")).font(.title2.weight(.semibold))
                    Text(days < 3
                         ? L("从 \(model.history.first?.day ?? "今天") 开始记录。每次扫描都会存一笔，过几天就能看出是谁在长。",
                             "Recording since \(model.history.first?.day ?? "today"). Every scan adds a point; in a few days you'll see what grows.")
                         : L("每天各类东西占用的空间。", "Space used by each kind, per day."))
                        .foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(points) { p in
                        BarMark(x: .value("day", p.day), y: .value("GB", Double(p.bytes) / 1e9))
                            .foregroundStyle(by: .value("kind", ThingKind(rawValue: p.kind)?.title ?? p.kind))
                            .opacity(days > 1 && chosen != nil && p.day != chosen ? 0.5 : 1)
                    }
                }
                .chartForegroundStyleScale(domain: kinds.map(\.title), range: kinds.map(\.color))
                .chartYAxisLabel("GB")
                .chartOverlay { proxy in
                    // A click picks the day under it; the breakdown below follows.
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let plot = proxy.plotFrame,
                                      let day: String = proxy.value(atX: location.x - geo[plot].origin.x) else { return }
                                model.timelineDay = day
                            }
                    }
                }
                .frame(height: 260)
                if !free.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("可用空间", "Free space")).font(.headline)
                        Chart(free) { p in
                            LineMark(x: .value("day", p.day), y: .value("GB", Double(p.bytes) / 1e9))
                                .symbol(.circle)
                                .foregroundStyle(.green)
                        }
                        .chartYAxisLabel("GB")
                        .frame(height: 160)
                    }
                }
                if let d = model.dayDetail, !d.things.isEmpty {
                    DayBreakdown(detail: d, kinds: kinds)
                }
            }
            .padding(32)
        }
        .navigationTitle(L("时间线", "Timeline"))
    }
}

/// One day thing by thing: what each one used, and how much that changed since the day before
/// it with a record.
private struct DayBreakdown: View {
    var detail: ReportStore.DayDetail
    var kinds: [ThingKind]
    @State private var folded: Set<ThingKind> = []
    @State private var showAll: Set<ThingKind> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("\(detail.day) 的明细", "\(detail.day), thing by thing")).font(.headline)
                Text(detail.previousDay.map {
                    L("和 \($0) 相比，变化最大的排在前面。点上面的柱子换一天。",
                      "Compared with \($0), biggest changes first. Click a bar above to pick another day.")
                } ?? L("这是第一天的记录，还没有可以比较的日子。", "The first day on record, so there's nothing to compare it with yet."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(kinds, id: \.self) { k in
                    let things = detail.things.filter { $0.kind == k.rawValue }
                    if !things.isEmpty {
                        group(k, things)
                        Divider().opacity(0.5)
                    }
                }
            }
        }
    }

    private func group(_ kind: ThingKind, _ things: [ReportStore.ThingChange]) -> some View {
        let open = !folded.contains(kind)
        let shown = showAll.contains(kind) ? things : Array(things.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    if open { folded.insert(kind) } else { folded.remove(kind) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Circle().fill(kind.color).frame(width: 8, height: 8)
                    Text(kind.title).font(.body.weight(.medium))
                    Text("\(things.count)").foregroundStyle(.tertiary).monospacedDigit()
                    Spacer()
                    numbers(things.reduce(0) { $0 + ($1.bytes ?? 0) }, change: things.reduce(0) { $0 + $1.change }, new: false)
                        .font(.body.weight(.medium))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { t in
                        HStack(spacing: 10) {
                            Text(t.title).lineLimit(1).truncationMode(.middle).help(t.title)
                            Spacer()
                            numbers(t.bytes, change: t.change, new: t.before == nil)
                        }
                        .font(.callout)
                    }
                    if things.count > shown.count {
                        Button(L("还有 \(things.count - shown.count) 个…", "\(things.count - shown.count) more…")) {
                            showAll.insert(kind)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .padding(.leading, 40)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
    }

    /// Size on the day and the change, in columns so they line up across rows.
    private func numbers(_ bytes: UInt64?, change: Int64, new: Bool) -> some View {
        HStack(spacing: 16) {
            Text(bytes.map(Fmt.bytes) ?? L("已不在", "gone"))
                .foregroundStyle(bytes == nil ? .tertiary : .primary)
                .frame(width: 90, alignment: .trailing)
            if detail.previousDay != nil {
                Text(new ? L("新出现", "new") : change == 0 ? "—" : (change > 0 ? "+" : "−") + Fmt.bytes(change.magnitude))
                    .foregroundStyle(change > 0 ? Color.orange : change < 0 ? Color.green : Color.secondary)
                    .frame(width: 90, alignment: .trailing)
            }
        }
        .monospacedDigit()
    }
}
