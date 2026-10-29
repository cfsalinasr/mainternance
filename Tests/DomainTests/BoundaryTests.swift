import Foundation
import Testing

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func runBoundaryScript(root: URL?) throws -> Int32 {
    let process = Process()
    process.executableURL = repoRoot.appendingPathComponent("scripts/check-boundaries.sh")
    process.arguments = root.map { [$0.path] } ?? []
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// Builds a temp tree from `["Layer": "source"]` (placed at Sources/Layer/File.swift), runs the script, cleans up.
private func status(for files: [String: String]) throws -> Int32 {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    for (layer, source) in files {
        let dir = temp.appendingPathComponent("Sources/\(layer)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try source.write(to: dir.appendingPathComponent("File.swift"), atomically: true, encoding: .utf8)
    }
    return try runBoundaryScript(root: temp)
}

@Test func layerBoundariesHold() throws {
    #expect(try runBoundaryScript(root: nil) == 0)
}

@Test func boundaryScriptDetectsViolation() throws {
    #expect(try status(for: ["MainternanceDomain": "import SwiftUI\n"]) == 1)
}

@Test(arguments: [
    "import Foundation\nimport SwiftUI\n",
    "import Foundation; import SwiftUI\n",
    "@testable import MainternanceData\n",
    "import struct Foundation.Date\n",
    "let x = 1; import SwiftUI\n",
    "/* c */ import SwiftUI\n",
    "/* a\n b */ import SwiftUI\n"
])
func domainViolations(source: String) throws {
    #expect(try status(for: ["MainternanceDomain": source]) == 1)
}

@Test(arguments: [
    "import Foundation\n",
    "import Foundation // comment\n",
    "import Foundation; import Foundation\n",
    "// import SwiftUI\nimport Foundation\n",
    "/* import SwiftUI */\nimport Foundation\n",
    "/*\nimport SwiftUI\n*/\nimport Foundation\n"
])
func domainAllowed(source: String) throws {
    #expect(try status(for: ["MainternanceDomain": source]) == 0)
}

@Test(arguments: [
    "import MainternanceData\n",
    "@testable import MainternanceData\n",
    "import SwiftUI; import MainternanceData\n",
    "import struct MainternanceData.Thing\n"
])
func presentationViolations(source: String) throws {
    #expect(try status(for: ["MainternancePresentation": source]) == 1)
}

@Test func presentationAllowsSwiftUIAndDomain() throws {
    let source = "import SwiftUI\nimport MainternanceDomain\n// import MainternanceData\n"
    #expect(try status(for: ["MainternancePresentation": source]) == 0)
}

@Test func dataRejectsSwiftUI() throws {
    #expect(try status(for: ["MainternanceData": "import SwiftUI\n"]) == 1)
    #expect(try status(for: ["MainternanceData": "import Foundation; import SwiftUI\n"]) == 1)
}

@Test func dataAllowsFoundationAndDomain() throws {
    #expect(try status(for: ["MainternanceData": "import Foundation\nimport MainternanceDomain\n"]) == 0)
}

@Test func missingRootFails() throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
    #expect(try runBoundaryScript(root: missing) != 0)
}

@Test func rootWithoutSourcesFails() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    #expect(try runBoundaryScript(root: temp) != 0)
}
