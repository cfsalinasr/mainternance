# Mainternance Foundation and UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a double-clickable `Mainternance.app` with the approved menu bar popover, Home screen and all other screens, built on clean-architecture modules and driven by mock data, with repo, CI, lint and review tooling in place.

**Architecture:** One Swift package with four targets: `MainternanceDomain` (pure logic, protocols), `MainternanceData` (implementations; here, mocks), `MainternancePresentation` (SwiftUI views and view models), `MainternanceApp` (executable, composition root). Dependencies point inward and a script enforces it. No Xcode: SwiftPM builds, a script assembles and signs the `.app`.

**Tech Stack:** Swift 6.4 (language mode 6), SwiftUI with macOS 26+ glass APIs, Swift Testing, SwiftLint, SwiftFormat, GitHub Actions, SonarCloud, CodeRabbit.

**Spec:** `docs/superpowers/specs/2026-10-29-mainternance-design.md`. Approved visual reference: `.superpowers/brainstorm/39641-1793299169/content/home-layout-v2-icons.html` (copy it to `docs/design/home-layout-v2-icons.html` in Task 1 so it is versioned).

**Out of scope for this plan** (separate plans, in this order): (2) real metrics, health and notification policy, launch at login and scheduling; (3) cleanup, startup items, uninstaller backends; (4) file explorer backend; (5) ClamAV scanner and quarantine. This plan touches no real system APIs except reading `ProcessInfo.isLowPowerModeEnabled`.

## Global Constraints

- Platform: `.macOS("26.0")` in `Package.swift` (string form; `.v26` is unavailable in the installed manifest API). Only Command Line Tools are installed: no `xcodebuild`, no XCTest.
- Tests use Swift Testing (`import Testing`). Locally it needs `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`; `scripts/test.sh` adds the flag only when that directory exists and `xcode-select -p` is the Command Line Tools path.
- Layer rules: `MainternanceDomain` imports only `Foundation`. `MainternancePresentation` imports `SwiftUI`, `Foundation`, `MainternanceDomain`, never `MainternanceData`. Only `MainternanceApp` imports `MainternanceData`.
- Health is three states (`good`, `needsAttention`, `problem`) with explicit reasons. No numeric score anywhere.
- Sampling: visible 2 s, hidden 45 s, doubled in Low Power Mode. Nothing ticks when nothing is visible and nothing is due.
- Glass (`glassEffect`, materials) only on chrome: popover, window sidebar, banner. Data areas use solid surfaces.
- Icons are SF Symbols. Colors: amber = needs attention, green = good, red = problem.
- Repo: public `cfsalinasr/mainternance`, default branch `main`. Commit messages end with the trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- `.superpowers/` is git-ignored. Mock data values are those in the approved mockup.

## Review Focus

- Disk total size of 0 or negative (division by zero): evaluator returns `needsAttention` "Disk size unavailable", never crashes. Pinned in Task 3.
- Never scanned (`lastScan == nil`): `needsAttention` "Never scanned". Pinned in Task 3.
- `lastScan` in the future (clock skew): treated as age 0, `good`. Pinned in Task 3.
- Optional metrics missing (`gpuUsage`, `temperatureCelsius`, `battery`, `healthPercent`): popover, Home and the menu bar label omit them without crashing or showing "0". Pinned in Tasks 3 and 6.
- Hidden window must stop polling: after `stop()` no further refreshes occur. Pinned in Task 6.

---

### Task 1: Package scaffold, tooling and boundary check

**Files:**
- Create: `Package.swift`, `.gitignore`, `.swiftlint.yml`, `.swiftformat`, `README.md`, `scripts/test.sh`, `scripts/check-boundaries.sh`, `docs/design/home-layout-v2-icons.html` (copy)
- Create (one placeholder source each): `Sources/MainternanceDomain/Domain.swift`, `Sources/MainternanceData/Data.swift`, `Sources/MainternancePresentation/Presentation.swift`, `Sources/MainternanceApp/main.swift`
- Create (one placeholder test each): `Tests/DomainTests/BoundaryTests.swift`, `Tests/PresentationTests/PresentationPlaceholderTests.swift`, `Tests/DataTests/DataPlaceholderTests.swift`

**Interfaces:**
- Produces: targets `MainternanceDomain`, `MainternanceData` (depends on Domain), `MainternancePresentation` (depends on Domain), executable `MainternanceApp` (product name `Mainternance`, depends on all three), test targets `DomainTests`, `DataTests`, `PresentationTests`. `scripts/test.sh [swift test args]` runs tests with the right flags. `scripts/check-boundaries.sh` exits non-zero on any layer violation.

