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
        h.log(title: "Song B", station: "Classic FM")
        let data    = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(ListenHistory.self, from: data)
        XCTAssertEqual(decoded, h)
    }
}
