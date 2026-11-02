# Weekly Scan, Notifications, Launch at Login and Live Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Settings screen real: saved preferences, a working "Launch at login", an opt-in weekly scan that runs while the app is open, and notifications for problems and for the weekly result.

**Architecture:** Domain gets `AppPreferences`, the pure schedule rules and three ports (preferences, login item, notifications). Data implements them (JSON file, `SMAppService`, `UNUserNotificationCenter`). Presentation gets a live `SettingsViewState` and a `ScanScheduler` that watches the clock and starts a scan through the existing `ScannerViewModel`; a small `ScanNotifier` turns finished scans into notifications. The App target wires them.

**Tech Stack:** Swift 6, ServiceManagement (`SMAppService.mainApp`), UserNotifications, Swift Testing. Same layers and rules as `docs/superpowers/plans/2026-10-29-scanner-engine.md`.

**Spec:** `docs/superpowers/specs/2026-10-29-mainternance-design.md` (Settings, scheduling), plus this plan's decisions below. No separate design document: the owner asked for the rest of the app to be built at the builder's discretion, so the calls are listed here.

## Decisions (builder's calls)

- The weekly scan is OFF by default and starts only after the owner turns it on. It runs a **Quick** scan, only while Mainternance is running (it is a menu bar app; "Launch at login" keeps it running). There is no background daemon and no launchd job.
- A run missed because the app was closed or the Mac asleep is made up ONCE, when the app is next running and the scanner is ready, only if the last run is older than one week-slot. Nothing is retried when the scanner is not ready; the next tick tries again.
- A scheduled scan never starts while another scan, install or quarantine is working.
- "Problem alerts": a notification when a finished scan has findings (any scan, manual or scheduled). "Weekly digest": a notification with the result of each scheduled scan (clean or not). Notifications carry counts only, never file names.
- Nothing is claimed that is not true: when notification permission is denied, or login-item approval is needed, Settings says so in plain words and where to change it.

## Global Constraints

- Layer rules: Domain imports only Foundation; Presentation never imports Data; only the App target wires Data. System APIs (`SMAppService`, `UNUserNotificationCenter`, files) live in `MainternanceData` behind Domain ports.
- Nothing is deleted or moved by this work. No `sudo`, no shell, no launchd plists.
- Unknown is nil/"unknown", never faked. All UI copy is honest (no "protected" claims; the preview captions in Settings are removed only when the control behind them is real).
- `scripts/lint.sh` exit 0, `scripts/check-boundaries.sh`, `scripts/test.sh` green before every commit; commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; every commit builds on its own. Float comparisons in tests use a tolerance.

## Review Focus

- A damaged or hand-edited preferences file (bad JSON, weekday 99, hour -5) must load defaults/clamped values and must not be overwritten before it is moved aside. Pinned in Task 2.
- Clock edge cases: daylight-saving change, a time zone change, the Mac asleep through the due time, and "now" exactly at the due time must run once, never twice in one slot and never in a loop. Pinned in Task 1 and Task 4.
- A scheduled scan colliding with a running scan or an install must be skipped, not queued or stacked. Pinned in Task 4.
- Notification permission denied or login-item `requiresApproval`: the toggle must reflect the real state, not the requested one. Pinned in Tasks 2 and 3.
- Running unbundled (tests, `swift run`): the notification and login-item services must degrade to "unavailable" without crashing. Pinned in Task 2.

---

## File structure

- Domain (new): `Sources/MainternanceDomain/Settings/AppPreferences.swift` (preferences + `ScanSchedule` rules), `Sources/MainternanceDomain/Settings/SettingsPorts.swift` (the three ports and their value types).
- Data (new): `Sources/MainternanceData/Settings/PreferencesStore.swift`, `LoginItemService.swift`, `UserNotificationService.swift`.
- Presentation: modify `Settings/SettingsViewState.swift`, `Settings/SettingsView.swift`; remove `Settings/ScanScheduleStore.swift` and the presentation-only `Scanner/ScanSchedule.swift` (moved to Domain); new `Scheduling/ScanScheduler.swift`, `Scheduling/ScanNotifier.swift`.
- App: modify `CompositionRoot.swift`, `MainternanceApp.swift`, `Window/WindowStates` (takes the settings state).
- Docs: `README.md`, `docs/STATUS.md`.

### Task 1: Domain: preferences, schedule rules, ports

**Files:**
- Create: `Sources/MainternanceDomain/Settings/AppPreferences.swift`, `Sources/MainternanceDomain/Settings/SettingsPorts.swift`
- Test: `Tests/DomainTests/ScanScheduleTests.swift`

