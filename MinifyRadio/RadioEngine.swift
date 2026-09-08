import AVFoundation
import MediaPlayer
import AudioToolbox
import Accelerate
import UIKit

// MARK: - Station model

struct Station: Codable, Equatable, Identifiable {
    var id:            String
    var name:          String
    var url:           String
    var tagline:       String
    var accentHex:     String
    var backgroundHex: String
    var logoUrl:       String?

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

// MARK: - AudioFileStream callbacks (file-scope — stable C function pointer addresses)

private func _afsPropertyListener(
    _ clientData: UnsafeMutableRawPointer,
    _ streamID:   AudioFileStreamID,
    _ propertyID: AudioFileStreamPropertyID,
    _ ioFlags:    UnsafeMutablePointer<AudioFileStreamPropertyFlags>
) {
    guard propertyID == kAudioFileStreamProperty_DataFormat else { return }
    var fmt  = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_DataFormat,
                                     &size, &fmt) == noErr else { return }
    Unmanaged<RadioEngine>.fromOpaque(clientData).takeUnretainedValue()
        .setupConverter(inputFormat: fmt)
}

private func _afsPacketsCallback(
    _ clientData:         UnsafeMutableRawPointer,
    _ numberBytes:        UInt32,
    _ numberPackets:      UInt32,
    _ inputData:          UnsafeRawPointer,
    _ packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
) {
    Unmanaged<RadioEngine>.fromOpaque(clientData).takeUnretainedValue()
        .decodeAudioPackets(bytes: inputData, byteCount: numberBytes,
                            packetCount: numberPackets, descriptions: packetDescriptions)
}

// MARK: - AudioConverter input data proc

private struct ConverterContext {
    let bytes:       UnsafeRawPointer
    let byteCount:   UInt32
    let packetCount: UInt32
    let descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    var done = false
}

private func _converterDataProc(
    _  converter:       AudioConverterRef,
    _  ioPackets:       UnsafeMutablePointer<UInt32>,
    _  ioBufferList:    UnsafeMutablePointer<AudioBufferList>,
    _  outDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _  userData:        UnsafeMutableRawPointer?
) -> OSStatus {
    guard let ctx = userData?.assumingMemoryBound(to: ConverterContext.self) else { return -1 }
    if ctx.pointee.done { ioPackets.pointee = 0; return -1 }
    ioBufferList.pointee.mNumberBuffers           = 1
    ioBufferList.pointee.mBuffers.mNumberChannels = 0
    ioBufferList.pointee.mBuffers.mDataByteSize   = ctx.pointee.byteCount
    ioBufferList.pointee.mBuffers.mData           = UnsafeMutableRawPointer(mutating: ctx.pointee.bytes)
    outDescriptions?.pointee = ctx.pointee.descriptions
    ioPackets.pointee = ctx.pointee.packetCount
    ctx.pointee.done  = true
    return noErr
}

// MARK: - RadioEngine

class RadioEngine: NSObject, ObservableObject {

    // Single instance shared by the phone UI and the CarPlay scene —
    // both must observe and control the same playback state.
    static let shared = RadioEngine()

    // MARK: - Default stations

    static let defaultStations: [Station] = [
        Station(id: "classicfm",  name: "Classic FM",
                url: "https://media-ice.musicradio.com/ClassicFMMP3",
                tagline: "The World's Greatest Music",
                accentHex: "#FFD700", backgroundHex: "#1A0000"),
        Station(id: "reprezent", name: "Reprezent",
                url: "https://reprezent.streammachine.co.uk/stream/reprezent",
                tagline: "Voice of Young London",
                accentHex: "#E8E8E8", backgroundHex: "#0A0A0A"),
        Station(id: "worldwide", name: "Worldwide FM",
                url: "https://worldwide-fm.radiocult.fm/stream",
                tagline: "Gilles Peterson",
                accentHex: "#FBBF24", backgroundHex: "#1A2F1A"),
    ]

