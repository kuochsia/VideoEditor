import Foundation

// MARK: - SRT Parser

enum SRTParser {

    // MARK: Parsing

    static func parse(_ content: String) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            // Minimum: index line + time line + at least one text line
            guard lines.count >= 3 else { continue }

            // Line 0: sequence number (we ignore it, will be regenerated)
            // Line 1: timecode "00:00:00,000 --> 00:00:01,000"
            let parts = lines[1].components(separatedBy: " --> ")
            guard parts.count == 2 else { continue }

            let start = timeToSeconds(parts[0])
            let end = timeToSeconds(parts[1])

            // Lines 2+: subtitle text (supports multi-line subtitles)
            let text = lines[2...].joined(separator: "\n")

            entries.append(SubtitleEntry(start: start, end: end, text: text))
        }

        return entries
    }

    // MARK: Generation

    static func generate(from entries: [SubtitleEntry]) -> String {
        entries.enumerated().map { index, sub in
            "\(index + 1)\n\(formatTime(sub.start)) --> \(formatTime(sub.end))\n\(sub.text)\n"
        }.joined(separator: "\n")
    }

    // MARK: - Time Helpers

    static func timeToSeconds(_ time: String) -> Double {
        // Accept both comma (SRT standard) and period as decimal separator
        let clean = time
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = clean.components(separatedBy: ":")
        guard parts.count == 3 else { return 0 }
        let h = Double(parts[0]) ?? 0
        let m = Double(parts[1]) ?? 0
        let s = Double(parts[2]) ?? 0
        return (h * 3600.0) + (m * 60.0) + s
    }

    static func formatTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
