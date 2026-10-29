# Live Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mock providers behind the menu bar popover and Home screen with real, live readings of this Mac (disk, memory pressure, thermal state, battery, CPU, GPU), and make everything that is still sample data say so.

**Architecture:** Real providers live in `MainternanceData` behind the existing Domain protocols (`SystemSnapshotProviding`, `ScanStatusProviding`, `SuggestedActionsProviding`). Each reading is a tiny wrapper over a public macOS API plus a PURE mapping function that is unit-tested with fixtures; a `LiveSystemSnapshotProvider` assembles them. Unknown data is `nil` and the UI omits it; it is never faked. Screens whose engines do not exist yet (Files, Scanner, Cleanup, Startup, Uninstaller) get a visible "Sample data" badge.

**Tech Stack:** Swift 6, Foundation (`URLResourceKey`, `ProcessInfo`, `sysctlbyname`), IOKit (`IOPSCopyPowerSourcesInfo`, `AppleSmartBattery` registry entry, `IOAccelerator` `PerformanceStatistics`), Mach (`host_statistics`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-29-mainternance-design.md` (Health model, Performance rules). Previous plan: `docs/superpowers/plans/2026-10-29-foundation-and-ui.md` (read its Global Constraints).

## Verified facts about this Mac (probe run 2026-10-29)

- Disk free "for important usage" = 278.3 GB of 494.3 GB total (matches System Settings; plain `volumeAvailableCapacity` says 232.1 GB and `df` says 216 GB; USE `volumeAvailableCapacityForImportantUsageKey`, because it is the figure the user sees in System Settings).
- `sysctl kern.memorystatus_vm_pressure_level` = 1 (1 normal, 2 warning, 4 critical).
- `ProcessInfo.thermalState.rawValue` = 0 (nominal).
- `host_statistics(HOST_CPU_LOAD_INFO)` works (cumulative user/system/idle/nice ticks; CPU usage is the DELTA between two samples).
- Battery: `pmset` says 100%, AC, charged. IORegistry `AppleSmartBattery`: `CurrentCapacity=100`, `MaxCapacity=100` (percent on Apple silicon), `CycleCount=22`, `IsCharging=No`, `ExternalConnected=Yes`, and `BatteryData{DesignCapacity=4629, FullChargeCapacity=4679, NominalChargeCapacity=4806}` (mAh). Health = FullChargeCapacity / DesignCapacity clamped to 0...100 (here 101% -> 100).
- GPU: `IOAccelerator` `PerformanceStatistics` has `Device Utilization %` (34 at probe time). Best effort.
- No battery temperature or SoC temperature key was found: temperature stays `nil` (hidden), as the spec says.

## Global Constraints

- Layer rules unchanged: Domain imports only Foundation; Presentation never imports Data; only the App target wires Data. IOKit/Mach calls live ONLY in `MainternanceData`.
- Unknown is `nil`, never `0` or a made-up value; the UI omits unknown data. Health states and reasons come from Domain.
- Readers must never crash: every external value (NaN, negative, out of range, missing key) maps to `nil` or a clamped value, with tests.
- Reading cost: all readers are cheap and synchronous (< a few ms); the polling cadence rules from the spec are unchanged (2 s visible, 45 s hidden, doubled in Low Power Mode). No new timers.
- Tests: Swift Testing; pure mapping functions are tested with fixtures; real-system smoke tests must use loose, environment-independent assertions (battery may be absent on CI VMs).
- `scripts/lint.sh` exit 0, `scripts/check-boundaries.sh`, `scripts/test.sh` all green before every commit. Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; every commit builds on its own.
- Never claim live data that is not live: copy and labels must be accurate.

## Review Focus

- Disk free uses the "important usage" key (278 GB on the user's Mac, not 232 or 216). Pinned in Task 2.
- A first CPU sample has no delta: result is `nil`, never `0%` or NaN. Pinned in Task 4.
- Battery absent (desktop Mac / VM): `battery == nil`, UI omits the column and row. Pinned in Task 3.
- Battery health above 100% or missing capacities: clamped / `nil`. Pinned in Task 3.
- Unknown startup-item count / OS-update state / scanner status are `nil`, omit their checks and rows, and do NOT make Home permanently amber. Pinned in Task 1.
- Home must not look "Good" or "live" for things it cannot see: the Home summary says what is measured. Pinned in Task 6.

---

### Task 1: Domain: unknown is nil (startup items, OS update, scan status)

**Files:**
- Modify: `Sources/MainternanceDomain/SystemSnapshot.swift`, `Health.swift`, `Overview.swift`
- Modify (compile fixes and nil handling): `Sources/MainternancePresentation/Popover/PopoverModel.swift`, `Home/HomeModel.swift`, any other consumer the compiler flags
- Modify: `Sources/MainternanceData/Mock/*.swift` (mocks keep returning values, wrapped as optionals)
- Test: `Tests/DomainTests/HealthEvaluatorTests.swift`, `LoadOverviewTests.swift`, `Tests/PresentationTests/PopoverModelTests.swift`, `HomeModelTests.swift`

**Interfaces:**
- Produces: `SystemSnapshot.newStartupItemCount: Int?` and `SystemSnapshot.osUpdateAvailable: Bool?` (nil = unknown); `ScanStatusProviding.currentStatus() async -> ScanStatus?` (nil = no scanner yet); `HealthEvaluator.evaluate(snapshot:scan:now:)` takes `scan: ScanStatus?`; `Overview.scan: ScanStatus?`.
- Evaluator rules: the `startupItems` check is omitted when the count is nil; the `osUpdate` check is omitted when the flag is nil; the `lastScan` and `scannerFindings` checks are omitted when `scan == nil`. All other rules unchanged.

- [ ] **Step 1: Write failing tests** (exact reasons unchanged for known values): nil startup count omits `startupItems`; nil osUpdate omits `osUpdate`; `scan == nil` omits `lastScan` and `scannerFindings` and a snapshot that is otherwise healthy yields `overall == .good`; non-nil values behave exactly as before (existing tests keep passing).
- [ ] **Step 2: Run to see them fail** (`scripts/test.sh --filter HealthEvaluatorTests`).
- [ ] **Step 3: Implement** the optional fields, the optional `ScanStatus` through `ScanStatusProviding`, `LoadOverview` and `Overview`, and the evaluator omissions.
- [ ] **Step 4: Presentation nil handling:** the popover omits the "Last scan" and "Next scan" rows when `scan == nil` and shows one row `Scanner: not set up yet`; Home's scan summary card shows `Scanner not set up yet` when `scan == nil`; the Home banner reasons and the menu bar are unaffected. Add tests in `PopoverModelTests` and `HomeModelTests` for these nil cases.
- [ ] **Step 5: Run `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`; commit** `feat(domain): unknown startup/update/scan status is nil`.

### Task 2: Data: disk, memory pressure and thermal readers

**Files:**
- Create: `Sources/MainternanceData/Live/DiskReader.swift`, `MemoryPressureReader.swift`, `ThermalReader.swift`
- Test: `Tests/DataTests/DiskReaderTests.swift`, `MemoryPressureReaderTests.swift`, `ThermalReaderTests.swift`

**Interfaces:**
- Produces (all `public struct`, `Sendable`, injectable raw readers with real defaults):
  - `DiskReader` `init(volumeURL: URL = URL(fileURLWithPath: "/"), read: @escaping @Sendable (URL) -> RawDisk? = DiskReader.readSystem)`; `func read() -> (total: Int64, free: Int64)?`. `RawDisk { total: Int64?, importantFree: Int64? }`; pure `static func map(_ raw: RawDisk?) -> (total: Int64, free: Int64)?`: nil when total is nil or <= 0 or free is nil; free clamped to `0...total`. The system reader uses `.volumeTotalCapacityKey` and `.volumeAvailableCapacityForImportantUsageKey`.
  - `MemoryPressureReader` `init(read: @escaping @Sendable () -> Int32? = MemoryPressureReader.readSystem)`; `func read() -> MemoryPressure?`; pure `static func map(_ level: Int32?) -> MemoryPressure?`: 1 -> `.normal`, 2 -> `.warning`, 4 -> `.critical`, anything else or nil -> nil. The system reader uses `sysctlbyname("kern.memorystatus_vm_pressure_level")`.
  - `ThermalReader` `init(read: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState })`; `func read() -> ThermalLevel`; pure map: nominal/fair/serious/critical to the Domain `ThermalLevel` (unknown future cases -> `.serious`).
- [ ] **Step 1: Write failing tests:** `DiskReader.map` with the user's real numbers (total 494_332_366_848, free 278_333_262_487 maps to the same pair), free > total clamped to total, negative free clamped to 0, total 0/negative/nil -> nil, free nil -> nil; memory levels 1/2/4 and 0/3/8/nil; thermal mapping for all four states; a smoke test per system reader asserting only environment-independent facts (disk: free <= total and total > 0; memory: result is non-nil on macOS; thermal: no crash).
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement the three readers** (the Review Focus disk item: use the important-usage key).
- [ ] **Step 4: `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`; commit** `feat(data): live disk, memory pressure and thermal readers`.

### Task 3: Data: battery reader

**Files:**
- Create: `Sources/MainternanceData/Live/BatteryReader.swift`
- Test: `Tests/DataTests/BatteryReaderTests.swift`

**Interfaces:**
- Produces: `public struct BatteryReader` `init(read: @escaping @Sendable () -> RawBattery? = BatteryReader.readSystem)`; `func read() -> BatterySnapshot?`. `public struct RawBattery: Equatable, Sendable { currentPercent: Int?, isCharging: Bool?, externalConnected: Bool?, cycleCount: Int?, designCapacity: Int?, fullChargeCapacity: Int? }`. Pure `static func map(_ raw: RawBattery?) -> BatterySnapshot?`: nil when raw is nil or `currentPercent` is nil; percent clamped 0...100; `isCharging` = `isCharging ?? false`; `healthPercent` = `fullChargeCapacity * 100 / designCapacity` rounded, clamped 0...100, nil when either capacity is nil or `designCapacity <= 0`; `cycleCount` nil when negative or missing.
- The system reader finds the `AppleSmartBattery` IOService (IOKit; `IOServiceGetMatchingService` + `IORegistryEntryCreateCFProperties`), reads `CurrentCapacity`, `IsCharging`, `ExternalConnected`, `CycleCount` and the nested `BatteryData` dictionary (`DesignCapacity`, `FullChargeCapacity`; if `FullChargeCapacity` is absent fall back to `AppleRawMaxCapacity` at the top level); returns nil when the service does not exist (desktop Mac / VM). Release every IOKit object (`IOObjectRelease`).
- [ ] **Step 1: Write failing tests:** the user's real values (current 100, not charging, external connected, cycles 22, design 4629, full 4679) map to percent 100, health 100 (101% clamped), cycles 22; health 95 for 4397/4629; design 0 or nil -> health nil; percent 140 -> 100, percent -5 -> 0; negative cycles -> nil; raw nil -> nil; a smoke test that only asserts `read()` does not crash and, when non-nil, `0...100` percent.
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement** the mapping and the IOKit reader.
- [ ] **Step 4: `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`; commit** `feat(data): live battery reader`.

### Task 4: Data: CPU and GPU readers

**Files:**
- Create: `Sources/MainternanceData/Live/CPUReader.swift`, `GPUReader.swift`
- Test: `Tests/DataTests/CPUReaderTests.swift`, `GPUReaderTests.swift`

**Interfaces:**
- Produces:
  - `public struct CPUTicks: Equatable, Sendable { user: UInt64, system: UInt64, idle: UInt64, nice: UInt64 }`.
  - `public final class CPUReader: @unchecked Sendable` (or an actor with a synchronous-friendly wrapper; choose what compiles cleanly under Swift 6 without `nonisolated(unsafe)`, state protected by a `Mutex`) with `init(read: @escaping @Sendable () -> CPUTicks? = CPUReader.readSystem)`; `func usage() -> Double?`: the first call stores the baseline and returns nil; later calls return the busy fraction `0...1` of the delta since the previous call; pure `static func usage(previous: CPUTicks, current: CPUTicks) -> Double?` = `(delta user + system + nice) / (delta total)`, nil when the total delta is 0 or any counter went backwards (wrapped); result clamped 0...1 and finite.
  - `public struct GPUReader` `init(read: @escaping @Sendable () -> Int? = GPUReader.readSystem)`; `func usage() -> Double?`; pure `static func map(_ percent: Int?) -> Double?`: nil when missing, clamped to 0...100 then divided by 100. The system reader walks `IOAccelerator` services and reads `PerformanceStatistics["Device Utilization %"]` (the maximum across accelerators), nil when absent. Best effort; never throws or crashes.
- [ ] **Step 1: Write failing tests:** first `usage()` call returns nil (Review Focus); second call with +100 busy / +300 idle ticks gives 0.25; zero total delta -> nil; a counter going backwards -> nil; three-call sequence uses the delta of the last two calls only; GPU map 34 -> 0.34, 150 -> 1.0, -3 -> 0.0, nil -> nil; smoke tests for the system readers (no crash; values in range when non-nil).
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement** the readers (`host_statistics(HOST_CPU_LOAD_INFO)` for ticks; IOKit for GPU, releasing objects).
- [ ] **Step 4: `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`; commit** `feat(data): live CPU and GPU readers`.

### Task 5: Data and App: the live provider and wiring

**Files:**
- Create: `Sources/MainternanceData/Live/LiveSystemSnapshotProvider.swift`, `NoScannerStatusProvider.swift`, `NoSuggestedActionsProvider.swift`
- Modify: `Sources/MainternanceApp/CompositionRoot.swift`
- Test: `Tests/DataTests/LiveSystemSnapshotProviderTests.swift`

**Interfaces:**
- Produces: `public struct LiveSystemSnapshotProvider: SystemSnapshotProviding` with `init(disk: DiskReader = .init(), memory: MemoryPressureReader = .init(), thermal: ThermalReader = .init(), battery: BatteryReader = .init(), cpu: CPUReader = .init(), gpu: GPUReader = .init())`; `currentSnapshot()` composes one `SystemSnapshot`: disk total/free (when the disk reader returns nil: total 0, free 0, which the evaluator already reports as "Disk size unavailable"), `memoryPressure` (nil from the reader -> `.normal` is NOT allowed: if the Domain type cannot express unknown, make `SystemSnapshot.memoryPressure` optional in this task and update the evaluator to omit the check when nil, with tests), thermal, `cpuUsage` (nil from the first sample -> 0.0 is NOT allowed: make `SystemSnapshot.cpuUsage` `Double?` and update consumers to omit the CPU column/sparkline sample when nil), `gpuUsage`, `temperatureCelsius = nil`, `battery`, `newStartupItemCount = nil`, `osUpdateAvailable = nil`.
- `NoScannerStatusProvider: ScanStatusProviding` returns `nil`; `NoSuggestedActionsProvider: SuggestedActionsProviding` returns `[]`.
- `CompositionRoot` wires `LiveSystemSnapshotProvider`, `NoScannerStatusProvider`, `NoSuggestedActionsProvider` (the mock providers stay in the module for tests and previews but are no longer wired).
- [ ] **Step 1: Write failing tests** with fake readers: all readers present composes the expected snapshot; each reader returning nil yields the documented nil/omitted field; first snapshot has `cpuUsage == nil` and the second has a value (CPU delta); memory unknown makes the check omitted; end-to-end: `LoadOverview` with the live provider (fake readers) and the no-scanner provider produces a report with no `lastScan`/`scannerFindings`/`startupItems`/`osUpdate` checks.
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement** the provider, the two empty providers, the optional Domain fields (memoryPressure, cpuUsage) with evaluator/presentation nil handling (the popover omits the CPU and Memory columns when nil; Home omits the Memory tile; sparklines skip nil CPU samples) and the wiring.
- [ ] **Step 4: Real-machine smoke test:** add a `DataTests` test that `LiveSystemSnapshotProvider().currentSnapshot()` returns `diskTotalBytes > 0` and `diskFreeBytes <= diskTotalBytes` (loose, environment-independent). Also, once, run the same provider from a throwaway Swift script or test with printed output and put the real values (disk free/total, memory pressure, thermal, battery percent/health/cycles, CPU after two samples a second apart, GPU) in the task report so the controller can compare them with `pmset -g batt`, System Settings and Activity Monitor.
- [ ] **Step 5: `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`, `swift build`; commit** `feat: wire live system readings into the app`.

### Task 6: Honest UI: sample-data badges, popover closes, Details empty state

**Files:**
- Create: `Sources/MainternancePresentation/Design/SampleDataBadge.swift`
- Modify: `Files/FilesView.swift`, `Scanner/ScannerView.swift`, `Cleanup/CleanupView.swift`, `Startup/StartupView.swift`, `Uninstaller/UninstallerView.swift`, `Home/DetailsDisclosure.swift`, `Home/HomeView.swift`, `Popover/PopoverView.swift`, `Sources/MainternanceApp/MainternanceApp.swift`, `Window/SidebarView.swift`
- Test: `Tests/PresentationTests/DetailsStateTests.swift`

**Interfaces:**
- Produces: `SampleDataBadge` (a compact capsule reading `Sample data`, with an accessibility label `Sample data, not your real files`); shown at the top of Files, Scanner, Cleanup, Startup and Uninstaller screens and next to their sidebar items (small `Sample` text). Settings gets a one-line note under the notification toggles: `Not connected yet: these settings are not applied.`
- Popover/Home: the popover closes when `Open Mainternance` is chosen (dismiss the `MenuBarExtra` window, for example `NSApp.keyWindow?.orderOut(nil)` or the supported dismiss mechanism for `MenuBarExtra(.window)`; verify it does not break the visibility observer: closing must report hidden through `WindowVisibilityObserver`).
- Details: a pure `DetailsState` (in Presentation) derives from the history: `.collecting` when fewer than 2 samples (view text `Collecting data…`), `.ready` otherwise; the disclosure shows `Collecting data…` in `.collecting` and omits the GPU row when no GPU samples; tests for the thresholds and for the nil-CPU samples skipped.
- Home banner/summary wording: when there is no scanner, the card reads `Scanner: not set up yet`; nothing on Home says "Good" for checks it cannot make (already enforced by Task 1/5; add a test asserting the check list for the live provider with unknown fields).
- [ ] **Step 1: Write failing tests** for `DetailsState` (0, 1, 2, 30 samples; nil CPU samples do not count) and a test that the Home/popover models built from a live-style overview (unknown startup/osUpdate/scan, nil CPU on first sample) contain no `0%` text and no scan rows.
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement** the badge, the screens' badges, the sidebar markers, the popover dismiss on open, the Details empty state and the Settings note.
- [ ] **Step 4: `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`, `swift build`; launch the debug binary 4 s and `pkill -x Mainternance`; commit** `feat(ui): label sample-data screens, close popover on open, details empty state`.

### Task 7: README, honesty about what is live, release build

**Files:**
- Modify: `README.md`

- [ ] **Step 1:** Update the README with a "What is live" section: LIVE: disk free (important usage), memory pressure, thermal state, battery (percent, charging, health, cycles), CPU, GPU (when the Mac reports it); NOT LIVE (sample data, labelled in the UI): Files, Scanner, Cleanup, Startup, Uninstaller, Settings; not available on this hardware path: temperatures.
- [ ] **Step 2:** `scripts/build-app.sh` (no `--install`); `codesign --verify --deep --strict` on the bundle; commit `docs: what is live and what is sample data`.