- [ ] **Step 1: Install tools.** Run `brew install swiftlint swiftformat`. Expected: `swiftlint version` and `swiftformat --version` print versions.
- [ ] **Step 2: `git init -b main`; write `.gitignore`** (`.build/`, `.swiftpm/`, `.superpowers/`, `.DS_Store`, `*.app`, `dist/`).
- [ ] **Step 3: Write `Package.swift`** (tools-version 6.0) with the targets above. Swift 6 language mode already enforces strict concurrency; add no `swiftSettings` and no unsafe flags.
- [ ] **Step 4: Write `scripts/check-boundaries.sh`:** greps `Sources/MainternanceDomain` for any `import` other than `Foundation`, `Sources/MainternancePresentation` for `import MainternanceData`, and `Sources/MainternanceData` for `import SwiftUI`. Prints offending lines and exits 1; exits 0 otherwise.
- [ ] **Step 5: Write the failing test** `BoundaryTests.swift` in `DomainTests`: `@Test func layerBoundariesHold()` runs `scripts/check-boundaries.sh` through `Process` (path resolved from `#filePath`) and `#expect(process.terminationStatus == 0)`. Add a second test `boundaryScriptDetectsViolation` that runs the script against a temp directory tree containing `import SwiftUI` under a fake `MainternanceDomain` folder (script takes an optional root argument, default `.`) and expects status 1.
- [ ] **Step 6: Run `scripts/test.sh`.** Expected: FAIL (script missing or root argument unsupported) until Step 4 handles the optional root.
- [ ] **Step 7: Write `scripts/test.sh`** (adds the plugin flag per Global Constraints, forwards all args, `exec swift test "$@"`), make both scripts executable, write `.swiftlint.yml` (`strict` friendly, exclude `.build`) and `.swiftformat` (Swift 6, 4-space indent, `--maxwidth 120`), a short `README.md` (what it is, `scripts/test.sh`, `scripts/build-app.sh` coming in Task 12), and copy the mockup.
- [ ] **Step 8: Run `scripts/test.sh`, `swiftlint --strict`, `swiftformat --lint .`, `swift build`.** Expected: all pass.
- [ ] **Step 9: Commit** `chore: scaffold package, tooling and boundary check`.

### Task 2: Publish repo, CI, SonarCloud and CodeRabbit

**Files:**
- Create: `.github/workflows/ci.yml`, `sonar-project.properties`, `.coderabbit.yaml`
- Modify: `README.md` (badges and "Tooling" section)

**Interfaces:**
- Consumes: Task 1 scripts.
- Produces: GitHub repo `cfsalinasr/mainternance` with CI running lint, boundary check, build, test, Sonar scan.

- [ ] **Step 1: Resolve action SHAs.** For each of `actions/checkout` and `SonarSource/sonarqube-scan-action`, run `gh api repos/<owner>/<repo>/commits/<tag> --jq .sha` (tags `v4` and `v5`) and pin `uses:` to the full SHA with the tag in a trailing comment (CodeRabbit rule carried over from `spps-assistant`).
- [ ] **Step 2: Write `ci.yml`:** on push and PR to `main`; one job on `macos-latest`: checkout (`fetch-depth: 0`), `brew install swiftlint swiftformat`, `swiftlint --strict`, `swiftformat --lint .`, `scripts/check-boundaries.sh`, `scripts/test.sh --enable-code-coverage`, then the Sonar scan step with `SONAR_TOKEN` and `GITHUB_TOKEN` passed only to that step's `env`.
- [ ] **Step 3: Write `sonar-project.properties`:** `sonar.projectKey=cfsalinasr_mainternance`, `sonar.organization=cfsalinasr`, `sonar.sources=Sources`, `sonar.tests=Tests`, `sonar.exclusions=**/.build/**,**/*.app/**`, encoding UTF-8.
- [ ] **Step 4: Write `.coderabbit.yaml`** modeled on `/Users/cristiansalinas/Desktop/spps/spps-assistant/.coderabbit.yaml`: `profile: assertive`, `auto_review` on `main`, and `path_instructions` for `Sources/MainternanceDomain/**` (Foundation-only, no I/O), `Sources/MainternanceData/**` (implements Domain protocols; every deletion goes through the protected-paths guard, Trash only), `Sources/MainternancePresentation/**` (no import of Data; no business logic in views), `Sources/MainternanceApp/**` (only composition), `.github/workflows/**` (actions pinned to SHAs, secrets only in step env), `Tests/**` (no mocking of Domain logic).
- [ ] **Step 5: Push.** The public repo `cfsalinasr/mainternance` already exists and is empty, and the `SONAR_TOKEN` secret and the SonarCloud project `cfsalinasr_mainternance` (org `cfsalinasr`, Automatic Analysis disabled through the API on 2026-10-29) were set up by the controller. Run `git remote add origin https://github.com/cfsalinasr/mainternance.git && git push -u origin main`.
- [ ] **Step 6: Sonar guard.** Guard the Sonar step with `if: ${{ env.SONAR_TOKEN != '' }}` via a job-level env mapping of the secret, so a missing secret never fails the build. If the scan reports "You are running CI analysis while Automatic Analysis is enabled", tell the user: it must be turned off in SonarCloud (project, Administration, Analysis Method).
- [ ] **Step 6b: CodeRabbit.** CodeRabbit is a GitHub App and cannot be installed from the CLI. After the first pull request exists, check `gh api repos/cfsalinasr/mainternance/issues/<n>/comments --jq '.[].user.login'` for `coderabbitai[bot]`; if absent, tell the user to add `mainternance` to the CodeRabbit app's repository list (GitHub, Settings, Applications, CodeRabbit, Configure).
- [ ] **Step 7: Verify CI.** `gh run watch` on the first run. Expected: green. If SonarCloud cannot import Swift coverage, drop coverage reporting from CI and note it in the README rather than hacking a converter.
- [ ] **Step 8: Commit** `ci: add workflow, sonar and coderabbit config`; push.

