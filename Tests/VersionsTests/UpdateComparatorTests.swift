import Testing
@testable import Versions

struct VerdictCase: Sendable, CustomTestStringConvertible {
    let name: String
    let installed: VersionPair
    let available: VersionPair
    let basis: ComparisonBasis
    let expected: String // "newer", "major", "same", "older", "cant"

    var testDescription: String { name }
}

private func short(_ name: String, _ installed: (String?, String?), _ available: String, _ expected: String) -> VerdictCase {
    VerdictCase(
        name: name,
        installed: VersionPair(short: installed.0, build: installed.1),
        available: VersionPair.fromCask(available),
        basis: .shortVersion,
        expected: expected
    )
}

private func sparkle(_ name: String, _ installed: (String?, String?), _ available: (String?, String?), _ expected: String) -> VerdictCase {
    VerdictCase(
        name: name,
        installed: VersionPair(short: installed.0, build: installed.1),
        available: VersionPair(short: available.0, build: available.1),
        basis: .bundleVersion,
        expected: expected
    )
}

let verdictCases: [VerdictCase] = [
    // Homebrew / App Store: compare display versions
    short("chrome minor update", ("155.0.8059.86", "8059.86"), "156.0.8078.48", "newer"),
    short("firefox current", ("158.0.1", "15826.10.19"), "158.0.1", "same"),
    short("slack current", ("4.52.182", "452000182"), "4.52.182", "same"),
    short("adguard behind", ("2.20.1", "2627"), "2.20.2.2629", "newer"),
    short("discord 0.0.x", ("0.0.416", "0.0.416"), "0.0.420", "newer"),
    short("cask build part newer", ("1.2.3", "455"), "1.2.3,456", "newer"),
    short("cask build part same", ("1.2.3", "456"), "1.2.3,456", "same"),
    short("cask build part older is still same", ("1.2.3", "460"), "1.2.3,456", "same"),
    short("cask build part is a hash", ("0.84.17", "1306"), "0.84.17,1306a54b77", "same"),
    short("cask build part is a date in another scheme", ("1.17", "45"), "1.17,2026.10", "same"),
    short("cleanmymac short newer", ("5.7.0", "50700.0.2609242043"), "5.7.2,50702.0.2610141002", "newer"),
    short("installed beta newer than stable", ("159.0b5", nil), "158.0.1", "older"),
    short("installed newer than store lag", ("2.36", "800"), "2.35", "older"),
    short("pre-release installed, release out", ("2.0rc1", nil), "2.0", "newer"),
    short("major upgrade 5 to 6", ("5.4.1", nil), "6.0", "major"),
    short("major upgrade 1 to 2", ("1.9", nil), "2.0.1", "major"),
    short("rapid release not major", ("155.0", nil), "156.0", "newer"),
    short("zero major not major", ("0.9.1", nil), "1.0", "newer"),
    short("year based not major", ("2024.3", nil), "2025.1", "newer"),
    short("latest is cant compare", ("1.0", "1"), "latest", "cant"),
    short("garbage cask version", ("1.0", "1"), "release-candidate", "cant"),
    short("unreadable installed", ("N/A", nil), "1.0", "cant"),
    short("cask tracks build number", ("8.2.26", "8226"), "8226", "same"),
    short("cask tracks build number, newer", ("8.2.26", "8226"), "8230", "newer"),
    short("cask build number behind", ("8.2.26", "8226"), "8200", "older"),
    short("formats don't line up", ("8.2.26", nil), "8226", "cant"),
    short("date vs semver", ("1.4", "14"), "20261023", "cant"),
    short("build equality protects against false alert", ("2.5", "2.5.1"), "2.5.1", "same"),
    short("only build in plist", (nil, "2.4.1.1001"), "2.4.1.1002", "newer"),
    short("only build in plist same", (nil, "2.4.1.1001"), "2.4.1.1001", "same"),
    short("99 to 100 transition", ("99.0.1", nil), "100.0", "newer"),
    short("trailing zero same", ("1.2", nil), "1.2.0", "same"),
    short("cask with debian revision", ("8.37.2", nil), "8.37.2-1", "newer"),
    short("cask with revision equal to build", ("8.37.2", "1"), "8.37.2-1", "same"),
    short("build joined with a dot, current", ("2.20.2", "2629"), "2.20.2.2629", "same"),
    short("build joined with a dot, newer build", ("2.20.2", "2627"), "2.20.2.2629", "newer"),
    short("build joined with a dot, installed build ahead", ("2.20.2", "2630"), "2.20.2.2629", "older"),
    short("patch release is not mistaken for a build", ("1.2", "5"), "1.2.1", "newer"),
    short("tiny build never bridges schemes", ("2024.3", "1"), "5.2", "cant"),
    short("calver is not a chromium prefix", ("2024.1.2", nil), "1.9.5", "cant"),
    short("three-part version is not a chromium prefix", ("155.1.97", nil), "1.98.60", "cant"),
    short("prefixed v", ("v3.7.6", nil), "3.7.6", "same"),
    short("chromium-prefixed version", ("155.1.97.57", "197.57"), "1.98.60.0", "newer"),
    short("chromium-prefixed version same", ("155.1.98.60", nil), "1.98.60.0", "same"),
    short("chromium-prefixed version ahead", ("156.1.99.1", nil), "1.98.60.0", "older"),
    short("prefix rule needs matching lead", ("155.2.97.57", nil), "1.98.60.0", "cant"),

    // Sparkle: compare CFBundleVersion
    sparkle("adguard build newer", ("2.20.1", "2627"), ("2.20.2", "2629"), "newer"),
    sparkle("same build", ("2.20.2", "2629"), ("2.20.2", "2629"), "same"),
    sparkle("build older", ("2.20.2", "2630"), ("2.20.2", "2629"), "older"),
    sparkle("build newer but short older", ("3.0", "500"), ("2.9", "501"), "cant"),
    sparkle("major via short", ("5.9", "590"), ("6.0", "600"), "major"),
    sparkle("feed without short", ("1.0", "10"), (nil, "11"), "newer"),
    sparkle("feed with only short", ("1.0", nil), ("1.1", nil), "newer"),
    sparkle("build schemes differ, shorts decide", ("2.0.10", "69"), ("2.0.11", "2026.10.01"), "newer"),
    sparkle("build schemes differ, shorts same", ("2.0.10", "69"), ("2.0.10", "2026.10.01"), "same"),
    sparkle("build schemes differ, no shorts", (nil, "69"), (nil, "2026.10.01"), "cant"),
    sparkle("unreadable feed build", ("1.0", "10"), ("1.0", "latest"), "cant"),
    sparkle("dotted build", ("13.1.0", "283357"), ("13.2.0", "284000"), "newer"),
]

