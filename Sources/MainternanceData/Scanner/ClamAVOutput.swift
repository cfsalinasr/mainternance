import Foundation

/// Keeps the last couple of stderr lines of a child, sanitized, for failure messages.
struct StderrTail {
    private var lines: [String] = []

    mutating func add(_ line: String) {
        let clean = ClamAVInstaller.sanitized(line)
        guard !clean.isEmpty else { return }
        lines.append(clean)
        if lines.count > 2 {
            lines.removeFirst()
        }
    }

    func failureMessage(prefix: String) -> String {
        lines.isEmpty ? prefix : "\(prefix): \(lines.joined(separator: " "))"
    }
}

extension ClamAVInstaller {
    static let maxMessageLength = 200

    /// Replaces control characters with spaces, trims and bounds the length.
    static func sanitized(_ text: String) -> String {
        let mapped = String(String.UnicodeScalarView(text.unicodeScalars.map {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ? " " : $0
        }))
        let collapsed = mapped.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard collapsed.count > maxMessageLength else { return collapsed }
        return String(collapsed.prefix(maxMessageLength)) + "…"
    }

    /// Download progress 0...1 from a freshclam output line, nil when the line carries none.
    ///
    /// Accepts `... [=====>   ] 62.58MiB/62.58MiB` (bytes done over total) and `62%`. Anything else, odd or
    /// non-finite numbers included, is nil; values are clamped to 0...1. Only the last carriage-return separated
    /// segment is read, because freshclam redraws its progress bar in place.
    static func parseFreshclamProgress(_ line: String) -> Double? {
        guard let segment = line.split(separator: "\r").last.map(String.init) else { return nil }
        let range = NSRange(segment.startIndex..., in: segment)
        if let match = sizePair.firstMatch(in: segment, range: range) {
            return sizeRatio(segment, match)
        }
        if let match = percent.firstMatch(in: segment, range: range), let value = number(segment, match, 1) {
            return clamp(value / 100)
        }
        return nil
    }

    private static func sizeRatio(_ text: String, _ match: NSTextCheckingResult) -> Double? {
        guard let done = number(text, match, 1), let total = number(text, match, 3),
              let doneUnit = unitFactor(text, match, 2), let totalUnit = unitFactor(text, match, 4)
        else {
            return nil
        }
        let denominator = total * totalUnit
        guard denominator > 0 else { return nil }
        return clamp(done * doneUnit / denominator)
    }

    private static func clamp(_ value: Double) -> Double? {
        value.isFinite ? min(max(value, 0), 1) : nil
    }

    private static func number(_ text: String, _ match: NSTextCheckingResult, _ group: Int) -> Double? {
        guard let range = Range(match.range(at: group), in: text) else { return nil }
        return Double(text[range])
    }

    private static func unitFactor(_ text: String, _ match: NSTextCheckingResult, _ group: Int) -> Double? {
        guard let range = Range(match.range(at: group), in: text) else { return nil }
        switch text[range].lowercased() {
        case "b": return 1
        case "kib", "kb": return 1024
        case "mib", "mb": return 1024 * 1024
        case "gib", "gb": return 1024 * 1024 * 1024
        case "tib", "tb": return 1024 * 1024 * 1024 * 1024
        default: return nil
        }
    }

    // swiftlint:disable force_try
    private static let sizePair = try! NSRegularExpression(
        pattern: #"(?<![\d.\-])(\d+(?:\.\d+)?)\s*([KMGT]?i?B)\s*/\s*(\d+(?:\.\d+)?)\s*([KMGT]?i?B)"#,
        options: [.caseInsensitive]
    )
    private static let percent = try! NSRegularExpression(pattern: #"(?<![\d.\-])(\d+(?:\.\d+)?)\s*%"#)
    // swiftlint:enable force_try
}
