import SwiftUI
import AVKit
import AppKit

// MARK: - AVPlayer View

struct AVPlayerNSView: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    var showControls: Bool = false

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = showControls ? .floating : .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = gravity
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        nsView.videoGravity = gravity
        nsView.controlsStyle = showControls ? .floating : .none
    }
}
