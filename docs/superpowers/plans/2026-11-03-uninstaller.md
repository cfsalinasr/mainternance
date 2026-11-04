# Uninstaller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A real Uninstaller screen: list the apps in `/Applications` and `~/Applications`, find what each one left in the owner's `~/Library`, show it all for review, and move the chosen app and leftovers to the Trash (never a permanent delete).

**Architecture:** Domain gets uninstaller types and ports. Data implements them: an app lister, a leftover finder (exact matches on fixed `~/Library` folders) and a mover with the same re-check discipline as `CleanupMover`. Presentation replaces the sample `UninstallerViewState`/view with a real state, a review sheet and a result card; the App target wires it. Same layers, rules and review process as `docs/superpowers/plans/2026-11-03-cleanup.md`.

**Tech Stack:** Swift 6, Foundation (`FileManager`, `Bundle`/`Info.plist` reading), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-29-mainternance-design.md` ("Uninstaller: remove an app plus its leftovers, previewed first") plus the decisions below (the owner asked for the rest of the app to be built at the builder's discretion, and said "start" instead of answering questions).

## Decisions (builder's calls)

- **Apps listed:** direct children ending `.app` (real folders, not links) of `/Applications` and `~/Applications`. Not listed: apps whose bundle identifier starts with `com.apple.` (macOS's own), and the running Mainternance bundle. No deeper search (no `/Applications/Utilities`, no `/System/Applications`).
- **Name, identifier, version** come from the bundle's `Contents/Info.plist` (`CFBundleName` or `CFBundleDisplayName`, falling back to the folder name; `CFBundleIdentifier`; `CFBundleShortVersionString`). An unreadable or missing plist gives an app with the folder name and no identifier. Sizes are NOT measured for the list (listing stays fast); the selected app's size and its leftovers are measured when it is selected.
- **Leftovers**, only these `~/Library` folders, only direct children, matched by exact text, never by "contains":
  - by identifier `id` (strong match, ticked by default): `Application Support/<id>`, `Caches/<id>`, `Containers/<id>`, `Group Containers` entries named `<id>` or ending `.<id>`, `Preferences/<id>.plist`, `Saved Application State/<id>.savedState`, `HTTPStorages/<id>`, `WebKit/<id>`, `Cookies/<id>.binarycookies`, `Logs/<id>`;
  - by app name (weak match, NOT ticked by default, labelled "matched by name only"): `Application Support/<name>`, `Logs/<name>`, `Caches/<name>`, compared case-insensitively, skipped when the name has fewer than 4 characters;
  - launch agents (`LaunchAgents/<id>.plist` or starting `<id>.`): listed, NOT ticked by default, with the line "Starts something at login; switch it off in Startup first".
  An identifier that is empty, longer than 200 characters, or has anything outside letters, digits, `.`, `-` and `_` is treated as "no identifier" (no strong matches), so a hostile Info.plist can never build a path with `/` or `..`.
- **Order of the move:** the app first. If the app cannot be moved (it is running, macOS refuses, it changed), its leftovers are NOT moved, so an app is never left half-working. If the owner unticks the app, only the ticked leftovers move (an app and nothing else is allowed too).
- **Running apps:** an app that is running (by bundle identifier, through an injected check) is refused with "Quit it first". The screen says this up front.
- **Trash only:** `FileManager.trashItem` through an injected closure; `removeItem`, `unlink`, `rm` are forbidden. Space returns when the owner empties the Trash, and the screen says so. Apps in `/Applications` may need an administrator password to move; if macOS refuses, it is reported per item ("macOS could not move it to the Trash: ...") and nothing is retried or escalated.
- **Honest copy:** sizes are "about" (allocated bytes, no links followed, no crossing volumes, "at least" on unreadable parts); "freed" counts only what moved; leftovers are described as "found by name/identifier", never as "safe to remove" or "all traces".

## Global Constraints

- Layer rules: Domain imports only Foundation; Presentation never imports Data; only the App target wires Data; no file access or decision rules in views.
- No permanent deletion anywhere (the only exemption in the repo is `QuarantineRemoval`). Trash moves go through an injected closure so tests NEVER touch the real Trash, the real `~/Library` or the real `/Applications` (tests use a temp "home" and a temp "Applications" folder).
- Names and paths from disk are untrusted: shown through `DisplayText.clean`; never executed; never put in a shell command.
- Unknown is nil, never faked.
- `scripts/lint.sh` exit 0, `scripts/check-boundaries.sh`, `scripts/test.sh` green before every commit; commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; every commit builds. Float tolerances in tests.

## Review Focus

- A link named `Foo.app` in `/Applications`, or a leftover folder that is a link into `/System` or the home folder, is never followed for size or moved as its target. Pinned in Tasks 1 and 2.
- A hostile `CFBundleIdentifier` (`../../Documents`, `a/b`, empty, 5000 characters) builds no path outside the fixed folders. Pinned in Task 1.
- Two apps that share a name, or a short or generic name (`Go`, `Notes`), must not pull in each other's folders or drag in unrelated ones: name matches are unticked and exact. Pinned in Task 1.
- Something swapped between review and confirm (app replaced, leftover turned into a link, item vanished) is refused with a reason, and a failed app move skips its leftovers. Pinned in Task 2.
- Moving the running Mainternance bundle, a `com.apple.*` app, or the home folder itself is impossible, even when asked directly. Pinned in Task 2.
- Selecting apps quickly in a row must show the newest app's leftovers, never an older one's. Pinned in Task 3.

---

## File structure

- Domain (new): `Sources/MainternanceDomain/Uninstaller/UninstallerTypes.swift`, `UninstallerPorts.swift`.
- Data (new): `Sources/MainternanceData/Uninstaller/AppLister.swift`, `LeftoverFinder.swift`, `AppMover.swift`, `UninstallerServices.swift`. Reuse `ItemStat`, `CleanupRules.resolve`, `CleanupMeasurer.size(of:device:)`, `ProtectedPaths`, `DisplayText`; extract a shared helper only if `CleanupMover*Tests` stay green unchanged, otherwise duplicate the small check with a comment pointing at `CleanupMover`.
- Presentation: rewrite `Uninstaller/UninstallerViewState.swift`, `Uninstaller/UninstallerView.swift`, add `Uninstaller/UninstallerReviewSheet.swift`, `Uninstaller/UninstallerText.swift`; delete `SampleApp`, `Leftover` and `SampleLists.apps` from `Shared/SampleLists.swift` and their tests in `SampleListsTests.swift`.
- App: `CompositionRoot.swift`, `Window/WindowStates.swift` (init takes the real state), `MainternanceApp.swift`.
- Domain `Health.swift` (`.uninstaller` available), `HomeModel.comingNextText`, docs.

### Task 1: Domain and Data: list apps and find leftovers

**Files:** the Domain files and `AppLister.swift`, `LeftoverFinder.swift`; Test: `Tests/DomainTests/UninstallerTypesTests.swift`, `Tests/DataTests/AppListerTests.swift`, `LeftoverFinderTests.swift`, `UninstallerTestSupport.swift`.

**Interfaces (Produces):**
- `public struct InstalledApp: Sendable, Equatable, Identifiable { public let id: String /* absolute path of the .app */; public let name: String; public let bundleID: String?; public let version: String?; public let identity: CleanupEntry.Identity?; public var displayName: String }`
- `public enum LeftoverMatch: Sendable, Equatable { case identifier, nameOnly, launchAgent }` with `public var isSelectedByDefault: Bool` (true only for `.identifier`).
- `public struct Leftover: Sendable, Equatable, Identifiable { public let id: String /* absolute path */; public let name: String; public let location: String /* e.g. "Caches" */; public let match: LeftoverMatch; public let bytes: Int64; public let isLowerBound: Bool; public let type: CleanupEntry.ItemType; public let identity: CleanupEntry.Identity?; public var displayName: String }`
- `public struct AppDetails: Sendable, Equatable { public let app: InstalledApp; public let appBytes: Int64; public let appIsLowerBound: Bool; public let leftovers: [Leftover] }` (leftovers largest first).
- `public protocol AppListing: Sendable { func listApps() async -> [InstalledApp] }` (sorted by name, case-insensitive); `public protocol LeftoverFinding: Sendable { func details(for app: InstalledApp) async -> AppDetails }`.
- Data internals take `home: URL` and `applicationFolders: [URL]` so tests pass temp folders; `static func validIdentifier(_ text: String?) -> String?` in Data (internal, tested).

- [ ] **Step 1: Write the failing tests** for each Review Focus line of this task plus: a temp "Applications" with three `.app` folders (real `Info.plist` files written by the test) lists name, identifier, version, sorted; `com.apple.*` and the running bundle are not listed; non-`.app` entries, files named `.app` and links are skipped; a missing folder lists nothing; every leftover location in the Decisions list is found for an exact identifier and not for `com.example.app2` or `xcom.example.app` (but the Group Containers `.<id>` suffix rule matches `ABCDE12345.com.example.app`); name matches are `.nameOnly`, case-insensitive, absent for names under 4 characters; launch agents are `.launchAgent`; sizes within tolerance of written bytes (block-rounded: `>= written`, `< written + 1 MiB`); a leftover that is a link counts as the link itself (not followed); cancellation of `details` returns promptly with lower-bound sizes.
- [ ] **Step 2: Run** `scripts/test.sh`; expect failures.
- [ ] **Step 3: Implement** the types and the two Data types. Read `Info.plist` with `PropertyListSerialization` on a file of at most 1 MiB (bounded read), no `Bundle(path:)` (it can follow links); leftover finder reads each fixed folder's children once (no per-app guessing of paths with a name in them), reads each candidate with `ItemStat.read` (no link following), and sizes folders with `CleanupMeasurer.size(of:device:)`.
- [ ] **Step 4: Run** tests, lint, boundaries; green.
- [ ] **Step 5: Commit** `feat: list installed apps and find their leftovers`.

### Task 2: Data: move an app and its leftovers to the Trash

**Files:** `Domain/Uninstaller/UninstallerPorts.swift` (`AppUninstalling`, `UninstallOutcome`), `Data/Uninstaller/AppMover.swift`, `UninstallerServices.swift`; Test: `Tests/DataTests/AppMoverTests.swift`, `UninstallerServicesTests.swift`.

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `public struct UninstallOutcome: Sendable, Equatable { public let appMoved: Bool; public let appFailure: String?; public let movedLeftovers: [Leftover]; public let failedLeftovers: [LeftoverFailure]; public let skipped: [Leftover] /* not tried because the app did not move */; public var movedBytes: Int64 /* app bytes only when moved, plus moved leftovers */ }` with `public struct LeftoverFailure: Sendable, Equatable { public let leftover: Leftover; public let reason: String }`. `public protocol AppUninstalling: Sendable { func moveToTrash(app: InstalledApp, appBytes: Int64, leftovers: [Leftover], includeApp: Bool) async -> UninstallOutcome }`.
- `public struct UninstallerServices: Sendable { public let lister: any AppListing; public let finder: any LeftoverFinding; public let mover: any AppUninstalling; public init(home: URL = homeDirectoryForCurrentUser, applicationFolders: [URL] = [/Applications, ~/Applications], isRunning: @escaping @Sendable (String) -> Bool = UninstallerServices.isRunning, trash: @escaping @Sendable (URL) throws -> Void = CleanupServices.moveToTrash) }` where the default `isRunning` asks `NSRunningApplication.runningApplications(withBundleIdentifier:)`.

- [ ] **Step 1: Write the failing tests** for each Review Focus line of this task plus: the fake trash moves items into a temp folder and the tests assert the real moved paths; the app is moved first and its leftovers after; a refused app skips every leftover (`skipped`) and calls the trash closure zero times; `includeApp: false` moves only leftovers; a leftover is refused unless its parent resolves (links resolved) to exactly one of the fixed `~/Library` folders and its name is a plain name; the app is refused unless its parent resolves to one of the application folders and it ends `.app`; kind or identity changed since measuring → `.changed`; vanished → `.vanished`; another volume → `.otherVolume`; `ProtectedPaths.isProtected` (system, home itself, the running bundle) → `.protected`; `com.apple.*` identifier re-read from the plist at move time → refused; running (injected `isRunning` returns true) → "Quit it first"; a trash error on one leftover does not stop the rest and is not counted as moved; `movedBytes` counts only what moved.
- [ ] **Step 2: Run** tests; expect failures.
- [ ] **Step 3: Implement** `AppMover` with the same re-check order as the `CleanupMover` doc comment (parent resolved and allowed, parent opened with `O_NOFOLLOW | O_DIRECTORY` and same device/inode as when the move started, child read with `fstatat` no-follow and compared with the measured type and identity, same volume, not protected, last `lstat` identical right before the move), generalised to "allowed folders". Reasons reuse `CleanupRefusal.text`; add the "Quit it first" and "macOS apps are not removed" texts in Domain.
- [ ] **Step 4: Run** tests, lint, boundaries; `pgrep -f mainternance-runner-` empty; confirm no test touched the real Trash, `/Applications` or `~/Library`.
- [ ] **Step 5: Commit** `feat: move an app and its leftovers to the Trash`.

### Task 3: Presentation: the real Uninstaller screen

**Files:** rewrite `UninstallerViewState.swift`, `UninstallerView.swift`; create `UninstallerReviewSheet.swift`, `UninstallerText.swift`; modify `Shared/SampleLists.swift`, `Window/WindowStates.swift`; Test: `Tests/PresentationTests/UninstallerViewStateTests.swift` (replaces the sample-based tests), `UninstallerFakes.swift`.

**Interfaces:**
- Consumes: Task 1 and 2 ports and types.
- Produces: `@MainActor @Observable public final class UninstallerViewState { public init(lister: any AppListing, finder: any LeftoverFinding, mover: any AppUninstalling); public private(set) var apps: [InstalledApp]; public private(set) var details: AppDetails?; public private(set) var selectedID: String?; public private(set) var isListing: Bool; public private(set) var isLoadingDetails: Bool; public private(set) var isMoving: Bool; public private(set) var isReviewing: Bool; public private(set) var lastOutcome: UninstallOutcome?; public var searchText: String; var visibleApps: [InstalledApp]; public func appear() async; func select(_ id: String?) async; func toggleApp(); func toggleLeftover(_ id: String); func isSelected(leftover: String) -> Bool; var includesApp: Bool; var selectedLeftovers: [Leftover]; var selectedBytes: Int64; var canReview: Bool; func review(); func cancelReview(); func confirm() async }`.

- [ ] **Step 1: Write the failing tests** with fakes: `appear()` lists apps and selects nothing; `select` loads details, with the app and strong-match leftovers ticked and name-only and launch-agent leftovers unticked; quick successive selects keep only the newest app's details (gated fake, generation guard); an unknown id clears the selection; `searchText` filters `visibleApps` case-insensitively on name; `review()` only when the app or a leftover is ticked and nothing is loading or moving; nothing moves without `review()` first; `confirm()` passes exactly the ticked leftovers and `includeApp`; after a move the moved leftovers leave `details`, a moved app leaves `apps` and clears the selection, failures stay listed with their reasons; a refused app shows "not moved" and the leftovers listed as skipped; `appear()` while moving or reviewing is ignored; the result text counts only `movedBytes`.
- [ ] **Step 2: Run** tests; expect failures.
- [ ] **Step 3: Implement** state and views: a list (name, version) with a search field; a detail pane with the app card (size, "Quit it first" note when it may be running), leftovers grouped as "Found by identifier" and "Matched by name only — check these" with per-item checkboxes and about-sizes, the launch-agent warning line, a total, and a "Review…" button; the review sheet lists the app and every ticked leftover with "These items move to the Trash. Space comes back when you empty the Trash." and a Confirm button; a result card with moved count, about-size, and one line per failure. Remove the sample data and the sample badge for this screen; delete `SampleApp`, `Leftover`, `SampleLists.apps` and their tests.
- [ ] **Step 4: Run** tests, lint, boundaries.
- [ ] **Step 5: Commit** `feat: real Uninstaller screen`.

### Task 4: Availability, wiring, docs

**Files:** `Domain/Health.swift`, `Home/HomeModel.swift`, `CompositionRoot.swift`, `MainternanceApp.swift`, `README.md`, `docs/STATUS.md`; update `NavigationTests`, `MappingsTests`, `SampleDataCopyTests`, `HomeModelTests`.

- [ ] **Step 1: Write the failing tests:** `.uninstaller.isAvailable` is true and `SidebarItem.visible` becomes Home, Cleanup, Scanner, Startup, Uninstaller, Settings; `SampleDataCopy` marks only Files; `HomeModel.comingNextText == "Coming next: file explorer."`.
- [ ] **Step 2: Implement:** set `.uninstaller` available, update the Home text, build `UninstallerServices()` in `CompositionRoot`, pass the state through `Composition` and `WindowStates`, call `state.appear()` when the screen appears (never at launch).
- [ ] **Step 3: Docs:** README ("What is live": Uninstaller moves an app and its leftovers, found by exact identifier or name, to the Trash after review; never permanent; macOS's own apps are not listed; leftovers can be missed or over-matched, so the name-only ones are unticked) and STATUS (shipped list; remaining plans: File explorer only; update the stale "Done on branch" notes to "merged"; manual checks: uninstall a throwaway app on a real Mac with the app in `/Applications` and look in the Trash, including the administrator-password case, and that Put Back restores it).
- [ ] **Step 4:** `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`, `scripts/build-app.sh` (no `--install`), `codesign --verify --deep --strict`; check `pgrep -f mainternance-runner-`.
- [ ] **Step 5: Commit** `feat: Uninstaller on the sidebar, wiring and docs`.
