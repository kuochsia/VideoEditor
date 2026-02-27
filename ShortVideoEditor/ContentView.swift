import SwiftUI
import AVKit
import AppKit

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
        } message: { msg in Text(msg) }
        .alert("Erreur", isPresented: $vm.showDropError, presenting: vm.dropError) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in Text(msg) }
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
                .onDrop(of: [.fileURL], isTargeted: nil) { providers, location in
                    vm.handleSmartDrop(providers: providers, dropLocation: location, panelSize: geo.size)
                    return true
                }
            }
        }
    }

    // Computes AspectFit foreground dimensions given canvas size and source video size
    private func fgSize(w: CGFloat, h: CGFloat) -> (CGFloat, CGFloat) {
        let srcW = vm.videoNaturalSize.width
        let srcH = vm.videoNaturalSize.height
        let ratio = (srcW > 0 && srcH > 0) ? srcW / srcH : 16.0 / 9.0
        if w / h < ratio {
            return (w, w / ratio)
        } else {
            return (h * ratio, h)
        }
    }

    @ViewBuilder
    private func videoStack(player: AVPlayer, bgPlayer: AVPlayer?, w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .bottom) {

            // MARK: Background
            switch vm.cropMode {
            case .fill:
                AVPlayerNSView(player: player, gravity: .resizeAspectFill).frame(width: w, height: h)
            case .black:
                blackBackground(player: player, w: w, h: h)
            case .blurred:
                blurredBackground(player: player, w: w, h: h)
            }

            // MARK: Overlays (NEW: Wrapped in a centered container)
            ZStack {
                ForEach($vm.overlays) { $item in
                    DraggableOverlayView(
                        item: $item,
                        containerHeight: h,
                        onDelete: { vm.overlays.removeAll { $0.id == item.id } }
                    )
                }
            }
            .frame(width: w, height: h) // Forces true center alignment

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
        .gesture(
            SpatialTapGesture(count: 2)
                .onEnded { event in
                    guard !vm.overlays.isEmpty else { return }
                    vm.overlayManagerPosition = event.location
                    withAnimation(.easeOut(duration: 0.15)) {
                        vm.showOverlayManager = true
                    }
                }
        )
        // Overlay manager anchored at click position, clamped to canvas bounds
        .overlay(alignment: .topLeading) {
            if vm.showOverlayManager {
                ClampedOverlayPanel(vm: vm, clickPoint: vm.overlayManagerPosition)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
            }
        }
        .onAppear {
            vm.lastPreviewVideoSize = CGSize(width: w, height: h)
            vm.previewCanvasSize    = CGSize(width: w, height: h)
        }
        .onChange(of: h) { newH in
            vm.lastPreviewVideoSize = CGSize(width: w,    height: newH)
            vm.previewCanvasSize    = CGSize(width: w,    height: newH)
        }
        .onChange(of: w) { newW in
            vm.lastPreviewVideoSize = CGSize(width: newW, height: h)
            vm.previewCanvasSize    = CGSize(width: newW, height: h)
        }
        .onChange(of: vm.outputFormat) { _ in
            vm.lastPreviewVideoSize = CGSize(width: w, height: h)
            vm.previewCanvasSize    = CGSize(width: w, height: h)
        }
        .onChange(of: vm.videoNaturalSize) { _ in
            vm.lastPreviewVideoSize = CGSize(width: w, height: h)
        }
    }

    @ViewBuilder
    private func blackBackground(player: AVPlayer, w: CGFloat, h: CGFloat) -> some View {
        let (fgW, fgH) = fgSize(w: w, h: h)
        ZStack {
            Color.black.frame(width: w, height: h)
            AVPlayerNSView(player: player, gravity: .resizeAspect)
                .frame(width: fgW, height: fgH)
        }
        .frame(width: w, height: h)
    }

    @ViewBuilder
    private func blurredBackground(player: AVPlayer, w: CGFloat, h: CGFloat) -> some View {
        let (fgW, fgH) = fgSize(w: w, h: h)
        ZStack {
            AVPlayerNSView(player: player, gravity: .resizeAspectFill)
                .frame(width: w, height: h)
                .blur(radius: CGFloat(vm.blurIntensity) * 0.3)
                .clipped()
            AVPlayerNSView(player: player, gravity: .resizeAspect)
                .frame(width: fgW, height: fgH)
        }
        .frame(width: w, height: h)
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

// MARK: - Clamped Overlay Panel

struct ClampedOverlayPanel: View {
    @ObservedObject var vm: EditorViewModel
    let clickPoint: CGPoint
    @State private var panelSize: CGSize = CGSize(width: 260, height: 200)

    var body: some View {
        GeometryReader { canvas in
            let maxX = canvas.size.width  - panelSize.width  - 8
            let maxY = canvas.size.height - panelSize.height - 8
            let x = max(8, min(clickPoint.x, maxX))
            let y = max(8, min(clickPoint.y, maxY))

            OverlayManagerPanel(vm: vm)
                .fixedSize()
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear    { panelSize = g.size }
                            .onChange(of: g.size) { panelSize = $0 }
                    }
                )
                .offset(x: x, y: y)
        }
    }
}

// MARK: - Overlay Manager Panel

struct OverlayManagerPanel: View {
    @ObservedObject var vm: EditorViewModel
    // NSEvent monitor to catch clicks outside this panel
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Text("Images (\(vm.overlays.count))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().overlay(Color.white.opacity(0.12))

            // Rows
            ForEach(vm.overlays.indices, id: \.self) { i in
                overlayRow(index: i)
                if i < vm.overlays.count - 1 {
                    Divider().overlay(Color.white.opacity(0.07)).padding(.leading, 52)
                }
            }
        }
        .background(.ultraThinMaterial)
        .background(Color(white: 0.1).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 6)
        .frame(minWidth: 240, maxWidth: 300)
        // Install global mouse-down monitor to dismiss on outside click
        // Delay prevents catching the very double-click that opened the panel
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                    DispatchQueue.main.async { self.dismiss() }
                    return event
                }
            }
        }
        .onDisappear {
            if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
            clearHighlights()
        }
    }

    @ViewBuilder
    private func overlayRow(index: Int) -> some View {
        let item = vm.overlays[index]
        HStack(spacing: 10) {

            // Thumbnail
            Image(nsImage: item.nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(item.isHighlighted ? Color.accentColor : Color.white.opacity(0.1),
                                lineWidth: item.isHighlighted ? 2 : 1)
                )

            // Filename
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.url.pathExtension.uppercased())
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer()

            // Delete
            Button {
                // Clear highlight first to avoid onHover firing on stale index
                if index < vm.overlays.count {
                    vm.overlays[index].isHighlighted = false
                }
                vm.overlays.remove(at: index)
                PersistenceManager.shared.saveOverlays(vm.overlays)
                if vm.overlays.isEmpty { dismiss() }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(item.isHighlighted ? .red : .white.opacity(0.35))
                    .frame(width: 26, height: 26)
                    .background(item.isHighlighted ? Color.red.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(item.isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard index < vm.overlays.count else { return }
            vm.overlays[index].isHighlighted = hovering
        }
    }

    private func dismiss() {
        clearHighlights()
        withAnimation(.easeOut(duration: 0.15)) {
            vm.showOverlayManager = false
        }
    }

    private func clearHighlights() {
        for i in vm.overlays.indices { vm.overlays[i].isHighlighted = false }
    }
}
