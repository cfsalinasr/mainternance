import Foundation

/// Port for the malware scanning engine. Implemented in the Data layer.
public protocol ScannerEngine: Sendable {
    func status() async -> EngineStatus
    func install() -> AsyncStream<InstallEvent>
    func updateDefinitions() -> AsyncStream<InstallEvent>
    func scan(_ scope: ScanScope) -> AsyncStream<ScanEvent>
    func cancelScan() async
}
