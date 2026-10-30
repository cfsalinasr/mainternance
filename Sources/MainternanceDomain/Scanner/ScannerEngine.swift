import Foundation

/// Port for the malware scanning engine. Implemented in the Data layer.
public protocol ScannerEngine: Sendable {
    func status() async -> EngineStatus
    func install() -> AsyncStream<InstallEvent>
    func updateDefinitions() -> AsyncStream<InstallEvent>
    /// Runs a scan. `.found` events that arrive before a `.failed` are real and must be kept by the consumer.
    func scan(_ scope: ScanScope) -> AsyncStream<ScanEvent>
    /// Re-scans exactly one file. A finding must be `.confirmed` with the same signature before the app acts on it
    /// (scan output can be forged by file names, so it is never trusted on its own).
    func verifyFinding(path: String) async -> VerifyResult
    func cancelScan() async
}
