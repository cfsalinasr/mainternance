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

@Test func layerBoundariesHold() throws {
    #expect(try runBoundaryScript(root: nil) == 0)
}

@Test func boundaryScriptDetectsViolation() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("boundary-\(UUID().uuidString)")
    let domain = temp.appendingPathComponent("Sources/MainternanceDomain")
    try FileManager.default.createDirectory(at: domain, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    try "import SwiftUI\n".write(to: domain.appendingPathComponent("Bad.swift"), atomically: true, encoding: .utf8)
    #expect(try runBoundaryScript(root: temp) == 1)
}
