import CoreMedia
import CoreVideo
import XCTest

// MARK: - Fan-out

/// The seam every consumer of the picture arrives through. Nothing here needs
/// a camera, a session or a window: the distributor's whole job is who gets
/// handed what, and that is decided by registration alone.
final class NCFrameDistributorTests: XCTestCase {
    // MARK: - A sink that only remembers

    /// Records what it was given, and appends its own name to a shared log so
    /// the order sinks are called in can be asserted across several of them.
    private final class RecordingSink: NCFrameSink {
        let name: String
        private let log: Log

        private(set) var frames: [(buffer: CVPixelBuffer, time: CMTime)] = []

        final class Log {
            private(set) var names: [String] = []
            func append(_ name: String) { names.append(name) }
        }

        init(_ name: String, log: Log = Log()) {
            self.name = name
            self.log = log
        }

        func receive(_ frame: CVPixelBuffer, at time: CMTime) {
            frames.append((frame, time))
            log.append(name)
        }
    }

    // MARK: - Registration

    func testARegisteredSinkIsHandedTheFrameAndItsTime() throws {
        let distributor = NCFrameDistributor()
        let sink = RecordingSink("only")
        let buffer = try makePixelBuffer()
        let time = CMTime(value: 1234, timescale: 600)

        distributor.add(sink)
        XCTAssertEqual(distributor.sinkCount, 1)
        distributor.deliver(buffer, at: time)

        XCTAssertEqual(sink.frames.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(sink.frames.first).buffer === buffer,
            "the sink is handed the very buffer that was delivered, not a copy")
        XCTAssertEqual(try XCTUnwrap(sink.frames.first).time, time)
    }

    func testAnUnregisteredDistributorDeliversToNobody() throws {
        let distributor = NCFrameDistributor()
        XCTAssertEqual(distributor.sinkCount, 0)

        // Delivering with nothing registered is the state the app is in
        // between capture sessions, and must not be an error.
        distributor.deliver(try makePixelBuffer(), at: .zero)
    }

    /// A sink registered twice would encode, or write to disk, every frame
    /// twice.
    func testRegisteringTheSameSinkTwiceStillDeliversOnce() throws {
        let distributor = NCFrameDistributor()
        let sink = RecordingSink("doubled")

        distributor.add(sink)
        distributor.add(sink)

        XCTAssertEqual(distributor.sinkCount, 1)
        distributor.deliver(try makePixelBuffer(), at: .zero)
        XCTAssertEqual(sink.frames.count, 1)
    }

    // MARK: - Fan-out

    func testEverySinkReceivesEveryFrameInRegistrationOrder() throws {
        let distributor = NCFrameDistributor()
        let log = RecordingSink.Log()
        let first = RecordingSink("first", log: log)
        let second = RecordingSink("second", log: log)
        let third = RecordingSink("third", log: log)

        distributor.add(first)
        distributor.add(second)
        distributor.add(third)
        XCTAssertEqual(distributor.sinkCount, 3)

        distributor.deliver(try makePixelBuffer(), at: CMTime(value: 1, timescale: 600))
        distributor.deliver(try makePixelBuffer(), at: CMTime(value: 2, timescale: 600))

        for sink in [first, second, third] {
            XCTAssertEqual(sink.frames.count, 2, "\(sink.name) saw both frames")
        }
        XCTAssertEqual(
            log.names, ["first", "second", "third", "first", "second", "third"],
            "registration order is delivery order, frame after frame")
    }

    func testSinksAreHandedTheSameBufferAsEachOther() throws {
        let distributor = NCFrameDistributor()
        let first = RecordingSink("first")
        let second = RecordingSink("second")
        let buffer = try makePixelBuffer()

        distributor.add(first)
        distributor.add(second)
        distributor.deliver(buffer, at: .zero)

        XCTAssertTrue(try XCTUnwrap(first.frames.first).buffer === buffer)
        XCTAssertTrue(
            try XCTUnwrap(second.frames.first).buffer === buffer,
            "one processed frame reaches every consumer; nothing is rendered twice")
    }

    // MARK: - Removal

    func testARemovedSinkStopsReceivingAndTheRestCarryOn() throws {
        let distributor = NCFrameDistributor()
        let staying = RecordingSink("staying")
        let leaving = RecordingSink("leaving")

        distributor.add(staying)
        distributor.add(leaving)
        distributor.deliver(try makePixelBuffer(), at: .zero)

        distributor.remove(leaving)
        XCTAssertEqual(distributor.sinkCount, 1)
        distributor.deliver(try makePixelBuffer(), at: .zero)

        XCTAssertEqual(leaving.frames.count, 1, "the frame from before it left, and no more")
        XCTAssertEqual(staying.frames.count, 2)
    }

    func testRemovingASinkThatWasNeverRegisteredChangesNothing() throws {
        let distributor = NCFrameDistributor()
        let registered = RecordingSink("registered")
        let stranger = RecordingSink("stranger")

        distributor.add(registered)
        distributor.remove(stranger)

        XCTAssertEqual(distributor.sinkCount, 1)
        distributor.deliver(try makePixelBuffer(), at: .zero)
        XCTAssertEqual(registered.frames.count, 1)
        XCTAssertEqual(stranger.frames.count, 0)
    }

    // MARK: - Synthesised pixel buffers

    /// The distributor never looks inside a buffer, so the smallest one the
    /// capture pixel format allows is enough.
    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        return try XCTUnwrap(buffer, "CVPixelBufferCreate returned \(status)")
    }
}
