import SwiftUI

// MARK: - Colour helpers

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >>  8) & 0xFF) / 255,
            blue:  Double( rgb        & 0xFF) / 255
        )
    }
}

// MARK: - Slot edit wrapper (Identifiable for .sheet(item:))

private struct SlotEdit: Identifiable { let id: Int }

// MARK: - ContentView

struct ContentView: View {

    @ObservedObject private var engine = RadioEngine.shared
    @StateObject private var iap     = IAPManager()
    @StateObject private var physics = WavePhysics()

    @State private var showSupport = false
    @State private var slotToEdit: SlotEdit? = nil

    private var accent: Color {
        engine.currentStation.map { Color(hex: $0.accentHex) } ?? Color(hex: "#94A3B8")
    }

    private var waveBackground: Color {
        engine.currentStation.map { Color(hex: $0.backgroundHex) } ?? Color(hex: "#0A0A0A")
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ── Wave — full screen ───────────────────────────────
                WaveGridView(
                    accent:     accent,
                    background: waveBackground,
                    physics:    physics
                )

                // ── Player card ──────────────────────────────────────
                VStack(spacing: 0) {

                    // App / station header — hidden once a station is selected
                    if engine.currentStation == nil {
                        Text("Minify Radio")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                            .kerning(0.3)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Spacer().frame(height: 28)

                    // Now playing
                    VStack(spacing: 5) {
                        Text(engine.nowPlayingTitle)
                            .font(.system(
                                size:   engine.isPlaying ? 17 : 13,
                                weight: engine.isPlaying ? .semibold : .regular
                            ))
                            .foregroundColor(.white.opacity(engine.isPlaying ? 1.0 : 0.32))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .animation(.easeInOut(duration: 0.3), value: engine.isPlaying)
                            .animation(.easeInOut(duration: 0.3), value: engine.nowPlayingTitle)

                        if !engine.nowPlayingArtist.isEmpty {
                            Text(engine.nowPlayingArtist)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.45))
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                                .animation(.easeInOut(duration: 0.3), value: engine.nowPlayingArtist)
                        }
                    }
                    .frame(minHeight: 54)

                    Spacer().frame(height: 36)

                    // Station buttons
                    HStack(spacing: 12) {
                        ForEach(Array(engine.stations.enumerated()), id: \.offset) { i, station in
                            StationButton(
                                station:  station,
                                isActive: engine.isPlaying && engine.currentStation?.id == station.id,
                                accent:   accent,
                                onPlay:   { engine.toggleStation(station) },
                                onEdit:   { slotToEdit = SlotEdit(id: i) }
                            )
                        }
                    }

                    Spacer().frame(height: 32)

                    // Support
                    Button { showSupport = true } label: {
                        Text("Support Minify")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.18))
                            .kerning(0.3)
                    }
                }
                .padding(28)
                .animation(.easeInOut(duration: 0.4), value: engine.currentStation == nil)
                .background(cardBackground)
                .shadow(color: .black.opacity(0.55), radius: 30, y: 20)
                .shadow(color: accent.opacity(engine.isPlaying ? 0.30 : 0), radius: 45, y: 10)
                .shadow(color: accent.opacity(engine.isPlaying ? 0.20 : 0), radius: 80)
                .shadow(color: accent.opacity(engine.isPlaying ? 0.10 : 0), radius: 130)
                .animation(.easeInOut(duration: 0.8), value: engine.isPlaying)
                .frame(
                    maxWidth:  geo.size.width  * 0.92,
                    minHeight: geo.size.height * 0.80,
                    maxHeight: geo.size.height * 0.92
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            engine.onEnergyUpdate = { [weak physics] bass, mid, treble in
                physics?.bassEnergy   = bass
                physics?.midEnergy    = mid
                physics?.trebleEnergy = treble
            }
            engine.onBeat = { [weak physics] intensity in
                physics?.triggerBeatPulse(intensity: intensity)
            }
        }
        .sheet(isPresented: $showSupport) {
            SupportSheet(iap: iap)
                .task { await iap.loadProducts() }
        }
        .sheet(item: $slotToEdit) { edit in
            StationSearchSheet(slot: edit.id, engine: engine)
                .presentationDetents([.medium, .large])
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.black.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(
                        accent.opacity(engine.isPlaying ? 0.30 : 0.12),
                        lineWidth: 1
                    )
                    .animation(.easeInOut(duration: 0.8), value: engine.isPlaying)
            )
    }
}

