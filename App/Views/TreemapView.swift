import AppKit
import CFastScan
import DiskIndex
import Recognizers
import SwiftUI

struct TMRect: Identifiable {
    let id: NodeID
    let rect: CGRect
    let depth: Int
    let name: String
    let size: UInt64
    let color: Color
    let drillable: Bool
}

struct TreemapView: View {
    @Environment(AppModel.self) private var model
    /// An external disk; nil is the startup disk.
    var disk: ExternalDisk?
    /// Drill-down as raw paths: node ids can go away when the disk changes.
    @State private var stackPaths: [String] = []
    @State private var stack: [NodeID] = []
    @State private var rects: [TMRect] = []
    @State private var hovered: TMRect?
    /// The block whose preview is open: a file, or a folder the map doesn't go into.
    @State private var picked: TMRect?
    /// The block a right-click opens the menu for: the pointer leaving doesn't clear it.
    @State private var pointed: TMRect?

    private var tree: ScanTree? {
        if let disk { return disk.tree }
        return model.tree
    }
    private var things: [Thing] { disk?.things ?? model.things }
    private var revision: Int { disk?.treeRevision ?? model.treeRevision }
    /// Where the map opens: the home folder, or the external disk's top.
    private var start: String { disk?.volume.path ?? NSHomeDirectory() }

