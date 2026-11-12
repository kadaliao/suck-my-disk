import AppKit
import Privileged
import ServiceManagement
import Update

/// The helper that uninstalls apps belonging to the system without a password each time.
/// It lives inside the app and runs as root only after the person turns it on here and
/// allows it in System Settings; macOS lists it under Login Items & Extensions.
@MainActor @Observable
final class Helper {
    enum State: Equatable {
        case off
        /// Registered, waiting for the person to allow it in System Settings.
        case needsApproval
        case on
    }

    /// False in demo and screenshot runs and in builds that aren't releases: nothing is registered.
    let available: Bool
    private(set) var state = State.off
    /// Why turning it on or off failed, or why the helper that is on doesn't answer.
    private(set) var problem: String?
    private(set) var checking = false

    private var service: SMAppService { SMAppService.daemon(plistName: Privileged.plistName) }

    init(enabled: Bool) {
        available = enabled && Updates.isReleaseBuild
        refresh()
    }

    /// Read off the main actor by Clean Up, right before it runs.
    nonisolated static var isOn: Bool {
        SMAppService.daemon(plistName: Privileged.plistName).status == .enabled
    }

    func refresh() {
        guard available else { return }
        let was = state
        state = switch service.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
        if state != was { problem = nil }
        // Just allowed: make sure it really starts and answers.
        if state == .on, was != .on { verify() }
    }

    func turnOn() {
        guard available else { return }
        problem = nil
        do {
            try service.register()
        } catch {
            // Registered but not allowed yet is reported as an error too; the status tells them apart.
            if service.status != .requiresApproval { problem = error.localizedDescription }
        }
        refresh()
        if state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func turnOff() {
        guard available else { return }
        problem = nil
        do { try service.unregister() } catch { problem = error.localizedDescription }
        refresh()
    }

    private func verify() {
        checking = true
        Task {
            let result = await Task.detached { HelperClient.hello() }.value
            checking = false
            if case .failure(let e) = result, state == .on { problem = e.description }
        }
    }
}
