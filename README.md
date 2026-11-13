# WorkTimer

Local-first macOS menu-bar work-hours tracker. No network, no cloud, no screenshots, no keystroke content.

## Build and run
- `swift test` (the test target passes the Swift Testing macro-plugin path needed with Command Line Tools only).
- `./scripts/build-app.sh` produces `build/WorkTimer.app` (ad-hoc signed). Copy it to `/Applications`, open it, and allow notifications.

## Data
- Stored in your user profile: `~/Library/Application Support/WorkTimer/worktimer.sqlite` (plus `Backups/`). Backups are plain SQLite and **not encrypted**.
- **After an update** the app takes a pre-migration backup, migrates, republishes the widget snapshot and asks WidgetKit to reload all timelines. The version is recorded only after success.
- Deviation from the plan: the system SQLite3 library is used instead of GRDB (no dependencies).

## Accounting definitions
- Work = classified work time; private, break, idle, away and unknown are excluded. Outside-hours time is *pending* (not work) until answered.
- Week-to-date balance = work Monday..selected day minus scheduled targets for those days (today's full target counts and is labelled "incomplete").
- One calculator (`ReportCalculator`) feeds the menu bar, reports, widget snapshot and CSV.

## Rule precedence
Private beats work on ties; domain rules beat app rules. Default private: nu.nl, nos.nl, tweakers.net, VLC. Hostname matching is exact or `.`-suffix (so `menu.nl` does not match `nu.nl`).

## Corrections
Corrections are an overlay (`manual_adjustments`); captured evidence is never rewritten, and corrections can be undone.

## Needs Xcode / a real Mac (sources provided, not buildable here)
`Extensions/` holds the Safari Web Extension (hostname only), its native handler, the WidgetKit widget and an XcodeGen `project.yml`. They need Xcode, a signing team and the App Group `group.nl.worktimer.shared`. The handler and widget sources type-check against the core library. The SwiftPM app cannot host widgets, so `reloadWidgets` is a no-op until the widget extension is installed via Xcode.

## Not measured
CPU, memory and energy targets, 8-hour soak, DST on a real clock, real sleep/lock, Safari behaviour and widget refresh budgets need manual validation (plan section 10, milestones A and H).
