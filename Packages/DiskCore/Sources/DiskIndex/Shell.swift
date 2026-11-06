import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var ok: Bool { status == 0 }
}

public enum Shell {
    /// PATH plus the usual Homebrew / user locations, without duplicates.
    static var searchDirs: [String] {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin",
                     "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return (env.split(separator: ":").map(String.init) + extra).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Finds an executable on PATH plus the usual Homebrew / user locations.
    public static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in searchDirs {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// PATH for a child process. An app opened from Finder only has /usr/bin:/bin:…,
    /// so a script such as npm (`#!/usr/bin/env node`) could not find its interpreter.
    /// The tool's own folder goes first: that is where its node, python… usually live.
    static func childPATH(for exe: String) -> String {
        let own = (exe as NSString).deletingLastPathComponent
        return ([own] + searchDirs.filter { $0 != own }).joined(separator: ":")
    }

    /// Runs a command and captures output. Kills it after `timeout` seconds.
    /// `env` adds to (or overrides) the inherited environment.
    @discardableResult
    public static func run(_ argv: [String], cwd: String? = nil, timeout: TimeInterval = 60,
                           stream: Bool = false, env extra: [String: String] = [:]) -> ShellResult {
        guard let exe = which(argv[0]) else {
            return ShellResult(status: 127, stdout: "", stderr: "\(argv[0]): not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = childPATH(for: exe)
        env.merge(extra) { _, new in new }
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let outBuf = Buffer(), errBuf = Buffer()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            outBuf.append(d)
            if stream, !d.isEmpty { FileHandle.standardError.write(d) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            errBuf.append(d)
            if stream, !d.isEmpty { FileHandle.standardError.write(d) }
        }
        do { try p.run() } catch {
            return ShellResult(status: 126, stdout: "", stderr: "\(error)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline { p.terminate(); break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        outBuf.append(out.fileHandleForReading.readDataToEndOfFile())
        errBuf.append(err.fileHandleForReading.readDataToEndOfFile())
        return ShellResult(status: p.terminationStatus, stdout: outBuf.string, stderr: errBuf.string)
    }
}

private final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
