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

## Install

Mainternance is a menu bar app: there is no Dock icon. Click the shield in the menu bar, then
choose Open Mainternance to show the window.

- `scripts/build-app.sh` builds a release binary and assembles and signs
  `~/Library/Caches/mainternance/dist/Mainternance.app` (outside the repo).
- `scripts/build-app.sh --install` does the same and also copies the app to `/Applications`.
- Without a signing identity the app is signed ad-hoc, and macOS may reset granted permissions after
  every rebuild. Run `scripts/make-signing-cert.sh` once to create the stable self-signed identity
  `Mainternance Local Signing` in your login keychain (it asks for your password once; use `--dry-run`
  to preview). Later builds pick it up automatically.
- To open it at login, add it under System Settings > General > Login Items. A later plan adds a
  Settings toggle wired to the system.
- Full Disk Access is not needed yet; it is granted later, in the scanner plan.

## Building

Build products go out-of-tree because an iCloud-synced Desktop corrupts in-repo `.build` output.
`scripts/test.sh` uses `$MAINTERNANCE_BUILD_DIR`, defaulting to `~/Library/Caches/mainternance/build`.
Use the same location for manual builds: `swift build --scratch-path ~/Library/Caches/mainternance/build`.

## Tooling

CI (GitHub Actions, `.github/workflows/ci.yml`) runs lint, the layer-boundary check, build and tests
on every push and pull request to `main`, then a SonarCloud scan. Actions are pinned to commit SHAs.
Code coverage is collected by `swift test` but is not reported to SonarCloud, which does not import
Swift coverage natively. CodeRabbit reviews pull requests using `.coderabbit.yaml`.