**Interfaces:**
- Produces:
  - `public struct ScanSchedule: Equatable, Codable, Sendable { public var weekday: Int /*1=Sunday*/; public var hour: Int; public var minute: Int; public init(weekday: Int = 1, hour: Int = 2, minute: Int = 0); public func clamped() -> ScanSchedule; public func slotStart(containing now: Date, calendar: Calendar) -> Date; public func isDue(now: Date, lastRun: Date?, calendar: Calendar) -> Bool; public static func weekdayName(_:calendar:) -> String; public func description(locale:timeZone:) -> String }` (the last two moved unchanged from the presentation copy).
  - `public struct AppPreferences: Equatable, Codable, Sendable { public var launchAtLogin: Bool; public var weeklyScanEnabled: Bool; public var schedule: ScanSchedule; public var problemAlerts: Bool; public var weeklyDigest: Bool; public var lastScheduledRun: Date?; public static let defaults }` defaults: launchAtLogin false, weeklyScanEnabled false, problemAlerts true, weeklyDigest true, lastScheduledRun nil.
  - `public protocol PreferencesStoring: Sendable { func load() async -> AppPreferences; func save(_ p: AppPreferences) async }`
  - `public enum LoginItemStatus: Sendable, Equatable { case enabled, disabled, requiresApproval, unavailable }`; `public protocol LoginItemControlling: Sendable { func status() -> LoginItemStatus; func setEnabled(_ on: Bool) throws -> LoginItemStatus }`
  - `public enum NotificationAuthorization: Sendable, Equatable { case notDetermined, allowed, denied, unavailable }`; `public struct UserNotice: Sendable, Equatable { public let id: String; public let title: String; public let body: String }`; `public protocol NotificationPosting: Sendable { func authorization() async -> NotificationAuthorization; func requestAuthorization() async -> NotificationAuthorization; func post(_ notice: UserNotice) async }`

- [ ] **Step 1: Write the failing tests** (`ScanScheduleTests`, fixed calendar UTC, Gregorian): `slotStart` for Sunday 02:00 with now = Wednesday returns the previous Sunday 02:00; with now = Sunday 01:59 returns the Sunday a week earlier; with now exactly Sunday 02:00 returns that instant. `isDue` is true when lastRun is nil and now is past this week's slot; false when lastRun >= slotStart; true when lastRun is from the previous week and now is past the slot; false before the slot when lastRun is previous week's slot (a run for the current slot is not due yet). A DST test: America/Bogota is fixed, so use America/New_York spring-forward Sunday 02:30 (nonexistent time) and assert `isDue` is true exactly once (true at 03:00 with nil lastRun, false after lastRun = that moment). `clamped()` maps weekday 99 to 7, 0 to 1, hour -5 to 0, minute 75 to 59. `AppPreferences` JSON round-trip with a hard-coded JSON string pins the field names (`launchAtLogin`, `weeklyScanEnabled`, `schedule`, `problemAlerts`, `weeklyDigest`, `lastScheduledRun`); dates use `secondsSince1970`.
- [ ] **Step 2: Run** `scripts/test.sh` and confirm the new tests fail to compile or fail.
- [ ] **Step 3: Implement** the types above; `slotStart` uses `calendar.nextDate(after:matching:matchingPolicy: .nextTime, direction: .backward)` with the weekday/hour/minute components; `isDue` is `lastRun < slotStart` (nil counts as due) and `now >= slotStart`. Remove the old presentation `ScanSchedule`, point its users at the Domain type.
- [ ] **Step 4: Run** `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`; all green.
- [ ] **Step 5: Commit** `feat: preferences, schedule rules and settings ports`.

### Task 2: Data: preferences file, login item, notifications

**Files:**
- Create: `Sources/MainternanceData/Settings/PreferencesStore.swift`, `LoginItemService.swift`, `UserNotificationService.swift`
- Test: `Tests/DataTests/PreferencesStoreTests.swift`, `Tests/DataTests/SettingsServicesTests.swift`

**Interfaces:**
- Consumes: Task 1 ports and types.
- Produces: `public final class PreferencesStore: PreferencesStoring { public init(directory: URL) }` (file `preferences.json` in `directory`); `public struct LoginItemService: LoginItemControlling { public init(isBundled: Bool = Bundle.main.bundleURL.pathExtension == "app") }`; `public final class UserNotificationService: NotificationPosting { public init(isBundled: Bool = Bundle.main.bundleURL.pathExtension == "app") }`.

