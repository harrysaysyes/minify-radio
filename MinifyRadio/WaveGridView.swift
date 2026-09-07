// Native Swift wave grid — faithful port of wave-grid.js
// Full physics: per-point spring state, directional touch push, spring restoration + friction.
// Uses SwiftUI Canvas + TimelineView for frame-driven animation.
// Radio addition: audioEnergy property modulates wave amplitude.

import SwiftUI

// MARK: - Config (mirrors wave-grid.js config object exactly)

private enum WaveCfg {
    static let xGap: Double            = 12
    static let yGap: Double            = 18
    static let xScale: Double          = 0.002
    static let yScale: Double          = 0.0015
    static let speedX: Double          = 0.03
    static let speedY: Double          = 0.015
    static let angleGain: Double       = 6
    static let waveAmpY: Double        = 12
    // Touch interaction
    static let influenceRadius: Double = 350
    static let cursorStrength: Double  = 2.0
    static let velocityScale: Double   = 0.35
    static let pointerLerp: Double     = 0.2
    static let cursorXScale: Double    = 0.3
    static let maxCursorMove: Double   = 45
    // Spring physics
    static let tension: Double         = 0.035
    static let friction: Double        = 0.88
    // Audio reactivity multiplier (matches wave-grid.js audioAmplitudeMultiplier)
    static let audioAmpMultiplier: Double = 4.0
}

// MARK: - Physics state (class so Canvas closure can mutate it)

final class WavePhysics: ObservableObject {

    struct GridPoint {
        var baseX, baseY: Double
        var cx:  Double = 0
        var cy:  Double = 0
        var cvx: Double = 0
        var cvy: Double = 0
    }

    private(set) var points: [GridPoint] = []
    private(set) var rows = 0
    private(set) var cols = 0

    private var time:            Double = 0
    private var lastTime:        Double = 0
    private(set) var initializedSize: CGSize = .zero

    // Smoothed pointer state
    private var pxSmooth: Double = 0
    private var pySmooth: Double = 0
    private var pvx:      Double = 0
    private var pvy:      Double = 0
    private var pActive          = false

    private var rowBuf:      [CGPoint] = []
    private var smoothedBuf: [CGPoint] = []
    private var allSmoothed: [CGPoint] = []

    /// Set externally by RadioEngine. Not @Published — avoids SwiftUI redraws.
    var bassEnergy:   Double = 0
    var midEnergy:    Double = 0
    var trebleEnergy: Double = 0

    private var smoothedAmpY:    Double = WaveCfg.waveAmpY
    private var smoothedXStretch: Double = 0

    // MARK: Grid init

    func prepare(size: CGSize) {
        guard size.width > 0, size.height > 0, size != initializedSize else { return }
        initializedSize = size

        let padX = 4  // extra columns each side
        let padY = 3  // extra rows each side
        let c = Int(ceil(size.width  / WaveCfg.xGap)) + 1 + padX * 2
        let r = Int(ceil(size.height / WaveCfg.yGap)) + 1 + padY * 2
        cols = c
        rows = r

        var pts = [GridPoint]()
        pts.reserveCapacity(r * c)
        for row in 0..<r {
            for col in 0..<c {
                pts.append(GridPoint(
                    baseX: Double(col - padX) * WaveCfg.xGap,
                    baseY: Double(row - padY) * WaveCfg.yGap
                ))
            }
        }
        points      = pts
        rowBuf      = [CGPoint](repeating: .zero, count: c)
        smoothedBuf = [CGPoint](repeating: .zero, count: c)
        allSmoothed = [CGPoint](repeating: .zero, count: r * c)
    }

    // MARK: Physics update

