import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore

// MARK: - Display sink

/// Shows the processed picture in a layer.
///
/// The window is one consumer of the frame among however many others, and this
/// is the whole of what makes it one: a layer, and the wrapping needed to put a
/// pixel buffer into it. It holds no capture session and no window, and knows
/// nothing about orientation — the picture arrives already the way round the
/// user asked for.
final class NCDisplaySink: NCFrameSink {
    // MARK: - Properties

    /// The layer to host in the view that shows the camera. Configured here so
    /// the caller only has to place it. Replaced outright if the renderer ever
    /// stops taking frames and cannot be talked round.
    private(set) var layer: AVSampleBufferDisplayLayer

    /// Called with a replacement layer that the owner must host in place of the
    /// old one. Delivered on the main thread, because hosting touches a view.
    var onLayerReplaced: ((AVSampleBufferDisplayLayer) -> Void)?

    /// The renderer that accepts frames. Enqueueing and flushing are safe from
    /// the capture queue; the layer's own properties are not, and are set once
    /// at construction on the thread that builds it.
    private var renderer: AVSampleBufferVideoRenderer { layer.sampleBufferRenderer }

    /// When the renderer started refusing frames, or nil while it is taking
    /// them. A renderer can stop accepting for a moment — the window being
    /// occluded does it — and start again on its own, so refusal is only worth
    /// acting on once it persists.
    private var refusingSince: CFTimeInterval?

    /// Whether a flush has already been tried against the current refusal.
    private var hasFlushedForRefusal = false

    /// How long the renderer may refuse frames before each remedy is tried.
    /// A picture that has been frozen for a second is already a fault; one
    /// that survives a flush is a renderer that will never come back.
    private static let flushAfter: CFTimeInterval = 1.0
    private static let rebuildAfter: CFTimeInterval = 3.0

    /// Describes the shape of the buffers being enqueued. Building one per
    /// frame is wasted work, so it is kept until the picture changes shape —
    /// which a rotation, a resolution change or a different camera all do.
    private var formatDescription: CMFormatDescription?
    private var formatWidth = 0
    private var formatHeight = 0

    /// One line when the picture starts arriving, so a pipeline that never
    /// delivered is distinguishable from one that delivered and then stopped.
    private var hasLoggedFirstFrame = false

    // MARK: - Lifecycle

    init() {
        layer = Self.makeLayer()
    }

    private static func makeLayer() -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor.black
        return layer
    }

    // MARK: - NCFrameSink

    func receive(_ frame: CVPixelBuffer, at time: CMTime) {
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)

        if formatDescription == nil || width != formatWidth || height != formatHeight {
            // Frames already in flight describe the old shape, so they are
            // discarded rather than shown stretched for an instant.
            renderer.flush()
            guard let description = makeFormatDescription(for: frame) else { return }
            formatDescription = description
            formatWidth = width
            formatHeight = height
        }

        // A renderer that is not ready is being fed faster than it will take.
        // Dropping the frame is right for live video: the next one is already
        // closer to the truth than this one. What is not right is dropping for
        // ever, so a refusal that persists is escalated rather than repeated.
        guard renderer.isReadyForMoreMediaData else {
            handleRefusal()
            return
        }
        resumeAfterRefusal()

        guard let formatDescription, let sample = makeSampleBuffer(
            for: frame, at: time, describedBy: formatDescription)
        else {
            return
        }

        renderer.enqueue(sample)

        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            NSLog("NCDisplaySink: first frame displayed, %dx%d", width, height)
        }
    }

    // MARK: - Clearing

    /// Throws away whatever is on screen, leaving the layer's black background.
    ///
    /// Used when the picture stops for a reason the user is about to be told
    /// about: a camera unplugged, or access withdrawn. Without this the last
    /// frame stays frozen in the window, which reads as a picture that is still
    /// live and merely very still.
    func clear() {
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        formatDescription = nil
        formatWidth = 0
        formatHeight = 0
        hasLoggedFirstFrame = false
    }

    // MARK: - Refusal and recovery

    /// Decides what to do about a renderer that will not take this frame.
    ///
    /// Runs on the capture queue, once per refused frame, so it does the least
    /// possible until the refusal has lasted long enough to be a fault. A
    /// renderer that has failed outright is not worth waiting on at all.
    private func handleRefusal() {
        let now = CACurrentMediaTime()
        guard let began = refusingSince else {
            refusingSince = now
            NSLog("NCDisplaySink: dropping frames, the renderer is not taking more")
            return
        }

        if renderer.status == .failed {
            NSLog(
                "NCDisplaySink: the renderer failed (%@), rebuilding",
                renderer.error?.localizedDescription ?? "no reason given")
            rebuild()
            return
        }

        let refusedFor = now - began
        if !hasFlushedForRefusal && refusedFor >= Self.flushAfter {
            hasFlushedForRefusal = true
            NSLog("NCDisplaySink: %.1fs without a frame taken, flushing", refusedFor)
            renderer.flush()
            return
        }

        if refusedFor >= Self.rebuildAfter {
            NSLog("NCDisplaySink: %.1fs without a frame taken, rebuilding", refusedFor)
            rebuild()
        }
    }

    /// Notes that the renderer is taking frames again, and says so if it had
    /// stopped — a picture that came back on its own is worth knowing about,
    /// because it means the stall was the transient kind.
    private func resumeAfterRefusal() {
        guard let began = refusingSince else { return }
        NSLog("NCDisplaySink: the renderer is taking frames again after %.1fs",
              CACurrentMediaTime() - began)
        refusingSince = nil
        hasFlushedForRefusal = false
    }

    /// Replaces the layer, because a renderer that will not take frames after a
    /// flush does not recover. The new layer is built here on the capture queue,
    /// where it belongs to nobody yet; only the hosting of it has to reach the
    /// main thread.
    private func rebuild() {
        let replacement = Self.makeLayer()
        layer = replacement

        // The new renderer knows nothing of the old one's picture, so the
        // format is described again from the next frame that arrives.
        formatDescription = nil
        formatWidth = 0
        formatHeight = 0
        refusingSince = nil
        hasFlushedForRefusal = false
        hasLoggedFirstFrame = false

        DispatchQueue.main.async { [weak self] in
            self?.onLayerReplaced?(replacement)
        }
    }

    // MARK: - Sample buffers

    private func makeFormatDescription(for frame: CVPixelBuffer) -> CMFormatDescription? {
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescriptionOut: &description)
        guard status == noErr, let description else {
            NSLog("NCDisplaySink: no format description, CoreMedia gave %d", status)
            return nil
        }
        return description
    }

    /// Wraps a buffer as a ready sample carrying the time the camera stamped
    /// the frame it came from.
    ///
    /// The sample is marked for immediate display. The layer has no control
    /// timebase — this is live video with nothing to synchronise to — so a
    /// frame is shown when it arrives rather than held for a presentation time
    /// on a clock that is not running.
    private func makeSampleBuffer(
        for frame: CVPixelBuffer, at time: CMTime, describedBy format: CMFormatDescription
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            NSLog("NCDisplaySink: no sample buffer, CoreMedia gave %d", status)
            return nil
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        {
            let attachment = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        return sample
    }
}
