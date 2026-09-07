import Foundation

/// Splits an ICY (Icecast/Shoutcast) byte stream into audio bytes and stream titles.
/// Pure state machine — no I/O — so chunk-boundary behaviour is fully testable.
///
/// Wire format: `metaInt` audio bytes, then 1 length byte (× 16 = metadata bytes),
/// then that much metadata, repeating. Any of these can split across network chunks.
struct IcyParser {

    private let metaInt: Int
    private var audioRemaining: Int
    private var metaRemaining  = 0
    private var awaitingLength = false
    private var metaBuffer     = Data()

    init(metaInt: Int) {
        self.metaInt   = metaInt
        audioRemaining = metaInt
    }

    /// Feed one network chunk. Returns the audio bytes it contained;
    /// calls `onTitle` once per complete metadata block that carried a title.
    mutating func consume(_ data: Data, onTitle: (String) -> Void) -> Data {
        guard metaInt > 0 else { return data }
        var audio = Data(capacity: data.count)
        var i = data.startIndex

        while i < data.endIndex {
            if metaRemaining > 0 {
                let take = min(metaRemaining, data.endIndex - i)
                metaBuffer.append(data[i ..< i + take])
                metaRemaining -= take
                i += take
                if metaRemaining == 0 {
                    if let title = IcyParser.title(from: metaBuffer) { onTitle(title) }
                    metaBuffer.removeAll(keepingCapacity: true)
                }
            } else if awaitingLength {
                metaRemaining  = Int(data[i]) * 16
                awaitingLength = false
                audioRemaining = metaInt
                i += 1
            } else {
                let take = min(audioRemaining, data.endIndex - i)
                audio.append(data[i ..< i + take])
                audioRemaining -= take
                i += take
                if audioRemaining == 0 { awaitingLength = true }
            }
        }
        return audio
    }

    /// Extracts the value of `StreamTitle='…';` from a metadata block.
    static func title(from data: Data) -> String? {
        let raw = data.filter { $0 != 0 }
        guard let str = String(bytes: raw, encoding: .utf8),
              let s1  = str.range(of: "StreamTitle='"),
              let s2  = str.range(of: "'", range: s1.upperBound ..< str.endIndex) else { return nil }
        let title = String(str[s1.upperBound ..< s2.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}