    func update(currentTime: Double, size: CGSize) {
        prepare(size: size)
        guard !points.isEmpty else { return }

        if lastTime == 0 { lastTime = currentTime }
        let rawDelta   = currentTime - lastTime
        let dtSeconds  = min(max(rawDelta, 1.0 / 120.0), 1.0 / 30.0)
        lastTime       = currentTime
        time          += dtSeconds

        let dtScale = dtSeconds * 60.0

        for i in 0..<points.count {
            let bx = points[i].baseX
            let by = points[i].baseY

            if pActive {
                let dx   = bx - pxSmooth
                let dy   = by - pySmooth
                let dist = (dx*dx + dy*dy).squareRoot()

                if dist < WaveCfg.influenceRadius {
                    let velMag          = (pvx*pvx + pvy*pvy).squareRoot()
                    let minDist         = max(dist, WaveCfg.yGap * 0.5)
                    let dot             = dx * pvx + dy * pvy
                    let alignment       = dot / (velMag > 0 ? velMag : 1)
                    let alignmentFactor = max(0.0, alignment / minDist)
                    let normalizedDist  = dist / WaveCfg.influenceRadius
                    let falloff         = pow(1.0 - normalizedDist, 2.0)
                    let impulse         = falloff * alignmentFactor * WaveCfg.cursorStrength
                    points[i].cvx += pvx * impulse * WaveCfg.velocityScale
                    points[i].cvy += pvy * impulse * WaveCfg.velocityScale
                }
            }

            points[i].cvx += (-points[i].cx) * WaveCfg.tension
            points[i].cvy += (-points[i].cy) * WaveCfg.tension
            points[i].cvx *= WaveCfg.friction
            points[i].cvy *= WaveCfg.friction
            points[i].cx  += points[i].cvx * dtScale
            points[i].cy  += points[i].cvy * dtScale

            let m = WaveCfg.maxCursorMove
            points[i].cx = max(-m, min(m, points[i].cx))
            points[i].cy = max(-m, min(m, points[i].cy))
        }
    }

    // MARK: Beat / connect pulse — radial shockwave from screen centre

    func triggerBeatPulse() {
        guard !points.isEmpty, initializedSize != .zero else { return }
        let cx      = initializedSize.width  / 2
        let cy      = initializedSize.height / 2
        let maxR    = max(cx, cy) * 1.3
        let strength = 9.0

        for i in 0..<points.count {
            let dx   = points[i].baseX - cx
            let dy   = points[i].baseY - cy
            let dist = (dx*dx + dy*dy).squareRoot()
            guard dist > 0 else { continue }
            let falloff = pow(max(0.0, 1.0 - dist / maxR), 1.5)
            let nx = dx / dist
            let ny = dy / dist
            points[i].cvx += nx * strength * falloff
            points[i].cvy += ny * strength * falloff
        }
    }

    // MARK: Draw

