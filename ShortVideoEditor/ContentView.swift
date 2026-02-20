import SwiftUI
import AVKit
import UniformTypeIdentifiers
import QuartzCore

// --- 1. MODÈLES ---

struct SubtitleEntry: Identifiable {
    let id = UUID()
    var start: Double
    var end: Double
    var text: String
}

struct OverlayImage: Identifiable {
    let id = UUID()
    var url: URL
    var nsImage: NSImage
    var offset: CGSize = .zero
    var lastOffset: CGSize = .zero
    var scale: CGFloat = 0.3
    var currentScale: CGFloat = 0.0
    
    // Rotation & Style
    var rotation: Double = 0.0
    var showBackground: Bool = false
    
    var aspectRatio: CGFloat {
        let h = nsImage.size.height > 0 ? nsImage.size.height : 1
        return nsImage.size.width / h
    }
}

// --- 2. VUE UTILITAIRE (Effet de flou sidebar) ---

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// --- 3. INTERFACE PRINCIPALE ---

struct ContentView: View {
    @State private var inputURL: URL?
    @State private var sharedPlayer: AVPlayer?
    @State private var overlays: [OverlayImage] = []
    @State private var isExporting = false
    @State private var lastPreviewHeight: CGFloat = 800
    
    // États Sous-titres
    @State private var subtitles: [SubtitleEntry] = []
    @State private var rawSRTText: String = ""
    @State private var currentSubtitleText: String = ""
    @State private var subtitleFontSize: CGFloat = 40
    @State private var subtitleColor: Color = .white
    @State private var subtitleYPosition: CGFloat = 0.8
    @State private var timeObserver: Any?
    
    @State private var subtitleFontName: String = "Helvetica"
    @State private var availableFonts: [String] = []
    @State private var offsetInput: String = "0.0"

    // États Fond (Commun Sous-titres et Images)
    @State private var showSubtitleBackground: Bool = true
    @State private var subtitleBgColor: Color = .black
    @State private var subtitleBgOpacity: Double = 0.6
    @State private var subtitleCornerRadius: CGFloat = 10
    @State private var subtitlePadding: CGFloat = 10

