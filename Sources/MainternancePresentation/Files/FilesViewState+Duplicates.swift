import Foundation
import MainternanceDomain

extension FilesViewState {
    var duplicatesTotalText: String {
        FilesText.total(CleanupMath.sum(duplicateGroups.map(\.reclaimableBytes)), lowerBound: duplicatesStoppedEarly)
    }

    /// Notes under the Scan button: folders that could not be read, or a search that stopped early.
    var duplicateNotes: [String] {
        var notes: [String] = []
        if duplicateUnreadable > 0 {
            notes.append(FilesText.unreadable(duplicateUnreadable))
        }
        if duplicatesStoppedEarly {
            notes.append(FilesText.duplicatesStopped)
        }
        return notes
    }

    /// Which copy of `group` stays and which would move, by the current rule. Exactly one stays.
    func selection(for group: DuplicateGroup) -> DuplicateSelection {
        DuplicateSelection(group: group.files, rule: chosenRule)
    }

    /// Starts a duplicate scan. A scan already running is replaced: the older one stops and its late updates are
    /// ignored. Not while files are about to move.
    func startDuplicateScan() {
        guard canStartDuplicateScan else { return }
        duplicateGeneration += 1
        let mine = duplicateGeneration
        duplicateTask?.cancel()
        duplicateGroups = []
        duplicatePhase = nil
        duplicatesStoppedEarly = false
        duplicateUnreadable = 0
        hasFoundDuplicates = false
        isFindingDuplicates = true
        let stream = duplicateFinder.find()
        duplicateTask = Task { [weak self] in
            for await update in stream {
                guard let self, mine == duplicateGeneration, !Task.isCancelled else { return }
                switch update {
                case let .phase(text):
                    duplicatePhase = DisplayText.clean(text)
                case let .group(group):
                    duplicateGroups.removeAll { $0.id == group.id }
                    duplicateGroups.append(group)
                case let .finished(unreadable, wasCancelled):
                    duplicateUnreadable = unreadable
                    duplicatesStoppedEarly = wasCancelled
                }
            }
            guard let self, mine == duplicateGeneration else { return }
            finishDuplicateScan()
        }
    }

    private func finishDuplicateScan() {
        isFindingDuplicates = false
        duplicatePhase = nil
        hasFoundDuplicates = true
    }

    /// Stops the duplicate scan; the groups found so far stay.
    func stopDuplicateScan() {
        guard isFindingDuplicates else { return }
        duplicateGeneration += 1
        duplicateTask?.cancel()
        duplicatesStoppedEarly = true
        finishDuplicateScan()
    }

    /// Waits for the running duplicate scan to end (tests).
    func waitForDuplicateScan() async {
        await duplicateTask?.value
    }
}
