import Foundation
import MainternanceDomain

public extension ScannerViewModel {
    // MARK: - Quarantine

    /// Opens the confirmation sheet for one unresolved finding; unknown ids and busy states do nothing.
    func requestQuarantine(_ id: UUID) {
        guard !isBusy, let finding = findings.first(where: { $0.id == id }) else { return }
        pendingQuarantine = finding
    }

    func cancelQuarantine() {
        pendingQuarantine = nil
    }

    /// Re-checks the requested finding with the engine, and only when the engine confirms the same detection moves
    /// the file to quarantine. Every refusal leaves the finding listed and says why.
    func confirmQuarantine() async {
        guard let requested = pendingQuarantine, !isBusy else { return }
        let id = requested.id
        pendingQuarantine = nil
        errorMessage = nil
        notice = nil
        guard let finding = findings.first(where: { $0.id == id }) else { return }
        isQuarantining = true
        defer { isQuarantining = false }
        guard await isStillDetected(finding) else { return }
        do {
            let record = try await quarantine.quarantine(path: finding.path, signature: finding.signature)
            findings.removeAll { $0.id == id }
            quarantinedFindings[record.id] = finding
            notice = ScannerText.moved(Self.name(of: finding.path))
            await statusStore.updateFindings(findings)
        } catch {
            errorMessage = ScannerText.message(for: error, action: .quarantine)
        }
        await reloadQuarantine()
    }

    private func isStillDetected(_ finding: ScanFinding) async -> Bool {
        switch await scanner.verifyFinding(path: finding.path) {
        case let .confirmed(signature) where signature == finding.signature:
            return true
        case let .confirmed(signature):
            errorMessage = ScannerText.verifyDifferent(signature)
        case .clean:
            errorMessage = ScannerText.verifyClean(Self.name(of: finding.path))
        case let .failed(message):
            errorMessage = ScannerText.verifyFailed(message)
        }
        return false
    }

    /// Puts a quarantined file back. It returns to the findings only when it came from the current scan's list.
    func restore(_ id: UUID) async {
        guard !isBusy else { return }
        errorMessage = nil
        notice = nil
        let signature = quarantined.first { $0.id == id }?.signature
        do {
            let path = try await quarantine.restore(id)
            notice = ScannerText.restored(path, signature: signature)
            if let finding = quarantinedFindings.removeValue(forKey: id) {
                findings.append(finding)
                await statusStore.updateFindings(findings)
            }
        } catch {
            errorMessage = ScannerText.message(for: error, action: .restore)
        }
        await reloadQuarantine()
    }

    internal func reloadQuarantine() async {
        quarantined = await quarantine.records()
        notMoved = await quarantine.stillInPlace()
        unclaimedCount = await quarantine.unclaimedFiles().count
    }

    internal static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
