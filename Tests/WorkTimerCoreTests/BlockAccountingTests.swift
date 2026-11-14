import Foundation
import Testing
@testable import WorkTimerCore

private let blockZone = TimeZone(identifier: "Europe/Amsterdam")!
private func instant(_ hour: Int, _ minute: Int = 0, _ second: Int = 0, day: Int = 13) -> Millis {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = blockZone
    return calendar.date(from: DateComponents(year: 2025, month: 6, day: day, hour: hour, minute: minute, second: second))!.millis
}

private func memoryLedger() throws -> Ledger {
    let ledger = try Ledger.inMemory()
    try ledger.setReportingTimeZone(blockZone)
    return ledger
}

private func send(_ engine: TrackingEngine, _ event: EngineEvent, _ at: Millis) throws {
    try engine.handle(event, at: Stamp(wall: at, mono: Double(at) / 1000))
}

@Suite struct BlockAccountingTests {
    @Test func checkboxShiftRangesFollowDisplayedOrderInBothDirections() {
        let ids: [Millis] = [900, 600, 300, 0]
        #expect(ActivityBlock.selectionRange(orderedIDs: ids, anchor: 900, target: 300) == [900, 600, 300])
        #expect(ActivityBlock.selectionRange(orderedIDs: ids, anchor: 0, target: 600) == [0, 300, 600])
        #expect(ActivityBlock.selectionRange(orderedIDs: ids, anchor: 600, target: 600) == [600])
    }

    @Test func checkboxShiftRangesHandleClearedAnchorsAndExcludeIneligibleBlocks() {
        let eligible: [Millis] = [900, 300, 0]
        #expect(ActivityBlock.selectionRange(orderedIDs: eligible, anchor: nil, target: 300) == [300])
        #expect(ActivityBlock.selectionRange(orderedIDs: eligible, anchor: 600, target: 300) == [300])
        #expect(ActivityBlock.selectionRange(orderedIDs: eligible, anchor: 900, target: 0) == [900, 300, 0])
        #expect(ActivityBlock.selectionRange(orderedIDs: eligible, anchor: 900, target: 600).isEmpty)
    }

    @Test func popupHourlyDataMatchesTodayIncludingLiveCorrectionsAndHiddenSleepingHours() throws {
        let ledger = try memoryLedger()
        try ledger.record([
            ActivityInterval(span: Span(instant(10, day: 12), instant(11, day: 12)), category: .work, reason: .workWindow),
            ActivityInterval(span: Span(instant(5), instant(5, 5)), category: .work, reason: .workRule),
            ActivityInterval(span: Span(instant(10), instant(10, 5)), category: .privateTime, reason: .privateRule)
        ])
        try ReviewResolver(ledger: ledger).reclassify(Span(instant(10), instant(10, 5)), as: .learn, note: "", now: instant(20))
        let calc = ReportCalculator(ledger: ledger, liveBlocks: {
            [ActivityInterval(span: Span(instant(18), instant(18, 5)), category: .work, reason: .outsideHoursWork)]
        })
        let day = LocalDate(2025, 6, 13)
        let summary = calc.day(day, now: instant(20))
        let hours = SnapshotBuilder.hourlyBuckets(calc: calc, day: day)
        #expect(hours.reduce(0) { $0 + $1.work } == summary.work)
        #expect(hours.reduce(0) { $0 + $1.learn } == summary.learn)
        #expect(hours.reduce(0) { $0 + $1.personal } == summary.personal)
        #expect(summary.work == 10 * Duration.minute)
        #expect(summary.learn == ActivityBlock.length)
        let visible = hours.filter {
            let hour = calc.schedule.calendar.component(.hour, from: Date(millis: $0.start))
            return hour >= 6 && hour < 23
        }
        #expect(visible.reduce(0) { $0 + $1.work } == ActivityBlock.length)
        #expect(visible.first?.start == instant(6))
        #expect(visible.last?.end == instant(23))
    }

    @Test func bulkCorrectionChangesOnlySelectedBlocksAndPreservesAppsAndUndo() throws {
        let ledger = try memoryLedger()
        let start = instant(10)
        let range = Span(start, start + 15 * Duration.minute)
        try ledger.record([ActivityInterval(span: range, category: .privateTime, reason: .privateRule, apps: ["editor"])])
        let first = Span(start, start + ActivityBlock.length)
        let last = Span(start + 2 * ActivityBlock.length, range.end)
        let resolver = ReviewResolver(ledger: ledger)
        let edits = try resolver.reclassify([last, first, first], as: .work, note: "", now: range.end)
        #expect(edits.count == 2)
        let calc = ReportCalculator(ledger: ledger)
        let blocks = try calc.blocks(in: range)
        #expect(blocks.map { $0[.work] } == [ActivityBlock.length, 0, ActivityBlock.length])
        #expect(blocks.allSatisfy { $0.apps == ["editor"] })
        #expect(try ledger.adjustments(in: range).map(\.span) == [first, last])
        for id in edits { try resolver.undo(adjustmentID: id, now: range.end) }
        #expect(try calc.blocks(in: range).allSatisfy { $0[.privateTime] == ActivityBlock.length })
    }