### Task 3: Health model and evaluator (Domain)

**Files:**
- Create: `Sources/MainternanceDomain/Health.swift`, `Sources/MainternanceDomain/SystemSnapshot.swift`
- Delete: `Sources/MainternanceDomain/Domain.swift`
- Test: `Tests/DomainTests/HealthEvaluatorTests.swift`

**Interfaces:**
- Produces (all `public`, `Sendable`):
  - `enum HealthState: Int, Comparable { case good, needsAttention, problem }`
  - `enum CheckID: String, CaseIterable { case diskSpace, memoryPressure, thermal, batteryHealth, startupItems, lastScan, osUpdate, scannerFindings }`
  - `enum AppDestination: String { case home, cleanup, files, scanner, startup, uninstaller, settings }`
  - `enum MemoryPressure { case normal, warning, critical }`, `enum ThermalLevel { case nominal, fair, serious, critical }`
  - `struct BatterySnapshot: Equatable { var percent: Int; var isCharging: Bool; var healthPercent: Int?; var cycleCount: Int? }`
  - `struct SystemSnapshot: Equatable { var diskTotalBytes: Int64; var diskFreeBytes: Int64; var memoryPressure: MemoryPressure; var thermal: ThermalLevel; var cpuUsage: Double; var gpuUsage: Double?; var temperatureCelsius: Double?; var battery: BatterySnapshot?; var newStartupItemCount: Int; var osUpdateAvailable: Bool }`
  - `struct ScanStatus: Equatable { var lastScan: Date?; var nextScan: Date?; var unresolvedFindings: Int }`
  - `struct HealthCheck: Identifiable, Equatable { var id: CheckID; var state: HealthState; var title: String; var reason: String; var destination: AppDestination }`
  - `struct HealthReport: Equatable { var checks: [HealthCheck]; var overall: HealthState { get }; var attentionChecks: [HealthCheck] { get } }` (`overall` = max state, `.good` when empty; `attentionChecks` = non-good)
  - `struct HealthEvaluator { init(); func evaluate(snapshot: SystemSnapshot, scan: ScanStatus, now: Date) -> HealthReport }` — checks emitted in `CheckID.allCases` order; `batteryHealth` omitted when `battery == nil`.

Rules (my calls; the spec leaves thresholds to the builder):

| Check | needsAttention | problem | good reason |
|---|---|---|---|
| diskSpace | free < 15% of total, or total <= 0 | free < 5% | "41 GB free" style |
| memoryPressure | warning | critical | "Pressure normal" |
| thermal | serious | critical | "No throttling" |
| batteryHealth | healthPercent < 80 | never | "Health 91%" |
| startupItems | newStartupItemCount > 0 | never | "No new items" |
| lastScan | nil, or age > 10 days | age > 30 days | "N days ago" |
| osUpdate | available | never | "Up to date" |
| scannerFindings | never | unresolved > 0 | "No findings" |

