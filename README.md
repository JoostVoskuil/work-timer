# WorkTimer

Local-first macOS menu-bar work-hours tracker. No network, no cloud, no screenshots, no keystroke content.

Requires macOS 27 or later and Xcode with the macOS 27 SDK to build.

## Build and run
- `swift test` (the test target passes the Swift Testing macro-plugin path needed with Command Line Tools only).
- `./scripts/build-app.sh` produces `build/WorkTimer.app` (ad-hoc signed). Copy it to `/Applications`, open it, and allow notifications.
- To build, install and start the full app with its widget and Safari extensions, install XcodeGen (`brew install xcodegen`), set your Apple Developer Team ID, then run `TEAM_ID=YOUR_TEAM_ID ./scripts/watch-install.sh`. It watches app, widget, Safari extension, package and test sources; each detected edit rebuilds, replaces `/Applications/WorkTimer.app` and restarts it. Use `TEAM_ID=YOUR_TEAM_ID ./scripts/watch-install.sh --once` to install and launch without watching. Stop the watcher with Ctrl-C. Set `INSTALL_DIR` only if you deliberately want another installation folder.
- The Xcode build uses automatic signing and may ask Xcode to provision the configured team. All targets use the macOS App Group `TEAM_ID.nl.worktimer.shared`, expanded from `DEVELOPMENT_TEAM` into their entitlements and Info.plists; this team-prefixed format does not require portal registration. The installer refreshes Launch Services, explicitly registers the embedded widget extension, and the app calls `WidgetCenter.reloadAllTimelines()` on launch. You still need to add the WorkTimer widget from Notification Center's **Edit Widgets** screen. Safari extensions must be enabled in Safari settings.
- When activity continues outside the configured work window, WorkTimer sends an actionable notification asking whether the time is **Work**, **Private**, or should be reviewed **Later**. Notifications must be allowed in macOS System Settings.

## Data
- Stored in your user profile: `~/Library/Application Support/WorkTimer/worktimer.sqlite` (plus `Backups/`). Backups are plain SQLite and **not encrypted**.
- The app also publishes its widget summary to the shared App Group container, using the same location resolver as the widget. The database stays in the user profile. Successful publication requests a timeline reload on launch and at most every 15 minutes thereafter; macOS controls refresh timing.
- **After an update** the app takes a pre-migration backup, migrates, republishes the widget snapshot and asks WidgetKit to reload all timelines. The version is recorded only after success.
- Deviation from the plan: the system SQLite3 library is used instead of GRDB (no dependencies).

## Accounting definitions
- Work = classified work time; private, break, idle, away and unknown are excluded. Outside-hours time is *pending* (not work) until answered.
- Sleep and screen-locked intervals are recorded only within the configured work window. They remain away time, available for manual correction if you were working (for example, on a phone call); outside that window they are omitted.
- Week-to-date balance = work Monday..selected day minus scheduled targets for those days (today's full target counts and is labelled "incomplete").
- One calculator (`ReportCalculator`) feeds the menu bar, reports, widget snapshot and CSV.
- Pending review totals include only time covered by actual unanswered Review items, not every unknown recording reason. Unknown time without a Review item remains excluded from work.
- Report charts stack work (teal) and personal time (purple) with a legend. Personal time includes private rules, private browsing and confirmed private activity; unanswered after-hours activity is excluded until classified. Personal time never contributes to work balances.
- Learn (blue) is a separate category, not contractual work. Start/end a learning session from the menu bar, classify Review items as Learn, or change a timeline entry to Learn. Learning sessions respect private rules, idle, sleep, lock and break exclusions and end when the app restarts.
- Work + Learn share the weekly ceiling (45 hours by default). Reports, the menu and widgets show the combined usage; a notification warns once per week when the ceiling is reached. Actual time remains recorded even above the limit, rather than silently truncated. Work targets and balances still use Work only. Summary CSV includes `learn_h`.

## Rule precedence
Private beats work on ties; domain rules beat app rules. Default private: nu.nl, nos.nl, tweakers.net, VLC. Hostname matching is exact or `.`-suffix (so `menu.nl` does not match `nu.nl`).

## Corrections
Corrections are an overlay (`manual_adjustments`); captured evidence is never rewritten, and corrections can be undone.

## Review
Review explains uncertain periods: no keyboard/mouse input (possibly a call), tracking gaps, and unanswered outside-hours activity. Each item shows dates, duration, why confirmation is needed, and classification actions. These periods are excluded from work until confirmed. Leaving an item unanswered keeps it pending. Active after-hours sessions can be answered directly in Review; Work or Private also applies to the remainder of that session.
Recorded apps and website domains are shown as context, not proof of work. Idle periods retain foreground app identifiers going forward; older entries and tracking gaps may have no context. Task and document titles are not captured.
On restart, unfinished after-hours reviews from previous sessions are closed at their last recorded evidence, not extended to the present. They remain pending for your answer.

## Xcode extensions
`Extensions/` holds the Safari Web Extension (hostname only), its native handler, the WidgetKit widget and an XcodeGen `project.yml`. The SwiftPM-built app does not contain these extensions; use the XcodeGen watcher above for the full app. Widgets require the extension to be installed and added in Notification Center.
Both extensions enable App Sandbox, which macOS requires for PlugInKit discovery. The installer verifies that the installed widget appears in PlugInKit, rather than treating a successful registration command as proof of discovery. For desktop placement, right-click the desktop, choose **Edit Widgets**, and search for **WorkTimer**.

### Graph widgets
Choose **Daily graph** or **Weekly graph**, each available in medium and large sizes. The daily chart stacks activity by hour; the weekly chart stacks Monday through Sunday. Work is teal, Private is purple, and Learn is blue, with separate hour/minute totals beneath each chart. The existing **Work hours** summary remains available.

Graphs use the reporting timezone, including daylight-saving changes, and the same corrected/live accounting as Reports. Unanswered after-hours activity is excluded from Private; idle, away, breaks and gaps are not shown as classified activity. Empty charts say so rather than inventing activity, and snapshots older than 30 minutes show an outdated-data indicator. Gallery previews use example data only; placed widgets always use your published snapshot. All widget types receive refresh requests together, subject to macOS refresh scheduling.

## Not measured
CPU, memory and energy targets, 8-hour soak, DST on a real clock, real sleep/lock, Safari behaviour and widget refresh budgets need manual validation (plan section 10, milestones A and H).
