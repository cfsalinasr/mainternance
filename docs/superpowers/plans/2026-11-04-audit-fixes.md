# Audit fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Fix the High and Medium findings of the 2026-11-04 whole-app audit, with tests, so the app does not claim or do anything untrue before the owner's QA.

**Architecture:** Existing layers and patterns only (Domain / Data / Presentation / App; Presentation never imports Data; no logic in views or the App target). No new dependencies.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM, Swift Testing, built with scripts/test.sh, lint.sh, check-boundaries.sh.

**Spec:** The audit reports (read them for file:line, scenarios and suggested fixes; they are the requirements):
- /private/tmp/claude-501/-Users-cristiansalinas-Desktop-mainternance/7b58e81d-ba88-44d6-9512-a1dd8d666294/scratchpad/audit-scanner.md
- .../audit-moves.md, .../audit-quality.md, .../audit-ui.md (same folder)

## Global Constraints
- Nothing is deleted permanently; Trash only. Anything not real must say so in the UI. Plain-language UI text. Notifications carry counts only, never file names.
- Never run code against the real home folder, ~/Library, /Applications or the Trash; tests use temp folders and fakes. Do not run brew/freshclam.
- Keep: lint 0 issues, boundaries clean, every new behavior has a test, SwiftLint/Sonar rules (no hard-coded paths S1075, no empty closures, closure nesting <= 2, init <= 7 params).
- Commit per task with message ending: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus
Each task's tests must pin the audit's failure scenario, not just the happy path.

### Task 1: Scanner results never claim more than was scanned
Audit: scanner H2, M1, M4, L3. 
- `--alert-exceeds-max=yes` passed to clamscan; "limits exceeded" output lines are parsed as a separate "skipped, too large" result (never a threat); they count as not scanned so the result is not "complete" and never shows the green "No threats found"; verify (re-check before quarantine) treats limits-exceeded as failed, never clean.
- Unreadable folders ("Can't open directory") are counted separately from files and worded as folders and everything in them.
- iCloud: best-effort stop clamscan from downloading dataless files (setiopolicy_np materialize-off applied so the child inherits it; if it cannot be proven by a test, still apply it) AND make the Scanner screen text truthful: say Desktop and Documents may include iCloud files and that evicted ones may be downloaded unless skipped; do not claim iCloud is skipped for scopes where it is not.
- Scanner UI shows file names through DisplayText.clean (keep the raw path for actions).

### Task 2: Weekly scan really runs, notifies, and the UI knows when it is next
Audit: scanner H1, M2, M3; ui H1, M1.
- ScanScheduler refreshes engine status (scanner.refreshStatus or a lighter status call) at the start of every due tick before checking canStartScan; also refresh once at launch. Test with a rig that does NOT prime the engine.
- A scan that started but ended `.failed` calls a failure callback; notify "The weekly scan could not finish" (counts only, no messages/paths). A scheduled scan that fails before `.started` gives the slot back.
- Before a scheduled scan, if definitions are older than 7 days try updateDefinitions(); if still stale or failing, the digest says the definitions are N days old and never uses the "nothing found" wording.
- `ScanStatus.nextScan` is computed from preferences with ScanSchedule when weeklyScanEnabled (nil when off); Home and popover say "Weekly scan off" (not "Not scheduled") when disabled. Test: enabled means non-nil.
- Popover scan rows are built from the same health-report checks as Home (last-scan reason/state incl. unreadable results and unfinished scans, plus a Findings row).

### Task 3: Cleanup and Files cannot trap the owner
Audit: moves M1, M2, L-items cheap ones; ui M2, M3; quality L (hidden files).
- ProtectedPaths: a candidate that is an ancestor of the running bundle is protected (also for extra trees); refusal text "It holds Mainternance itself." (Cleanup and Uninstaller refusal enums). The CleanupMeasurer should not list such an entry. Test with a bundle path injected.
- Cleanup keeps the owner's unticks across re-measuring (store unticked ids; new ids get defaults); toggling during measuring is not lost; a new measuring after a move clears the old result card.
- Cleanup refuses an item with no recorded identity (like the other movers).
- Home's cleanup suggestion uses the default-selected total and mentions installers separately.
- "Moved 0 items" never appears next to "Nothing was moved".
- Large files and Duplicates skip hidden (dot) files like Search does; consistent rule in FileWalker/DuplicateFinder.

### Task 4: Saved data failures are never silent
Audit: quality M1, M2, M3, M4; scanner M5.
- Preferences: a failed write returns/throws failure; Settings shows a plain note ("Your setting could not be saved") through the existing notes list; a read error no longer disables saving for the whole session (retry the read, clear the flag on success); lastScheduledRun failure handled likewise.
- Quarantine: records()/stillInPlace()/unclaimedFiles() can report "unreadable"; Scanner screen shows a plain note ("The quarantine list could not be read; nothing in it was changed") instead of hiding the section.
- Startup "New": baseline key includes label + plist path + program (hash of Program/ProgramArguments); changed items show as "Changed since your last review" (or New) and count on Home. Migrate old baselines sensibly (existing reviewed labels keep working until their program changes is NOT acceptable; ruling: old baselines are treated as reviewed once and upgraded to the new key on first sight of an unchanged item).
- Integration test of the real FileManager.trashItem on a temporary disk image (hdiutil, mounted in a temp dir with -nobrowse, never the user's Trash): a link is moved as the link, its target untouched; skip the test gracefully if hdiutil/attach fails; detach always. Merge the two duplicate moveToTrash helpers into one.
- Fix the fake-sleeper race in Tests/PresentationTests/Fixtures.swift (register and suspend atomically or record released ids; bound waitForSleeps).
