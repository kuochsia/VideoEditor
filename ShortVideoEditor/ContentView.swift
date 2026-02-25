import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var vm = EditorViewModel()

    var body: some View {
        HStack(spacing: 0) {
            videoPreviewPanel
            SidebarView(vm: vm)
        }
        .overlay {
            if vm.isExporting { exportingOverlay }
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
                let ratio = vm.outputFormat.previewAspectRatio
                let availW = geo.size.width
                let availH = geo.size.height
                let wFromH = availH * ratio
                let (w, h): (CGFloat, CGFloat) = wFromH <= availW
                    ? (wFromH, availH)
                    : (availW, availW / ratio)

                ZStack {
                    if let player = vm.sharedPlayer {
                        videoStack(player: player, bgPlayer: vm.bgPlayer, w: w, h: h)
                    } else {
                        placeholderView.frame(width: w, height: h)
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

            // MARK: Background
            switch vm.cropMode {
            case .fill:
                AVPlayerNSView(player: player, gravity: .resizeAspectFill)
                    .frame(width: w, height: h)

            case .black:
                ZStack {
                    Color.black.frame(width: w, height: h)
                    let srcW = vm.videoNaturalSize.width
                    let srcH = vm.videoNaturalSize.height
                    let srcRatio = (srcW > 0 && srcH > 0) ? srcW / srcH : 16.0 / 9.0
                    let fgW = (w / h < srcRatio) ? w : h * srcRatio
                    let fgH = (w / h < srcRatio) ? w / srcRatio : h
                    AVPlayerNSView(player: player, gravity: .resizeAspect)
                        .frame(width: fgW, height: fgH)
                }
                .frame(width: w, height: h)

            case .blurred:
                let srcW = vm.videoNaturalSize.width
                let srcH = vm.videoNaturalSize.height
                let srcRatio = (srcW > 0 && srcH > 0) ? srcW / srcH : 16.0 / 9.0
                let fgW = (w / h < srcRatio) ? w : h * srcRatio
                let fgH = (w / h < srcRatio) ? w / srcRatio : h
                ZStack {
                    // Background: fill + blur
                    AVPlayerNSView(player: player, gravity: .resizeAspectFill)
                        .frame(width: w, height: h)
                        .blur(radius: CGFloat(vm.blurIntensity) * 0.3)
                        .clipped()
                    // Foreground: exact AspectFit frame from source ratio
                    AVPlayerNSView(player: player, gravity: .resizeAspect)
                        .frame(width: fgW, height: fgH)
                }
                .frame(width: w, height: h)
            }

            // MARK: Overlays
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

            // MARK: Controls bar
            PlayerControlsBar(player: player)
                .frame(width: w)
        }
        .frame(width: w, height: h)
        .background(Color.black)
        .clipped()
        .onAppear {
            vm.lastPreviewVideoSize = computeVideoDisplaySize(w: w, h: h)
        }
        .onChange(of: h) { newH in
            vm.lastPreviewVideoSize = computeVideoDisplaySize(w: w, h: newH)
        }
        .onChange(of: w) { newW in
            vm.lastPreviewVideoSize = computeVideoDisplaySize(w: newW, h: h)
        }
        .onChange(of: vm.outputFormat) { _ in
            vm.lastPreviewVideoSize = computeVideoDisplaySize(w: w, h: h)
        }
        .onChange(of: vm.videoNaturalSize) { _ in
            vm.lastPreviewVideoSize = computeVideoDisplaySize(w: w, h: h)
        }
    }

    // Store the full canvas size (w, h).
    // Subtitles/overlays are positioned relative to the canvas, so scale = renderH / canvasH.
    private func computeVideoDisplaySize(w: CGFloat, h: CGFloat) -> CGSize {
        return CGSize(width: w, height: h)
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

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().scaleEffect(1.5).tint(.white)
                Text("Exportation en cours…").foregroundColor(.white).font(.headline)
                Text("\(Int(vm.exportProgress * 100))%")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.title2.monospacedDigit())
            }
        }
    }
}