@Test(arguments: verdictCases)
func verdicts(_ c: VerdictCase) {
    let verdict = UpdateComparator.compare(installed: c.installed, available: c.available, basis: c.basis)
    switch (c.expected, verdict) {
    case ("newer", .newer(major: false)), ("major", .newer(major: true)), ("same", .same), ("older", .older), ("cant", .cantCompare):
        break
    default:
        Issue.record("\(c.name): expected \(c.expected), got \(verdict)")
    }
}

@Test func caskVersionSplit() {
    #expect(VersionPair.fromCask("1.2.3,456") == VersionPair(short: "1.2.3", build: "456"))
    #expect(VersionPair.fromCask("26.1.2,73,20261007195555") == VersionPair(short: "26.1.2", build: "73"))
    #expect(VersionPair.fromCask("3.7.6") == VersionPair(short: "3.7.6", build: nil))
    #expect(VersionPair.fromCask("latest") == VersionPair(short: "latest", build: nil))
    #expect(VersionPair.fromCask("1.0,") == VersionPair(short: "1.0", build: nil))
}

@Test func displaySplit() {
    #expect(VersionPair.splittingDisplay("5.0 (1234)") == VersionPair(short: "5.0", build: "1234"))
    #expect(VersionPair.splittingDisplay("5.0 (Build 1234)") == VersionPair(short: "5.0", build: "1234"))
    #expect(VersionPair.splittingDisplay("2.1 build 345") == VersionPair(short: "2.1", build: "345"))
    #expect(VersionPair.splittingDisplay("2.1") == VersionPair(short: "2.1", build: nil))
}

@Test func compatibility() throws {
    let v = { (s: String) in Version(s)! }
    #expect(UpdateComparator.isCompatible(v("5.0"), v("6.0")))
    #expect(UpdateComparator.isCompatible(v("155"), v("156")))
    #expect(UpdateComparator.isCompatible(v("99"), v("100")))
    #expect(!UpdateComparator.isCompatible(v("8"), v("8226")))
    #expect(!UpdateComparator.isCompatible(v("2026"), v("20261023")))
    #expect(!UpdateComparator.isCompatible(v("1.4"), v("2024.1")))
}
