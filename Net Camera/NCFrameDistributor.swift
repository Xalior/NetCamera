import CoreMedia
import CoreVideo
import Foundation

// MARK: - Sink

/// A consumer of the processed picture.
///
/// Every consumer is equal: the window is one of these, and so is anything
/// else that wants the same frame the window is showing. A sink is handed the
/// oriented pixel buffer and the time the camera stamped the frame it came
/// from, and nothing else — no capture session, no sample buffer, no window.
protocol NCFrameSink: AnyObject {
    /// Called once per frame, on the capture queue. The buffer is shared with
    /// every other sink, so a sink that reads it must not write to it, and one
    /// that needs it later must retain it.
    func receive(_ frame: CVPixelBuffer, at time: CMTime)
}

// MARK: - Distributor

/// Fans each processed frame out to every registered sink.
///
/// Registration happens on the main thread, from menu actions and application
/// setup; delivery happens on the capture queue, once per frame. The two are
/// separated by a lock held only long enough to copy the sink list, so a slow
/// sink delays its successors but never blocks a menu action.
///
/// Sinks are held strongly and leave only by being removed. A sink that
/// vanished on its own would stop the picture with no diagnosis to offer, so
/// the lifetime is the registrar's to state rather than the collector's to
/// decide.
final class NCFrameDistributor {
    // MARK: - Properties

    private let lock = NSLock()

    /// Registration order is delivery order, which a dictionary keyed by
    /// identity would not preserve.
    private var sinks: [NCFrameSink] = []

    /// How many sinks are registered.
    var sinkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sinks.count
    }

    // MARK: - Registration

    /// Registers a sink, unless that same object is already registered.
    /// Registering twice would deliver every frame to it twice, which for an
    /// encoder or a file writer is not a harmless duplicate.
    func add(_ sink: NCFrameSink) {
        lock.lock()
        defer { lock.unlock() }
        guard !sinks.contains(where: { $0 === sink }) else { return }
        sinks.append(sink)
    }

    /// Unregisters a sink. Removing one that was never registered does
    /// nothing.
    func remove(_ sink: NCFrameSink) {
        lock.lock()
        defer { lock.unlock() }
        sinks.removeAll { $0 === sink }
    }

    // MARK: - Delivery

    /// Hands a processed frame to every registered sink, in registration
    /// order.
    func deliver(_ frame: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        let recipients = sinks
        lock.unlock()

        for sink in recipients {
            sink.receive(frame, at: time)
        }
    }
}
