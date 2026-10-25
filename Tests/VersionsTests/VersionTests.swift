import Testing
@testable import Versions

struct OrderCase: Sendable, CustomTestStringConvertible {
    let lhs: String
    let op: String
    let rhs: String
    init(_ lhs: String, _ op: String, _ rhs: String) { self.lhs = lhs; self.op = op; self.rhs = rhs }
    var testDescription: String { "\(lhs) \(op) \(rhs)" }
}

/// Ordering of two version strings. Every bug found gets a row here.
let orderCases: [OrderCase] = [
    // Dotted numbers, part by part as integers
    .init("1", "<", "2"),
    .init("1.0", "<", "1.1"),
    .init("1.9", "<", "1.10"),
    .init("1.10", ">", "1.9"),
    .init("1.2.3", "<", "1.2.4"),
    .init("1.2.3", "<", "1.3.0"),
    .init("1.2.10", ">", "1.2.9"),
    .init("2.0", ">", "1.99.99"),
    .init("10.0", ">", "9.9"),
    .init("0.0.416", "<", "0.0.420"),
    .init("0.9", "<", "0.10"),
    .init("155.0.8059.86", "<", "156.0.8078.48"),
    .init("155.0.8059.86", ">", "155.0.8059.40"),
    .init("158.0.1", "=", "158.0.1"),
    .init("2.20.1", "<", "2.20.2"),
    .init("4.52.182", "=", "4.52.182"),
    .init("26.41.74", "<", "26.42"),
    .init("1.1.32", "<", "1.1.100"),
    // Missing parts count as zero
    .init("1.2", "=", "1.2.0"),
    .init("1.2", "=", "1.2.0.0"),
    .init("1", "=", "1.0.0"),
    .init("1.2", "<", "1.2.0.1"),
    .init("1.2.0.1", ">", "1.2"),
    .init("3.0.0", "<", "3.0.0.1"),
    // Leading zeros
    .init("02.08.02.61", "=", "2.8.2.61"),
    .init("1.01", "=", "1.1"),
    .init("1.010", ">", "1.9"),
    .init("2026.01", "<", "2026.10"),
    // Huge numbers don't overflow
    .init("20260724200710000", "<", "20260724200710001"),
    .init("99999999999999999999", ">", "9999999999999999999"),
    .init("1.20260930", ">", "1.20260929"),
    // Pre-release tags sort below the release they precede
    .init("1.2b4", "<", "1.2"),
    .init("1.2", ">", "1.2b4"),
    .init("1.2b4", "<", "1.2b5"),
    .init("1.2b4", "<", "1.2.1"),
    .init("1.2a1", "<", "1.2b1"),
    .init("1.2b9", "<", "1.2rc1"),
    .init("1.2rc1", "<", "1.2"),
    .init("1.2rc2", ">", "1.2rc1"),
    .init("1.0.0-alpha", "<", "1.0.0-alpha.1"),
    .init("1.0.0-alpha.1", "<", "1.0.0-beta"),
    .init("1.0.0-beta", "<", "1.0.0-beta.2"),
    .init("1.0.0-beta.2", "<", "1.0.0-beta.11"),
    .init("1.0.0-beta.11", "<", "1.0.0-rc.1"),
    .init("1.0.0-rc.1", "<", "1.0.0"),
    .init("2.0.0-beta", ">", "1.9.9"),
    .init("159.0b5", ">", "158.0.1"),
    .init("159.0b5", "<", "159.0"),
    .init("1.0 beta 2", "<", "1.0"),
    .init("1.0 Beta 2", "=", "1.0b2"),
    .init("1.0-BETA", "=", "1.0b"),
    .init("2.0-preview3", "<", "2.0"),
    .init("2.0-preview3", ">", "2.0-alpha9"),
    .init("3.2.0-RC3", "<", "3.2.0"),
    .init("1.0-dev", "<", "1.0-alpha"),
    .init("1.0-nightly", "<", "1.0-beta"),
    .init("1.0-canary", "<", "1.0"),
    .init("31.1-rc1", "<", "31.1"),
    .init("2.43.0-beta.02", "<", "2.43.0"),
    .init("1.0.0-alpha.10", ">", "1.0.0-alpha.9"),
    .init("1.0a", "=", "1.0alpha"),
    .init("1.0b", "=", "1.0beta"),
    .init("2026.3-eap", "<", "2026.3"),
    // Words that mark a release or patch read as separators
    .init("6000.6.7f1", "<", "6000.6.7f2"),
    .init("6000.6.7f2", "<", "6000.6.8f1"),
    .init("2.012R", "=", "2.12"),
    .init("1.0-final", "=", "1.0"),
    .init("5.69.0-latest", "=", "5.69.0"),
    .init("140.5.0esr", "=", "140.5.0"),
    .init("1.2p3", ">", "1.2"),
    .init("1.2 build 5", ">", "1.2 build 4"),
    // Unknown words compare alphabetically, below the bare release
    .init("2026b", "<", "2026c"),
    .init("2026a", "<", "2026"),
    .init("1.4.13c", "<", "1.4.13d"),
    // Prefixes
    .init("v1.2.3", "=", "1.2.3"),
    .init("V2.0", "=", "2.0"),
    .init("Version 3.1", "=", "3.1"),
    .init("v1.2.3", "<", "v1.2.10"),
    // Separators are interchangeable
    .init("1-2-3", "=", "1.2.3"),
    .init("1_2_3", "=", "1.2.3"),
    .init("2026-07-23", "<", "2026-10-14"),
    .init("2026-07-23", "<", "2026.07.24"),
    .init("8.37.2-1", ">", "8.37.2"),
    .init("8.37.2-1", "<", "8.37.2-2"),
    .init("1.2.0_1", ">", "1.2.0"),
    .init("1.0+build.5", ">", "1.0"),
    // Whitespace around the string
    .init(" 1.2.3 ", "=", "1.2.3"),
    .init("1.2.3\n", "=", "1.2.3"),
    // Date-like and year-based versions
    .init("2024.3", "<", "2025.1"),
    .init("2024.3.2", "<", "2024.10"),
    .init("20261023", ">", "20260930"),
    .init("2025-2", "<", "2025-3"),
    // Build numbers
    .init("2627", "<", "2629"),
    .init("450152", ">", "450151"),
    .init("15826.10.19", ">", "15726.10.5"),
    .init("50700.0.2609242043", "<", "50702.0.2610141002"),
    .init("452000182", "=", "452000182"),
]

