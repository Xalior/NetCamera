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
    /// the caller only has to place it.
    let layer: AVSampleBufferDisplayLayer

    /// The renderer that accepts frames. Enqueueing and flushing are safe from
    /// the capture queue; the layer's own properties are not, and are set once
    /// at construction on the thread that builds it.
    private var renderer: AVSampleBufferVideoRenderer { layer.sampleBufferRenderer }

    /// Describes the shape of the buffers being enqueued. Building one per
    /// frame is wasted work, so it is kept until the picture changes shape —
    /// which a rotation, a resolution change or a different camera all do.
    private var formatDescription: CMFormatDescription?
    private var formatWidth = 0
    private var formatHeight = 0

    /// One line when the picture starts arriving, and one when it first stops:
    /// enough to tell a pipeline that never delivered from one that delivers
    /// faster than the renderer will take.
    private var hasLoggedFirstFrame = false
    private var hasLoggedRefusal = false

    // MARK: - Lifecycle

    init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor.black
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
        // closer to the truth than this one.
        guard renderer.isReadyForMoreMediaData else {
            if !hasLoggedRefusal {
                hasLoggedRefusal = true
                NSLog("NCDisplaySink: dropping frames, the renderer is not taking more")
            }
            return
        }
        hasLoggedRefusal = false

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
