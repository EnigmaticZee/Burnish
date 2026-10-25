import Foundation
import Net
import NetTesting
import Testing
import Versions
@testable import UpdateSources

@Suite struct TauriTests {
    @Test func expandsTauriTemplates() {
        let url = TauriSource.expand("https://releases.example.com/{{target}}/{{arch}}/{{current_version}}", version: "1.2.0", isARM: true)
        #expect(url?.absoluteString == "https://releases.example.com/darwin/aarch64/1.2.0")
        #expect(TauriSource.expand("https://r.example.com/{{target}}-{{arch}}.json", version: "1", isARM: false)?.absoluteString
                == "https://r.example.com/darwin-x86_64.json")
        #expect(TauriSource.expand("http://insecure.example.com/latest.json", version: "1", isARM: true) == nil, "HTTPS only")
        #expect(TauriSource.expand("https://x.example.com/{{unknown}}", version: "1", isARM: true) == nil)
    }

    @Test func readsAStaticLatestJSON() throws {
        let json = """
        {"version":"v2.4.1","notes":"Faster sync.","pub_date":"2026-10-20T09:30:00Z",
         "platforms":{"darwin-aarch64":{"signature":"…","url":"https://example.com/App_aarch64.app.tar.gz"},
                      "darwin-x86_64":{"signature":"…","url":"https://example.com/App_x64.app.tar.gz"}}}
        """
        let release = try #require(TauriSource.parse(Data(json.utf8), isARM: true))
        #expect(release.source == .tauri)
        #expect(release.version.short == "2.4.1", "a leading v is dropped")
        #expect(release.needsManualInstall, "the app installs it, checking its own signature")
        #expect(release.releaseNotes?.text == "Faster sync.")
        #expect(release.date != nil)
    }

    @Test func ignoresAFeedWithoutThisMac() {
        let json = #"{"version":"3.0.0","platforms":{"windows-x86_64":{"url":"https://example.com/a.msi"}}}"#
        #expect(TauriSource.parse(Data(json.utf8), isARM: true) == nil)
    }

    @Test func asksEachEndpointAndUnderstands204() async throws {
        let client = MockHTTPClient()
        client.respond(to: "https://one.example.com/latest.json", status: 500, text: "")
        client.respond(to: "https://two.example.com/darwin/aarch64/1.0.0", status: 204, text: "")
        let source = TauriSource(client: client, isARM: true)
        let release = try await source.check(endpoints: ["https://one.example.com/latest.json",
                                                         "https://two.example.com/{{target}}/{{arch}}/{{current_version}}"],
                                             installed: VersionPair(short: "1.0.0"))
        #expect(release.version.short == "1.0.0", "204 means nothing newer")
        #expect(client.requests.count == 2, "the first endpoint failed, so the second was asked")
    }

    @Test func everyEndpointFailing() async {
        let client = MockHTTPClient()
        await #expect(throws: TauriSource.Failure.self) {
            try await TauriSource(client: client, isARM: true).check(endpoints: ["https://gone.example.com/latest.json"],
                                                                    installed: VersionPair(short: "1.0"))
        }
    }
}
