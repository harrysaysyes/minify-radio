import Foundation

// Pure DSP building blocks for musical wave reactivity. No I/O, no Apple
// frameworks — everything here is unit-tested with synthetic signals.

/// Classic attack/release envelope: rises fast, falls slow. Time constants are
/// seconds to reach ~63% of a step change.
struct EnvelopeFollower {

    let attack:  Double
    let release: Double
    private(set) var value: Double = 0

    mutating func process(_ input: Double, dt: Double) -> Double {
        let tau   = input > value ? attack : release
        let alpha = 1 - exp(-dt / max(tau, 1e-6))
        value += (input - value) * alpha
        return value
    }

    mutating func reset(to newValue: Double) {
        value = newValue
    }
}

/// Maps a band's energy to 0…1 relative to its own recent average, so a quiet
/// classical stream and a loud club stream both use the full expressive range.
/// A steady signal reads 0.5; transients above the recent average push toward 1.
struct AdaptiveNormalizer {

    let halflife: Double   // seconds for the rolling reference to move halfway
    let gate:     Double   // absolute level below which output is 0 (idle noise)
    private(set) var reference: Double = 0

    mutating func normalize(_ x: Double, dt: Double) -> Double {
        reference += (x - reference) * (1 - exp(-dt * M_LN2 / max(halflife, 1e-6)))
        guard x > gate, reference > gate else { return 0 }
        return min(1, x / (2 * reference))
    }
}

/// Predictive beat tracker. Onset detection is always reactive — the pulse fires
/// after the beat was heard, so it lands late by detection + output latency.
/// This tracker listens to onset times, estimates tempo (folding double-time
/// into beat range) and phase-locks a beat grid to them. Once confident, beats
/// can be *predicted* and fired slightly early to cancel known latency; erratic
/// material never locks and stays reactive.
struct TempoTracker {

    let minPeriod:     Double
    let maxPeriod:     Double
    let lockThreshold: Double

    private(set) var period:     Double?
    private(set) var confidence: Double = 0
    private(set) var nextBeat:   Double?
    private var lastOnset: Double?
    private var intervals: [Double] = []

    init(minPeriod: Double = 0.3, maxPeriod: Double = 1.0, lockThreshold: Double = 0.6) {
        self.minPeriod     = minPeriod
        self.maxPeriod     = maxPeriod
        self.lockThreshold = lockThreshold
    }

    var isLocked: Bool { confidence >= lockThreshold && period != nil }

    mutating func registerOnset(at time: Double) {
        defer { lastOnset = time }
        guard let last = lastOnset else { return }

        var interval = time - last
        guard interval > 0.05, interval < 4.0 else { return }
        while interval > maxPeriod { interval /= 2 }
        while interval < minPeriod { interval *= 2 }

        intervals.append(interval)
        if intervals.count > 8 { intervals.removeFirst() }
        guard intervals.count >= 4 else { return }

        let median = intervals.sorted()[intervals.count / 2]
        period = median

        // Confidence falls with interval jitter relative to the median.
        let meanDeviation = intervals.map { abs($0 - median) / median }
            .reduce(0, +) / Double(intervals.count)
        confidence = max(0, 1 - meanDeviation * 6)

        // Phase-lock: nudge the predicted grid halfway toward this onset.
        if isLocked, let predicted = nextBeat {
            var error = (time - predicted).truncatingRemainder(dividingBy: median)
            if error >  median / 2 { error -= median }
            if error < -median / 2 { error += median }
            var beat = predicted + error * 0.5
            while beat <= time { beat += median }
            nextBeat = beat
        } else {
            nextBeat = time + median
        }
    }

    /// Consume the next predicted beat if it is due at `time` (+ `lead` seconds of
    /// early-fire to cover output latency). Predictions stop after ~4 silent periods.
    mutating func consumeBeat(at time: Double, lead: Double) -> Bool {
        guard isLocked, let p = period, let beat = nextBeat,
              let last = lastOnset, time - last < p * 4,
              time + lead >= beat else { return false }
        nextBeat = beat + p
        return true
    }

    mutating func reset() {
        period     = nil
        confidence = 0
        nextBeat   = nil
        lastOnset  = nil
        intervals.removeAll()
    }
}

/// Spectral-flux onset detector: fires when a band's energy *rises* sharply
/// relative to its recent rises. Detects beats in loud and quiet passages alike,
/// because the threshold adapts to the stream.
struct OnsetDetector {

    let sensitivity: Double   // flux must exceed sensitivity × rolling mean flux
    let refractory:  Double   // minimum seconds between onsets
    let minFlux:     Double   // absolute floor so silence never triggers

    private var prevEnergy: Double = 0
    private var meanFlux:   Double = 0
    private var sinceOnset: Double = .greatestFiniteMagnitude

    init(sensitivity: Double, refractory: Double, minFlux: Double) {
        self.sensitivity = sensitivity
        self.refractory  = refractory
        self.minFlux     = minFlux
    }

    mutating func process(energy: Double, dt: Double) -> Bool {
        let flux = max(0, energy - prevEnergy)
        prevEnergy  = energy
        sinceOnset += dt

        let isOnset = flux > max(sensitivity * meanFlux, minFlux)
            && sinceOnset >= refractory

        // Update the rolling mean after the comparison, so a beat is judged
        // against the stream's history, not against itself.
        meanFlux += (flux - meanFlux) * (1 - exp(-dt * M_LN2 / 1.5))

        if isOnset { sinceOnset = 0 }
        return isOnset
    }
}
