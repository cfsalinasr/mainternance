# Mainternance

A native macOS app (Swift, SwiftUI) built with a clean architecture: `MainternanceDomain`
(pure Foundation), `MainternanceData` and `MainternancePresentation` (both depend on Domain),
and the `MainternanceApp` executable that wires them together.

## Development

- Run tests: `scripts/test.sh` (adds the Swift Testing flag needed with Command Line Tools only)
- Lint: `scripts/lint.sh` (SwiftLint strict, then SwiftFormat lint)
- Check layer boundaries: `scripts/check-boundaries.sh`
- Build the `.app` bundle: `scripts/build-app.sh` (coming in Task 12)

## Building

Build products go out-of-tree because an iCloud-synced Desktop corrupts in-repo `.build` output.
`scripts/test.sh` uses `$MAINTERNANCE_BUILD_DIR`, defaulting to `~/Library/Caches/mainternance/build`.
Use the same location for manual builds: `swift build --scratch-path ~/Library/Caches/mainternance/build`.