    // MARK: - Published state

    @Published private(set) var stations:       [Station]
    @Published private(set) var isPlaying       = false
    @Published private(set) var currentStation: Station? = nil
    @Published private(set) var nowPlayingTitle  = "Select a station"
    @Published private(set) var nowPlayingArtist = ""
    @Published private(set) var history: ListenHistory

    var onEnergyUpdate: ((_ bass: Double, _ mid: Double, _ treble: Double) -> Void)?
    var onBeat: ((_ intensity: Double) -> Void)?

    // MARK: - Streaming engine
    //
    // Single pipeline: one connection feeds AudioFileStream → AudioConverter → PCM,
    // which is both played (AVAudioEngine) and metered (a tap on the output mixer).
    // Energy is measured on the audio actually leaving the mixer, so it is in sync
    // with the speaker by construction — no guessed delay.

    private let audioEngine = AVAudioEngine()
    private var playerNode:      AVAudioPlayerNode?
    private var audioFileStream: AudioFileStreamID?
    private var audioConverter:  AudioConverterRef?
    private var pcmFormat:       AVAudioFormat?
    private var streamTask:      URLSessionDataTask?
    private var icyParser:       IcyParser?

    private var scheduledFrames: AVAudioFramePosition = 0
    private var nodeStarted     = false
    private var retryWorkItem:   DispatchWorkItem?

    /// Audio queued before playback starts — enough to ride out network jitter.
    private let prebufferSeconds = 0.75

    // Track identity: artwork + store page looked up per ICY title, wave art until it arrives
    @Published private(set) var trackLink: URL? = nil
    private var trackArtwork:  MPMediaItemArtwork?
    private var artworkTask:   Task<Void, Never>?
    private var artworkCache = [String: (art: MPMediaItemArtwork, link: URL?)]()

    /// Serial queue that owns all decode state. stop() uses sync to drain it before teardown,
    /// guaranteeing no in-flight decode work can race with audioFileStream/audioConverter teardown.
    private let decodeQueue = DispatchQueue(label: "radio.decode", qos: .userInitiated)

    private lazy var streamSession: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Energy

    private var energyTimer:    Timer?
    private var bassSmoothed:   Double = 0
    private var midSmoothed:    Double = 0
    private var trebleSmoothed: Double = 0
    private var tapBass:        Double = 0
    private var tapMid:         Double = 0
    private var tapTreble:      Double = 0

    // Musical hearing: per-band adaptive normalization (tap thread),
    // attack/release envelopes (main timer), bass onset → beat pulse.
    private var bassNorm    = AdaptiveNormalizer(halflife: 4, gate: 1e-3)
    private var midNorm     = AdaptiveNormalizer(halflife: 4, gate: 1e-3)
    private var trebleNorm  = AdaptiveNormalizer(halflife: 4, gate: 1e-3)
    private var bassOnset   = OnsetDetector(sensitivity: 2.2, refractory: 0.12, minFlux: 0.005)
    private var tempo       = TempoTracker()
    private var meterClock:  Double = 0     // audio-sample time, advanced by the tap
    private var beatLead:    Double = 0.08  // fire early: output latency + shockwave rise
    // Slow visual envelopes: the field breathes with the piece's dynamics.
    // Fast musical events reach the waves only through beat pulses.
    private var bassEnv     = EnvelopeFollower(attack: 0.6, release: 2.5)
    private var midEnv      = EnvelopeFollower(attack: 0.8, release: 3.0)
    private var trebleEnv   = EnvelopeFollower(attack: 0.5, release: 2.0)

    // FFT state — allocated once, reused each tap callback
    private var fftSetup:      FFTSetup?
    private var fftLog2n:      vDSP_Length = 0
    private var fftN:          Int = 0
    private var fftRealBuf:    [Float] = []
    private var fftImagBuf:    [Float] = []
    private var fftMagBuf:     [Float] = []
    private var fftWindow:     [Float] = []
    private var fftSampleRate: Double  = 0