Exact reasons pinned by tests: disk attention `"Disk 91% full"` (used percent rounded: 41 GB free of 460 GB); total <= 0 `"Disk size unavailable"`; never scanned `"Never scanned"`; startup `"3 new login items"` (singular `"1 new login item"`).

- [ ] **Step 1: Write failing tests** in `HealthEvaluatorTests.swift` using a `makeSnapshot(...)` helper with healthy defaults. Cover: all-healthy yields `overall == .good`; disk boundaries (15% exactly is `good`, just under is `needsAttention`, 5% exactly is `needsAttention`, just under is `problem`); the 41-of-460-GB case gives reason `"Disk 91% full"`; `diskTotalBytes == 0` and `< 0` give `needsAttention` with `"Disk size unavailable"` and no crash; memory and thermal mapping; battery nil omits the check, `healthPercent` 79 attention, 80 good, `healthPercent == nil` good; startup singular/plural; `lastScan == nil` gives `"Never scanned"` attention; scan 10 days old good, 11 days attention, 31 days problem; `lastScan` one day in the future is `good`; `unresolvedFindings == 2` problem; `overall` is the worst check; `attentionChecks` excludes good ones. Use a fixed `now`.
- [ ] **Step 2: Run `scripts/test.sh --filter HealthEvaluatorTests`.** Expected: FAIL (types undefined).
- [ ] **Step 3: Implement the types and `HealthEvaluator.evaluate`** per the Interfaces and rules table. Pure functions, no `Date()` calls inside.
- [ ] **Step 4: Run the filter again, then `scripts/test.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(domain): health model and evaluator`.

### Task 4: Overview use case, provider protocols and sampling policy (Domain)

**Files:**
- Create: `Sources/MainternanceDomain/Overview.swift`, `Sources/MainternanceDomain/SamplingPolicy.swift`
- Test: `Tests/DomainTests/LoadOverviewTests.swift`, `Tests/DomainTests/SamplingPolicyTests.swift`

**Interfaces:**
- Consumes: Task 3 types.
- Produces:
  - `protocol SystemSnapshotProviding: Sendable { func currentSnapshot() async -> SystemSnapshot }`
  - `protocol ScanStatusProviding: Sendable { func currentStatus() async -> ScanStatus }`
  - `protocol SuggestedActionsProviding: Sendable { func suggestedActions() async -> [SuggestedAction] }`
  - `struct SuggestedAction: Identifiable, Equatable { var id: String; var title: String; var detail: String; var symbol: String; var destination: AppDestination }`
  - `struct Overview: Equatable { var snapshot: SystemSnapshot; var scan: ScanStatus; var report: HealthReport; var actions: [SuggestedAction] }`
  - `struct LoadOverview: Sendable { init(snapshots: any SystemSnapshotProviding, scans: any ScanStatusProviding, actions: any SuggestedActionsProviding, evaluator: HealthEvaluator = .init(), now: @escaping @Sendable () -> Date = Date.init); func callAsFunction() async -> Overview }`
  - `struct SamplingPolicy: Sendable { init(visible: Duration = .seconds(2), hidden: Duration = .seconds(45)); func interval(isVisible: Bool, isLowPowerMode: Bool) -> Duration }`

- [ ] **Step 1: Write failing tests.** `LoadOverviewTests`: with fake providers returning a fixed snapshot, scan and one action, `LoadOverview()` returns an `Overview` whose `report` equals `HealthEvaluator().evaluate(...)` with the injected `now`, and whose `actions` are passed through unchanged. `SamplingPolicyTests`: `(visible, normal) == .seconds(2)`, `(hidden, normal) == .seconds(45)`, `(visible, lowPower) == .seconds(4)`, `(hidden, lowPower) == .seconds(90)`.
- [ ] **Step 2: Run both filters.** Expected: FAIL.
- [ ] **Step 3: Implement** the protocols, structs, `LoadOverview` (fetch the three providers concurrently with `async let`) and `SamplingPolicy` (low power doubles).
- [ ] **Step 4: Run `scripts/test.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(domain): overview use case, provider protocols, sampling policy`.

### Task 5: Mock providers (Data)

**Files:**
- Create: `Sources/MainternanceData/Mock/MockSystemSnapshotProvider.swift`, `MockScanStatusProvider.swift`, `MockSuggestedActionsProvider.swift`
- Delete: `Sources/MainternanceData/Data.swift`
- Test: `Tests/DataTests/MockProvidersTests.swift`

**Interfaces:**
- Consumes: Task 4 protocols.
- Produces: `MockSystemSnapshotProvider`, `MockScanStatusProvider(now: @Sendable () -> Date)`, `MockSuggestedActionsProvider`, each `public struct` with `public init`, conforming to the matching protocol.

