import AppKit
import DiskIndex
import Foundation
import Observation
import Recognizers

/// One external disk with its own index and findings. It is not followed live: it is
/// scanned when it shows up (plugged in, or present at launch), on Rescan, and after
/// Clean Up. What the last scan found is shown meanwhile.
@MainActor @Observable
final class ExternalDisk: Identifiable {
    /// The volume UUID.
    let id: String
    var volume: ExternalVolume
    var tree: ScanTree?
    var report: Report?
    /// Only `.idle`, `.scanning` and `.recognizing` are used.
    var phase: Phase = .idle
    /// Bumped whenever `tree` is replaced.
    var treeRevision = 0
    /// Stops the running scan when the disk is about to be ejected, so it isn't "in use".
    @ObservationIgnored var cancelScan: ScanCancellation?

    init(_ volume: ExternalVolume) {
        id = volume.uuid
        self.volume = volume
    }

    var things: [Thing] { report?.things ?? [] }
    var isBusy: Bool { phase != .idle }
    var reclaimable: UInt64 { things.reduce(0) { $0 + $1.reclaimable } }
    func occupied(_ kind: ThingKind) -> UInt64 { things.filter { $0.kind == kind }.reduce(0) { $0 + $1.bytes } }

    var indexURL: URL { AppPaths.indexURL(volumeUUID: id) }
    var reportURL: URL { ReportStore.reportURL(volume: id) }

    /// Removes cleaned items from the findings.
    func drop(_ ids: Set<String>, save: Bool) {
        guard var r = report else { return }
        for t in r.things.indices { r.things[t].items.removeAll { ids.contains($0.id) } }
        r.things.removeAll { $0.items.isEmpty }
        report = r
        guard save else { return }
        let url = reportURL
        Task.detached(priority: .utility) { ReportStore.save(r, to: url) }
    }
}

extension AppModel {
    /// Follows disks being plugged in and out. Listing volumes reads no folder contents.
    func watchExternalDisks() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshExternals() }
            }
        }
        nc.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            MainActor.assumeIsolated {
                for d in self?.externals ?? [] where d.volume.path == path { d.cancelScan?.cancel() }
            }
        }
        refreshExternals()
    }

    func refreshExternals() {
        let mounted = ExternalVolumes.list()
        let ids = Set(mounted.map(\.uuid))
        if case .disk(let id) = page, !ids.contains(id) { page = .section(.overview) }
        externals.removeAll { !ids.contains($0.id) }
        for v in mounted {
            if let d = externals.first(where: { $0.id == v.uuid }) {
                let renamed = d.volume.path != v.path
                d.volume = v
                // Renamed: every saved path points at the old mount point.
                if renamed, Privacy.hasFullDiskAccess { Task { await scan(d) } }
                continue
            }
            let d = ExternalDisk(v)
            externals.append(d)
            Task { await load(d) }
        }
        externals.sort { $0.volume.name.localizedStandardCompare($1.volume.name) == .orderedAscending }
        resetSelection()
    }

    /// Shows what the last scan found right away, then scans again. Without Full Disk
    /// Access macOS would ask before the disk is read, so that waits for the user.
    private func load(_ d: ExternalDisk) async {
        let indexURL = d.indexURL, reportURL = d.reportURL
        let (tree, report) = await Task.detached(priority: .utility) {
            (ReportStore.loadIndex(from: indexURL), ReportStore.load(from: reportURL))
        }.value
        if d.tree == nil, d.report == nil {
            d.tree = tree
            d.report = report
            d.treeRevision += 1
            resetSelection()
        }
        if Privacy.hasFullDiskAccess { await scan(d) }
    }

    /// Scans an external disk and recognizes what is on it. `interactive`: the user asked, so full speed.
    func scan(_ d: ExternalDisk, interactive: Bool = false) async {
        guard demo == nil, !d.isBusy, externals.contains(where: { $0 === d }) else { return }
        d.phase = .scanning(files: 0, bytes: 0)
        let progress = ProgressRelay()
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                if case .scanning = d.phase, let p = progress.value { d.phase = .scanning(files: p.files, bytes: p.bytes) }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        let path = d.volume.path
        let stop = ScanCancellation()
        d.cancelScan = stop
        let tree = await Task.detached(priority: interactive ? .userInitiated : .utility) {
            var o = ScanOptions()
            o.background = !interactive
            return ScanTree.scan(roots: [path], options: o, cancellation: stop) { progress.value = $0 }
        }.value
        poll.cancel()
        d.cancelScan = nil
        // Ejected or unplugged meanwhile: what was read is incomplete.
        guard let tree, externals.contains(where: { $0 === d }) else { d.phase = .idle; return }
        let indexURL = d.indexURL, reportURL = d.reportURL, volume = d.volume
        await Task.detached(priority: .utility) { try? ReportStore.saveIndex(tree, to: indexURL) }.value
        d.tree = tree
        d.treeRevision += 1
        d.phase = .recognizing(L("正在识别项目和渲染帧…", "Recognizing projects and render frames…"))
        let report = await Recognize.external(tree: tree, volume: volume)
        await Task.detached(priority: .utility) { ReportStore.save(report, to: reportURL) }.value
        if let v = ExternalVolumes.list().first(where: { $0.uuid == d.id }) { d.volume = v }
        d.report = report
        resetSelection()
        d.phase = .idle
    }
}
