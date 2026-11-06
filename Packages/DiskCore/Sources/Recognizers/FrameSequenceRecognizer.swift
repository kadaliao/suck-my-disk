import AVFoundation
import CFastScan
import DiskIndex
import Insights
import Foundation
import ImageIO

/// Finds folders of rendered frames (00000.jpg ... 07303.jpg) whose final video
/// already exists. Only the frame folder itself is offered, never its parent:
/// render folders often hold paid TTS audio and stills next to the frames.
///
/// A video counts as the final only if its frame count matches almost exactly, it
/// is not inside another project, and no other frame folder sits closer to it.
public enum FrameSequenceRecognizer {
    public struct Sequence: Sendable {
        public var path: String
        public var count: Int
        public var ext: String
        public var width: Int
        public var height: Int
        public var newest: Date?
    }

    public static func recognize(_ ctx: RecognizeContext) async -> [Thing] {
        let tree = ctx.tree
        var candidates: [NodeID] = []
        let n = tree.count
        for i in 1..<UInt32(n) {
            let x = tree.node(i).pointee
            guard x.flags & SM_F_DIR != 0, x.flags & (SM_F_COLLAPSED | SM_F_PACKAGE | SM_F_DETACHED) == 0,
                  x.img_count >= 300, x.img_bytes >= 50_000_000 else { continue }
            candidates.append(i)
        }
        var sequences: [(NodeID, Sequence)] = []
        for i in candidates {
            let path = tree.path(i)
            if Guards.isDenied(path) || ctx.isOffLimits(path) { continue }
            if let seq = inspect(path) { sequences.append((i, seq)) }
        }
        // Folders holding a frame sequence: a video in one of them belongs to those frames.
        var holders: Set<NodeID> = []
        for (i, _) in sequences {
            var cur: NodeID? = i
            while let c = cur, c != ScanTree.root, holders.insert(c).inserted { cur = tree.parent(c) }
        }
        // Group by owning folder: the nearest ancestor with a git repo or manifest, else the grandparent.
        var groups: [String: [ReclaimItem]] = [:]
        var groupBytes: [String: UInt64] = [:]
        var counts: [String: Double?] = [:]
        for (i, seq) in sequences {
            let path = seq.path
            let scope = scopeDir(tree, i)
            let match = await nearestFinal(tree, frames: i, seq, stopAt: scope.node, holders: holders, cache: &counts)
            let bytes = tree.size(i)
            let recent = seq.newest.map { ctx.now.timeIntervalSince($0) < 7 * 86400 } ?? false
            var item: ReclaimItem
            if let match {
                item = ReclaimItem(
                    id: "frames:" + path, label: L("渲染帧 \(seq.count) 张", "\(seq.count) rendered frames"), path: path,
                    bytes: bytes, estimate: tree.node(i).pointee.t_alloc, tier: .regenerable, action: .delete(path: path),
                    restore: L("用原工程重新渲染", "re-render from the source project"),
                    reason: L("成片已存在：\(Fmt.home(match))（帧数和成片一致）",
                              "final video exists: \(Fmt.home(match)) (same number of frames)"),
                    preselected: !recent)
                if recent, let d = seq.newest {
                    item.warnings.append(L("\(Fmt.stamp(d)) 刚渲染过，所以没预选", "rendered \(Fmt.stamp(d)), so not preselected"))
                }
            } else {
                item = ReclaimItem(
                    id: "frames:" + path, label: L("图片序列 \(seq.count) 张", "\(seq.count)-image sequence"), path: path,
                    bytes: bytes, tier: .yours, action: .trash(path: path), restore: nil,
                    reason: L("像渲染帧，但没找到对应的成片，按你的文件处理", "looks like frames, but no matching final video was found"),
                    preselected: false)
                // Your files keep the 7-day rule even when ticked.
                if let d = Guards.recentChange(path, now: ctx.now) { item.warnings.append(Guards.waitNote(changed: d)) }
            }
            groups[scope.path, default: []].append(item)
            groupBytes[scope.path, default: 0] += bytes
        }
        return groups.map { scope, items in
            Thing(id: "media:" + scope, kind: .media,
                  title: L("渲染中间帧 · \((scope as NSString).lastPathComponent)", "Render frames · \((scope as NSString).lastPathComponent)"),
                  path: scope, bytes: groupBytes[scope] ?? 0,
                  detail: L("\(items.count) 组帧序列", "\(items.count) frame folders"),
                  items: items.sorted { $0.bytes > $1.bytes })
        }.sorted { $0.reclaimable > $1.reclaimable }
    }