    var body: some View {
        Group {
            if let tree {
                VStack(alignment: .leading, spacing: 0) {
                    breadcrumb(tree)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    GeometryReader { geo in
                        canvas
                            .onAppear { relayout(tree, geo.size) }
                            .onChange(of: geo.size) { _, s in relayout(tree, s) }
                            .onChange(of: stackPaths) { _, _ in relayout(tree, geo.size) }
                            .onChange(of: revision) { _, _ in relayout(tree, geo.size) }
                    }
                    .padding(.horizontal, 16)
                    .overlay(alignment: .bottom) {
                        if let p = picked {
                            preview(p, tree).transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    infoBar(tree)
                }
                .onAppear { resolveStack(tree) }
                // A full rescan brings a new tree whose node ids mean nothing to the old state.
                .id(ObjectIdentifier(tree))
            } else if let disk {
                ContentUnavailableView {
                    Label(L("还没扫描这块盘", "This disk hasn't been scanned"), systemImage: "externaldrive")
                } actions: {
                    Button(L("扫描", "Scan")) { Task { await model.scan(disk, interactive: true) } }.disabled(disk.isBusy)
                }
            } else {
                ContentUnavailableView {
                    Label(L("索引需要更新", "The index needs a refresh"), systemImage: "square.grid.3x3.square")
                } description: {
                    Text(L("刚清理过磁盘，重新扫描一下就能看到最新的全盘地图。", "You just cleaned up; rescan to see the current map."))
                } actions: {
                    Button(L("重新扫描", "Rescan")) { Task { await model.rescan() } }.disabled(model.isBusy)
                }
            }
        }
        .navigationTitle(disk?.volume.name ?? L("全盘", "Whole Disk"))
    }

    private func pathTo(_ node: NodeID, _ tree: ScanTree) -> [NodeID] {
        var out: [NodeID] = [node]
        var cur = node
        while let p = tree.parent(cur), p != ScanTree.root { out.insert(p, at: 0); cur = p }
        return out
    }

    private var canvas: some View {
        Canvas { ctx, _ in
            for r in rects {
                let path = Path(roundedRect: r.rect, cornerRadius: r.depth == 0 ? 7 : 4, style: .continuous)
                let isHover = hovered?.id == r.id
                if r.depth == 0 {
                    ctx.fill(path, with: .color(r.color.opacity(isHover ? 0.30 : 0.18)))
                } else {
                    ctx.fill(path, with: .color(r.color.opacity(isHover ? 0.85 : 0.55)))
                }
                if picked?.id == r.id { ctx.stroke(path, with: .color(.primary.opacity(0.8)), lineWidth: 2) }
                if r.rect.width > 54 && r.rect.height > 18 {
                    let size = Text(Fmt.bytes(r.size)).font(.system(size: 10)).foregroundStyle(.secondary)
                    let label = Text("\(Text(r.name).font(.system(size: 11, weight: r.depth == 0 ? .semibold : .regular)))  \(size)")
                    var inner = ctx
                    inner.clip(to: Path(r.rect.insetBy(dx: 5, dy: 2)))
                    inner.draw(label, at: CGPoint(x: r.rect.minX + 6, y: r.rect.minY + 3), anchor: .topLeading)
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                // Only on moving to another block: each change redraws the map and rebuilds its menu.
                let hit = rects.last { $0.rect.contains(p) }
                if hit?.id != hovered?.id || hit?.id != pointed?.id {
                    hovered = hit
                    pointed = hit
                }
            case .ended: hovered = nil
            }
        }
        .onTapGesture(count: 1, coordinateSpace: .local) { p in
            guard let tree, let r = rects.last(where: { $0.rect.contains(p) }) else {
                withAnimation(.snappy) { picked = nil }
                return
            }
            withAnimation(.snappy) {
                if r.drillable {
                    picked = nil
                    stackPaths = pathTo(r.id, tree).map { tree.rawPath($0) }
                } else {
                    picked = picked?.id == r.id ? nil : r
                }
            }
        }
        .contextMenu {
            if let r = pointed, let tree { blockMenu(r, tree) }
        }
    }

    // MARK: acting on a block

    private var busy: Bool { model.isBusy || (disk?.isBusy ?? false) }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Ticks the item and opens the Clean Up sheet: the map itself never removes anything.
    private func addToCleanUp(_ item: ReclaimItem) {
        model.setSelected([item.id], true)
        model.confirmCleanUp(disk)
    }

    /// Named after the item when it isn't the block itself ("Uninstall Figma" for its data folder).
    private func addTitle(_ item: ReclaimItem, _ r: TMRect) -> String {
        item.label == r.name ? L("加入清理…", "Add to Clean Up…") : L("加入清理：\(item.label)…", "Add to Clean Up: \(item.label)…")
    }

    private var unlisted: String { L("这一项没有在这几类里列出，可以在访达里处理", "Not in any list here; you can handle it in Finder") }

    @ViewBuilder
    private func blockMenu(_ r: TMRect, _ tree: ScanTree) -> some View {
        let path = tree.path(r.id)
        let found = Report.items(at: path, in: things)
        Button(L("在访达中显示", "Show in Finder")) { reveal(path) }
        Divider()
        if found.isEmpty {
            Button(unlisted) {}.disabled(true)
        }
        ForEach(found, id: \.item.id) { m in
            Button(addTitle(m.item, r)) { addToCleanUp(m.item) }.disabled(busy)
        }
    }

    /// A block's symbol until its cover is ready: by kind of file, a folder for folders.
    private func symbol(_ r: TMRect, _ tree: ScanTree) -> String {
        if let g = LargeFileRecognizer.group(of: r.name, package: false), g != .other {
            return LargeFileIcon.symbol("large:" + g.rawValue)
        }
        return tree.isDir(r.id) ? "folder" : "doc"
    }

    private func preview(_ r: TMRect, _ tree: ScanTree) -> some View {
        let path = tree.path(r.id)
        let found = Report.items(at: path, in: things)
        return HStack(alignment: .top, spacing: 14) {
            FileThumbnail(path: tree.isDir(r.id) ? nil : path, side: 64, symbol: symbol(r, tree), tint: r.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.name).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(Fmt.bytes(r.size)).monospacedDigit()
                }
                Text(Fmt.home(path))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                if found.isEmpty {
                    Text(unlisted).font(.caption).foregroundStyle(.tertiary)
                } else if found.count == 1, let i = found.first?.item {
                    Text(i.reason + (i.restore.map { L(" · 恢复：", " · restore: ") + $0 } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack {
                    Button(L("在访达中显示", "Show in Finder")) { reveal(path) }
                    if found.count == 1, let i = found.first?.item {
                        Button(addTitle(i, r)) { addToCleanUp(i) }.buttonStyle(.borderedProminent).disabled(busy)
                    } else if found.count > 1 {
                        Menu(L("加入清理", "Add to Clean Up")) {
                            ForEach(found, id: \.item.id) { m in Button(m.item.label) { addToCleanUp(m.item) } }
                        }
                        .fixedSize()
                        .disabled(busy)
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            Button { withAnimation(.snappy) { picked = nil } } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help(L("关闭", "Close"))
        }
        .padding(14)
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(12)
    }

    /// Maps the path stack onto the current tree, dropping folders that no longer exist.
    private func resolveStack(_ tree: ScanTree) {
        var out: [NodeID] = []
        for p in stackPaths {
            guard let hit = tree.nearest(p), hit.exact, tree.isDir(hit.node) else { break }
            out.append(hit.node)
        }
        if out.isEmpty {
            out = tree.find(start).map { pathTo($0, tree) } ?? tree.children(ScanTree.root)
            stackPaths = out.map { tree.rawPath($0) }
        } else if out.count < stackPaths.count {
            stackPaths = Array(stackPaths.prefix(out.count))
        }
        stack = out
    }

    private func breadcrumb(_ tree: ScanTree) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(stack.enumerated()), id: \.offset) { i, n in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(i == 0 ? (disk?.volume.name ?? L("磁盘", "Disk")) : tree.name(n)) {
                    withAnimation(.snappy) { stackPaths = Array(stackPaths.prefix(i + 1)) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(i == stack.count - 1 ? .primary : .secondary)
                .font(.callout.weight(i == stack.count - 1 ? .semibold : .regular))
            }
            Spacer()
            if let top = stack.last {
                Text(Fmt.bytes(tree.size(top))).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func infoBar(_ tree: ScanTree) -> some View {
        HStack {
            if let h = hovered {
                Text(h.name).font(.callout.weight(.medium))
                Text(Fmt.home(tree.path(h.id))).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Fmt.bytes(h.size)).monospacedDigit()
            } else {
                Text(L("点文件夹钻进去，点文件看预览，右键可以在访达中显示或加入清理；上方路径可以返回，颜色表示它属于哪一类。",
                       "Click a folder to go in and a file to preview it; right-click to show it in Finder or add it to Clean Up. The path above goes back; colors show what kind of thing it is."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: layout

    private func relayout(_ tree: ScanTree, _ size: CGSize) {
        resolveStack(tree)
        if let h = hovered, tree.isDetached(h.id) { hovered = nil }
        guard let top = stack.last, size.width > 10, size.height > 10 else { return }
        let kinds = kindMap(tree)
        var out: [TMRect] = []
        layout(tree, top, CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), depth: 0, kinds: kinds, out: &out)
        rects = out
        // Where they are now, and gone when no longer shown.
        if let h = hovered { hovered = out.first { $0.id == h.id } }
        if let p = picked { picked = out.first { $0.id == p.id } }
        if let p = pointed { pointed = out.first { $0.id == p.id } }
    }

    private func kindMap(_ tree: ScanTree) -> [NodeID: ThingKind] {
        var m: [NodeID: ThingKind] = [:]
        // Browser profiles sit inside app data: coloring them would hide what holds them.
        for t in things where t.kind != .browser {
            if let p = t.path, let n = tree.find(p) { m[n] = t.kind }
            for i in t.items { if let p = i.path, let n = tree.find(p) { m[n] = t.kind } }
        }
        return m
    }

    private func color(_ tree: ScanTree, _ node: NodeID, _ kinds: [NodeID: ThingKind]) -> Color {
        var cur: NodeID? = node
        while let c = cur, c != ScanTree.root {
            if let k = kinds[c] { return k.color }
            cur = tree.parent(c)
        }
        return Color(nsColor: .systemGray)
    }

    private func layout(_ tree: ScanTree, _ node: NodeID, _ rect: CGRect, depth: Int, kinds: [NodeID: ThingKind], out: inout [TMRect]) {
        var kids = tree.sortedChildren(node).filter { tree.size($0) > 0 }
        let total = Double(kids.reduce(UInt64(0)) { $0 + tree.size($1) })
        guard total > 0 else { return }
        // Keep what is visible; tiny items are not drawn.
        var acc = 0.0
        var keep = 0
        for k in kids {
            acc += Double(tree.size(k))
            keep += 1
            if acc / total > 0.995 || keep >= 60 { break }
        }
        kids = Array(kids.prefix(keep))
        let frames = Squarify.layout(kids.map { Double(tree.size($0)) }, in: rect)
        for (k, f) in zip(kids, frames) where f.width >= 2 && f.height >= 2 {
            let n = tree.node(k).pointee
            let isDir = n.flags & SM_F_DIR != 0
            let drillable = isDir && n.flags & SM_F_COLLAPSED == 0 && n.first_child != SM_NONE
            let r = f.insetBy(dx: 1.5, dy: 1.5)
            out.append(TMRect(id: k, rect: r, depth: depth, name: tree.name(k) + (isDir ? "" : ""), size: tree.size(k),
                              color: color(tree, k, kinds), drillable: drillable))
            if depth == 0, drillable, r.width > 70, r.height > 50 {
                layout(tree, k, CGRect(x: r.minX + 3, y: r.minY + 20, width: r.width - 6, height: r.height - 23),
                       depth: 1, kinds: kinds, out: &out)
            }
        }
    }
}

/// Squarified treemap (Bruls, Huizing, van Wijk).
enum Squarify {
    static func layout(_ values: [Double], in r: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, r.width > 0, r.height > 0 else { return out }
        let scale = Double(r.width * r.height) / total
        let areas = values.map { $0 * scale }
        var rect = r
        var i = 0
        while i < areas.count {
            let short = Double(min(rect.width, rect.height))
            var j = i + 1
            var sum = areas[i]
            var worst = ratio(areas[i...i], sum, short)
            while j < areas.count {
                let w = ratio(areas[i...j], sum + areas[j], short)
                if w > worst { break }
                worst = w
                sum += areas[j]
                j += 1
            }
            if rect.width >= rect.height {
                let w = CGFloat(sum / Double(rect.height))
                var y = rect.minY
                for k in i..<j {
                    let h = CGFloat(areas[k]) / w
                    out[k] = CGRect(x: rect.minX, y: y, width: w, height: h)
                    y += h
                }
                rect = CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
            } else {
                let h = CGFloat(sum / Double(rect.width))
                var x = rect.minX
                for k in i..<j {
                    let w = CGFloat(areas[k]) / h
                    out[k] = CGRect(x: x, y: rect.minY, width: w, height: h)
                    x += w
                }
                rect = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
            }
            i = j
        }
        return out
    }

    private static func ratio(_ row: ArraySlice<Double>, _ sum: Double, _ short: Double) -> Double {
        guard let mx = row.max(), let mn = row.min(), sum > 0, mn > 0 else { return .infinity }
        let s2 = sum * sum, w2 = short * short
        return max(w2 * mx / s2, s2 / (w2 * mn))
    }
}
