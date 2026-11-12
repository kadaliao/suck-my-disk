import Foundation
import Privileged

// SuckMyDisk's helper. launchd starts it as root when the app connects, and it quits once
// nobody has asked for anything for a while. See `Privileged` for what it does and for whom.

/// One at a time, and the place the idle timer lives.
let work = DispatchQueue(label: Privileged.helperID)
nonisolated(unsafe) var lastAsked = Date()
let idle: TimeInterval = 30

final class Handler: NSObject, HelperProtocol {
    let uid: uid_t
    init(uid: uid_t) { self.uid = uid }

    func hello(reply: @escaping @Sendable (Int) -> Void) {
        work.async {
            lastAsked = Date()
            reply(Privileged.version)
        }
    }

    func trashApp(_ path: String, reply: @escaping @Sendable (Bool, String) -> Void) {
        let uid = uid
        work.async {
            lastAsked = Date()
            let result = AppMover().trash(path, for: uid)
            lastAsked = Date()
            switch result {
            case .success(let dest):
                NSLog("moved %@ to %@ for user %d", path, dest, uid)
                reply(true, dest)
            case .failure(let why):
                NSLog("did not move %@ for user %d: %@", path, uid, why.description)
                reply(false, why.description)
            }
        }
    }

    func quit(reply: @escaping @Sendable () -> Void) {
        work.async {
            reply()
            // After the reply is on its way.
            work.asyncAfter(deadline: .now() + 0.1) { exit(0) }
        }
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        // The user the system says is on the other end, not one the caller names.
        c.exportedObject = Handler(uid: c.effectiveUserIdentifier)
        c.resume()
        return true
    }
}

// Only SuckMyDisk signed by the team that signed this helper may connect; the system checks
// every message against it. A helper with no team can't tell who is calling, so it won't run.
guard let team = Privileged.ownTeam(),
      let rule = Privileged.requirement(identifier: Privileged.appID, team: team) else {
    NSLog("not signed by a team: refusing to run")
    exit(1)
}
let delegate = Listener()
let listener = NSXPCListener(machServiceName: Privileged.helperID)
listener.setConnectionCodeSigningRequirement(rule)
listener.delegate = delegate
listener.resume()

let timer = DispatchSource.makeTimerSource(queue: work)
timer.schedule(deadline: .now() + idle, repeating: 5)
timer.setEventHandler { if Date().timeIntervalSince(lastAsked) > idle { exit(0) } }
timer.resume()
dispatchMain()
