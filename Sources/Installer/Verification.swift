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

/// What kind of file a download is: by its bytes first, and by its name when the bytes say nothing.
public enum ArchiveKind: Equatable, Sendable {
    case zip, dmg, pkg, tarGzip, tarBzip2, tarXz, tar, unknown

    public static func detect(_ file: URL, name: String? = nil) -> ArchiveKind {
        let kind = byContent(file)
        if kind != .unknown { return kind }
        return name.map(byName) ?? .unknown
    }

    /// What the file name claims, for a download whose bytes Burnish doesn't recognise.
    static func byName(_ name: String) -> ArchiveKind {
        let lower = name.lowercased()
        if lower.hasSuffix(".dmg") { return .dmg }
        if lower.hasSuffix(".zip") { return .zip }
        if lower.hasSuffix(".pkg") || lower.hasSuffix(".mpkg") { return .pkg }
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return .tarGzip }
        if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz") || lower.hasSuffix(".tbz2") { return .tarBzip2 }
        if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { return .tarXz }
        if lower.hasSuffix(".tar") { return .tar }
        return .unknown
    }

    /// The tool that opens this kind. Kinds that share one needn't be tried twice.
    var opener: String {
        switch self {
        case .zip: "ditto"
        case .dmg: "hdiutil"
        case .tarGzip, .tarBzip2, .tarXz, .tar: "tar"
        case .pkg: "installer"
        case .unknown: ""
        }
    }

    static func byContent(_ file: URL) -> ArchiveKind {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .unknown }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 512)) ?? Data()
        let bytes = [UInt8](head)
        func starts(_ prefix: [UInt8]) -> Bool { bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix }

        // UDIF disk images end with a 512-byte "koly" trailer. That comes first: a compressed image
        // (bzip2 or lzma) opens with its compressor's own magic, the same bytes a tarball would.
        if let size = try? handle.seekToEnd(), size >= 512 {
            try? handle.seek(toOffset: size - 512)
            if let trailer = try? handle.read(upToCount: 4), trailer == Data("koly".utf8) { return .dmg }
        }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if starts(Array("xar!".utf8)) { return .pkg }
        if starts([0x1F, 0x8B]) { return .tarGzip }
        if starts(Array("BZh".utf8)) { return .tarBzip2 }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .tarXz }
        if bytes.count >= 262, Array(bytes[257..<262]) == Array("ustar".utf8) { return .tar }
        return .unknown
    }
}

/// What a download looked like when it couldn't be opened, for a bug report: its name and size,
/// its first bytes and the start of its trailer, and how Burnish read it. Nothing about the person
/// or the Mac.
public enum ArchiveEvidence {
    public static func describe(_ file: URL, name: String, readAs kind: ArchiveKind) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        var head = Data(), tail = Data()
        if let handle = try? FileHandle(forReadingFrom: file) {
            head = (try? handle.read(upToCount: 8)) ?? Data()
            if size >= 512, (try? handle.seek(toOffset: UInt64(size - 512))) != nil {
                tail = (try? handle.read(upToCount: 4)) ?? Data()
            }
            try? handle.close()
        }
        let hex = head.map { String(format: "%02x", $0) }.joined()
        let trailer = String(decoding: tail.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
        return "\(name) · \(size) bytes · starts \(hex) · 512 bytes from the end: \(trailer.isEmpty ? "-" : trailer) · read as \(kind)"
    }

    /// The top of an opened download, when the app wasn't in it.
    public static func contents(of folder: URL) -> String {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        guard !names.isEmpty else { return "nothing" }
        return names.prefix(6).joined(separator: ", ") + (names.count > 6 ? ", …" : "")
    }
}
