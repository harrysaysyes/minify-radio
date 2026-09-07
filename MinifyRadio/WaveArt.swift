// Static wave-grid renderer — same field math as WaveGridView, frozen to one frame.
// CarPlay can't draw custom UI, but its templates accept images: this is where the
// brand lives on the car screen (grid tiles) and the lock screen (Now Playing artwork).

import UIKit
import MediaPlayer

enum WaveArt {

    private static var tileCache    = [String: UIImage]()
    private static var artworkCache = [String: MPMediaItemArtwork]()

    /// Rounded thumbnail for CarPlay list rows. Bolder than the phone background —
    /// a handful of thick waves reads cleanly at row size, dense thin lines don't.
    static func tile(for station: Station, side: CGFloat = 80) -> UIImage {
        let key = "\(station.id)-\(Int(side))"
        if let hit = tileCache[key] { return hit }
        let img = render(
            size:          CGSize(width: side, height: side),
            accentHex:     station.accentHex,
            backgroundHex: station.backgroundHex,
            xGap: side / 12, yGap: side / 6.5, amp: side / 11,
            noiseXScale: 0.8 / side, noiseYScale: 0.6 / side,
            lineAlpha: 0.9, lineWidth: max(1.5, side / 45),
            seed: seed(for: station.id),
            cornerRadius: side * 0.22
        )
        tileCache[key] = img
        return img
    }

    /// Large square artwork for the Now Playing screen (CarPlay, lock screen, Control Center).
    static func artwork(for station: Station) -> MPMediaItemArtwork {
        if let hit = artworkCache[station.id] { return hit }
        let img = render(
            size:          CGSize(width: 600, height: 600),
            accentHex:     station.accentHex,
            backgroundHex: station.backgroundHex,
            xGap: 12, yGap: 18, amp: 12,
            noiseXScale: 0.002, noiseYScale: 0.0015,
            lineAlpha: 0.42, lineWidth: 1,
            seed: seed(for: station.id),
            cornerRadius: 0
        )
        let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        artworkCache[station.id] = art
        return art
    }

    // Deterministic per-station "time" — each station is a different frame of the same field.
    private static func seed(for id: String) -> Double {
        var h = 0
        for c in id.unicodeScalars { h = (h &* 31 &+ Int(c.value)) & 0xFFFF }
        return Double(h) * 0.37
    }

    private static func render(size: CGSize, accentHex: String, backgroundHex: String,
                               xGap: Double, yGap: Double, amp: Double,
                               noiseXScale: Double, noiseYScale: Double,
                               lineAlpha: CGFloat, lineWidth: CGFloat,
                               seed: Double, cornerRadius: CGFloat) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        return UIGraphicsImageRenderer(size: size, format: fmt).image { rc in
            let cg = rc.cgContext
            if cornerRadius > 0 {
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: cornerRadius).addClip()
            }
            color(backgroundHex).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let pad  = 2
            let cols = Int(ceil(size.width  / xGap)) + 1 + pad * 2
            let rows = Int(ceil(size.height / yGap)) + 1 + pad * 2

            var pts = [[CGPoint]](repeating: [CGPoint](repeating: .zero, count: cols), count: rows)
            for r in 0..<rows {
                for c in 0..<cols {
                    let x = Double(c - pad) * xGap
                    let y = Double(r - pad) * yGap
                    let n = SimplexNoise.noise2D(x * noiseXScale + seed * 0.03,
                                                 y * noiseYScale + seed * 0.015)
                    pts[r][c] = CGPoint(x: x, y: y + sin(6 * n) * amp)
                }
            }

            // No row may cross its neighbour — same two-pass clamp as WaveGridView
            let gap: CGFloat = 0.5
            for r in 1..<rows {
                for c in 0..<cols { pts[r][c].y = max(pts[r][c].y, pts[r - 1][c].y + gap) }
            }
            for r in stride(from: rows - 2, through: 0, by: -1) {
                for c in 0..<cols { pts[r][c].y = min(pts[r][c].y, pts[r + 1][c].y - gap) }
            }

            cg.setAlpha(lineAlpha)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.setStrokeColor(color(accentHex).cgColor)
            cg.setLineWidth(lineWidth)
            cg.setLineJoin(.round)
            cg.setLineCap(.round)
            for r in 0..<rows {
                cg.beginPath()
                cg.move(to: pts[r][0])
                for c in 1..<(cols - 1) {
                    let mid = CGPoint(x: (pts[r][c].x + pts[r][c + 1].x) / 2,
                                      y: (pts[r][c].y + pts[r][c + 1].y) / 2)
                    cg.addQuadCurve(to: mid, control: pts[r][c])
                }
                cg.addLine(to: pts[r][cols - 1])
                cg.strokePath()
            }
            cg.endTransparencyLayer()
        }
    }

    private static func color(_ hex: String) -> UIColor {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        return UIColor(red:   CGFloat((rgb >> 16) & 0xFF) / 255,
                       green: CGFloat((rgb >>  8) & 0xFF) / 255,
                       blue:  CGFloat( rgb        & 0xFF) / 255,
                       alpha: 1)
    }
}
