import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Multipart framing

/// The wire format of an MJPEG stream, and nothing else.
///
/// `multipart/x-mixed-replace` is the 2006-spec netcam: a response that never
/// ends, carrying one JPEG per part, each part replacing the last in whatever is
/// showing it. The bytes are decided here rather than inside the server's
/// response closure, because a format is a fact about the wire and can be
/// asserted byte for byte with no server, no socket and no camera present.
enum NCMJPEGFraming {
    /// Separates one picture from the next. Any token would do provided it
    /// cannot occur inside JPEG data; this one is fixed rather than generated
    /// per connection, because every client is sent the identical bytes and a
    /// per-connection boundary would mean framing each frame once per client.
    static let boundary: String = "netcameraframe"

    /// What the response says it is. The client is told the boundary here and
    /// nowhere else.
    static let contentType: String = "multipart/x-mixed-replace; boundary=\(boundary)"

    /// Wraps one encoded picture as one part.
    ///
    /// The length is stated rather than left to the reader to discover, so a
    /// client reads exactly the JPEG and does not have to scan its bytes for
    /// the next boundary — which is also what makes a boundary appearing by
    /// chance inside the data harmless.
    static func part(for jpeg: Data) -> Data {
        var part = Data()
        part.append(contentsOf: Array("--\(boundary)\r\n".utf8))
        part.append(contentsOf: Array("Content-Type: image/jpeg\r\n".utf8))
        part.append(contentsOf: Array("Content-Length: \(jpeg.count)\r\n\r\n".utf8))
        part.append(jpeg)
        part.append(contentsOf: Array("\r\n".utf8))
        return part
    }

    /// Closes the multipart body. A live stream ends when the client leaves and
    /// so is rarely sent, but a stream that ends any other way says so properly
    /// rather than simply stopping.
    static let terminator: Data = Data("--\(boundary)--\r\n".utf8)
}

// MARK: - A watching client

/// One browser watching the stream.
///
/// The frames a client is owed are held in an `AsyncStream` that keeps only the
/// newest one. That is the whole of the back-pressure policy, and it is
/// deliberate: frames arrive on the capture queue, which also feeds the window,
/// so a client on a bad network must lose frames rather than slow the pipeline
/// down for everybody. Latest-frame-wins is what live video means — a frame that
/// could not be sent in time is of no interest by the time it could be.
final class NCMJPEGClient: Sendable {
    /// The parts waiting to be written, newest only.
    let parts: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation

    init() {
        // A buffer of one: a client that cannot keep up is served the picture as
        // it is now, not the backlog of what it has missed.
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .bufferingNewest(1))
        self.parts = stream
        self.continuation = continuation
    }

    /// Offers a part. Never waits: if the client has not written the last one
    /// yet, this one takes its place.
    func offer(_ part: Data) {
        continuation.yield(part)
    }

    /// Ends the client's stream, which is what lets whoever is writing it finish
    /// rather than wait for a frame that will never come.
    func finish() {
        continuation.finish()
    }
}

// MARK: - MJPEG sink

/// Encodes the processed picture for everyone watching over the network.
///
/// It is a consumer of the frame exactly as the window is, and it has no
/// privileged copy of anything: the browser and the window are handed the same
/// processed buffer, so what one shows the other shows. The picture goes out at
/// the camera's own resolution and at no quality the client chose — a client
/// asks for the stream and nothing else, and scales what it gets, the way
/// resizing the app's own window scales rather than re-encodes.
///
/// The two costs it exists to control:
///
/// - **Nobody watching costs nothing.** With no client registered the frame is
///   returned on untouched; no JPEG is made and thrown away.
/// - **Everybody watching costs one encode.** A frame is encoded once and the
///   same bytes are offered to every client, so a second browser costs a write,
///   not a second trip through the encoder.
///
/// Clients are registered from the server's connection tasks and frames arrive
/// on the capture queue, so the registry is guarded by a lock held only long
/// enough to copy the list — a slow write can therefore never hold up the next
/// frame's delivery to the window.
final class NCMJPEGSink: NCFrameSink, @unchecked Sendable {
    // MARK: - Encoding