    var body: some View {
        HStack(spacing: 0) {
            // --- ZONE GAUCHE : PREVIEW VIDÉO ---
            ZStack {
                Color(white: 0.05).ignoresSafeArea()
                GeometryReader { geo in
                    let h = geo.size.height
                    let w = h * (9/16)
                    
                    ZStack {
                        if let player = sharedPlayer {
                            ZStack {
                                VideoPlayer(player: player)
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: w, height: h)
                                    .clipped()
                                
                                // IMAGES (OVERLAYS)
                                ForEach($overlays) { $item in
                                    DraggableOverlayView(
                                        item: $item,
                                        containerHeight: h,
                                        subtitlePadding: subtitlePadding,
                                        subtitleCornerRadius: subtitleCornerRadius,
                                        subtitleBgColor: subtitleBgColor,
                                        subtitleBgOpacity: subtitleBgOpacity,
                                        onDelete: {
                                            overlays.removeAll(where: { $0.id == item.id })
                                        }
                                    )
                                }
                                
                                // SOUS-TITRES
                                if !currentSubtitleText.isEmpty {
                                    Text(currentSubtitleText)
                                        .font(.custom(subtitleFontName, size: subtitleFontSize))
                                        .fontWeight(.bold)
                                        .foregroundColor(subtitleColor)
                                        .multilineTextAlignment(.center)
                                        .padding(subtitlePadding)
                                        .background(
                                            Group {
                                                if showSubtitleBackground {
                                                    RoundedRectangle(cornerRadius: subtitleCornerRadius)
                                                        .fill(subtitleBgColor.opacity(subtitleBgOpacity))
                                                }
                                            }
                                        )
                                        .shadow(color: showSubtitleBackground ? .clear : .black, radius: 2)
                                        .position(x: w / 2, y: h * subtitleYPosition)
                                        .allowsHitTesting(false)
                                }
                            }
                            .frame(width: w, height: h)
                            .background(Color.black)
                            .onAppear { self.lastPreviewHeight = h }
                        } else {
                            placeholderView.frame(width: w, height: h)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleSmartDrop(providers: providers)
                    return true
                }
            }
            
            // --- ZONE DROITE : PANNEAU ÉDITEUR ---
            VStack(alignment: .leading, spacing: 20) {
                Text("Éditeur SRT").font(.title2).bold()
                
                // 1. ÉDITEUR TEXTE
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("TEXTE BRUT").font(.caption).foregroundColor(.secondary).bold()
                        Spacer()
                        Button(action: saveSRTFile) { Label("", systemImage: "arrow.down.doc.fill") }.buttonStyle(.bordered).controlSize(.small)
                        Button("Valider") { syncFromRawText() }.buttonStyle(.borderedProminent).controlSize(.small).tint(.green)
                    }
                    TextEditor(text: $rawSRTText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxHeight: .infinity)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                }
                
                if !subtitles.isEmpty || sharedPlayer != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 15) {
                            
                            // TIMING
                            Group {
                                Text("TIMING").font(.caption).foregroundColor(.secondary).bold()
                                HStack(spacing: 8) {
                                    TextField("Sec", text: $offsetInput).textFieldStyle(.roundedBorder).frame(width: 60)
                                    Button("Appliquer") { applyCustomOffset() }.buttonStyle(.bordered)
                                    Button("Indexer") { reindexSubtitles() }.buttonStyle(.bordered)
                                }
                            }
                            
                            Divider()
                            
                            // STYLE TEXTE
                            Group {
                                Text("TYPOGRAPHIE").font(.caption).foregroundColor(.secondary).bold()
                                HStack {
                                    Text("Police")
                                    Spacer()
                                    Picker("", selection: $subtitleFontName) {
                                        ForEach(availableFonts, id: \.self) { Text($0).tag($0) }
                                    }.frame(width: 120).labelsHidden()
                                }
                                HStack {
                                    ColorPicker("", selection: $subtitleColor).labelsHidden()
                                    Text("Couleur Texte")
                                }
                                Slider(value: $subtitleFontSize, in: 20...120) { Text("Taille") }
                            }
                            
                            Divider()
                            
                            // FOND (Appliqué aux Sous-titres + Images optionnelles)
                            Group {
                                Toggle("Afficher le fond (Sous-titres)", isOn: $showSubtitleBackground)
                                    .font(.system(size: 12, weight: .bold))
                                
                                if showSubtitleBackground {
                                    HStack {
                                        ColorPicker("", selection: $subtitleBgColor).labelsHidden()
                                        Text("Couleur Fond")
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Opacité: \(Int(subtitleBgOpacity * 100))%").font(.caption)
                                        Slider(value: $subtitleBgOpacity, in: 0...1)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Arrondi: \(Int(subtitleCornerRadius))").font(.caption)
                                        Slider(value: $subtitleCornerRadius, in: 0...30)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Marges: \(Int(subtitlePadding))").font(.caption)
                                        Slider(value: $subtitlePadding, in: 0...40)
                                    }
                                }
                            }
                            
                            Divider()
                            
                            Text("POSITION Y (Sous-titres)").font(.caption).foregroundColor(.secondary).bold()
                            Slider(value: $subtitleYPosition, in: 0.1...0.9)
                        }
                    }
                }
                
                if sharedPlayer != nil {
                    Button(action: startExportProcess) {
                        Text(isExporting ? "Exportation..." : "EXPORTER")
                            .bold().frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(.blue).controlSize(.large).disabled(isExporting)
                }
            }
            .padding()
            .frame(width: 400)
            .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
            .onAppear { self.availableFonts = NSFontManager.shared.availableFontFamilies }
        }
        .overlay(isExporting ? loadingOverlay : nil)
    }

    // --- 4. LOGIQUE UI ---
    
    var placeholderView: some View {
        VStack(spacing: 15) {
            Image(systemName: "video.badge.plus").font(.system(size: 40)).foregroundColor(.blue)
            Text("Glissez Vidéo, SRT ou Image").font(.headline)
        }
    }

    var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()
            ProgressView("Exportation en cours...").foregroundColor(.white)
        }
    }

    private func syncFromRawText() { self.subtitles = parseSRT(rawSRTText) }

    private func reindexSubtitles() {
        syncFromRawText()
        self.rawSRTText = generateRawSRT()
    }

    private func saveSRTFile() {
        // Sauvegarde dans Downloads
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let filename = "subtitle_export_\(Int(Date().timeIntervalSince1970)).srt"
        let outputURL = downloadsURL.appendingPathComponent(filename)
        do {
            try rawSRTText.write(to: outputURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        } catch { print("Erreur sauvegarde SRT: \(error.localizedDescription)") }
    }

    private func applyCustomOffset() {
        let cleanInput = offsetInput.replacingOccurrences(of: ",", with: ".")
        if let offsetValue = Double(cleanInput) {
            syncFromRawText()
            for i in 0..<subtitles.count {
                subtitles[i].start = max(0, subtitles[i].start + offsetValue)
                subtitles[i].end = max(0, subtitles[i].end + offsetValue)
            }
            self.rawSRTText = generateRawSRT()
        }
    }

    private func generateRawSRT() -> String {
        var srt = ""
        for (index, sub) in subtitles.enumerated() {
            srt += "\(index + 1)\n\(formatSRTTime(sub.start)) --> \(formatSRTTime(sub.end))\n\(sub.text)\n\n"
        }
        return srt
    }

    private func formatSRTTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private func parseSRT(_ content: String) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard lines.count >= 3 else { continue }
            let parts = lines[1].components(separatedBy: " --> ")
            guard parts.count == 2 else { continue }
            entries.append(SubtitleEntry(start: timeToSeconds(parts[0]), end: timeToSeconds(parts[1]), text: lines[2...].joined(separator: "\n")))
        }
        return entries
    }

    private func timeToSeconds(_ time: String) -> Double {
        let clean = time.replacingOccurrences(of: ",", with: ".")
        let parts = clean.components(separatedBy: ":")
        guard parts.count == 3 else { return 0 }
        let h = Double(parts[0]) ?? 0, m = Double(parts[1]) ?? 0, s = Double(parts[2]) ?? 0
        return (h * 3600.0) + (m * 60.0) + s
    }

    private func setupTimer(for player: AVPlayer) {
        if let observer = timeObserver { player.removeTimeObserver(observer) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
            currentSubtitleText = subtitles.first(where: { time.seconds >= $0.start && time.seconds <= $0.end })?.text ?? ""
        }
    }

    private func handleSmartDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (data, _) in
                guard let urlData = data as? Data, let url = URL(dataRepresentation: urlData, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    let ext = url.pathExtension.lowercased()
                    if ["mp4", "mov", "m4v"].contains(ext) {
                        self.inputURL = url
                        self.sharedPlayer = AVPlayer(url: url)
                        setupTimer(for: self.sharedPlayer!)
                    } else if ext == "srt" {
                        if let content = try? String(contentsOf: url) { self.rawSRTText = content; self.subtitles = parseSRT(content) }
                    } else if let image = NSImage(contentsOf: url) {
                        self.overlays.append(OverlayImage(url: url, nsImage: image))
                    }
                }
            }
        }
    }

    private func importSRT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.utf8PlainText, UTType(filenameExtension: "srt")!]
        if panel.runModal() == .OK, let url = panel.url {
            if let content = try? String(contentsOf: url) {
                self.rawSRTText = content
                self.subtitles = parseSRT(content)
            }
        }
    }

    func startExportProcess() {
        guard let inputURL = inputURL else { return }
        syncFromRawText()
        // Export dans Downloads
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let outputURL = downloadsURL.appendingPathComponent("Export_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        isExporting = true
        
        let bgSettings = (enabled: showSubtitleBackground, color: subtitleBgColor, opacity: subtitleBgOpacity, radius: subtitleCornerRadius, padding: subtitlePadding)
        
        VideoEditorEngine().export(videoURL: inputURL, overlays: overlays, subtitles: subtitles,
                                   subtitleStyle: (subtitleFontSize, subtitleColor, subtitleYPosition, subtitleFontName),
                                   backgroundSettings: bgSettings,
                                   previewHeight: lastPreviewHeight, outputURL: outputURL) { success, _ in
            DispatchQueue.main.async {
                self.isExporting = false
                if success { NSWorkspace.shared.activateFileViewerSelecting([outputURL]) }
            }
        }
    }
}