    static func scopeDir(_ tree: ScanTree, _ i: NodeID) -> (node: NodeID, path: String) {
        var cur = i
        var hops = 0
        while let p = tree.parent(cur), p != ScanTree.root {
            cur = p
            hops += 1
            if tree.node(cur).pointee.markers & ProjectRecognizer.manifestMask != 0 { return (cur, tree.path(cur)) }
            if hops >= 6 { break }
        }
        // No project found: use two levels up (e.g. ch28/ for ch28/build/frames).
        var up = i
        for _ in 0..<2 { if let p = tree.parent(up), p != ScanTree.root { up = p } }
        return (up, tree.path(up))
    }

    /// Videos under `root`, leaving out other projects (folders with their own git repo or
    /// manifest) and folders in `skip`.
    static func videos(_ tree: ScanTree, under root: NodeID, skip: Set<NodeID> = []) -> [String] {
        let exts: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm"]
        func enter(_ j: NodeID, _ n: sm_node) -> Bool {
            j == root || (n.flags & SM_F_COLLAPSED == 0 && n.markers & ProjectRecognizer.manifestMask == 0 && !skip.contains(j))
        }
        var out: [String] = []
        tree.walk(from: root) { j in
            let n = tree.node(j).pointee
            if n.flags & SM_F_FILE != 0 {
                let name = tree.name(j)
                if exts.contains((name as NSString).pathExtension.lowercased()) { out.append(tree.path(j)) }
                return false
            }
            return enter(j, n)
        }
        // Small finals (< 1 MiB) are not nodes; pick them up from folders that hold videos.
        tree.walk(from: root) { j in
            let n = tree.node(j).pointee
            guard n.flags & SM_F_DIR != 0, enter(j, n) else { return false }
            if n.markers & SM_M_VIDEO_FILE != 0 {
                let dir = tree.path(j)
                for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                where exts.contains((f as NSString).pathExtension.lowercased()) {
                    let p = dir + "/" + f
                    if !out.contains(p) { out.append(p) }
                }
            }
            return true
        }
        return out
    }

