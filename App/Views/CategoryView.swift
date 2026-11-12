import AppKit
import DiskIndex
import Recognizers
import Reclaim
import SwiftUI

struct CategoryView: View {
    @Environment(AppModel.self) private var model
    var kind: ThingKind
    @State private var expanded: Set<String> = []
    @State private var query = ""

    var body: some View {
        let things = model.things(kind).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.path ?? "").localizedCaseInsensitiveContains(query) }
        ScrollView {
            // A few groups with long lists inside (large files, browsers): a plain stack. A lazy
            // one livelocked once with rows taller than the window (see ExternalDiskView).
            if kind == .largeFile || kind == .browser {
                VStack(alignment: .leading, spacing: 0) { rows(things) }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 90)
                    .frame(maxWidth: 1100, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) { rows(things) }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 90)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: L("搜索", "Search"))
        .safeAreaInset(edge: .bottom) {
            if kind != .appData { SelectionBar(kind: kind) }
        }
        .navigationTitle(kind.title)
        .onAppear {
            // Open the first few groups so the list never looks empty.
            if expanded.isEmpty { expanded = Set(model.things(kind).prefix(kind == .project ? 3 : kind == .largeFile ? 1 : 2).map(\.id)) }
        }
    }

    @ViewBuilder
    private func rows(_ things: [Thing]) -> some View {
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                BigNumber(bytes: kind == .appData || kind == .app ? model.occupied(kind) : model.reclaimable(kind), size: 40)
                Text(kind == .appData ? L("被应用数据占用", "used by app data")
                     : kind == .app ? L("被应用和它们的数据占用", "used by apps and their data")
                     : kind == .browser ? L("缓存可以腾出", "of cache can go")
                     : kind == .largeFile ? L("移到废纸篓、清倒后可以腾出", "freed once moved to the Trash and emptied")
                     : L("可以腾出", "reclaimable"))
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
        case .app: return L("装在「应用程序」里的应用，连同它们放在资源库里的数据。可以整个卸载（应用和数据一起进废纸篓，能放回），也可以保留应用、只删它会自己重建的缓存。打开着的应用不会动，默认都不勾。",
                            "Apps in Applications, with the data they keep in your Library. Uninstall one (the app and its data go to the Trash, where you can put them back), or keep it and delete only the caches it rebuilds. Apps that are open are left alone; nothing is preselected.")
        case .appData: return L("这些数据属于各个应用，直接删会出问题。这里告诉你在应用里怎么清。", "This data belongs to apps and must be cleaned from inside them. Here's how.")
        case .largeFile: return L("个人文件夹里别处没列出的大文件：安装包、视频、磁盘映像、压缩包、模型权重…（资源库和以点开头的文件夹属于应用和工具，不在这里）。它们是你的文件：都不勾，选中的移到废纸篓，可以放回；git 跟踪的不列出。",
                                  "Big files in your home folder that nothing else lists: installers, videos, disk images, archives, model weights… (your Library and dot folders belong to apps and tools, so they're left out). They're your files: nothing is ticked, and what you pick goes to the Trash, where you can put it back. Files git tracks aren't listed.")
        case .browser: return L("浏览器记下的浏览记录、下载记录、Cookie、表单内容和上次的标签页。清掉的记录找不回来，所以都不勾；浏览器开着时不动它，先退出再清。保存的密码、书签、地址、银行卡和扩展一律不碰。",
                                "What browsers remember: history, downloads, cookies, form entries and your last tabs. Erased records can't be brought back, so nothing is ticked, and a browser that's open is left alone: quit it first. Saved passwords, bookmarks, addresses, cards and extensions are never touched.")
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
                    if thing.kind == .app { AppIcon(path: thing.path) }
                    if thing.kind == .browser { BrowserIcon(thing: thing) }
                    if thing.kind == .largeFile {
                        Image(systemName: LargeFileIcon.symbol(thing.id))
                            .font(.title3)
                            .foregroundStyle(thing.kind.color)
                            .frame(width: 26)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(thing.title).font(.body.weight(.medium)).lineLimit(1)
                            if let d = thing.detail, thing.kind == .project || thing.kind == .app || thing.kind == .browser {
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
                        if thing.kind != .appData, thing.kind != .largeFile, thing.bytes != thing.reclaimable {
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
            parts.append(thing.kind == .app ? L("打开于 \(Fmt.ago(d))", "opened \(Fmt.ago(d))")
                         : L("活跃于 \(Fmt.ago(d))", "active \(Fmt.ago(d))") + (thing.activitySource.map { " · \($0)" } ?? ""))
        }
        if let p = thing.path { parts.append(Fmt.home(p)) }
        // A list of files has no one place: say how many instead.
        if thing.kind == .largeFile, let d = thing.detail { parts.append(d) }
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
    @Environment(Helper.self) private var helper
    var item: ReclaimItem

    /// The password warning goes once the helper is on, and points to Settings while it is off.
    private var warnings: [String] {
        item.warnings.compactMap { w in
            guard w == AppRecognizer.passwordWarning else { return w }
            if helper.state == .on { return nil }
            return helper.available ? w + L("；在设置里可以改成只确认一次", "; Settings can make that a one-time approval") : w
        }
    }

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
                if let p = item.path, p != itemParentPath, item.app == nil {
                    Text(Fmt.home(p)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                if item.app != nil, item.action.isTrashOnly { AppDataList(item: item) }
                ForEach(warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).labelStyle(.titleAndIcon)
                }
            }
            Spacer()
            Text(ItemRow.amount(item))
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

    /// Records for what is erased (sizes there are next to nothing), otherwise the size it frees.
    static func amount(_ item: ReclaimItem) -> String {
        if let n = item.records { return L("\(Fmt.count(n)) 条", n == 1 ? "1 record" : "\(Fmt.count(n)) records") }
        if item.tier == .guide || (item.tier == .erase && item.estimate == 0) { return "" }
        return Fmt.bytes(item.estimate) + (item.estimateIsLowerBound ? "+" : "")
    }

    @ViewBuilder
    private var tierBadge: some View {
        let (text, color): (String, Color) = {
            switch item.tier {
            case .lossless: return (L("无损", "lossless"), .green)
            case .regenerable: return (L("可再生", "rebuildable"), .blue)
            case .yours: return (L("进废纸篓", "to Trash"), .orange)
            case .erase: return (L("永久清除", "erased for good"), .red)
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

/// A browser's app icon; a globe for one that is gone (or in demo mode, a tile).
struct BrowserIcon: View {
    @Environment(AppModel.self) private var model
    var thing: Thing

    var body: some View {
        let app = thing.items.lazy.compactMap(\.app).first
        if app != nil || model.demo != nil {
            AppIcon(path: app ?? "/Applications/\(thing.title.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? thing.title).app")
        } else {
            Image(systemName: "globe").font(.title3).foregroundStyle(.secondary).frame(width: 26)
        }
    }
}

enum LargeFileIcon {
    /// "large:video" → film.
    static func symbol(_ id: String) -> String {
        switch id.dropFirst("large:".count) {
        case "installer": return "opticaldiscdrive"
        case "vm": return "desktopcomputer"
        case "video": return "film"
        case "audio": return "waveform"
        case "archive": return "doc.zipper"
        case "model": return "cpu"
        case "app": return "app.dashed"
        default: return "doc"
        }
    }
}

/// An app's icon as Finder shows it. In demo mode, and for an app that is gone, a tile with its initial.
struct AppIcon: View {
    @Environment(AppModel.self) private var model
    var path: String?

    var body: some View {
        if model.demo == nil, let p = path, FileManager.default.fileExists(atPath: p) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 26, height: 26)
        } else {
            let name = ((path ?? "?") as NSString).lastPathComponent
            let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 360) / 360
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(hue: hue, saturation: 0.55, brightness: 0.85).gradient)
                .overlay(Text(name.prefix(1).uppercased()).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white))
                .frame(width: 22, height: 22)
                .padding(2)
        }
    }
}

/// Where an app's data is, under its Uninstall item: what goes to the Trash with it.
struct AppDataList: View {
    @Environment(AppModel.self) private var model
    var item: ReclaimItem
    @State private var all = false

    var body: some View {
        let places = Array(Executor.paths(item.action).dropFirst())
        let shown = all ? places : Array(places.prefix(5))
        VStack(alignment: .leading, spacing: 1) {
            ForEach(shown, id: \.self) { p in
                HStack(spacing: 6) {
                    Text(Fmt.home(p)).lineLimit(1).truncationMode(.middle)
                    if let n = model.tree?.find(p), let t = model.tree, t.size(n) >= 1_000_000 {
                        Text(Fmt.bytes(t.size(n))).monospacedDigit()
                    }
                }
            }
            if places.count > shown.count {
                Button(L("还有 \(places.count - shown.count) 处…", "\(places.count - shown.count) more…")) { all = true }
                    .buttonStyle(.link)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
