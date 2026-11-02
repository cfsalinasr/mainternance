# Scanner Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A real malware scanner: install ClamAV through Homebrew from inside the app, keep its definitions up to date, run quick and full scans with live progress, show real findings, quarantine files only after the user confirms (and restore them), and hide the screens that are still not real.

**Architecture:** Domain gets scanner value types and ports (`ScannerEngine`, `QuarantineStoring`, scan status). Data gets the ClamAV integration: a locator, a testable process runner, an installer + definitions updater with an app-owned config and database directory, a scan runner that parses `clamscan` output, and a quarantine store. Presentation replaces the sample `ScannerViewState` with a real view model over the Domain ports. Everything that talks to the system sits behind a protocol so it is tested with fake runners and a fake `clamscan` script; the real engine is exercised by an opt-in integration test and by the user's EICAR test file.

**Tech Stack:** Swift 6, Foundation `Process`/`FileManager`, ClamAV 1.5.x (`clamscan`, `freshclam`) from Homebrew (`/opt/homebrew`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-29-mainternance-design.md` (Malware scanner, Health model, Performance rules). Earlier plans: `docs/superpowers/plans/2026-10-29-foundation-and-ui.md`, `docs/superpowers/plans/2026-10-29-live-metrics.md` (read their Global Constraints; the common rules at `.superpowers/sdd/2026-10-29-live-metrics/common-rules.md` also apply: nil for unknown, no leaks, honest copy, whole-tree lint exit 0, tests that fail on regression).

## Verified facts (this Mac, 2026-10-29)

- Homebrew at `/opt/homebrew`; formula `clamav` 1.5.4 is bottled and NOT installed. Its caveat: the example configs in `/opt/homebrew/etc/clamav/` must be edited before use. DECISION: the app never edits Homebrew's files. It writes its OWN `freshclam.conf` and keeps its OWN database in `~/Library/Application Support/Mainternance/ClamAV/` and passes them explicitly (`freshclam --config-file=...`, `clamscan --database=...`).
- Binaries after install: `/opt/homebrew/bin/clamscan`, `/opt/homebrew/bin/freshclam` (Intel Homebrew: `/usr/local/bin`). 215 GB free on this Mac; definitions are roughly 300 MB.
- The EICAR test string is detected by ClamAV and is harmless: it is the safe end-to-end test.
- The app is not sandboxed. Full Disk Access is NOT granted: scanning protected folders produces "Operation not permitted" errors that the UI must explain.

## Global Constraints

- Layer rules: Domain imports only Foundation; Presentation never imports Data; only the App target wires Data. All `Process`/file-system code lives in `MainternanceData`.
- Never use a shell: run executables with an argument array (no `sh -c`, no string interpolation of paths into commands). Never use `sudo`. Never run anything but the located `brew`, `clamscan`, `freshclam`.
- Nothing is ever deleted: quarantine MOVES a file after explicit user confirmation and it can always be restored. There is no permanent delete in this plan. Protected paths can never be quarantined (`/System`, `/usr`, `/bin`, `/sbin`, `/Library/Apple`, `/private/var/db`, the running app bundle) and only regular files (not directories, not symlinks) are moved.
- Scans run at low priority and never block the main actor. A scan is cancellable, and cancelling terminates the `clamscan` child process (no orphans, no zombies) and leaves no partial state.
- All UI copy is honest: no "protected"/"safe" claims; say what was scanned, how many files, how many unreadable, with which definitions age. Findings come from ClamAV signatures; the UI says so.
- Unknown is nil (no scanner installed: `ScanStatus` stays nil, as today).
- `scripts/lint.sh` exit 0 on the whole tree, `scripts/check-boundaries.sh`, `scripts/test.sh` green before every commit; commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; every commit builds on its own.

## Review Focus

- Command injection / path safety: a file or folder name containing spaces, quotes, `;`, `$()`, a leading `-`, or newlines must never be interpreted as an option or a command (argument arrays, `--` separators, absolute paths). Pinned in Tasks 3 and 5.
- Orphaned processes: cancelling a scan, or quitting the app mid-scan, must not leave `clamscan` running. Pinned in Task 5.
- Quarantine safety: a protected path, a directory, a symlink, a file that vanished or changed since the scan, a name collision on restore, and a missing original folder must all be handled without data loss. Pinned in Task 6.
- Findings parsing: ClamAV output lines with odd paths (colons in names, `FOUND` inside a name) must not produce wrong findings. Pinned in Task 5.
- Honest permission errors: unreadable files are counted and explained, never reported as "clean". Pinned in Tasks 5 and 7.
- Home health: unresolved findings make Home red, "never scanned" amber, and neither appears when no scanner is installed. Pinned in Task 7.

---

### Task 1: Hide the screens that are not real

**Files:**
- Modify: `Sources/MainternanceDomain/Health.swift` (or wherever `AppDestination` lives), `Sources/MainternancePresentation/Window/SidebarView.swift`, `MainWindowView.swift`, `Navigation.swift`, `Sources/MainternancePresentation/Home/*` (a "Coming next" line), `README.md`
- Test: `Tests/PresentationTests/NavigationTests.swift` (or the sidebar tests)

**Interfaces:**
- Produces: `AppDestination.isAvailable: Bool` (a pure, tested rule in Presentation or Domain: `true` for `home` and `settings`; `false` for `files`, `cleanup`, `startup`, `uninstaller`; `scanner` is `false` in this task and flipped to `true` in Task 7). The sidebar lists only available destinations; `Navigation.open(_:)` ignores unavailable ones (a deep link or a health-check destination pointing to an unavailable screen routes to Home); the unavailable screens' code, `SampleDataBadge` and sample data stay in the repo untouched.
- [ ] **Step 1: Write failing tests:** the sidebar item list excludes unavailable destinations and keeps order; `open(.files)` leaves the selection unchanged (or goes Home) and never selects a hidden screen; a `HealthCheck` whose destination is unavailable is not rendered as a tappable link; the Home "Coming next" text is pinned (`Coming next: malware scanner, file explorer, cleanup, startup items, uninstaller.`).
- [ ] **Step 2: Run to see them fail; implement; run again.**
- [ ] **Step 3:** README "What is live" section updated: hidden screens are listed under "Planned, not available yet".
- [ ] **Step 4: `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`; commit** `feat(ui): hide screens whose engines do not exist yet`.

### Task 2: Domain: scanner types and ports

**Files:**
- Create: `Sources/MainternanceDomain/Scanner/ScannerTypes.swift`, `ScannerEngine.swift`, `Quarantine.swift`, `ScanSummaryRules.swift`
- Test: `Tests/DomainTests/ScannerTypesTests.swift`

**Interfaces (all `public`, `Sendable`, `Equatable` where useful):**
- `enum EngineStatus: Equatable { case homebrewMissing, notInstalled, installing(stage: String), downloadingDefinitions, ready(definitionsAge: TimeInterval?), updateNeeded(definitionsAge: TimeInterval?), failed(message: String) }` with pure `static func status(engineInstalled: Bool, homebrewAvailable: Bool, definitionsDate: Date?, now: Date) -> EngineStatus` (not installed + no Homebrew -> `.homebrewMissing`; not installed -> `.notInstalled`; installed + no definitions -> `.updateNeeded(nil)`; definitions older than 7 days -> `.updateNeeded(age)`; else `.ready(age)`).
- `enum ScanScope: Equatable { case quick, full, custom(URL) }`.
- `struct ScanFinding: Identifiable, Equatable { id: UUID; path: String; signature: String; foundAt: Date }`.
- `enum ScanEvent: Equatable { case started(scope: ScanScope), progress(scanned: Int, current: String), found(ScanFinding), finished(ScanSummary), failed(message: String) }`; `struct ScanSummary: Equatable { scope: ScanScope; scanned: Int; unreadable: Int; findings: Int; startedAt: Date; endedAt: Date; cancelled: Bool; definitionsDate: Date? }`.
- `protocol ScannerEngine: Sendable { func status() async -> EngineStatus; func install() -> AsyncStream<InstallEvent>; func updateDefinitions() -> AsyncStream<InstallEvent>; func scan(_ scope: ScanScope) -> AsyncStream<ScanEvent>; func cancelScan() async }` with `enum InstallEvent: Equatable { case stage(String), progress(Double?), finished, failed(message: String) }`.
- `struct QuarantineRecord: Identifiable, Equatable, Codable { id: UUID; originalPath: String; quarantinedAt: Date; signature: String; sha256: String; size: Int64 }`; `protocol QuarantineStoring: Sendable { func quarantine(path: String, signature: String) async throws -> QuarantineRecord; func restore(_ id: UUID) async throws -> String; func records() async -> [QuarantineRecord] }`; `enum QuarantineError: Error, Equatable { case protectedPath, notRegularFile, missing, changedSinceScan, restoreTargetMissing, alreadyQuarantined, ioFailure(String) }`.
- `ScanSummaryRules` (pure): `lastScanDate(summary:) -> Date?` (nil when cancelled), `ScanStatus` mapping: `ScanStatus(lastScan: summary.endedAt, nextScan: nil, unresolvedFindings: n)`.
- [ ] **Step 1: Write failing tests:** `EngineStatus.status(...)` for every branch and the 7-day boundary (exactly 7 days is ready, 7 days + 1 s is updateNeeded); a cancelled scan does not count as a last scan; `ScanStatus` mapping; every type is `Sendable` (compile-time).
- [ ] **Step 2: Run to see them fail; implement; run again.**
- [ ] **Step 3: `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`; commit** `feat(domain): scanner engine and quarantine ports`.

### Task 3: Data: ClamAV locator and process runner

**Files:**
- Create: `Sources/MainternanceData/Scanner/ToolLocator.swift`, `ProcessRunning.swift`, `SystemProcessRunner.swift`
- Test: `Tests/DataTests/ToolLocatorTests.swift`, `SystemProcessRunnerTests.swift` (uses real `/bin/echo`, `/bin/sh` only inside TESTS to build fake tools; production never uses a shell)

**Interfaces:**
- `struct ToolLocator { init(candidates: [String] = ["/opt/homebrew/bin", "/usr/local/bin"], isExecutable: @Sendable (String) -> Bool = ...); func path(for tool: String) -> String?` (absolute path only; the tool name is one of `brew`, `clamscan`, `freshclam`; a name with `/` or `..` returns nil) }.
- `protocol ProcessRunning: Sendable { func run(_ executable: String, arguments: [String], environment: [String: String]?, lowPriority: Bool) -> RunningProcess }`; `final class RunningProcess: Sendable` exposing `lines: AsyncStream<ProcessLine>` (`enum ProcessLine { case stdout(String), stderr(String) }`, split on `\n`, partial lines flushed at EOF, invalid UTF-8 replaced not dropped), `func wait() async -> Int32` (exit status; `nil`-safe for launch failure -> 127 with a stderr line), `func terminate() async` (SIGTERM, then SIGKILL after 2 s, reaping the child) and `isRunning`.
- `SystemProcessRunner: ProcessRunning` uses `Foundation.Process` with `executableURL` and `arguments` (NO shell), `qualityOfService = .utility` when `lowPriority`, pipes read asynchronously (no deadlock on large output), and terminates the child if the owning task is cancelled.
- [ ] **Step 1: Write failing tests:** locator returns the first executable candidate path, nil when none, rejects names with `/` or `..`; runner streams stdout and stderr lines separately and in order, handles output larger than the pipe buffer (for example 200,000 lines), flushes a final line without a trailing newline, reports a non-zero exit status, reports a launch failure for a missing executable, an argument containing spaces/quotes/`;`/`$(...)`/newline/leading `-` reaches the child verbatim (use `/usr/bin/printf '%s\n'`-style fake via `/bin/echo` is NOT enough: use a tiny script under a temp dir that prints its argv), `terminate()` kills a long-running child (`/bin/sleep 30`) within about 3 s and the process is gone (check with `kill(pid, 0)`), cancelling the awaiting task terminates the child.
- [ ] **Step 2: Run to see them fail; implement; run again.**
- [ ] **Step 3: `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`; commit** `feat(data): tool locator and process runner`.

### Task 4: Data: ClamAV installer and definitions

**Files:**
- Create: `Sources/MainternanceData/Scanner/ClamAVPaths.swift`, `ClamAVInstaller.swift`, `DefinitionsStore.swift`
- Test: `Tests/DataTests/ClamAVInstallerTests.swift`, `DefinitionsStoreTests.swift`

**Interfaces:**
- `struct ClamAVPaths { init(supportDirectory: URL = ~/Library/Application Support/Mainternance); var root: URL /*.../ClamAV*/; var databaseDirectory: URL; var freshclamConfig: URL; var quarantineDirectory: URL /*sibling*/ }`.
- `struct DefinitionsStore { init(paths: ClamAVPaths); func definitionsDate() -> Date? }` = the newest modification date among `daily.cvd|daily.cld`, `main.cvd|main.cld`, `bytecode.cvd|bytecode.cld` that exist (nil when none).
- `final class ClamAVInstaller` (Sendable) `init(locator: ToolLocator, runner: ProcessRunning, paths: ClamAVPaths)`: `func isInstalled() -> Bool` (`clamscan` and `freshclam` located); `func install() -> AsyncStream<InstallEvent>`: requires `brew` (else `.failed("Homebrew was not found ...")`), runs `brew install clamav` with `HOMEBREW_NO_AUTO_UPDATE=1` and `HOMEBREW_NO_ENV_HINTS=1` in the environment, emits `.stage(...)` events from recognizable brew output ("Downloading", "Pouring", "Summary" etc.; unknown lines are ignored, progress stays `nil`), `.finished` on exit 0 and `.failed(message)` with the last stderr lines otherwise; never `sudo`; `func updateDefinitions() -> AsyncStream<InstallEvent>`: ensures the app-owned directory and writes `freshclam.conf` (`DatabaseDirectory <databaseDirectory>`, `DatabaseMirror database.clamav.net`, `LogTimeout`-free minimal config, NO `Example` line, a pure `static func freshclamConfig(databaseDirectory:) -> String` that is unit-tested) then runs `freshclam --config-file=<conf> --stdout --no-warnings`, emits `.stage("Downloading definitions…")` and download-percentage progress parsed from freshclam output when present (pure `parseFreshclamProgress(_:) -> Double?` tested with real-looking lines such as `daily.cvd database available for update` and `Time: 4.3s, ETA: 0.0s [=========================>] 62.58MiB/62.58MiB`; unrecognized lines -> nil), `.finished` only when exit 0 AND a definitions file now exists, otherwise `.failed`.
- [ ] **Step 1: Write failing tests** with a fake `ProcessRunning` (records executable + arguments + environment, replays canned output/exit codes): brew missing -> failed message; the install invocation is exactly `[brew, install, clamav]` with the environment keys set; success and failure paths; stage mapping; `freshclamConfig` content has `DatabaseDirectory` and no `Example` and no Homebrew paths; `updateDefinitions` passes `--config-file=<our conf>` and never touches `/opt/homebrew/etc`; the config file is created with the expected content in a temp directory; progress parser cases; `DefinitionsStore.definitionsDate()` newest-of logic with temp files and mtimes, nil when none; a definitions download that exits 0 but leaves no database file is a failure.
- [ ] **Step 2: Run to see them fail; implement; run again.**
- [ ] **Step 3: `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`; commit** `feat(data): clamav installer and definitions store`.

### Task 5: Data: scan runner and output parsing

**Files:**
- Create: `Sources/MainternanceData/Scanner/ScanScopes.swift`, `ClamScanOutputParser.swift`, `ClamAVScanner.swift`
- Test: `Tests/DataTests/ClamScanOutputParserTests.swift`, `ScanScopesTests.swift`, `ClamAVScannerTests.swift`

**Interfaces:**
- `ScanScopes` (pure): `static func roots(for scope: ScanScope, home: URL, fileManager existence: (String) -> Bool) -> [String]`: quick = `~/Downloads`, `~/Desktop`, `/Applications`, `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`; full = `~` and `/Applications`; custom = that URL; only existing paths, absolute, de-duplicated, never `/` itself.
- `ClamScanOutputParser` (pure): parses one `clamscan` stdout/stderr line into `enum ClamLine { case scanned(path: String), found(path: String, signature: String), unreadable(path: String), summary(...)/ignored }` for `clamscan -v --no-summary`-style output (`<path>: OK`, `<path>: <Signature> FOUND`, `<path>: Permission denied. ERROR` / `Can't open file or directory ... ERROR` / `Operation not permitted`); the PATH is everything before the LAST `": "` that precedes a known suffix (`OK`, ` FOUND`, `ERROR`), so a path containing `: ` or the word FOUND parses correctly.
- `ClamAVScanner` (`ScannerEngine` implementation) `init(locator:, runner:, paths:, definitions:, installer:, now:, home:)`: `status()` from `EngineStatus.status(...)`; `scan(_:)` returns an `AsyncStream<ScanEvent>`: refuses to start unless status is `.ready` or `.updateNeeded` (emits `.failed("...")`), runs `clamscan` with an argument ARRAY: `--database=<dir>`, `-v`, `--no-summary`, `--recursive`, `--infected` is NOT used (we need the OK lines for progress), `--` before the root paths, low priority; emits `.started`, throttled `.progress(scanned:current:)` (at most about 10 per second, so a million files do not flood the UI), `.found(ScanFinding)` for every FOUND line, counts unreadable files, and `.finished(ScanSummary)` on exit 0 or 1 (1 means infected files were found); exit 2 or higher with no findings -> `.failed(message)` including the last stderr line; `cancelScan()` terminates the child (no orphan) and the stream finishes with `.finished(summary)` where `cancelled == true`; only one scan at a time (a second `scan` while one runs emits `.failed("A scan is already running")`).
- [ ] **Step 1: Write failing tests:** parser table (OK, FOUND, odd paths with `: ` and with `FOUND` in the name, unicode, permission errors, noise lines ignored); scope roots (existence filtering, de-dupe, never `/`); scanner with a FAKE runner replaying a canned transcript: events in order, findings produced with the right path/signature, unreadable counted and NOT reported as clean, exit-code mapping (0 clean, 1 infected, 2 failure), progress throttling (a 100,000-line transcript yields far fewer than 100,000 progress events), cancel terminates the child and yields `cancelled == true`, a second concurrent scan is refused, refusal when not installed/no definitions, the exact argument array (`--` separator present, a folder named `-rf $(x) ; y` passed verbatim after it), definitions date copied into the summary; plus an opt-in integration test that is SKIPPED unless `clamscan` exists and a definitions database exists, which scans a temp folder containing the EICAR test string and expects one finding named like `Eicar` (the EICAR string is built from two concatenated halves in the test source so this repository does not contain a file antivirus tools flag).
- [ ] **Step 2: Run to see them fail; implement; run again.**
- [ ] **Step 3: `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`; commit** `feat(data): clamscan scan runner and output parser`.