Mock values (from the approved mockup): disk 460 GB total, 41 GB free (use decimal GB, `41_000_000_000` and `460_000_000_000`); memory `.normal`; thermal `.nominal`; cpu 0.23; gpu 0.08; temperature nil; battery 82%, charging, health 91, cycles 214; 3 new startup items; no OS update. Scan: last scan 3 days before `now`, next scan the coming Sunday 02:00, 0 findings. Actions: `"Clear 12 GB of junk"` / `"Caches, logs, old installers"` (symbol `sparkles`, `.cleanup`); `"Review 3 new login items"` / `"Added since last week"` (`power`, `.startup`); `"4 GB of duplicates found"` / `"Review before removing"` (`doc.on.doc`, `.files`).

- [ ] **Step 1: Write failing test:** the mock snapshot fed through `HealthEvaluator` yields `overall == .needsAttention` with exactly two non-good checks, `diskSpace` ("Disk 91% full") and `startupItems` ("3 new login items"), matching the mockup's "2 checks". The mock actions have three entries with the destinations above.
- [ ] **Step 2: Run `scripts/test.sh --filter MockProvidersTests`.** Expected: FAIL.
- [ ] **Step 3: Implement the three mock providers.**
- [ ] **Step 4: Run `scripts/test.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(data): mock providers matching approved mockup`.

### Task 6: View models and menu bar label (Presentation)

**Files:**
- Create: `Sources/MainternancePresentation/OverviewViewModel.swift`, `Sources/MainternancePresentation/MenuBarLabel.swift`
- Delete: `Sources/MainternancePresentation/Presentation.swift`
- Test: `Tests/PresentationTests/OverviewViewModelTests.swift`, `Tests/PresentationTests/MenuBarLabelTests.swift`

**Interfaces:**
- Consumes: `LoadOverview`, `Overview`, `SamplingPolicy`, `HealthState`.
- Produces:
  - `@MainActor @Observable public final class OverviewViewModel { public private(set) var overview: Overview?; public init(load: LoadOverview, policy: SamplingPolicy = .init(), isLowPowerMode: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }); public func setVisible(_ visible: Bool); public func start(); public func stop(); public func refresh() async }`
  - `public struct MenuBarLabel: Equatable { public var symbol: String; public var state: HealthState; public var text: String; public static func make(from overview: Overview?) -> MenuBarLabel }` — `symbol` is `"checkmark.shield"` for good and `"exclamationmark.shield"` otherwise; `text` is the free disk space formatted by `ByteCountFormatter` (`.decimal`, GB, e.g. `"41 GB"`); with `overview == nil` it is `symbol "shield"`, `state .good`, `text ""`.

- [ ] **Step 1: Write failing tests.** `MenuBarLabelTests`: nil overview gives the empty label; needs-attention overview gives `"exclamationmark.shield"`, `.needsAttention`, `"41 GB"`; a good overview gives `"checkmark.shield"`. `OverviewViewModelTests` (fake providers, a fake `sleep` that records requested durations and suspends on a continuation the test releases): `refresh()` sets `overview`; after `start()` with `setVisible(true)` the loop requests a 2 s sleep, with `setVisible(false)` a 45 s sleep, with low power true the visible interval is 4 s; changing visibility wakes the loop and triggers an immediate refresh; **after `stop()` no further `refresh` happens even when the fake sleep is released**; calling `start()` twice does not create two loops.
- [ ] **Step 2: Run the filters.** Expected: FAIL.
- [ ] **Step 3: Implement.** One structured `Task` loop owned by the view model (refresh, then sleep for `policy.interval(...)`, repeat), cancelled by `stop()`; `setVisible` cancels the current sleep so the new cadence applies.
- [ ] **Step 4: Run `scripts/test.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(presentation): overview view model and menu bar label`.

### Task 7: Design components, popover and menu bar item

**Files:**
- Create: `Sources/MainternancePresentation/Design/HealthStyle.swift`, `Design/GlassPanel.swift`, `Design/MetricColumn.swift`, `Design/InfoRow.swift`, `Popover/PopoverView.swift`
- Create: `Sources/MainternanceApp/MainternanceApp.swift` (replaces `main.swift`), `Sources/MainternanceApp/CompositionRoot.swift`
- Test: `Tests/PresentationTests/HealthStyleTests.swift`

