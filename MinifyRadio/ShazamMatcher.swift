import ShazamKit
import AVFoundation

/// Identifies tracks on stations that don't send ICY titles, by matching the
/// audio already flowing through the output tap against the Shazam catalog.
/// No microphone involved — the decoded stream is fed straight in.
final class ShazamMatcher: NSObject, SHSessionDelegate {

    /// Called on the main queue with the matched item.
    var onMatch: ((SHMatchedMediaItem) -> Void)?

    private let lock = NSLock()
    private var session: SHSession?
    private var listenedSeconds = 0.0

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
        if listenedSeconds > listenWindow { session = nil }   // this attempt is over
        lock.unlock()
        s.matchStreamingBuffer(buffer, at: time)
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        cancel()
        guard let item = match.mediaItems.first else { return }
        DispatchQueue.main.async { [weak self] in self?.onMatch?(item) }
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        // Keep listening — more audio may still match before the window closes.
    }
}
