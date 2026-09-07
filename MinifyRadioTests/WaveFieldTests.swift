import XCTest

final class SimplexNoiseTests: XCTestCase {

    func testRangeAndContinuity() {
        // Mismatched perm/permMod12 tables (a past bug) break continuity at
        // simplex cell borders — dense sampling catches that class of defect.
        var prev = SimplexNoise.noise2D(0, 0)
        for i in 1 ..< 4000 {
            let x = Double(i) * 0.004
            let n = SimplexNoise.noise2D(x, x * 0.7)
            XCTAssertLessThanOrEqual(abs(n), 1.0)
            XCTAssertLessThan(abs(n - prev), 0.1)
            prev = n
        }
    }

    func testPermutationTableIsPinned() {
        // The table is fixed-seed: wave art and the field must be identical on
        // every launch. If these values change, generated artwork changes too.
        XCTAssertEqual(SimplexNoise.noise2D(0.5, 0.5),    -0.6143130272544324, accuracy: 1e-12)
        XCTAssertEqual(SimplexNoise.noise2D(12.34, 56.78), 0.6377298286723214, accuracy: 1e-12)
        XCTAssertEqual(SimplexNoise.noise2D(-3.21, 0.07),  0.0313352625270243, accuracy: 1e-12)
    }
}

final class RippleTests: XCTestCase {

    func testRingFrontPeaksWhereRadiusMeetsDistance() {
        let dist = 300.0
        let ageAtFront = dist / Ripple.speed
        let atFront  = Ripple.displacement(dist: dist, age: ageAtFront,       strength: 20)
        let before   = Ripple.displacement(dist: dist, age: ageAtFront * 0.4, strength: 20)
        let after    = Ripple.displacement(dist: dist, age: ageAtFront + 0.5, strength: 20)
        XCTAssertGreaterThan(atFront, before)
        XCTAssertGreaterThan(atFront, after)
        XCTAssertGreaterThan(atFront, 5)
    }

    func testRippleFadesWithAge() {
        // Same relative front position, later in life → weaker
        let young = Ripple.displacement(dist: Ripple.speed * 0.2, age: 0.2, strength: 20)
        let old   = Ripple.displacement(dist: Ripple.speed * 1.5, age: 1.5, strength: 20)
        XCTAssertGreaterThan(young, old * 3)
    }

    func testDeadAndUnbornRipplesContributeNothing() {
        XCTAssertEqual(Ripple.displacement(dist: 100, age: -0.1, strength: 20), 0)
        XCTAssertEqual(Ripple.displacement(dist: 100, age: 4.0,  strength: 20), 0)
    }

    func testFarFromFrontIsZero() {
        // Ring at radius ~520px; a point at 100px is far behind the front
        XCTAssertEqual(Ripple.displacement(dist: 100, age: 1.0, strength: 20), 0)
    }

    func testStrengthScalesLinearly() {
        let dist = 200.0
        let age  = dist / Ripple.speed
        let a = Ripple.displacement(dist: dist, age: age, strength: 10)
        let b = Ripple.displacement(dist: dist, age: age, strength: 20)
        XCTAssertEqual(b, a * 2, accuracy: 1e-9)
    }
}

final class WaveFieldTests: XCTestCase {

    private let field = WaveField()

    func testDeterministic() {
        let a = field.displacement(x: 120, y: 340, rowFraction: 0.4, time: 12.5,
                                   amplitude: 12, shimmer: 0.5)
        let b = field.displacement(x: 120, y: 340, rowFraction: 0.4, time: 12.5,
                                   amplitude: 12, shimmer: 0.5)
        XCTAssertEqual(a.dx, b.dx)
        XCTAssertEqual(a.dy, b.dy)
    }

