import Foundation

/// The wave field: pure math mapping (position, row, time, energy) → displacement.
///
/// Three ideas layered on the original single-octave noise:
/// - domain warping (Quilez): the field is sampled at coordinates displaced by
///   its own value, turning flat wobble into marbled, flowing motion
/// - incremental drift (Whitney): each row's phase advances at a rate scaled by
///   its position, so idle waves slowly drift through alignment and dissolution
/// - Gerstner-style horizontal displacement: lines bunch toward crests, which is
///   what makes waves read as water instead of jelly
struct WaveField {

    var xScale = 0.002
    var yScale = 0.0015
    var speedX = 0.022
    var speedY = 0.011

    /// Warp strength in noise-space units.
    var warp = 0.35

    /// Whitney drift rate: row phase advances at rowFraction × drift × time.
    var drift = 0.012

    /// Horizontal bunching.
    var gerstnerAmp        = 7.0
    var gerstnerWavelength = 240.0
    var gerstnerSpeed      = 0.55

    /// Fine treble octave, as a fraction of amplitude — a sparkle, not jitter.
    var shimmerAmp = 0.12

    /// Keeps the sin(gain·noise) fold of the original look.
    var angleGain = 6.0

    func displacement(x: Double, y: Double, rowFraction: Double, time: Double,
                      amplitude: Double, shimmer: Double) -> (dx: Double, dy: Double) {
        let u = x * xScale + time * speedX + rowFraction * drift * time
        let v = y * yScale + time * speedY

        func fbm(_ a: Double, _ b: Double) -> Double {
            SimplexNoise.noise2D(a, b)
                + 0.5 * SimplexNoise.noise2D(a * 2.03 + 17.1, b * 2.11 + 9.2)
        }

        let q = fbm(u + 5.2, v + 1.3)
        let n = fbm(u + warp * q, v + warp * q) / 1.5

        var dy = sin(angleGain * n) * amplitude

        if shimmer > 0.001 {
            dy += SimplexNoise.noise2D(u * 6.7 + time * 0.6, v * 6.1)
                * amplitude * shimmerAmp * shimmer
        }

        let k  = 2.0 * .pi / gerstnerWavelength
        let dx = gerstnerAmp * cos(k * x + time * gerstnerSpeed + rowFraction * 2.4)
        return (dx, dy)
    }
}

/// A beat ripple: an expanding ring, like a drop hitting water. Each beat spawns
/// its own ring with its own birth time; rings coexist and superpose, so fast
/// music gets one visible reaction per hit instead of one smeared excursion.
enum Ripple {

    /// Ring expansion speed, px/s.
    static let speed = 520.0

    /// Ring front thickness, px.
    static let width = 90.0

    /// Displacement magnitude at `dist` from the ripple origin, `age` seconds
    /// after the beat. Zero before birth and after ~3 s of decay.
    static func displacement(dist: Double, age: Double, strength: Double,
                             speed: Double = Ripple.speed,
                             width: Double = Ripple.width) -> Double {
        guard age >= 0, age < 3 else { return 0 }
        let front = (dist - age * speed) / width
        guard abs(front) < 3 else { return 0 }
        return strength * exp(-front * front) * exp(-age * 1.8)
    }
}
