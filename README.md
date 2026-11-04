# Mainternance

[![CI](https://github.com/cfsalinasr/mainternance/actions/workflows/ci.yml/badge.svg)](https://github.com/cfsalinasr/mainternance/actions/workflows/ci.yml)
[![Quality Gate](https://sonarcloud.io/api/project_badges/measure?project=cfsalinasr_mainternance&metric=alert_status)](https://sonarcloud.io/project/overview?id=cfsalinasr_mainternance)

A native macOS app (Swift, SwiftUI) built with a clean architecture: `MainternanceDomain`
(pure Foundation), `MainternanceData` and `MainternancePresentation` (both depend on Domain),
and the `MainternanceApp` executable that wires them together.

## Development

- Run tests: `scripts/test.sh` (adds the Swift Testing flag needed with Command Line Tools only)
- Lint: `scripts/lint.sh` (SwiftLint strict, then SwiftFormat lint)
- Check layer boundaries: `scripts/check-boundaries.sh`
- Build and sign the `.app` bundle: `scripts/build-app.sh` (see Install)

## What is live

Only part of the app reads your Mac today. Screens that are not backed by a working engine are hidden.

**Live readings of this Mac** (Overview, popover and menu bar):

- Free disk space, the "important usage" figure that System Settings shows (it counts purgeable space).
- Memory pressure and thermal state.
- Battery: percent, charging, health and cycle count. Absent on Macs without a battery.
- CPU usage. It needs two samples, so it appears a couple of seconds after the first reading; the first
  value averages the time since the last reading.
- GPU utilization, when the Mac reports it.

Readings are refreshed about every 2 s while the popover or window is open and about every 45 s
otherwise; both intervals are doubled in Low Power Mode.

**Malware scanner** (Scanner screen, and its status on Home):

- On-demand scans (quick, full or a folder you choose) with ClamAV, which the app installs for you through
  Homebrew (Homebrew must already be installed). The app keeps its own config and virus database in
  `~/Library/Application Support/Mainternance/ClamAV` and never edits Homebrew's files.
- It matches known signatures only. There is **no real-time protection**: nothing is checked unless you run a scan.
- Nothing is deleted. Quarantine moves a file only after you confirm, and Restore puts it back. There is no
  permanent delete in the app.
- Without Full Disk Access some folders cannot be read; the app says so and keeps any detection it could not
  re-check until a scan has covered it.
- To try it safely, see `docs/testing-the-scanner.md`.

**Settings** (saved in `~/Library/Application Support/Mainternance/preferences.json`):

- Weekly quick scan: off until you turn it on. You pick the day and time. It runs **only while Mainternance
  is open**; if the Mac was asleep or the app was closed at that time, it runs once, the next time Mainternance
  runs (it checks about once a minute and when the Mac wakes). Turning it on, or changing the day or time, never
  starts a scan right away: the new time counts from the next time it comes round. When the scanner is not ready
  at that moment (ClamAV not installed, or a scan, install or quarantine already working) the weekly scan is
  skipped without a notification and tried again at the next check.
- Launch at login: the toggle shows what macOS reports. It works when the app runs from `/Applications`. If
  macOS needs your approval the toggle shows on with a note: approve it in System Settings > General > Login
  Items (the note goes away when you come back to the app), or turn the toggle off to withdraw the request.
- Notifications: "Problem alerts" (a scan found something to review) and "Weekly digest" (the result, when a
  weekly scan finishes). Both start on, but nothing is shown until you allow notifications: while macOS has never
  asked, Settings shows "Allow notifications to receive these" with an Allow Notifications button (macOS also asks
  when you turn a toggle on). Mainternance never asks by itself in the background. If you refused, Settings says
  to allow them in System Settings > Notifications > Mainternance. They carry counts only, never file names: files
  to review, "detections" for findings that could not be tied to a file, and how many files could not be read.
  Nothing is posted when the scanner was not ready or the scan failed before it produced a result.
- Known limits of the weekly scan and notifications: while Mainternance is the app in front, macOS may not show
  its notification banners (the app does not yet ask macOS to show them in the foreground); macOS may delay the
  once-a-minute check while the app sits idle in the background (App Nap), so a scan can start a little after
  the chosen time.

**Startup** (Startup screen, and the "Startup items" check on Home):

- Lists the launch agents and daemons that start programs on this Mac: your own agents
  (`~/Library/LaunchAgents`), agents for all users (`/Library/LaunchAgents`) and system daemons
  (`/Library/LaunchDaemons`). Each row says what is registered and by which file, whether launchd has it on or off
  ("Unknown" when that cannot be read), and offers Reveal in Finder. A file that cannot be read is listed as such,
  never hidden. The app makes no "safe" or "suspicious" judgement.
- Only your own agents can be switched off and on (`launchctl disable`/`enable` for your user: reversible, no
  administrator, nothing deleted or moved). The change **takes effect at your next login**. Agents for all users
  and daemons are installed for all users and are read-only here by design: Mainternance only switches your own
  agents. When launchd has no setting of its own for an item, its file's `Disabled` key decides (On unless it
  says `true`).
- Login items you added in System Settings > General > Login Items are managed by macOS and are **not listed**:
  an app cannot read them.
- "New" means not present when you last chose Mark all as reviewed. The first time the screen opens it only
  records what is there (nothing counts as new yet). The list of reviewed items is kept in
  `~/Library/Application Support/Mainternance/startup-review.json`. Home shows the number of new items once that
  list exists, and nothing (rather than "0") before; it reads the files at most once a minute, and again right
  after the Startup screen lists or marks as reviewed. If the list cannot be saved, the screen says so and
  Mark all as reviewed is off.

**Cleanup** (Cleanup screen, and its suggestion on Home):

- Measures four fixed places in your home folder, and nothing else: **Caches** (each item in `~/Library/Caches`),
  **Logs** (each item in `~/Library/Logs`), **Old installers** (`.dmg`, `.pkg` and `.iso` files directly in
  `~/Downloads` not changed or added for more than 30 days: the newest of the modified, created and "date added"
  dates counts) and **Developer build caches** (each item in Xcode's
  `~/Library/Developer/Xcode/DerivedData`, shown only when that folder exists). No system files, no documents, no
  browser profiles, and it never empties the Trash.
- Measuring starts when you open the screen (never at launch) and only reads. Sizes are the space the items take on
  disk, shown as "about"; "at least" when part of an item could not be read. Links are never followed: a link
  counts, and moves, as the link itself.
- Caches, logs and developer build caches start ticked; old installers are never selected until you tick them.
  Nothing moves until you choose Review, check the list (you can tick or untick single items) and click Move to
  Trash. A list older than 5 minutes is not cleaned: the screen asks you to measure again first. Leaving the
  screen while it measures drops that measuring; the previous list stays. Items **move to the Trash, never a permanent delete**: Finder's Put Back
  restores them, and the space comes back only when you empty the Trash yourself.
- Each item is checked again just before it moves: it must still be directly inside its folder (the same folder on
  disk as when the move started), not in a protected place (a link to a protected place is left alone too), and
  the very item that was measured, of the same kind. An item that cannot move (for example a cache an open app is using)
  is listed with the reason and the rest continue; only what really moved is counted. Quit apps before cleaning
  their caches.
- Home suggests "Free about N GB in Cleanup" once the Cleanup screen has measured (nothing before) and the total
  is at least 500 MB. Afterwards it measures again in the background at most every 10 minutes, only while Home is on
  screen in the window and never in Low Power Mode (at low priority; leaving Home stops it), and updates at once
  whenever the Cleanup screen measures or moves items.

**Uninstaller** (Uninstaller screen):

- Lists the apps directly inside `/Applications` and `~/Applications` (not deeper folders). macOS's own apps
  (bundle identifier starting `com.apple.`) and Mainternance itself are not listed. The list loads when you open
  the screen, never at launch.
- Choosing an app measures it and looks for its leftovers in a fixed set of `~/Library` folders (Application
  Support, Caches, Containers, Group Containers, Preferences, Saved Application State, HTTPStorages, WebKit,
  Cookies, Logs, LaunchAgents). A leftover is found by **exact** identifier or exact name, never by "contains".
  This can **miss** leftovers and can **over-match**: review the list. Leftovers matched by name only are
  unticked and labelled so; launch agents are unticked too, and the screen says to switch them off in Startup first.
- Nothing is permanently deleted. After you review, the app and the ticked leftovers **move to the Trash**; Put
  Back restores them, and space comes back only when you empty the Trash. The app moves first: if it cannot move
  (it is running, or macOS refuses), its leftovers stay where they are. A running app is refused: quit it first.
- Apps in `/Applications` may need an administrator password; if macOS refuses, the screen says so per item and
  nothing is retried.
- Sizes are "about"; "freed" counts only what really moved.

**Not available** (shown as unknown, never as a made-up value): temperatures (no public source on Apple
silicon) and macOS update status.

**Planned, not available yet** (hidden in the app until each one works; Home lists them under
"Coming next"):

- File explorer

Later plans bring these back one by one.

## Install

Mainternance is a menu bar app: there is no Dock icon. Click the shield in the menu bar to see the
popover with the live readings, then choose Open Mainternance to show the window, which has Home, Cleanup,
Scanner, Startup, Uninstaller and Settings (see What is live).

- `scripts/build-app.sh` builds a release binary and assembles and signs
  `~/Library/Caches/mainternance/dist/Mainternance.app` (outside the repo).
- `scripts/build-app.sh --install` does the same and also copies the app to `/Applications`.
- Without a signing identity the app is signed ad-hoc, and macOS may reset granted permissions after
  every rebuild. Run `scripts/make-signing-cert.sh` once to create the stable self-signed identity
  `Mainternance Local Signing` in your login keychain (it asks for your password once; use `--dry-run`
  to preview). Later builds pick it up automatically.
- To open it at login, turn on Launch at login in Settings (install it with `--install` first, so it runs from
  `/Applications`). If macOS asks, approve it in System Settings > General > Login Items.
- Full Disk Access is optional: grant it under System Settings > Privacy & Security if you want scans to read
  protected folders (see `docs/testing-the-scanner.md`).

## Building

Build products go out-of-tree because an iCloud-synced Desktop corrupts in-repo `.build` output.
`$MAINTERNANCE_BUILD_DIR` is the cache root (default `~/Library/Caches/mainternance`); the scripts use
`build/`, `dist/` and `icon/` under it. For manual builds use
`swift build --scratch-path ~/Library/Caches/mainternance/build`.

## Tooling

CI (GitHub Actions, `.github/workflows/ci.yml`) runs lint, the layer-boundary check, build and tests
on every push and pull request to `main`, then a SonarCloud scan. Actions are pinned to commit SHAs.
Code coverage is collected by `scripts/test.sh --enable-code-coverage` and converted to SonarCloud's generic format by
`scripts/coverage-to-sonar.sh` (writes the untracked `coverage.xml`); SwiftUI views and the app target are excluded
by design in `sonar-project.properties`. CodeRabbit reviews pull requests using `.coderabbit.yaml`.
