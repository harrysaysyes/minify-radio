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
