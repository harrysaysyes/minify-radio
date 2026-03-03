import AVFoundation
import MediaPlayer
import CoreMedia
import Accelerate

// MARK: - Station model

struct Station: Codable, Equatable, Identifiable {
    var id:            String
    var name:          String
    var url:           String
    var tagline:       String
    var accentHex:     String  // wave line colour
    var backgroundHex: String  // wave background colour
    var logoUrl:       String? // favicon / logo image URL (nil for default stations)

    // Custom decoder: migrates old saves that predate backgroundHex / logoUrl
    init(id: String, name: String, url: String, tagline: String,
         accentHex: String, backgroundHex: String, logoUrl: String? = nil) {
        self.id = id; self.name = name; self.url = url
        self.tagline = tagline; self.accentHex = accentHex
        self.backgroundHex = backgroundHex; self.logoUrl = logoUrl
    }

    init(from decoder: Decoder) throws {
        let c  = try decoder.container(keyedBy: CodingKeys.self)
        id     = try c.decode(String.self, forKey: .id)
        name   = try c.decode(String.self, forKey: .name)
        url    = try c.decode(String.self, forKey: .url)
        tagline    = try c.decode(String.self, forKey: .tagline)
        accentHex  = try c.decode(String.self, forKey: .accentHex)
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex)
            ?? Station.darkHex(accentHex, factor: 0.12)
        logoUrl = try c.decodeIfPresent(String.self, forKey: .logoUrl)
    }

    /// Darken a hex colour to a near-black tint (mirrors wave-grid.js darkenHex)
    static func darkHex(_ hex: String, factor: Double) -> String {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = min(255, Int(Double((rgb >> 16) & 0xFF) * factor))
        let g = min(255, Int(Double((rgb >>  8) & 0xFF) * factor))
        let b = min(255, Int(Double( rgb        & 0xFF) * factor))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Radio Browser API result

struct RadioBrowserStation: Codable, Identifiable {
    var id: String { stationuuid }
    let stationuuid:  String
    let name:         String
    let url_resolved: String?
    let url:          String?
    let country:      String?
    let tags:         String?
    let favicon:      String?

    var streamUrl: String { url_resolved ?? url ?? "" }
}

// MARK: - MTAudioProcessingTap global callbacks
// Must be file-scope functions (not closures) to have stable C function pointer addresses.

private func _tapInit(
    _ tap: MTAudioProcessingTap,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func _tapFinalize(_ tap: MTAudioProcessingTap) {
    let s = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<RadioEngine>.fromOpaque(s).release()
}

private func _tapPrepare(
    _ tap: MTAudioProcessingTap,
    _ maxFrames: CMItemCount,
    _ format: UnsafePointer<AudioStreamBasicDescription>
) {
    let s = MTAudioProcessingTapGetStorage(tap)
    let engine = Unmanaged<RadioEngine>.fromOpaque(s).takeUnretainedValue()
    engine.tapSampleRate = format.pointee.mSampleRate > 0 ? format.pointee.mSampleRate : 44100.0
    engine.tapBassFilter = 0
}

private func _tapUnprepare(_ tap: MTAudioProcessingTap) {}

private func _tapProcess(
    _ tap: MTAudioProcessingTap,
    _ numberFrames: CMItemCount,
    _ flags: MTAudioProcessingTapFlags,
    _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    _ numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    let s = MTAudioProcessingTapGetStorage(tap)
    guard bufferListInOut.pointee.mNumberBuffers > 0,
          let data = bufferListInOut.pointee.mBuffers.mData else { return }

    let n = Int(bufferListInOut.pointee.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
    guard n > 0 else { return }

    let engine  = Unmanaged<RadioEngine>.fromOpaque(s).takeUnretainedValue()
    let samples = data.assumingMemoryBound(to: Float.self)

    // One-pole IIR low-pass at ~1500 Hz separates bass from mid/high.
    // Matches web AnalyserNode bins 0-9 (~0-1550 Hz) vs bins 10-39 (~1550-6700 Hz).
    // α = 1 − exp(−2π·fc/fs)
    let alpha   = Float(1.0 - exp(-2.0 * .pi * 1500.0 / engine.tapSampleRate))
    var bassLP  = engine.tapBassFilter
    var bassEsq: Float = 0
    var midEsq:  Float = 0
    for i in 0..<n {
        let x   = samples[i]
        bassLP += alpha * (x - bassLP)
        let mid = x - bassLP
        bassEsq += bassLP * bassLP
        midEsq  += mid    * mid
    }
    engine.tapBassFilter = bassLP

    let fN      = Float(n)
    let bassRMS = sqrt(bassEsq / fN)
    let midRMS  = sqrt(midEsq  / fN)

    // Frequency weighting: bass 70 %, mid/high 30 % — matches web AnalyserNode.
    // Scale factor 8 maps typical music levels (0.04–0.12) into 0.3–1.0.
    engine.tapRMS = min(1.0, Double(bassRMS * 0.7 + midRMS * 0.3) * 8.0)
}

// MARK: - RadioEngine

class RadioEngine: NSObject, ObservableObject {

    // MARK: - Default stations (colours match web version exactly)

    static let defaultStations: [Station] = [
        Station(id: "classicfm",  name: "Classic FM",   url: "https://media-ice.musicradio.com/ClassicFMMP3",             tagline: "The World's Greatest Music", accentHex: "#FFD700", backgroundHex: "#1A0000"),
        Station(id: "reprezent", name: "Reprezent",     url: "https://reprezent.streammachine.co.uk/stream/reprezent",    tagline: "Voice of Young London",      accentHex: "#E8E8E8", backgroundHex: "#0A0A0A"),
        Station(id: "worldwide", name: "Worldwide FM",  url: "https://worldwide-fm.radiocult.fm/stream",                  tagline: "Gilles Peterson",            accentHex: "#FBBF24", backgroundHex: "#1A2F1A"),
    ]

    // MARK: - Published state

    @Published private(set) var stations:          [Station]
    @Published private(set) var isPlaying          = false
    @Published private(set) var currentStation:    Station? = nil
    @Published private(set) var nowPlayingTitle    = "Select a station"
    @Published private(set) var nowPlayingArtist   = ""

    /// Called ~30 fps with energy 0–1 when playing. Not @Published — avoids
    /// triggering 30 SwiftUI redraws/sec.
    var onEnergyUpdate: ((Double) -> Void)?

    // MARK: - Private

    private var player:         AVPlayer?
    private var playerItem:     AVPlayerItem?
    private var statusObs:      NSKeyValueObservation?
    private var energyTimer:    Timer?
    private var energyPhase:    Double = 0
    private var energySmoothed: Double = 0
    private var audioTap: MTAudioProcessingTap?
    /// Written from real-time audio thread, read on main thread.
    /// Non-zero only when MTAudioProcessingTap is active.
    var tapRMS: Double = 0
    /// Captured in _tapPrepare; read on audio thread only.
    var tapSampleRate: Double = 44100.0
    /// IIR bass low-pass filter state; maintained between callbacks on audio thread.
    var tapBassFilter: Float = 0

    // MARK: - Init

    override init() {
        let saved = UserDefaults.standard.data(forKey: "radio_stations")
            .flatMap { try? JSONDecoder().decode([Station].self, from: $0) }
        stations = (saved?.count == 3) ? saved! : RadioEngine.defaultStations
        super.init()
        setupAudioSession()
        setupRemoteCommands()
    }

    // MARK: - Play / Stop

    func toggleStation(_ station: Station) {
        if isPlaying && currentStation?.id == station.id {
            stop()
        } else {
            play(station)
        }
    }

    func stop() {
        player?.pause()
        player     = nil
        playerItem = nil
        statusObs?.invalidate()
        statusObs  = nil
        stopEnergySimulation()
        isPlaying        = false
        currentStation   = nil
        nowPlayingTitle  = "Select a station"
        nowPlayingArtist = ""
        onEnergyUpdate?(0)
        updateNowPlaying()
    }

    // MARK: - Station management

    func replaceStation(at slot: Int, with s: RadioBrowserStation) {
        guard slot < stations.count else { return }
        let accent = accentForName(s.name)
        let bg     = Station.darkHex(accent, factor: 0.12)
        stations[slot] = Station(
            id:            "custom_\(s.stationuuid)",
            name:          s.name,
            url:           s.streamUrl,
            tagline:       s.country ?? "",
            accentHex:     accent,
            backgroundHex: bg,
            logoUrl:       (s.favicon?.isEmpty == false) ? s.favicon : nil
        )
        saveStations()
    }

    // MARK: - Station search

    func searchStations(query: String) async throws -> [RadioBrowserStation] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        // all.api.radio-browser.info is a DNS round-robin across all live servers
        let urlString = "https://all.api.radio-browser.info/json/stations/search?name=\(encoded)&limit=20&hidebroken=true&order=clickcount"
        guard let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("MinifyRadio/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([RadioBrowserStation].self, from: data)
    }

    // MARK: - Private: play

    private func play(_ station: Station) {
        stop()
        guard let url = URL(string: station.url) else { return }
        try? AVAudioSession.sharedInstance().setActive(true)

        playerItem = AVPlayerItem(url: url)
        player     = AVPlayer(playerItem: playerItem)

        statusObs = playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    if self.nowPlayingTitle == "Connecting…" {
                        self.nowPlayingTitle  = "Live"
                        self.nowPlayingArtist = station.tagline
                        self.updateNowPlaying()
                    }
                    if self.audioTap == nil, let item = self.playerItem {
                        self.installTap(on: item)
                    }
                case .failed:
                    self.nowPlayingTitle  = "Connection error"
                    self.nowPlayingArtist = "Stream may be offline"
                    self.updateNowPlaying()
                default: break
                }
            }
        }

        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: .main)
        playerItem?.add(output)

        player?.play()
        currentStation   = station
        isPlaying        = true
        nowPlayingTitle  = "Connecting…"
        nowPlayingArtist = ""
        updateNowPlaying()
        startEnergySimulation()
        // Tap installed at readyToPlay (see status observer) — not here,
        // because the player hasn't established the stream connection yet.
    }

    // MARK: - Real audio metering via MTAudioProcessingTap

    private func installTap(on item: AVPlayerItem) {
        let selfRef = Unmanaged.passRetained(self)

        // Use global functions (not closures) — only those have stable C function pointer addresses.
        var callbacks = MTAudioProcessingTapCallbacks(
            version:    kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: selfRef.toOpaque(),
            init:       _tapInit,
            finalize:   _tapFinalize,
            prepare:    _tapPrepare,
            unprepare:  _tapUnprepare,
            process:    _tapProcess
        )

        var tapOut: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                         kMTAudioProcessingTapCreationFlag_PostEffects,
                                         &tapOut) == noErr,
              let tap = tapOut else {
            selfRef.release()
            return
        }
        audioTap = tap  // Swift ARC keeps it alive; nil in stopEnergySimulation triggers finalize

        // AVMutableAudioMixInputParameters with no track applies the tap to ALL audio
        // in the player item — correct for live streams where assetTrack is always nil.
        let params = AVMutableAudioMixInputParameters()
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    // MARK: - Audio session

    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    // MARK: - Energy simulation

    private func startEnergySimulation() {
        stopEnergySimulation()
        energyPhase   = 0
        energySmoothed = 0
        tapRMS        = 0

        energyTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.energyPhase += 1.0 / 30.0
            let t = self.energyPhase

            let live = self.tapRMS
            if live > 0.01 {
                // Asymmetric envelope follower — matches Web Audio AnalyserNode behaviour.
                // Fast attack (lerp 0.35) snaps to loud hits; slow release (lerp 0.10)
                // lets the energy tail off musically rather than cutting dead.
                // At 30 fps, attack 0.35 ≈ 73 ms TC; release 0.10 ≈ 300 ms TC.
                let alpha = live > self.energySmoothed ? 0.35 : 0.10
                self.energySmoothed += (live - self.energySmoothed) * alpha
            } else {
                // Organic simulation — three overlapping slow sines, zero flicker possible.
                // Periods: ~20 s, ~8.8 s, ~4.7 s → irregular breathing like live music.
                let a = 0.5 + 0.5 * sin(t * 0.31)
                let b = 0.5 + 0.5 * sin(t * 0.71 + 2.1)
                let c = 0.5 + 0.5 * sin(t * 1.33 + 0.8)
                let target = a * 0.50 + b * 0.30 + c * 0.20   // 0…1
                // 0.04 lerp ≈ 0.83 s time-constant — silky smooth
                self.energySmoothed += (target - self.energySmoothed) * 0.04
            }

            self.onEnergyUpdate?(self.energySmoothed)
        }
    }

    private func stopEnergySimulation() {
        energyTimer?.invalidate()
        energyTimer = nil
        audioTap = nil  // Swift ARC releases tap → finalize callback → releases retained self ref
        tapRMS   = 0
    }

    // MARK: - Remote commands

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.isEnabled = true
        c.playCommand.addTarget { [weak self] _ in
            guard let self else { return .success }
            if let station = self.currentStation { self.play(station) }
            else if let first = self.stations.first { self.play(first) }
            return .success
        }
        c.pauseCommand.isEnabled = true
        c.pauseCommand.addTarget { [weak self] _ in self?.stop(); return .success }

        c.stopCommand.isEnabled = true
        c.stopCommand.addTarget { [weak self] _ in self?.stop(); return .success }

        c.togglePlayPauseCommand.isEnabled = true
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .success }
            if self.isPlaying { self.stop() }
            else if let s = self.currentStation { self.play(s) }
            else if let first = self.stations.first { self.play(first) }
            return .success
        }
        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .success }
            let idx = self.stations.firstIndex(where: { $0.id == self.currentStation?.id }) ?? -1
            self.play(self.stations[(idx + 1) % self.stations.count])
            return .success
        }
        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .success }
            let idx = self.stations.firstIndex(where: { $0.id == self.currentStation?.id }) ?? 0
            self.play(self.stations[(idx - 1 + self.stations.count) % self.stations.count])
            return .success
        }
        c.changePlaybackRateCommand.isEnabled = false
        c.skipForwardCommand.isEnabled        = false
        c.skipBackwardCommand.isEnabled       = false
    }

    // MARK: - Now Playing

    private func updateNowPlaying() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle]             = nowPlayingTitle.isEmpty ? (currentStation?.name ?? "Minify Radio") : nowPlayingTitle
        info[MPMediaItemPropertyArtist]            = nowPlayingArtist.isEmpty ? (currentStation?.tagline ?? "") : nowPlayingArtist
        info[MPMediaItemPropertyAlbumTitle]        = currentStation?.name ?? "Minify Radio"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState  = isPlaying ? .playing : .paused
    }

    // MARK: - Persist

    private func saveStations() {
        if let data = try? JSONEncoder().encode(stations) {
            UserDefaults.standard.set(data, forKey: "radio_stations")
        }
    }

    // MARK: - Accent colour from station name (custom stations)

    private func accentForName(_ name: String) -> String {
        var h: Int = 0
        for c in name.unicodeScalars { h = (h &* 31) &+ Int(c.value) }
        let hue = abs(h) % 360
        return hslToHex(hue: Double(hue), saturation: 0.70, lightness: 0.50)
    }

    private func hslToHex(hue: Double, saturation: Double, lightness: Double) -> String {
        let s = saturation, l = lightness
        let a = s * min(l, 1 - l)
        func f(_ n: Double) -> Int {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            let color = l - a * max(min(k - 3, min(9 - k, 1)), -1)
            return Int(round(255 * color))
        }
        return String(format: "#%02X%02X%02X", f(0), f(8), f(4))
    }
}

