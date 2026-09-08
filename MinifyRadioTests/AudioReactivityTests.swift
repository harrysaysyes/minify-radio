import XCTest

final class EnvelopeFollowerTests: XCTestCase {

    func testAttackReaches63PercentAfterOneTimeConstant() {
        var env = EnvelopeFollower(attack: 0.1, release: 0.5)
        let dt = 1.0 / 60.0
        var value = 0.0
        for _ in 0 ..< Int(0.1 / dt) { value = env.process(1.0, dt: dt) }
        XCTAssertEqual(value, 0.63, accuracy: 0.07)
    }

    func testReleaseIsSlowerThanAttack() {
        var env = EnvelopeFollower(attack: 0.02, release: 0.5)
        let dt = 1.0 / 60.0
        for _ in 0 ..< 30 { _ = env.process(1.0, dt: dt) }   // fully risen
        var value = 1.0
        for _ in 0 ..< 6 { value = env.process(0.0, dt: dt) }  // 0.1 s of release
        XCTAssertGreaterThan(value, 0.7)   // long release: still mostly up after 0.1 s
    }

    func testSettlesNearInput() {
        var env = EnvelopeFollower(attack: 0.05, release: 0.2)
        var value = 0.0
        for _ in 0 ..< 120 { value = env.process(0.8, dt: 1.0 / 60.0) }
        XCTAssertEqual(value, 0.8, accuracy: 0.01)
    }

    func testResetJumpsImmediately() {
        var env = EnvelopeFollower(attack: 0.1, release: 0.5)
        env.reset(to: 0.4)
        XCTAssertEqual(env.process(0.4, dt: 1.0 / 60.0), 0.4, accuracy: 0.001)
    }
}

final class AdaptiveNormalizerTests: XCTestCase {

    private let dt = 1.0 / 20.0   // tap-callback cadence

    func testConstantSignalSettlesAtHalf() {
        var norm = AdaptiveNormalizer(halflife: 1.0, gate: 1e-4)
        var out = 0.0
        for _ in 0 ..< 400 { out = norm.normalize(0.5, dt: dt) }
        XCTAssertEqual(out, 0.5, accuracy: 0.05)
    }

    func testQuietStationGetsSameRangeAsLoudStation() {
        var loud  = AdaptiveNormalizer(halflife: 1.0, gate: 1e-4)
        var quiet = AdaptiveNormalizer(halflife: 1.0, gate: 1e-4)
        var loudOut = 0.0, quietOut = 0.0
        for _ in 0 ..< 400 {
            loudOut  = loud.normalize(0.9,  dt: dt)
            quietOut = quiet.normalize(0.01, dt: dt)
        }
        XCTAssertEqual(loudOut, quietOut, accuracy: 0.05)
    }

    func testTransientAboveRecentAverageApproachesOne() {
        var norm = AdaptiveNormalizer(halflife: 2.0, gate: 1e-4)
        for _ in 0 ..< 400 { _ = norm.normalize(0.2, dt: dt) }
        XCTAssertGreaterThan(norm.normalize(0.9, dt: dt), 0.9)
    }

    func testSilenceIsGatedToZero() {
        var norm = AdaptiveNormalizer(halflife: 1.0, gate: 1e-4)
        for _ in 0 ..< 100 { _ = norm.normalize(0.5, dt: dt) }
        XCTAssertEqual(norm.normalize(0.00001, dt: dt), 0)
    }
}

final class TransitionDetectorTests: XCTestCase {

    private let dt = 1.0 / 20.0

    private func run(_ det: inout TransitionDetector, energy: Double, seconds: Double) -> Int {
        var fires = 0
        for _ in 0 ..< Int(seconds / dt) {
            if det.process(energy: energy, dt: dt) { fires += 1 }
        }
        return fires
    }

    func testSteadyMusicNeverFires() {
        var det = TransitionDetector()
        XCTAssertEqual(run(&det, energy: 0.5, seconds: 60), 0)
    }

    func testDipThenRecoveryFiresOnce() {
        var det = TransitionDetector()
        _ = run(&det, energy: 0.5, seconds: 30)     // establish baseline
        _ = run(&det, energy: 0.02, seconds: 1.5)   // gap between tracks
        XCTAssertEqual(run(&det, energy: 0.5, seconds: 5), 1)   // fires at recovery
    }

    func testBriefDipDoesNotFire() {
        var det = TransitionDetector()
        _ = run(&det, energy: 0.5, seconds: 30)
        _ = run(&det, energy: 0.02, seconds: 0.3)   // just a beat of silence
        XCTAssertEqual(run(&det, energy: 0.5, seconds: 5), 0)
    }

    func testRefractoryLimitsFireRate() {
        var det = TransitionDetector()
        _ = run(&det, energy: 0.5, seconds: 30)
        var fires = 0
        for _ in 0 ..< 3 {                          // three dips ~7s apart
            _ = run(&det, energy: 0.02, seconds: 1.5)
            fires += run(&det, energy: 0.5, seconds: 5)
        }
        XCTAssertEqual(fires, 1)                    // refractory swallows the rest
    }

    func testSilenceFromStartNeverFires() {
        var det = TransitionDetector()
        XCTAssertEqual(run(&det, energy: 0.0001, seconds: 60), 0)
        XCTAssertEqual(run(&det, energy: 0.5, seconds: 5), 0)   // music starting isn't a transition
    }
}

final class OnsetDetectorTests: XCTestCase {

    private let dt = 1.0 / 20.0

    /// Kick pattern: sharp energy rise every half second over a quiet bed.
    func testDetectsPeriodicKicks() {
        var det = OnsetDetector(sensitivity: 2.0, refractory: 0.15, minFlux: 0.01)
        var onsets = 0
        for frame in 0 ..< 200 {                      // 10 seconds
            let isKickFrame = frame % 10 == 0         // every 0.5 s
            let energy = isKickFrame ? 0.8 : 0.1
            if det.process(energy: energy, dt: dt) { onsets += 1 }
        }
        XCTAssertGreaterThanOrEqual(onsets, 15)
        XCTAssertLessThanOrEqual(onsets, 20)
    }

    func testSteadyEnergyProducesNoOnsets() {
        var det = OnsetDetector(sensitivity: 2.0, refractory: 0.15, minFlux: 0.01)
        var onsets = 0
        for _ in 0 ..< 200 {
            if det.process(energy: 0.6, dt: dt) { onsets += 1 }
        }
        XCTAssertLessThanOrEqual(onsets, 1)   // at most the very first rise
    }

    func testRefractoryPreventsDoubleTriggers() {
        var det = OnsetDetector(sensitivity: 2.0, refractory: 0.3, minFlux: 0.01)
        var onsets = 0
        // Two sharp rises 0.1 s apart — second falls inside the refractory window
        let energies = [0.1, 0.9, 0.1, 0.9, 0.1, 0.1, 0.1, 0.1]
        for e in energies {
            if det.process(energy: e, dt: 0.05) { onsets += 1 }
        }
        XCTAssertEqual(onsets, 1)
    }

    func testSilenceNeverTriggers() {
        var det = OnsetDetector(sensitivity: 2.0, refractory: 0.15, minFlux: 0.01)
        var onsets = 0
        for _ in 0 ..< 200 {
            if det.process(energy: 0.0001, dt: dt) { onsets += 1 }
        }
        XCTAssertEqual(onsets, 0)
    }
}