// --- 5. COMPOSANT IMAGE DÉPLAÇABLE (DraggableOverlayView) ---

struct DraggableOverlayView: View {
    @Binding var item: OverlayImage
    let containerHeight: CGFloat
    
    // Styles globaux
    var subtitlePadding: CGFloat
    var subtitleCornerRadius: CGFloat
    var subtitleBgColor: Color
    var subtitleBgOpacity: Double
    var onDelete: () -> Void
    
    @State private var isSettingsOpen = false
    @State private var showSnapLineV: Bool = false
    @State private var showSnapLineH: Bool = false
    
    var body: some View {
        let currentScale = item.scale + item.currentScale
        let w = (containerHeight * 0.4) * currentScale
        
        // Utilisation des styles globaux pour le fond de l'image
        let bgPadding = subtitlePadding
        let bgRadius = subtitleCornerRadius
        
        ZStack {
            // 1. ANCRE STABLE (POUR LE POPOVER)
            Color.clear
                .frame(width: w, height: w / item.aspectRatio)
                .contentShape(Rectangle())
                .popover(isPresented: $isSettingsOpen, arrowEdge: .bottom) {
                    SettingsPopoverContent(item: $item, onDelete: onDelete)
                }
            
            // 2. CONTENU ROTATIF (IMAGE)
            ZStack(alignment: .center) {
                Image(nsImage: item.nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: w)
                    .padding(item.showBackground ? bgPadding : 0)
                    .background(
                        Group {
                            if item.showBackground {
                                RoundedRectangle(cornerRadius: bgRadius)
                                    .fill(subtitleBgColor.opacity(subtitleBgOpacity))
                            }
                        }
                    )
            }
            .rotationEffect(.degrees(item.rotation))
            
        }
        .offset(item.offset)
        // DOUBLE-CLIC POUR MENU
        .onTapGesture(count: 2) {
            isSettingsOpen.toggle()
        }
        // GESTE DÉPLACEMENT & ZOOM
        .gesture(
            SimultaneousGesture(
                DragGesture()
                    .onChanged { v in
                        var newWidth = item.lastOffset.width + v.translation.width
                        var newHeight = item.lastOffset.height + v.translation.height
                        
                        // SNAP (Aimant)
                        let snapThreshold: CGFloat = 15.0
                        if abs(newWidth) < snapThreshold {
                            if !showSnapLineV { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default) }
                            newWidth = 0
                            showSnapLineV = true
                        } else { showSnapLineV = false }
                        
                        if abs(newHeight) < snapThreshold {
                            if !showSnapLineH { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default) }
                            newHeight = 0
                            showSnapLineH = true
                        } else { showSnapLineH = false }
                        
                        item.offset = CGSize(width: newWidth, height: newHeight)
                    }
                    .onEnded { _ in
                        item.lastOffset = item.offset
                        showSnapLineV = false
                        showSnapLineH = false
                    },
                MagnificationGesture()
                    .onChanged { v in item.currentScale = (v - 1.0) * item.scale }
                    .onEnded { _ in
                        item.scale += item.currentScale
                        item.currentScale = 0
                    }
            )
        )
        // LIGNES DE SNAP
        .overlay {
            if showSnapLineV { Rectangle().fill(Color.yellow).frame(width: 1, height: 2000).position(x: 0, y: 0) }
            if showSnapLineH { Rectangle().fill(Color.yellow).frame(width: 2000, height: 1).position(x: 0, y: 0) }
        }
    }
}

