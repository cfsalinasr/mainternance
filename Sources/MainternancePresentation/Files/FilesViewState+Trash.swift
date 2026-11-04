import Foundation
import MainternanceDomain

extension FilesViewState {
    /// What a review will move, fixed when the review opens: whole groups (with the copies to remove) and single
    /// files from Search or Large files.
    struct TrashPlan {
        var groups: [(group: DuplicateGroup, remove: [FileItem])] = []
        var singles: [FileItem] = []

        var files: [FileItem] {
            groups.flatMap(\.remove) + singles
        }

        var bytes: Int64 {
            let perGroup = groups.map { entry in
                let product = entry.group.bytesEach.multipliedReportingOverflow(by: Int64(entry.remove.count))
                return product.overflow ? Int64.max : product.partialValue
            }
            return CleanupMath.sum(perGroup + singles.map(\.bytes))
        }
    }

    /// What the review would move: the plan's files while it is open, otherwise every copy the keep rule drops.
    var removableFiles: [FileItem] {
        plan?.files ?? duplicatePlan().files
    }

    var reclaimableBytes: Int64 {
        plan?.bytes ?? duplicatePlan().bytes
    }

    /// Why a file that is still listed could not be moved last time.
    func failureReason(for file: FileItem) -> String? {
        lastOutcome?.failed.first { $0.file.id == file.id }?.reason
    }

    var resultText: String? {
        lastOutcome.map(FilesText.result)
    }

    var failureLines: [String] {
        lastOutcome?.failed.map(FilesText.failure) ?? []
    }

    /// A scan, a review or a move is under way: nothing new may be moved.
    var isBusy: Bool {
        isFindingDuplicates || isScanningDisk || isMoving || isReviewing
    }

    private func duplicatePlan() -> TrashPlan {
        var plan = TrashPlan()
        for group in duplicateGroups {
            let removable = selection(for: group).removable
            if !removable.isEmpty {
                plan.groups.append((group, removable))
            }
        }
        return plan
    }

    /// The text of the button that opens the review, nil when nothing is removable.
    var reviewButtonText: String? {
        let files = removableFiles
        return files.isEmpty ? nil : FilesText.reviewButton(count: files.count, bytes: reclaimableBytes)
    }

    var canReview: Bool {
        !isBusy && !duplicatePlan().files.isEmpty
    }

    /// Opens the review of every duplicate the keep rule would move. Only with something removable, and not while a
    /// scan or a move runs.
    func review() {
        let candidate = duplicatePlan()
        guard !isBusy, !candidate.files.isEmpty else { return }
        lastOutcome = nil
        plan = candidate
        isReviewing = true
    }

    /// Opens the review for one file from Search or Large files.
    func requestTrash(_ file: FileItem) {
        guard !isBusy else { return }
        lastOutcome = nil
        plan = TrashPlan(singles: [file])
        isReviewing = true
    }

    func cancelReview() {
        guard isReviewing, !isMoving else { return }
        isReviewing = false
        plan = nil
    }

    /// Moves what the review showed, only after `review()` or `requestTrash(_:)`. Duplicates go one group at a time
    /// through `moveDuplicatesToTrash`, single files through `moveToTrash`.
    func confirm() async {
        guard isReviewing, !isMoving, let reviewed = plan else { return }
        isReviewing = false
        plan = nil
        isMoving = true
        defer { isMoving = false }
        var moved: [FileItem] = []
        var failed: [FileFailure] = []
        for entry in reviewed.groups {
            let outcome = await trasher.moveDuplicatesToTrash(entry.group, remove: entry.remove)
            moved += outcome.moved
            failed += outcome.failed
        }
        if !reviewed.singles.isEmpty {
            let outcome = await trasher.moveToTrash(reviewed.singles)
            moved += outcome.moved
            failed += outcome.failed
        }
        let outcome = FileTrashOutcome(moved: moved, failed: failed)
        lastOutcome = outcome
        drop(Set(moved.map(\.id)))
    }

    /// Removes moved files from every list; a group left with one copy goes away.
    private func drop(_ moved: Set<String>) {
        guard !moved.isEmpty else { return }
        diskMapIsStale = true
        searchResults.removeAll { moved.contains($0.id) }
        if let result = diskResult {
            diskResult = DiskScanResult(
                largest: result.largest.filter { !moved.contains($0.id) }, tree: result.tree,
                unreadableFolders: result.unreadableFolders, wasCancelled: result.wasCancelled
            )
        }
        duplicateGroups = duplicateGroups.compactMap { group in
            let left = group.files.filter { !moved.contains($0.id) }
            guard left.count >= 2 else { return nil }
            return left.count == group.files.count ? group
                : DuplicateGroup(id: group.id, bytesEach: group.bytesEach, files: left)
        }
    }
}
