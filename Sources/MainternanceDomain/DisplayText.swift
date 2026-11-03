import Foundation

/// Untrusted text from disk (file names, property list values) made safe to show.
public enum DisplayText {
    /// `text` without control, format (bidi, zero-width) or illegal characters; tabs and line breaks become
    /// spaces. For showing only: never for a path or anything passed on to the system.
    public static func clean(_ text: String) -> String {
        let breaks = CharacterSet.newlines.union(CharacterSet(charactersIn: "\t"))
        let removed = CharacterSet.controlCharacters.union(.illegalCharacters)
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if breaks.contains(scalar) {
                scalars.append(" ")
            } else if !removed.contains(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }
}
