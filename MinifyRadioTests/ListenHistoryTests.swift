import XCTest

final class ListenHistoryTests: XCTestCase {

    func testLogsEntries() {
        var h = ListenHistory()
        h.log(title: "Song A", station: "Reprezent")
        h.log(title: "Song B", station: "Reprezent")
        XCTAssertEqual(h.entries.map(\.title), ["Song A", "Song B"])
        XCTAssertEqual(h.entries.first?.station, "Reprezent")
    }

    func testDedupsConsecutiveRepeats() {
        var h = ListenHistory()
        h.log(title: "Song A", station: "Reprezent")
        h.log(title: "Song A", station: "Reprezent")   // ICY often repeats titles
        XCTAssertEqual(h.entries.count, 1)
    }

    func testSameTitleLogsAgainAfterADifferentTrack() {
        var h = ListenHistory()
        h.log(title: "Song A", station: "Reprezent")
        h.log(title: "Song B", station: "Reprezent")
        h.log(title: "Song A", station: "Reprezent")   // played again later
        XCTAssertEqual(h.entries.count, 3)
    }

    func testSameTitleOnDifferentStationIsLogged() {
        var h = ListenHistory()
        h.log(title: "Song A", station: "Reprezent")
        h.log(title: "Song A", station: "Worldwide FM")
        XCTAssertEqual(h.entries.count, 2)
    }

    func testIgnoresEmptyTitles() {
        var h = ListenHistory()
        h.log(title: "   ", station: "Reprezent")
        XCTAssertTrue(h.entries.isEmpty)
    }

    func testCapsAtCapacityKeepingNewest() {
        var h = ListenHistory()
        for i in 0 ..< (ListenHistory.capacity + 25) {
            h.log(title: "Song \(i)", station: "Reprezent")
        }
        XCTAssertEqual(h.entries.count, ListenHistory.capacity)
        XCTAssertEqual(h.entries.last?.title, "Song \(ListenHistory.capacity + 24)")
        XCTAssertEqual(h.entries.first?.title, "Song 25")
    }

    func testCodableRoundtrip() throws {
        var h = ListenHistory()
        h.log(title: "Song A", station: "Reprezent")
        h.log(title: "Song B", station: "Classic FM", link: URL(string: "https://music.apple.com/x"))
        let data    = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(ListenHistory.self, from: data)
        XCTAssertEqual(decoded, h)
    }

    func testDecodesLegacyEntriesWithoutLinks() throws {
        // History persisted before links existed must still load
        let legacy = #"{"entries":[{"id":"11111111-1111-1111-1111-111111111111","date":700000000,"station":"Reprezent","title":"Song A"}]}"#
        let decoded = try JSONDecoder().decode(ListenHistory.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertNil(decoded.entries[0].link)
    }

    func testLogStoresLinkWhenKnownUpFront() {
        var h = ListenHistory()
        let url = URL(string: "https://music.apple.com/track/1")
        h.log(title: "Song A", station: "Reprezent", link: url)
        XCTAssertEqual(h.entries.first?.link, url)
    }

    func testAttachLinkFillsTheMatchingEntry() {
        var h = ListenHistory()
        h.log(title: "Song A", station: "Reprezent")
        h.log(title: "Song B", station: "Reprezent")
        let url = URL(string: "https://music.apple.com/track/a")!
        h.attachLink(url, title: "Song A", station: "Reprezent")
        XCTAssertEqual(h.entries[0].link, url)
        XCTAssertNil(h.entries[1].link)
    }

    func testAttachLinkTargetsTheLatestLinklessOccurrence() {
        var h = ListenHistory()
        let old = URL(string: "https://music.apple.com/old")!
        h.log(title: "Song A", station: "Reprezent", link: old)
        h.log(title: "Song B", station: "Reprezent")
        h.log(title: "Song A", station: "Reprezent")          // played again, no link yet
        let new = URL(string: "https://music.apple.com/new")!
        h.attachLink(new, title: "Song A", station: "Reprezent")
        XCTAssertEqual(h.entries[0].link, old)                 // earlier entry untouched
        XCTAssertEqual(h.entries[2].link, new)
    }

    func testAttachLinkWithNoMatchDoesNothing() {
        var h = ListenHistory()
        h.log(title: "Song A", station: "Reprezent")
        h.attachLink(URL(string: "https://x")!, title: "Other Song", station: "Reprezent")
        XCTAssertNil(h.entries[0].link)
    }
}