    /// Turns a processed frame into JPEG bytes, or nil if it cannot.
    /// A closure rather than a hard call so the sink's bookkeeping — who is
    /// watching, and how often the encoder runs — can be exercised without a
    /// camera or an image at all.
    typealias Encoder = (CVPixelBuffer) -> Data?

    /// The real encoder: Core Image, hardware-accelerated, straight from the
    /// pixel buffer.
    ///
    /// Colour is handled as the saved still handles it. Colour management is off
    /// — the working colour space is null — so the camera's values travel to the
    /// client untouched, and the file is tagged sRGB so those values say what
    /// they are meant to mean. One convention, both consumers.
    static func coreImageEncoder() -> Encoder {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let colorSpace: CGColorSpace =
            CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return { frame in
            let picture = CIImage(cvPixelBuffer: frame)
            return context.jpegRepresentation(
                of: picture, colorSpace: colorSpace, options: [:])
        }
    }

    // MARK: - Properties

    private let encode: Encoder

    /// Everyone currently watching. Guarded by the lock; the capture queue only
    /// ever copies it.
    private let lock: NSLock = NSLock()
    private var clients: [NCMJPEGClient] = []

    /// Whether the current run of encode failures has been traced. An encoder
    /// that cannot render says so once rather than thirty times a second.
    private var encodeFailureReported: Bool = false

    /// How many clients are watching. Zero means this sink does no work at all.
    var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }

    // MARK: - Lifecycle

    init(encoder: @escaping Encoder = NCMJPEGSink.coreImageEncoder()) {
        self.encode = encoder
    }

    // MARK: - Clients

    /// Registers a client and hands back the stream of parts to write to it.
    /// The caller owns the client and must close it when the connection ends.
    func open() -> NCMJPEGClient {
        let client = NCMJPEGClient()
        lock.lock()
        clients.append(client)
        let watching = clients.count
        lock.unlock()
        NSLog("NCMJPEGSink: a client is watching, %d in total", watching)
        return client
    }

    /// Unregisters a client and ends its stream.
    ///
    /// A client that is not removed is a phantom: the sink would keep encoding
    /// for a connection nobody is reading, for as long as the app runs. Closing
    /// twice is harmless, so the caller can do it wherever it is certain to run.
    func close(_ client: NCMJPEGClient) {
        lock.lock()
        clients.removeAll { $0 === client }
        let watching = clients.count
        lock.unlock()
        client.finish()
        NSLog("NCMJPEGSink: a client has gone, %d still watching", watching)
    }

    // MARK: - NCFrameSink

    /// Encodes the frame once and offers it to everyone watching. Runs on the
    /// capture queue.
    ///
    /// The buffer is encoded here and never kept: it comes from the pool the
    /// transform shares with every sink, so holding one would take it out of
    /// circulation. What outlives the call is the JPEG, which belongs to nobody
    /// but the clients it is offered to.
    func receive(_ frame: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        let recipients = clients
        lock.unlock()

        // Nobody watching, nothing to do — decided before the encoder is
        // reached, because encoding a picture and discarding it is exactly the
        // cost this stream is not allowed to impose on an idle Mac.
        guard !recipients.isEmpty else { return }

        guard let jpeg: Data = encode(frame) else {
            reportEncodeFailure()
            return
        }
        encodeFailureReported = false

        // Framed once as well as encoded once: every client is sent identical
        // bytes.
        let part: Data = NCMJPEGFraming.part(for: jpeg)
        for client in recipients {
            client.offer(part)
        }
    }

    /// Traces the first failure of a run and stays quiet until frames encode
    /// again.
    private func reportEncodeFailure() {
        guard !encodeFailureReported else { return }
        encodeFailureReported = true
        NSLog("NCMJPEGSink: Core Image would not encode the frame")
    }
}
