import CoreServices
import DiskIndex
import Foundation

public struct ActivitySignal: Sendable, Codable {
    public var date: Date
    public var source: String
    public init(date: Date, source: String) {
        self.date = date
        self.source = source
    }
}

/// "When did I last work on this?" from sources that are more honest than mtime:
/// coding-agent sessions, shell history, git metadata and Spotlight.
public final class ActivityIndex: @unchecked Sendable {
    private var agentDirs: [(key: String, date: Date, source: String)] = []
    private var pathHits: [(path: String, date: Date, source: String)] = []
    private let home = NSHomeDirectory()

    public init(now: Date = Date()) {
        loadAgentDir(home + "/.claude/projects", source: "Claude Code")
        loadAgentDir(home + "/.pi/agent/sessions", source: "pi")
        loadCodex(home + "/.codex/sessions", since: now.addingTimeInterval(-400 * 86400))
        loadFish(home + "/.local/share/fish/fish_history")
        loadZsh(home + "/.zsh_history")
        pathHits.sort { $0.path < $1.path }
    }

    /// Claude Code style: every character outside [A-Za-z0-9-] becomes "-".
    public static func encode(_ path: String) -> String {
        String(path.map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber)) || c == "-" ? c : "-"
        })
    }

    private static func trimDashes(_ s: String) -> Substring {
        var t = Substring(s)
        while t.first == "-" { t = t.dropFirst() }
        while t.last == "-" { t = t.dropLast() }
        return t
    }

    private func loadAgentDir(_ dir: String, source: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for n in names {
            let p = dir + "/" + n
            guard let d = Self.newestFileDate(in: p) else { continue }
            agentDirs.append((String(Self.trimDashes(n)), d, source))
        }
    }

    static func newestFileDate(in dir: String) -> Date? {
        let fm = FileManager.default
        var newest: Date?
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        for i in items {
            let a = try? fm.attributesOfItem(atPath: dir + "/" + i)
            if let m = a?[.modificationDate] as? Date, newest.map({ m > $0 }) ?? true { newest = m }
        }
        return newest
    }

    private func loadCodex(_ dir: String, since: Date) {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: dir) else { return }
        while let rel = e.nextObject() as? String {
            guard rel.hasSuffix(".jsonl") || rel.hasSuffix(".json") else { continue }
            let p = dir + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  let m = attrs[.modificationDate] as? Date, m >= since,
                  let fh = FileHandle(forReadingAtPath: p) else { continue }
            let head = fh.readData(ofLength: 8192)
            try? fh.close()
            let s = String(decoding: head, as: UTF8.self)
            guard let r = s.range(of: "\"cwd\":\"") else { continue }
            let rest = s[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            pathHits.append((String(rest[..<end]), m, "Codex"))
        }
    }

    private func loadFish(_ path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var when: Date?
        var cmd: String?
        var inPaths = false
        func flushCd() {
            guard let cmd, let when, cmd.hasPrefix("cd ") else { return }
            let target = String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if target.hasPrefix("/") || target.hasPrefix("~") {
                pathHits.append((expand(target), when, "shell"))
            }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("- cmd: ") {
                flushCd()
                cmd = String(line.dropFirst(7))
                when = nil
                inPaths = false
            } else if line.hasPrefix("  when: ") {
                if let t = TimeInterval(line.dropFirst(8)) { when = Date(timeIntervalSince1970: t) }
            } else if line.hasPrefix("  paths:") {
                inPaths = true
            } else if inPaths, line.hasPrefix("    - "), let when {
                let p = expand(String(line.dropFirst(6)))
                if p.hasPrefix("/") { pathHits.append((p, when, "shell")) }
            }
        }
        flushCd()
    }

    private func loadZsh(_ path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") where line.hasPrefix(": ") {
            // ": 1700000000:0;cd ~/workspace/foo"
            let parts = line.dropFirst(2).split(separator: ";", maxSplits: 1)
            guard parts.count == 2, let ts = TimeInterval(parts[0].split(separator: ":").first ?? "") else { continue }
            let cmd = parts[1]
            guard cmd.hasPrefix("cd ") else { continue }
            let target = expand(String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            if target.hasPrefix("/") { pathHits.append((target, Date(timeIntervalSince1970: ts), "shell")) }
        }
    }

    private func expand(_ p: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + p.dropFirst(1) }
        return p
    }

    /// Latest activity for a project directory. Among agent dirs the longest
    /// matching project wins, so "dmwc-fine" sessions don't count for "dmwc".
    public func lastActivity(forProject project: String, allProjects: Set<String>) -> ActivitySignal? {
        var best: ActivitySignal?
        func take(_ d: Date, _ s: String) {
            if best == nil || d > best!.date { best = ActivitySignal(date: d, source: s) }
        }
        let enc = String(Self.trimDashes(Self.encode(project)))
        for a in agentDirs where a.key == enc || a.key.hasPrefix(enc + "-") {
            if a.key != enc, let owner = longestProject(forAgentKey: a.key, among: allProjects), owner != project { continue }
            take(a.date, a.source)
        }
        let prefix = project + "/"
        // pathHits is sorted by path; scan the range that starts with the project.
        var lo = 0, hi = pathHits.count
        while lo < hi { let mid = (lo + hi) / 2; if pathHits[mid].path < project { lo = mid + 1 } else { hi = mid } }
        var i = lo
        while i < pathHits.count, pathHits[i].path == project || pathHits[i].path.hasPrefix(prefix) {
            take(pathHits[i].date, pathHits[i].source)
            i += 1
        }
        if let d = Self.spotlightLastUsed(project) { take(d, "Finder") }
        return best
    }

    private var keyCache: [String: String] = [:]
    private func longestProject(forAgentKey key: String, among projects: Set<String>) -> String? {
        if keyCache.isEmpty {
            for p in projects { keyCache[String(Self.trimDashes(Self.encode(p)))] = p }
        }
        var k = Substring(key)
        while !k.isEmpty {
            if let p = keyCache[String(k)] { return p }
            guard let dash = k.lastIndex(of: "-") else { break }
            k = k[..<dash]
        }
        return nil
    }

    public static func spotlightLastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
