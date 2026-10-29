/// Byte formatting for file rows; an empty file reads "Empty" rather than "Zero KB".
func formatFileSize(_ bytes: Int64) -> String {
    bytes > 0 ? formatFreeSpace(bytes) : "Empty"
}
