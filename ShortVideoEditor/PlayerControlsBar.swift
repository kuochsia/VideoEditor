import SwiftUI
import AVKit
import Combine

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
                .frame(width: 70, alignment: .trailing)

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
                .frame(width: 70, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .onAppear {
            attachObservers(to: player)
        }
        .onDisappear {
            detachObservers(from: player)
        }
        // Re-attach when the player instance changes (new video dropped)
        .onChange(of: player) { newPlayer in
            detachObservers(from: player)
            resetState()
            attachObservers(to: newPlayer)
        }
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

    // MARK: - State Reset

    private func resetState() {
        isPlaying = false
        currentTime = 0
        duration = 1
        isSeeking = false
    }

    // MARK: - Observation

    private func attachObservers(to p: AVPlayer) {
        // KVO on rate → play/pause state
        rateObserver = p.observe(\.rate, options: [.new, .initial]) { player, _ in
            DispatchQueue.main.async { isPlaying = player.rate != 0 }
        }

        // KVO on currentItem.status → duration
        statusObserver = p.currentItem?.observe(\.status, options: [.new, .initial]) { item, _ in
            DispatchQueue.main.async { loadDuration(from: item) }
        }

        // Periodic time → scrubber position
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard !isSeeking else { return }
            currentTime = time.seconds
            // Refresh duration if not yet loaded
            if duration <= 1, let item = p.currentItem {
                loadDuration(from: item)
            }
        }

        // End of playback
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: p.currentItem,
            queue: .main
        ) { _ in
            isPlaying = false
        }
    }

    private func detachObservers(from p: AVPlayer) {
        if let observer = timeObserver {
            p.removeTimeObserver(observer)
            timeObserver = nil
        }
        rateObserver?.invalidate()
        rateObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func loadDuration(from item: AVPlayerItem) {
        let d = item.asset.duration.seconds
        if d.isFinite && d > 0 { duration = d }
    }

    // MARK: - Format  m:ss.ms

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.000" }
        let m  = Int(seconds) / 60
        let s  = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%d:%02d.%03d", m, s, ms)
    }
}
