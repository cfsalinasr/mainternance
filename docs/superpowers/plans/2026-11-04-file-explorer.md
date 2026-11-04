# File Explorer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A real Files screen with three honest parts: instant search (Spotlight), a large-files list with a disk-usage treemap, and a duplicate finder, with Quick Look, Reveal in Finder and a reviewed move to the Trash (never a permanent delete).

**Architecture:** Domain gets file types and ports. Data implements them: one shared folder walker (no link following, same volume, cancellable, streaming) used by the large-file scan, the disk tree and the duplicate finder; a Spotlight searcher behind a port; a trasher with the same re-check discipline as `CleanupMover`/`AppMover`. Presentation replaces the sample `FilesViewState`/views (keeping `TreemapLayout`, `KeepRule` logic and the view shells that still fit) with a real state; the App target wires it. Same layers, rules and review process as `docs/superpowers/plans/2026-11-03-uninstaller.md`.

**Tech Stack:** Swift 6, Foundation (`FileManager`, `NSMetadataQuery`), CryptoKit (SHA-256), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-29-mainternance-design.md` ("File explorer") plus the decisions below (the owner asked for the rest of the app to be built at the builder's discretion).

## Decisions (builder's calls)

- **Where it looks:** the owner's home folder only. Never walked: `~/Library`, `~/.Trash`, any folder whose name starts with `.`, links (not followed, never counted twice), other volumes (not crossed), and anything `ProtectedPaths.isProtected` says. Package folders (`.app`, `.photoslibrary`, any folder macOS reports as a package) count as ONE item in sizes and the treemap and are never offered for the Trash; only plain files can be moved. Folders macOS refuses to read (privacy prompts on Desktop, Documents, Downloads) are counted and reported ("N folders could not be read") and make totals "at least".
- **Sizes** are allocated bytes (`totalFileAllocatedSize`), shown with "about"/"at least" like Cleanup.
- **Search:** `NSMetadataQuery` over the home scope, results capped at 500, newest change first, results under `~/Library` or dot-folders dropped, each result re-checked with `lstat` (exists, plain file or folder) before it is shown. Filters: name text (case-insensitive contains), type (`FileKind`), minimum size (the existing `SizeFilter`), changed within (the existing `DateFilter`). Search is debounced 300 ms and only the newest query's results are shown. Copy says "Spotlight results: files Spotlight has not indexed will not appear." A search that finds nothing never claims Spotlight is off (it cannot tell).
- **Large files:** plain files of at least 50 MB, the largest 200, largest first, streamed as the walk progresses; plus a disk tree for the treemap with at most 40 children per folder and one "Other" node for the rest. Scanning runs on demand (a button and when the Large files tab first opens), never at launch, at utility priority, and is cancellable.
- **Duplicates:** plain files of at least 1 MB. Group by exact size, then SHA-256 of the first and last 64 KiB, then SHA-256 of the whole file to confirm. Hard links (same device and inode) are one file, never a duplicate pair. APFS clones cannot be told apart cheaply: the screen says "Clones share disk space, so moving one may free less than shown." Results stream in as groups are confirmed; cancellable.
- **Keep one:** every duplicate group keeps at least one copy; rules newest, oldest, shortest path (existing `KeepRule`, ties by shorter then alphabetical path). The state never offers all copies, and the trasher refuses a duplicate move unless another copy still exists with the same size and identity.
- **Trash:** `FileManager.trashItem` through an injected closure (same as Cleanup/Uninstaller); `removeItem`, `unlink`, `rm` forbidden. Before each move the trasher re-checks: path inside the home folder (parent resolved), not under `~/Library` or a dot-folder, not protected, a plain file, same volume, and unchanged since scanning (device/inode identity, size and modified date); anything else is refused with a reason. One refusal never stops the rest. Nothing moves without the review sheet and an explicit confirm.
- **Quick Look and Reveal** are injected closures (`NSWorkspace`/SwiftUI `quickLookPreview` in the App/View layer), never decision logic in views.
- **Honest copy:** no "safe to delete" wording; "freed" counts only what moved; scanning shows what it is doing and how many folders it could not read.

## Global Constraints

- Layer rules: Domain imports only Foundation; Presentation never imports Data; only the App target wires Data; no file access or decision rules in views.
- No permanent deletion anywhere (the only exemption is `QuarantineRemoval`). Trash moves go through an injected closure; tests NEVER touch the real Trash, the real home folder or `~/Library` (temp folders only; Spotlight itself is never queried in automated tests).
- Names and paths from disk are untrusted: shown through `DisplayText.clean`; never executed; never put in a shell command.
- Unknown is nil, never faked. Anything not real says so or stays hidden.
- `scripts/lint.sh` exit 0, `scripts/check-boundaries.sh`, `scripts/test.sh` green before every commit; commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; every commit builds. Float tolerances in tests; no hard-coded absolute paths in `Sources` (SonarCloud S1075): ask `FileManager`/`URL` APIs or take parameters.

## Review Focus

- A link in the tree (to `/System`, to home, to a folder above itself making a loop) is never followed or double counted; a folder that is another volume's mount point is not entered. Pinned in Task 1.
- A huge or deeply nested tree, unreadable folders and cancellation: the walk stays bounded in memory, stops promptly on cancel and reports unreadable folders. Pinned in Tasks 1 and 2.
- Files with identical size and identical head and tail but different middles are NOT reported as duplicates; hard links are not duplicates; empty and tiny files are ignored. Pinned in Task 2.
- A file changed, replaced or removed between scan and confirm is refused, never trashed blindly; a duplicate move that would leave no copy is refused. Pinned in Task 4.
- Odd names (spaces, newlines, leading `-`, RTL override) display safely and move correctly. Pinned in Tasks 1 and 4.
- Two overlapping searches or scans must not show an older result over a newer one; leaving the screen cancels work. Pinned in Tasks 5 and 6.

---

## File structure

- Domain (new): `Sources/MainternanceDomain/Files/FileTypes.swift` (`FileKind`, `FileItem`, `DiskNode`, `DuplicateGroup`, `FileSearchQuery`, updates), `FilePorts.swift`.
- Data (new): `Sources/MainternanceData/Files/FileWalker.swift`, `LargeFileScanner.swift`, `DuplicateFinder.swift`, `SpotlightPredicate.swift`, `SpotlightSearcher.swift`, `FileTrasher.swift`, `FilesServices.swift`. Reuse `ItemStat`, `CleanupRules.resolve`, `CleanupMeasurer.size(of:device:)` ideas, `ProtectedPaths`, `DisplayText`, `CleanupServices.moveToTrash`.
- Presentation: rewrite `Files/FilesViewState.swift`, `FilesView.swift`, `FileResultRow.swift`, `LargeFilesView.swift`, `DuplicateGroupView.swift`, `FileSearch.swift` (criteria only; the sample filter goes), `DiskTreemapView.swift` (uses `DiskNode`); keep `TreemapLayout.swift` and `FileSizeText.swift`; add `Files/FilesReviewSheet.swift`, `Files/FilesText.swift`; delete `FilesSampleData.swift`, `SampleFile`, the sample `DuplicateGroup`/`TreemapNode` and their tests (`FilesSampleDataTests.swift`).
- App: `CompositionRoot.swift`, `MainternanceApp.swift`, `Window/WindowStates.swift`.
- Domain `Health.swift` (`.files` available), `HomeModel.comingNextText`, docs.

### Task 1: Domain, walker, large files and disk tree

**Files:** Domain types/ports above; Data `FileWalker.swift`, `LargeFileScanner.swift`; Test: `Tests/DomainTests/FileTypesTests.swift`, `Tests/DataTests/FileWalkerTests.swift`, `LargeFileScannerTests.swift`, `FilesTestSupport.swift`.

**Interfaces (Produces):**
- `public enum FileKind: String, Sendable, CaseIterable { case document, image, video, audio, archive, code, other }` with `static func kind(forExtension:) -> FileKind` (the one table; Presentation adds `title`/`symbol`).
- `public struct FileItem: Sendable, Equatable, Identifiable { public let id: String /* absolute path */; public let name: String; public let bytes: Int64; public let modified: Date; public let kind: FileKind; public let identity: CleanupEntry.Identity?; public var displayName: String; public var displayPath: String }`.
- `public final class DiskNode: Sendable, Identifiable { public let id: String; public let name: String; public let bytes: Int64; public let isOther: Bool; public let isPackage: Bool; public let children: [DiskNode]; public var isDrillable: Bool }` (an immutable tree; `isOther` aggregates the children beyond 40).
- `public struct DiskScanResult: Sendable, Equatable { public let largest: [FileItem]; public let tree: DiskNode; public let unreadableFolders: Int; public let wasCancelled: Bool }`.
- `public enum DiskScanUpdate: Sendable { case progress(scannedFiles: Int), finished(DiskScanResult) }`.
- `public protocol DiskScanning: Sendable { func scan() -> AsyncStream<DiskScanUpdate> }` (the stream ends after `finished`; cancelling the consuming task stops the walk, but the consumer's iterator ends at once and never sees a result, so Tasks 5 and 6 treat a cancelled scan as having no result and keep the previous one; `wasCancelled` exists for tests and for a stop handle if partial results are ever wanted).
- Data: `struct FileWalker: Sendable { init(home: URL, isProtected: @escaping @Sendable (String) -> Bool); func walk(onFile: (WalkedFile) -> Void, onFolderUnreadable: () -> Void, shouldStop: () -> Bool) }` where `WalkedFile` carries path, `ItemStat`, `isPackageRoot`. The walk skips the exclusions in Decisions.

- [ ] **Step 1: Write the failing tests** for each Review Focus line of this task plus: kinds by extension (case-insensitive; unknown → other); `DiskNode` keeps 40 children and an `Other` node summing the rest; the largest list holds files at or above 50 MB (the threshold is injectable so tests use small files), sorted largest first, capped at 200; sizes `>= written` and `< written + 1 MiB`; packages count once and are not in `largest`; `~/Library`, `.Trash`, dot-folders are never entered; a hard-linked pair counts once; progress updates arrive; cancelling stops promptly with `wasCancelled`.
- [ ] **Step 2: Run** `scripts/test.sh`; expect failures.
- [ ] **Step 3: Implement** the types, `FileWalker` (`contentsOfDirectory` plus `ItemStat.read`, no link following, device check against the home folder's device, depth-first, an explicit stack not recursion) and `LargeFileScanner` building `largest` with a bounded min-heap and the tree bottom-up.
- [ ] **Step 4: Run** tests, lint, boundaries; green.
- [ ] **Step 5: Commit** `feat: file walker, large files and disk tree`.

### Task 2: Data: duplicate finder

**Files:** Domain `DuplicateGroup`, `DuplicateUpdate`, `DuplicateFinding` in `FileTypes.swift`/`FilePorts.swift`; Data `DuplicateFinder.swift`; Test: `Tests/DataTests/DuplicateFinderTests.swift`.

**Interfaces:**
- Consumes: Task 1 `FileWalker`, `FileItem`.
- Produces: `public struct DuplicateGroup: Sendable, Equatable, Identifiable { public let id: String; public let bytesEach: Int64; public let files: [FileItem] /* at least 2 */; public var reclaimableBytes: Int64 /* bytesEach * (count - 1): what moving all but one copy would free */ }`; `public enum DuplicateUpdate: Sendable { case phase(String), group(DuplicateGroup), finished(unreadableFolders: Int, wasCancelled: Bool) }`; `public protocol DuplicateFinding: Sendable { func find() -> AsyncStream<DuplicateUpdate> }`. Data: `DuplicateFinder(home:isProtected:minimumBytes: Int64 = 1_000_000)`.

- [ ] **Step 1: Write the failing tests** for each Review Focus line of this task plus: three identical files plus one different of the same size give one group of three; same size and same head/tail but a different middle give no group; hard links are one file; files under the minimum are ignored; groups stream (`.group` arrives before `.finished`); results are deterministic in order (largest group first within a pass is not required, but the files inside a group are sorted by path); cancelling returns promptly; a file that becomes unreadable mid-hash is dropped, not reported.
- [ ] **Step 2: Run** tests; expect failures.
- [ ] **Step 3: Implement** the three passes with CryptoKit `SHA256` and bounded reads (64 KiB chunks via `FileHandle`, `Task.isCancelled` between chunks); never read a file twice for the same pass.
- [ ] **Step 4: Run** tests, lint, boundaries; green.
- [ ] **Step 5: Commit** `feat: duplicate finder`.

### Task 3: Data: Spotlight search

**Files:** Domain `FileSearchQuery`, `FileSearching` port (`func search(_ query: FileSearchQuery) async -> FileSearchResult`, `FileSearchResult { files: [FileItem]; isTruncated: Bool }`); Data `SpotlightPredicate.swift`, `SpotlightSearcher.swift`; Test: `Tests/DataTests/SpotlightPredicateTests.swift`, `SpotlightSearcherTests.swift`.

**Interfaces:**
- Produces: `public struct FileSearchQuery: Sendable, Equatable { public var text: String; public var kind: FileKind?; public var minimumBytes: Int64; public var modifiedAfter: Date? ; public var isEmpty: Bool }`; Data `enum SpotlightPredicate { static func make(_ query: FileSearchQuery) -> NSPredicate? }` (nil for an empty query; text is escaped, never concatenated into a format string) and `struct SpotlightSearcher: FileSearching { init(home: URL, runQuery: @escaping @Sendable (NSPredicate, URL, Int) async -> [String] = SpotlightSearcher.runSpotlight) }`.

- [ ] **Step 1: Write the failing tests:** the predicate for each filter (name contains case/diacritic-insensitive, content-type tree for each `FileKind`, `kMDItemFSSize >=`, `kMDItemFSContentChangeDate >=`), text containing quotes, `*`, `\` and `%` stays a literal; an empty query gives nil and the searcher returns nothing without running a query; with a fake `runQuery` returning paths, results under `~/Library`, dot-folders, links, vanished files and files outside home are dropped, results are re-read with `lstat`, sorted newest first, capped at 500 with `isTruncated`; the real `runSpotlight` is NOT called by any test.
- [ ] **Step 2: Run** tests; expect failures.
- [ ] **Step 3: Implement** the predicate builder and `SpotlightSearcher`; `runSpotlight` runs an `NSMetadataQuery` on the main run loop (`searchScopes = [home]`, `sortDescriptors` newest change first), waits for `NSMetadataQueryDidFinishGathering`, stops the query, and honours cancellation. Note in the doc comment that it is exercised only by the manual check in `docs/STATUS.md`.
- [ ] **Step 4: Run** tests, lint, boundaries; green.
- [ ] **Step 5: Commit** `feat: Spotlight file search`.

### Task 4: Data: move files to the Trash, and the services

**Files:** Domain `FileTrashing` port, `FileTrashOutcome`, `FileRefusal` texts; Data `FileTrasher.swift`, `FilesServices.swift`; Test: `Tests/DataTests/FileTrasherTests.swift`, `FilesServicesTests.swift`.

**Interfaces:**
- Consumes: Tasks 1-3 types.
- Produces: `public struct FileTrashOutcome: Sendable, Equatable { public let moved: [FileItem]; public let failed: [FileFailure]; public var movedBytes: Int64 }` with `public struct FileFailure { public let file: FileItem; public let reason: String }`; `public protocol FileTrashing: Sendable { func moveToTrash(_ files: [FileItem]) async -> FileTrashOutcome; func moveDuplicatesToTrash(_ group: DuplicateGroup, remove: [FileItem]) async -> FileTrashOutcome }`; `public struct FilesServices: Sendable { public let search: any FileSearching; public let disk: any DiskScanning; public let duplicates: any DuplicateFinding; public let trasher: any FileTrashing; public init(home: URL = homeDirectoryForCurrentUser, runQuery: ..., trash: @escaping @Sendable (URL) throws -> Void = CleanupServices.moveToTrash, isProtected: ... ) }`.

- [ ] **Step 1: Write the failing tests** for each Review Focus line of this task plus: the fake trash moves into a temp folder and tests assert real moved paths; refusals (with readable reasons) for: not under home, under `~/Library` or a dot-folder, protected, a link, a folder or package, another volume, changed since scanned (identity, size or modified date), vanished; one failure does not stop the others; `moveDuplicatesToTrash` refuses when `remove` would leave no copy of the group, when a file to remove is not in the group, and when no kept copy still exists with the same size and identity, and calls the trash closure zero times in those cases; `movedBytes` counts only what moved.
- [ ] **Step 2: Run** tests; expect failures.
- [ ] **Step 3: Implement** `FileTrasher` with the re-check order of `CleanupMover` (resolved parent, `O_NOFOLLOW` open and identity, `fstatat` child, volume, protected, last `lstat`), adding the home-folder, `~/Library`/dot-folder and unchanged-since-scan checks. Default `isProtected` is `ProtectedPaths.isProtected`.
- [ ] **Step 4: Run** tests, lint, boundaries; `pgrep -f mainternance-runner-` empty; confirm no test touched the real Trash, home or `~/Library`.
- [ ] **Step 5: Commit** `feat: move files and duplicates to the Trash`.

### Task 5: Presentation: search, large files and treemap

**Files:** rewrite `FilesViewState.swift` (search, large files, treemap), `FilesView.swift`, `FileResultRow.swift`, `LargeFilesView.swift`, `DiskTreemapView.swift`, `FileSearch.swift` (criteria and `FileSearchQuery` mapping only), add `FilesText.swift`; Test: `Tests/PresentationTests/FilesViewStateTests.swift`, `FilesFakes.swift`; remove sample search/treemap data and their tests.

**Interfaces:**
- Consumes: Task 1-3 ports and types; the existing `TreemapLayout`.
- Produces: `@MainActor @Observable public final class FilesViewState { public init(search: any FileSearching, disk: any DiskScanning, duplicates: any DuplicateFinding, trasher: any FileTrashing, quickLook: @escaping @MainActor (String) -> Void, reveal: @escaping @MainActor (String) -> Void); var segment: FilesSegment; var criteria: FileSearchCriteria; public private(set) var searchResults: [FileItem]; var isSearching: Bool; var searchIsTruncated: Bool; public private(set) var diskResult: DiskScanResult?; var isScanningDisk: Bool; var scanProgress: Int; var breadcrumb: [DiskNode]; var currentNode: DiskNode; func drillInto(_ id: String); func goUp(); func jump(toDepth: Int); func searchChanged() async /* debounced */; func startDiskScan(); func cancelWork(); public func appear() async; func quickLook(_ file: FileItem); func reveal(_ file: FileItem) }`.

- [ ] **Step 1: Write the failing tests** with fakes: `searchChanged()` debounces (injectable sleep) and only the newest query's results show (gated fake); an inactive criteria clears results without querying; the criteria map to the right `FileSearchQuery` (the cutoff from an injectable clock); `appear()` starts nothing on the Search tab and starts the disk scan the first time Large files opens, never twice while running; progress updates `scanProgress`; a finished result fills `diskResult` and the drill-down uses `DiskNode` (breadcrumb, drill only into drillable children, goUp, jump clamp); `cancelWork()` cancels search and scan and a cancelled scan keeps the previous result; unreadable folders produce a visible note; `quickLook`/`reveal` call the injected closures with the file's real, uncleaned path (cleaning is for display only).
- [ ] **Step 2: Run** tests; expect failures.
- [ ] **Step 3: Implement** state and views: Search tab with the field, filters, a results list with Quick Look and Reveal buttons (the Trash button arrives in Task 6, hidden until then), the Spotlight note and truncation note; Large files tab with a Scan button, a progress line, the list (name, folder, size, date) and the treemap with breadcrumb; sample data and the Files sample badge removed for these two tabs (the Duplicates tab is hidden from the picker until Task 6).
- [ ] **Step 4: Run** tests, lint, boundaries.
- [ ] **Step 5: Commit** `feat: real file search, large files and treemap`.

### Task 6: Presentation: duplicates and moving to the Trash

**Files:** `FilesViewState.swift` (extend), `DuplicateGroupView.swift`, `FilesReviewSheet.swift`, `FileResultRow.swift` (Trash button), `KeepRule.swift` (adapt to `FileItem`); Test: extend `FilesViewStateTests.swift`, `KeepRuleTests` (replace the sample-based ones); delete `FilesSampleData.swift`, `SampleFile`, remaining sample types and `FilesSampleDataTests.swift`.

**Interfaces:**
- Consumes: Task 4 `FileTrashing`; Task 5 state.
- Produces: on `FilesViewState`: `public private(set) var duplicateGroups: [DuplicateGroup]; var isFindingDuplicates: Bool; var duplicatePhase: String?; var keepRule: KeepRule; func startDuplicateScan(); func selection(for group: DuplicateGroup) -> DuplicateSelection; var removableFiles: [FileItem]; var reclaimableBytes: Int64; var isReviewing: Bool; var isMoving: Bool; var lastOutcome: FileTrashOutcome?; func review(); func cancelReview(); func confirm() async; func requestTrash(_ file: FileItem)` (a single-file Trash from Search or Large files opens the same review sheet).

- [ ] **Step 1: Write the failing tests:** `DuplicateSelection` keeps exactly one file per group by each rule with deterministic ties and never offers all copies (also for groups of two with identical dates); groups stream in and a newer scan replaces an older one (generation guard); `review()` only when something is removable and nothing runs; nothing moves without `review()`; `confirm()` sends duplicates through `moveDuplicatesToTrash` per group and single files through `moveToTrash`, moved files leave every list, failed ones stay with their reason, a group left with one copy disappears; the result text counts only `movedBytes` and carries the clone note; changing `keepRule` while reviewing is ignored; leaving the screen cancels the scan.
- [ ] **Step 2: Run** tests; expect failures.
- [ ] **Step 3: Implement** the duplicates tab (Scan button, phase text, groups with the Keep/Would remove badge, keep-rule picker, "Review N files, frees about X"), the review sheet ("These files move to the Trash. Space comes back when you empty the Trash. Clones share disk space, so moving one may free less than shown."), the per-row Trash button, and the result card with one line per failure. Delete the remaining sample code and show the Duplicates tab.
- [ ] **Step 4: Run** tests, lint, boundaries.
- [ ] **Step 5: Commit** `feat: real duplicates and moving files to the Trash`.

### Task 7: Availability, wiring, docs

**Files:** `Domain/Health.swift`, `Home/HomeModel.swift`, `CompositionRoot.swift`, `MainternanceApp.swift`, `Window/WindowStates.swift`, `README.md`, `docs/STATUS.md`; update `NavigationTests`, `MappingsTests`, `SampleDataCopyTests`, `HomeModelTests`.

- [ ] **Step 1: Write the failing tests:** `.files.isAvailable` is true and `SidebarItem.visible` becomes Home, Cleanup, Files, Scanner, Startup, Uninstaller, Settings; no screen is a sample any more (`SampleDataCopy.isSample` false for all, and remove the sample badge/marker code and its tests if nothing uses it); `HomeModel.comingNextText` is removed or says nothing is pending (decide: drop the line from Home entirely and its test).
- [ ] **Step 2: Implement:** set `.files` available, build `FilesServices()` in `CompositionRoot`, wire `quickLook` (`NSWorkspace`-free: use a SwiftUI `quickLookPreview` binding or `QLPreviewPanel` in the App target) and `reveal` (`NSWorkspace.shared.activateFileViewerSelecting`), call `state.appear()`/`cancelWork()` when the screen appears/disappears (never at launch).
- [ ] **Step 3: Docs:** README ("What is live": the three parts, home folder only, what is excluded, Spotlight limits, clone note, Trash only) and STATUS (shipped list; flip the Uninstaller section from "Done on branch" to merged; no remaining plans; manual checks: real Spotlight search finds a known file, a real large-file scan and treemap on the home folder, a duplicates scan with a planted duplicate, Quick Look, Reveal, a real Trash move with Put Back, and the privacy prompts for Desktop/Documents/Downloads).
- [ ] **Step 4:** `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`, `scripts/build-app.sh` (no `--install`), `codesign --verify --deep --strict`; check `pgrep -f mainternance-runner-`.
- [ ] **Step 5: Commit** `feat: Files on the sidebar, wiring and docs`.
