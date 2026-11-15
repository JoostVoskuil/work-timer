---
name: worktimer-block-accounting
description: Use when changing five-minute activity blocks, winner selection, correction projection, reports, CSV, dashboard graphs, or widget totals in WorkTimer.
---

# WorkTimer five-minute accounting

Use this skill when a change could affect how activity is stored, projected, or totaled.

## Trace the shared accounting path

1. Read `ActivityBlock.swift` and `BlockLedger.swift` to understand stored counters, block aggregation, and effective correction overlays.
2. Read `Schedule.swift` and the relevant code in `Reports.swift` for work-window and reporting-time-zone behavior.
3. Follow consumers such as `CSV.swift`, `Snapshot.swift`, `AppModel.swift`, and `Extensions/Widgets/`; prefer the shared calculator and snapshot path over a new tally.
4. Inspect the related tests in `BlockAccountingTests.swift` and `EngineTests.swift`.

## Preserve the accounting contract

- A canonical block is five minutes. Accounting projects each observed block to exactly one category for all five minutes; it does not split a block by its source durations.
- Convert Idle to Away before choosing the winner.
- During a scheduled work window, the greatest duration wins; ties use Work, Learn, Private, Break, Away, then Unknown. For a wholly outside-hours block, any recorded Work wins first; otherwise use the same winner rule.
- Preserve original counters and coverage so live observations can change the eventual winner. Corrections are overlays; do not destructively rewrite observations.
- Respect half-open time spans, the reporting time zone, schedule boundaries, and daylight-saving days. Do not assume every local day is 24 hours.
- Reports, Today, graphs, widgets, limits, and CSV must use consistent corrected/live accounting. Work + Learn may share a ceiling, but Learn is not contractual Work and must not affect Work-only targets or balances.
- Do not add app/site attribution to reports or persist additional browsing or usage history.

## Validate

Write focused tests that exercise the changed accounting result, not just helper constants. Cover the relevant winner/tie case, schedule boundary, correction overlay, or timezone edge, then run:

```sh
swift test --filter BlockAccountingTests
```

Run the full `swift test` suite when changing shared accounting or persistence.
