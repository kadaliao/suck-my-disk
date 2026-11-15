import AppKit
import DiskIndex
import QuickLookThumbnailing
import SwiftUI

/// A file's cover, or `symbol` until it is ready and for files that have none.
struct FileThumbnail: View {
    var path: String?
    var side: CGFloat
    var symbol: String
    var tint: Color
    @Environment(\.displayScale) private var scale
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.5))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: side, height: side)
        .task(id: path) {
            image = nil
            guard let path else { return }
            image = await Thumbnails.image(path, side: side, scale: scale)
        }
    }
}

/// Covers as Quick Look draws them: a video's frame, a PDF's first page, a photo. Making one
/// reads the file, so it happens only for a file on screen, is kept in memory only, and never
/// in demo or snapshot runs, for a file iCloud hasn't downloaded, or in folders macOS asks
/// about before an app reads them.
@MainActor
enum Thumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()
    /// Files Quick Look had no cover for: not asked again.
    private static var none: Set<String> = []
    /// An open list asks for dozens at once; a few at a time keeps the disk and Quick Look responsive.
    private static let limit = 3
    private static var running = 0
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    static func image(_ path: String, side: CGFloat, scale: CGFloat) async -> NSImage? {
        guard let modified = readable(path) else { return nil }
        let key = "\(Int(side * scale))|\(modified)|\(path)"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard !none.contains(key) else { return nil }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: side, height: side),
                                                   scale: scale, representationTypes: .thumbnail)
        let rep = await withTaskCancellationHandler {
            try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
        guard let image = rep?.nsImage else {
            if !Task.isCancelled { none.insert(key) }
            return nil
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// When a cover may be made: the file's modification time (a changed file gets a new one).
    private static func readable(_ path: String) -> Int? {
        // Demo and snapshot runs set it: their paths are made up, or must not be read.
        guard !Privacy.alwaysSkip, !Privacy.isInside(Firmlinks.dataPath(path), Privacy.rootsToSkip()) else { return nil }
        var st = stat()
        // Only a regular file that is on this Mac: Quick Look would download an iCloud placeholder.
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        return st.st_mtimespec.tv_sec
    }

    private static func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the slot straight to the next one waiting.
    private static func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}
