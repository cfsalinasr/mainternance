import Foundation
@testable import MainternancePresentation
import Testing

struct FormatBytesTests {
    @Test func sharedByteFormatterCoversUnitsAndZero() {
        #expect(formatBytes(41_000_000_000) == "41 GB")
        #expect(formatBytes(240_000_000) == "240 MB")
        #expect(formatBytes(12000) == "12 KB")
        #expect(formatBytes(0).contains("0"))
        #expect(!formatBytes(0).localizedCaseInsensitiveContains("zero"))
        #expect(formatBytes(-5) == formatBytes(0))
    }
}
