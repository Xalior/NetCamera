import CoreMedia
import CoreVideo
import XCTest

// MARK: - MJPEG

/// The stream's two halves that can be decided without a network: what a part
/// looks like on the wire, and who a frame is encoded for. Nothing here needs a
/// camera, a window or a server — the framing is bytes, and the bookkeeping is
/// counting.
final class NCMJPEGSinkTests: XCTestCase {
    // MARK: - Framing

    func testAPartCarriesTheBoundaryItsTypeAndItsLength() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
        let part = NCMJPEGFraming.part(for: jpeg)

        let expected =
            Data("--\(NCMJPEGFraming.boundary)\r\n".utf8)
            + Data("Content-Type: image/jpeg\r\n".utf8)
            + Data("Content-Length: 8\r\n\r\n".utf8)
            + jpeg
            + Data("\r\n".utf8)
        XCTAssertEqual(part, expected)
    }

    /// The stated length must be the length of the picture alone. A client
    /// reads exactly that many bytes, so a length that counts the headers or
    /// the trailing break puts every following part out of step.
    func testTheStatedLengthIsThePictureAndNothingElse() throws {
        for size in [1, 2, 1024, 65_537] {
            let jpeg = Data(repeating: 0x5A, count: size)
            let part = NCMJPEGFraming.part(for: jpeg)

            let header = try XCTUnwrap(headerOf(part))
            let stated = try XCTUnwrap(
                contentLength(in: header), "every part states a Content-Length")
            XCTAssertEqual(stated, size)

            // And the body really is that long: what follows the blank line is
            // the picture, then the break that ends the part.
            let body = part.dropFirst(header.count)
            XCTAssertEqual(body.count, size + 2)
            XCTAssertEqual(Data(body.prefix(size)), jpeg)
            XCTAssertEqual(Data(body.suffix(2)), Data("\r\n".utf8))
        }
    }

    func testTheContentTypeNamesTheBoundaryTheStreamActuallyUses() {
        XCTAssertEqual(
            NCMJPEGFraming.contentType,
            "multipart/x-mixed-replace; boundary=\(NCMJPEGFraming.boundary)")
        // The client splits on the boundary it was told about, so the two
        // agreeing is the whole contract.
        XCTAssertTrue(
            NCMJPEGFraming.part(for: Data([0x00])).starts(
                with: Array("--\(NCMJPEGFraming.boundary)\r\n".utf8)))
    }

    func testTheTerminatorClosesTheMultipartBody() {
        XCTAssertEqual(
            NCMJPEGFraming.terminator, Data("--\(NCMJPEGFraming.boundary)--\r\n".utf8))
    }

    // MARK: - Nobody watching

    /// The plan's criterion, as a test: with no client connected the sink must
    /// not encode. Encoding and discarding would put the cost of a stream
    /// nobody is watching on every idle Mac.
    func testAFrameWithNoClientsIsNotEncodedAtAll() throws {
        let encoder = CountingEncoder()
        let sink = NCMJPEGSink(encoder: encoder.encode)

        XCTAssertEqual(sink.clientCount, 0)
        for _ in 0..<30 {
            sink.receive(try makePixelBuffer(), at: .zero)
        }

        XCTAssertEqual(encoder.calls, 0, "nobody is watching, so nothing is encoded")
    }

    func testAClientThatHasBeenClosedTakesTheEncodeCostWithIt() throws {
        let encoder = CountingEncoder()
        let sink = NCMJPEGSink(encoder: encoder.encode)
        sink.setLive(true)

        let client = try XCTUnwrap(sink.open())
        sink.receive(try makePixelBuffer(), at: .zero)
        XCTAssertEqual(encoder.calls, 1)

        sink.close(client)
        XCTAssertEqual(sink.clientCount, 0, "a client that left is gone from the registry")
        sink.receive(try makePixelBuffer(), at: .zero)
        XCTAssertEqual(encoder.calls, 1, "the last client leaving stops the encoder")
    }

    // MARK: - One encode, however many are watching

    func testTwoClientsCostOneEncodeAndBothGetTheSameBytes() async throws {
        let encoder = CountingEncoder()
        let sink = NCMJPEGSink(encoder: encoder.encode)
        sink.setLive(true)

        let first = try XCTUnwrap(sink.open())
        let second = try XCTUnwrap(sink.open())
        XCTAssertEqual(sink.clientCount, 2)

        sink.receive(try makePixelBuffer(), at: .zero)

        XCTAssertEqual(encoder.calls, 1, "one frame is one encode, whoever is watching")

        let offeredToFirst: Data? = await nextPart(of: first)
        let offeredToSecond: Data? = await nextPart(of: second)
        let firstPart = try XCTUnwrap(offeredToFirst)
        let secondPart = try XCTUnwrap(offeredToSecond)
        XCTAssertEqual(firstPart, secondPart, "both clients are offered the identical bytes")
        XCTAssertEqual(firstPart, NCMJPEGFraming.part(for: encoder.picture))
    }

    /// One frame delivered is one part offered — not none, and not two.
    func testEveryClientIsOfferedEveryFrameOnce() async throws {
        let encoder = CountingEncoder()
        let sink = NCMJPEGSink(encoder: encoder.encode)
        sink.setLive(true)
        let client = try XCTUnwrap(sink.open())

        sink.receive(try makePixelBuffer(), at: .zero)
        sink.close(client)

        let parts: [Data] = await everythingOffered(to: client)
        XCTAssertEqual(parts, [NCMJPEGFraming.part(for: encoder.picture)])
    }

    // MARK: - Leaving

    /// A client the sink still holds after its connection has gone is a
    /// phantom: it keeps the encoder running for nobody, for as long as the app
    /// is up.
    func testAClosedClientReceivesNothingFurtherAndItsStreamEnds() async throws {
        let encoder = CountingEncoder()
        let sink = NCMJPEGSink(encoder: encoder.encode)
        sink.setLive(true)
        let leaving = try XCTUnwrap(sink.open())
        let staying = try XCTUnwrap(sink.open())

        sink.receive(try makePixelBuffer(), at: .zero)
        sink.close(leaving)
        XCTAssertEqual(sink.clientCount, 1, "the one that stayed, and only it")

        sink.receive(try makePixelBuffer(), at: .zero)
        XCTAssertEqual(encoder.calls, 2, "the remaining client is still served")

        // The departed client's stream carries what it was already owed and
        // then ends, which is what lets whoever was writing it stop waiting.
        let deliveredToLeaver: [Data] = await everythingOffered(to: leaving)
        XCTAssertEqual(deliveredToLeaver.count, 1, "the frame from before it left, and no more")

        let offeredToStaying: Data? = await nextPart(of: staying)
        XCTAssertNotNil(offeredToStaying, "the client that stayed is still being served")
    }

    func testClosingAClientTwiceIsHarmless() throws {
        let sink = NCMJPEGSink(encoder: CountingEncoder().encode)
        sink.setLive(true)
        let client = try XCTUnwrap(sink.open())

        sink.close(client)
        sink.close(client)
        XCTAssertEqual(sink.clientCount, 0)
    }

    // MARK: - Keeping up

    /// A client on a bad network must lose frames rather than hold up the
    /// capture queue, which also feeds the window. The sink offers and returns;
    /// what a slow client eventually reads is the newest picture, not a backlog
    /// of stale ones.
    func testASlowClientIsLeftWithTheNewestFrameNotABacklog() async throws {
        let encoder = CountingEncoder()
        let sink = NCMJPEGSink(encoder: encoder.encode)
        sink.setLive(true)
        let client = try XCTUnwrap(sink.open())

        for value in 1...50 {
            encoder.picture = Data([UInt8(value)])
            sink.receive(try makePixelBuffer(), at: .zero)
        }

        let offered: Data? = await nextPart(of: client)
        XCTAssertEqual(
            offered, NCMJPEGFraming.part(for: Data([50])),
            "what a client that never read gets is the picture as it is now")
    }

    // MARK: - Nothing to send

    /// A sink nobody has told there is a picture does not claim one. This is
    /// what a client connecting with no camera meets: a refusal it can act on,
    /// rather than a stream that is opened and then never carries a byte.
    func testASinkWithNoPictureRefusesToOpenAStream() {
        let sink = NCMJPEGSink(encoder: CountingEncoder().encode)

        XCTAssertFalse(sink.isLive, "a sink that has been told nothing claims nothing")
        XCTAssertNil(sink.open(), "there is no picture, so there is no stream to open")
        XCTAssertEqual(sink.clientCount, 0)
    }

    func testSayingThePictureIsFlowingIsWhatOpensTheStream() throws {
        let sink = NCMJPEGSink(encoder: CountingEncoder().encode)

        sink.setLive(true)
        XCTAssertTrue(sink.isLive)
        let client = try XCTUnwrap(sink.open())
        XCTAssertEqual(sink.clientCount, 1)

        sink.close(client)
    }

    /// The camera being unplugged while somebody is watching. Their stream ends
    /// rather than freezing on its last frame for ever, which is what lets
    /// whoever is writing it finish the response properly.
    func testThePictureStoppingEndsEveryStreamInProgress() async throws {
        let encoder = CountingEncoder()
        let sink = NCMJPEGSink(encoder: encoder.encode)
        sink.setLive(true)
        let watching = try XCTUnwrap(sink.open())

        sink.receive(try makePixelBuffer(), at: .zero)
        sink.setLive(false)

        XCTAssertEqual(sink.clientCount, 0, "nobody is left watching a picture that stopped")
        let delivered: [Data] = await everythingOffered(to: watching)
        XCTAssertEqual(
            delivered, [NCMJPEGFraming.part(for: encoder.picture)],
            "the frame from before it stopped, and then the end of the stream")
    }

    /// And no new client is taken on in the meantime.
    func testNoStreamIsOpenedOnceThePictureHasStopped() throws {
        let sink = NCMJPEGSink(encoder: CountingEncoder().encode)
        sink.setLive(true)
        let first = try XCTUnwrap(sink.open())
        sink.close(first)

        sink.setLive(false)
        XCTAssertNil(sink.open())
        XCTAssertEqual(sink.clientCount, 0)
    }

    /// Saying the same thing twice changes nothing, which matters because every
    /// capture start says it and a hot-plug can produce several in a row.
    func testSayingThePictureIsFlowingTwiceKeepsTheClientsItAlreadyHas() throws {
        let sink = NCMJPEGSink(encoder: CountingEncoder().encode)
        sink.setLive(true)
        let client = try XCTUnwrap(sink.open())

        sink.setLive(true)
        XCTAssertEqual(sink.clientCount, 1, "a client is not thrown out by good news")

        sink.close(client)
    }

    // MARK: - Helpers

    /// Stands in for Core Image. Counts how often it was asked, which is the
    /// only way to tell an encode that did not happen from one that happened
    /// and was thrown away.
    private final class CountingEncoder {
        private(set) var calls = 0
        var picture = Data([0xFF, 0xD8, 0xFF, 0xD9])

        func encode(_ frame: CVPixelBuffer) -> Data? {
            calls += 1
            return picture
        }
    }

    /// The next part a client is offered, or nil if its stream ended first.
    /// A client's stream is iterated once and once only, as any single-consumer
    /// stream is, so no test asks a client for both this and everything.
    private func nextPart(of client: NCMJPEGClient) async -> Data? {
        var iterator = client.parts.makeAsyncIterator()
        return await iterator.next()
    }

    /// Everything a closed client was offered before its stream ended. Only
    /// meaningful once the client has been closed; on a live one it would wait
    /// for the next frame for ever.
    private func everythingOffered(to client: NCMJPEGClient) async -> [Data] {
        var parts: [Data] = []
        for await part in client.parts { parts.append(part) }
        return parts
    }

    /// Everything up to and including the blank line that ends a part's
    /// headers.
    private func headerOf(_ part: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = part.range(of: separator) else { return nil }
        return part[part.startIndex..<range.upperBound]
    }

    private func contentLength(in header: Data) -> Int? {
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\r\n")
        where line.lowercased().hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// A buffer of the shape the capture path produces. The sink never looks
    /// inside one — its encoder does — so the smallest the pixel format allows
    /// is enough.
    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        return try XCTUnwrap(buffer, "CVPixelBufferCreate returned \(status)")
    }
}
