import SwiftUI
import AVKit
import AppKit

// MARK: - AVPlayer View (NSViewRepresentable)

struct AVPlayerNSView: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = gravity
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        nsView.videoGravity = gravity
    }
}

// MARK: - AVPlayer Layer View
// Bare NSView with AVPlayerLayer. Used for the fill/fit video layers.

struct AVPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    var transparentBackground: Bool = false  // when true, letterbox areas are clear not black

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        if transparentBackground {
            view.playerLayer.backgroundColor = nil
            view.layer?.backgroundColor = .clear
        }
        return view
    }

    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        nsView.playerLayer.player = player
        nsView.playerLayer.videoGravity = gravity
        if transparentBackground {
            nsView.playerLayer.backgroundColor = nil
            nsView.layer?.backgroundColor = .clear
        }
    }
}

final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

// MARK: - Blurred Player View
// Stacks two NSViews:
//   1. AVPlayerLayerView (fill) as the video background
//   2. NSVisualEffectView on top as the blur — GPU native, ~0 CPU cost
// This avoids CALayer.filters on AVPlayerLayer which kills performance.

struct BlurredPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var blurRadius: CGFloat  // used to modulate material intensity via alpha

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        // Video layer - fill
        let videoView = PlayerLayerNSView()
        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = .resizeAspectFill
        videoView.autoresizingMask = [.width, .height]
        container.addSubview(videoView)

        // Blur overlay - NSVisualEffectView is composited by the window server (GPU)
        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard
            let videoView = nsView.subviews.first as? PlayerLayerNSView,
            let blur = nsView.subviews.last as? NSVisualEffectView
        else { return }

        videoView.playerLayer.player = player
        // Modulate blur intensity via the blur view's alphaValue (0.3–1.0 range)
        let normalised = min(max(blurRadius / 80.0, 0), 1)
        blur.alphaValue = 0.3 + normalised * 0.7
    }
}

