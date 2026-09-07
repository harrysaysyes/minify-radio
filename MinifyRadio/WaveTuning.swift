import SwiftUI

/// Runtime home of the wave-feel constants, so they can be calibrated live from
/// the debug tuning panel. Once calibrated, values get baked back into the code
/// and this file goes away.
final class WaveTuning: ObservableObject {

    static let shared = WaveTuning()
    private init() {}

    // Flow
    @Published var flowBase      = 0.8
    @Published var flowMid       = 0.7
    @Published var gerstnerSpeed = 0.55

    // Wave shape
    @Published var ampMultiplier = 0.9
    @Published var gerstnerAmp   = 7.0
    @Published var warp          = 0.35
    @Published var shimmer       = 0.12

    // Beat ripples
    @Published var beatBase      = 10.0
    @Published var beatScale     = 16.0
    @Published var rippleSpeed   = 520.0
    @Published var rippleWidth   = 90.0
}

#if DEBUG
struct TuningPanel: View {

    @ObservedObject private var tuning = WaveTuning.shared
    @State private var group: TuningGroup? = nil

    enum TuningGroup: String, CaseIterable {
        case flow = "Flow", wave = "Wave", beat = "Beat"
    }

    var body: some View {
        VStack(spacing: 10) {
            if let group {
                VStack(spacing: 6) {
                    switch group {
                    case .flow:
                        row("flowBase",      $tuning.flowBase,      0...2)
                        row("flowMid",       $tuning.flowMid,       0...2)
                        row("gerstnerSpeed", $tuning.gerstnerSpeed, 0...1.5)
                    case .wave:
                        row("ampMult",     $tuning.ampMultiplier, 0...4)
                        row("gerstnerAmp", $tuning.gerstnerAmp,   0...20, decimals: 1)
                        row("warp",        $tuning.warp,          0...1)
                        row("shimmer",     $tuning.shimmer,       0...0.6)
                    case .beat:
                        row("beatBase",    $tuning.beatBase,    0...30,      decimals: 1)
                        row("beatScale",   $tuning.beatScale,   0...40,      decimals: 1)
                        row("rippleSpeed", $tuning.rippleSpeed, 100...1200,  decimals: 0)
                        row("rippleWidth", $tuning.rippleWidth, 20...300,    decimals: 0)
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(group == g ? Color.white : Color.white.opacity(0.12),
                                in: Capsule())
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
