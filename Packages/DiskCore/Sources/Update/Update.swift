import CryptoKit
import DiskIndex
import Foundation
import Security

/// A version like 0.4.1. A leading "v" is allowed (tags); anything else, betas included, isn't a version.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let t = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        var parts: [Int] = []
        for p in t.split(separator: ".", omittingEmptySubsequences: false) {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            parts.append(n)
        }
        guard !parts.isEmpty else { return nil }
        self.parts = parts
    }

    /// 0.5 and 0.5.0 are the same version.
    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// The newest release on GitHub, with the two files an update needs.
public struct Release: Sendable, Equatable {
    public var version: AppVersion
    /// The release's GitHub page, for its notes.
    public var page: URL
    public var published: Date?
    /// `SuckMyDisk-<version>.zip`: the stapled app.
    public var archive: URL
    public var archiveName: String
    /// `SHA256SUMS`.
    public var checksums: URL
}

public enum UpdateError: LocalizedError, Equatable {
    case http(Int)
    case noRelease
    case missingAsset(String)
    case checksum
    case unpack(String)
    case signature(String)
    case wrongApp(String)
    case cannotReplace(String)

    public var errorDescription: String? {
        switch self {
        case .http(403), .http(429):
            return L("GitHub 暂时拒绝了请求（访问太频繁），稍后再试。", "GitHub turned the request down for now (too many requests). Try again later.")
        case .http(let code):
            return L("GitHub 返回了 HTTP \(code)。", "GitHub answered with HTTP \(code).")
        case .noRelease:
            return L("GitHub 上没有可用的正式版本。", "GitHub has no usable release.")
        case .missingAsset(let name):
            return L("这个版本缺少 \(name)，没法自动更新。", "The release has no \(name), so it can't be installed automatically.")
        case .checksum:
            return L("下载的文件和 SHA256SUMS 对不上，已丢弃。", "The download doesn't match SHA256SUMS and was thrown away.")
        case .unpack(let m):
            return L("解压失败：\(m)", "Couldn't unpack the update: \(m)")
        case .signature(let m):
            return L("新版本的签名校验没通过，没有安装：\(m)", "The new version failed the signature check and wasn't installed: \(m)")
        case .wrongApp(let m):
            return L("下载到的不是预期的 SuckMyDisk 版本：\(m)", "The download isn't the expected SuckMyDisk version: \(m)")
        case .cannotReplace(let m):
            return m
        }
    }
}

public enum Updates {
    public static let repository = "kadaliao/suck-my-disk"
    public static let bundleID = "com.kadaliao.SuckMyDisk"
    static let developerID = """
        identifier "com.kadaliao.SuckMyDisk" and anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] \
        and certificate leaf[subject.OU] = "HMDAVG9B8J"
        """
    /// What a new version must satisfy: this app, signed with the project's Developer ID, notarized by Apple.
    public static let requirement = developerID + " and notarized"

    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    static let latestAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    // MARK: finding

    /// The newest published release (GitHub's "latest" skips drafts and pre-releases).
    public static func latest(userAgent: String, session: URLSession = .shared) async throws -> Release {
        var req = URLRequest(url: latestAPI, timeoutInterval: 30)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        try check(response)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        struct Body: Decodable {
            let tag_name: String
            let html_url: URL
            let published_at: Date?
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let b = try decoder.decode(Body.self, from: data)
        guard b.draft != true, b.prerelease != true, let version = AppVersion(b.tag_name) else { throw UpdateError.noRelease }
        let plain = b.tag_name.hasPrefix("v") ? String(b.tag_name.dropFirst()) : b.tag_name
        let name = "SuckMyDisk-\(plain).zip"
        guard let zip = b.assets.first(where: { $0.name == name }) else { throw UpdateError.missingAsset(name) }
        guard let sums = b.assets.first(where: { $0.name == "SHA256SUMS" }) else { throw UpdateError.missingAsset("SHA256SUMS") }
        // The page is opened in the browser and the files are downloaded: GitHub over HTTPS only.
        let onGitHub = { (u: URL) in u.scheme == "https" && u.host == "github.com" }
        guard onGitHub(b.html_url), onGitHub(zip.browser_download_url), onGitHub(sums.browser_download_url) else {
            throw UpdateError.noRelease
        }
        return Release(version: version, page: b.html_url, published: b.published_at,
                       archive: zip.browser_download_url, archiveName: name, checksums: sums.browser_download_url)
    }

    // MARK: downloading

    /// Downloads the release's app archive into `dir` and checks it against SHA256SUMS.
    /// A good copy already there is reused.
    public static func download(_ r: Release, to dir: URL, userAgent: String, session: URLSession = .shared) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var req = URLRequest(url: r.checksums, timeoutInterval: 60)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (sums, response) = try await session.data(for: req)
        try check(response)
        guard let expected = checksum(in: String(decoding: sums, as: UTF8.self), for: r.archiveName) else {
            throw UpdateError.missingAsset("SHA256SUMS: \(r.archiveName)")
        }
        let dest = dir.appendingPathComponent(r.archiveName)
        if fm.fileExists(atPath: dest.path), (try? sha256(dest)) == expected { return dest }

        req.url = r.archive
        let (tmp, archiveResponse) = try await session.download(for: req)
        defer { try? fm.removeItem(at: tmp) }
        try check(archiveResponse)
        guard try sha256(tmp) == expected else { throw UpdateError.checksum }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }

