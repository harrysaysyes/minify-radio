import AVFoundation
import MediaPlayer
import AudioToolbox
import Accelerate

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

    var onEnergyUpdate: ((Double) -> Void)?

    // MARK: - Streaming engine

    private var player:          AVPlayer?          // Job 1: playback
    private var audioFileStream: AudioFileStreamID? // Job 2: metering
    private var audioConverter:  AudioConverterRef?
    private var pcmFormat:       AVAudioFormat?
    private var streamTask:      URLSessionDataTask?

    private var icyMetaInt:      Int = 0
    private var icyBytesRead:    Int = 0
    private var icyMetaRemaining: Int = 0  // metadata bytes still to skip into next chunk

    /// Serial queue that owns all decode state. stop() uses sync to drain it before teardown,
    /// guaranteeing no in-flight decode work can race with audioFileStream/audioConverter teardown.
    private let decodeQueue = DispatchQueue(label: "radio.decode", qos: .userInitiated)

    private lazy var streamSession: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Energy

    private var energyTimer:    Timer?
    private var energyPhase:    Double = 0
    private var energySmoothed: Double = 0
    private var tapRMS: Double = 0

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
        if isPlaying && currentStation?.id == station.id { stop() }
        else { play(station) }
    }

    func stop() {
        // Cancel metering stream first
        streamTask?.cancel()
        streamTask = nil

        // Block until any in-progress decode work finishes, then tear down decode state.
        // This prevents the race where the URLSession bg thread is mid-parse while
        // the main thread disposes audioFileStream/audioConverter underneath it.
        decodeQueue.sync {
            if let s = audioFileStream { AudioFileStreamClose(s); audioFileStream = nil }
            if let c = audioConverter  { AudioConverterDispose(c); audioConverter  = nil }
            pcmFormat = nil; icyMetaInt = 0; icyBytesRead = 0; icyMetaRemaining = 0
        }

        // Stop playback
        player?.pause()
        player = nil

        stopEnergyTimer()
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

        // Job 1: Playback — AVPlayer handles Icecast, buffering, reconnection
        player = AVPlayer(playerItem: AVPlayerItem(url: url))
        player?.play()

        currentStation   = station
        isPlaying        = true
        nowPlayingTitle  = "Connecting…"
        nowPlayingArtist = ""
        updateNowPlaying()
        startEnergyTimer()

        // Job 2: Metering — silent second connection for RMS + ICY metadata
        startMeteringStream(url: url, station: station)
    }

    private func startMeteringStream(url: URL, station: Station) {
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

    // MARK: - Converter setup (called by _afsPropertyListener on background URLSession thread)

    /// Called when stream format is known — sets up the converter for MP3→PCM decoding (metering only).
    fileprivate func setupConverter(inputFormat: AudioStreamBasicDescription) {
        guard audioConverter == nil else { return }

        var inFmt  = inputFormat
        let ch     = max(1, UInt32(inputFormat.mChannelsPerFrame))
        let sr     = inputFormat.mSampleRate > 0 ? inputFormat.mSampleRate : 44100.0

        // Non-interleaved float32 output — required by AVAudioPCMBuffer for RMS measurement.
        guard let stdFmt = AVAudioFormat(standardFormatWithSampleRate: sr,
                                         channels: AVAudioChannelCount(ch)) else { return }
        var outFmt = stdFmt.streamDescription.pointee

        var conv: AudioConverterRef?
        guard AudioConverterNew(&inFmt, &outFmt, &conv) == noErr, let c = conv else { return }
        audioConverter = c
        pcmFormat = stdFmt

        DispatchQueue.main.async { [weak self] in
            guard let self, self.nowPlayingTitle == "Connecting…" else { return }
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
            // Measure energy directly from decoded PCM — no engine needed, buffer discarded
            guard let chData = buffer.floatChannelData else { return }
            let frames  = Int(buffer.frameLength)
            let chCount = Int(buffer.format.channelCount)
            var sum: Float = 0
            for ch in 0..<chCount {
                let d = chData[ch]
                for i in 0..<frames { sum += d[i] * d[i] }
            }
            let rms = sqrt(sum / Float(max(1, frames * chCount)))
            tapRMS = tanh(Double(rms) * 5.0)
        }
    }

    // MARK: - ICY stream parsing

    private func processStreamBytes(_ data: Data) {
        guard let stream = audioFileStream else { return }

        func feedToStream(_ chunk: Data) {
            chunk.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                AudioFileStreamParseBytes(stream, UInt32(chunk.count), base, [])
            }
        }

        guard icyMetaInt > 0 else { feedToStream(data); return }

        let bytes  = [UInt8](data)
        var offset = 0

        // A metadata block from the previous chunk may still need skipping.
        // If we don't track this, the metadata bytes are treated as audio → noise.
        if icyMetaRemaining > 0 {
            let skip = min(icyMetaRemaining, bytes.count)
            icyMetaRemaining -= skip
            offset += skip
            if offset >= bytes.count { return }
        }

        while offset < bytes.count {
            let remaining = icyMetaInt - icyBytesRead
            let available = bytes.count - offset

            if available < remaining {
                feedToStream(Data(bytes[offset...]))
                icyBytesRead += available
                break
            }

            // Complete one audio block
            feedToStream(Data(bytes[offset..<offset + remaining]))
            offset += remaining
            icyBytesRead = 0

            // Read 1-byte metadata length indicator
            guard offset < bytes.count else { break }
            let metaLen = Int(bytes[offset]) * 16
            offset += 1

            if metaLen > 0 {
                let metaAvail = bytes.count - offset
                if metaAvail >= metaLen {
                    // Whole metadata block is in this chunk — parse it
                    parseIcyMetadata(Data(bytes[offset..<offset + metaLen]))
                    offset += metaLen
                } else {
                    // Metadata block spans into the next chunk.
                    // Track how many bytes to skip on arrival; we lose this title update
                    // but that's far better than feeding metadata bytes to the audio decoder.
                    icyMetaRemaining = metaLen - metaAvail
                    break  // consumed all remaining bytes in this chunk
                }
            }
        }
    }

    private func parseIcyMetadata(_ data: Data) {
        let raw = data.filter { $0 != 0 }
        guard let str = String(bytes: raw, encoding: .utf8) else { return }
        guard let s1 = str.range(of: "StreamTitle='"),
              let s2 = str.range(of: "'", range: s1.upperBound..<str.endIndex) else { return }
        let title = String(str[s1.upperBound..<s2.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let parts = title.components(separatedBy: " - ")
            if parts.count >= 2 {
                self.nowPlayingTitle  = parts[1...].joined(separator: " - ").trimmingCharacters(in: .whitespaces)
                self.nowPlayingArtist = parts[0].trimmingCharacters(in: .whitespaces)
            } else {
                self.nowPlayingTitle  = title
                self.nowPlayingArtist = ""
            }
            self.updateNowPlaying()
        }
    }

    // MARK: - Audio session

    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    // MARK: - Energy timer

    private func startEnergyTimer() {
        stopEnergyTimer()
        energyPhase    = 0
        energySmoothed = 0
        tapRMS         = 0

        energyTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.energyPhase += 1.0 / 60.0
            let t    = self.energyPhase
            let live = self.tapRMS

            if live > 0.01 {
                // At 60 fps: attack 0.15 ≈ 100 ms TC (matches web AnalyserNode 83 ms),
                // release 0.04 ≈ 370 ms TC for gradual tail-off.
                let alpha = live > self.energySmoothed ? 0.15 : 0.04
                self.energySmoothed += (live - self.energySmoothed) * alpha
            } else {
                let a = 0.5 + 0.5 * sin(t * 0.31)
                let b = 0.5 + 0.5 * sin(t * 0.71 + 2.1)
                let c = 0.5 + 0.5 * sin(t * 1.33 + 0.8)
                let target = a * 0.50 + b * 0.30 + c * 0.20
                // 0.02 lerp at 60 fps ≈ same 830 ms TC as 0.04 at 30 fps
                self.energySmoothed += (target - self.energySmoothed) * 0.02
            }
            self.onEnergyUpdate?(self.energySmoothed)
        }
    }

    private func stopEnergyTimer() {
        energyTimer?.invalidate()
        energyTimer = nil
        tapRMS      = 0
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
            if let val = headers["icy-metaint"] as? String {
                let parsed = Int(val) ?? 0
                decodeQueue.async { [weak self] in self?.icyMetaInt = parsed }
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
        // This is the metering stream — playback continues via AVPlayer unaffected.
        // On error, organic sine waves kick in automatically (tapRMS stays < 0.01).
    }
}
