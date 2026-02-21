import Foundation
import AppKit
import SwiftUI

// MARK: - Persistence Keys

private enum Keys {
    // Files
    static let videoBookmark      = "videoBookmark"
    static let srtContent         = "srtContent"
    static let overlayBookmarks   = "overlayBookmarks"
    static let overlaySettings    = "overlaySettings"

    // Subtitle style
    static let subtitleFontSize   = "subtitleFontSize"
    static let subtitleColorR     = "subtitleColorR"
    static let subtitleColorG     = "subtitleColorG"
    static let subtitleColorB     = "subtitleColorB"
    static let subtitleColorA     = "subtitleColorA"
    static let subtitleYPosition  = "subtitleYPosition"
    static let subtitleFontName   = "subtitleFontName"

    // Subtitle background
    static let showSubtitleBg     = "showSubtitleBackground"
    static let subtitleBgR        = "subtitleBgR"
    static let subtitleBgG        = "subtitleBgG"
    static let subtitleBgB        = "subtitleBgB"
    static let subtitleBgOpacity  = "subtitleBgOpacity"
    static let subtitleCornerRadius = "subtitleCornerRadius"
    static let subtitlePadding    = "subtitlePadding"

    // Export
    static let outputFormat       = "outputFormat"
    static let outputFileName     = "outputFileName"
    static let cropMode           = "cropMode"
    static let blurIntensity      = "blurIntensity"
}

// MARK: - Persistence Manager

final class PersistenceManager {

    static let shared = PersistenceManager()
    private let defaults = UserDefaults.standard
    private init() {}

    // MARK: - Save All Settings

    func saveSettings(from vm: EditorViewModel) {
        // Subtitle style
        defaults.set(Double(vm.subtitleFontSize), forKey: Keys.subtitleFontSize)
        defaults.set(vm.subtitleFontName, forKey: Keys.subtitleFontName)
        defaults.set(Double(vm.subtitleYPosition), forKey: Keys.subtitleYPosition)
        saveColor(vm.subtitleColor, prefix: "subtitleColor")

        // Subtitle background
        defaults.set(vm.showSubtitleBackground, forKey: Keys.showSubtitleBg)
        saveColor(vm.subtitleBgColor, prefix: "subtitleBg")
        defaults.set(vm.subtitleBgOpacity, forKey: Keys.subtitleBgOpacity)
        defaults.set(Double(vm.subtitleCornerRadius), forKey: Keys.subtitleCornerRadius)
        defaults.set(Double(vm.subtitlePadding), forKey: Keys.subtitlePadding)

        // Export
        defaults.set(vm.outputFormat.rawValue, forKey: Keys.outputFormat)
        defaults.set(vm.outputFileName, forKey: Keys.outputFileName)
        defaults.set(vm.cropMode.rawValue, forKey: Keys.cropMode)
        defaults.set(vm.blurIntensity, forKey: Keys.blurIntensity)

        // SRT content
        defaults.set(vm.rawSRTText, forKey: Keys.srtContent)
    }

    // MARK: - Restore All Settings

    func restoreSettings(into vm: EditorViewModel) {
        // Subtitle style
        if let size = defaults.object(forKey: Keys.subtitleFontSize) as? Double {
            vm.subtitleFontSize = CGFloat(size)
        }
        if let font = defaults.string(forKey: Keys.subtitleFontName) {
            vm.subtitleFontName = font
        }
        if let y = defaults.object(forKey: Keys.subtitleYPosition) as? Double {
            vm.subtitleYPosition = CGFloat(y)
        }
        if let color = loadColor(prefix: "subtitleColor") {
            vm.subtitleColor = color
        }

        // Subtitle background
        if let show = defaults.object(forKey: Keys.showSubtitleBg) as? Bool {
            vm.showSubtitleBackground = show
        }
        if let bgColor = loadColor(prefix: "subtitleBg") {
            vm.subtitleBgColor = bgColor
        }
        if let opacity = defaults.object(forKey: Keys.subtitleBgOpacity) as? Double {
            vm.subtitleBgOpacity = opacity
        }
        if let radius = defaults.object(forKey: Keys.subtitleCornerRadius) as? Double {
            vm.subtitleCornerRadius = CGFloat(radius)
        }
        if let padding = defaults.object(forKey: Keys.subtitlePadding) as? Double {
            vm.subtitlePadding = CGFloat(padding)
        }

        // Export
        if let formatRaw = defaults.string(forKey: Keys.outputFormat),
           let format = OutputFormat(rawValue: formatRaw) {
            vm.outputFormat = format
        }
        if let name = defaults.string(forKey: Keys.outputFileName) {
            vm.outputFileName = name
        }
        if let cropRaw = defaults.string(forKey: Keys.cropMode),
           let crop = CropMode(rawValue: cropRaw) {
            vm.cropMode = crop
        }
        if let blur = defaults.object(forKey: Keys.blurIntensity) as? Double {
            vm.blurIntensity = blur
        }

        // SRT content
        if let srt = defaults.string(forKey: Keys.srtContent), !srt.isEmpty {
            vm.rawSRTText = srt
            vm.subtitles = SRTParser.parse(srt)
        }
    }

    // MARK: - Video Bookmark

