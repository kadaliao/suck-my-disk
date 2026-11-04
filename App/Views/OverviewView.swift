import DiskIndex
import Recognizers
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    CapacityBar(segments: model.segments, total: model.volume.total)
                    Legend(segments: model.segments, free: model.volume.free)
                }
                reclaimHero
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    ForEach([ThingKind.project, .media, .devCache, .model, .appData], id: \.self) { k in
                        KindCard(kind: k)
                    }
                }
                honesty
            }
            .padding(32)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle(L("概览", "Overview"))
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("可用空间", "Free space")).font(.title3).foregroundStyle(.secondary)
                BigNumber(bytes: model.volume.free, size: 64)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(L("磁盘 \(Fmt.bytes(model.volume.total))", "Disk \(Fmt.bytes(model.volume.total))"))
                Text(L("已用 \(Fmt.bytes(model.volume.used))", "Used \(Fmt.bytes(model.volume.used))"))
                if let r = model.report {
                    Text(L("结果更新于 ", "Updated ") + r.createdAt.formatted(
                        .relative(presentation: .named).locale(Locale(identifier: Fmt.isChinese ? "zh_Hans" : "en"))))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private var reclaimHero: some View {
        let plan = model.plan
        return HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("还能放心腾出", "You can safely free")).font(.title3).foregroundStyle(.secondary)
                BigNumber(bytes: plan.freed, size: 44)
                Text(L("已经替你勾好 \(plan.items.count) 项：都是能重新生成的东西，或者工具自己会清理的缓存。",
                       "\(plan.items.count) items are preselected: all rebuildable, or caches the tools clean themselves."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.undecided > 1_000_000_000 {
                    Button {
                        model.section = .devCache
                    } label: {
                        Label(L("另有 \(Fmt.bytes(model.undecided)) 等你决定：模拟器、uv 缓存、还在用的项目…",
                                "\(Fmt.bytes(model.undecided)) more awaits your call: simulators, uv cache, active projects…"),
                              systemImage: "hand.raised")
                            .font(.callout)
                    }
                    .buttonStyle(.link)
                    .padding(.top, 2)
                }
            }
            Spacer()
            Button {
                model.confirming = true
            } label: {
                Label(L("一键清理", "Clean Up"), systemImage: "sparkles").padding(.horizontal, 10).padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .disabled(plan.items.isEmpty || model.isBusy)
        }
        .padding(24)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var honesty: some View {
        let sys = model.things(.system)
        return VStack(alignment: .leading, spacing: 10) {
            Text(L("账算清楚", "Honest numbers")).font(.headline)
            ForEach(sys) { t in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(t.title)
                            if t.bytes > 0 { Text(Fmt.bytes(t.bytes)).monospacedDigit().foregroundStyle(.secondary) }
                        }
                        if let d = t.detail { Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
    }
}

struct KindCard: View {
    @Environment(AppModel.self) private var model
    var kind: ThingKind

    var body: some View {
        let things = model.things(kind)
        let reclaim = model.reclaimable(kind)
        let selected = model.selectedBytes(kind)
        Button {
            model.section = Section.allCases.first { $0.kind == kind } ?? .overview
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: Section.allCases.first { $0.kind == kind }?.symbol ?? "circle")
                        .foregroundStyle(kind.color)
                        .font(.title3)
                    Text(kind.title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                Text(kind == .appData ? Fmt.bytes(model.occupied(kind)) : Fmt.bytes(reclaim))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(subtitle(things: things, selected: selected))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func subtitle(things: [Thing], selected: UInt64) -> String {
        switch kind {
        case .project:
            let sleeping = things.filter { $0.detail != nil }.count
            return L("\(things.count) 个项目有可再生的产物，\(sleeping) 个在沉睡", "\(things.count) projects with rebuildable output, \(sleeping) asleep")
        case .appData:
            return L("微信、Chrome 这类只能在应用里清理，这里告诉你怎么做", "WeChat, Chrome…: cleaned inside each app; here's how")
        default:
            return selected > 0 ? L("已勾选 \(Fmt.bytes(selected))", "\(Fmt.bytes(selected)) selected")
                                : L("\(things.count) 组，默认都没勾，需要你决定", "\(things.count) groups, none preselected")
        }
    }
}