    /// Checks the folder really is a numbered, uniform, camera-less image sequence.
    public static func inspect(_ dir: String) -> Sequence? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "tif", "tiff", "exr", "dpx", "bmp", "tga"]
        struct Key: Hashable { var prefix: String; var width: Int; var ext: String }
        var groups: [Key: [Int]] = [:]
        var images = 0
        for n in names {
            let ext = (n as NSString).pathExtension.lowercased()
            guard imageExts.contains(ext) else { continue }
            images += 1
            let stem = (n as NSString).deletingPathExtension
            let digits = stem.reversed().prefix(while: \.isASCII).prefix(while: \.isNumber)
            guard digits.count >= 3, let v = Int(String(digits.reversed())) else { continue }
            let prefix = String(stem.dropLast(digits.count))
            groups[Key(prefix: prefix, width: digits.count, ext: ext), default: []].append(v)
        }
        guard let (key, nums) = groups.max(by: { $0.value.count < $1.value.count }),
              nums.count >= 300, Double(nums.count) >= 0.9 * Double(images) else { return nil }
        // Zero-padded and (almost) consecutive.
        let lo = nums.min()!, hi = nums.max()!
        let gaps = (hi - lo + 1) - nums.count
        guard Double(gaps) <= 0.05 * Double(nums.count) else { return nil }
        let sorted = nums.sorted()
        let sample = [sorted.first!, sorted[sorted.count / 2], sorted.last!]
        var dims: (Int, Int)?
        for v in sample {
            let name = key.prefix + String(format: "%0\(key.width)d", v) + "." + key.ext
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
            // Camera photos (bursts, timelapse originals) carry a maker / capture date.
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any], tiff[kCGImagePropertyTIFFMake] != nil { return nil }
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any], exif[kCGImagePropertyExifDateTimeOriginal] != nil { return nil }
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            if let d = dims, d != (w, h) { return nil }
            dims = (w, h)
        }
        let newest = (try? FileManager.default.attributesOfItem(atPath: dir))?[.modificationDate] as? Date
        return Sequence(path: dir, count: nums.count, ext: key.ext, width: dims?.0 ?? 0, height: dims?.1 ?? 0, newest: newest)
    }

    /// Looks for the final video from the frames folder upwards, nearest folder first,
    /// so chapter 20's frames match chapter 20's video and not chapter 19's. Going up,
    /// folders holding other frames (`holders`, minus this folder and its parents) are
    /// passed over: chapter 19's video belongs to chapter 19's frames, even when
    /// chapter 20's own video is gone.
    static func nearestFinal(_ tree: ScanTree, frames: NodeID, _ seq: Sequence, stopAt: NodeID,
                             holders: Set<NodeID> = [], cache: inout [String: Double?]) async -> String? {
        var own: Set<NodeID> = [frames]
        var up = frames
        while let p = tree.parent(up), p != ScanTree.root { own.insert(p); up = p }
        let skip = holders.subtracting(own)
        var cur = frames
        var tried: Set<String> = []
        for _ in 0..<6 {
            guard let p = tree.parent(cur), p != ScanTree.root else { break }
            cur = p
            let vids = videos(tree, under: cur, skip: skip).filter { !tried.contains($0) }
            tried.formUnion(vids)
            if let m = await bestMatch(seq, finals: vids, cache: &cache) { return m }
            if cur == stopAt { break }
        }
        return nil
    }

    /// The video newer than the frames whose frame count is closest to theirs. A render's
    /// own video has the same count, give or take a frame; a 3% window let unrelated videos
    /// of about the same length match. On a tie (a voice-only and a mixed version of the
    /// same render), the newest, usually the final mix.
    static func bestMatch(_ seq: Sequence, finals: [String], cache: inout [String: Double?]) async -> String? {
        var best: (path: String, err: Double, date: Date)?
        for v in finals {
            let m = (try? FileManager.default.attributesOfItem(atPath: v))?[.modificationDate] as? Date ?? .distantPast
            if let newest = seq.newest, m < newest.addingTimeInterval(-300) { continue }
            let expected: Double?
            if let c = cache[v] { expected = c } else {
                expected = await frameCount(v)
                cache[v] = expected
            }
            guard let expected, expected > 0 else { continue }
            let err = abs(Double(seq.count) - expected.rounded())   // whole frames, so ties are exact
            guard err <= max(3, 0.005 * expected) else { continue }
            if let b = best, err > b.err || (err == b.err && m <= b.date) { continue }
            best = (v, err, m)
        }
        return best?.path
    }

    /// Frames in the video track: its own duration, not the file's, which a longer
    /// audio track can stretch.
    static func frameCount(_ path: String) async -> Double? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fps = try? await track.load(.nominalFrameRate), fps > 0 else { return nil }
        var seconds = (try? await track.load(.timeRange))?.duration.seconds ?? 0
        if !(seconds > 0) { seconds = (try? await asset.load(.duration))?.seconds ?? 0 }
        return seconds > 0 ? seconds * Double(fps) : nil
    }
}
