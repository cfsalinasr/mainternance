import Foundation

/// Locale-aware file sizes with an automatic unit (KB, MB, GB). `formatFreeSpace` is GB-only, so small leftovers need
/// this.
func formatBytes(_ bytes: Int64, locale: Locale = .current) -> String {
    max(bytes, 0).formatted(.byteCount(style: .file).locale(locale))
}
