import AVFoundation
import CoreImage
import AppKit
import SwiftUI

// MARK: - Video Editor Engine

final class VideoEditorEngine {

    // MARK: - Export

    func export(
        videoURL: URL,
        overlays: [OverlayImage],
        subtitles: [SubtitleEntry],
        subtitleStyle: SubtitleStyle,
        backgroundStyle: BackgroundStyle,
        outputFormat: OutputFormat,
        cropMode: CropMode,
        blurIntensity: Double,
        previewVideoSize: CGSize,  // actual display size of video in preview (after AspectFit)
        outputURL: URL,
        onProgress: @escaping (Float) -> Void,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        let asset = AVAsset(url: videoURL)
        let renderSize = outputFormat.renderSize
        let mixComposition = AVMutableComposition()

        // MARK: Tracks

        guard
            let videoTrack = asset.tracks(withMediaType: .video).first,
            let compVideoTrack = mixComposition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            completion(false, ExportError.missingVideoTrack)
            return
        }

        do {
            try compVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: videoTrack,
                at: .zero
            )
        } catch {
            completion(false, error)
            return
        }

        if let audioTrack = asset.tracks(withMediaType: .audio).first,
           let compAudioTrack = mixComposition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: audioTrack,
                at: .zero
            )
        }

        // For blurred mode we add a second video track for the blurred background
        var compBgTrack: AVMutableCompositionTrack? = nil
        if cropMode == .blurred {
            compBgTrack = mixComposition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            try? compBgTrack?.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: videoTrack,
                at: .zero
            )
        }

        // MARK: Natural size

        let natSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let natW = abs(natSize.width)
        let natH = abs(natSize.height)
        let renderW = renderSize.width
        let renderH = renderSize.height

        // MARK: Video Composition

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        let sourceFrameRate = videoTrack.nominalFrameRate
        let frameRate = sourceFrameRate > 0 ? sourceFrameRate : 30
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))


        let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange

        switch cropMode {

        case .fill:
            // AspectFill: scale so the video covers the entire render size
            let scale = max(renderW / natW, renderH / natH)
            let tx = (renderW - natW * scale) / 2
            let ty = (renderH - natH * scale) / 2
            let transform = videoTrack.preferredTransform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: tx, y: ty))
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
            layerInstruction.setTransform(transform, at: .zero)
            instruction.layerInstructions = [layerInstruction]

        case .black:
            // AspectFit: scale so entire video fits inside render size, black bars on sides/top
            let scale = min(renderW / natW, renderH / natH)
            let tx = (renderW - natW * scale) / 2
            let ty = (renderH - natH * scale) / 2
            let transform = videoTrack.preferredTransform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: tx, y: ty))
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
            layerInstruction.setTransform(transform, at: .zero)
            instruction.layerInstructions = [layerInstruction]
            instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        case .blurred:
            // Both tracks pass their raw buffers to BlurCompositor.
            // The compositor handles fill/fit scaling + blur itself,
            // so we set identity transforms here (no pre-scaling needed).
            let bgInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compBgTrack!)
            let fgInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
            instruction.layerInstructions = [fgInstruction, bgInstruction]
            videoComposition.customVideoCompositorClass = BlurCompositor.self
        }

        videoComposition.instructions = [instruction]

        // MARK: Blur compositor context (passed via thread-local workaround using objc association)
        if cropMode == .blurred, let bgTrack = compBgTrack {
            BlurCompositor.configure(
                bgTrackID: bgTrack.trackID,
                fgTrackID: compVideoTrack.trackID,
                blurRadius: blurIntensity,
                renderSize: renderSize,
                preferredTransform: videoTrack.preferredTransform
            )
        }

        // MARK: Layer Setup (overlays + subtitles via CoreAnimation)
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.addSublayer(videoLayer)

        // MARK: Scale Factor
        // SwiftUI measures in logical points; renderSize is in physical pixels.
        // On Retina screens (2x), 1 SwiftUI point = 2 physical pixels.
        // We must multiply the preview canvas size by backingScaleFactor to get
        // physical pixels, then divide into renderSize (also physical pixels).
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let canvasPhysicalH = previewVideoSize.height * screenScale
        let canvasPhysicalW = previewVideoSize.width  * screenScale
        let uiToVideoScale = renderSize.height / canvasPhysicalH

        // MARK: Overlay Layers
        for overlay in overlays {
            guard let imgLayer = makeOverlayLayer(
                overlay: overlay,
                uiToVideoScale: uiToVideoScale,
                renderSize: renderSize
            ) else { continue }
            parentLayer.addSublayer(imgLayer)
        }

        // MARK: Subtitle Layers
        let videoDuration = asset.duration.seconds
        for entry in subtitles {
            guard let subLayer = makeSubtitleLayer(
                entry: entry,
                style: subtitleStyle,
                background: backgroundStyle,
                uiToVideoScale: uiToVideoScale,
                renderSize: renderSize,
                videoDuration: videoDuration
            ) else { continue }
            parentLayer.addSublayer(subLayer)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        // MARK: Export Session

        guard let exportSession = AVAssetExportSession(
            asset: mixComposition,
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            completion(false, ExportError.exportSessionCreationFailed)
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition

        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            onProgress(exportSession.progress)
        }

        exportSession.exportAsynchronously {
            progressTimer.invalidate()
            onProgress(1.0)
            let success = exportSession.status == .completed
            completion(success, exportSession.error)
        }
    }

    // MARK: - Layer Builders

    private func makeOverlayLayer(
        overlay: OverlayImage,
        uiToVideoScale: CGFloat,
        renderSize: CGSize
    ) -> CALayer? {
        var contentImage: CGImage?

        if overlay.showBackground {
            contentImage = renderOverlayWithBackground(overlay: overlay, uiToVideoScale: uiToVideoScale, renderSize: renderSize)
        } else {
            contentImage = overlay.nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        guard let cg = contentImage else { return nil }

        let rawW = (renderSize.height * 0.4) * (overlay.scale + overlay.currentScale)
        let rawH = rawW / overlay.aspectRatio

        var finalW = rawW
        var finalH = rawH
        if overlay.showBackground {
            let padding = overlay.bgPadding * uiToVideoScale
            finalW += padding * 2
            finalH += padding * 2
        }

        let centerX = renderSize.width / 2 + (overlay.offset.width * uiToVideoScale)
        // CoreAnimation Y axis is inverted relative to SwiftUI
        let centerY = renderSize.height / 2 - (overlay.offset.height * uiToVideoScale)

        let layer = CALayer()
        layer.contents = cg
        layer.bounds = CGRect(x: 0, y: 0, width: finalW, height: finalH)
        layer.position = CGPoint(x: centerX, y: centerY)

        // CoreAnimation rotates clockwise for positive angles; SwiftUI is counter-clockwise.
        // Negate to match the preview.
        let radians = -overlay.rotation * (.pi / 180)
        layer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(radians)))

        return layer
    }

    private func makeSubtitleLayer(
        entry: SubtitleEntry,
        style: SubtitleStyle,
        background: BackgroundStyle,
        uiToVideoScale: CGFloat,
        renderSize: CGSize,
        videoDuration: Double
    ) -> CALayer? {
        guard let subtitleImage = renderSubtitleImage(
            text: entry.text,
            style: style,
            background: background,
            uiToVideoScale: uiToVideoScale,
            renderWidth: renderSize.width
        ) else { return nil }

        let imgWidth = CGFloat(subtitleImage.width)
        let imgHeight = CGFloat(subtitleImage.height)

        // yPos is 0 (top) to 1 (bottom) in SwiftUI space; CoreAnimation Y=0 is bottom.
        let yPos = renderSize.height * (1.0 - style.yPosition) - imgHeight / 2

        let layer = CALayer()
        layer.contents = subtitleImage
        layer.frame = CGRect(
            x: (renderSize.width - imgWidth) / 2,
            y: yPos,
            width: imgWidth,
            height: imgHeight
        )

        // Keyframe animation spanning the full video duration.
        // Hard cut to opacity 1 at entry.start, stays fully visible,
        // then fades to 0 over the last 300ms before entry.end.
        layer.opacity = 0.0

        let d = videoDuration
        let fadeDuration = min(0.3, (entry.end - entry.start) * 0.5) // 300ms max, never over half the subtitle
        let fadeStart = entry.end - fadeDuration

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values   = [0.0, 1.0, 1.0,  0.0]
        anim.keyTimes = [
            NSNumber(value: entry.start / d), // hard cut: jump to 1 (duplicate keyframe)
            NSNumber(value: entry.start / d), // fully visible
            NSNumber(value: fadeStart   / d), // hold at 1 until here
            NSNumber(value: entry.end   / d)  // fade to 0
        ]
        anim.beginTime             = AVCoreAnimationBeginTimeAtZero
        anim.duration              = d
        anim.calculationMode       = .linear
        anim.fillMode              = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "visibility")

        return layer
    }

    // MARK: - Image Renderers

    private func renderOverlayWithBackground(overlay: OverlayImage, uiToVideoScale: CGFloat, renderSize: CGSize) -> CGImage? {
        let rawW = (renderSize.height * 0.4) * (overlay.scale + overlay.currentScale)
        let rawH = rawW / overlay.aspectRatio
        let padding = overlay.bgPadding * uiToVideoScale
        let finalW = ceil(rawW + padding * 2)
        let finalH = ceil(rawH + padding * 2)

        return renderOffscreen(width: Int(finalW), height: Int(finalH)) { ctx in
            ctx.clear(CGRect(x: 0, y: 0, width: finalW, height: finalH))
            let rect = NSRect(x: 0, y: 0, width: finalW, height: finalH)
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: overlay.bgCornerRadius * uiToVideoScale,
                yRadius: overlay.bgCornerRadius * uiToVideoScale
            )
            NSColor(overlay.bgColor).withAlphaComponent(overlay.bgOpacity).setFill()
            path.fill()
            let imgRect = NSRect(x: padding, y: padding, width: rawW, height: rawH)
            overlay.nsImage.draw(in: imgRect)
        }
    }

    private func renderSubtitleImage(
        text: String,
        style: SubtitleStyle,
        background: BackgroundStyle,
        uiToVideoScale: CGFloat,
        renderWidth: CGFloat
    ) -> CGImage? {
        let scaledFontSize = style.fontSize * uiToVideoScale
        let font = NSFont(name: style.fontName, size: scaledFontSize)
            ?? NSFont.systemFont(ofSize: scaledFontSize, weight: .bold)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(style.color),
            .paragraphStyle: paragraphStyle
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        // Use 90% of render width so text has some horizontal margin
        let maxW = renderWidth * 0.9
        let boundingRect = attrStr.boundingRect(
            with: NSSize(width: maxW, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let padding = background.enabled ? background.padding * uiToVideoScale : 0
        let finalW = ceil(boundingRect.width + padding * 2)
        let finalH = ceil(boundingRect.height + padding * 2)

        return renderOffscreen(width: Int(finalW), height: Int(finalH)) { ctx in
            ctx.clear(CGRect(x: 0, y: 0, width: finalW, height: finalH))
            if background.enabled {
                let rect = NSRect(x: 0, y: 0, width: finalW, height: finalH)
                let path = NSBezierPath(
                    roundedRect: rect,
                    xRadius: background.cornerRadius * uiToVideoScale,
                    yRadius: background.cornerRadius * uiToVideoScale
                )
                NSColor(background.color).withAlphaComponent(background.opacity).setFill()
                path.fill()
            }
            let textRect = NSRect(
                x: padding,
                y: padding - (font.descender / 2),
                width: boundingRect.width,
                height: boundingRect.height
            )
            attrStr.draw(in: textRect)
        }
    }

    // MARK: - Offscreen Rendering Helper

    /// Creates an offscreen bitmap, runs a drawing block, and returns a CGImage.
    private func renderOffscreen(width: Int, height: Int, drawing: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              )
        else { return nil }

        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current?.cgContext {
            drawing(ctx)
        }

        return rep.cgImage
    }
}

// MARK: - Export Errors

enum ExportError: LocalizedError {
    case missingVideoTrack
    case exportSessionCreationFailed

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "Impossible de lire la piste vidéo du fichier source."
        case .exportSessionCreationFailed:
            return "Impossible de créer la session d'exportation."
        }
    }
}
