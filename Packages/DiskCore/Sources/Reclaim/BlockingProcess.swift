import Darwin
import DiskIndex
import Foundation

/// The audit token binds a confirmation to one process even if macOS reuses its PID.
struct BlockingProcess {
    private var token = audit_token_t()
    let executable: String

    init?(_ program: Guards.Program) {
        let pid = program.pid
        guard pid > 1, pid != getpid(), pid != getppid(),
              getuid() != 0, program.uid == getuid() else { return nil }
        var port = mach_port_t()
        guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, port) }

        var value = audit_token_t()
        let capacity = MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == capacity else { return nil }
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath_audittoken(&value, &path, UInt32(path.count))
        guard length > 0 else { return nil }
        let executable = String(decoding: path.prefix(Int(length)), as: UTF8.self)
        guard !executable.hasPrefix("/System/Library/"), !executable.hasPrefix("/usr/libexec/"),
              !executable.hasPrefix("/sbin/"), !executable.hasPrefix("/usr/sbin/") else { return nil }
        self.executable = executable
        token = value
    }

    /// ESRCH also means the program quit while its confirmation was open.
    mutating func forceQuit(isCancelled: () -> Bool) -> Bool {
        let error = proc_signal_with_audittoken(&token, SIGKILL)
        if error == ESRCH { return true }
        guard error == 0 else { return false }
        // Delivery is asynchronous. Give the original process time to exit before rechecking the item.
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let deadline = ContinuousClock.now + .seconds(2)
        while proc_pidpath_audittoken(&token, &path, UInt32(path.count)) > 0 {
            guard ContinuousClock.now < deadline, !isCancelled() else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }
}
