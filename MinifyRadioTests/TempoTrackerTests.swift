import XCTest

final class TempoTrackerTests: XCTestCase {

    func testLocksOntoSteadyBeat() {
        var t = TempoTracker()
        for i in 0 ..< 8 { t.registerOnset(at: Double(i) * 0.5) }
        XCTAssertTrue(t.isLocked)
        XCTAssertEqual(t.period ?? 0, 0.5, accuracy: 0.01)
    }

    func testPredictsNextBeatAccurately() {
        var t = TempoTracker()
        for i in 0 ..< 8 { t.registerOnset(at: Double(i) * 0.5) }
        // Last onset at 3.5 — the next beat should be predicted near 4.0
        XCTAssertEqual(t.nextBeat ?? 0, 4.0, accuracy: 0.05)
    }

    func testFoldsDoubleTimeIntoBeatRange() {
        var t = TempoTracker()
        for i in 0 ..< 12 { t.registerOnset(at: Double(i) * 0.25) }   // hats at 240/min
        XCTAssertTrue(t.isLocked)
        XCTAssertEqual(t.period ?? 0, 0.5, accuracy: 0.01)            // folded to 120 bpm
    }

    func testErraticOnsetsNeverLock() {
        var t = TempoTracker()
        let times = [0.0, 0.41, 1.3, 1.62, 2.9, 3.05, 4.4, 5.71]
        for time in times { t.registerOnset(at: time) }
        XCTAssertFalse(t.isLocked)
    }

    func testFollowsTempoDrift() {
        var t = TempoTracker()
        var time = 0.0
        var interval = 0.5
        for _ in 0 ..< 20 {
            t.registerOnset(at: time)
            time += interval
            interval += 0.005          // gradual slow-down toward 0.6
        }
        XCTAssertTrue(t.isLocked)
        XCTAssertEqual(t.period ?? 0, interval, accuracy: 0.06)
    }

    func testConsumeBeatFiresOncePerPeriodWithLead() {
        var t = TempoTracker()
        for i in 0 ..< 8 { t.registerOnset(at: Double(i) * 0.5) }   // last onset 3.5, next beat 4.0
        XCTAssertFalse(t.consumeBeat(at: 3.8,  lead: 0.05))          // too early
        XCTAssertTrue(t.consumeBeat(at: 3.96, lead: 0.05))           // 3.96 + 0.05 ≥ 4.0
        XCTAssertFalse(t.consumeBeat(at: 3.97, lead: 0.05))          // already consumed this beat
        XCTAssertTrue(t.consumeBeat(at: 4.5,  lead: 0.05))           // the following beat
    }

    func testStopsPredictingAfterSilence() {
        var t = TempoTracker()
        for i in 0 ..< 8 { t.registerOnset(at: Double(i) * 0.5) }    // last onset 3.5
        // Consume beats until silence exceeds 4 periods past the last onset
        _ = t.consumeBeat(at: 4.0, lead: 0)
        _ = t.consumeBeat(at: 4.5, lead: 0)
        _ = t.consumeBeat(at: 5.0, lead: 0)
        XCTAssertFalse(t.consumeBeat(at: 6.1, lead: 0))              // > 3.5 + 4×0.5
    }

    func testResetClearsLock() {
        var t = TempoTracker()
        for i in 0 ..< 8 { t.registerOnset(at: Double(i) * 0.5) }
        t.reset()
        XCTAssertFalse(t.isLocked)
        XCTAssertNil(t.period)
        XCTAssertNil(t.nextBeat)
    }
}
