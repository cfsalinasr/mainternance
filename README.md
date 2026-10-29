# Mainternance

A native macOS app (Swift, SwiftUI) built with a clean architecture: `MainternanceDomain`
(pure Foundation), `MainternanceData` and `MainternancePresentation` (both depend on Domain),
and the `MainternanceApp` executable that wires them together.

## Development

- Run tests: `scripts/test.sh` (adds the Swift Testing flag needed with Command Line Tools only)
- Check layer boundaries: `scripts/check-boundaries.sh`
- Build the `.app` bundle: `scripts/build-app.sh` (coming in Task 12)
