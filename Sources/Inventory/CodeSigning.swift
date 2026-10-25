import Foundation
import Security

public protocol SignatureReading: Sendable {
    /// Reads the signature without validating it (fast enough for a scan).
    func signature(of bundle: URL) -> CodeSignature
}

/// Reads code signatures with the Security framework.
public struct SecuritySignatureReader: SignatureReading {
    public init() {}

    public func signature(of bundle: URL) -> CodeSignature {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return .unsigned
        }
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess, let dict = info as? [String: Any] else { return .unsigned }

        let identifier = dict[kSecCodeInfoIdentifier as String] as? String
        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []

        if identifier == nil && certificates.isEmpty && flags == 0 && teamID == nil {
            return .unsigned
        }
        // kSecCodeSignatureAdhoc
        if flags & 0x0002 != 0 || certificates.isEmpty {
            return CodeSignature(kind: .adHoc, teamID: nil, identifier: identifier)
        }
        let authority = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        return CodeSignature(kind: Self.kind(for: authority, teamID: teamID), teamID: teamID, identifier: identifier, authority: authority)
    }

    static func kind(for authority: String?, teamID: String?) -> CodeSignature.Kind {
        guard let authority else { return .other }
        if authority.hasPrefix("Developer ID Application") { return .developerID }
        if authority == "Apple Mac OS Application Signing" { return .appStore }
        if authority.hasPrefix("Apple Development") || authority.hasPrefix("Mac Developer") { return .development }
        if teamID == nil, authority.contains("Software Signing") { return .apple }
        return .other
    }
}

/// Full validation, used on a downloaded app before it replaces anything (install rule 4).
public enum SignatureValidator {
    public enum Failure: Error, Equatable, LocalizedError {
        case unsigned
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .unsigned: String(localized: "The new copy isn't signed")
            case .invalid(let detail): String(localized: "The new copy's signature isn't valid (\(detail))")
            }
        }
    }

    /// Checks every architecture and every nested framework and helper, and, when given, a code
    /// requirement such as `anchor apple generic and certificate leaf[subject.OU] = "TEAMID"`.
    public static func validate(_ bundle: URL, requirement text: String? = nil) throws(Failure) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw .unsigned
        }
        var requirement: SecRequirement?
        if let text {
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
                throw .invalid("bad requirement")
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, &error)
        if status == errSecSuccess { return }
        if status == errSecCSUnsigned { throw .unsigned }
        if status == errSecCSReqFailed { throw .invalid(String(localized: "not signed by the same developer")) }
        let detail = (error?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "OSStatus \(status)"
        throw .invalid(detail)
    }
}
