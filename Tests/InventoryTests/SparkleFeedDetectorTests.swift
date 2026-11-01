import Foundation
import Testing
@testable import Inventory

@Suite struct SparkleFeedDetection {
    func binary(_ parts: [String]) -> Data {
        var data = Data(repeating: 0, count: 64)
        for part in parts { data.append(Data(part.utf8)); data.append(0) }
        return data
    }

    @Test func keepsOnlyAddressesThatLookLikeAppcasts() {
        let data = binary([
            "http://www.andymatuschak.org/xml-namespaces/sparkle",
            "https://www.w3.org/2005/Atom",
            "https://developer.apple.com/documentation/",
            "https://updates.example.com/",
            "https://updates.example.com/%@/appcast.xml",
            "https://example.com/privacy",
            "https://www.example.com/software/checkupdate/mac?edition=1",
            "https://updates.example.com/stable/appcast.xml",
            "https://cdn.example.com/feed.rss",
        ])
        #expect(SparkleFeedDetector.candidates(in: data) == [
            "https://updates.example.com/stable/appcast.xml",
            "https://cdn.example.com/feed.rss",
            "https://www.example.com/software/checkupdate/mac?edition=1",
        ], "appcasts first, then feeds, then update paths; namespaces, bare hosts and format strings dropped")
    }

    @Test func stopsAtFourLeads() {
        let data = binary((1...9).map { "https://example.com/feeds/\($0)/appcast.xml" })
        #expect(SparkleFeedDetector.candidates(in: data).count == 4)
    }

    @Test func readsTheExecutableAndLeavesHugeOnesAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnish-sparkle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("Tool")
        try binary(["https://updates.example.com/appcast.xml"]).write(to: executable)
        #expect(SparkleFeedDetector.candidateFeeds(executable: executable) == ["https://updates.example.com/appcast.xml"])
        #expect(SparkleFeedDetector.candidateFeeds(executable: dir.appendingPathComponent("missing")).isEmpty)
    }
}