- [ ] **Step 1: Write the failing tests.** Store (temp directory, never the real Application Support): missing file loads `.defaults`; save then load round-trips including `lastScheduledRun`; bad JSON loads `.defaults`, is moved aside (`preferences.json.damaged`) and a later save writes a fresh file without losing the aside copy; an out-of-range schedule is clamped on load; the file is written atomically and with 0600 permissions; concurrent saves leave a readable file. Services: with `isBundled: false`, `LoginItemService.status()` is `.unavailable` and `setEnabled(true)` throws a `LoginItemError.unavailable` carrying a readable message; `UserNotificationService.authorization()` is `.unavailable`, `post` does nothing and does not crash.
- [ ] **Step 2: Run** the tests; expect failures.
- [ ] **Step 3: Implement** the three types. Login item: `SMAppService.mainApp`, `register()`/`unregister()`, map `.enabled/.notRegistered/.requiresApproval/.notFound`; after a change return the re-read status. Notifications: `UNUserNotificationCenter.current()` only when bundled; `post` builds a `UNMutableNotificationContent` (title, body, default sound off) with `UNNotificationRequest(identifier: notice.id, trigger: nil)`; replacing an id replaces the notification. Preferences: `JSONEncoder` with `dateEncodingStrategy: .secondsSince1970`, sorted keys, `Data.write(options: .atomic)` then `chmod 0600`.
- [ ] **Step 4: Run** tests, lint, boundaries; all green. Check `pgrep -f mainternance-runner-` and that no test touched `~/Library`.
- [ ] **Step 5: Commit** `feat: preferences file, login item and notification services`.

### Task 3: Presentation: live Settings

**Files:**
- Modify: `Sources/MainternancePresentation/Settings/SettingsViewState.swift`, `SettingsView.swift`, `Window/WindowStates.swift`, `Design/SampleDataBadge.swift` (the Settings note and `isSample` for Settings)
- Delete: `Settings/ScanScheduleStore.swift`
- Test: `Tests/PresentationTests/SettingsViewStateTests.swift` (replaces the preview-only tests it supersedes)

**Interfaces:**
- Consumes: `PreferencesStoring`, `LoginItemControlling`, `NotificationPosting`.
- Produces: `@MainActor @Observable public final class SettingsViewState { public init(preferences: any PreferencesStoring, loginItem: any LoginItemControlling, notifications: any NotificationPosting); public private(set) var current: AppPreferences; public private(set) var loginStatus: LoginItemStatus; public private(set) var notificationAuthorization: NotificationAuthorization; public private(set) var message: String?; func load() async; func setLaunchAtLogin(_ on: Bool) async; func setWeeklyScanEnabled(_ on: Bool) async; func setWeekday(_:) async; func setTime(hour:minute:) async; func setProblemAlerts(_ on: Bool) async; func setWeeklyDigest(_ on: Bool) async; public var onChange: (@MainActor (AppPreferences) -> Void)? }`

- [ ] **Step 1: Write the failing tests** with fakes: loading shows saved values; `setLaunchAtLogin(true)` calls the service and the toggle value follows the RETURNED status (`requiresApproval` keeps `launchAtLogin` false in the shown state and sets a message naming System Settings > General > Login Items; a thrown error shows its message and leaves the value false); turning on problem alerts or the weekly digest asks for authorization once when `notDetermined`; denied authorization sets a message saying where to allow notifications and the toggles still save the preference but the view shows the warning; every setter persists through the store and calls `onChange`; out-of-range weekday/hour/minute are clamped; saving does not run concurrently out of order (two quick setters end with the last value on disk).
- [ ] **Step 2: Run** the tests; expect failures.
- [ ] **Step 3: Implement** the state and update the view: remove the "Saved in this preview only" hints and `previewCaption`; add a "Run a quick scan every week" toggle that enables the day/time pickers (disabled when off); the summary line reads "Weekly quick scan, Sunday 02:00. Runs only while Mainternance is open; turn on Launch at login to keep it running."; show `message` and the permission warnings in secondary text. Keep the refresh note. Settings is no longer a sample screen, so drop its sample-data note and badge.
- [ ] **Step 4: Run** tests, lint, boundaries; all green.
- [ ] **Step 5: Commit** `feat: live Settings with saved preferences, login item and notification permission`.

### Task 4: Presentation: the weekly scheduler

**Files:**
- Create: `Sources/MainternancePresentation/Scheduling/ScanScheduler.swift`
- Test: `Tests/PresentationTests/ScanSchedulerTests.swift`

**Interfaces:**
- Consumes: `ScannerViewModel` (`canStartScan`, `startScan(.quick)`, `run`), `AppPreferences`, `PreferencesStoring`.
- Produces: `@MainActor public final class ScanScheduler { public init(scanner: ScannerViewModel, preferences: any PreferencesStoring, now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current); public func update(_ preferences: AppPreferences); public func start(); public func stop(); func tick() async; public private(set) var lastScheduledScanFinished: ScanSummary? }` and a hook `public var onScheduledScanFinished: (@MainActor (ScanSummary) -> Void)?`.

