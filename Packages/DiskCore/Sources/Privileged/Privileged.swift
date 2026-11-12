import Foundation
import Security

/// What the app and its helper agree on. The helper is a small program that runs as root, so
/// that uninstalling an app that belongs to the system needs no password each time. It does
/// one thing: move an app from /Applications to the Trash of the person who asked.
public enum Privileged {
    public static let appID = "com.kadaliao.SuckMyDisk"
    /// The helper's launchd label, Mach service and signing identifier.
    public static let helperID = "com.kadaliao.SuckMyDisk.helper"
    /// In the app's `Contents/Library/LaunchDaemons`.
    public static let plistName = helperID + ".plist"
    /// Raised when the messages change. A helper still running from before an update answers
    /// with its own number, is told to quit, and launchd starts the new one.
    public static let version = 1

    /// The team that signed this program, or nil for an unsigned or ad hoc build.
    public static func ownTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var fixed: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &fixed) == errSecSuccess, let fixed else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(fixed, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return team
    }

    /// The other end must be the program `identifier`, signed by `team` with a certificate from
    /// Apple. Nil if `team` doesn't look like a team id, so nothing odd gets into the text.
    public static func requirement(identifier: String, team: String) -> String? {
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}

@objc public protocol HelperProtocol {
    /// The helper's `Privileged.version`.
    func hello(reply: @escaping @Sendable (Int) -> Void)
    /// Moves the app at `path` to the caller's Trash. `ok` false: nothing was moved and
    /// `message` says why; true: `message` is where it went.
    func trashApp(_ path: String, reply: @escaping @Sendable (Bool, String) -> Void)
    /// Ends the helper; launchd starts it again when it is next needed.
    func quit(reply: @escaping @Sendable () -> Void)
}