    @Test func bulkCorrectionRollsBackAllChangesIfAnyBlockIsUnfinished() throws {
        let ledger = try memoryLedger()
        let start = instant(10)
        let range = Span(start, start + 10 * Duration.minute)
        try ledger.record([ActivityInterval(span: range, category: .privateTime, reason: .privateRule)])
        let before = try ledger.effectiveBlocks(in: range)
        #expect(throws: SQLiteError.self) {
            try ReviewResolver(ledger: ledger).reclassify(
                [Span(start, start + ActivityBlock.length), Span(start + ActivityBlock.length, range.end)],
                as: .work, note: "", now: range.end - Duration.minute)
        }
        #expect(try ledger.adjustments(in: range).isEmpty)
        #expect(try ledger.effectiveBlocks(in: range) == before)
    }

    @Test func bulkAwayCorrectionRollsBackWhenSelectionIncludesOutsideHours() throws {
        let ledger = try memoryLedger()
        let range = Span(instant(16, 55), instant(17, 5))
        try ledger.record([ActivityInterval(span: range, category: .work, reason: .workRule)])
        #expect(throws: SQLiteError.self) {
            try ReviewResolver(ledger: ledger).reclassify(
                [Span(instant(16, 55), instant(17)), Span(instant(17), instant(17, 5))],
                as: .away, note: "", now: range.end)
        }
        #expect(try ledger.adjustments(in: range).isEmpty)
        #expect(try ledger.effectiveBlocks(in: range).allSatisfy { $0[.work] == ActivityBlock.length })
    }

    @Test func pastDayQueriesExcludeCurrentLiveBlocksAndUseThatDaysTargetsAndCorrections() throws {
        let ledger = try memoryLedger()
        let past = LocalDate(2025, 6, 12)
        let current = LocalDate(2025, 6, 13)
        let pastSpan = Span(instant(10, day: 12), instant(10, 5, day: 12))
        try ledger.record([ActivityInterval(span: pastSpan, category: .work, reason: .workWindow, apps: ["past.editor"])])
        let calc = ReportCalculator(ledger: ledger, liveBlocks: {
            [ActivityInterval(span: Span(instant(10), instant(10, 5)), category: .privateTime,
                              reason: .privateRule, apps: ["current.editor"])]
        })
        let now = instant(10, 5)
        #expect(calc.day(past, now: now).work == ActivityBlock.length)
        #expect(calc.day(past, now: now).personal == 0)
        #expect(!calc.day(past, now: now).isToday)
        #expect(calc.day(past, now: now).targetMillis == 8 * Duration.hour)
        #expect(calc.day(current, now: now).personal == ActivityBlock.length)
        #expect(try calc.blocks(in: calc.schedule.daySpan(past)).map(\.apps) == [["past.editor"]])
        try ReviewResolver(ledger: ledger).reclassify([pastSpan], as: .learn, note: "", now: now)
        #expect(calc.day(past, now: now).learn == ActivityBlock.length)
        #expect(calc.day(current, now: now).personal == ActivityBlock.length)
    }

    @Test func sameCategoryAppSwitchesStayInTheirOwnBlocksAndAppearLive() throws {
        let ledger = try memoryLedger()
        let engine = TrackingEngine(ledger: ledger)
        let start = instant(10)
        try send(engine, .launch(app: "com.apple.TextEdit", idleSeconds: 0), start)
        try send(engine, .appActivated("com.apple.Terminal"), start + Duration.minute)
        try send(engine, .appActivated("com.apple.finder"), start + ActivityBlock.length)
        let calc = ReportCalculator(ledger: ledger, liveBlocks: { engine.liveIntervals(now: start + 6 * Duration.minute) })
        let live = try calc.blocks(in: Span(start, start + 10 * Duration.minute))
        #expect(live[0].apps == ["com.apple.Terminal", "com.apple.TextEdit"])
        #expect(live[1].apps == ["com.apple.finder"])
        try send(engine, .shutdown, start + 10 * Duration.minute)
        let stored = try ledger.blocks(in: Span(start, start + 10 * Duration.minute))
        #expect(stored.map(\.apps) == live.map(\.apps))
        #expect(stored.allSatisfy { $0[.work] == ActivityBlock.length })
    }

    @Test func repeatedSameCategorySwitchesKeepAppSetsAndWritesBounded() throws {
        let ledger = try memoryLedger()
        let engine = TrackingEngine(ledger: ledger)
        let start = instant(10)
        let before = try ledger.db.scalar("SELECT total_changes()")!
        try send(engine, .launch(app: "editor.a", idleSeconds: 0), start)
        for i in 1...1_000 {
            try send(engine, .appActivated(i % 2 == 0 ? "editor.a" : "editor.b"), start + Millis(i) * 3_600)
        }
        try send(engine, .shutdown, start + Duration.hour)
        let blocks = try ledger.blocks(in: Span(start, start + Duration.hour))
        #expect(blocks.count == 12)
        #expect(blocks.allSatisfy { $0.apps == ["editor.a", "editor.b"] })
        #expect(try ledger.db.scalar("SELECT total_changes()")! - before < 260)
    }

    @Test func appSetsSurviveCheckpointRecoveryOnceAndCorrections() throws {
        let ledger = try memoryLedger()
        let start = instant(10)
        let span = Span(start, start + 10 * Duration.minute)
        let engine = TrackingEngine(ledger: ledger)
        try send(engine, .launch(app: "editor.a", idleSeconds: 0), start)
        try send(engine, .appActivated("editor.b"), start + 2 * Duration.minute)
        try engine.checkpointNow(at: Stamp(wall: span.end, mono: Double(span.end) / 1000))
        let checkpoint = try #require(ledger.readCheckpoint())
        let payload = try #require(JSONSerialization.jsonObject(with: Data(checkpoint.stateJSON.utf8)) as? [String: Any])
        let pending = try #require(payload["pending"] as? [[String: Any]])
        #expect(pending.allSatisfy { ($0["apps"] as? [String])?.isEmpty == true })
        #expect(payload["appsByBlock"] != nil)
        let restart = TrackingEngine(ledger: ledger)
        try restart.recover(now: span.end)
        let stored = try ledger.blocks(in: span)
        #expect(stored[0].apps == ["editor.a", "editor.b"])
        #expect(stored[1].apps == ["editor.b"])
        try restart.recover(now: span.end)
        #expect(try ledger.blocks(in: span) == stored)
        let resolver = ReviewResolver(ledger: ledger)
        let edit = try resolver.reclassify(span, as: .privateTime, note: "", now: span.end)
        let calc = ReportCalculator(ledger: ledger)
        #expect(try calc.blocks(in: span).map(\.apps) == stored.map(\.apps))
        try resolver.undo(adjustmentID: edit, now: span.end)
        #expect(try calc.blocks(in: span).map(\.apps) == stored.map(\.apps))
    }

    @Test func idleRemovesProvisionalAppsAndDoesNotCaptureInactiveForegroundApps() throws {
        let ledger = try memoryLedger()
        let engine = TrackingEngine(ledger: ledger)
        let start = instant(10)
        try send(engine, .launch(app: "editor.a", idleSeconds: 0), start)
        try send(engine, .appActivated("editor.b"), start + Duration.minute)
        try send(engine, .idleSample(seconds: 300), start + ActivityBlock.length)
        try send(engine, .appActivated("editor.c"), start + 6 * Duration.minute)
        try send(engine, .shutdown, start + 10 * Duration.minute)
        let blocks = try ledger.blocks(in: Span(start, start + 10 * Duration.minute))
        #expect(blocks.allSatisfy { $0.apps.isEmpty && $0[.away] == ActivityBlock.length })
    }

    @Test func safariAppIsRetainedWithoutDomainsOrPrivateBrowsingDetails() throws {
        for state in [BrowserState.domain("secret.example"), .privateBrowsing] {
            let ledger = try memoryLedger()
            let engine = TrackingEngine(ledger: ledger)
            let start = instant(10)
            try send(engine, .launch(app: safariBundleID, idleSeconds: 0), start)
            try send(engine, .browser(BrowserObservation(id: "test", session: "session", seq: 1, observedAt: start, state: state)), start)
            try engine.checkpointNow(at: Stamp(wall: start + 10_000, mono: Double(start + 10_000) / 1000))
            let checkpoint = try #require(ledger.readCheckpoint())
            #expect(!checkpoint.stateJSON.contains("secret.example"))
            #expect(!checkpoint.stateJSON.contains("\"domain\":"))
            try send(engine, .shutdown, start + 20_000)
            let blocks = try ledger.blocks(in: Span(start, start + ActivityBlock.length))
            #expect(blocks.first?.apps == [safariBundleID])
            let json = try JSONEncoder().encode(blocks)
            #expect(!String(decoding: json, as: UTF8.self).contains("secret.example"))
        }
    }

    @Test func workingHoursCreditOnlyTheLongestCategoryWithDeterministicTies() throws {
        let start = instant(10)
        let schedule = Schedule(timeZone: blockZone)
        let cases: [([WorkTimerCore.Category: Millis], WorkTimerCore.Category)] = [
            ([.work: 240_000, .privateTime: 60_000], .work),
            ([.work: 60_000, .privateTime: 240_000], .privateTime),
            ([.learn: 180_000, .work: 60_000, .privateTime: 60_000], .learn),
            ([.gap: 180_000, .work: 120_000], .gap),
            ([.breakTime: 180_000, .away: 120_000], .breakTime),
            ([.idle: 120_000, .away: 60_000, .privateTime: 120_000], .away),
            ([.work: 150_000, .privateTime: 150_000], .work),
            ([.learn: 150_000, .privateTime: 150_000], .learn)
        ]
        for (amounts, winner) in cases {
            let raw = ActivityBlock(start: start, amounts: amounts, coverage: [Span(start, start + ActivityBlock.length)])
            let accounted = try #require(BlockAccounting.accounted(raw, schedule: schedule))
            #expect(accounted.amounts == [winner: ActivityBlock.length])
            try accounted.validate()
            #expect(raw.amounts == amounts)
        }
    }

    @Test func outsideHoursAnyWorkWinsIncludingWeekendsAndWindowEdges() throws {
        let schedule = Schedule(timeZone: blockZone)
        for start in [instant(6, 55), instant(17), instant(18), instant(10, day: 14)] {
            let raw = ActivityBlock(start: start, amounts: [.work: 1, .privateTime: ActivityBlock.length - 1],
                                    coverage: [Span(start, start + ActivityBlock.length)])
            #expect(BlockAccounting.accounted(raw, schedule: schedule)?.amounts == [.work: ActivityBlock.length])
        }
        let beforeEnd = ActivityBlock(start: instant(16, 55), amounts: [.work: 1, .privateTime: ActivityBlock.length - 1],
                                     coverage: [Span(instant(16, 55), instant(17))])
        #expect(BlockAccounting.accounted(beforeEnd, schedule: schedule)?.amounts == [.privateTime: ActivityBlock.length])
        let noWork = ActivityBlock(start: instant(18), amounts: [.learn: 180_000, .privateTime: 120_000],
                                  coverage: [Span(instant(18), instant(18, 5))])
        #expect(BlockAccounting.accounted(noWork, schedule: schedule)?.amounts == [.learn: ActivityBlock.length])
    }

    @Test func blocksTouchingAnUnalignedWorkWindowUseTheMajorityRule() {
        let schedule = Schedule(versions: [ScheduleVersion(windowStartMinute: 7 * 60 + 2)], timeZone: blockZone)
        let start = instant(7)
        let raw = ActivityBlock(start: start, amounts: [.work: 60_000, .privateTime: 240_000],
                                coverage: [Span(start, start + ActivityBlock.length)])
        #expect(BlockAccounting.accounted(raw, schedule: schedule)?.amounts == [.privateTime: ActivityBlock.length])
    }

    @Test func partialBlocksCountFiveMinutesButAbsentBlocksAreNotInvented() throws {
        let start = instant(10)
        let raw = ActivityBlock(start: start, amounts: [.work: Duration.minute],
                                coverage: [Span(start + Duration.minute, start + 2 * Duration.minute)])
        let accounted = try #require(BlockAccounting.accounted(raw, schedule: Schedule(timeZone: blockZone)))
        #expect(accounted.amounts == [.work: ActivityBlock.length])
        #expect(accounted.coverage == [accounted.span])
        try accounted.validate()
        #expect(raw.observed == Duration.minute)
        #expect(BlockAccounting.accounted(ActivityBlock(start: start), schedule: Schedule(timeZone: blockZone)) == nil)
    }

    @Test func liveWinnerIsRecalculatedFromAllObservationsWithoutCountingTwice() throws {
        let ledger = try memoryLedger()
        let start = instant(10)
        let span = Span(start, start + ActivityBlock.length)
        try ledger.record([ActivityInterval(span: Span(start, start + 20_000), category: .privateTime, reason: .privateRule)])
        var live = [ActivityInterval(span: Span(start + 20_000, start + 60_000), category: .work, reason: .workWindow)]
        let calc = ReportCalculator(ledger: ledger, liveBlocks: { live })
        #expect(try calc.blocks(in: span).first?.amounts == [.work: ActivityBlock.length])
        live.append(ActivityInterval(span: Span(start + 60_000, start + 240_000), category: .privateTime, reason: .privateRule))
        #expect(try calc.blocks(in: span).first?.amounts == [.privateTime: ActivityBlock.length])
        #expect(try calc.blocks(in: span).reduce(0) { $0 + $1.observed } == ActivityBlock.length)
        #expect(try ledger.blocks(in: span).first?.observed == 20_000)
    }

    @Test func explicitCorrectionsOverrideTheWinnerAndUndoRestoresIt() throws {
        for hour in [10, 18] {
            let ledger = try memoryLedger()
            let start = instant(hour)
            let span = Span(start, start + ActivityBlock.length)
            try ledger.record([
                ActivityInterval(span: Span(start, start + Duration.minute), category: .work, reason: .workRule),
                ActivityInterval(span: Span(start + Duration.minute, span.end), category: .privateTime, reason: .privateRule)
            ])
            let calc = ReportCalculator(ledger: ledger)
            let original = try calc.blocks(in: span)
            #expect(original.first?.amounts == [hour == 10 ? .privateTime : .work: ActivityBlock.length])
            let resolver = ReviewResolver(ledger: ledger)
            let edit = try resolver.reclassify(span, as: .learn, note: "", now: span.end)
            #expect(try calc.blocks(in: span).first?.amounts == [.learn: ActivityBlock.length])
            try resolver.undo(adjustmentID: edit, now: span.end)
            #expect(try calc.blocks(in: span) == original)
            #expect(try ledger.blocks(in: span).first?[.work] == Duration.minute)
        }
    }

    @Test func historyReportsCSVAndWidgetGraphsUseTheSameSingleCategoryBlocks() throws {
        let ledger = try memoryLedger()
        try ledger.record([
            ActivityInterval(span: Span(instant(10), instant(10, 4)), category: .work, reason: .workWindow),
            ActivityInterval(span: Span(instant(10, 4), instant(10, 5)), category: .privateTime, reason: .privateRule),
            ActivityInterval(span: Span(instant(18), instant(18, 1)), category: .work, reason: .workRule),
            ActivityInterval(span: Span(instant(18, 1), instant(18, 5)), category: .privateTime, reason: .privateRule)
        ])
        let raw = try ledger.blocks(in: Span(instant(10), instant(19)))
        let writes = try ledger.db.scalar("SELECT total_changes()")
        let calc = ReportCalculator(ledger: ledger)
        let day = LocalDate(2025, 6, 13)
        let now = instant(19)
        #expect(calc.day(day, now: now).work == 10 * Duration.minute)
        #expect(calc.day(day, now: now).personal == 0)
        #expect(calc.week(containing: day, now: now).work == 10 * Duration.minute)
        #expect(calc.month(containing: day, now: now).work == 10 * Duration.minute)
        let snapshot = SnapshotBuilder.build(calc: calc, now: now, health: HealthStatus(), status: "Work")
        #expect(snapshot.todayWork == 10 * Duration.minute)
        #expect(snapshot.graphs?.hours[10].work == ActivityBlock.length)
        #expect(snapshot.graphs?.hours[18].work == ActivityBlock.length)
        let csv = try CSV.timeline(calc, range: day...day)
        let rows = csv.split(separator: "\n").dropFirst()
        #expect(rows.count == 2)
        for row in rows {
            let cells = row.split(separator: ",")
            #expect(cells[3] == "300.000")
            #expect(cells[4] == "300.000")
            #expect(cells[5...9].allSatisfy { $0 == "0.000" })
        }
        #expect(try ledger.db.scalar("SELECT total_changes()") == writes)
        #expect(try ledger.blocks(in: Span(instant(10), instant(19))) == raw)
    }

    @Test func completedAwayGroupsPreserveBlocksAndNormalizeIdle() {
        let start = instant(10)
        let blocks = (0..<6).map { offset in
            let time = start + Millis(offset) * ActivityBlock.length
            return ActivityBlock(start: time, amounts: [offset % 2 == 0 ? .idle : .away: ActivityBlock.length],
                                 coverage: [Span(time, time + ActivityBlock.length)])
        }
        let groups = ActivityBlockGroup.groupingAway(Array(blocks.reversed()), completedThrough: start + 30 * Duration.minute)
        #expect(groups.count == 1)
        #expect(groups[0].blocks.count == 6)
        #expect(groups[0].span == Span(start, start + 30 * Duration.minute))
        #expect(groups[0].observed == 30 * Duration.minute)
        #expect(groups[0].blocks.allSatisfy { $0[.away] == ActivityBlock.length && $0[.idle] == 0 })
        #expect(blocks[0][.idle] == ActivityBlock.length)
    }

    @Test func awayGroupingDoesNotBridgeGapsMixedPartialOrUnfinishedBlocks() {
        let start = instant(10)
        func full(_ offset: Int) -> ActivityBlock {
            let time = start + Millis(offset) * ActivityBlock.length
            return ActivityBlock(start: time, amounts: [.away: ActivityBlock.length],
                                 coverage: [Span(time, time + ActivityBlock.length)])
        }
        let mixed = ActivityBlock(start: start + 3 * ActivityBlock.length,
                                  amounts: [.away: 2 * Duration.minute, .work: 3 * Duration.minute],
                                  coverage: [Span(start + 3 * ActivityBlock.length, start + 4 * ActivityBlock.length)])
        let partial = ActivityBlock(start: start + 4 * ActivityBlock.length, amounts: [.away: 3 * Duration.minute],
                                    coverage: [Span(start + 4 * ActivityBlock.length, start + 4 * ActivityBlock.length + 3 * Duration.minute)])
        let blocks = [full(0), full(2), mixed, partial, full(5), full(6)]
        let groups = ActivityBlockGroup.groupingAway(blocks, completedThrough: start + 6 * ActivityBlock.length)
        #expect(groups.count == blocks.count)
        #expect(groups.flatMap(\.blocks) == blocks)
    }

    @Test func correctingAndUndoingOneBlockSplitsAndReformsAwayGroup() throws {
        let ledger = try memoryLedger()
        let start = instant(10)
        let span = Span(start, start + 30 * Duration.minute)
        try ledger.record([ActivityInterval(span: span, category: .away, reason: .idleTimeout)])
        let original = ActivityBlockGroup.groupingAway(try ledger.effectiveBlocks(in: span), completedThrough: span.end)
        let resolver = ReviewResolver(ledger: ledger)
        let id = try resolver.reclassify(Span(start + 10 * Duration.minute, start + 15 * Duration.minute),
                                        as: .work, note: "", now: span.end)
        let corrected = ActivityBlockGroup.groupingAway(try ledger.effectiveBlocks(in: span), completedThrough: span.end)
        #expect(corrected.map { $0.blocks.count } == [2, 1, 3])
        #expect(corrected.flatMap(\.blocks).reduce(0) { $0 + $1[.work] } == 5 * Duration.minute)
        try resolver.undo(adjustmentID: id, now: span.end)
        #expect(ActivityBlockGroup.groupingAway(try ledger.effectiveBlocks(in: span), completedThrough: span.end) == original)
    }

    @Test func retroactiveIdleCrossingMorningBoundaryRecordsOnlyWorkingTime() throws {
        let ledger = try memoryLedger()
        let engine = TrackingEngine(ledger: ledger)
        try send(engine, .launch(app: "editor", idleSeconds: 0), instant(6, 58))
        try send(engine, .idleSample(seconds: 300), instant(7, 3))
        try send(engine, .idleSample(seconds: 0), instant(7, 8))
        try send(engine, .shutdown, instant(7, 10))
        let blocks = try ledger.blocks(in: Span(instant(6), instant(8)))
        #expect(blocks.reduce(0) { $0 + $1[.away] } == 8 * Duration.minute)
        #expect(blocks.reduce(0) { $0 + $1[.work] } == 2 * Duration.minute)
        #expect(blocks.reduce(0) { $0 + $1[.privateTime] } == 0)
        #expect(blocks.first?.start == instant(7))
    }

    @Test func retroactiveIdleCrossingEveningBoundaryOmitsOutsideInactivity() throws {
        let ledger = try memoryLedger()
        let engine = TrackingEngine(ledger: ledger)
        try send(engine, .launch(app: "editor", idleSeconds: 0), instant(16, 58))
        try send(engine, .idleSample(seconds: 300), instant(17, 3))
        try send(engine, .idleSample(seconds: 0), instant(17, 8))
        try send(engine, .shutdown, instant(17, 10))
        let blocks = try ledger.blocks(in: Span(instant(16), instant(18)))
        #expect(blocks.reduce(0) { $0 + $1[.away] } == 2 * Duration.minute)
        #expect(blocks.reduce(0) { $0 + $1[.privateTime] } == 2 * Duration.minute)
        #expect(blocks.reduce(0) { $0 + $1.observed } == 4 * Duration.minute)
    }

    @Test func allInactiveStatesStopRecordingAtEndOfWorkWindow() throws {
        for event in [EngineEvent.sleep, .lock, .pause, .sessionResigned] {
            let ledger = try memoryLedger()
            let engine = TrackingEngine(ledger: ledger)
            try send(engine, .launch(app: "editor", idleSeconds: 0), instant(16, 50))
            try send(engine, event, instant(16, 55))
            try send(engine, .tick, instant(17, 10))
            try send(engine, .shutdown, instant(17, 15))
            let blocks = try ledger.blocks(in: Span(instant(16), instant(18)))
            #expect(blocks.reduce(0) { $0 + $1[.away] } == 5 * Duration.minute)
            #expect(blocks.reduce(0) { $0 + $1[.work] } == 5 * Duration.minute)
            #expect(blocks.reduce(0) { $0 + $1.observed } == 10 * Duration.minute)
        }
    }

    @Test func weekendIdleProducesNoActivityOrReviews() throws {
        let ledger = try memoryLedger()
        let engine = TrackingEngine(ledger: ledger)
        try send(engine, .launch(app: "editor", idleSeconds: 400), instant(9, day: 14))
        try send(engine, .idleSample(seconds: 1_000), instant(9, 10, day: 14))
        try send(engine, .shutdown, instant(9, 15, day: 14))
        #expect(try ledger.blocks(in: Span(instant(9, day: 14), instant(10, day: 14))).isEmpty)
        #expect(ledger.reviews(status: .pending).isEmpty)
    }

    @Test func idleDuringPomodoroBreakPreservesBreakInsideAndOutsideHours() throws {
        for hour in [10, 18] {
            let ledger = try memoryLedger()
            let engine = TrackingEngine(ledger: ledger)
            let start = instant(hour)
            try send(engine, .launch(app: "editor", idleSeconds: 0), start)
            try send(engine, .pomodoroBreak(true), start)
            try send(engine, .idleSample(seconds: 300), start + 5 * Duration.minute)
            try send(engine, .shutdown, start + 10 * Duration.minute)
            let blocks = try ledger.blocks(in: Span(start, start + 10 * Duration.minute))
            #expect(blocks.reduce(0) { $0 + $1[.breakTime] } == 10 * Duration.minute)
            #expect(blocks.reduce(0) { $0 + $1[.away] } == 0)
        }
    }

    @Test func recoveryClipsOldPendingAndOpenAwayToWorkWindow() throws {
        let ledger = try memoryLedger()
        let pending = ActivityInterval(span: Span(instant(16, 55), instant(17, 5)), category: .away, reason: .idleTimeout)
        let encoded = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        let state = "{\"pending\":[\(encoded)],\"openStart\":\(instant(17, 5)),\"category\":\"away\",\"reason\":\"locked\"}"
        try ledger.writeCheckpoint(observed: instant(17, 10), cleanQuit: false, stateJSON: state)
        try TrackingEngine(ledger: ledger).recover(now: instant(17, 10))
        let blocks = try ledger.blocks(in: Span(instant(16), instant(18)))
        #expect(blocks.reduce(0) { $0 + $1[.away] } == 5 * Duration.minute)
        #expect(blocks.last?.coverage.last?.end == instant(17))
    }

    @Test func awayCorrectionCannotRecreateOutsideHoursInactivity() throws {
        let ledger = try memoryLedger()
        let span = Span(instant(18), instant(18, 5))
        try ledger.record([ActivityInterval(span: span, category: .privateTime, reason: .outsideHoursPrivate)])
        #expect(throws: SQLiteError.self) {
            try ReviewResolver(ledger: ledger).reclassify(span, as: .away, note: "", now: span.end)
        }
        #expect(try ledger.effectiveBlocks(in: span).first?[.privateTime] == 5 * Duration.minute)
        #expect(try ledger.adjustments(in: span).isEmpty)
    }

    @Test func thousandSwitchesUseTwelveRowsAndCadencedWritesRetainingSourceDurations() throws {
        let ledger = try memoryLedger()
        let engine = TrackingEngine(ledger: ledger)
        let start = instant(9)
        let before = try ledger.db.scalar("SELECT total_changes()")!
        try send(engine, .launch(app: "editor", idleSeconds: 0), start)
        for i in 1...1_000 {
            try send(engine, .appActivated(i % 2 == 0 ? "editor" : "org.videolan.vlc"), start + Millis(i) * 3_600)
        }
        try send(engine, .shutdown, start + Duration.hour)
        let blocks = try ledger.blocks(in: Span(start, start + Duration.hour))
        #expect(blocks.count == 12)
        #expect(blocks.reduce(0) { $0 + $1[.work] } == 30 * Duration.minute)
        #expect(blocks.reduce(0) { $0 + $1[.privateTime] } == 30 * Duration.minute)
        #expect(blocks.allSatisfy { $0.observed == ActivityBlock.length })
        let writes = try ledger.db.scalar("SELECT total_changes()")! - before
        #expect(writes < 260)
        #expect(try ledger.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='activity_intervals'") == 0)
        let json = try ledger.db.query("SELECT counters_json FROM activity_blocks") { $0.text(0) }.joined()
        #expect(blocks.allSatisfy { $0.apps == ["editor", "org.videolan.vlc"] })
        #expect(!json.contains("\"domain\":"))
    }

    @Test func idleRetroactivitySurvivesCategorySwitchesAndBlockBoundary() throws {
        let ledger = try memoryLedger()
        let engine = TrackingEngine(ledger: ledger)
        let start = instant(9, 3)
        try send(engine, .launch(app: "editor", idleSeconds: 0), start)
        for i in 1...59 {
            let time = start + Millis(i) * 5_000
            try send(engine, .appActivated(i % 2 == 0 ? "editor" : "org.videolan.vlc"), time)
            try send(engine, .idleSample(seconds: Double(i * 5)), time)
        }
        try send(engine, .idleSample(seconds: 300), start + 5 * Duration.minute)
        try send(engine, .idleSample(seconds: 0), start + 8 * Duration.minute)
        try send(engine, .shutdown, start + 10 * Duration.minute)
        let blocks = try ledger.blocks(in: Span(start, start + 10 * Duration.minute))
        #expect(blocks.reduce(0) { $0 + $1[.away] } == 8 * Duration.minute)
        #expect(blocks.reduce(0) { $0 + $1[.work] + $1[.privateTime] } == 2 * Duration.minute)
        #expect(ledger.reviews(status: .pending).isEmpty)
    }

    @Test func recoveryCommitsDurableTailOnceAndReviewsOnlyWorkWindowGap() throws {
        let ledger = try memoryLedger()
        let first = TrackingEngine(ledger: ledger)
        let start = instant(16, 40)
        try send(first, .launch(app: "editor", idleSeconds: 0), start)
        try send(first, .appActivated("org.videolan.vlc"), start + 3 * Duration.minute)
        try send(first, .tick, start + 5 * Duration.minute)
        let checkpoint = try #require(ledger.readCheckpoint())
        #expect(!checkpoint.stateJSON.contains("\"app\":"))
        #expect(!checkpoint.stateJSON.contains("\"domain\":"))
        let restart = TrackingEngine(ledger: ledger)
        try restart.recover(now: instant(18))
        let baseline = try ledger.blocks(in: Span(start, instant(18)))
        #expect(baseline.reduce(0) { $0 + $1[.work] } == 3 * Duration.minute)
        #expect(baseline.reduce(0) { $0 + $1[.privateTime] } == 2 * Duration.minute)
        let review = try #require(ledger.reviews(status: .pending).first)
        #expect(review.start == instant(16, 45))
        #expect(review.end == instant(17))
        try restart.recover(now: instant(18))
        #expect(try ledger.blocks(in: Span(start, instant(18))) == baseline)
        #expect(ledger.reviews(status: .pending).count == 1)
    }

    @Test func reviewThresholdIsFifteenMinutesOfContiguousWorkingTime() throws {
        for duration in [15 * Duration.minute - 1, 15 * Duration.minute, 15 * Duration.minute + 1] {
            let ledger = try memoryLedger()
            let start = instant(10)
            try ledger.record([ActivityInterval(span: Span(start, start + duration), category: .gap, reason: .suspension)])
            #expect(ledger.reviews(status: .pending).count == (duration >= 15 * Duration.minute ? 1 : 0))
        }
        let ledger = try memoryLedger()
        try ledger.record([ActivityInterval(span: Span(instant(6), instant(7, 14)), category: .gap, reason: .appNotRunning)])
        #expect(ledger.reviews(status: .pending).isEmpty)
        try ledger.record([ActivityInterval(span: Span(instant(7, 14), instant(7, 15)), category: .gap, reason: .browserUnknown)])
        #expect(ledger.reviews(status: .pending).first?.start == instant(7))
        let weekend = try memoryLedger()
        try weekend.record([ActivityInterval(span: Span(instant(9, day: 14), instant(12, day: 14)), category: .gap, reason: .appNotRunning)])
        #expect(weekend.reviews(status: .pending).isEmpty)
    }

    @Test func mixedBlockGapAnswerPreservesKnownTimeAndCanBeUndone() throws {
        let ledger = try memoryLedger()
        let start = instant(10)
        try ledger.record([
            ActivityInterval(span: Span(start, start + Duration.minute), category: .work, reason: .workWindow),
            ActivityInterval(span: Span(start + Duration.minute, start + 16 * Duration.minute), category: .gap, reason: .suspension),
            ActivityInterval(span: Span(start + 16 * Duration.minute, start + 20 * Duration.minute), category: .privateTime, reason: .privateRule)
        ])
        let review = try #require(ledger.reviews(status: .pending).first)
        try ReviewResolver(ledger: ledger).resolve(review, as: .learn, now: start + 20 * Duration.minute)
        let range = Span(start, start + 20 * Duration.minute)
        let effective = try ledger.effectiveBlocks(in: range)
        #expect(effective.reduce(0) { $0 + $1[.work] } == Duration.minute)
        #expect(effective.reduce(0) { $0 + $1[.learn] } == 15 * Duration.minute)
        #expect(effective.reduce(0) { $0 + $1[.privateTime] } == 4 * Duration.minute)
        let edits = try ledger.adjustments(in: range)
        try ReviewResolver(ledger: ledger).undo(adjustmentID: edits[0].id!, now: range.end)
        #expect(try ledger.effectiveBlocks(in: range).reduce(0) { $0 + $1[.gap] } == 15 * Duration.minute)
        #expect(ledger.reviews(status: .pending).count == 1)
    }

    @Test func partialBlockCorrectionsPreserveCoverageAndOverlappingUndo() throws {
        let ledger = try memoryLedger()
        let start = instant(10)
        let span = Span(start, start + ActivityBlock.length)
        try ledger.record([ActivityInterval(span: Span(start + Duration.minute, start + 3 * Duration.minute), category: .privateTime, reason: .privateRule)])
        let resolver = ReviewResolver(ledger: ledger)
        let first = try resolver.reclassify(span, as: .work, note: "", now: span.end)
        let second = try resolver.reclassify(span, as: .learn, note: "", now: span.end)
        #expect(try ledger.effectiveBlocks(in: span).first?[.learn] == 2 * Duration.minute)
        try resolver.undo(adjustmentID: first, now: span.end)
        #expect(try ledger.effectiveBlocks(in: span).first?[.learn] == 2 * Duration.minute)
        try resolver.undo(adjustmentID: second, now: span.end)
        #expect(try ledger.effectiveBlocks(in: span).first?[.privateTime] == 2 * Duration.minute)
        #expect(throws: (any Error).self) {
            try resolver.reclassify(Span(start + 1, span.end), as: .work, note: "", now: span.end)
        }
        #expect(throws: (any Error).self) {
            try resolver.reclassify(span, as: .work, note: "", now: span.end - 1)
        }
    }

    @Test func blockCSVHasCategoryCountersWithoutAttributionOrInventedOrder() throws {
        let ledger = try memoryLedger()
        try ledger.record([ActivityInterval(span: Span(instant(9), instant(9, 2)), category: .work, reason: .workWindow, app: "editor")])
        let calc = ReportCalculator(ledger: ledger)
        let csv = try CSV.timeline(calc, range: LocalDate(2025, 6, 13)...LocalDate(2025, 6, 13))
        #expect(csv.hasPrefix("block_start,block_end,time_zone,observed_s,work_s,learn_s,private_s,break_s,away_s,unknown_s,pending_s\n"))
        #expect(csv.split(separator: "\n").count == 2)
        #expect(csv.contains(",300.000,300.000,"))
        #expect(!csv.contains("editor"))
    }
}