    // MARK: - Init

    private override init() {
        let saved = UserDefaults.standard.data(forKey: "radio_stations")
            .flatMap { try? JSONDecoder().decode([Station].self, from: $0) }
        stations = (saved?.count == 3) ? saved! : RadioEngine.defaultStations
        history = UserDefaults.standard.data(forKey: "listen_history")
            .flatMap { try? JSONDecoder().decode(ListenHistory.self, from: $0) }
            ?? ListenHistory()
        super.init()
        setupAudioSession()
        setupRemoteCommands()
        setupInterruptionHandling()
    }

    // MARK: - Play / Stop

    func toggleStation(_ station: Station) {
        if isPlaying && currentStation?.id == station.id { stop() }
        else { play(station) }
    }

    func stop() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        streamTask?.cancel()
        streamTask = nil

        // Block until any in-progress decode work finishes, then tear down decode and
        // playback state. This prevents the race where the URLSession bg thread is
        // mid-parse while the main thread disposes the stream/converter underneath it.
        decodeQueue.sync {
            if let s = audioFileStream { AudioFileStreamClose(s); audioFileStream = nil }
            if let c = audioConverter  { AudioConverterDispose(c); audioConverter  = nil }
            pcmFormat = nil
            icyParser = nil
            teardownPlayback()
        }

        artworkTask?.cancel()
        artworkTask  = nil
        trackArtwork = nil
        trackLink    = nil

        stopEnergyTimer()
        isPlaying        = false
        currentStation   = nil
        nowPlayingTitle  = "Select a station"
        nowPlayingArtist = ""
        onEnergyUpdate?(0, 0, 0)
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
        let urlString = "https://all.api.radio-browser.info/json/stations/search?name=\(encoded)&limit=20&hidebroken=true&order=clickcount"
        guard let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("MinifyRadio/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([RadioBrowserStation].self, from: data)
    }

    // MARK: - Play

    func play(_ station: Station) {
        stop()
        guard let url = URL(string: station.url) else { return }
        try? AVAudioSession.sharedInstance().setActive(true)

        currentStation   = station
        isPlaying        = true
        nowPlayingTitle  = "Connecting…"
        nowPlayingArtist = ""
        beatLead         = Double(AVAudioSession.sharedInstance().outputLatency) + 0.08
        updateNowPlaying()
        startEnergyTimer()

        openStream(url: url)
    }

    private func openStream(url: URL) {
        // Open AudioFileStream (format detection fires _afsPropertyListener → setupConverter)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var sid: AudioFileStreamID?
        guard AudioFileStreamOpen(selfPtr, _afsPropertyListener, _afsPacketsCallback,
                                  0, &sid) == noErr, let s = sid else { return }
        audioFileStream = s

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("MinifyRadio/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        streamTask = streamSession.dataTask(with: request)
        streamTask?.resume()
    }

    // MARK: - Reconnection (live streams shouldn't end)

    private func scheduleReconnect() {
        guard isPlaying, currentStation != nil else { return }
        nowPlayingTitle  = "Reconnecting…"
        nowPlayingArtist = currentStation?.tagline ?? ""
        updateNowPlaying()
        let work = DispatchWorkItem { [weak self] in self?.reconnect() }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func reconnect() {
        guard isPlaying, let station = currentStation, let url = URL(string: station.url) else { return }
        decodeQueue.sync {
            if let s = audioFileStream { AudioFileStreamClose(s); audioFileStream = nil }
            if let c = audioConverter  { AudioConverterDispose(c); audioConverter  = nil }
            pcmFormat = nil
            icyParser = nil
        }
        openStream(url: url)
    }

    // MARK: - Playback graph (all engine mutation happens on decodeQueue)

    private func configurePlayback(format: AVAudioFormat) {
        if let old = playerNode {
            old.stop()
            audioEngine.detach(old)
        }
        let node = AVAudioPlayerNode()
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)

        audioEngine.mainMixerNode.removeTap(onBus: 0)
        audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) {
            [weak self] buffer, _ in
            self?.measureEnergy(buffer)
        }
        try? audioEngine.start()
        playerNode      = node
        nodeStarted     = false
        scheduledFrames = 0
    }