    func testVerticalDisplacementScalesLinearlyWithAmplitude() {
        let one = field.displacement(x: 80, y: 200, rowFraction: 0.3, time: 7,
                                     amplitude: 10, shimmer: 0.4)
        let two = field.displacement(x: 80, y: 200, rowFraction: 0.3, time: 7,
                                     amplitude: 20, shimmer: 0.4)
        XCTAssertEqual(two.dy, one.dy * 2, accuracy: 1e-9)
    }

    func testDisplacementIsBounded() {
        for i in 0 ..< 500 {
            let d = field.displacement(x: Double(i) * 7.3, y: Double(i % 40) * 18,
                                       rowFraction: Double(i % 50) / 50, time: Double(i) * 0.37,
                                       amplitude: 12, shimmer: 1.0)
            XCTAssertLessThanOrEqual(abs(d.dy), 12 * 1.5)
            XCTAssertLessThanOrEqual(abs(d.dx), field.gerstnerAmp + 1e-9)
        }
    }

    func testSpatialContinuity() {
        // One-pixel steps must not jump. The warped field's worst-case honest
        // slope is ~1.5 px/px; tearing (the mismatched-table bug) was 5–10 px.
        for i in 0 ..< 200 {
            let x = Double(i) * 3.1
            let a = field.displacement(x: x,     y: 180, rowFraction: 0.5, time: 30,
                                       amplitude: 12, shimmer: 0.5)
            let b = field.displacement(x: x + 1, y: 180, rowFraction: 0.5, time: 30,
                                       amplitude: 12, shimmer: 0.5)
            XCTAssertLessThan(abs(a.dy - b.dy), 2.5)
            XCTAssertLessThan(abs(a.dx - b.dx), 0.5)
        }
    }

    func testFieldEvolvesOverTime() {
        let a = field.displacement(x: 100, y: 100, rowFraction: 0.5, time: 0,
                                   amplitude: 12, shimmer: 0)
        let b = field.displacement(x: 100, y: 100, rowFraction: 0.5, time: 10,
                                   amplitude: 12, shimmer: 0)
        XCTAssertNotEqual(a.dy, b.dy, accuracy: 0.001)
    }

    func testWhitneyDriftSeparatesRowsOverTime() {
        // At t=0 rows share the same phase; later, rows have drifted apart
        let early0 = field.displacement(x: 100, y: 100, rowFraction: 0.0, time: 0,
                                        amplitude: 12, shimmer: 0)
        let early1 = field.displacement(x: 100, y: 100, rowFraction: 1.0, time: 0,
                                        amplitude: 12, shimmer: 0)
        XCTAssertEqual(early0.dy, early1.dy, accuracy: 1e-9)

        let late0 = field.displacement(x: 100, y: 100, rowFraction: 0.0, time: 120,
                                       amplitude: 12, shimmer: 0)
        let late1 = field.displacement(x: 100, y: 100, rowFraction: 1.0, time: 120,
                                       amplitude: 12, shimmer: 0)
        XCTAssertNotEqual(late0.dy, late1.dy, accuracy: 0.001)
    }

    func testShimmerAddsDetail() {
        let flat = field.displacement(x: 150, y: 260, rowFraction: 0.4, time: 20,
                                      amplitude: 12, shimmer: 0)
        let shim = field.displacement(x: 150, y: 260, rowFraction: 0.4, time: 20,
                                      amplitude: 12, shimmer: 1)
        XCTAssertNotEqual(flat.dy, shim.dy, accuracy: 0.0001)
        XCTAssertEqual(flat.dx, shim.dx)   // shimmer is vertical detail only
    }

    func testWarpChangesTheField() {
        var unwarped = WaveField()
        unwarped.warp = 0
        let a = field.displacement(x: 90, y: 90, rowFraction: 0.2, time: 15,
                                   amplitude: 12, shimmer: 0)
        let b = unwarped.displacement(x: 90, y: 90, rowFraction: 0.2, time: 15,
                                      amplitude: 12, shimmer: 0)
        XCTAssertNotEqual(a.dy, b.dy, accuracy: 0.0001)
    }
}
