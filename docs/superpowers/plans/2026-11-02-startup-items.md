# Startup Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A real Startup screen: list the launch agents and daemons that start things on this Mac, flag new ones since the owner last reviewed, let the owner turn user-level ones off and on (reversibly), and show the real "new startup items" count on Home.

**Architecture:** Domain gets `StartupItem` and ports (`StartupListing`, `StartupControlling`, `StartupReviewing`). Data implements them: a reader of launchd property lists, a reader of `launchctl print-disabled`, a controller using `launchctl enable/disable`, and a small review store. Presentation replaces the sample `StartupViewState` with a real one; the App target wires it. Same layers, rules and review process as `docs/superpowers/plans/2026-10-29-scanner-engine.md` and `2026-11-02-schedule-notifications-settings.md`.

**Tech Stack:** Swift 6, Foundation (`PropertyListSerialization`, `FileManager`), the existing `ProcessRunning` port for `launchctl`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-29-mainternance-design.md` (Startup), plus the decisions below (the owner asked for the rest of the app to be built at the builder's discretion).

## Decisions (builder's calls)

- Sources listed: `~/Library/LaunchAgents` (user agents), `/Library/LaunchAgents` (system agents), `/Library/LaunchDaemons` (system daemons). Only `.plist` files, read-only parsing; an unreadable or malformed plist becomes a row marked "could not be read" (never dropped silently).
- Only USER agents can be switched: `launchctl disable gui/<uid>/<label>` / `enable` (reversible, no admin, nothing deleted). It takes effect at the next login and the screen says so. System agents and daemons are read-only with "Needs an administrator: change it in the app that installed it" and a Reveal in Finder button.
- Enabled/disabled comes from `launchctl print-disabled gui/<uid>` (user) and `launchctl print-disabled system` (system); a label with no entry is enabled; if the command fails the state is unknown (nil, shown as "Unknown"), never guessed.
- Login items added in System Settings (Background Items) cannot be listed by an app: the screen says exactly that.
- "New" means: not present at the owner's last review. The first time the screen is ever opened establishes the baseline silently (nothing is "new" yet, and the screen says "Showing a baseline from today"). A "Mark all as reviewed" button updates the baseline. The Home count is the number of new items; unknown (nil) until the first baseline exists.
- Nothing is deleted or moved. No `sudo`, no shell: `launchctl` runs through the process runner with an argument array and a validated label.

## Global Constraints

- Layer rules: Domain imports only Foundation; Presentation never imports Data; only the App target wires Data. No decision rules or file/system access in views.
- Labels and paths from plists are untrusted input: a label is validated (non-empty, no `/`, no leading `-`, no control characters, length <= 255) before it is ever passed to `launchctl`; paths are shown, never executed.
- Unknown is nil/"Unknown", never faked. Honest copy: no "safe/suspicious" judgement; say what is registered and by which file.
- `scripts/lint.sh` exit 0, `scripts/check-boundaries.sh`, `scripts/test.sh` green before every commit; commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; every commit builds. Tests never touch the real `~/Library`, `/Library` or the real launchd (fake runner, temp folders). Float tolerances in tests.

## Review Focus

- A label such as `--version`, `../x`, `a/b`, one with a newline, or 300 characters must never reach `launchctl`. Pinned in Task 1.
- A plist that is binary, empty, huge, malformed, or lacks `Label`/`Program`/`ProgramArguments` must produce a row or a clear "could not be read" row, never a crash or a dropped item. Pinned in Task 1.
- `launchctl` missing, failing or printing unexpected text must give "Unknown", not "enabled". Pinned in Task 1.
- A toggle that fails (non-zero exit) must leave the displayed state unchanged and show the reason. Pinned in Task 2.
- The review baseline file damaged or unreadable: items are NOT all shown as new (that would cry wolf), and the file is not overwritten before it is moved aside (same rule as the preferences store: no deletion, Trash only, protected-paths guard). Pinned in Task 1.
- Symlinked plists and plists listed twice (same label in two folders) must appear once per file, with the duplicate label noted. Pinned in Task 1.

---

## File structure

- Domain (new): `Sources/MainternanceDomain/Startup/StartupItem.swift`, `StartupPorts.swift`.
- Data (new): `Sources/MainternanceData/Startup/LaunchItemReader.swift`, `LaunchctlStateReader.swift`, `LaunchctlController.swift`, `StartupReviewStore.swift`, `StartupServices.swift`.
- Presentation: rewrite `Startup/StartupViewState.swift`, `Startup/StartupView.swift`; delete the sample `StartupItem`/`StartupKind` from `Shared/SampleLists.swift`; modify `Window/WindowStates.swift`, `Design/SampleDataBadge.swift`; `AppDestination.startup.isAvailable` becomes true in `Domain/Health.swift` together with the Home wiring.
- App: `CompositionRoot.swift`, `MainternanceApp.swift`.
- Docs: `README.md`, `docs/STATUS.md`.

### Task 1: Domain and Data: list, state, control, review

**Files:** the Domain and Data files above; Test: `Tests/DomainTests/StartupItemTests.swift`, `Tests/DataTests/LaunchItemReaderTests.swift`, `LaunchctlStateReaderTests.swift`, `LaunchctlControllerTests.swift`, `StartupReviewStoreTests.swift`.

**Interfaces (Produces):**
- `public enum StartupKind: Sendable, CaseIterable { case userAgent, systemAgent, systemDaemon }`
- `public struct StartupItem: Sendable, Equatable, Identifiable { public let id: String /* plist path */; public let label: String?; public let name: String; public let kind: StartupKind; public let plistPath: String; public let program: String?; public let runsAtLoad: Bool?; public var isEnabled: Bool?; public var isNew: Bool; public let readProblem: String?; public var canToggle: Bool /* userAgent, valid label, no readProblem */ }` and `public static func isValidLabel(_ s: String) -> Bool`.
- `public struct StartupSnapshot: Sendable, Equatable { public var items: [StartupItem]; public var baselineEstablished: Bool; public var newCount: Int? /* nil until baseline */; public var duplicateLabels: Set<String> }`
- `public protocol StartupListing: Sendable { func list() async -> StartupSnapshot }`; `public protocol StartupControlling: Sendable { func setEnabled(_ item: StartupItem, _ enabled: Bool) async throws }` throwing `StartupError` (`.notAllowed`, `.invalidLabel`, `.failed(String)`); `public protocol StartupReviewing: Sendable { func markReviewed(_ labels: [String]) async }`.
- Data: `public struct StartupServices: Sendable { public let lister: any StartupListing; public let controller: any StartupControlling; public let reviewer: any StartupReviewing; public init(runner: any ProcessRunning, directory: URL, uid: uid_t = getuid(), home: URL = homeDirectoryForCurrentUser) }`.

- [ ] **Step 1: Write the failing tests** for each Review Focus line above plus: a valid user-agent plist (Label, ProgramArguments, RunAtLoad) becomes a row with name from the label's last component and `program` = first argument; `Program` key wins over `ProgramArguments`; a `print-disabled` sample output (as printed by this Mac: lines `"label" => disabled|enabled` inside `disabled services = { ... }`) maps to `isEnabled`; no entry means enabled; command failure gives nil; the controller runs exactly `[launchctl, disable, gui/<uid>/<label>]` or `enable` through the fake runner, refuses non-user items with `.notAllowed`, and surfaces a non-zero exit as `.failed(<last stderr line>)`; the first `list()` with no baseline file sets `baselineEstablished` false and `newCount` nil and writes the baseline of current labels (path-based id when a plist has no label) only after being asked via `markReviewed` or first listing, per the Decisions (first listing establishes it silently); a later new plist is `isNew`; `markReviewed` clears it.
- [ ] **Step 2: Run** `scripts/test.sh`; expect failures.
- [ ] **Step 3: Implement** the types. The reader skips nothing silently, reads with `PropertyListSerialization` (limit size to 1 MB, larger or non-dictionary becomes a `readProblem` row), does not follow symlinks out of the three folders for reading metadata beyond the plist itself, and sorts by kind then name. The state reader and controller use `ProcessRunning` (see `Sources/MainternanceData/Scanner/ProcessRunning.swift`) with absolute `/bin/launchctl`. The review store is JSON in the given directory (`startup-review.json`), 0600, atomic; a damaged file is moved aside with the same rules as `PreferencesStore` (read errors leave it alone and write nothing; copies bounded; trash only; protected-paths guard; strict names) and while blocked `newCount` is nil.
- [ ] **Step 4: Run** tests, lint, boundaries; green; `pgrep -f mainternance-runner-` empty.
- [ ] **Step 5: Commit** `feat: startup items reader, launchctl state and control, review baseline`.

### Task 2: Presentation: the real Startup screen

**Files:** modify `Startup/StartupViewState.swift`, `Startup/StartupView.swift`, `Window/WindowStates.swift`, `Design/SampleDataBadge.swift`, `Shared/SampleLists.swift`; Test: `Tests/PresentationTests/StartupViewStateTests.swift` (replaces the sample-based tests).

**Interfaces:**
- Consumes: Task 1 ports and types.
- Produces: `@MainActor @Observable public final class StartupViewState { public init(lister: any StartupListing, controller: any StartupControlling, reviewer: any StartupReviewing, reveal: @escaping @MainActor (String) -> Void); public private(set) var snapshot: StartupSnapshot?; public private(set) var busyIDs: Set<String>; public private(set) var message: String?; func refresh() async; func setEnabled(_ id: String, _ on: Bool) async; func markAllReviewed() async; func reveal(_ id: String); func items(of: StartupKind) -> [StartupItem]; var baselineNote: String?; var isLoading: Bool }`.

- [ ] **Step 1: Write the failing tests** with fakes: refresh fills the snapshot; toggling a user agent calls the controller, then re-reads state, and shows "Takes effect at your next login"; a controller failure leaves the item's displayed state unchanged and sets the readable message; a system item cannot be toggled (`canToggle` false, `setEnabled` ignored with a message); `markAllReviewed` calls the reviewer with every label/id and refreshes (new badges disappear); first-ever listing shows `baselineNote` "Showing a baseline from today: nothing counts as new yet"; empty folders show an empty state; unknown enabled state shows "Unknown"; `reveal(id)` calls the closure with the plist path only for ids in the snapshot.
- [ ] **Step 2: Run** tests; expect failures.
- [ ] **Step 3: Implement** state and view: sections per kind with plain titles ("Your login items and agents", "Agents for all users", "System daemons"), each row: name, label + program path, On/Off/Unknown text, "New" badge (text, not color alone), Reveal in Finder, a switch only for toggleable rows; a footer: "Login items you added in System Settings > General > Login Items are managed by macOS and are not listed here." and a "Mark all as reviewed" button. Remove the sample items, the `SampleDataBadge` for Startup and the sample `StartupItem`/`StartupKind` from `SampleLists.swift` (update its tests).
- [ ] **Step 4: Run** tests, lint, boundaries.
- [ ] **Step 5: Commit** `feat: real Startup screen`.

### Task 3: Home count, availability, wiring, docs

**Files:** modify `Domain/Health.swift` (`.startup` becomes available), the live snapshot provider that supplies `newStartupItemCount` (find it under `Sources/MainternanceData/Live/`), `CompositionRoot.swift`, `MainternanceApp.swift`, `README.md`, `docs/STATUS.md`; tests for the provider count.

- [ ] **Step 1: Write the failing tests:** the snapshot provider reports `newStartupItemCount` from the startup lister (nil when the baseline is not established or the lister cannot say, so Home says unknown rather than 0), and the Home health check for startup items follows the real count (amber when > 0 new items, with the reason naming the count and linking to Startup).
- [ ] **Step 2:** implement the provider change, wire `StartupServices` in `CompositionRoot` (directory: Application Support/Mainternance), refresh the Startup state when the screen appears, set `.startup` available, update the README (what is live: Startup lists agents and daemons, only user agents can be switched, takes effect at next login, login items from System Settings are not listed) and STATUS (remaining plans: cleanup, uninstaller, file explorer).
- [ ] **Step 3:** `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`, `scripts/build-app.sh` (no `--install`), `codesign --verify --deep --strict`; check `pgrep -f mainternance-runner-`.
- [ ] **Step 4: Commit** `feat: startup items on Home, wiring and docs`.
