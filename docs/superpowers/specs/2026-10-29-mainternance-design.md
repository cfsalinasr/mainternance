# Mainternance: design

A personal macOS maintenance app for one person's laptop. It lives in the menu bar, has a full window, launches at login, and keeps the Mac healthy: system health at a glance, junk cleanup, a dynamic file explorer (search, duplicates, large files), startup item and app management, and a malware scanner that runs weekly.

Decisions the user made are stated as decisions. Anything marked **(my call)** was chosen by the builder and has not been confirmed.

## Intent and why

The user wants the useful parts of tools like CleanMyMac without the cost, and wants the malware scanner most of all. It is only for their own laptop, so there is no distribution, no App Store, and no multi-user concern. The app should feel native to the newest macOS and be cheap to run: it must never be the reason the machine is slow.

## Goals

- Menu bar item: an icon colored by health plus one short value (free disk space). A popover shows the details.
- Full window: Home, Cleanup, Files, Scanner, Startup, Uninstaller, Settings.
- Home screen is attention-first (chosen from two mockups): a health banner with reasons, metric tiles, suggested actions, last and next scan, and a collapsed Details section with CPU, GPU and RAM sparklines. The approved visual reference is `.superpowers/brainstorm/*/content/home-layout-v2-icons.html`, modeled on the macOS Weather popover.
- Native macOS look using system materials and SF Symbols. Glass is used for chrome only; data-heavy areas use solid surfaces.
- Dynamic file explorer with instant search, duplicate finder and large-file finder.
- Weekly scheduled malware scan, with catch-up if the Mac was off.
- Local push notifications when the app flags a problem, each deep-linking to the fix.
- Ships as a double-clickable `.app` in `/Applications`, launching at login.

## Non-goals

- Real-time (on-access) protection. It needs Apple's Endpoint Security entitlement, which is impractical here.
- App Store distribution, notarization, public releases, auto-update.
- Matching commercial antivirus on new or behavioral threats. The scanner is a second opinion beside XProtect and Gatekeeper.
- Windows or Intel-specific support.

## Anti-goals (a failure even if it technically works)

- An opaque numeric "health score". Health is three states with explicit, clickable reasons.
- Anything that deletes without a preview, or that deletes permanently. Everything goes to Trash or quarantine.
- Noticeable background CPU, memory or battery use.
- Notification fatigue.

## Health model

States: **Good**, **Needs attention** (amber), **Problem** (red). Computed from concrete checks, each shown with its reason and a link to the fix:

- disk free space
- memory pressure (not percent used)
- thermal state (`ProcessInfo.thermalState`, a public API)
- battery health (max capacity, cycle count)
- startup items (new since last review)
- last scan age
- macOS update available
- unresolved scanner findings

Temperature and GPU utilization have no supported API on Apple Silicon. They are best-effort extras that hide themselves if the reading fails, and they never drive the health state.

## Performance rules (user's decision)

- While the popover or window is visible: sample every 1-2 seconds.
- While hidden: refresh every 30-60 seconds, only the values the menu bar item needs.
- **(my call)** Pause or slow heavy work (scans, indexing, duplicate hashing) in Low Power Mode and on low battery. Run heavy work at utility or background priority.
- No timers that tick when nothing is visible and nothing is due.

## Notifications

The user wants push notifications when the app flags a problem. These are local macOS notifications; no server is involved.

- **(my call)** Interrupting notifications only for **Problem** state and malware findings. **Needs attention** items go into a weekly digest, so amber flags don't train the user to ignore the app.
- **(my call)** De-duplicate and use a cooldown per issue, and require a condition to be sustained before alerting (for example a process pinned at high CPU for several minutes, not a single spike).
- Clicking a notification opens the relevant screen.

## Malware scanner

- Wraps **ClamAV** (open source) for signature scanning, with scheduled and on-demand scans and a quarantine view.
- Mac-specific checks on top: suspicious launch agents and daemons (the common persistence trick), code-signature and notarization validation, known adware and browser-hijacker locations, and optional hash lookups against VirusTotal (needs the user's API key).
- Weekly schedule while the app runs as a login item, configurable, with catch-up after missed runs.
- ClamAV comes from Homebrew (user's decision; Homebrew is already installed at `/opt/homebrew`, ClamAV is not). The user never touches a terminal: the Scanner screen detects a missing engine, offers an **Install** button that runs `brew install clamav` with progress shown in the app, writes a `freshclam.conf`, and runs `freshclam` for the first definitions download (about 300 MB). `clamscan` runs as a low-priority child process with live progress parsed from its output; `freshclam` runs before each scheduled scan. Bundling is a possible later change, not part of this build. The `clamd` daemon is not used, to keep memory use low.
- **(my call, needs confirmation)** Findings are never deleted automatically. Quarantine moves the file after the user confirms; restore is always possible.

## File explorer

- Instant search through Spotlight (`NSMetadataQuery`), with filters for type, size and date.
- Large files: live, sorted list plus a treemap or sunburst of disk usage with drill-down.
- Duplicates: group by size, then partial hash (head and tail), then full-hash confirmation. Skip hard links and APFS clones. Results stream into the UI as they arrive; scans are cancellable.
- Actions: Quick Look, reveal in Finder, move to Trash, and "keep one" rules (newest, oldest, shortest path).

## Cleanup, startup items, uninstaller

- Cleanup: caches, logs, temp files, old installers, Xcode and developer caches. Preview first, then Trash. A protected-paths guard makes certain locations impossible to touch, and has its own tests.
- Startup: list and toggle login items, launch agents and daemons, flag new ones.
- Uninstaller: remove an app plus its leftovers, previewed first.

## Architecture

Clean architecture in Swift Package modules, so the compiler enforces the boundaries:

- **Domain**: entities, use cases, repository protocols. No UI or system-API imports.
- **Data**: implementations: system metrics, file scanning, ClamAV wrapper, launch-agent inspector, protected-paths guard.
- **Presentation**: SwiftUI views and view models (MVVM). Depends on Domain only.
- **App**: composition root and wiring.

The UI is built first against fake implementations of the Domain protocols, then real ones replace them.

## Platform and distribution

- Swift and SwiftUI, targeting the current macOS (**my call**: latest only, since it runs on one machine).
- Not sandboxed; needs Full Disk Access (granted once) and notification permission.
- Signed with the user's free personal Apple ID team so the Full Disk Access grant survives rebuilds. Build, then copy to `/Applications`.
- Launch at login via `SMAppService`, with a Settings toggle.

## Tooling and repo

- Public GitHub repo `cfsalinasr/mainternance`, created with the already-authenticated `gh`.
- SwiftLint, SwiftFormat, strict concurrency, unit tests on Domain, safety tests for the deletion guards.
- GitHub Actions CI on a macOS runner (free for public repos): build, lint, test, then SonarCloud scan (project key `cfsalinasr_mainternance`, org `cfsalinasr`, `SONAR_TOKEN` as a repo secret). Swift coverage import needs a conversion step and is to be verified when wiring up.
- CodeRabbit as a GitHub App with a `.coderabbit.yaml` whose `path_instructions` enforce the layer rules, modeled on the one in `spps-assistant`.
- `.superpowers/` goes in `.gitignore`.

## Build order

1. Repo, package structure, lint and CI config.
2. UI against mock data: popover, Home, and the other screens.
3. Real backends one at a time: metrics and health, notifications and scheduling, cleanup, files, startup and uninstaller, scanner.

Each stage should be usable on its own.

## Left to the builder

Exact thresholds for health states, icon choices, treemap rendering approach, internal module naming, and the detailed layouts of screens other than Home.
