import Foundation

/// Which processors an executable has code for, from its Mach-O header alone (the first few
/// kilobytes), so finding Intel-only apps costs next to nothing.
public enum MachOArchitectures {
    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let fatMagic64: UInt32 = 0xCAFE_BABF
    static let thinMagic64: UInt32 = 0xFEED_FACF
    static let thinMagic: UInt32 = 0xFEED_FACE

    public static func of(_ executable: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return [] }
        defer { try? handle.close() }
        return parse((try? handle.read(upToCount: 4096)) ?? Data())
    }

    static func parse(_ header: Data) -> [String] {
        let bytes = [UInt8](header)
        func big(_ at: Int) -> UInt32? {
            guard at + 4 <= bytes.count else { return nil }
            return bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func little(_ at: Int) -> UInt32? { big(at).map(\.byteSwapped) }

        guard let magic = big(0) else { return [] }
        if magic == fatMagic || magic == fatMagic64, let count = big(4), count < 32 {
            let entry = magic == fatMagic64 ? 32 : 20
            return (0..<Int(count)).compactMap { big(8 + $0 * entry).flatMap(name) }
        }
        // Thin binaries store the header little-endian on Intel and Apple silicon alike.
        if let thin = little(0), thin == thinMagic64 || thin == thinMagic, let type = little(4), let arch = name(type) {
            return [arch]
        }
        return []
    }

    static func name(_ cpuType: UInt32) -> String? {
        switch cpuType {
        case 0x0100_000C: "arm64"
        case 0x0100_0007: "x86_64"
        case 0x0000_0007: "i386"
        case 0x0000_000C: "arm"
        case 0x0000_0012, 0x0100_0012: "ppc"
        default: nil
        }
    }
}
