import SwiftUI
import AVKit

// MARK: - Root Content View

struct ContentView: View {
    @StateObject private var vm = EditorViewModel()

    var body: some View {
        HStack(spacing: 0) {
            videoPreviewPanel
            SidebarView(vm: vm)
        }
        .overlay {
            if vm.isExporting {
                exportingOverlay
            }
        }
        .alert("Erreur d'exportation", isPresented: $vm.showExportError, presenting: vm.exportError) { _ in
            Button("OK", role: .cancel) {}
        } message: { errorMsg in
            Text(errorMsg)
        }
        .onAppear { vm.onAppear() }
        .onDisappear { vm.onDisappear() }
    }

    // MARK: - Video Preview Panel

    private var videoPreviewPanel: some View {
        ZStack {
            Color(white: 0.05).ignoresSafeArea()

            GeometryReader { geo in
                // Compute preview dimensions to fit inside the available space
                // while respecting the selected output format's aspect ratio.
                let ratio = vm.outputFormat.previewAspectRatio
                let availW = geo.size.width
                let availH = geo.size.height

                // Fit inside the panel: try height-constrained first, clamp to width if needed
                let hFromH = availH
                let wFromH = hFromH * ratio
                let (w, h): (CGFloat, CGFloat) = wFromH <= availW
                    ? (wFromH, hFromH)
                    : (availW, availW / ratio)

                ZStack {
                    if let player = vm.sharedPlayer {
                        videoStack(player: player, bgPlayer: vm.bgPlayer, w: w, h: h)
                    } else {
                        placeholderView
                            .frame(width: w, height: h)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: vm.outputFormat)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                vm.handleSmartDrop(providers: providers)
                return true
            }
        }
    }

    @ViewBuilder
    private func videoStack(player: AVPlayer, bgPlayer: AVPlayer?, w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .bottom) {

            // MARK: Background layer (crop-mode dependent)
            Group {
                switch vm.cropMode {
                case .fill:
                    AVPlayerLayerView(player: player, gravity: .resizeAspectFill)
                        .frame(width: w, height: h)

                case .black:
                    Color.black.frame(width: w, height: h)

                case .blurred:
                    if let bg = bgPlayer {
                        AVPlayerLayerView(player: bg, gravity: .resizeAspectFill)
                            .frame(width: w, height: h)
                    } else {
                        Color.black.frame(width: w, height: h)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: vm.cropMode)

            // MARK: Foreground video — aspectFit, transparent background (black + blurred modes)
            if vm.cropMode != .fill {
                AVPlayerLayerView(player: player, gravity: .resizeAspect, transparentBackground: true)
                    .frame(width: w, height: h)
            }

            // MARK: Image overlays
            ForEach($vm.overlays) { $item in
                DraggableOverlayView(
                    item: $item,
                    containerHeight: h,
                    onDelete: { vm.overlays.removeAll { $0.id == item.id } }
                )
            }

            // MARK: Subtitles
            if !vm.currentSubtitleText.isEmpty {
                subtitleView(w: w, h: h)
            }

            // MARK: Custom controls bar — pinned to the bottom
            PlayerControlsBar(player: player)
                .frame(width: w)
        }
        .frame(width: w, height: h)
        .background(Color.black)
        .clipped()
        .onAppear { vm.lastPreviewHeight = vm.outputFormat.previewReferenceIsHeight ? h : w }
        .onChange(of: h) { newH in
            vm.lastPreviewHeight = vm.outputFormat.previewReferenceIsHeight ? newH : w
        }
        .onChange(of: vm.outputFormat) { _ in
            vm.lastPreviewHeight = vm.outputFormat.previewReferenceIsHeight ? h : w
        }
    }

    private func subtitleView(w: CGFloat, h: CGFloat) -> some View {
        Text(vm.currentSubtitleText)
            .font(.custom(vm.subtitleFontName, size: vm.subtitleFontSize))
            .fontWeight(.bold)
            .foregroundColor(vm.subtitleColor)
            .multilineTextAlignment(.center)
            .padding(vm.subtitlePadding)
            .background {
                if vm.showSubtitleBackground {
                    RoundedRectangle(cornerRadius: vm.subtitleCornerRadius)
                        .fill(vm.subtitleBgColor.opacity(vm.subtitleBgOpacity))
                }
            }
            .shadow(color: vm.showSubtitleBackground ? .clear : .black, radius: 2)
            .position(x: w / 2, y: h * vm.subtitleYPosition)
            .allowsHitTesting(false)
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        VStack(spacing: 15) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 40))
                .foregroundColor(.blue)
            Text("Glissez Vidéo, SRT ou Image")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Exporting Overlay
    // Only shown as a blocking overlay during the export process itself.
    // Progress detail is shown inline in the sidebar for a less intrusive experience.

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("Exportation en cours…")
                    .foregroundColor(.white)
                    .font(.headline)
                Text("\(Int(vm.exportProgress * 100))%")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.title2.monospacedDigit())
            }
        }
    }
}