### Task 6: Data: quarantine store

**Files:**
- Create: `Sources/MainternanceData/Scanner/ProtectedPaths.swift`, `QuarantineStore.swift`
- Test: `Tests/DataTests/ProtectedPathsTests.swift`, `QuarantineStoreTests.swift`

**Interfaces:**
- `ProtectedPaths.isProtected(_ path: String) -> Bool` (pure, resolves `..` and symlinked prefixes via `standardizedFileURL`/`resolvingSymlinksInPath`, case-insensitive for the volume): `/System`, `/usr`, `/bin`, `/sbin`, `/Library/Apple`, `/private/var/db`, `/private/etc`, the root itself, the user's home itself and the Quarantine directory itself, and the running app bundle path.
- `QuarantineStore: QuarantineStoring` `init(directory: URL, fileManager: FileManager = .default, now: () -> Date)`: `quarantine(path:signature:)`: rejects protected paths (`.protectedPath`), non-regular files, symlinks and directories (`.notRegularFile`), missing files (`.missing`); computes SHA-256 (CryptoKit, streamed in chunks) and size; moves the file (same-volume `moveItem`; cross-volume copy + verify hash + remove original only after the copy verified) to `<dir>/<uuid>`; removes the execute bits (`0o600`); writes `<dir>/index.json` atomically (the manifest, `QuarantineRecord` list); `restore(_:)`: moves back to `originalPath`; if the original folder is missing -> `.restoreTargetMissing` (nothing moved); if a file already exists there -> restores next to it with a ` (restored)` suffix and returns the final path; restores the permissions recorded at quarantine time (store them in the manifest); unknown id -> `.missing`; an id already restored is a no-op error `.missing`; `records()` returns the manifest; a corrupt or missing manifest yields an empty list without crashing and never deletes quarantined files; all operations are serialized (actor or lock). NO permanent deletion API.
- [ ] **Step 1: Write failing tests** in temp directories (never touch real user files): quarantine then restore round-trips content, permissions and returns the path; protected paths table; symlink/directory/missing rejected with the right error; hash/size recorded; the quarantined copy has no execute bit; restore collision gets the suffix and does not overwrite; restore with a missing original folder changes nothing; a corrupt manifest is survived; two concurrent quarantines of different files both succeed and the manifest has both; quarantining the same path twice -> second is `.missing` or `.alreadyQuarantined` (pick one, document, test); a crash between move and manifest write is recoverable (the manifest write happens FIRST as `pending`, or an orphan sweep restores consistency: choose and test; never lose a file).
- [ ] **Step 2: Run to see them fail; implement; run again.**
- [ ] **Step 3: `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`; commit** `feat(data): quarantine store with protected paths`.

