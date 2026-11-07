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
            resolvedByQuarantine[record.id] = finding
            notice = ScannerText.moved(Self.name(of: finding.path))
            await statusStore.remember(memory)
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

    /// Puts a quarantined file back. It returns to the findings when it is linked to a finding (the link is
    /// remembered across launches and survives cancelled and failed scans; a completed scan that covers the file's
    /// path forgets it). Everything else is disabled while it runs, so a double click does nothing.
    func restore(_ id: UUID) async {
        guard !isBusy else { return }
        isRestoring = true
        defer { isRestoring = false }
        errorMessage = nil
        notice = nil
        let signature = quarantined.first { $0.id == id }?.signature
        do {
            let path = try await quarantine.restore(id)
            notice = ScannerText.restored(path, signature: signature)
            if let finding = resolvedByQuarantine.removeValue(forKey: id) {
                merge(finding)
                await statusStore.remember(memory)
            }
        } catch {
            errorMessage = ScannerText.message(for: error, action: .restore)
        }
        await reloadQuarantine()
    }

    /// A list that cannot be read is never shown as an empty quarantine: the lists keep what the last good read
    /// showed, `quarantineUnreadable` makes the screen say so, and no finding link is dropped.
    internal func reloadQuarantine() async {
        quarantineReloadCount += 1
        let mine = quarantineReloadCount
        do {
            let records = try await quarantine.records()
            let inPlace = try await quarantine.stillInPlace()
            let unclaimed = try await quarantine.unclaimedFiles().count
            // A newer reload started while this one read: its snapshot is the current one, this one is stale.
            guard mine == quarantineReloadCount else { return }
            quarantined = records
            notMoved = inPlace
            unclaimedCount = unclaimed
            quarantineUnreadable = false
        } catch {
            if mine == quarantineReloadCount {
                quarantineUnreadable = true
            }
            return
        }
        await dropLinksOfRecordsThatAreGone()
    }

    /// The Quarantine section shows while it holds anything, or while its list cannot be read.
    var showsQuarantineSection: Bool {
        quarantineUnreadable || !quarantined.isEmpty || !notMoved.isEmpty || unclaimedCount > 0
    }

    /// A link whose quarantine record no longer exists can never be restored. Only a non-empty answer proves a
    /// record is gone (an empty quarantine is also what a store that lost its folder reports), so an empty one
    /// removes nothing. A scan never removes a link: it cannot see a file that is in quarantine.
    private func dropLinksOfRecordsThatAreGone() async {
        let known = Set((quarantined + notMoved).map(\.id))
        guard !known.isEmpty else { return }
        let kept = resolvedByQuarantine.filter { known.contains($0.key) }
        guard kept.count != resolvedByQuarantine.count else { return }
        resolvedByQuarantine = kept
        await statusStore.remember(memory)
    }

    /// The file name as shown in messages (cleaned of control and bidi characters).
    internal static func name(of path: String) -> String {
        ScannerText.shownName(path)
    }
}
