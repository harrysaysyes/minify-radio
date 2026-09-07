import XCTest

final class IcyParserTests: XCTestCase {

    /// Builds a length byte + null-padded metadata block for `StreamTitle='…';`.
    private func metaBlock(_ content: String) -> Data {
        var body = Data(content.utf8)
        let padded = max(16, ((body.count + 15) / 16) * 16)
        body.append(Data(repeating: 0, count: padded - body.count))
        return Data([UInt8(padded / 16)]) + body
    }

    private func consumeAll(_ parser: inout IcyParser, chunks: [Data]) -> (audio: Data, titles: [String]) {
        var audio  = Data()
        var titles = [String]()
        for chunk in chunks {
            audio += parser.consume(chunk) { titles.append($0) }
        }
        return (audio, titles)
    }

    func testZeroLengthMetadataPassesAudioThrough() {
        var p = IcyParser(metaInt: 4)
        let (audio, titles) = consumeAll(&p, chunks: [Data([1, 2, 3, 4, 0, 5, 6, 7, 8, 0])])
        XCTAssertEqual(audio, Data([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertTrue(titles.isEmpty)
    }

    func testParsesTitleInSingleChunk() {
        var p = IcyParser(metaInt: 2)
        let chunk = Data([9, 9]) + metaBlock("StreamTitle='Artist - Song';") + Data([8, 8])
        let (audio, titles) = consumeAll(&p, chunks: [chunk])
        XCTAssertEqual(audio, Data([9, 9, 8, 8]))
        XCTAssertEqual(titles, ["Artist - Song"])
    }

    func testMetadataSpanningChunksStillParses() {
        var p = IcyParser(metaInt: 2)
        let full = Data([1, 2]) + metaBlock("StreamTitle='Long Song Name';") + Data([3, 4])
        let cut  = 2 + 1 + 5   // audio + length byte + 5 bytes into the metadata
        let (audio, titles) = consumeAll(&p, chunks: [full.prefix(cut), full.dropFirst(cut)])
        XCTAssertEqual(audio, Data([1, 2, 3, 4]))
        XCTAssertEqual(titles, ["Long Song Name"])
    }

    func testLengthByteAtChunkBoundary() {
        var p = IcyParser(metaInt: 3)
        let chunk1 = Data([1, 2, 3])            // audio ends exactly at chunk end
        let chunk2 = metaBlock("StreamTitle='X';") + Data([4])
        let (audio, titles) = consumeAll(&p, chunks: [chunk1, chunk2])
        XCTAssertEqual(audio, Data([1, 2, 3, 4]))
        XCTAssertEqual(titles, ["X"])
    }

    func testMultipleTitlesInOneChunk() {
        var p = IcyParser(metaInt: 1)
        let chunk = Data([1]) + metaBlock("StreamTitle='A';")
                  + Data([2]) + metaBlock("StreamTitle='B';")
        let (audio, titles) = consumeAll(&p, chunks: [chunk])
        XCTAssertEqual(audio, Data([1, 2]))
        XCTAssertEqual(titles, ["A", "B"])
    }

    func testByteByByteDelivery() {
        var p = IcyParser(metaInt: 2)
        let full = Data([7, 7]) + metaBlock("StreamTitle='Drip';") + Data([6, 6])
        let (audio, titles) = consumeAll(&p, chunks: full.map { Data([$0]) })
        XCTAssertEqual(audio, Data([7, 7, 6, 6]))
        XCTAssertEqual(titles, ["Drip"])
    }

    func testTitleExtraction() {
        XCTAssertEqual(IcyParser.title(from: Data("StreamTitle='A - B';".utf8)), "A - B")
        XCTAssertNil(IcyParser.title(from: Data("StreamUrl='x';".utf8)))
        XCTAssertNil(IcyParser.title(from: Data("StreamTitle='';".utf8)))
        XCTAssertNil(IcyParser.title(from: Data([0xFF, 0xFE])))
    }
}
