import SwiftUI
import AVKit
import AVFoundation
import AppKit
import Combine

// MARK: - Editor ViewModel

final class EditorViewModel: ObservableObject {

    // MARK: Video
    @Published var inputURL: URL?
    @Published var sharedPlayer: AVPlayer?
    @Published var bgPlayer: AVPlayer?
    @Published var videoNaturalSize: CGSize = .zero

    // MARK: Overlays
    @Published var overlays: [OverlayImage] = []

    // MARK: Drop errors
    @Published var showDropError: Bool = false
    @Published var dropError: String? = nil

    // MARK: Overlay manager
    @Published var showOverlayManager: Bool = false
    @Published var overlayManagerPosition: CGPoint = .zero

    // MARK: Preview canvas — single source of truth for both drop positioning and export scale
    @Published var previewCanvasSize: CGSize = CGSize(width: 338, height: 600)

    var lastPreviewVideoSize: CGSize {
        get { previewCanvasSize }
        set { previewCanvasSize = newValue }
    }

    // MARK: Subtitles
    @Published var subtitles: [SubtitleEntry] = []
    @Published var rawSRTText: String = ""
    @Published var currentSubtitleText: String = ""
    @Published var offsetInput: String = "0.0"

    // MARK: Subtitle Style
    @Published var subtitleFontSize: CGFloat = 40
    @Published var subtitleColor: Color = .white
    @Published var subtitleYPosition: CGFloat = 0.8
    @Published var subtitleFontName: String = "Helvetica"
    @Published var availableFonts: [String] = []

    // MARK: Subtitle Background Style
    @Published var showSubtitleBackground: Bool = true
    @Published var subtitleBgColor: Color = .black
    @Published var subtitleBgOpacity: Double = 0.6
    @Published var subtitleCornerRadius: CGFloat = 10
    @Published var subtitlePadding: CGFloat = 10
    @Published var forceUppercaseSubtitles: Bool = false // <-- NOUVEAU
    // MARK: Export
    @Published var isExporting: Bool = false
    @Published var exportProgress: Double = 0.0
    @Published var exportError: String? = nil
    @Published var showExportError: Bool = false
    @Published var outputFormat: OutputFormat = .portrait
    @Published var outputFileName: String = "Export"
    @Published var cropMode: CropMode = .fill
    @Published var blurIntensity: Double = 40.0

    // MARK: Preview
    // (lastPreviewVideoSize is a computed alias → see previewCanvasSize above)

    // MARK: Private
    private var timeObserver: Any?
    private weak var timeObserverPlayer: AVPlayer?
    private var progressTimer: Timer?
    private var exportSession: AVAssetExportSession?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func onAppear() {
        availableFonts = NSFontManager.shared.availableFontFamilies
        restoreSession()
        setupAutosave()
    }

    func onDisappear() {
        removeTimeObserver()
    }

    // MARK: - Persistence: Restore

    private func restoreSession() {
        let pm = PersistenceManager.shared

        // Restore all scalar settings first
        pm.restoreSettings(into: self)

        // Restore video if it still exists
        if let url = pm.restoreVideoURL() {
            loadVideo(url: url, saveBookmark: false)
        }

        // Restore overlays
        let restored = pm.restoreOverlays()
        if !restored.isEmpty {
            overlays = restored
        }
    }

    // MARK: - Persistence: Autosave
    // We debounce saves by 1 second to avoid hammering UserDefaults on every slider tick.