    func saveVideoBookmark(for url: URL) {
        guard let bookmark = makeBookmark(for: url) else { return }
        defaults.set(bookmark, forKey: Keys.videoBookmark)
    }

    func restoreVideoURL() -> URL? {
        guard let data = defaults.data(forKey: Keys.videoBookmark) else { return nil }
        return resolveBookmark(data)
    }

    func clearVideoBookmark() {
        defaults.removeObject(forKey: Keys.videoBookmark)
    }

    // MARK: - Overlay Bookmarks

    /// Saves bookmarks + per-overlay settings (transform, background style).
    func saveOverlays(_ overlays: [OverlayImage]) {
        var bookmarks: [Data] = []
        var settings: [[String: Any]] = []

        for overlay in overlays {
            guard let bookmark = makeBookmark(for: overlay.url) else { continue }
            bookmarks.append(bookmark)
            settings.append(encodeOverlaySettings(overlay))
        }

        defaults.set(bookmarks, forKey: Keys.overlayBookmarks)
        defaults.set(settings, forKey: Keys.overlaySettings)
    }

    /// Restores overlays whose files still exist on disk.
    func restoreOverlays() -> [OverlayImage] {
        guard
            let bookmarks = defaults.array(forKey: Keys.overlayBookmarks) as? [Data],
            let settingsArray = defaults.array(forKey: Keys.overlaySettings) as? [[String: Any]]
        else { return [] }

        var result: [OverlayImage] = []
        for (bookmark, settings) in zip(bookmarks, settingsArray) {
            guard
                let url = resolveBookmark(bookmark),
                let image = NSImage(contentsOf: url)
            else { continue }

            var overlay = OverlayImage(url: url, nsImage: image)
            applyOverlaySettings(settings, to: &overlay)
            result.append(overlay)
        }
        return result
    }

    func clearOverlays() {
        defaults.removeObject(forKey: Keys.overlayBookmarks)
        defaults.removeObject(forKey: Keys.overlaySettings)
    }

    // MARK: - Bookmark Helpers

    private func makeBookmark(for url: URL) -> Data? {
        // Start accessing so we can create the bookmark
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        // Verify file still exists
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // Start accessing the security-scoped resource
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    // MARK: - Color Helpers

    private func saveColor(_ color: Color, prefix: String) {
        let ns = NSColor(color)
        guard let rgb = ns.usingColorSpace(.deviceRGB) else { return }
        defaults.set(Double(rgb.redComponent),   forKey: "\(prefix)R")
        defaults.set(Double(rgb.greenComponent), forKey: "\(prefix)G")
        defaults.set(Double(rgb.blueComponent),  forKey: "\(prefix)B")
        defaults.set(Double(rgb.alphaComponent), forKey: "\(prefix)A")
    }

    private func loadColor(prefix: String) -> Color? {
        guard
            let r = defaults.object(forKey: "\(prefix)R") as? Double,
            let g = defaults.object(forKey: "\(prefix)G") as? Double,
            let b = defaults.object(forKey: "\(prefix)B") as? Double,
            let a = defaults.object(forKey: "\(prefix)A") as? Double
        else { return nil }
        return Color(NSColor(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)))
    }

    // MARK: - Overlay Settings Encoding

    private func encodeOverlaySettings(_ overlay: OverlayImage) -> [String: Any] {
        let ns = NSColor(overlay.bgColor).usingColorSpace(.deviceRGB)
        return [
            "offsetW":        Double(overlay.offset.width),
            "offsetH":        Double(overlay.offset.height),
            "scale":          Double(overlay.scale),
            "rotation":       overlay.rotation,
            "showBackground": overlay.showBackground,
            "bgOpacity":      overlay.bgOpacity,
            "bgCornerRadius": Double(overlay.bgCornerRadius),
            "bgPadding":      Double(overlay.bgPadding),
            "bgColorR":       Double(ns?.redComponent   ?? 0),
            "bgColorG":       Double(ns?.greenComponent ?? 0),
            "bgColorB":       Double(ns?.blueComponent  ?? 0),
            "bgColorA":       Double(ns?.alphaComponent ?? 1),
        ]
    }

    private func applyOverlaySettings(_ dict: [String: Any], to overlay: inout OverlayImage) {
        if let w = dict["offsetW"] as? Double, let h = dict["offsetH"] as? Double {
            overlay.offset = CGSize(width: w, height: h)
            overlay.lastOffset = overlay.offset
        }
        if let s = dict["scale"] as? Double       { overlay.scale = CGFloat(s) }
        if let r = dict["rotation"] as? Double    { overlay.rotation = r }
        if let b = dict["showBackground"] as? Bool { overlay.showBackground = b }
        if let o = dict["bgOpacity"] as? Double   { overlay.bgOpacity = o }
        if let r = dict["bgCornerRadius"] as? Double { overlay.bgCornerRadius = CGFloat(r) }
        if let p = dict["bgPadding"] as? Double   { overlay.bgPadding = CGFloat(p) }

        if let r = dict["bgColorR"] as? Double,
           let g = dict["bgColorG"] as? Double,
           let b = dict["bgColorB"] as? Double,
           let a = dict["bgColorA"] as? Double {
            overlay.bgColor = Color(NSColor(calibratedRed: CGFloat(r), green: CGFloat(g),
                                            blue: CGFloat(b), alpha: CGFloat(a)))
        }
    }
}
