import Foundation
import Testing
@testable import DiskIndex
@testable import Update

@Suite struct UpdateTests {
    @Test func versionsCompareByNumber() throws {
        let v = { (s: String) in try #require(AppVersion(s)) }
        #expect(try v("v0.4.1") == v("0.4.1"))
        #expect(try v("0.5") == v("0.5.0"))
        #expect(try v("0.4.10") > v("0.4.9"))
        #expect(try v("1.0.0") > v("0.99.99"))
        #expect(try v("0.5.0") > v("0.4.1"))
        #expect(try v("v0.4.1").description == "0.4.1")
        for bad in ["", "v", "0.5.0-beta", "0..1", "1.x", "-1.0", "0.5 "] { #expect(AppVersion(bad) == nil, "\(bad)") }
    }

    static func release(tag: String = "v0.5.0", prerelease: Bool = false, assets: [String]) -> Data {
        let list = assets.map {
            #"{"name":"\#($0)","size":10,"browser_download_url":"https://github.com/kadaliao/suck-my-disk/releases/download/\#(tag)/\#($0)"}"#
        }
        return Data(#"""
            {"tag_name":"\#(tag)","name":"SuckMyDisk","draft":false,"prerelease":\#(prerelease),
             "published_at":"2026-11-08T10:00:00Z","html_url":"https://github.com/kadaliao/suck-my-disk/releases/tag/\#(tag)",
             "body":"notes","assets":[\#(list.joined(separator: ","))]}
            """#.utf8)
    }

    @Test func picksTheAppArchiveAndChecksums() throws {
        let r = try Updates.parse(Self.release(assets: ["SHA256SUMS", "smd-0.5.0-macos.zip", "SuckMyDisk-0.5.0.dmg", "SuckMyDisk-0.5.0.zip"]))
        #expect(r.version == AppVersion("0.5.0")!)
        #expect(r.archiveName == "SuckMyDisk-0.5.0.zip")
        #expect(r.archive.lastPathComponent == "SuckMyDisk-0.5.0.zip")
        #expect(r.checksums.lastPathComponent == "SHA256SUMS")
        #expect(r.published != nil)
    }

    @Test func refusesReleasesItCantInstall() {
        #expect(throws: UpdateError.missingAsset("SuckMyDisk-0.5.0.zip")) {
            try Updates.parse(Self.release(assets: ["SHA256SUMS", "SuckMyDisk-0.5.0.dmg"]))
        }
        #expect(throws: UpdateError.missingAsset("SHA256SUMS")) {
            try Updates.parse(Self.release(assets: ["SuckMyDisk-0.5.0.zip"]))
        }
        #expect(throws: UpdateError.noRelease) {
            try Updates.parse(Self.release(prerelease: true, assets: ["SHA256SUMS", "SuckMyDisk-0.5.0.zip"]))
        }
        #expect(throws: UpdateError.noRelease) {
            try Updates.parse(Self.release(tag: "v0.6.0-beta.1", assets: ["SHA256SUMS", "SuckMyDisk-0.6.0-beta.1.zip"]))
        }
    }

    @Test func takesLinksFromGitHubOnly() {
        var json = String(decoding: Self.release(assets: ["SHA256SUMS", "SuckMyDisk-0.5.0.zip"]), as: UTF8.self)
        json = json.replacingOccurrences(of: #""html_url":"https://github.com"#, with: #""html_url":"http://example.com"#)
        #expect(throws: UpdateError.noRelease) { try Updates.parse(Data(json.utf8)) }
    }

    @Test func neverInstallsOverTheSameOrANewerCopy() throws {
        let fx = try Fixture()
        let installed = URL(fileURLWithPath: fx.path("Applications/SuckMyDisk.app"))
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleShortVersionString": "0.6.0"]
        info.write(to: installed.appendingPathComponent("Contents/Info.plist"), atomically: true)
        let archive = URL(fileURLWithPath: fx.path("SuckMyDisk-0.5.1.zip"))
        #expect { try Updates.install(archive, version: AppVersion("0.5.1")!, over: installed) } throws: { e in
            if case .cannotReplace = e as? UpdateError { return true } else { return false }
        }
        #expect(Updates.installedVersion(installed) == AppVersion("0.6.0")!)
    }

    @Test func refusesAnArchiveHoldingALinkInsteadOfAnApp() throws {
        let fx = try Fixture()
        let real = try adHocApp(in: fx, version: "0.5.0")
        let pack = URL(fileURLWithPath: fx.path("pack"))
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent("SuckMyDisk.app"), withDestinationURL: real)
        let zip = fx.path("SuckMyDisk-0.5.0.zip")
        #expect(Shell.run(["/usr/bin/ditto", "-c", "-k", pack.path, zip]).ok)
        let installed = URL(fileURLWithPath: fx.path("Applications/SuckMyDisk.app"))
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        #expect(throws: UpdateError.wrongApp("SuckMyDisk.app")) {
            try Updates.unpack(URL(fileURLWithPath: zip), version: AppVersion("0.5.0")!, near: installed)
        }
    }

    @Test func readsChecksumsFile() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "B", count: 64)
        let sums = "\(a)  SuckMyDisk-0.5.0.dmg\n\(b)  SuckMyDisk-0.5.0.zip\n"
        #expect(Updates.checksum(in: sums, for: "SuckMyDisk-0.5.0.zip") == b.lowercased())
        #expect(Updates.checksum(in: sums, for: "SuckMyDisk-0.5.zip") == nil)
        #expect(Updates.checksum(in: "short  SuckMyDisk-0.5.0.zip", for: "SuckMyDisk-0.5.0.zip") == nil)
    }

    /// A minimal app bundle, ad-hoc signed: valid code, but not ours.
    func adHocApp(in fx: Fixture, version: String) throws -> URL {
        let app = URL(fileURLWithPath: fx.path("SuckMyDisk.app"))
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": Updates.bundleID, "CFBundleShortVersionString": version,
                                  "CFBundleExecutable": "SuckMyDisk", "CFBundlePackageType": "APPL"]
        info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macos.appendingPathComponent("SuckMyDisk").path)
        let r = Shell.run(["/usr/bin/codesign", "--force", "--sign", "-", app.path])
        #expect(r.ok, "\(r.stderr)")
        return app
    }

    @Test func refusesAppsNotSignedWithTheProjectsDeveloperID() throws {
        let fx = try Fixture()
        let app = try adHocApp(in: fx, version: "0.5.0")
        #expect(Shell.run(["/usr/bin/codesign", "--verify", "--strict", app.path]).ok)
        #expect { try Updates.verify(app, version: AppVersion("0.5.0")!) } throws: { e in
            if case .signature = e as? UpdateError { return true } else { return false }
        }
    }

    @Test func swapTradesPlacesAndDropsTheOldCopy() throws {
        let fx = try Fixture()
        let installed = URL(fileURLWithPath: try fx.file("Applications/SuckMyDisk.app/Contents/old", text: "old"))
            .deletingLastPathComponent().deletingLastPathComponent()
        let staged = URL(fileURLWithPath: try fx.file("stage/SuckMyDisk.app/Contents/new", text: "new"))
            .deletingLastPathComponent().deletingLastPathComponent()
        #expect(Updates.blocker(for: installed) == nil)
        try Updates.swap(staged, into: installed)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: installed.appendingPathComponent("Contents/new").path))
        #expect(!fm.fileExists(atPath: installed.appendingPathComponent("Contents/old").path))
        #expect(!fm.fileExists(atPath: staged.path))
        #expect(throws: UpdateError.self) { try Updates.swap(staged, into: installed) }
    }

    @Test func knowsWhereItCantReplaceItself() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1234/d/SuckMyDisk.app")
        #expect(Updates.blocker(for: translocated) != nil)
        #expect(Updates.blocker(for: URL(fileURLWithPath: "/System/Applications/Calculator.app")) != nil)
    }

    @Test func prunesOldDownloads() throws {
        let fx = try Fixture()
        for n in ["SuckMyDisk-0.4.1.zip", "SuckMyDisk-0.5.0.zip", "SuckMyDisk-0.5.1.zip", "partial.tmp"] { try fx.file("u/" + n, text: "x") }
        Updates.pruneDownloads(in: URL(fileURLWithPath: fx.path("u")), keepingNewerThan: AppVersion("0.5.0")!)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fx.path("u")) == ["SuckMyDisk-0.5.1.zip"])
    }

    @Test func relaunchHelperRunsInItsOwnSession() throws {
        let fx = try Fixture()
        let out = fx.path("pgid")
        _ = try Updates.spawnDetached(["/bin/sh", "-c", #"echo "$$ $(ps -o pgid= -p $$)" > "$1""#, "sh", out])
        var text = ""
        for _ in 0..<100 where text.isEmpty {
            Thread.sleep(forTimeInterval: 0.05)
            text = (try? String(contentsOfFile: out, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let ids = text.split(separator: " ").compactMap { Int32($0) }
        #expect(ids.count == 2, "\(text)")
        #expect(ids.first == ids.last, "the helper leads its own process group")
        #expect(ids.last != getpgrp())
    }
}
