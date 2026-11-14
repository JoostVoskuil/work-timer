# WorkTimer

Local-first macOS menu-bar work-hours tracker. No network, no cloud, no screenshots, no keystroke content.

## Build and run
- `swift test` (the test target passes the Swift Testing macro-plugin path needed with Command Line Tools only).
- `./scripts/build-app.sh` produces `build/WorkTimer.app` (ad-hoc signed). Copy it to `/Applications`, open it, and allow notifications.
- To build, install and start the full app with its widget and Safari extensions, install XcodeGen (`brew install xcodegen`), set your Apple Developer Team ID, then run `TEAM_ID=YOUR_TEAM_ID ./scripts/watch-install.sh`. It watches app, widget, Safari extension, package and test sources; each detected edit rebuilds, replaces `/Applications/WorkTimer.app` and restarts it. Use `TEAM_ID=YOUR_TEAM_ID ./scripts/watch-install.sh --once` to install and launch without watching. Stop the watcher with Ctrl-C. Set `INSTALL_DIR` only if you deliberately want another installation folder.
- The Xcode build uses automatic signing and may ask Xcode to provision the configured team. The App Group `group.nl.worktimer.shared` must be available to that team. The installer refreshes Launch Services, explicitly registers the embedded widget extension, and the app calls `WidgetCenter.reloadAllTimelines()` on launch. You still need to add the WorkTimer widget from Notification Center's **Edit Widgets** screen. Safari extensions must be enabled in Safari settings.
- When activity continues outside the configured work window, WorkTimer sends an actionable notification asking whether the time is **Work**, **Private**, or should be reviewed **Later**. Notifications must be allowed in macOS System Settings.

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

## Xcode extensions
`Extensions/` holds the Safari Web Extension (hostname only), its native handler, the WidgetKit widget and an XcodeGen `project.yml`. The SwiftPM-built app does not contain these extensions; use the XcodeGen watcher above for the full app. Widgets require the extension to be installed and added in Notification Center.
Both extensions enable App Sandbox, which macOS requires for PlugInKit discovery. The installer verifies that the installed widget appears in PlugInKit, rather than treating a successful registration command as proof of discovery. For desktop placement, right-click the desktop, choose **Edit Widgets**, and search for **WorkTimer**.

## Not measured
CPU, memory and energy targets, 8-hour soak, DST on a real clock, real sleep/lock, Safari behaviour and widget refresh budgets need manual validation (plan section 10, milestones A and H).