// MARK: - ICY / Timed metadata delegate

extension RadioEngine: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        for group in groups {
            for item in group.items {
                guard let value = item.stringValue,
                      !value.isEmpty,
                      isReadableMetadata(value) else { continue }
                let parts = value.components(separatedBy: " - ")
                if parts.count >= 2 {
                    nowPlayingTitle  = parts[1...].joined(separator: " - ").trimmingCharacters(in: .whitespaces)
                    nowPlayingArtist = parts[0].trimmingCharacters(in: .whitespaces)
                } else {
                    nowPlayingTitle  = value.trimmingCharacters(in: .whitespaces)
                    nowPlayingArtist = ""
                }
                updateNowPlaying()
                return
            }
        }
    }

    /// Returns false if the string looks like garbage (binary, base64, or non-human text).
    private func isReadableMetadata(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        // Reject if too many non-printable chars
        let readable = scalars.filter { s in
            (s.value >= 0x20 && s.value <= 0x7E)
            || (s.value >= 0xA0 && s.value <= 0x024F)
            || s.value == 0x0A || s.value == 0x0D
        }
        guard Double(readable.count) / Double(max(1, scalars.count)) >= 0.80 else { return false }
        // Reject encoded/garbage: any single "word" longer than 15 chars is a red flag
        // (real artist/track names rarely have 15+ char words without spaces)
        let longestWord = value.components(separatedBy: .whitespaces).map(\.count).max() ?? 0
        if longestWord > 15 { return false }
        // Reject strings longer than 16 chars with almost no spaces (timestamps, encoded data)
        if value.count > 16 {
            let spaces = value.filter { $0 == " " }.count
            if Double(spaces) / Double(value.count) < 0.04 { return false }
        }
        return true
    }
}
