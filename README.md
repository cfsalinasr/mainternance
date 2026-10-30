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

Only part of the app reads your Mac today. The rest shows sample data and says so.

**Live readings of this Mac** (Overview, popover and menu bar):

- Free disk space, the "important usage" figure that System Settings shows (it counts purgeable space).
- Memory pressure and thermal state.
- Battery: percent, charging, health and cycle count. Absent on Macs without a battery.
- CPU usage. It needs two samples, so it appears a couple of seconds after the first reading; the first
  value averages the time since the last reading.
- GPU utilization, when the Mac reports it.

Readings are refreshed about every 2 s while the popover or window is open and about every 45 s
otherwise; both intervals are doubled in Low Power Mode.

**Not available** (shown as unknown, never as a made-up value): temperatures (no public source on Apple
silicon), the startup-item count, macOS update status, scanner status and suggestions.

**Sample data**, labelled "Sample data" in the app and not connected to your Mac yet: Files, Scanner,
Cleanup, Startup and Uninstaller. Settings are not applied yet either.

Later plans replace these one by one: the cleanup, startup and uninstaller backends; the file explorer;
the ClamAV scanner and quarantine; notifications, launch at login and scheduling.

## Install

Mainternance is a menu bar app: there is no Dock icon. Click the shield in the menu bar to see the
popover with the live readings, then choose Open Mainternance to show the window. Several window
sections show sample data (see What is live).

- `scripts/build-app.sh` builds a release binary and assembles and signs
  `~/Library/Caches/mainternance/dist/Mainternance.app` (outside the repo).
- `scripts/build-app.sh --install` does the same and also copies the app to `/Applications`.
- Without a signing identity the app is signed ad-hoc, and macOS may reset granted permissions after
  every rebuild. Run `scripts/make-signing-cert.sh` once to create the stable self-signed identity
  `Mainternance Local Signing` in your login keychain (it asks for your password once; use `--dry-run`
  to preview). Later builds pick it up automatically.
- To open it at login, add it under System Settings > General > Login Items. The Settings toggle is sample
  data for now; a later plan wires it to the system.
- Full Disk Access is not needed yet; it is granted later, in the scanner plan.

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