// MARK: - Station button

private struct StationButton: View {
    let station:  Station
    let isActive: Bool
    let accent:   Color
    let onPlay:   () -> Void
    let onEdit:   () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(spacing: 5) {
                if let logoUrl = station.logoUrl, let url = URL(string: logoUrl) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                Text(station.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActive ? Color(white: 0.08) : .white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 90)
            .padding(.horizontal, 6)
            .background(isActive ? accent : accent.opacity(0.10))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(accent.opacity(isActive ? 0 : 0.28), lineWidth: 1)
            )
        }
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onEdit() }
        )
    }
}

// MARK: - Station search sheet

struct StationSearchSheet: View {
    let slot:   Int
    @ObservedObject var engine: RadioEngine
    @Environment(\.dismiss) private var dismiss

    @State private var query        = ""
    @State private var results:     [RadioBrowserStation] = []
    @State private var isSearching  = false
    @State private var errorMessage = ""
    @State private var searchTask:  Task<Void, Never>? = nil

    var body: some View {
        ZStack {
            Color(white: 0.039).ignoresSafeArea()

            VStack(spacing: 0) {
                // Handle
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 36, height: 5)
                    .padding(.top, 14)

                Spacer().frame(height: 20)

                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.35))

                    TextField("Search 30,000+ stations…", text: $query)
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: query) { _ in scheduleSearch() }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Color.white.opacity(0.06))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .padding(.horizontal, 20)

                Spacer().frame(height: 16)

                // Results
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isSearching {
                            Text("Searching…")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.3))
                                .padding(.top, 40)
                        } else if !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.3))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                                .padding(.top, 40)
                        } else if results.isEmpty && query.count >= 2 {
                            Text("No stations found.")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.3))
                                .padding(.top, 40)
                        } else if query.count < 2 {
                            Text("Search by name, genre or country")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.25))
                                .padding(.top, 40)
                        } else {
                            ForEach(results) { station in
                                ResultRow(station: station)
                                    .onTapGesture {
                                        engine.replaceStation(at: slot, with: station)
                                        dismiss()
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard query.count >= 2 else { results = []; isSearching = false; return }
        isSearching  = true
        errorMessage = ""
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await engine.searchStations(query: query)
                await MainActor.run { results = found; isSearching = false }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSearching  = false
                }
            }
        }
    }
}

// MARK: - Result row

private struct ResultRow: View {
    let station: RadioBrowserStation

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.15))
                    .frame(width: 40, height: 40)
                Text(initials)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(station.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let country = station.country, !country.isEmpty {
                    Text(country)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.38))
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var initials: String {
        let words = station.name.split(separator: " ")
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String(station.name.prefix(2)).uppercased()
    }
}

// MARK: - Support sheet

private struct SupportSheet: View {
    @ObservedObject var iap: IAPManager
    @Environment(\.dismiss) private var dismiss

    private let accent = Color(hex: "#94A3B8")

    var body: some View {
        ZStack {
            Color(white: 0.039).ignoresSafeArea()

            if iap.thankYouShown {
                VStack(spacing: 16) {
                    Text("Thank you.")
                        .font(.system(size: 30, weight: .black))
                        .foregroundColor(.white)
                    Text("It means a lot.")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.4))
                    Button("Done", action: dismiss.callAsFunction)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(accent)
                        .padding(.top, 4)
                }
            } else {
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 36, height: 5)
                        .padding(.top, 14)

                    Spacer().frame(height: 32)

                    Text("Support Minify")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)

                    Spacer().frame(height: 6)

                    Text("No features locked. Just appreciation.")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.35))

                    Spacer().frame(height: 36)

                    if iap.products.isEmpty {
                        Text("Loading…")
                            .foregroundColor(.white.opacity(0.3))
                            .font(.system(size: 14))
                    } else {
                        VStack(spacing: 8) {
                            ForEach(iap.products, id: \.id) { product in
                                Button {
                                    Task { await iap.purchase(product) }
                                } label: {
                                    HStack {
                                        Text(product.displayName)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.white)
                                        Spacer()
                                        Text(product.displayPrice)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(accent)
                                    }
                                    .padding(.horizontal, 18)
                                    .frame(height: 50)
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                                }
                                .disabled(iap.isPurchasing)
                            }
                        }
                        .padding(.horizontal, 24)
                    }

                    Spacer()
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
