import MainternanceDomain

/// There is no scanner engine yet, so there is no status to report.
public struct NoScannerStatusProvider: ScanStatusProviding {
    public init() {}

    public func currentStatus() async -> ScanStatus? {
        nil
    }
}
