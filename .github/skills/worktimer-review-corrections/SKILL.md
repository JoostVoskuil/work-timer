---
name: worktimer-review-corrections
description: Use when changing WorkTimer review items, gap answers, block corrections, manual entries, or undo behavior. Preserves the distinction between captured observations and correction overlays.
---

# WorkTimer review and correction changes

Use this skill when modifying `ReviewResolver`, review persistence, correction UI, or how corrected blocks are reported.

## Trace the existing flow

1. Read `ReviewResolver.swift`, the adjustment/review methods in `Ledger.swift`, and `effectiveBlocks(in:)` in `BlockLedger.swift`.
2. Follow the relevant call site in `AppModel.swift` and UI in `Views.swift`; errors should remain visible through the existing UI error state.
3. Check `BlockAccountingTests.swift` and `EngineTests.swift` for current behavior before changing it.

## Preserve these semantics

- Reviews are exceptions for unknown tracking gaps; ordinary idle and outside-hours activity are not automatically review tasks.
- A review answer is a correction overlay. Never rewrite the captured block counters or app sets.
- `Review later` leaves the review pending. Undoing a review-linked adjustment restores that review to pending.
- The current resolver accepts category answers only for a complete gap review range. Although the API comment mentions splitting, partial category pieces are rejected; do not expand split behavior without first defining the intended semantics and adding regression tests.
- Ordinary block corrections must target completed five-minute boundaries. Away corrections are allowed only when the recorded coverage is wholly within scheduled working hours.
- Manual entries must use completed five-minute boundaries and Work, Learn, Private, or Break; they replace recorded blocks in-range and must be undoable.
- Multi-block corrections are atomic: a failed operation must not leave only part of the selection applied.
- Keep validation failures explicit; do not silently ignore malformed ranges or turn failures into success-shaped results.

## Test the behavior

Add focused tests for the changed resolver/ledger behavior, including the applicable pending-review, overlap, completed-block, work-window, transaction, and undo cases. Run:

```sh
swift test --filter BlockAccountingTests
swift test --filter EngineTests
```

Also run the full `swift test` suite when the change affects shared persistence or accounting.