### Task 7: Presentation and App: the real Scanner screen and Home status

**Files:**
- Create: `Sources/MainternancePresentation/Scanner/ScannerViewModel.swift`, `ScanStatusStore.swift` (Data side: `Sources/MainternanceData/Scanner/ScanStatusStore.swift` persisting the last scan summary and unresolved findings as JSON in Application Support)
- Modify: `Scanner/ScannerView.swift`, `EngineStatusCard.swift`, `ScanProgressCard.swift`, `FindingsList.swift`, `ScannerSampleState.swift` (remove the sample preview picker and the sample badge from this screen; the sample data types that are no longer used are deleted), `Window/WindowStates.swift`, `Sources/MainternanceApp/CompositionRoot.swift`, `AppDestination.isAvailable` (scanner becomes `true`), the scan-status provider wiring (`ScanStatusProviding` real implementation in Data replacing `NoScannerStatusProvider` when the engine is installed)
- Test: `Tests/PresentationTests/ScannerViewModelTests.swift`, `Tests/DataTests/ScanStatusStoreTests.swift`

**Interfaces:**
- `@MainActor @Observable final class ScannerViewModel` `init(engine: any ScannerEngine, quarantine: any QuarantineStoring, statusStore: any ScanStatusRecording, now: ...)`: published `engine: EngineStatus`, `run: RunState` (`idle`, `installing(stage, progress)`, `scanning(scanned, current, unreadable)`, `finished(summary)`), `findings: [ScanFinding]` (unresolved), `quarantined: [QuarantineRecord]`, `pendingQuarantine: ScanFinding?`; actions `refreshStatus()`, `install()`, `updateDefinitions()`, `startScan(_ scope)`, `cancel()`, `requestQuarantine(_ id)`, `confirmQuarantine()`, `cancelQuarantine()`, `restore(_ id)`; `canStartScan` is true only when the engine is `ready`/`updateNeeded` and nothing is running; Quarantine ALWAYS goes through `requestQuarantine` then `confirmQuarantine` (never automatic); errors are exposed as user-readable text; no real file or process is touched in the view model tests (fakes only).
- UI: engine card (Install / Update definitions buttons, progress, `homebrewMissing` guidance with the install URL text `https://brew.sh`, `failed` with the message), Quick scan / Full scan / Cancel buttons enabled by `canStartScan`, progress card with scanned count, current folder (middle truncation), unreadable count and, when unreadable > 0 AND the files look like permission errors, an explanation with a button `Open Full Disk Access settings` that opens `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`; findings list with signature name, path, `Quarantine…` (confirmation sheet: names the file and the signature and says exactly "The file will be moved to the app's quarantine folder. It is not deleted and you can restore it.") and a Quarantine section with `Restore`; accessibility labels; severity is never by color alone; no "protected/safe" claims, summary text says what was scanned and with which definitions date; a one-line caption `Detections come from ClamAV signatures and can include false positives.`
- Home: `ScanStatusProviding` real implementation reads the persisted summary: `lastScan` (ignores cancelled scans), `unresolvedFindings` (decremented when a finding is quarantined; resolved findings never reappear without a new scan), `nextScan = nil`. While the engine is not installed the provider returns nil (scanner row stays "Not set up yet"); once installed: never scanned -> amber "Never scanned", findings -> red.
- [ ] **Step 1: Write failing tests** for the view model with fake engine/quarantine/statusStore: install flow states; refresh status; `canStartScan` per engine state and while running; a scan streams progress and ends `finished`; cancel; findings accumulate; unresolved findings counted; `confirmQuarantine` without `requestQuarantine` does nothing; `requestQuarantine` of an unknown or already-quarantined id does not open the sheet; confirm quarantines exactly the requested finding (captured by id), removes it from `findings`, adds to `quarantined`, updates the status store; a quarantine error (`.changedSinceScan`, `.protectedPath`) leaves the finding in place and shows an error; restore moves it back to `findings` only if it was a finding of the last scan; a second scan while running is rejected; `ScanStatusStore` persistence round trip, corrupt file -> nil, cancelled scans ignored. Pin all user-visible strings.
- [ ] **Step 2: Run to see them fail; implement the view model, the Data status store, the screen and the wiring; flip `AppDestination.scanner.isAvailable`; run again.**
- [ ] **Step 3: `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`, `swift build`; smoke-launch 4 s; commit** `feat: real scanner screen, engine wiring and scan status`.

### Task 8: Docs, release build and the user's test script

**Files:**
- Modify: `README.md`; Create: `docs/testing-the-scanner.md`

- [ ] **Step 1:** README: Scanner is live (what it does and does not do: on-demand scans, no real-time protection, signatures only, quarantine and restore, no permanent delete, Homebrew required, weekly scheduling and notifications are NOT included yet). `docs/testing-the-scanner.md`: the safe EICAR test (how to create the harmless test file with `printf` from two halves, scan it from the app, quarantine it, restore it, delete it by hand), what the Full Disk Access message means, how to uninstall (`brew uninstall clamav`, remove `~/Library/Application Support/Mainternance/ClamAV`).
- [ ] **Step 2:** `scripts/build-app.sh` (no `--install`), `codesign --verify --deep --strict` on the bundle; commit `docs: scanner documentation`.