**Interfaces:**
- Consumes: Task 6.
- Produces: `extension HealthState { var color: Color; var title: String }` (`"Good"`, `"Needs attention"`, `"Problem"`; green, amber, red); `GlassPanel<Content: View>` (applies `glassEffect` directly; no availability check is needed with the 26.0 floor); `MetricColumn(title:symbol:value:state:)`, `InfoRow(title:value:symbol:state:)`; `PopoverView(viewModel: OverviewViewModel, openWindow: () -> Void, scanNow: () -> Void)`; `CompositionRoot.makeOverviewViewModel() -> OverviewViewModel` wiring the three mock providers.

Popover content, top to bottom, as in the approved mockup: hero (`"This Mac"`, big state title in the state color, shield symbol and `"N checks"` on the right, hidden when good); divider; four `MetricColumn`s (CPU `"23%"`, Memory `"Green"`/`"Amber"`/`"Red"`, Thermal, Battery percent; battery column omitted when `battery == nil`); divider; `InfoRow`s for Disk free, Battery health (omitted when nil), Last scan (`"Never"` when nil), Next scan; divider; `Scan now`; `Open Mainternance`. The app scene is a `MenuBarExtra` with `.menuBarExtraStyle(.window)` whose label is the `MenuBarLabel` symbol tinted by state plus its text. `PopoverView` calls `setVisible(true)` on appear and `setVisible(false)` on disappear.

- [ ] **Step 1: Write failing test** `HealthStyleTests`: `title` values for the three states.
- [ ] **Step 2: Run `scripts/test.sh --filter HealthStyleTests`.** Expected: FAIL.
- [ ] **Step 3: Implement `HealthStyle` and the components.**
- [ ] **Step 4: Implement `PopoverView`, `CompositionRoot` and the `MenuBarExtra` scene** (call `viewModel.start()` at launch).
- [ ] **Step 5: Run `swift build && scripts/test.sh`.** Expected: PASS.
- [ ] **Step 6: Visual check.** Run `.build/debug/Mainternance` and confirm the menu bar shows the amber shield and `41 GB`, and the popover matches the mockup. Compare against `docs/design/home-layout-v2-icons.html`; record any deviation in the commit message.
- [ ] **Step 7: Commit** `feat(ui): design components, popover and menu bar item`.

### Task 8: Main window shell and Home screen

**Files:**
- Create: `Sources/MainternancePresentation/Window/MainWindowView.swift`, `Window/SidebarView.swift`, `Home/HomeView.swift`, `Home/HealthBanner.swift`, `Home/MetricTile.swift`, `Home/SuggestedActionsCard.swift`, `Home/ScanSummaryCard.swift`, `Home/DetailsDisclosure.swift`, `Navigation.swift`
- Modify: `Sources/MainternanceApp/MainternanceApp.swift` (add the window scene; wire `openWindow` and navigation)
- Test: `Tests/PresentationTests/NavigationTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable public final class Navigation { public var selection: AppDestination; public func open(_ destination: AppDestination) }`; `MainWindowView(navigation:overview:)`; `HomeView(viewModel:navigation:)`. Sidebar order and symbols: Home `house`, Cleanup `sparkles`, Files `magnifyingglass`, Scanner `shield`, Startup `power`, Uninstaller `trash`, Settings `gearshape`. Tapping a `HealthCheck` reason, a `SuggestedAction` or a tile calls `navigation.open(destination)`.

Home layout as approved: `HealthBanner` (state color tint, reasons joined with `" · "`, `Scan now` button), four `MetricTile`s (Disk free, Memory, Thermal, Battery with `"health 91% · 214 cycles"`; battery tile omitted when nil), `SuggestedActionsCard`, `ScanSummaryCard` (`"Last scan 3 days ago, clean"` and `"Next: Sun 02:00"`), and a collapsed `DetailsDisclosure` containing CPU, GPU and RAM sparklines (GPU and temperature rows omitted when nil). Sparkline history keeps the last 30 samples in the view model only while the window is visible.

- [ ] **Step 1: Write failing test** `NavigationTests`: default selection is `.home`; `open(.files)` sets selection; `open` of the current destination is a no-op.
- [ ] **Step 2: Run `scripts/test.sh --filter NavigationTests`.** Expected: FAIL.
- [ ] **Step 3: Implement `Navigation`, the window scene (`Window("Mainternance", id: "main")` with `NavigationSplitView`) and all Home components.** The sidebar uses system glass; the detail area uses solid surfaces.
- [ ] **Step 4: Wire `Open Mainternance` and notification-style deep links** (a banner reason tap) to `openWindow(id: "main")` and `navigation.open`.
- [ ] **Step 5: Run `swift build && scripts/test.sh`.** Expected: PASS.
- [ ] **Step 6: Visual check** against the mockup as in Task 7; verify the window and popover share one `OverviewViewModel` and that closing the window calls `setVisible(false)`.
- [ ] **Step 7: Commit** `feat(ui): main window and Home screen`.

