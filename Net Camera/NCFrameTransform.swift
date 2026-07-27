import CoreImage
import CoreVideo
import Foundation

// MARK: - Orientation

/// The geometry a captured frame is given so that it reads the way the user
/// asked for it: some number of quarter turns, and possibly a mirror.
///
/// The three persisted settings are not independent. *Mirror Vertically*
/// (`isUpsideDown`) does not flip anything — it selects the orientation two
/// places further along the same four-step cycle that `position` walks, so it
/// is a half-turn wearing a mirror's name. One consequence is that the eight
/// `(position, isUpsideDown)` pairs collapse onto four distinct orientations:
/// `(0, true)` and `(2, false)` are the same picture, and the settings tuple
/// cannot be recovered from the result.
struct NCFrameOrientation: Equatable {
    /// Quarter turns clockwise, 0...3.
    let quarterTurnsClockwise: Int

    /// Whether the picture is mirrored left-to-right in the camera's own,
    /// pre-rotation space. Mirroring is stored independently of rotation and
    /// composed with it, never folded into it.
    let mirroredInSourceSpace: Bool

    /// Derives the geometry from the three persisted settings.
    ///
    /// The cycle is `[portrait, landscapeLeft, portraitUpsideDown,
    /// landscapeRight]`, read as `[0, 90, 180, 270]` degrees clockwise, and
    /// `isUpsideDown` advances two places along it.
    ///
    /// `position` is normalised rather than rejected. The menu actions only
    /// ever produce 0...3, but a value read back from `UserDefaults` carries
    /// no such guarantee, and a pure function has no previously applied
    /// orientation it could leave standing.
    init(position: Int, isMirrored: Bool, isUpsideDown: Bool) {
        let wrapped = ((position % 4) + 4) % 4
        quarterTurnsClockwise = (wrapped + (isUpsideDown ? 2 : 0)) % 4
        mirroredInSourceSpace = isMirrored
    }
}

// MARK: - Frame transform

/// Turns a captured pixel buffer into an oriented one.
///
/// A pure function over pixel buffers: it holds a rendering context and a
/// buffer pool for efficiency, but the output depends only on the input buffer
/// and the orientation. Nothing here touches the capture session, the window
/// or any application state, which is what lets it be exercised over
/// synthesised buffers with no camera present.
final class NCFrameTransform {
    // MARK: - Properties

    private let context: CIContext

    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolFormat: OSType = 0

    // MARK: - Lifecycle

    init() {
        // No working colour space: this stage moves pixels about and must not
        // reinterpret them, so colour management is left switched off and the
        // camera's values pass through untouched.
        context = CIContext(options: [.workingColorSpace: NSNull()])
    }

    // MARK: - Geometry

    /// Quarter turns clockwise as exact matrices.
    ///
    /// Core Image's coordinate space has y increasing upwards, the same way
    /// the picture is displayed, so a clockwise turn on screen is
    /// `(x, y) -> (y, -x)` here. These are written as integers rather than
    /// built with `CGAffineTransform(rotationAngle:)`, whose `cos(.pi / 2)` is
    /// 6.1e-17 rather than 0 and so resamples the whole picture through a
    /// sub-pixel offset.
    ///
    /// Which way round the cycle's two quarter turns go follows from
    /// `AVCaptureVideoOrientation`, whose four cases are each documented
    /// separately: the cycle the settings walk — portrait, landscapeLeft,
    /// portraitUpsideDown, landscapeRight — is quarter turns clockwise.
    private static let quarterTurns: [CGAffineTransform] = [
        CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0),
        CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0),
        CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0),
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0),
    ]

    /// Mirrors left-to-right about the origin. Negating x is a left-right flip
    /// whichever way y points, so this needs no coordinate-space caveat.
    private static let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    /// The matrix for an orientation, about the origin.
    static func matrix(for orientation: NCFrameOrientation) -> CGAffineTransform {
        let mirroring = orientation.mirroredInSourceSpace ? mirror : .identity
        let rotation = quarterTurns[orientation.quarterTurnsClockwise]

        // THE COMPOSITION ORDER, kept on one line because it is the whole of
        // what this function decides.
        //
        // `AVCaptureConnection.videoMirrored` is documented to mirror the video
        // "about its vertical axis" — the connection's own, before any rotation
        // — and the rotation composes on top. That is why one mirror flag reads
        // left-right at positions 0 and 2 and top-bottom at positions 1 and 3.
        // No line of the app computes it because it belongs to the API the app
        // calls, which is also where it is specified.
        //
        // Mirror in the source's space, then rotate. The alternative,
        // `rotation.concatenating(mirroring)`, mirrors the rotated result and
        // is a different picture at 90 and 270 degrees.
        return mirroring.concatenating(rotation)
    }

    // MARK: - Transform

    /// Applies an orientation to a frame, returning a new buffer.
    ///
    /// The result's dimensions are the source's, swapped when the orientation
    /// is an odd number of quarter turns. Returns `nil` if no destination
    /// buffer could be obtained.
    func apply(_ orientation: NCFrameOrientation, to source: CVPixelBuffer) -> CVPixelBuffer? {
        let placed = CIImage(cvPixelBuffer: source)
            .transformed(by: Self.matrix(for: orientation))

        // Turning and mirroring about the origin carries the picture off it;
        // bring the extent back to (0, 0) so it renders into the buffer whole.
        let upright = placed.transformed(
            by: CGAffineTransform(
                translationX: -placed.extent.origin.x,
                y: -placed.extent.origin.y))

        guard
            let destination = buffer(
                width: Int(upright.extent.width.rounded()),
                height: Int(upright.extent.height.rounded()),
                format: CVPixelBufferGetPixelFormatType(source))
        else {
            return nil
        }

        context.render(upright, to: destination)
        return destination
    }

    // MARK: - Buffer pool

    /// Vends a destination buffer, rebuilding the pool whenever the shape it
    /// must serve changes. Alternating between an upright and a quarter-turned
    /// orientation swaps the output's dimensions and so rebuilds the pool,
    /// which is a menu action's worth of work rather than a per-frame cost.
    private func buffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if pool == nil || width != poolWidth || height != poolHeight || format != poolFormat {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]

            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            guard status == kCVReturnSuccess, let created else {
                NSLog(
                    "NCFrameTransform: no %dx%d buffer pool, CVPixelBufferPoolCreate gave %d",
                    width, height, status)
                pool = nil
                return nil
            }

            pool = created
            poolWidth = width
            poolHeight = height
            poolFormat = format
        }

        guard let pool else { return nil }
        var vended: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &vended)
        guard status == kCVReturnSuccess else {
            NSLog("NCFrameTransform: no buffer from the pool, CoreVideo gave %d", status)
            return nil
        }
        return vended
    }
}
