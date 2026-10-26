import Foundation
import Testing
@testable import BurnishCore

@Suite struct ReleaseHistoryTests {
    let markdown = """
    # Version history

    ## 0.3.0-beta — 2026-10-25
    Burnish now shows its working.

    + Every update lists where it comes from and the checks it has to pass
      before it goes in.
    + Minor updates can install themselves.

    - **Every update shows its hallmarks.** An app's details now list where the download comes from
      and each check it has to pass.
    - **Fixed:** notices no longer cover the search field.

    Nothing to do: Burnish updates itself as usual, and automatic updates stay off until you turn them
    on.

    ## 0.1.0-alpha — 2026-10-24
    First light.

    - **Finds updates for apps from anywhere.**
    """

    @Test func readsEachPartOfAnEntry() throws {
        let history = ReleaseHistory(markdown: markdown)
        #expect(history.entries.map(\.version) == ["0.3.0-beta", "0.1.0-alpha"])
        let entry = try #require(history.entry(for: "0.3.0-beta"))
        #expect(entry.date == "2026-10-25")
        #expect(entry.headline == "Burnish now shows its working.")
        #expect(entry.short == ["Every update lists where it comes from and the checks it has to pass before it goes in.",
                                "Minor updates can install themselves."], "wrapped lines join their bullet")
        #expect(entry.items.count == 2)
        #expect(entry.items[0].hasSuffix("and each check it has to pass."))
        #expect(entry.paragraphs == ["Nothing to do: Burnish updates itself as usual, and automatic updates stay off until you turn them on."])
    }

    @Test func anEntryWithoutAShortVersionStillReads() {
        let entry = ReleaseHistory(markdown: markdown).entries[1]
        #expect(entry.headline == "First light.")
        #expect(entry.short.isEmpty)
        #expect(entry.items == ["**Finds updates for apps from anywhere.**"])
    }

    @Test func anUnlistedVersionFallsBackToTheNewest() {
        #expect(ReleaseHistory(markdown: markdown).entry(for: "9.9.9")?.version == "0.3.0-beta")
    }

    @Test func theRealHistoryParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/HISTORY.md")
        let history = ReleaseHistory(markdown: try String(contentsOf: url, encoding: .utf8))
        let newest = try #require(history.entries.first)
        #expect(!newest.headline.isEmpty && !newest.items.isEmpty, "every release needs a headline and items")
        #expect((3...5).contains(newest.short.count), "the short version is three to five lines")
    }
}
