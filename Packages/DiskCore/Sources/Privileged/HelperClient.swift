import Foundation

/// The app's side: asks the helper to move an app. Blocks until it answers.
public enum HelperClient {
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var value: (Bool, String)?

        /// The first answer wins: a reply, or the connection failing.
        func set(_ ok: Bool, _ message: String) {
            lock.withLock { if value == nil { value = (ok, message) } }
            done.signal()
        }

        func wait(_ seconds: TimeInterval) -> (Bool, String) {
            _ = done.wait(timeout: .now() + seconds)
            return lock.withLock { value } ?? (false, "the helper didn't answer in \(Int(seconds)) s")
        }
    }

    /// The helper is a system service. Tests run one of their own as the current user.
    nonisolated(unsafe) static var lookup: NSXPCConnection.Options = .privileged

    private static func connect() -> NSXPCConnection? {
        // Only the helper this team signed is talked to; an unsigned build has no helper.
        guard let team = Privileged.ownTeam(),
              let rule = Privileged.requirement(identifier: Privileged.helperID, team: team) else { return nil }
        let c = NSXPCConnection(machServiceName: Privileged.helperID, options: lookup)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.setCodeSigningRequirement(rule)
        c.resume()
        return c
    }

    private static func ask(_ c: NSXPCConnection, timeout: TimeInterval,
                            _ call: (HelperProtocol, Answer) -> Void) -> (Bool, String) {
        let answer = Answer()
        guard let helper = c.remoteObjectProxyWithErrorHandler({ answer.set(false, "helper: \($0.localizedDescription)") })
                as? HelperProtocol else { return (false, "helper: no proxy") }
        call(helper, answer)
        return answer.wait(timeout)
    }

    /// The running helper's version, or why it can't be reached. A helper left running from
    /// before an update is told to quit, and the new one is asked.
    public static func hello(timeout: TimeInterval = 10) -> Result<Int, AppMover.Refusal> {
        var last = "helper: this build is not signed"
        for attempt in 0..<2 {
            guard let c = connect() else { break }
            defer { c.invalidate() }
            let (ok, text) = ask(c, timeout: timeout) { h, a in h.hello { a.set(true, String($0)) } }
            guard ok else { last = text; break }
            if Int(text) == Privileged.version { return .success(Privileged.version) }
            last = "helper: version \(text), expected \(Privileged.version)"
            guard attempt == 0 else { break }
            _ = ask(c, timeout: 2) { h, a in h.quit { a.set(true, "") } }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return .failure(AppMover.Refusal(last))
    }

    /// Nil once the app at `path` is in the Trash; otherwise why it isn't.
    public static func trashApp(_ path: String, timeout: TimeInterval = 60) -> String? {
        if case .failure(let e) = hello() { return e.description }
        guard let c = connect() else { return "helper: this build is not signed" }
        defer { c.invalidate() }
        let (ok, text) = ask(c, timeout: timeout) { h, a in h.trashApp(path) { a.set($0, $1) } }
        return ok ? nil : text
    }
}
