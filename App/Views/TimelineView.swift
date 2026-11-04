import Charts
import DiskIndex
import Recognizers
import SwiftUI

struct TimelineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let points = model.history.filter { $0.kind != "free" && $0.kind != ThingKind.system.rawValue }
        let free = model.history.filter { $0.kind == "free" }
        let days = Set(model.history.map(\.day)).count
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
                    }
                }
                .chartForegroundStyleScale(domain: [ThingKind.project, .media, .devCache, .model, .appData].map(\.title),
                                           range: [ThingKind.project, .media, .devCache, .model, .appData].map(\.color))
                .chartYAxisLabel("GB")
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
            }
            .padding(32)
        }
        .navigationTitle(L("时间线", "Timeline"))
    }
}
