import CryptoKit
import Foundation

/// Checks on the downloaded file itself (rules 2 and 3).
public enum DownloadVerifier {
    /// Sparkle signs the exact archive bytes with Ed25519; the public key is `SUPublicEDKey`.
    public static func verifyEdDSA(file: URL, signature: String, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let signatureData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        else { return false }
        return key.isValidSignature(signatureData, for: data)
    }

    public static func sha256Hex(of file: URL) throws -> String {
        var hasher = SHA256()
        try stream(file) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha512Base64(of file: URL) throws -> String {
        var hasher = SHA512()
        try stream(file) { hasher.update(data: $0) }
        return Data(hasher.finalize()).base64EncodedString()
    }

    static func stream(_ file: URL, _ body: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            body(chunk)
        }
    }
}

/// What kind of file a download is, by its first bytes rather than its name.
public enum ArchiveKind: Equatable, Sendable {
    case zip, dmg, pkg, tarGzip, tarBzip2, tarXz, tar, unknown

    public static func detect(_ file: URL) -> ArchiveKind {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .unknown }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 512)) ?? Data()
        let bytes = [UInt8](head)
        func starts(_ prefix: [UInt8]) -> Bool { bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix }

        if starts([0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if starts(Array("xar!".utf8)) { return .pkg }
        if starts([0x1F, 0x8B]) { return .tarGzip }
        if starts(Array("BZh".utf8)) { return .tarBzip2 }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .tarXz }
        if bytes.count >= 262, Array(bytes[257..<262]) == Array("ustar".utf8) { return .tar }
        // UDIF disk images end with a 512-byte "koly" trailer.
        if let size = try? handle.seekToEnd(), size >= 512 {
            try? handle.seek(toOffset: size - 512)
            if let trailer = try? handle.read(upToCount: 4), trailer == Data("koly".utf8) { return .dmg }
        }
        return .unknown
    }
}
