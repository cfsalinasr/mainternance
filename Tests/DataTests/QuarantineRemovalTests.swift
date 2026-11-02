import Darwin
import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("Quarantine removal guard")
struct QuarantineRemovalTests {
    private func info(_ path: String) throws -> stat {
        try #require(QuarantineFiles.linkInfo(path))
    }

    @Test("only sidecars and partial files directly in the vault are vault artifacts")
    func artifactNames() {
        let id = UUID().uuidString
        #expect(QuarantineRemoval.isVaultArtifactName("\(id).json"))
        #expect(QuarantineRemoval.isVaultArtifactName("\(id).partial"))
        #expect(!QuarantineRemoval.isVaultArtifactName("index.json"))
        #expect(!QuarantineRemoval.isVaultArtifactName(id))
        #expect(!QuarantineRemoval.isVaultArtifactName("../\(id).json"))
        #expect(!QuarantineRemoval.isVaultArtifactName("sub/x.partial"))
    }

    @Test("a name that is not a vault artifact is refused and stays")
    func refusesForeignName() throws {
        let temp = try TempDirectory()
        let manifest = temp.url.appendingPathComponent("index.json")
        try Data("{}".utf8).write(to: manifest)
        #expect(throws: QuarantineError.self) {
            try QuarantineRemoval.remove(.vaultArtifact(vault: temp.url, name: "index.json"))
        }
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test("a symlink with an artifact name is refused and its target stays")
    func refusesSymlink() throws {
        let temp = try TempDirectory()
        let target = temp.url.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        let name = "\(UUID().uuidString).json"
        try FileManager.default.createSymbolicLink(
            atPath: temp.url.appendingPathComponent(name).path, withDestinationPath: target.path
        )
        #expect(throws: QuarantineError.changedSinceScan) {
            try QuarantineRemoval.remove(.vaultArtifact(vault: temp.url, name: name))
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    }

    @Test("a missing artifact is already done")
    func missingArtifactIsDone() throws {
        let temp = try TempDirectory()
        try QuarantineRemoval.remove(.vaultArtifact(vault: temp.url, name: "\(UUID().uuidString).partial"))
    }

    @Test("the original is removed only from the very folder that was checked, and only if it is the same file")
    func verifiedOriginal() throws {
        let temp = try TempDirectory()
        let folder = try QuarantineFiles.realParent(of: temp.url.appendingPathComponent("x").path)
        let file = temp.url.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        let identity = try QuarantineFiles.folderIdentity(folder)
        let other = temp.url.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: other)
        // A different file under the checked name is refused.
        #expect(throws: QuarantineError.changedSinceScan) {
            try QuarantineRemoval.remove(.verifiedOriginal(
                folder: folder, folderIdentity: identity, name: "a.txt", file: info(other.path)
            ))
        }
        // The same file in a folder that is not the checked one is refused.
        let elsewhere = try info(file.path)
        var wrongFolder = identity
        wrongFolder.st_ino += 1
        #expect(throws: QuarantineError.changedSinceScan) {
            try QuarantineRemoval.remove(.verifiedOriginal(
                folder: folder, folderIdentity: wrongFolder, name: "a.txt", file: elsewhere
            ))
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        try QuarantineRemoval.remove(.verifiedOriginal(
            folder: folder, folderIdentity: identity, name: "a.txt", file: elsewhere
        ))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
}
