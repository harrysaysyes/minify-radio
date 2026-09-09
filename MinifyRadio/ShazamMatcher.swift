import ShazamKit
import AVFoundation

/// Identifies tracks on stations that don't send ICY titles, by matching the
/// audio already flowing through the output tap against the Shazam catalog.
/// No microphone involved — the decoded stream is fed straight in.
final class ShazamMatcher: NSObject, SHSessionDelegate {

    /// Called on the main queue with the matched item.
    var onMatch: ((SHMatchedMediaItem) -> Void)?

    /// Called on the main queue when an attempt's listen window closes unmatched.
    var onNoMatch: (() -> Void)?

    private let lock = NSLock()
    private var session: SHSession?
    private var listenedSeconds = 0.0
    private var monoBuffer: AVAudioPCMBuffer?

    /// How much audio one attempt may consume before giving up.
    private let listenWindow = 12.0

    func beginAttempt() {
        lock.lock()
        defer { lock.unlock() }
        let s = SHSession()
        s.delegate = self
        session = s
        listenedSeconds = 0
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        session = nil
    }

    /// Feed one tap buffer; called on the audio tap queue for every buffer,
    /// cheap no-op unless an attempt is active.
    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        lock.lock()
        guard let s = session else { lock.unlock(); return }
        listenedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        var expired = false
        if listenedSeconds > listenWindow {   // this attempt is over
            session = nil
            expired = true
        }
        let mono = downmixedToMono(buffer)
        lock.unlock()
        if expired {
            DispatchQueue.main.async { [weak self] in self?.onNoMatch?() }
            return
        }
        s.matchStreamingBuffer(mono, at: time)
    }

    /// ShazamKit only accepts mono PCM — the output tap delivers stereo.
    private func downmixedToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let channels = Int(buffer.format.channelCount)
        let frames   = Int(buffer.frameLength)
        guard channels > 1, frames > 0, let src = buffer.floatChannelData else { return buffer }

        if monoBuffer == nil
            || monoBuffer!.format.sampleRate != buffer.format.sampleRate
            || monoBuffer!.frameCapacity < AVAudioFrameCount(frames) {
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate,
                                          channels: 1),
                  let fresh = AVAudioPCMBuffer(pcmFormat: fmt,
                                               frameCapacity: max(4096, AVAudioFrameCount(frames)))
            else { return buffer }
            monoBuffer = fresh
        }
        let mono = monoBuffer!
        mono.frameLength = AVAudioFrameCount(frames)
        guard let dst = mono.floatChannelData?[0] else { return buffer }

        let scale = 1.0 / Float(channels)
        for i in 0 ..< frames {
            var sum: Float = 0
            for ch in 0 ..< channels { sum += src[ch][i] }
            dst[i] = sum * scale
        }
        return mono
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        cancel()
        guard let item = match.mediaItems.first else { return }
        DispatchQueue.main.async { [weak self] in self?.onMatch?(item) }
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        // Keep listening — more audio may still match before the window closes.
        #if DEBUG
        if let error { print("shazam error: \(error)") }
        #endif
    }
}
