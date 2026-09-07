// Faithful port of simplex-noise.js (Stefan Gustavson's implementation)

import Foundation

enum SimplexNoise {

    private static let grad3: [(Int, Int, Int)] = [
        (1,1,0),(-1,1,0),(1,-1,0),(-1,-1,0),
        (1,0,1),(-1,0,1),(1,0,-1),(-1,0,-1),
        (0,1,1),(0,-1,1),(0,1,-1),(0,-1,-1)
    ]

    // Deterministic permutation table (splitmix64, fixed seed). The field and all
    // generated wave art must be identical on every launch, and permMod12 must
    // derive from this same table or gradient hashing breaks at cell borders.
    private static let perm: [Int] = {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        let p = (0..<256).map { _ in Int(next() % 256) }
        return (0..<512).map { p[$0 & 255] }
    }()

    private static let permMod12: [Int] = perm.map { $0 % 12 }

    private static func dot(_ g: (Int, Int, Int), _ x: Double, _ y: Double) -> Double {
        Double(g.0) * x + Double(g.1) * y
    }

    /// 2D simplex noise — faithful port of simplex-noise.js noise2D()
    /// Returns value in [-1, 1]
    static func noise2D(_ xin: Double, _ yin: Double) -> Double {
        let F2 = 0.5 * (sqrt(3.0) - 1.0)
        let G2 = (3.0 - sqrt(3.0)) / 6.0

        let s = (xin + yin) * F2
        let i = Int(floor(xin + s))
        let j = Int(floor(yin + s))
        let t = Double(i + j) * G2
        let X0 = Double(i) - t
        let Y0 = Double(j) - t
        let x0 = xin - X0
        let y0 = yin - Y0

        let i1: Int, j1: Int
        if x0 > y0 { i1 = 1; j1 = 0 }
        else        { i1 = 0; j1 = 1 }

        let x1 = x0 - Double(i1) + G2
        let y1 = y0 - Double(j1) + G2
        let x2 = x0 - 1.0 + 2.0 * G2
        let y2 = y0 - 1.0 + 2.0 * G2

        let ii = i & 255
        let jj = j & 255
        let gi0 = permMod12[ii + perm[jj]]
        let gi1 = permMod12[ii + i1 + perm[jj + j1]]
        let gi2 = permMod12[ii + 1 + perm[jj + 1]]

        var n0: Double = 0
        var t0 = 0.5 - x0 * x0 - y0 * y0
        if t0 >= 0 { t0 *= t0; n0 = t0 * t0 * dot(grad3[gi0], x0, y0) }

        var n1: Double = 0
        var t1 = 0.5 - x1 * x1 - y1 * y1
        if t1 >= 0 { t1 *= t1; n1 = t1 * t1 * dot(grad3[gi1], x1, y1) }

        var n2: Double = 0
        var t2 = 0.5 - x2 * x2 - y2 * y2
        if t2 >= 0 { t2 *= t2; n2 = t2 * t2 * dot(grad3[gi2], x2, y2) }

        return 70.0 * (n0 + n1 + n2)
    }
}