    /// The hash SHA256SUMS lists for `name` (lines are "<hash>  <name>").
    static func checksum(in sums: String, for name: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.count == 2, f[1] == name || f[1] == "*" + name, f[0].count == 64 { return f[0].lowercased() }
        }
        return nil
    }

    static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func check(_ response: URLResponse) throws {
        if let h = response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw UpdateError.http(h.statusCode) }
    }

    // MARK: checking

    /// Unpacks the archive on the same volume as `installed` (so installing is one rename)
    /// and checks the app inside. The caller deletes the returned app's folder when done.
    public static func unpack(_ archive: URL, version: AppVersion, near installed: URL) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
        do {
            let r = Shell.run(["/usr/bin/ditto", "-x", "-k", archive.path, dir.path], timeout: 120)
            guard r.ok else { throw UpdateError.unpack(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let apps = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".app") }
            guard apps.count == 1 else { throw UpdateError.wrongApp(L("压缩包里有 \(apps.count) 个 app", "the archive holds \(apps.count) apps")) }
            let app = dir.appendingPathComponent(apps[0])
            let kind = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard kind.isDirectory == true, kind.isSymbolicLink != true else { throw UpdateError.wrongApp(apps[0]) }
            try verify(app, version: version)
            return app
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// The app must be SuckMyDisk at exactly `version`, signed with the project's Developer ID,
    /// notarized, and unmodified (every file, every architecture, nested code included).
    public static func verify(_ app: URL, version: AppVersion) throws {
        try checkSignature(app, requirement: requirement)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.wrongApp("Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError.wrongApp(info["CFBundleIdentifier"] as? String ?? "?")
        }
        let found = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        guard let found, found == version else {
            throw UpdateError.wrongApp(L("版本是 \(found?.description ?? "?")，应为 \(version)", "version \(found?.description ?? "?"), expected \(version)"))
        }
    }

    static func checkSignature(_ app: URL, requirement text: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.signature(L("读不出签名", "no readable signature"))
        }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else {
            throw UpdateError.signature("requirement")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, req, &error)
        guard status == errSecSuccess else {
            _ = error?.takeRetainedValue()
            let why = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            throw UpdateError.signature(why)
        }
    }

    /// True when this process is a release build: signed with the project's Developer ID.
    /// Xcode builds aren't, and never replace themselves.
    public static var isReleaseBuild: Bool {
        var me: SecCode?
        var req: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecRequirementCreateWithString(developerID as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(me, [], req) == errSecSuccess
    }

    // MARK: installing

    /// Why the app at `installed` can't replace itself, or nil when it can.
    public static func blocker(for installed: URL) -> String? {
        let path = installed.path
        let readOnly = (try? installed.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        if path.contains("/AppTranslocation/") || readOnly {
            return L("SuckMyDisk 正从磁盘映像或隔离位置运行。先把它拖进「应用程序」文件夹，之后它就能自己更新。",
                     "SuckMyDisk is running from a disk image or a quarantined location. Move it into Applications; from there it can update itself.")
        }
        let parent = installed.deletingLastPathComponent().path
        if access(parent, W_OK) != 0 || access(path, W_OK) != 0 {
            return L("没有权限替换 \(path)。请从 GitHub 下载新版本手动安装。",
                     "No permission to replace \(path). Download the new version from GitHub instead.")
        }
        return nil
    }

    /// Puts `new` where `installed` is: the two folders trade places in one rename, so a complete app
    /// is there at every moment. The old version, now at `new`'s path, is deleted.
    public static func swap(_ new: URL, into installed: URL) throws {
        guard renamex_np(new.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            let why = String(cString: strerror(errno))
            throw UpdateError.cannotReplace(L("替换 \(installed.path) 失败：\(why)", "Couldn't replace \(installed.path): \(why)"))
        }
        try? FileManager.default.removeItem(at: new)
    }

    /// Unpacks, checks and installs the archive over `installed`.
    public static func install(_ archive: URL, version: AppVersion, over installed: URL) throws {
        if let why = blocker(for: installed) { throw UpdateError.cannotReplace(why) }
        // Someone may have put a newer copy there by hand since this one was downloaded.
        if let onDisk = installedVersion(installed), version <= onDisk {
            throw UpdateError.cannotReplace(L("\(installed.path) 已经是 \(onDisk) 版。", "\(installed.path) is already version \(onDisk)."))
        }
        let app = try unpack(archive, version: version, near: installed)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try swap(app, into: installed)
    }

    static func installedVersion(_ app: URL) -> AppVersion? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    /// Opens `app` once this process has exited. The waiting shell runs in its own session,
    /// so it outlives the app's launchd job.
    public static func relaunch(_ app: URL, arguments: [String] = []) throws {
        let script = #"pid=$1; app=$2; shift 2; i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done; exec /usr/bin/open -a "$app" "$@""#
        var argv = ["/bin/sh", "-c", script, "sh", String(getpid()), app.path]
        if !arguments.isEmpty { argv += ["--args"] + arguments }
        _ = try spawnDetached(argv)
    }

    /// Starts `argv` in a new session with stdio on /dev/null and no other inherited descriptors.
    static func spawnDetached(_ argv: [String]) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        posix_spawn_file_actions_addopen(&files, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&files, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&files, 2, "/dev/null", O_WRONLY, 0)
        let cargs = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &files, &attr, cargs, environ)
        guard rc == 0 else {
            throw UpdateError.cannotReplace(L("没能重新打开：\(String(cString: strerror(rc)))", "Couldn't relaunch: \(String(cString: strerror(rc)))"))
        }
        return pid
    }

    // MARK: housekeeping

    /// Deletes downloaded archives that aren't newer than `current`.
    public static func pruneDownloads(in dir: URL, keepingNewerThan current: AppVersion) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            let v = name.hasPrefix("SuckMyDisk-") && name.hasSuffix(".zip")
                ? AppVersion(String(name.dropFirst("SuckMyDisk-".count).dropLast(".zip".count))) : nil
            if v.map({ $0 <= current }) ?? true { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        }
    }
}