    private func teardownPlayback() {
        if let node = playerNode {
            node.stop()
            audioEngine.detach(node)
            playerNode = nil
        }
        audioEngine.mainMixerNode.removeTap(onBus: 0)
        audioEngine.stop()
        nodeStarted     = false
        scheduledFrames = 0
    }

    // MARK: - Converter setup (called by _afsPropertyListener during parse on decodeQueue)

    /// Called when stream format is known — sets up MP3/AAC→PCM decoding and the playback graph.
    fileprivate func setupConverter(inputFormat: AudioStreamBasicDescription) {
        guard audioConverter == nil else { return }

        var inFmt  = inputFormat
        let ch     = max(1, UInt32(inputFormat.mChannelsPerFrame))
        let sr     = inputFormat.mSampleRate > 0 ? inputFormat.mSampleRate : 44100.0

        // Non-interleaved float32 output — what AVAudioPlayerNode and the FFT both want.
        guard let stdFmt = AVAudioFormat(standardFormatWithSampleRate: sr,
                                         channels: AVAudioChannelCount(ch)) else { return }
        var outFmt = stdFmt.streamDescription.pointee

        var conv: AudioConverterRef?
        guard AudioConverterNew(&inFmt, &outFmt, &conv) == noErr, let c = conv else { return }
        audioConverter = c
        pcmFormat = stdFmt
        configurePlayback(format: stdFmt)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.nowPlayingTitle == "Connecting…" || self.nowPlayingTitle == "Reconnecting…"
            else { return }
            self.nowPlayingTitle  = "Live"
            self.nowPlayingArtist = self.currentStation?.tagline ?? ""
            self.updateNowPlaying()
        }
    }

    // MARK: - Decode (called by _afsPacketsCallback on background thread)

    fileprivate func decodeAudioPackets(
        bytes:       UnsafeRawPointer,
        byteCount:   UInt32,
        packetCount: UInt32,
        descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard let conv = audioConverter,
              let fmt  = pcmFormat,
              packetCount > 0 else { return }

        let framesPerPacket: UInt32 = 1152
        let outputFrames = packetCount * framesPerPacket

        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: outputFrames) else { return }
        buffer.frameLength = outputFrames

        var ctx      = ConverterContext(bytes: bytes, byteCount: byteCount,
                                        packetCount: packetCount, descriptions: descriptions)
        var ioFrames = outputFrames
        let status   = AudioConverterFillComplexBuffer(conv, _converterDataProc, &ctx,
                                                       &ioFrames, buffer.mutableAudioBufferList, nil)
        if (status == noErr || status == -1) && ioFrames > 0 {
            buffer.frameLength = ioFrames
            playerNode?.scheduleBuffer(buffer, completionHandler: nil)
            scheduledFrames += AVAudioFramePosition(ioFrames)
            if !nodeStarted, let node = playerNode,
               Double(scheduledFrames) >= prebufferSeconds * fmt.sampleRate {
                node.play()
                nodeStarted = true
            }
        }
    }

    // MARK: - Energy metering (tap on the output mixer — synced to the speaker)

    private func measureEnergy(_ buffer: AVAudioPCMBuffer) {
        guard let chData = buffer.floatChannelData else { return }
        let frames     = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        let chCount    = Int(buffer.format.channelCount)
        guard frames > 0, sampleRate > 0, chCount > 0 else { return }

            // Mix to mono
            var mono = [Float](repeating: 0, count: frames)
            for ch in 0..<chCount {
                let src = chData[ch]
                for i in 0..<frames { mono[i] += src[i] }
            }
            if chCount > 1 {
                let s = Float(1.0 / Double(chCount))
                vDSP_vsmul(mono, 1, [s], &mono, 1, vDSP_Length(frames))
            }

            // Lazy FFT setup — reallocate only when size/rate changes
            let log2n: vDSP_Length = 11   // 2048-point
            let n = 1 << log2n
            if fftSetup == nil || fftLog2n != log2n || fftSampleRate != sampleRate {
                if let old = fftSetup { vDSP_destroy_fftsetup(old) }
                fftSetup      = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
                fftLog2n      = log2n
                fftN          = n
                fftSampleRate = sampleRate
                fftRealBuf    = [Float](repeating: 0, count: n / 2)
                fftImagBuf    = [Float](repeating: 0, count: n / 2)
                fftMagBuf     = [Float](repeating: 0, count: n / 2)
                fftWindow     = [Float](repeating: 0, count: n)
                vDSP_hann_window(&fftWindow, vDSP_Length(n), Int32(vDSP_HANN_NORM))
            }
            guard let setup = fftSetup else { return }

            // Window + zero-pad
            var windowed = [Float](repeating: 0, count: fftN)
            vDSP_vmul(mono, 1, fftWindow, 1, &windowed, 1, vDSP_Length(min(frames, fftN)))

            // Forward real FFT using stable pointer approach
            fftRealBuf.withUnsafeMutableBufferPointer { rp in
                fftImagBuf.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeMutableBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftN / 2) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(fftN / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, fftLog2n, FFTDirection(FFT_FORWARD))
                    fftMagBuf.withUnsafeMutableBufferPointer { mp in
                        vDSP_zvmags(&split, 1, mp.baseAddress!, 1, vDSP_Length(fftN / 2))
                    }
                }
            }

            // Sum bands — normalize by fftN/2 so values are independent of transform size
            let binHz    = sampleRate / Double(fftN)
            let bassLo   = max(1, Int(20   / binHz))
            let bassHi   = Int(250  / binHz)
            let midLo    = bassHi + 1
            let midHi    = Int(3000 / binHz)
            let trebLo   = midHi + 1
            let trebHi   = min(Int(16000 / binHz), fftN / 2 - 1)
            let norm     = 1.0 / Float(fftN / 2)

            var bSum: Float = 0, mSum: Float = 0, tSum: Float = 0
            for b in bassLo...bassHi { bSum += fftMagBuf[b] }
            for b in midLo...midHi   { mSum += fftMagBuf[b] }
            for b in trebLo...trebHi { tSum += fftMagBuf[b] }

            let bCount = Float(max(1, bassHi - bassLo + 1))
            let mCount = Float(max(1, midHi  - midLo  + 1))
            let tCount = Float(max(1, trebHi - trebLo + 1))

            let dt        = Double(frames) / sampleRate
            let bassRaw   = Double(sqrt(bSum / bCount) * norm)
            let midRaw    = Double(sqrt(mSum / mCount) * norm)
            let trebleRaw = Double(sqrt(tSum / tCount) * norm)

            tapBass   = bassNorm.normalize(bassRaw, dt: dt)
            tapMid    = midNorm.normalize(midRaw, dt: dt)
            tapTreble = trebleNorm.normalize(trebleRaw, dt: dt)

            meterClock += dt
            if bassOnset.process(energy: bassRaw, dt: dt) {
                tempo.registerOnset(at: meterClock)
                // Unlocked: react directly. Locked: the predicted grid carries the
                // beat, but events clearly off the grid (snares, syncopation) still
                // get their own softer ripple.
                let offGrid = tempo.gridOffset(of: meterClock)
                if offGrid == nil || offGrid! > 0.2 {
                    let intensity = tapBass * (offGrid == nil ? 1.0 : 0.7)
                    DispatchQueue.main.async { [weak self] in self?.onBeat?(intensity) }
                }
            }
            if tempo.consumeBeat(at: meterClock, lead: beatLead) {
                let intensity = max(tapBass, 0.4)
                DispatchQueue.main.async { [weak self] in self?.onBeat?(intensity) }
            }
    }

    // MARK: - Stream bytes → decoder (runs on decodeQueue)

    private func processStreamBytes(_ data: Data) {
        let audio = icyParser?.consume(data) { [weak self] title in
            DispatchQueue.main.async { self?.applyStreamTitle(title) }
        } ?? data
        guard let stream = audioFileStream, !audio.isEmpty else { return }
        audio.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            AudioFileStreamParseBytes(stream, UInt32(audio.count), base, [])
        }
    }

    private func applyStreamTitle(_ title: String) {
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 2 {
            nowPlayingTitle  = parts[1...].joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            nowPlayingArtist = parts[0].trimmingCharacters(in: .whitespaces)
        } else {
            nowPlayingTitle  = title
            nowPlayingArtist = ""
        }
        fetchTrackArtwork(query: title)
        updateNowPlaying()
        if let station = currentStation {
            history.log(title: title, station: station.name)
            if let data = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(data, forKey: "listen_history")
            }
        }
    }

    // MARK: - Track artwork (iTunes Search — no key, no account)

    private func fetchTrackArtwork(query rawQuery: String) {
        artworkTask?.cancel()
        trackArtwork = nil
        trackLink    = nil
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        if let hit = artworkCache[query] {
            trackArtwork = hit.art
            trackLink    = hit.link
            return
        }

        artworkTask = Task { [weak self] in
            guard let found = await RadioEngine.lookupTrack(query: query) else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.artworkCache[query] = found
                self.trackArtwork = found.art
                self.trackLink    = found.link
                self.updateNowPlaying()
            }
        }
    }

    private static func lookupTrack(query: String) async -> (art: MPMediaItemArtwork, link: URL?)? {
        struct SearchResponse: Codable {
            struct Result: Codable {
                let artworkUrl100: String?
                let trackViewUrl:  String?
            }
            let results: [Result]
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://itunes.apple.com/search?media=music&limit=1&term=\(encoded)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response  = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let result    = response.results.first,
              let thumbUrl  = result.artworkUrl100,
              let artUrl    = URL(string: thumbUrl.replacingOccurrences(of: "100x100", with: "600x600")),
              let (imgData, _) = try? await URLSession.shared.data(from: artUrl),
              let image = UIImage(data: imgData) else { return nil }
        let art  = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        let link = result.trackViewUrl.flatMap(URL.init(string:))
        return (art, link)
    }

    // MARK: - Audio session

    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw  = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended, self.isPlaying,
                  let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self.decodeQueue.async {
                try? self.audioEngine.start()
                if self.nodeStarted { self.playerNode?.play() }
            }
        }
    }

    // MARK: - Energy timer

    private func startEnergyTimer() {
        stopEnergyTimer()
        bassSmoothed   = 0
        midSmoothed    = 0
        trebleSmoothed = 0
        tapBass        = 0
        tapMid         = 0
        tapTreble      = 0

        // Fresh hearing per station — the previous stream's loudness must not leak in
        bassNorm   = AdaptiveNormalizer(halflife: 4, gate: 1e-3)
        midNorm    = AdaptiveNormalizer(halflife: 4, gate: 1e-3)
        trebleNorm = AdaptiveNormalizer(halflife: 4, gate: 1e-3)
        bassOnset  = OnsetDetector(sensitivity: 2.2, refractory: 0.12, minFlux: 0.005)
        tempo.reset()
        meterClock = 0
        bassEnv    = EnvelopeFollower(attack: 0.6, release: 2.5)
        midEnv     = EnvelopeFollower(attack: 0.8, release: 3.0)
        trebleEnv  = EnvelopeFollower(attack: 0.5, release: 2.0)

        energyTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let dt = 1.0 / 60.0
            self.bassSmoothed   = self.bassEnv.process(self.tapBass,     dt: dt)
            self.midSmoothed    = self.midEnv.process(self.tapMid,       dt: dt)
            self.trebleSmoothed = self.trebleEnv.process(self.tapTreble, dt: dt)
            self.onEnergyUpdate?(self.bassSmoothed, self.midSmoothed, self.trebleSmoothed)
        }
    }

    private func stopEnergyTimer() {
        energyTimer?.invalidate()
        energyTimer = nil
        tapBass     = 0
        tapMid      = 0
        tapTreble   = 0
    }

    // MARK: - Remote commands

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.isEnabled = true
        c.playCommand.addTarget { [weak self] _ in
            guard let self else { return .success }
            if let s = self.currentStation { self.play(s) }
            else if let first = self.stations.first { self.play(first) }
            return .success
        }
        c.pauseCommand.isEnabled = true
        c.pauseCommand.addTarget { [weak self] _ in self?.stop(); return .success }
        c.stopCommand.isEnabled  = true
        c.stopCommand.addTarget  { [weak self] _ in self?.stop(); return .success }

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
        info[MPMediaItemPropertyTitle]      = nowPlayingTitle.isEmpty  ? (currentStation?.name    ?? "Minify Radio") : nowPlayingTitle
        info[MPMediaItemPropertyArtist]     = nowPlayingArtist.isEmpty ? (currentStation?.tagline ?? "") : nowPlayingArtist
        info[MPMediaItemPropertyAlbumTitle] = currentStation?.name ?? "Minify Radio"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        if let station = currentStation {
            info[MPMediaItemPropertyArtwork] = trackArtwork ?? WaveArt.artwork(for: station)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState  = isPlaying ? .playing : .paused
    }

    // MARK: - Persist

    private func saveStations() {
        if let data = try? JSONEncoder().encode(stations) {
            UserDefaults.standard.set(data, forKey: "radio_stations")
        }
    }

    // MARK: - Accent colour

    private func accentForName(_ name: String) -> String {
        var h: Int = 0
        for c in name.unicodeScalars { h = (h &* 31) &+ Int(c.value) }
        return hslToHex(hue: Double(abs(h) % 360), saturation: 0.70, lightness: 0.50)
    }

    private func hslToHex(hue: Double, saturation: Double, lightness: Double) -> String {
        let s = saturation, l = lightness
        let a = s * min(l, 1 - l)
        func f(_ n: Double) -> Int {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            return Int(round(255 * (l - a * max(min(k - 3, min(9 - k, 1)), -1))))
        }
        return String(format: "#%02X%02X%02X", f(0), f(8), f(4))
    }
}

// MARK: - URLSession streaming delegate

extension RadioEngine: URLSessionDataDelegate {

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if dataTask === streamTask, let http = response as? HTTPURLResponse {
            let headers = Dictionary(uniqueKeysWithValues:
                http.allHeaderFields.compactMap { k, v -> (String, Any)? in
                    guard let key = k as? String else { return nil }
                    return (key.lowercased(), v)
                })
            let parsed = (headers["icy-metaint"] as? String).flatMap(Int.init) ?? 0
            decodeQueue.async { [weak self] in
                self?.icyParser = parsed > 0 ? IcyParser(metaInt: parsed) : nil
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard dataTask === streamTask else { return }
        decodeQueue.async { [weak self] in
            // Re-check inside the queue: stop() may have fired between the guard above
            // and this block running, in which case streamTask will have changed.
            guard let self, dataTask === self.streamTask else { return }
            self.processStreamBytes(data)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard task === streamTask else { return }
        if let err = error as NSError?, err.code == NSURLErrorCancelled { return }
        // The one connection died — live radio shouldn't end, so keep trying
        // while the user still expects playback.
        DispatchQueue.main.async { [weak self] in self?.scheduleReconnect() }
    }
}
