# WorkTimer contributor instructions

## App shape

- WorkTimer is a local-first macOS menu-bar app. `Sources/WorkTimerCore` contains the Swift package, accounting, storage, tracking engine and reports. `Sources/WorkTimerApp` contains the SwiftUI/AppKit app. `Extensions/` contains the WidgetKit widget and Safari Web Extension.
- Read the relevant parts of `README.md` before changing user-visible behavior; it documents product behavior and accounting rules in detail.
- Keep core behavior in `WorkTimerCore` when it does not depend on app UI or macOS app services. Keep UI state and presentation in `WorkTimerApp`.
- The package targets macOS 27 and uses Swift Testing (`@Test`, `#expect`) for tests.

## Invariants to preserve

- Keep tracking local. Do not add network uploads, cloud services, screenshots, keystroke capture, or storage of app-switch history, window titles, per-app durations, or Safari domains. Persist only the data the feature requires and keep app/site classification live where possible.
- Time is UTC milliseconds (`Millis`); `Span` ranges are half-open `[start, end)`. Canonical activity is stored in five-minute `ActivityBlock`s.
- Keep observations separate from corrections: adjustments are overlays, must remain undoable, and must not rewrite captured evidence.
- Preserve existing user data. The current database is schema 2; do not silently migrate, convert, delete, or replace existing databases or backups. Use transactions for multi-step ledger changes and surface failures through the existing error path.
- Use the shared accounting/reporting logic rather than introducing a second interpretation of totals. Account for schedule and reporting-time-zone boundaries, including daylight-saving changes.
- Keep user-visible wording and category names consistent with the existing UI and README. Update the README when product behavior or documented accounting rules change.

## Validation

- Run `swift test` for core, accounting, storage, and engine changes.
- Run `./scripts/build-app.sh` when a change affects the SwiftPM-built app or needs an app build.
- The Safari and widget extensions are built through `Extensions/project.yml` with XcodeGen and full Xcode; do not treat a SwiftPM build as validation of those extension targets.
- Add focused regression tests for changed behavior, especially data-preservation, boundary, undo, and error cases. Use temporary databases as the existing tests do.
