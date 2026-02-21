import AVFoundation
import CoreImage
import CoreVideo

// MARK: - Blur Compositor
// Custom AVVideoCompositing for the blurred background mode.
//
// IMPORTANT: When using a custom compositor, pixel buffers arrive at their
// NATIVE resolution — layerInstruction transforms are NOT pre-applied.
// This compositor must manually:
//   1. Scale bg to AspectFill the render size, blur it
//   2. Scale fg to AspectFit the render size, composite centered on top

final class BlurCompositor: NSObject, AVVideoCompositing {

    // MARK: - Static Configuration

    private static var _bgTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    private static var _fgTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    private static var _blurRadius: Double = 40.0
    private static var _renderSize: CGSize = CGSize(width: 1080, height: 1920)
    private static var _preferredTransform: CGAffineTransform = .identity

    static func configure(
        bgTrackID: CMPersistentTrackID,
        fgTrackID: CMPersistentTrackID,
        blurRadius: Double,
        renderSize: CGSize,
        preferredTransform: CGAffineTransform
    ) {
        _bgTrackID          = bgTrackID
        _fgTrackID          = fgTrackID
        _blurRadius         = blurRadius
        _renderSize         = renderSize
        _preferredTransform = preferredTransform
    }

    // MARK: - AVVideoCompositing

    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard
            let bgBuffer = request.sourceFrame(byTrackID: Self._bgTrackID),
            let fgBuffer = request.sourceFrame(byTrackID: Self._fgTrackID),
            let outputBuffer = renderContext?.newPixelBuffer()
        else {
            request.finish(with: CompositorError.missingFrame)
            return
        }

        let rW = Self._renderSize.width
        let rH = Self._renderSize.height
        let canvas = CGRect(x: 0, y: 0, width: rW, height: rH)

        // --- 1. Background: AspectFill + blur ---
        let bgRaw = CIImage(cvPixelBuffer: bgBuffer)
        let bgImage = correctedImage(bgRaw, videoTrackTransform: Self._preferredTransform)

        let bgW = bgImage.extent.width
        let bgH = bgImage.extent.height
        let fillScale = max(rW / bgW, rH / bgH)
        // Scale first, then translate to center
        let bgTransform = CGAffineTransform(scaleX: fillScale, y: fillScale)
            .translatedBy(x: 0, y: 0) // origin after scale
        let bgScaled = bgImage
            .transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
            .transformed(by: CGAffineTransform(
                translationX: (rW - bgW * fillScale) / 2,
                y: (rH - bgH * fillScale) / 2
            ))
            .cropped(to: canvas)

        let blurred = bgScaled
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": Self._blurRadius])
            .cropped(to: canvas)

        // --- 2. Foreground: AspectFit, centered ---
        let fgRaw = CIImage(cvPixelBuffer: fgBuffer)
        let fgImage = correctedImage(fgRaw, videoTrackTransform: Self._preferredTransform)

        let fgW = fgImage.extent.width
        let fgH = fgImage.extent.height
        let fitScale = min(rW / fgW, rH / fgH)
        let fgScaled = fgImage
            .transformed(by: CGAffineTransform(scaleX: fitScale, y: fitScale))
            .transformed(by: CGAffineTransform(
                translationX: (rW - fgW * fitScale) / 2,
                y: (rH - fgH * fitScale) / 2
            ))

        // --- 3. Composite fg (sharp) over blurred bg ---
        let composited = fgScaled.composited(over: blurred)

        // --- 4. Render ---
        ciContext.render(
            composited,
            to: outputBuffer,
            bounds: canvas,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        request.finish(withComposedVideoFrame: outputBuffer)
    }

    /// Applies the video track's preferredTransform so the image is visually upright.
    /// For portrait iPhones videos, the raw buffer is landscape — this corrects it.
    private func correctedImage(_ image: CIImage, videoTrackTransform: CGAffineTransform) -> CIImage {
        // Normalise: translate back to origin after applying the preferred transform
        var t = videoTrackTransform
        // Remove any negative translation (common in rotated video)
        let transformed = image.transformed(by: t)
        let origin = transformed.extent.origin
        if origin.x != 0 || origin.y != 0 {
            return transformed.transformed(by: CGAffineTransform(
                translationX: -origin.x, y: -origin.y
            ))
        }
        return transformed
    }
}

// MARK: - Compositor Error

enum CompositorError: Error {
    case missingFrame
}
