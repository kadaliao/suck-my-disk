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
            case .active(let p): hovered = rects.last { $0.rect.contains(p) }
            case .ended: hovered = nil
            }
        }
        .onTapGesture(count: 1, coordinateSpace: .local) { p in
            if let r = rects.last(where: { $0.rect.contains(p) && $0.drillable }), let tree {
                withAnimation(.snappy) { stackPaths = pathTo(r.id, tree).map { tree.rawPath($0) } }
            }
        }
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
                Text(L("点一下方块钻进去，面包屑可以返回。颜色表示它属于哪一类。", "Click a block to go in; use the path above to go back. Colors show what kind of thing it is."))
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
    }

    private func kindMap(_ tree: ScanTree) -> [NodeID: ThingKind] {
        var m: [NodeID: ThingKind] = [:]
        for t in things {
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