- [ ] **Step 1: Write the failing tests** (fake scanner engine from `ScannerFakes`, injected clock): disabled schedule never scans; due and ready scans once with scope `.quick` and records `lastScheduledRun = now` BEFORE the scan runs (so a crash cannot cause a loop) via the store; a second `tick()` in the same slot does nothing; engine not ready (`canStartScan` false) skips without recording and the next tick retries; a scan already running skips without stacking; a missed run (app opened Wednesday, last run two weeks ago) runs once; the clock moving backwards (time zone/clock change) does not start a scan; `stop()` cancels the timer (no tick after stop); `onScheduledScanFinished` fires with the summary only for scheduled scans, not manual ones.
- [ ] **Step 2: Run** tests; expect failures.
- [ ] **Step 3: Implement.** A `Task` loop sleeping 60 s (and an immediate tick at `start()` and when preferences change); each tick re-reads state on the main actor; `NSWorkspace.didWakeNotification` is wired in the App target (Task 6), which calls `tick()`; the scheduler itself imports only Foundation.
- [ ] **Step 4: Run** tests, lint, boundaries; check for stray tasks/processes.
- [ ] **Step 5: Commit** `feat: weekly quick scan scheduler`.

### Task 5: Presentation: notifications for scan results

**Files:**
- Create: `Sources/MainternancePresentation/Scheduling/ScanNotifier.swift`
- Modify: `Sources/MainternancePresentation/Scanner/ScannerViewModel+Scan.swift` (a `public var onScanCompleted: (@MainActor (ScanSummary, _ manual: Bool) -> Void)?` hook called after a scan is recorded)
- Test: `Tests/PresentationTests/ScanNotifierTests.swift`

**Interfaces:**
- Consumes: `NotificationPosting`, `AppPreferences` (via `update(_:)`), `ScanSummary`.
- Produces: `@MainActor public final class ScanNotifier { public init(notifications: any NotificationPosting); public func update(_ preferences: AppPreferences); public func scanCompleted(_ summary: ScanSummary, scheduled: Bool) async }`

- [ ] **Step 1: Write the failing tests:** with problem alerts on and findings > 0 a notice is posted with id `scan-findings`, title "Mainternance found N file(s) to review", body without any file name; no notice when findings are 0 (that case belongs to the digest only); digest on + scheduled scan posts `weekly-digest` ("Weekly scan finished: nothing found / N files to review", with scanned and unreadable counts, and "some folders could not be read" when unreadable > 0); digest off or manual scan posts no digest; authorization `denied` or `unavailable` posts nothing and does not crash; a cancelled or failed scan (not complete) never says "nothing found".
- [ ] **Step 2: Run** tests; expect failures.
- [ ] **Step 3: Implement** `ScanNotifier` and the `onScanCompleted` hook (called with `manual = true` for scans the scheduler did not start; the scheduler marks its own run through a flag set before `startScan`).
- [ ] **Step 4: Run** tests, lint, boundaries.
- [ ] **Step 5: Commit** `feat: notify about scan findings and the weekly result`.

### Task 6: App wiring, docs, release build

**Files:**
- Modify: `Sources/MainternanceApp/CompositionRoot.swift`, `MainternanceApp.swift`, `README.md`, `docs/STATUS.md`, `docs/testing-the-scanner.md` (a short section on the weekly scan and notifications)

- [ ] **Step 1:** In `CompositionRoot.make()` create `PreferencesStore(directory: <Application Support>/Mainternance)`, `LoginItemService()`, `UserNotificationService()`, the `SettingsViewState`, `ScanScheduler`, `ScanNotifier`; on launch load preferences, push them to scheduler and notifier, wire `SettingsViewState.onChange` to both, wire `scanner.onScanCompleted` and the scheduler hook to the notifier, start the scheduler, call `tick()` on `NSWorkspace.didWakeNotification`, stop the scheduler on `willTerminateNotification`. `WindowStates` receives the settings state.
- [ ] **Step 2:** README "What is live": Settings are real; the weekly scan and notifications are described honestly (quick scan only while the app is open; launch at login needs the app in Applications and may need approval in System Settings; notifications need permission). Update STATUS (remove the stale "PR open" text; list this plan done and the remaining plans).
- [ ] **Step 3:** `scripts/test.sh`, `scripts/lint.sh`, `scripts/check-boundaries.sh`, `scripts/build-app.sh` (no `--install`), `codesign --verify --deep --strict` on the bundle; check `pgrep -f mainternance-runner-`.
- [ ] **Step 4: Commit** `feat: wire schedule, notifications and login item; docs`.
