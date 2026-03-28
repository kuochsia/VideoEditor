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
        if cropMode == .blurred || cropMode == .blurOnly {
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
        case .blurOnly:
            // Only the background track — full-screen blurred, no sharp foreground.
            let bgInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compBgTrack!)
            instruction.layerInstructions = [bgInstruction]
            videoComposition.customVideoCompositorClass = BlurCompositor.self
            
        }
        
       

        videoComposition.instructions = [instruction]

        // MARK: Blur compositor context (passed via thread-local workaround using objc association)
        if cropMode == .blurred || cropMode == .blurOnly, let bgTrack = compBgTrack {
            BlurCompositor.configure(
                bgTrackID: bgTrack.trackID,
                fgTrackID: cropMode == .blurOnly ? kCMPersistentTrackID_Invalid : compVideoTrack.trackID,
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
        let uiToVideoScale = renderSize.height / (previewVideoSize.height*2)
        let fontScale      = uiToVideoScale
        print("🎬 EXPORT — canvas: \(previewVideoSize), render: \(renderSize), scale: \(String(format:"%.3f", uiToVideoScale))")
        print("🎬 EXPORT — cropMode: \(cropMode), letterboxOffsetY")
        for (i, ov) in overlays.enumerated() {
            print("🎬 Overlay[\(i)] offset=\(ov.offset) scale=\(String(format:"%.3f",ov.scale))")
        }

        // MARK: Letterbox Offset
        // In the SwiftUI preview, ZStack(alignment: .bottom) anchors everything to the
        // canvas bottom. In blurred/black modes the foreground video is AspectFit and
        // also bottom-aligned (its bottom edge touches the canvas bottom).
        //
        // In export, BlurCompositor/AVFoundation centers the video vertically.
        // This creates a gap below the video that doesn't exist in the preview.
        // We must shift all overlay/subtitle layers UP by that gap so they match.
        //
        // letterboxOffsetY = pixels from export frame bottom to video bottom
        //                  = (renderH - fgH_export) / 2   (only when video doesn't fill frame)
        let letterboxOffsetY: CGFloat = 0
        

        // MARK: Overlay Layers
        for overlay in overlays {
            guard let imgLayer = makeOverlayLayer(
                overlay: overlay,
                uiToVideoScale: uiToVideoScale,
                letterboxOffsetY: letterboxOffsetY,
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
                fontScale: fontScale,
                letterboxOffsetY: letterboxOffsetY,
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
        letterboxOffsetY: CGFloat,
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

        // In SwiftUI preview (ZStack .bottom): offset=(0,0) → overlay at canvas bottom-center.
        // In export (CA, Y=0=bottom): same anchor point = bottom of frame.
        // letterboxOffsetY shifts up to compensate for the centered video gap.
        // CA origin is bottom-left. Center of canvas is renderSize.height / 2.
        // SwiftUI negative Y moves UP. Core Animation positive Y moves UP.
        // We subtract the offset to properly map SwiftUI's downward Y-axis to CA's upward Y-axis.
        let centerX = renderSize.width / 2 + (overlay.offset.width  * uiToVideoScale)
        let centerY = renderSize.height / 2 - (overlay.offset.height * uiToVideoScale)
        print("🎬 Param — x: \(centerX),y: \(centerY),Overlay: \(overlay.offset ), render: \(renderSize), lett: \(String(format:"%.3f", letterboxOffsetY))")
       
        let layer = CALayer()
        layer.contents = cg
        layer.bounds = CGRect(x: 0, y: 0, width: finalW, height: finalH)
        layer.position = CGPoint(x: centerX, y: centerY)
    
        let radians = -overlay.rotation * (.pi / 180)
        layer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(radians)))

        return layer
    }

    private func makeSubtitleLayer(
            entry: SubtitleEntry,
            style: SubtitleStyle,
            background: BackgroundStyle,
            uiToVideoScale: CGFloat,
            fontScale: CGFloat,
            letterboxOffsetY: CGFloat,
            renderSize: CGSize,
            videoDuration: Double
        ) -> CALayer? {
            
            // 1. On applique la majuscule ici si l'option est activée
            let finalString = style.isUppercase ? entry.text.uppercased() : entry.text
            
            guard let subtitleImage = renderSubtitleImage(
                text: finalString,
                style: style,
                background: background,
                uiToVideoScale: uiToVideoScale,
                fontScale: fontScale,
                renderWidth: renderSize.width
            ) else { return nil }
            
            let imgWidth  = CGFloat(subtitleImage.width)
            let imgHeight = CGFloat(subtitleImage.height)

            let yPos = renderSize.height * (1.0 - style.yPosition) - imgHeight / 2

            let layer = CALayer()
            layer.contents = subtitleImage
            layer.frame = CGRect(
                x: (renderSize.width - imgWidth) / 2,
                y: yPos,
                width: imgWidth,
                height: imgHeight
            )

            layer.opacity = 0.0

            // 2. Animation corrigée (sécurisée pour éviter les crashs d'export)
            let d = videoDuration
            let fadeDuration = min(0.3, (entry.end - entry.start) * 0.5)
            
            let startRel = max(0.0, entry.start / d)
            let endRel = min(1.0, entry.end / d)
            let fadeStartRel = max(startRel, (entry.end - fadeDuration) / d)
            
            let epsilon = 0.00001
            let preStartRel = max(0.0, startRel - epsilon)

            let anim = CAKeyframeAnimation(keyPath: "opacity")
            anim.values   = [0.0, 0.0, 1.0, 1.0, 0.0]
            anim.keyTimes = [
                NSNumber(value: 0.0),
                NSNumber(value: preStartRel),
                NSNumber(value: startRel),
                NSNumber(value: fadeStartRel),
                NSNumber(value: endRel)
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
            fontScale: CGFloat,
            renderWidth: CGFloat
        ) -> CGImage? {
            
            let scaledFontSize = style.fontSize * fontScale
            
            // 1. Charger la police avec la graisse (Bold)
            let baseFont = NSFont(name: style.fontName, size: scaledFontSize)
                ?? NSFont.systemFont(ofSize: scaledFontSize)
            let fontDescriptor = baseFont.fontDescriptor.withSymbolicTraits(.bold)
            let font = NSFont(descriptor: fontDescriptor, size: scaledFontSize)
                ?? NSFont.systemFont(ofSize: scaledFontSize, weight: .bold)

            let maxW = renderWidth * 0.70
            
            // 2. MESURE : Utiliser l'alignement à gauche pour forcer boundingRect à donner la taille RÉELLE
            let measureStyle = NSMutableParagraphStyle()
            measureStyle.alignment = .left
            
            let measureAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: measureStyle
            ]
            let measureStr = NSAttributedString(string: text, attributes: measureAttrs)
            
            let tightRect = measureStr.boundingRect(
                with: NSSize(width: maxW, height: 2000),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            
            // La vraie taille dynamique de notre texte
            let actualTextWidth = ceil(tightRect.width)
            let actualTextHeight = ceil(tightRect.height)
            
            // 3. DESSIN : Utiliser l'alignement centré
            let drawStyle = NSMutableParagraphStyle()
            drawStyle.alignment = .center
            
            let drawAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(style.color),
                .paragraphStyle: drawStyle
            ]
            let drawStr = NSAttributedString(string: text, attributes: drawAttrs)
            
            let padding = background.enabled ? background.padding * uiToVideoScale : 0
            let finalW = actualTextWidth + padding * 2
            let finalH = actualTextHeight + padding * 2

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
                
                // On dessine le texte dans un rectangle qui moule parfaitement sa vraie taille
                let textRect = NSRect(
                    x: padding,
                    y: padding - (font.descender / 2),
                    width: actualTextWidth,
                    height: actualTextHeight
                )
                drawStr.draw(in: textRect)
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