### Task 9: Files screen UI (search, duplicates, large files)

**Files:**
- Create: `Sources/MainternancePresentation/Files/FilesView.swift`, `Files/FileSearchBar.swift`, `Files/FileResultRow.swift`, `Files/DuplicateGroupView.swift`, `Files/LargeFilesView.swift`, `Files/DiskTreemapView.swift`, `Files/FilesSampleData.swift`
- Test: `Tests/PresentationTests/FilesSampleDataTests.swift`

**Interfaces:**
- Produces: `FilesView(navigation:)` with a segmented control `Search | Duplicates | Large files`; a search field with type, size and date filter menus; result rows (icon, name, path, size, modified date) with Quick Look, Reveal in Finder and Move to Trash buttons that are present but disabled with help text `"Available when the file engine is connected"`; `DuplicateGroupView` showing a group with a `Keep: newest | oldest | shortest path` picker; `DiskTreemapView` drawn with `Canvas` from sample data, drill-down by tap. `FilesSampleData` holds the `struct`s and `static let` samples (marked `// Replaced by Domain providers in the file-explorer plan`).

- [ ] **Step 1: Write failing test:** sample data is non-empty, every duplicate group has at least two files with equal sizes, and `largest` is sorted descending by size.
- [ ] **Step 2: Run `scripts/test.sh --filter FilesSampleDataTests`.** Expected: FAIL.
- [ ] **Step 3: Implement the sample data and the views.** Filtering the sample list by the search text must work live so the interaction can be judged. Solid surfaces for data areas.
- [ ] **Step 4: Run `swift build && scripts/test.sh`.** Expected: PASS.
- [ ] **Step 5: Visual check** of all three segments, including the treemap drill-down.
- [ ] **Step 6: Commit** `feat(ui): files screen with mock data`.

### Task 10: Scanner screen UI

**Files:**
- Create: `Sources/MainternancePresentation/Scanner/ScannerView.swift`, `Scanner/EngineStatusCard.swift`, `Scanner/ScanProgressCard.swift`, `Scanner/FindingsList.swift`, `Scanner/ScannerSampleState.swift`
- Test: `Tests/PresentationTests/ScannerStateTests.swift`

**Interfaces:**
- Produces: `enum ScannerEngineState: Equatable { case notInstalled, installing(progress: Double), downloadingDefinitions(progress: Double), ready(definitionsAge: Duration), updateNeeded }` and `enum ScanRunState: Equatable { case idle, running(scanned: Int, current: String), finished(findings: Int) }`, each with a `title`/`detail` presentation used by `EngineStatusCard`; `ScannerView` renders the engine card (notInstalled shows an **Install** button, installing and downloading show a progress bar, ready shows green), scan buttons (`Quick scan`, `Full scan`, disabled unless `ready`), a progress card, a findings list with a `Quarantine` action that asks for confirmation first (never automatic), and a schedule line (`"Weekly, Sunday 02:00"`). A debug-only picker (`#if DEBUG`) cycles the sample states so every state can be reviewed.

- [ ] **Step 1: Write failing test:** `title` for each engine state (`"Scanning engine not installed"`, `"Installing…"`, `"Downloading definitions…"`, `"Engine ready"`, `"Definitions out of date"`), and that scan buttons are enabled only when `ready`.
- [ ] **Step 2: Run `scripts/test.sh --filter ScannerStateTests`.** Expected: FAIL.
- [ ] **Step 3: Implement the states and views.**
- [ ] **Step 4: Run `swift build && scripts/test.sh`.** Expected: PASS.
- [ ] **Step 5: Visual check** of every engine and run state via the debug picker.
- [ ] **Step 6: Commit** `feat(ui): scanner screen with sample states`.

### Task 11: Cleanup, Startup, Uninstaller and Settings screens

**Files:**
- Create: `Sources/MainternancePresentation/Cleanup/CleanupView.swift`, `Startup/StartupView.swift`, `Uninstaller/UninstallerView.swift`, `Settings/SettingsView.swift`, `Shared/PreviewListRow.swift`, `Shared/SampleLists.swift`
- Test: `Tests/PresentationTests/SampleListsTests.swift`

