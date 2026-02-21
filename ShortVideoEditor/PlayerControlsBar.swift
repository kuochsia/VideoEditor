import SwiftUI
import AVKit
import Combine

// MARK: - Player Controls Bar

struct PlayerControlsBar: View {
    let player: AVPlayer

    @State private var isPlaying: Bool = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var isSeeking: Bool = false
    @State private var timeObserver: Any?
    @State private var rateObserver: NSKeyValueObservation?
    @State private var statusObserver: NSKeyValueObservation?

    var body: some View {
        HStack(spacing: 12) {
            // Play / Pause
            Button(action: togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            // Current time
            Text(formatTime(currentTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 44, alignment: .trailing)

            // Scrubber
            Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                isSeeking = editing
                if !editing {
                    player.seek(
                        to: CMTime(seconds: currentTime, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
            }
            .accentColor(.white)

            // Duration
            Text(formatTime(duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 44, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .onAppear { attachObservers() }
        .onDisappear { detachObservers() }
    }

    // MARK: - Actions

    private func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= duration - 0.1 {
                player.seek(to: .zero)
            }
            player.play()
        }
    }

    // MARK: - Observation

    private func attachObservers() {
        // KVO on rate → reflects external play/pause changes immediately
        rateObserver = player.observe(\.rate, options: [.new, .initial]) { p, _ in
            DispatchQueue.main.async { isPlaying = p.rate != 0 }
        }

        // KVO on currentItem.status → load duration as soon as asset is ready
        statusObserver = player.currentItem?.observe(\.status, options: [.new, .initial]) { item, _ in
            DispatchQueue.main.async { loadDuration(from: item) }
        }

        // Periodic time observer → scrubber + current time label
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard !isSeeking else { return }
            currentTime = time.seconds
        }

        // Reset isPlaying when playback reaches the end
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            isPlaying = false
        }
    }

    private func detachObservers() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        rateObserver?.invalidate()
        rateObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
    }

    private func loadDuration(from item: AVPlayerItem) {
        let d = item.asset.duration.seconds
        if d.isFinite && d > 0 { duration = d }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
