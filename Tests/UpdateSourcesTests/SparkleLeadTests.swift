import Foundation
import Net
import NetTesting
import Testing
import Versions
@testable import UpdateSources

/// A feed address found inside an app is only used once the feed proves it's the app's own.
@Suite struct SparkleLeadTests {
    func appcast(title: String, items: [(version: String, short: String, file: String)]) -> String {
        let body = items.map { item in
            """
            <item><title>\(item.short)</title>
            <sparkle:version>\(item.version)</sparkle:version><sparkle:shortVersionString>\(item.short)</sparkle:shortVersionString>
            <enclosure url="https://dl.example.com/\(item.file)" length="1" type="application/octet-stream" /></item>
            """
        }.joined()
        return """
        <?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel><title>\(title)</title>\(body)</channel></rss>
        """
    }

    let owner = SparkleSource.Owner(names: ["Quiet Tool", "QuietTool"], installed: VersionPair(short: "1.0", build: "100"))

    @Test func theChannelTitleOrTheDownloadNameProvesOwnership() throws {
        let named = try AppcastParser.parseFeed(Data(appcast(title: "Quiet Tool Updates", items: [("110", "1.1", "Other.zip")]).utf8))
        #expect(named.title == "Quiet Tool Updates")
        #expect(SparkleSource.belongs(named, to: owner))
        let file = try AppcastParser.parseFeed(Data(appcast(title: "Updates", items: [("110", "1.1", "QuietTool-1.1.dmg")]).utf8))
        #expect(SparkleSource.belongs(file, to: owner))
        let stranger = try AppcastParser.parseFeed(Data(appcast(title: "Updates", items: [("9", "9.0", "Something.zip")]).utf8))
        #expect(!SparkleSource.belongs(stranger, to: owner))
    }

    @Test func listingTheInstalledVersionProvesOwnershipToo() throws {
        let history = try AppcastParser.parseFeed(Data(appcast(title: "Updates", items: [("110", "1.1", "a.zip"), ("100", "1.0", "b.zip")]).utf8))
        #expect(SparkleSource.belongs(history, to: owner))
    }

    @Test func theFirstFeedThatBelongsWinsAndStrangersAreSkipped() async throws {
        let client = MockHTTPClient()
        client.respond(to: "https://example.com/stale.xml", status: 404, body: Data())
        client.respond(to: "https://example.com/other/appcast.xml", text: appcast(title: "Other App", items: [("500", "5.0", "Other.zip")]))
        client.respond(to: "https://example.com/quiet/appcast.xml", text: appcast(title: "Quiet Tool", items: [("110", "1.1", "QuietTool.zip")]))
        let leads = ["https://example.com/stale.xml", "https://example.com/other/appcast.xml", "https://example.com/quiet/appcast.xml"].map { URL(string: $0)! }
        let source = SparkleSource(client: client, system: SystemVersion("27.0"), isARM: true)
        let found = try #require(await source.check(leads: leads, owner: owner))
        #expect(found.feed.absoluteString == "https://example.com/quiet/appcast.xml")
        #expect(found.result.release?.version.short == "1.1")

        let onlyStrangers = await source.check(leads: Array(leads.prefix(2)), owner: owner)
        #expect(onlyStrangers == nil, "a feed for another app never raises an alert for this one")
    }
}