**Interfaces:**
- Produces: `CleanupView` (categories with checkboxes and sizes: Caches, Logs, Temp files, Old installers, Xcode and developer caches; a total; a `Review` then `Move to Trash` flow with a confirmation sheet listing what will move); `StartupView` (login items, launch agents, launch daemons with a toggle each and a `New` badge); `UninstallerView` (app list with a detail pane listing leftovers and total size, preview first); `SettingsView` (Launch at login toggle, scan schedule day and time pickers, notification toggles for Problem alerts and the weekly digest, polling note). All toggles bind to local `@State` only in this plan; actions are present but inert, with the same help text as Task 9. `SampleLists` holds the sample rows.

- [ ] **Step 1: Write failing test:** sample cleanup total equals the sum of its categories and matches the `"12 GB"` of the Home action (within rounding to the nearest GB); startup sample contains exactly 3 items flagged new; every sample app row lists at least one leftover.
- [ ] **Step 2: Run `scripts/test.sh --filter SampleListsTests`.** Expected: FAIL.
- [ ] **Step 3: Implement the sample data and the four screens.**
- [ ] **Step 4: Run `swift build && scripts/test.sh`.** Expected: PASS.
- [ ] **Step 5: Visual check** of all four screens and the cleanup confirmation sheet.
- [ ] **Step 6: Commit** `feat(ui): cleanup, startup, uninstaller and settings screens`.

### Task 12: Build, sign and install the .app

**Files:**
- Create: `scripts/build-app.sh`, `scripts/make-signing-cert.sh`, `Resources/Info.plist.template`, `Resources/AppIcon.iconset/` (generated by script), `scripts/make-icon.sh`
- Modify: `README.md` (install and permissions section)

**Interfaces:**
- Produces: `scripts/build-app.sh [--install]` creates `dist/Mainternance.app` from `swift build -c release`, signs it, and with `--install` copies it to `/Applications`. Bundle id `com.cfsalinasr.mainternance`; `LSUIElement` true (menu bar app, no Dock icon; my call, revisit if the window feels hard to reach); `LSMinimumSystemVersion` 26.0; `NSHumanReadableCopyright`. `scripts/make-signing-cert.sh` creates a self-signed code-signing certificate named `Mainternance Local Signing` in the login keychain (one-time; macOS will ask for the user's password). `build-app.sh` signs with that identity when present and falls back to ad-hoc (`codesign -s -`) with a printed warning that Full Disk Access may reset after rebuilds.

- [ ] **Step 1: Write `scripts/make-icon.sh`** producing a simple shield-on-gradient `AppIcon.icns` with `sips` and `iconutil` from a generated PNG (no Xcode asset catalog).
- [ ] **Step 2: Write `Info.plist.template` and `build-app.sh`:** release build, assemble `Contents/MacOS`, `Contents/Resources`, `Contents/Info.plist`, sign, then `codesign --verify --deep --strict`.
- [ ] **Step 3: Write `make-signing-cert.sh`** (openssl key and cert with `extendedKeyUsage=codeSigning`, import to the login keychain, trust for code signing). It must be idempotent and print what it did.
- [ ] **Step 4: Run `scripts/build-app.sh`.** Expected: `dist/Mainternance.app` exists and `codesign --verify --deep --strict dist/Mainternance.app` exits 0.
- [ ] **Step 5: Smoke test.** `open dist/Mainternance.app`, confirm with `pgrep -x Mainternance` that it is running and the menu bar item appears; then quit it.
- [ ] **Step 6: Ask the user to run `! scripts/make-signing-cert.sh`** (needs their password), rebuild with `--install`, and confirm the app launches from `/Applications`. Report plainly if the signing identity or install step was skipped.
- [ ] **Step 7: Update `README.md`** with the install steps and the note that Full Disk Access is granted later, in the scanner plan.
- [ ] **Step 8: Commit** `feat: build, sign and install script`; push and confirm CI is green.

---

## Self-review notes

- **Spec coverage:** menu bar item, popover, attention-first Home, all seven window screens, glass-on-chrome rule, health model with reasons and thresholds, performance cadence and Low Power Mode, repo, lint, tests, CI, Sonar, CodeRabbit, `.app` packaging and signing are covered. Deferred to later plans by design: real metrics and notification policy, launch at login, scheduling, cleanup, files, startup and uninstaller backends, ClamAV, quarantine, Full Disk Access.
- **Calls made here, not in the spec:** the health thresholds table; `LSUIElement` true; deployment floor 26.0 (lowest with the glass APIs); lint tools installed with Homebrew; Sonar coverage dropped if Swift import is not viable.
