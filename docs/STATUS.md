# Project status

Last updated: 2026-10-30 (work paused; resumes in the next session).

## Shipped on `main`
- Menu bar item and popover plus a main window (Home, Settings) showing **live readings** of this Mac: free disk space (the figure System Settings shows), memory pressure, thermal state, battery (percent, charging, health, cycles), CPU, GPU. Unknown data is shown as unknown, never faked. See `README.md` ("What is live").
- Build, sign and install scripts (`scripts/build-app.sh`, `scripts/make-signing-cert.sh`), CI, SonarCloud and CodeRabbit.

## In progress: malware scanner (branch `feat/scanner-engine`, plan `docs/superpowers/plans/2026-10-29-scanner-engine.md`)
Done and reviewed: hiding the screens that are not real (Task 1), scanner domain types (2), tool locator and safe process runner (3), ClamAV installer and definitions store (4).
Implemented, re-review pending: scan runner, output parser, per-finding re-verification, exclusions, fail-closed handling of dropped detections (5).
To do: quarantine store (6), the real Scanner screen and Home status (7), documentation and release build (8). Then a pull request through CI, SonarCloud and CodeRabbit.
Not started (separate plans): file explorer, cleanup, startup items, uninstaller, notifications, launch at login, weekly scheduling.

## Rules that apply to all remaining work
- Nothing is deleted automatically: quarantine moves a file only after the user confirms, and it can always be restored. No permanent delete.
- ClamAV is installed through Homebrew from inside the app; the app keeps its own config and virus database in `~/Library/Application Support/Mainternance/ClamAV` and never edits Homebrew's files.
- Anything that is not real must say so in the UI, or stay hidden.

## Needs a human (cannot be verified without a screen)
- Popover: after "Open Mainternance" the popover closes, the window stays open, and one click on the menu bar icon reopens it without leaving the icon highlighted.
- App CPU in Activity Monitor stays near 0% with the popover and window closed.
- First real scanner run once Task 7 lands: Install button, Update definitions, the harmless EICAR test file (see `docs/testing-the-scanner.md`, written in Task 8).
