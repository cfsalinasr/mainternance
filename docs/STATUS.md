# Project status

Last updated: 2026-11-04.

## Shipped on `main`
- Menu bar item and popover plus a main window (Home, Settings) showing **live readings** of this Mac: free disk space (the figure System Settings shows), memory pressure, thermal state, battery (percent, charging, health, cycles), CPU, GPU. Unknown data is shown as unknown, never faked. See `README.md` ("What is live").
- Malware scanner (PR #3): ClamAV installed through Homebrew from the app, quick/full/folder scans, quarantine and restore, status on Home.
- Settings, weekly scan and notifications (plan `2026-11-02-schedule-notifications-settings.md`): merged to `main`. Live Settings saved to `preferences.json`, Launch at login through macOS, an opt-in weekly quick scan that runs only while the app is open (a missed slot runs once later; also checked on wake), and notifications with counts only, never file names.
- Startup (plan `2026-11-02-startup-items.md`): merged to `main`. Real list of launch agents and daemons with launchd state, Reveal in Finder, switching your own agents off and on, "New" badges and the count on Home.
- Cleanup (plan `2026-11-03-cleanup.md`): merged to `main`. Measures caches, logs, old installers and Xcode build caches, review sheet, move to the Trash (never a permanent delete), Home suggestion.
- Build, sign and install scripts (`scripts/build-app.sh`, `scripts/make-signing-cert.sh`), CI, SonarCloud and CodeRabbit.
- Uninstaller (plan `2026-11-03-uninstaller.md`): merged to `main` (PR #7). Moves an app and its leftovers to the Trash after review (never permanent). Leftovers are found by exact identifier or name in fixed `~/Library` folders, so some can be missed or over-matched; name-only ones and launch agents are unticked. Apple's apps (bundle identifier starting com.apple.) are not listed. Apps in `/Applications` may need an administrator password.
- Files (plan `2026-11-04-file-explorer.md`): merged to `main` (PR #8). Spotlight search with type, size and date filters; large files with a treemap of disk use; duplicates by size, then partial hash, then full SHA-256. Home folder only; never `~/Library`, hidden folders, links or other disks. Quick Look, Reveal in Finder, and moves to the Trash after review (never permanent), with a keep-one rule so a duplicate group never loses its last copy. The sample-data markers and Home's "Coming next" line are gone because every screen is real.

## Remaining plans
- None.

## Rules that apply to all remaining work
- Nothing is deleted automatically: quarantine moves a file only after the user confirms, and it can always be restored. No permanent delete.
- ClamAV is installed through Homebrew from inside the app; the app keeps its own config and virus database in `~/Library/Application Support/Mainternance/ClamAV` and never edits Homebrew's files.
- Anything that is not real must say so in the UI, or stay hidden.

## Known limits (accepted, not bugs to hide)
- Files: a file that has other hard links frees nothing when moved, but "freed" still counts its size. APFS clones can free less than shown too.
- Files: if a file becomes iCloud-only (stored online) in the moment between the duplicate scan listing it and reading it, opening it may start a download. Files already iCloud-only when scanned are skipped.
- Files: Spotlight search lists files only (no folders), and Spotlight may not have indexed everything.
- Uninstaller: a running app with no bundle identifier can still be moved.

## Needs a human (cannot be verified without a screen)
- Popover: after "Open Mainternance" the popover closes, the window stays open, and one click on the menu bar icon reopens it without leaving the icon highlighted.
- App CPU in Activity Monitor stays near 0% with the popover and window closed.
- Launch at login from `/Applications`, including the approval step in System Settings > General > Login Items.
- Cleanup: run it on a real Mac, move a few caches, then look in the Trash (they are there and Put Back restores them), and check Home's suggestion.
- Cleanup and links: the real `FileManager.trashItem` is never run by the automated tests (they use a fake Trash), so its handling of links rests on this check only. Put a link in `~/Library/Caches` that points to a folder elsewhere, move it with Cleanup, and confirm the Trash holds the link while the folder it pointed to is untouched.
- Uninstaller: uninstall a throwaway app on a real Mac with the app in `/Applications` and look in the Trash (the app and its ticked leftovers are there), including the administrator-password case, and check that Put Back restores it. The real `FileManager.trashItem` is never run by the automated tests.
- Startup: switching one of your own agents off, logging out and in, and checking it no longer starts (then switching it back on).
- Notifications: the permission prompt, then a weekly scan set a few minutes ahead (see `docs/testing-the-scanner.md`).
- First real scanner run with real ClamAV (not done yet): Install button, Update definitions, the harmless EICAR test file (see `docs/testing-the-scanner.md`).
- Files, search: a real Spotlight search finds a file you know exists. Also try the text `x" || kMDItemFSSize > 0 || "y`, `*` and `?` and confirm they behave as plain text (no error, no odd matches).
- Files, large files: a real scan and treemap on the home folder. Note how long it takes, whether the app stays responsive, and watch its memory in Activity Monitor.
- Files, duplicates: a scan with a planted duplicate pair (two identical files of 1 MB or more) finds exactly that pair.
- Files: Quick Look and Reveal in Finder from a row.
- Files, Trash: a real move of a single file and of a duplicate, then Put Back in Finder. The real `FileManager.trashItem` is never run by the automated tests.
- Files, packages: check that moving a file inside a package folder (for example inside an `.app` or a Photos library) is refused, and that search does not list files inside packages.
- Files, privacy: the prompts for Desktop, Documents and Downloads, and the "folders could not be read" note when you decline.
- Uninstaller, known limit: a running app with no bundle identifier can still be moved by the Uninstaller. Check what happens.
