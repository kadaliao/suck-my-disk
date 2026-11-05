import AppKit
import DiskIndex
import Recognizers
import SwiftUI

/// One external disk: what can go (projects and render frames on it) and its map.
struct ExternalDiskView: View {
    @Environment(AppModel.self) private var model
    var disk: ExternalDisk
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            if model.showDiskMap {
                TreemapView(disk: disk)
            } else {
                list
            }
        }
        .navigationTitle(disk.volume.name)
        .onAppear {
            if expanded.isEmpty { expanded = Set(disk.things.prefix(3).map(\.id)) }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("可以腾出", "Reclaimable")).font(.title3).foregroundStyle(.secondary)
                    BigNumber(bytes: disk.reclaimable, size: 44)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(L("磁盘 \(Fmt.bytes(disk.volume.total))", "Disk \(Fmt.bytes(disk.volume.total))"))
                    Text(L("可用 \(Fmt.bytes(disk.volume.free))", "Free \(Fmt.bytes(disk.volume.free))"))
                    status
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            CapacityBar(segments: segments, total: disk.volume.total, height: 14)
            Legend(segments: segments, free: disk.volume.free)
            if !model.hasFullDiskAccess, disk.report == nil, !disk.isBusy { DiskAccessBanner(disk: disk) }
            Picker("", selection: Bindable(model).showDiskMap) {
                Text(L("可以清理", "Reclaim")).tag(false)
                Text(L("方块图", "Map")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch disk.phase {
        case .scanning(let files, _):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L("正在扫描 \(files.formatted()) 个文件", "Scanning \(files.formatted()) files"))
            }
        case .recognizing(let m):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(m).lineLimit(1)
            }
        default:
            if let r = disk.report {
                SwiftUI.TimelineView(.everyMinute) { ctx in Text(scannedAgo(r.createdAt, now: ctx.date)) }
            } else {
                Text(L("还没扫描", "Not scanned yet"))
            }
        }
    }

    private func scannedAgo(_ d: Date, now: Date) -> String {
        let m = Int(now.timeIntervalSince(d) / 60)
        if m < 1 { return L("刚刚扫描", "Scanned just now") }
        if m < 60 { return L("\(m) 分钟前扫描", "Scanned \(m) min ago") }
        if m < 48 * 60 { return L("\(m / 60) 小时前扫描", "Scanned \(m / 60) h ago") }
        return L("\(m / 1440) 天前扫描", "Scanned \(m / 1440) days ago")
    }

    private var segments: [Segment] {
        let project = disk.occupied(.project), media = disk.occupied(.media)
        let used = disk.volume.used
        let other = used > project + media ? used - project - media : 0
        return [
            Segment(id: "project", title: ThingKind.project.title, bytes: project, color: ThingKind.project.color),
            Segment(id: "media", title: ThingKind.media.title, bytes: media, color: ThingKind.media.color),
            Segment(id: "other", title: L("其他", "Other"), bytes: other, color: Color(nsColor: .tertiaryLabelColor)),
        ]
    }

    // MARK: list

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach([ThingKind.project, .media], id: \.self) { kind in
                    let things = disk.things.filter { $0.kind == kind }.sorted { $0.reclaimable > $1.reclaimable }
                    if !things.isEmpty {
                        Text(kind.title).font(.headline).padding(.top, 14).padding(.bottom, 4)
                        ForEach(things) { t in
                            ThingRow(thing: t, expanded: expanded.contains(t.id)) {
                                withAnimation(.snappy) {
                                    if expanded.contains(t.id) { expanded.remove(t.id) } else { expanded.insert(t.id) }
                                }
                            }
                            Divider().opacity(0.5)
                        }
                    }
                }
                if disk.things.isEmpty { empty }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 90)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            if !disk.things.isEmpty { SelectionBar(disk: disk) }
        }
    }

    @ViewBuilder
    private var empty: some View {
        if disk.report != nil {
            ContentUnavailableView {
                Label(L("没找到可以清理的东西", "Nothing to reclaim found"), systemImage: "checkmark.circle")
            } description: {
                Text(L("这块盘上没有沉睡项目的依赖和构建产物，也没有渲染中间帧。看看「方块图」，空间都去哪了一目了然。",
                       "No sleeping projects' dependencies or build output, and no render frames on this disk. The map shows where the space goes."))
            }
            .padding(.top, 40)
        } else if disk.isBusy {
            VStack(spacing: 10) {
                ProgressView()
                Text(L("第一次扫描这块盘，扫完就能看到结果", "Scanning this disk for the first time"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else if model.hasFullDiskAccess {
            ContentUnavailableView {
                Label(L("还没扫描这块盘", "This disk hasn't been scanned"), systemImage: "externaldrive")
            } actions: {
                Button(L("扫描", "Scan")) { Task { await model.scan(disk, interactive: true) } }
            }
            .padding(.top, 40)
        }
    }
}

/// Without Full Disk Access macOS asks before an app reads an external disk, so the scan waits for the user.
struct DiskAccessBanner: View {
    @Environment(AppModel.self) private var model
    var disk: ExternalDisk

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("macOS 读外接磁盘前会先问你", "macOS asks before an app reads an external disk"))
                    .font(.callout.weight(.medium))
                Text(L("开启「完全磁盘访问」后，插上就会自动扫描。也可以现在扫描，macOS 会问一次。",
                       "With Full Disk Access, disks are scanned as soon as they are plugged in. Or scan now; macOS asks once."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(L("打开系统设置", "Open System Settings")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            Button(L("扫描", "Scan")) { Task { await model.scan(disk, interactive: true) } }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 14))
    }
}