    private func setupAutosave() {
        // Save settings whenever any published property changes
        objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                PersistenceManager.shared.saveSettings(from: self)
                PersistenceManager.shared.saveOverlays(self.overlays)
            }
            .store(in: &cancellables)
    }

    // MARK: - Time Observer

    private func removeTimeObserver() {
        if let observer = timeObserver, let player = timeObserverPlayer {
            player.removeTimeObserver(observer)
            timeObserver = nil
            timeObserverPlayer = nil
        }
    }

    func setupTimer(for player: AVPlayer) {
        removeTimeObserver()
        timeObserverPlayer = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentSubtitleText = self.subtitles.currentText(at: time.seconds)
        }
    }

    // MARK: - Drop Handling

    func handleSmartDrop(providers: [NSItemProvider], dropLocation: CGPoint = .zero, panelSize: CGSize = .zero) {
        // Process only the first provider to avoid duplicates
        guard let provider = providers.first else { return }

        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { [weak self] item, error in
            guard let self else { return }

            // Resolve URL from whatever type was returned
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let u = item as? URL {
                url = u
            } else if let str = item as? String {
                url = URL(string: str)
            } else {
                url = nil
            }

            guard let url else {
                DispatchQueue.main.async {
                    self.presentDropError("Impossible de lire le fichier.\n\(error?.localizedDescription ?? "Format non reconnu.")")
                }
                return
            }

            let ext = url.pathExtension.lowercased()
            DispatchQueue.main.async {
                if ["mp4", "mov", "m4v"].contains(ext) {
                    self.loadVideo(url: url)
                } else if ext == "srt" {
                    self.loadSRT(url: url)
                } else {
                    // Any other file → try as image
                    guard let image = NSImage(contentsOf: url) else {
                        self.presentDropError(
                            "Impossible de charger « \(url.lastPathComponent) » comme image.\n" +
                            "Formats supportés : PNG, JPEG, TIFF, GIF, WebP.\n" +
                            "Extension détectée : \(ext.isEmpty ? "aucune" : ext)"
                        )
                        return
                    }
                    self.addOverlay(image: image, url: url, dropLocation: dropLocation, panelSize: panelSize)
                }
            }
        }
    }

    private func addOverlay(image: NSImage, url: URL, dropLocation: CGPoint, panelSize: CGSize) {
        let canvas = previewCanvasSize
        let imgW = image.size.width
        let imgH = image.size.height
        guard imgW > 0, imgH > 0 else {
            presentDropError("L'image semble corrompue (dimensions nulles).")
            return
        }

        // Target: longest side = 300pt in canvas coordinates
        let targetLongest: CGFloat = 300
        let scale: CGFloat
        if imgW >= imgH {
            // width is longest → displayW = 300 → scale = 300 / (canvas.height * 0.4)
            scale = targetLongest / (canvas.height * 0.4)
        } else {
            // height is longest → displayH = 300 → displayW = 300 * aspectRatio
            // displayW = canvas.height * 0.4 * scale → scale = displayW / (canvas.height * 0.4)
            let displayW = targetLongest * (imgW / imgH)
            scale = displayW / (canvas.height * 0.4)
        }

        // The canvas is centered in the panel (GeometryReader space)
        let canvasOriginX = (panelSize.width  - canvas.width)  / 2
        let canvasOriginY = (panelSize.height - canvas.height) / 2

        // Drop position relative to canvas top-left
        let localX = dropLocation.x - canvasOriginX
        let localY = dropLocation.y - canvasOriginY

        // Convert to SwiftUI offset for ZStack(alignment: .bottom):
        // In .bottom ZStack, offset=(0,0) → overlay sits at bottom-center.
        // offset.height is relative to the BOTTOM of the canvas (negative = up).
        // Drop at localY from top → distance from bottom = canvas.height - localY
        // overlay center should be at that distance from bottom → offset = -(canvas.height - localY)
        // Convert to SwiftUI offset for ZStack(alignment: .center):
                // offset=(0,0) → overlay sits at exact center.
        let offsetX = localX - canvas.width  / 2
        let offsetY = localY - canvas.height / 2   // <-- Changed from canvas.height to canvas.height / 2

        var overlay = OverlayImage(url: url, nsImage: image)
        overlay.scale = max(scale, 0.05)  // floor to avoid invisible images
        overlay.offset = CGSize(width: offsetX, height: offsetY)
        overlay.lastOffset = overlay.offset

        overlays.append(overlay)
        PersistenceManager.shared.saveOverlays(overlays)
    }

    private func presentDropError(_ message: String) {
        dropError = message
        showDropError = true
    }

    private func loadVideo(url: URL, saveBookmark: Bool = true) {
        inputURL = url
        outputFileName = url.deletingPathExtension().lastPathComponent
        let player = AVPlayer(url: url)
        sharedPlayer = player
        setupTimer(for: player)

        // Detect actual visual size (accounts for rotation from preferredTransform)
        let asset = AVAsset(url: url)
        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            videoNaturalSize = CGSize(width: abs(size.width), height: abs(size.height))
        }

        // Second player for blurred background
        let bg = AVPlayer(url: url)
        bg.isMuted = true
        bgPlayer = bg

        // Keep bg in sync with main player rate
        player.observe(\.rate, options: [.new]) { [weak bg] main, _ in
            guard let bg else { return }
            bg.rate = main.rate
        }

        if saveBookmark {
            PersistenceManager.shared.saveVideoBookmark(for: url)
        }
    }

    private func loadSRT(url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        rawSRTText = content
        subtitles = SRTParser.parse(content)
        // SRT content is saved via autosave (rawSRTText is @Published)
    }

    // MARK: - SRT Operations

    func syncFromRawText() {
        subtitles = SRTParser.parse(rawSRTText)
    }

    func reindexSubtitles() {
        syncFromRawText()
        rawSRTText = SRTParser.generate(from: subtitles)
    }

    func applyCustomOffset() {
        let cleanInput = offsetInput.replacingOccurrences(of: ",", with: ".")
        guard let offsetValue = Double(cleanInput) else { return }
        syncFromRawText()
        for i in 0..<subtitles.count {
            subtitles[i].start = max(0, subtitles[i].start + offsetValue)
            subtitles[i].end = max(0, subtitles[i].end + offsetValue)
        }
        rawSRTText = SRTParser.generate(from: subtitles)
    }

    func saveSRTFile() {
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let filename = "subtitle_export_\(Int(Date().timeIntervalSince1970)).srt"
        let outputURL = downloadsURL.appendingPathComponent(filename)
        do {
            try rawSRTText.write(to: outputURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        } catch {
            presentError("Erreur lors de la sauvegarde SRT: \(error.localizedDescription)")
        }
    }

    func importSRT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.utf8PlainText]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            loadSRT(url: url)
        }
    }

    // MARK: - Export

    func startExportProcess() {
        guard let inputURL else { return }
        syncFromRawText()

        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }

        let safeName = outputFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Export"
            : outputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatSuffix = outputFormat.rawValue.replacingOccurrences(of: ":", with: "-")
        let fullName = "\(safeName)_\(formatSuffix).mp4"
        let outputURL = downloadsURL.appendingPathComponent(fullName)
        try? FileManager.default.removeItem(at: outputURL)

        isExporting = true
        exportProgress = 0.0

        let subtitleStyle = SubtitleStyle(
            fontSize: subtitleFontSize,
            color: subtitleColor,
            yPosition: subtitleYPosition,
            fontName: subtitleFontName,
            isUppercase: forceUppercaseSubtitles // <-- NOUVEAU
        )
        let bgStyle = BackgroundStyle(
            enabled: showSubtitleBackground,
            color: subtitleBgColor,
            opacity: subtitleBgOpacity,
            cornerRadius: subtitleCornerRadius,
            padding: subtitlePadding
        )

        let engine = VideoEditorEngine()
        engine.export(
            videoURL: inputURL,
            overlays: overlays,
            subtitles: subtitles,
            subtitleStyle: subtitleStyle,
            backgroundStyle: bgStyle,
            outputFormat: outputFormat,
            cropMode: cropMode,
            blurIntensity: blurIntensity,
            previewVideoSize: previewCanvasSize,
            outputURL: outputURL,
            onProgress: { [weak self] progress in
                DispatchQueue.main.async {
                    self?.exportProgress = Double(progress)
                }
            }
        ) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isExporting = false
                self.exportProgress = 0.0
                if success {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                } else {
                    let msg = error?.localizedDescription ?? "Erreur inconnue lors de l'exportation."
                    self.presentError(msg)
                }
            }
        }
    }

    // MARK: - Helpers

    private func presentError(_ message: String) {
        exportError = message
        showExportError = true
    }
}

// MARK: - Subtitle Binary Search Helper

private extension Array where Element == SubtitleEntry {
    func currentText(at time: Double) -> String {
        guard !isEmpty else { return "" }
        var low = 0
        var high = count - 1
        while low <= high {
            let mid = (low + high) / 2
            let entry = self[mid]
            if time < entry.start {
                high = mid - 1
            } else if time > entry.end {
                low = mid + 1
            } else {
                return entry.text
            }
        }
        return ""
    }
}
