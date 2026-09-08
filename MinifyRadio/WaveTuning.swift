import SwiftUI
import UIKit

/// Runtime home of the wave-feel values, calibrated live from the debug tuning
/// panel. Once calibrated, values get baked back into the code and this file
/// goes away.
final class WaveTuning: ObservableObject {

    static let shared = WaveTuning()
    private init() {}

    enum BeatOrigin: String, CaseIterable {
        case center = "Centre", bottom = "Bottom", top = "Top", both = "Both"
    }

    // Flow
    @Published var flowBase      = WaveCfg.flowBase
    @Published var flowMid       = WaveCfg.flowMid
    @Published var gerstnerSpeed = 1.37

    // Wave shape
    @Published var ampMultiplier = WaveCfg.audioAmpMultiplier
    @Published var gerstnerAmp   = 5.6
    @Published var warp          = 0.2
    @Published var shimmer       = 0.24
    @Published var restGap       = WaveCfg.restGap

    // Beat ripples
    @Published var beatOrigin: BeatOrigin = .center
    @Published var beatBase      = WaveCfg.beatStrengthBase
    @Published var beatScale     = WaveCfg.beatStrengthScale
    @Published var rippleSpeed   = Ripple.speed
    @Published var rippleWidth   = Ripple.width

    // Look
    @Published var yGap          = WaveCfg.yGap
    @Published var lineWidth     = 1.0
    @Published var lineAlpha     = 0.42
    @Published var glow          = 0.0
    @Published var baseAmp       = WaveCfg.waveAmpY

    var clipboardSummary: String {
        [
            "flowBase \(f(flowBase))", "flowMid \(f(flowMid))", "gerstnerSpeed \(f(gerstnerSpeed))",
            "ampMult \(f(ampMultiplier))", "gerstnerAmp \(f(gerstnerAmp, 1))", "warp \(f(warp))",
            "shimmer \(f(shimmer))", "restGap \(f(restGap, 1))",
            "origin \(beatOrigin.rawValue)", "beatBase \(f(beatBase, 1))", "beatScale \(f(beatScale, 1))",
            "rippleSpeed \(f(rippleSpeed, 0))", "rippleWidth \(f(rippleWidth, 0))",
            "yGap \(f(yGap, 0))", "lineWidth \(f(lineWidth, 1))", "lineAlpha \(f(lineAlpha))",
            "glow \(f(glow, 1))", "baseAmp \(f(baseAmp, 0))",
        ].joined(separator: ", ")
    }

    private func f(_ v: Double, _ decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f", v)
    }
}

#if DEBUG
struct TuningPanel: View {

    @ObservedObject private var tuning = WaveTuning.shared
    @State private var group: TuningGroup? = nil
    @State private var copied = false

    enum TuningGroup: String, CaseIterable {
        case flow = "Flow", wave = "Wave", beat = "Beat", look = "Look"
    }

    var body: some View {
        VStack(spacing: 10) {
            if let group {
                VStack(spacing: 6) {
                    switch group {
                    case .flow:
                        row("flowBase",      $tuning.flowBase,      0...3)
                        row("flowMid",       $tuning.flowMid,       0...3)
                        row("gerstnerSpeed", $tuning.gerstnerSpeed, 0...3)
                    case .wave:
                        row("ampMult",     $tuning.ampMultiplier, 0...4)
                        row("gerstnerAmp", $tuning.gerstnerAmp,   0...20, decimals: 1)
                        row("warp",        $tuning.warp,          0...1)
                        row("shimmer",     $tuning.shimmer,       0...0.6)
                        row("restGap",     $tuning.restGap,       1...16, decimals: 1)
                    case .beat:
                        Picker("origin", selection: $tuning.beatOrigin) {
                            ForEach(WaveTuning.BeatOrigin.allCases, id: \.self) {
                                Text($0.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        row("beatBase",    $tuning.beatBase,    0...40,      decimals: 1)
                        row("beatScale",   $tuning.beatScale,   0...40,      decimals: 1)
                        row("rippleSpeed", $tuning.rippleSpeed, 100...1200,  decimals: 0)
                        row("rippleWidth", $tuning.rippleWidth, 20...300,    decimals: 0)
                    case .look:
                        row("yGap",      $tuning.yGap,      8...40,   decimals: 0)
                        row("lineWidth", $tuning.lineWidth, 0.5...4,  decimals: 1)
                        row("lineAlpha", $tuning.lineAlpha, 0.1...1)
                        row("glow",      $tuning.glow,      0...12,   decimals: 1)
                        row("baseAmp",   $tuning.baseAmp,   4...30,   decimals: 0)
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(TuningGroup.allCases, id: \.self) { g in
                    Button(g.rawValue) {
                        group = group == g ? nil : g
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(group == g ? .black : .white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(group == g ? Color.white : Color.white.opacity(0.12),
                                in: Capsule())
                }
                Button {
                    UIPasteboard.general.string = tuning.clipboardSummary
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func row(_ label: String, _ value: Binding<Double>,
                     _ range: ClosedRange<Double>, decimals: Int = 2) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 88, alignment: .leading)
            Slider(value: value, in: range)
                .tint(.white.opacity(0.7))
            Text(String(format: "%.\(decimals)f", value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
#endif
