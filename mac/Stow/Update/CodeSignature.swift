import Foundation
import Security

/// Code signature checks for an update, through the Security framework.
enum CodeSignature {
    struct Info: Equatable, Sendable {
        var identifier: String?
        var teamID: String?
    }

    /// The running app's signature.
    static func running() throws -> Info {
        var code: SecCode?
        try check(SecCodeCopySelf(SecCSFlags(), &code), "read this app's signature")
        var staticCode: SecStaticCode?
        try check(SecCodeCopyStaticCode(code!, SecCSFlags(), &staticCode), "read this app's signature")
        return try info(of: staticCode!)
    }

    /// The signature of the bundle or binary at `url` (not validated).
    static func info(at url: URL) throws -> Info {
        try info(of: staticCode(at: url))
    }

    /// Validates the whole bundle (every architecture and nested code, strictly) against a
    /// requirement: an Apple-issued certificate for `teamID`, and `identifier` when given.
    static func validate(_ url: URL, teamID: String, identifier: String?) throws {
        let code = try staticCode(at: url)
        var text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        if let identifier { text = "identifier \"\(identifier)\" and " + text }
        var requirement: SecRequirement?
        try check(SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement), "build the signature requirement")
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        if status == errSecCSReqFailed {
            throw UpdateError.signature("The update isn't signed by the same developer as this copy of Stow (team \(teamID)).")
        }
        if status != errSecSuccess {
            throw UpdateError.signature("The update's signature isn't valid: \(message(for: status))")
        }
        let info = try info(of: code)
        guard info.teamID == teamID else {
            throw UpdateError.signature("The update is signed by \(info.teamID ?? "no team"), not \(teamID).")
        }
    }

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code), "read the update's signature")
        return code!
    }

    private static func info(of code: SecStaticCode) throws -> Info {
        var dictionary: CFDictionary?
        try check(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary),
                  "read a signature")
        let values = dictionary as? [String: Any] ?? [:]
        return Info(identifier: values[kSecCodeInfoIdentifier as String] as? String,
                    teamID: values[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    private static func check(_ status: OSStatus, _ action: String) throws {
        guard status == errSecSuccess else { throw UpdateError.signature("Couldn't \(action): \(message(for: status))") }
    }

    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
    }
}