// Contenu du menu Popover
struct SettingsPopoverContent: View {
    @Binding var item: OverlayImage
    var onDelete: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Réglages Image").font(.headline)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Rotation"); Spacer(); Text("\(Int(item.rotation))°").monospacedDigit().foregroundColor(.secondary) }
                Slider(value: $item.rotation, in: 0...360, step: 1).controlSize(.small)
                if item.rotation != 0 {
                    Button("Remettre droit (0°)") { withAnimation { item.rotation = 0 } }.font(.caption).buttonStyle(.link)
                }
            }
            Divider()
            Toggle("Fond translucide", isOn: $item.showBackground)
            Divider()
            Button(action: onDelete) { Label("Supprimer", systemImage: "trash").foregroundColor(.red) }.buttonStyle(.plain)
        }
        .padding()
        .frame(width: 250)
    }
}

// --- 6. MOTEUR D'EXPORT FINAL ---

class VideoEditorEngine {
    func export(videoURL: URL, overlays: [OverlayImage], subtitles: [SubtitleEntry],
                subtitleStyle: (size: CGFloat, color: Color, yPos: CGFloat, fontName: String),
                backgroundSettings: (enabled: Bool, color: Color, opacity: Double, radius: CGFloat, padding: CGFloat),
                previewHeight: CGFloat, outputURL: URL, completion: @escaping (Bool, Error?) -> Void) {
        
        let asset = AVAsset(url: videoURL)
        let mixComposition = AVMutableComposition()
        let renderSize = CGSize(width: 1080, height: 1920)
        
        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let compVideoTrack = mixComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        
        try? compVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let compAudioTrack = mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try? compAudioTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
        }
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.addSublayer(videoLayer)
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
        let natSize = videoTrack.naturalSize
        let scale = (natSize.width/natSize.height > 1080/1920) ? (1920/natSize.height) : (1080/natSize.width)
        let transform = videoTrack.preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (1080 - natSize.width*scale)/2, y: (1920 - natSize.height*scale)/2))
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        let uiToVideoScale = 1920 / previewHeight
        
        // 4. Overlays
        for overlay in overlays {
            var contentImage: CGImage?
            if overlay.showBackground {
                contentImage = generateOverlayWithBackground(overlay: overlay, bgSettings: backgroundSettings, scaleFactor: uiToVideoScale)
            } else if let cg = overlay.nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                contentImage = cg
            }
            
            if let cg = contentImage {
                let imgLayer = CALayer()
                imgLayer.contents = cg
                
                let rawW = (1920 * 0.4) * (overlay.scale + overlay.currentScale)
                let rawH = rawW / overlay.aspectRatio
                
                var finalW = rawW
                var finalH = rawH
                if overlay.showBackground {
                    let padding = backgroundSettings.padding * uiToVideoScale
                    finalW += (padding * 2)
                    finalH += (padding * 2)
                }
                
                let x = 540 + (overlay.offset.width * uiToVideoScale)
                let y = 960 - (overlay.offset.height * uiToVideoScale)
                
                imgLayer.bounds = CGRect(x: 0, y: 0, width: finalW, height: finalH)
                imgLayer.position = CGPoint(x: x, y: y)
                
                // Correction sens rotation (-)
                let radians = -overlay.rotation * (.pi / 180)
                imgLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(radians)))
                
                parentLayer.addSublayer(imgLayer)
            }
        }
        
        // 5. Sous-titres
        for entry in subtitles {
            if let subtitleImage = generateSubtitleImage(
                text: entry.text,
                fontName: subtitleStyle.fontName,
                fontSize: subtitleStyle.size * uiToVideoScale,
                textColor: NSColor(subtitleStyle.color),
                bgSettings: backgroundSettings,
                scaleFactor: uiToVideoScale
            ) {
                let subLayer = CALayer()
                subLayer.contents = subtitleImage
                let imgWidth = CGFloat(subtitleImage.width)
                let imgHeight = CGFloat(subtitleImage.height)
                let yPos = 1920 * (1.0 - subtitleStyle.yPos) - (imgHeight / 2)
                subLayer.frame = CGRect(x: (1080 - imgWidth) / 2, y: yPos, width: imgWidth, height: imgHeight)
                subLayer.opacity = 0.0
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = 1.0; anim.toValue = 1.0
                anim.beginTime = AVCoreAnimationBeginTimeAtZero + entry.start
                anim.duration = entry.end - entry.start
                anim.isRemovedOnCompletion = true
                subLayer.add(anim, forKey: "visibility")
                parentLayer.addSublayer(subLayer)
            }
        }
        
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        guard let export = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetHEVCHighestQuality) else { completion(false, nil); return }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        export.exportAsynchronously { completion(export.status == .completed, export.error) }
    }
    
    // Génération Overlay (Image + Fond)
    private func generateOverlayWithBackground(overlay: OverlayImage, bgSettings: (enabled: Bool, color: Color, opacity: Double, radius: CGFloat, padding: CGFloat), scaleFactor: CGFloat) -> CGImage? {
        let rawW = (1920 * 0.4) * (overlay.scale + overlay.currentScale)
        let rawH = rawW / overlay.aspectRatio
        let padding = bgSettings.padding * scaleFactor
        let finalW = ceil(rawW + (padding * 2))
        let finalH = ceil(rawH + (padding * 2))
        
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(finalW), pixelsHigh: Int(finalH), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: finalW, height: finalH)
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.clear(CGRect(x: 0, y: 0, width: finalW, height: finalH))
            let rect = NSRect(x: 0, y: 0, width: finalW, height: finalH)
            let path = NSBezierPath(roundedRect: rect, xRadius: bgSettings.radius * scaleFactor, yRadius: bgSettings.radius * scaleFactor)
            NSColor(bgSettings.color).withAlphaComponent(bgSettings.opacity).setFill()
            path.fill()
            let imgRect = NSRect(x: padding, y: padding, width: rawW, height: rawH)
            overlay.nsImage.draw(in: imgRect)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
    
    // Génération Sous-titres
    private func generateSubtitleImage(text: String, fontName: String, fontSize: CGFloat, textColor: NSColor,
                                       bgSettings: (enabled: Bool, color: Color, opacity: Double, radius: CGFloat, padding: CGFloat),
                                       scaleFactor: CGFloat) -> CGImage? {
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraphStyle]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let maxW: CGFloat = 1000
        let boundingRect = attrStr.boundingRect(with: NSSize(width: maxW, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let padding = bgSettings.padding * scaleFactor
        let finalW = ceil(boundingRect.width + (padding * 2))
        let finalH = ceil(boundingRect.height + (padding * 2))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(finalW), pixelsHigh: Int(finalH), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: finalW, height: finalH)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.clear(CGRect(x: 0, y: 0, width: finalW, height: finalH))
            if bgSettings.enabled {
                let rect = NSRect(x: 0, y: 0, width: finalW, height: finalH)
                let path = NSBezierPath(roundedRect: rect, xRadius: bgSettings.radius * scaleFactor, yRadius: bgSettings.radius * scaleFactor)
                NSColor(bgSettings.color).withAlphaComponent(bgSettings.opacity).setFill()
                path.fill()
            }
            let textRect = NSRect(x: padding, y: padding - (font.descender / 2), width: boundingRect.width, height: boundingRect.height)
            attrStr.draw(in: textRect)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
