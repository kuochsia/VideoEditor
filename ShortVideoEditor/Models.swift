import SwiftUI
import AppKit

// MARK: - Subtitle

struct SubtitleEntry: Identifiable {
    let id = UUID()
    var start: Double
    var end: Double
    var text: String
}

// MARK: - Overlay Image

struct OverlayImage: Identifiable {
    let id = UUID()
    var url: URL
    var nsImage: NSImage
    var offset: CGSize = .zero
    var lastOffset: CGSize = .zero
    var scale: CGFloat = 0.3
    var currentScale: CGFloat = 0.0

    // Transform
    var rotation: Double = 0.0

    // Highlight (used by overlay manager panel)
    var isHighlighted: Bool = false

    // Independent background style (separate from subtitle style)
    var showBackground: Bool = false
    var bgColor: Color = .black
    var bgOpacity: Double = 0.6
    var bgCornerRadius: CGFloat = 10
    var bgPadding: CGFloat = 10

    var aspectRatio: CGFloat {
        let h = nsImage.size.height > 0 ? nsImage.size.height : 1
        return nsImage.size.width / h
    }
}

// MARK: - Output Format

enum OutputFormat: String, CaseIterable, Identifiable {
    case portrait  = "9:16"
    case square    = "1:1"
    case landscape = "16:9"

    var id: String { rawValue }

    var renderSize: CGSize {
        switch self {
        case .portrait:  return CGSize(width: 1080, height: 1920)
        case .square:    return CGSize(width: 1080, height: 1080)
        case .landscape: return CGSize(width: 1920, height: 1080)
        }
    }

    /// Width/Height ratio for the preview panel
    var previewAspectRatio: CGFloat {
        let s = renderSize
        return s.width / s.height
    }
    var previewReferenceIsHeight: Bool {
        switch self {
        case .portrait, .square: return true
        case .landscape:         return false
        }
    }

    var icon: String {
        switch self {
        case .portrait:  return "iphone"
        case .square:    return "square"
        case .landscape: return "rectangle"
        }
    }
}

// MARK: - Crop Mode

enum CropMode: String, CaseIterable, Identifiable {
    case fill        = "Fill"
    case blurred     = "Flou"
    case black       = "Noir"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .fill:    return "arrow.up.left.and.arrow.down.right"
        case .blurred: return "square.stack.3d.down.right"
        case .black:   return "square.fill"
        }
    }

    var description: String {
        switch self {
        case .fill:    return "Recadrage plein"
        case .blurred: return "Fond flouté"
        case .black:   return "Fond noir"
        }
    }
}

// MARK: - Style Structs (avoid anonymous tuples in engine calls)

struct SubtitleStyle {
    var fontSize: CGFloat
    var color: Color
    var yPosition: CGFloat
    var fontName: String
}

struct BackgroundStyle {
    var enabled: Bool
    var color: Color
    var opacity: Double
    var cornerRadius: CGFloat
    var padding: CGFloat
}