@Test(arguments: orderCases)
func ordering(_ c: OrderCase) throws {
    let lhs = try #require(Version(c.lhs), "\(c.lhs) should parse")
    let rhs = try #require(Version(c.rhs), "\(c.rhs) should parse")
    switch c.op {
    case "<":
        #expect(lhs < rhs)
        #expect(rhs > lhs)
        #expect(lhs != rhs)
    case ">":
        #expect(lhs > rhs)
        #expect(rhs < lhs)
    case "=":
        #expect(lhs == rhs)
        #expect(!(lhs < rhs) && !(rhs < lhs))
        #expect(lhs.hashValue == rhs.hashValue)
    default:
        Issue.record("bad op \(c.op)")
    }
}

@Test(arguments: [
    "", "   ", "latest", "LATEST", "beta", "beta 2", "unknown", "N/A", "1.2/3", "1.2:3", "1,2",
    "#1", "1.2.3@beta", "—", "1.0 β", "v", "vv1.0", "release", "x.y.z", "abc1.0",
    String(repeating: "1.", count: 60),
])
func unparseable(_ string: String) {
    #expect(Version(string) == nil, "\"\(string)\" should not parse")
}

@Test func majorAndLeadingNumber() throws {
    #expect(Version("5.4.1")?.major == 5)
    #expect(Version("0.0.416")?.major == 0)
    #expect(Version("155.0.8059.86")?.major == 155)
    #expect(Version("99999999999999999999")?.major == nil)
    #expect(Version("99999999999999999999")?.leadingNumber != nil)
    #expect(try #require(Version("1.2b4")).isPrerelease)
    #expect(try #require(Version("1.2.4")).isPlainNumeric)
    #expect(try #require(Version("6000.6.7f1")).isPlainNumeric)
}

@Test func sortsAList() throws {
    let input = ["1.10", "1.2", "1.2b1", "1.9.9", "2.0rc1", "1.2.1", "2.0"]
    let sorted = input.compactMap(Version.init).sorted().map(\.raw)
    #expect(sorted == ["1.2b1", "1.2", "1.2.1", "1.9.9", "1.10", "2.0rc1", "2.0"])
}
