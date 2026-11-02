# Project status

Last updated: 2026-11-02.

## Shipped on `main`
- Menu bar item and popover plus a main window (Home, Settings) showing **live readings** of this Mac: free disk space (the figure System Settings shows), memory pressure, thermal state, battery (percent, charging, health, cycles), CPU, GPU. Unknown data is shown as unknown, never faked. See `README.md` ("What is live").
- Build, sign and install scripts (`scripts/build-app.sh`, `scripts/make-signing-cert.sh`), CI, SonarCloud and CodeRabbit.

## In progress: malware scanner (branch `feat/scanner-engine`, plan `docs/superpowers/plans/2026-10-29-scanner-engine.md`)
The scanner is built: Tasks 1-8 are implemented and reviewed (locator, runner, installer, scan runner, quarantine, Scanner screen, Home status, docs). Pull request #3 is open and going through CI, SonarCloud and CodeRabbit. Still pending: the first check with real ClamAV (below). Ask the owner before merging or installing.
Not started (separate plans): file explorer, cleanup, startup items, uninstaller, notifications, launch at login, weekly scheduling.

## Rules that apply to all remaining work
- Nothing is deleted automatically: quarantine moves a file only after the user confirms, and it can always be restored. No permanent delete.
- ClamAV is installed through Homebrew from inside the app; the app keeps its own config and virus database in `~/Library/Application Support/Mainternance/ClamAV` and never edits Homebrew's files.
- Anything that is not real must say so in the UI, or stay hidden.

## Needs a human (cannot be verified without a screen)
- Popover: after "Open Mainternance" the popover closes, the window stays open, and one click on the menu bar icon reopens it without leaving the icon highlighted.
- App CPU in Activity Monitor stays near 0% with the popover and window closed.
- First real scanner run with real ClamAV (not done yet): Install button, Update definitions, the harmless EICAR test file (see `docs/testing-the-scanner.md`).