    func draw(ctx: GraphicsContext, size: CGSize, lineColor: Color, bgColor: Color) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bgColor))
        guard !points.isEmpty else { return }

        // Bass → wave height
        let bassResponse = pow(max(0, bassEnergy), 1.5)
        let effAmpY      = WaveCfg.waveAmpY * (1.0 + bassResponse * WaveCfg.audioAmpMultiplier)
        smoothedAmpY    += (effAmpY - smoothedAmpY) * 0.12

        // Treble → subtle compression toward screen centre
        let trebleResponse = pow(max(0, trebleEnergy), 1.2)
        smoothedXStretch  += (trebleResponse * 0.06 - smoothedXStretch) * 0.15
        let screenCentreX  = size.width / 2

        let nc = cols
        guard nc > 0 else { return }

        // Phase 1: compute all row positions into allSmoothed
        for row in 0..<rows {
            for col in 0..<cols {
                let i = row * cols + col
                guard i < points.count else { break }
                let p = points[i]
                let noise = SimplexNoise.noise2D(
                    p.baseX * WaveCfg.xScale + time * WaveCfg.speedX,
                    p.baseY * WaveCfg.yScale + time * WaveCfg.speedY
                )
                let wy  = sin(WaveCfg.angleGain * noise) * smoothedAmpY
                let fx  = p.baseX + p.cx * WaveCfg.cursorXScale
                let fxS = screenCentreX + (fx - screenCentreX) * (1.0 - smoothedXStretch)
                rowBuf[col] = CGPoint(x: fxS, y: p.baseY + wy + p.cy)
            }
            // Bézier smoothing pass
            let base = row * nc
            smoothedBuf[0] = rowBuf[0]
            if nc > 1 { smoothedBuf[nc - 1] = rowBuf[nc - 1] }
            for k in 1..<(nc - 1) {
                smoothedBuf[k] = CGPoint(
                    x: (rowBuf[k - 1].x + 2.0 * rowBuf[k].x + rowBuf[k + 1].x) / 4.0,
                    y: (rowBuf[k - 1].y + 2.0 * rowBuf[k].y + rowBuf[k + 1].y) / 4.0
                )
            }
            for k in 0..<nc { allSmoothed[base + k] = smoothedBuf[k] }
        }

        // Phase 2: enforce row ordering — no row may cross its neighbour
        let gap = 0.5
        // Top-down: each row's y must be >= previous row's y
        for row in 1..<rows {
            let prev = (row - 1) * nc
            let curr = row * nc
            for k in 0..<nc {
                allSmoothed[curr + k].y = max(allSmoothed[curr + k].y, allSmoothed[prev + k].y + gap)
            }
        }
        // Bottom-up: each row's y must be <= next row's y
        for row in stride(from: rows - 2, through: 0, by: -1) {
            let next = (row + 1) * nc
            let curr = row * nc
            for k in 0..<nc {
                allSmoothed[curr + k].y = min(allSmoothed[curr + k].y, allSmoothed[next + k].y - gap)
            }
        }

        // Phase 3: draw — transparency layer prevents alpha accumulation where lines converge
        ctx.withCGContext { cg in
            let uiColor = UIColor(lineColor)
            var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
            uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            cg.setAlpha(a)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.setStrokeColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            cg.setLineWidth(1)
            cg.setLineJoin(.round)
            cg.setLineCap(.round)

            for row in 0..<rows {
                let base = row * nc
                cg.beginPath()
                cg.move(to: allSmoothed[base])
                if nc > 2 {
                    for i in 1..<(nc - 1) {
                        let ctrl = allSmoothed[base + i]
                        let mid  = CGPoint(x: (allSmoothed[base + i].x + allSmoothed[base + i + 1].x) / 2,
                                          y: (allSmoothed[base + i].y + allSmoothed[base + i + 1].y) / 2)
                        cg.addQuadCurve(to: mid, control: ctrl)
                    }
                }
                cg.addLine(to: allSmoothed[base + nc - 1])
                cg.strokePath()
            }
            cg.endTransparencyLayer()
        }
    }

    // MARK: Touch input

    func pointerMoved(to location: CGPoint) {
        let rawX = Double(location.x)
        let rawY = Double(location.y)

        let prevSmX = pxSmooth
        let prevSmY = pySmooth

        pxSmooth += (rawX - pxSmooth) * WaveCfg.pointerLerp
        pySmooth += (rawY - pySmooth) * WaveCfg.pointerLerp

        var vx = pxSmooth - prevSmX
        var vy = pySmooth - prevSmY

        let mag = (vx*vx + vy*vy).squareRoot()
        if mag > 100 {
            let scale = 100.0 / mag
            vx *= scale
            vy *= scale
        }
        pvx     = vx
        pvy     = vy
        pActive = true
    }

    func pointerEnded() {
        pActive = false
        pvx = 0
        pvy = 0
    }
}

// MARK: - View

struct WaveGridView: View {
    var accent:     Color = Color(white: 0.4)
    var background: Color = Color(white: 0.039)

    @ObservedObject var physics: WavePhysics

    var onTap: (() -> Void)? = nil

    @State private var touchStart: CGPoint? = nil

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                physics.update(
                    currentTime: timeline.date.timeIntervalSinceReferenceDate,
                    size: size
                )
                physics.draw(
                    ctx: ctx,
                    size: size,
                    lineColor: accent.opacity(0.42),
                    bgColor: background
                )
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if touchStart == nil { touchStart = value.location }
                        physics.pointerMoved(to: value.location)
                    }
                    .onEnded { value in
                        physics.pointerEnded()
                        if let start = touchStart {
                            let dx = value.location.x - start.x
                            let dy = value.location.y - start.y
                            if hypot(dx, dy) <= 14 { onTap?() }
                        }
                        touchStart = nil
                    }
            )
        }
        .ignoresSafeArea()
    }
}

#Preview {
    WaveGridView(
        accent:     Color(red: 0.58, green: 0.64, blue: 0.72),
        background: Color(white: 0.039),
        physics:    WavePhysics()
    )
}
