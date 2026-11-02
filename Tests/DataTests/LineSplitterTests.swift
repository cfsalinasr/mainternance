@testable import MainternanceData
import Testing

@Suite("LineSplitter")
struct LineSplitterTests {
    private func feed(_ splitter: inout LineSplitter, _ bytes: [UInt8]) -> [String] {
        bytes.withUnsafeBufferPointer { splitter.append($0) }
    }

    @Test("a line longer than the cap is split without losing a byte")
    func longLineIsCapped() {
        var splitter = LineSplitter()
        let total = 3 * LineSplitter.maxLineBytes
        var lines: [String] = []
        for _ in 0 ..< (total / 65536) {
            lines += feed(&splitter, [UInt8](repeating: 0x61, count: 65536))
        }
        if let last = splitter.flush() {
            lines.append(last)
        }
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.utf8.count == LineSplitter.maxLineBytes })
        #expect(lines.reduce(0) { $0 + $1.utf8.count } == total)
    }

    @Test("a line of exactly the cap followed by a newline is one line")
    func exactCap() {
        var splitter = LineSplitter()
        var lines = feed(&splitter, [UInt8](repeating: 0x62, count: LineSplitter.maxLineBytes))
        lines += feed(&splitter, [0x0A, 0x63, 0x0A])
        #expect(lines.map(\.utf8.count) == [LineSplitter.maxLineBytes, 1])
    }

    @Test("lines split across chunks are joined, CRLF trimmed")
    func chunked() {
        var splitter = LineSplitter()
        var lines = feed(&splitter, Array("ab".utf8))
        lines += feed(&splitter, Array("c\r\nd".utf8))
        lines += feed(&splitter, Array("e\n".utf8))
        #expect(lines == ["abc", "de"])
        #expect(splitter.flush() == nil)
    }
}
