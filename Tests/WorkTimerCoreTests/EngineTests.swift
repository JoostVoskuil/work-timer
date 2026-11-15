import Testing
import Foundation
@testable import WorkTimerCore

private let tz = TimeZone(identifier: "Europe/Amsterdam")!

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, _ s: Int = 0) -> Millis {
    var c = Calendar(identifier: .gregorian); c.timeZone = tz
    return Millis(c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!.timeIntervalSince1970 * 1000)
}

private final class Rig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)")
    let ledger: Ledger
    let engine: TrackingEngine
    var mono = 0.0
    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ledger = try Ledger(path: dir.appendingPathComponent("t.sqlite").path)
        try ledger.setReportingTimeZone(tz)
        engine = TrackingEngine(ledger: ledger)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }
    func send(_ e: EngineEvent, _ t: Millis) throws {
        mono = Double(t) / 1000
        _ = try engine.handle(e, at: Stamp(wall: t, mono: mono))
    }
    func calc(now: Millis) -> ReportCalculator { ReportCalculator(ledger: ledger, liveBlocks: { [engine] in engine.liveIntervals(now: now) }) }
    func total(_ cat: WorkTimerCore.Category, _ day: LocalDate, now: Millis) -> Millis {
        calc(now: now).day(day, now: now).byCategory[cat] ?? 0
    }
}

@Suite struct DomainTests {
    @Test func deceptiveHostnames() {
        #expect(DomainMatcher.matches(host: "www.nu.nl", pattern: "nu.nl"))
        #expect(DomainMatcher.matches(host: "nu.nl", pattern: "nu.nl"))
        #expect(!DomainMatcher.matches(host: "menu.nl", pattern: "nu.nl"))
        #expect(!DomainMatcher.matches(host: "nu.nl.evil.com", pattern: "nu.nl"))
        #expect(!DomainMatcher.matches(host: "evilnu.nl", pattern: "nu.nl"))
    }
    @Test func privateWinsTies() {
        let rs = RuleSet([ClassificationRule(kind: .domain, pattern: "x.com", isWork: true), ClassificationRule(kind: .domain, pattern: "x.com", isWork: false)])
        #expect(rs.decide(app: nil, domain: "x.com")?.isWork == false)
    }
    @Test func defaultPrivateDomain() throws {
        let r = try Rig()
        let rs = RuleSet(r.ledger.rules())
        #expect(rs.decide(app: nil, domain: "www.tweakers.net")?.isWork == false)
        #expect(rs.decide(app: "org.videolan.vlc", domain: nil)?.isWork == false)
    }
}

@Suite struct EngineTests {
    let fri = LocalDate(2025, 6, 13)

    @Test func workWindowCountsFrontApp() throws {
        let r = try Rig()
        try r.send(.launch(app: "com.apple.Xcode", idleSeconds: 0), at(2025, 6, 13, 9))
        try r.send(.tick, at(2025, 6, 13, 10))
        #expect(r.total(.work, fri, now: at(2025, 6, 13, 10)) == Duration.hour)
    }

    @Test func learningSessionIsSeparateAndRespectsPrivateRulesAndLock() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 9)
        try r.send(.launch(app: "com.apple.Xcode", idleSeconds: 0), start)
        try r.send(.learning(true), start)
        try r.send(.appActivated("org.videolan.vlc"), start + 10 * Duration.minute)
        try r.send(.lock, start + 20 * Duration.minute)
        try r.send(.unlock, start + 30 * Duration.minute)
        try r.send(.appActivated("com.apple.Xcode"), start + 30 * Duration.minute)
        try r.send(.learning(false), start + 40 * Duration.minute)
        try r.send(.tick, start + 50 * Duration.minute)
        let summary = r.calc(now: start + 50 * Duration.minute).day(fri, now: start + 50 * Duration.minute)
        #expect(summary.learn == 20 * Duration.minute)
        #expect(summary.personal == 10 * Duration.minute)
        #expect(summary.byCategory[.away] == 10 * Duration.minute)
        #expect(summary.work == 10 * Duration.minute)
    }

    @Test func afterHoursCanBeAnsweredAsLearn() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 18)
        try r.send(.launch(app: "a", idleSeconds: 0), start)
        try r.send(.answerOutside(.learn), start + 10 * Duration.minute)
        try r.send(.tick, start + 20 * Duration.minute)
        let summary = r.calc(now: start + 20 * Duration.minute).day(fri, now: start + 20 * Duration.minute)
        #expect(summary.learn == 10 * Duration.minute)
        #expect(summary.personal == 10 * Duration.minute)
        #expect(summary.work == 0)
        #expect(summary.pending == 0)
        #expect(r.ledger.reviews(status: .pending).isEmpty)
    }

    @Test func manualModeAppliesImmediatelyAndOverridesRules() throws {
        let r = try Rig()
        let t = at(2025, 6, 13, 10)
        try r.ledger.upsertRule(ClassificationRule(kind: .app, pattern: "com.microsoft.outlook", isWork: true))
        r.engine.reloadConfiguration()
        try r.send(.launch(app: "com.microsoft.outlook", idleSeconds: 0), t)
        #expect(r.engine.liveStatus()?.category == .work)
        #expect(r.engine.manualMode == nil)
        #expect(r.engine.scheduledCategory(at: t) == .work)
        for (answer, category) in [(OutsideAnswer.private, WorkTimerCore.Category.privateTime), (.learn, .learn), (.work, .work)] {
            try r.send(.answerOutside(answer), t + Duration.minute)
            #expect(r.engine.liveStatus()?.category == category)
            #expect(r.engine.liveStatus()?.reason == .manualMode)
            #expect(r.engine.manualMode == category)
        }
        try r.send(.automaticMode, t + 2 * Duration.minute)
        #expect(r.engine.manualMode == nil)
        #expect(r.engine.liveStatus()?.reason == .workRule)
    }

    @Test func learnRulesPersistAndClassifyAsLearn() throws {
        let r = try Rig()
        try r.ledger.upsertRule(ClassificationRule(kind: .app, pattern: "com.apple.iBooksX", category: .learn))
        #expect(r.ledger.rules().first { $0.pattern == "com.apple.ibooksx" }?.category == .learn)
        r.engine.reloadConfiguration()
        let t = at(2025, 6, 13, 10)
        try r.send(.launch(app: "com.apple.iBooksX", idleSeconds: 0), t)
        #expect(r.engine.liveStatus()?.category == .learn)
        #expect(r.engine.liveStatus()?.reason == .learnRule)
        let rs = RuleSet([ClassificationRule(kind: .domain, pattern: "x.com", category: .work),
                          ClassificationRule(kind: .domain, pattern: "docs.x.com", category: .learn)])
        #expect(rs.decide(app: nil, domain: "docs.x.com")?.category == .learn)
    }

    @Test func manualModeSurvivesIdleAndLockButEndsAtWorkWindowBoundary() throws {
        let r = try Rig()
        try r.send(.launch(app: "a", idleSeconds: 0), at(2025, 6, 13, 16))
        try r.send(.answerOutside(.private), at(2025, 6, 13, 16))
        try r.send(.idleSample(seconds: 400), at(2025, 6, 13, 16, 10))
        try r.send(.idleSample(seconds: 0), at(2025, 6, 13, 16, 11))
        try r.send(.lock, at(2025, 6, 13, 16, 12))
        try r.send(.unlock, at(2025, 6, 13, 16, 13))
        #expect(r.engine.manualMode == .privateTime)
        #expect(r.engine.liveStatus()?.category == .privateTime)
        try r.send(.tick, at(2025, 6, 13, 17, 10))
        #expect(r.engine.manualMode == nil)
        #expect(r.engine.liveStatus()?.category == .privateTime)
        #expect(r.engine.liveStatus()?.reason == .outsideHoursPrivate)
    }

    @Test func sleepAndLockAreOmittedOutsideWorkHours() throws {
        for unavailable in [EngineEvent.sleep, .lock] {
            let r = try Rig()
            let start = at(2025, 6, 13, 18)
            let end = at(2025, 6, 13, 19)
            try r.send(.launch(app: "a", idleSeconds: 0), start)
            try r.send(unavailable, start)
            try r.send(.tick, end)
            #expect(r.engine.liveStatus() == nil)
            #expect(r.engine.liveInterval(now: end) == nil)
            #expect(try r.calc(now: end).blocks(in: Span(start, end)).isEmpty)
        }
    }

    @Test func loginWindowIsAwayDespiteManualModeRulesAndBreakThenResumes() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 10)
        try r.ledger.upsertRule(ClassificationRule(kind: .app, pattern: "com.apple.loginwindow", category: .work))
        r.engine.reloadConfiguration()
        try r.send(.launch(app: "editor", idleSeconds: 0), start)
        try r.send(.answerOutside(.learn), start)
        try r.send(.pomodoroBreak(true), start)
        try r.send(.appActivated("com.apple.loginwindow"), start + 5 * Duration.minute)
        #expect(r.engine.liveStatus()?.category == .away)
        #expect(r.engine.liveStatus()?.reason == .locked)
        try r.send(.idleSample(seconds: 600), start + 10 * Duration.minute)
        try r.send(.appActivated("editor"), start + 15 * Duration.minute)
        #expect(r.engine.liveStatus()?.category == .breakTime)
        try r.send(.pomodoroBreak(false), start + 15 * Duration.minute)
        #expect(r.engine.liveStatus()?.category == .learn)
        try r.send(.shutdown, start + 20 * Duration.minute)
        let blocks = try r.ledger.blocks(in: Span(start, start + 20 * Duration.minute))
        #expect(blocks.map { $0[.away] } == [0, ActivityBlock.length, ActivityBlock.length, 0])
        #expect(blocks[1].apps.isEmpty && blocks[2].apps.isEmpty)
        #expect(r.ledger.reviews(status: .pending).isEmpty)
    }

    @Test func loginWindowAtLaunchIsClippedToWorkingHours() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 6, 55)
        let end = at(2025, 6, 13, 7, 10)
        try r.send(.launch(app: "com.apple.loginwindow", idleSeconds: 0), start)
        #expect(r.engine.liveStatus() == nil)
        try r.send(.tick, end)
        try r.send(.shutdown, end)
        let blocks = try r.ledger.blocks(in: Span(start, end))
        #expect(blocks.count == 2)
        #expect(blocks.allSatisfy { $0[.away] == ActivityBlock.length && $0.apps.isEmpty })
        #expect(r.ledger.reviews(status: .pending).isEmpty)
    }

    @Test func sleepAndLockAreClippedToWorkWindow() throws {
        for unavailable in [EngineEvent.sleep, .lock] {
            let r = try Rig()
            let start = at(2025, 6, 13, 6)
            let end = at(2025, 6, 13, 18)
            try r.send(.launch(app: "a", idleSeconds: 0), start)
            try r.send(unavailable, start)
            try r.send(.tick, end)
            let blocks = try r.calc(now: end).blocks(in: Span(start, end))
            #expect(blocks.reduce(0) { $0 + $1[.away] } == 10 * Duration.hour)
            #expect(blocks.first?.span.start == at(2025, 6, 13, 7))
            #expect(blocks.last?.span.end == at(2025, 6, 13, 17))
            #expect(r.total(.work, fri, now: end) == 0)
        }
    }

    @Test func unlockingOutsideHoursResumesPrivateWithoutReview() throws {
        let r = try Rig()
        try r.send(.launch(app: "a", idleSeconds: 0), at(2025, 6, 13, 18))
        try r.send(.lock, at(2025, 6, 13, 18))
        try r.send(.unlock, at(2025, 6, 13, 19))
        #expect(r.engine.liveStatus()?.outsidePrompt == false)
        #expect(r.engine.liveStatus()?.category == .privateTime)
        #expect(r.ledger.reviews(status: .pending).isEmpty)
        #expect(r.engine.liveStatus()?.since == at(2025, 6, 13, 19))
    }

    @Test func idleBelowThresholdCountsAsWork() throws {
        let r = try Rig()
        let t0 = at(2025, 6, 13, 10)
        try r.send(.launch(app: "a", idleSeconds: 0), t0)
        try r.send(.idleSample(seconds: 299), t0 + 299_000)
        try r.send(.idleSample(seconds: 0), t0 + 300_000)
        try r.send(.tick, t0 + 600_000)
        #expect(r.total(.idle, fri, now: t0 + 600_000) == 0)
        #expect(r.total(.work, fri, now: t0 + 600_000) == 10 * Duration.minute)
    }

    @Test func idleAtThresholdIsRetroactiveFromLastInput() throws {
        let r = try Rig()
        let t0 = at(2025, 6, 13, 10)
        try r.send(.launch(app: "a", idleSeconds: 0), t0)
        var t = t0
        while t < t0 + 20 * Duration.minute { t += 5_000; try r.send(.idleSample(seconds: Double(t - t0) / 1000), t) }
        let now = t0 + 20 * Duration.minute
        #expect(r.total(.away, fri, now: now) == 20 * Duration.minute)
        #expect(r.total(.work, fri, now: now) == 0)
    }

    @Test func idleDefaultsToAwayWithoutReviewOrAppContext() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 10)
        try r.send(.launch(app: "com.apple.Xcode", idleSeconds: 0), start)
        try r.send(.idleSample(seconds: 600), start + 10 * Duration.minute)
        try r.send(.idleSample(seconds: 0), start + 20 * Duration.minute)
        #expect(r.ledger.reviews(status: .pending).isEmpty)
        #expect(r.total(.away, fri, now: start + 20 * Duration.minute) == 20 * Duration.minute)
        #expect(r.ledger.readCheckpoint()?.stateJSON.contains("com.apple.Xcode") == false)
    }

    @Test func idleReturnKeepsIdlePeriodAndResumesWork() throws {
        let r = try Rig()
        let t0 = at(2025, 6, 13, 10)
        try r.send(.launch(app: "a", idleSeconds: 0), t0)
        try r.send(.idleSample(seconds: 600), t0 + 600_000)
        try r.send(.idleSample(seconds: 0), t0 + 1_200_000)
        try r.send(.tick, t0 + 1_800_000)
        let now = t0 + 1_800_000
        #expect(r.total(.away, fri, now: now) == 20 * Duration.minute)
        #expect(r.total(.work, fri, now: now) == 10 * Duration.minute)
    }

    @Test func privateDomainIsExcluded() throws {
        let r = try Rig()
        let t0 = at(2025, 6, 13, 10)
        try r.send(.launch(app: safariBundleID, idleSeconds: 0), t0)
        for i in 0..<120 {
            let t = t0 + Millis(i) * 5_000
            try r.send(.browser(BrowserObservation(id: "p\(i)", session: "s", seq: i + 1, observedAt: t, state: .domain("www.nu.nl"))), t)
        }
        try r.send(.browser(BrowserObservation(id: "pz", session: "s", seq: 999, observedAt: t0 + 10 * Duration.minute, state: .domain("www.nu.nl"))), t0 + 10 * Duration.minute)
        #expect(r.total(.privateTime, fri, now: t0 + 10 * Duration.minute) == 10 * Duration.minute)
    }

    @Test func staleBrowserContextIsNotCountedAsWork() throws {
        let r = try Rig()
        let t0 = at(2025, 6, 13, 10)
        try r.send(.launch(app: safariBundleID, idleSeconds: 0), t0)
        try r.send(.browser(BrowserObservation(id: "1", session: "s", seq: 1, observedAt: t0, state: .domain("github.com"))), t0)
        try r.send(.tick, t0 + 5 * Duration.minute)
        #expect(r.total(.work, fri, now: t0 + 5 * Duration.minute) < 5 * Duration.minute)
    }

    @Test func outsideHoursIsConfirmedPrivateNotWork() throws {
        let r = try Rig()
        let t0 = at(2025, 6, 13, 16, 50)
        try r.send(.launch(app: "a", idleSeconds: 0), t0)
        try r.send(.tick, at(2025, 6, 13, 17, 20))
        let now = at(2025, 6, 13, 17, 20)
        #expect(r.total(.work, fri, now: now) == 10 * Duration.minute)
        #expect(r.calc(now: now).day(fri, now: now).pending == 0)
        #expect(r.calc(now: now).day(fri, now: now).personal == 20 * Duration.minute)
    }

    @Test func outsideHoursAnsweredWorkKeepsLaterTimeOnly() throws {
        let r = try Rig()
        try r.send(.launch(app: "a", idleSeconds: 0), at(2025, 6, 13, 16, 50))
        try r.send(.tick, at(2025, 6, 13, 17, 10))
        try r.send(.answerOutside(.work), at(2025, 6, 13, 17, 10))
        try r.send(.tick, at(2025, 6, 13, 17, 20))
        let now = at(2025, 6, 13, 17, 20)
        #expect(r.total(.work, fri, now: now) == 20 * Duration.minute)
        #expect(r.calc(now: now).day(fri, now: now).pending == 0)
    }

    @Test func explicitWorkDoesNotNeedAnOutsideReview() throws {
        let r = try Rig()
        try r.send(.launch(app: "a", idleSeconds: 0), at(2025, 6, 13, 18))
        #expect(r.ledger.reviews(status: .pending).isEmpty)
        try r.send(.answerOutside(.work), at(2025, 6, 13, 18, 15))
        #expect(r.engine.pendingOutsideReviewID == nil)
        #expect(r.ledger.reviews(status: .pending).isEmpty)
        try r.send(.tick, at(2025, 6, 13, 18, 30))
        #expect(r.total(.work, fri, now: at(2025, 6, 13, 18, 30)) == 15 * Duration.minute)
    }

    @Test func weekendIsNotWork() throws {
        let r = try Rig()
        try r.send(.launch(app: "a", idleSeconds: 0), at(2025, 6, 14, 10))
        try r.send(.tick, at(2025, 6, 14, 11))
        #expect(r.total(.work, LocalDate(2025, 6, 14), now: at(2025, 6, 14, 11)) == 0)
    }

    @Test func sleepIsNotWork() throws {
        let r = try Rig()
        try r.send(.launch(app: "a", idleSeconds: 0), at(2025, 6, 13, 9))
        try r.send(.sleep, at(2025, 6, 13, 10))
        try r.send(.wake, at(2025, 6, 13, 12))
        try r.send(.tick, at(2025, 6, 13, 12, 30))
        #expect(r.total(.work, fri, now: at(2025, 6, 13, 12, 30)) == 90 * Duration.minute)
    }

    @Test func ledgerNeverOverlaps() throws {
        let r = try Rig()
        let t0 = at(2025, 6, 13, 9)
        try r.send(.launch(app: "a", idleSeconds: 0), t0)
        for i in 1...30 { try r.send(i % 3 == 0 ? .appActivated("b") : .tick, t0 + Millis(i) * 60_000) }
        let iv = try r.calc(now: t0 + 30 * Duration.minute).blocks(in: Span(t0 - Duration.hour, t0 + Duration.hour * 2))
        for (a, b) in zip(iv, iv.dropFirst()) { #expect(a.span.end <= b.span.start) }
    }

    @Test func crashRecoveryRecordsGap() throws {
        let r = try Rig()
        try r.send(.launch(app: "a", idleSeconds: 0), at(2025, 6, 13, 9))
        try r.send(.tick, at(2025, 6, 13, 9, 30))
        let r2 = TrackingEngine(ledger: r.ledger)
        try r2.recover(now: at(2025, 6, 13, 11))
        let calc = ReportCalculator(ledger: r.ledger, liveBlocks: { r2.liveIntervals(now: at(2025, 6, 13, 11)) })
        let gaps = try r.ledger.blocks(in: Span(at(2025, 6, 13, 9), at(2025, 6, 13, 12))).filter { $0[.gap] > 0 }
        #expect(!gaps.isEmpty)
        #expect(calc.day(fri, now: at(2025, 6, 13, 11)).work <= 31 * Duration.minute)
    }

    @Test func restartingOutsideHoursDoesNotCreateReviews() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 18)
        let observed = at(2025, 6, 13, 18, 10)
        let restarted = at(2025, 6, 13, 19)
        try r.send(.launch(app: "a", idleSeconds: 0), start)
        try r.send(.tick, observed)
        let engine = TrackingEngine(ledger: r.ledger)
        try engine.recover(now: restarted)
        #expect(r.ledger.reviews(status: .pending).isEmpty)
        _ = try engine.handle(.launch(app: "a", idleSeconds: 0), at: Stamp(wall: restarted, mono: Double(restarted) / 1000))
        let reviews = r.ledger.reviews(status: .pending).filter { $0.type == .outsideHours }
        #expect(reviews.isEmpty)
    }

    @Test func contiguousUnknownObservationsProduceOneGapReview() throws {
        let r = try Rig()
        let first = at(2025, 6, 13, 10)
        for i in 0..<20 {
            let start = first + Millis(i) * Duration.minute
            _ = try r.ledger.append(ActivityInterval(span: Span(start, start + Duration.minute), category: .gap, reason: .browserUnknown))
        }
        let reviews = r.ledger.reviews(status: .pending)
        #expect(reviews.count == 1)
        #expect(reviews.first?.start == first)
        #expect(reviews.first?.end == first + 20 * Duration.minute)
    }
}

@Suite struct WidgetGraphTests {
    @Test func graphBucketsMatchCorrectedLiveReportsAndIncludeDefaultPrivateTime() throws {
        let r = try Rig()
        _ = try r.ledger.append(ActivityInterval(span: Span(at(2025, 6, 8, 9), at(2025, 6, 8, 11)), category: .work, reason: .workWindow))
        _ = try r.ledger.append(ActivityInterval(span: Span(at(2025, 6, 9, 9), at(2025, 6, 9, 10)), category: .learn, reason: .learning))
        _ = try r.ledger.append(ActivityInterval(span: Span(at(2025, 6, 13, 7), at(2025, 6, 13, 8)), category: .privateTime, reason: .outsideHours))
        _ = try r.ledger.append(ActivityInterval(span: Span(at(2025, 6, 13, 8, 45), at(2025, 6, 13, 10, 15)), category: .work, reason: .workWindow))
        _ = try r.ledger.addAdjustment(Adjustment(span: Span(at(2025, 6, 13, 9, 15), at(2025, 6, 13, 9, 45)), category: .learn, createdAt: at(2025, 6, 13, 12)))
        _ = try r.ledger.append(ActivityInterval(span: Span(at(2025, 6, 13, 10, 15), at(2025, 6, 13, 11)), category: .privateTime, reason: .correction))
        _ = try r.ledger.append(ActivityInterval(span: Span(at(2025, 6, 13, 11), at(2025, 6, 13, 12)), category: .away, reason: .locked))
        let now = at(2025, 6, 13, 12, 30)
        let calc = ReportCalculator(ledger: r.ledger, live: {
            ActivityInterval(span: Span(at(2025, 6, 13, 12), now), category: .work, reason: .workWindow, source: "live")
        })
        let snapshot = SnapshotBuilder.build(calc: calc, now: now, health: HealthStatus(), status: "Work")
        let graph = try #require(snapshot.graphs)
        #expect(graph.hours.count == 24)
        #expect(graph.hours[7].personal == Duration.hour)
        #expect(graph.hours[8].work == 15 * Duration.minute)
        #expect(graph.hours[9].work == 30 * Duration.minute)
        #expect(graph.hours[9].learn == 30 * Duration.minute)
        #expect(graph.hours[10].work == 15 * Duration.minute)
        #expect(graph.hours[10].personal == 45 * Duration.minute)
        #expect(graph.hours[11].work + graph.hours[11].personal + graph.hours[11].learn == 0)
        #expect(graph.hours[12].work == 30 * Duration.minute)
        #expect(graph.hours.reduce(0) { $0 + $1.work } == snapshot.todayWork)
        #expect(graph.hours.reduce(0) { $0 + $1.personal } == calc.day(LocalDate(2025, 6, 13), now: now).personal)
        #expect(graph.hours.reduce(0) { $0 + $1.learn } == snapshot.todayLearn)
        #expect(graph.days.count == 7)
        #expect(graph.days.first?.start == at(2025, 6, 9, 0))
        #expect(graph.days.last?.end == at(2025, 6, 16, 0))
        #expect(graph.days.reduce(0) { $0 + $1.work } == 90 * Duration.minute)
        #expect(graph.days.reduce(0) { $0 + $1.personal } == 105 * Duration.minute)
        #expect(graph.days.reduce(0) { $0 + $1.learn } == 90 * Duration.minute)
        #expect(graph.days[4].work == snapshot.todayWork)
        #expect(graph.days[5].work + graph.days[6].work == 0)
    }

    @Test func hourlyGraphsRespectMidnightAndBothDaylightSavingTransitions() throws {
        for (day, expectedHours) in [(LocalDate(2025, 3, 30), 23), (LocalDate(2025, 10, 26), 25)] {
            let r = try Rig()
            let span = r.ledger.schedule().daySpan(day)
            _ = try r.ledger.append(ActivityInterval(span: Span(span.start - Duration.hour, span.end + Duration.hour), category: .work, reason: .workWindow))
            let snapshot = SnapshotBuilder.build(calc: r.calc(now: span.end - 1), now: span.end - 1, health: HealthStatus(), status: "Work")
            let hours = try #require(snapshot.graphs?.hours)
            #expect(hours.count == expectedHours)
            #expect(hours.first?.start == span.start)
            #expect(hours.last?.end == span.end)
            #expect(hours.allSatisfy { $0.work == Duration.hour })
            #expect(hours.reduce(0) { $0 + $1.work } == snapshot.todayWork)
            for (left, right) in zip(hours, hours.dropFirst()) { #expect(left.end == right.start) }
        }
    }

    @Test func legacySnapshotStillLoadsWithoutInventingGraphData() throws {
        let r = try Rig()
        let now = at(2025, 6, 13, 12)
        let snapshot = SnapshotBuilder.build(calc: r.calc(now: now), now: now, health: HealthStatus(), status: "Work")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "graphs")
        let data = try JSONSerialization.data(withJSONObject: json)
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(legacy.graphs == nil)
        #expect(legacy.todayWork == snapshot.todayWork)
        try data.write(to: SnapshotStore(directory: r.dir).url)
        #expect(SnapshotStore(directory: r.dir).load() == .ok(legacy))
    }
}

@Suite struct AccountingTests {
    @Test func combinedWeeklyLimitIncludesLearnAndAlertsOnceAtExactly45Hours() throws {
        let r = try Rig()
        let start = at(2025, 6, 9, 0)
        _ = try r.ledger.append(ActivityInterval(span: Span(start, start + 39 * Duration.hour), category: .work, reason: .workWindow))
        _ = try r.ledger.append(ActivityInterval(span: Span(start + 39 * Duration.hour, start + 44 * Duration.hour), category: .learn, reason: .learning))
        let day = LocalDate(2025, 6, 13)
        let now = at(2025, 6, 13, 18)
        let alerts = WorkAlerts(ledger: r.ledger)
        var week = r.calc(now: now).week(containing: day, now: now)
        #expect(week.work == 39 * Duration.hour)
        #expect(week.learn == 5 * Duration.hour)
        #expect(week.remainingBeforeCeiling == Duration.hour)
        #expect(try alerts.newlyReachedWeeklyCeiling(week, at: now) == nil)
        _ = try r.ledger.append(ActivityInterval(span: Span(start + 44 * Duration.hour, start + 45 * Duration.hour), category: .learn, reason: .learning))
        week = r.calc(now: now).week(containing: day, now: now)
        #expect(week.workAndLearn == 45 * Duration.hour)
        #expect(week.ceilingReached)
        #expect(week.remainingBeforeCeiling == 0)
        #expect(week.ceilingProgress == 1)
        #expect(try alerts.newlyReachedWeeklyCeiling(week, at: now) != nil)
        #expect(try WorkAlerts(ledger: r.ledger).newlyReachedWeeklyCeiling(week, at: now) == nil)
        #expect(week.toDateBalance == 39 * Duration.hour - week.toDateTarget)
        let snapshot = SnapshotBuilder.build(calc: r.calc(now: now), now: now, health: HealthStatus(), status: "Learn")
        #expect(snapshot.weekLearn == 6 * Duration.hour)
        let csv = CSV.summary(r.calc(now: now), range: day...day, now: now)
        #expect(csv.hasPrefix("date,time_zone,work_h,learn_h,"))

        let nextStart = at(2025, 6, 16, 0)
        _ = try r.ledger.append(ActivityInterval(span: Span(nextStart, nextStart + 46 * Duration.hour), category: .learn, reason: .learning))
        let nextWeek = r.calc(now: nextStart + 46 * Duration.hour).week(containing: LocalDate(2025, 6, 18), now: nextStart + 46 * Duration.hour)
        #expect(nextWeek.remainingBeforeCeiling == 0)
        #expect(nextWeek.workAndLearn == 46 * Duration.hour)
        #expect(try alerts.newlyReachedWeeklyCeiling(nextWeek, at: nextStart + 46 * Duration.hour) != nil)
    }

    @Test func completedReviewCanBeClassifiedAsLearning() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 10)
        let end = start + Duration.hour
        _ = try r.ledger.append(ActivityInterval(span: Span(start, end), category: .gap, reason: .appNotRunning))
        let review = try #require(r.ledger.reviews(status: .pending).first)
        try ReviewResolver(ledger: r.ledger).resolve(review, as: .learn, now: end)
        #expect(r.calc(now: end).day(LocalDate(2025, 6, 13), now: end).learn == Duration.hour)
        #expect(r.calc(now: end).day(LocalDate(2025, 6, 13), now: end).work == 0)
        #expect(r.ledger.reviews(status: .pending).isEmpty)
    }

    @Test func personalTimeIncludesOutsideHoursAndRemainsSeparateFromWork() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 18)
        _ = try r.ledger.append(ActivityInterval(span: Span(start, start + Duration.hour), category: .privateTime, reason: .privateRule))
        _ = try r.ledger.append(ActivityInterval(span: Span(start + Duration.hour, start + 2 * Duration.hour), category: .privateTime, reason: .outsideHours))
        let now = start + 2 * Duration.hour
        let day = LocalDate(2025, 6, 13)
        #expect(r.calc(now: now).day(day, now: now).personal == 2 * Duration.hour)
        #expect(r.calc(now: now).day(day, now: now).work == 0)
        let summary = r.calc(now: now).day(day, now: now)
        #expect(summary.personal == 2 * Duration.hour)
        #expect(summary.pending == 0)
        #expect(summary.work == 0)
    }

    @Test func unknownTimeWithoutReviewIsNotReportedAsPending() throws {
        let r = try Rig()
        let span = Span(at(2025, 6, 13, 10), at(2025, 6, 13, 10, 14))
        _ = try r.ledger.append(ActivityInterval(span: span, category: .gap, reason: .browserUnknown))
        let summary = r.calc(now: span.end).day(LocalDate(2025, 6, 13), now: span.end)
        #expect(r.ledger.reviews(status: .pending).isEmpty)
        #expect(summary.pending == 0)
        #expect(summary.work == 0)
        #expect(summary.byCategory[.gap] == 15 * Duration.minute)
        #expect(try r.ledger.blocks(in: span).reduce(0) { $0 + $1[.gap] } == 14 * Duration.minute)
    }

    @Test func pendingTotalsAreClippedToUnansweredReviewRange() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 10)
        let end = start + Duration.hour
        _ = try r.ledger.append(ActivityInterval(span: Span(start, end), category: .gap, reason: .appNotRunning))
        for existing in r.ledger.reviews(status: .pending) {
            try r.ledger.resolveReview(id: existing.id!, resolution: "replaced test selection", at: end)
        }
        let id = try r.ledger.addReview(ReviewItem(type: .gap, start: start + 10 * Duration.minute,
                                                 end: start + 30 * Duration.minute, createdAt: end, dedupeKey: "pending-gap"))
        let calc = r.calc(now: end)
        #expect(calc.day(LocalDate(2025, 6, 13), now: end).pending == 20 * Duration.minute)
        #expect(calc.week(containing: LocalDate(2025, 6, 13), now: end).pending == 20 * Duration.minute)
        try r.ledger.resolveReview(id: id, resolution: "answered", at: end)
        #expect(calc.day(LocalDate(2025, 6, 13), now: end).pending == 0)
        #expect(calc.week(containing: LocalDate(2025, 6, 13), now: end).pending == 0)
        #expect(calc.day(LocalDate(2025, 6, 13), now: end).work == 0)
    }

    @Test func correctingAwayBlocksAsWorkIncludesPhoneCallAndSupportsUndo() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 10)
        let end = at(2025, 6, 13, 10, 30)
        let span = Span(start, end)
        _ = try r.ledger.append(ActivityInterval(span: span, category: .idle, reason: .idleTimeout))
        let id = try ReviewResolver(ledger: r.ledger).reclassify(span, as: .work, note: "Phone call", now: end)
        #expect(r.total(.work, LocalDate(2025, 6, 13), now: end) == 30 * Duration.minute)
        #expect(r.ledger.reviews(status: .pending).isEmpty)
        #expect(try r.ledger.blocks(in: span).reduce(0) { $0 + $1[.away] } == 30 * Duration.minute)
        try ReviewResolver(ledger: r.ledger).undo(adjustmentID: id, now: end)
        #expect(r.total(.away, LocalDate(2025, 6, 13), now: end) == 30 * Duration.minute)
    }

    @Test func weekToDateBalance() throws {
        let r = try Rig()
        // Mon-Wed 8h each, Wed noon "now"? Use Thursday 08:00 as now: 3 complete days target 24h.
        for d in 9...11 {
            _ = try r.ledger.append(ActivityInterval(span: Span(at(2025, 6, d, 8), at(2025, 6, d, 16)), category: .work, reason: .workWindow))
        }
        let now = at(2025, 6, 11, 18)
        let w = r.calc(now: now).week(containing: LocalDate(2025, 6, 11), now: now)
        #expect(w.work == 24 * Duration.hour)
        #expect(w.toDateBalance == 0)
        #expect(w.fullWeekTarget == 40 * Duration.hour)
        #expect(w.currentDayIncomplete)
    }

    @Test func manualAdjustmentChangesTotals() throws {
        let r = try Rig()
        let s = Span(at(2025, 6, 13, 9), at(2025, 6, 13, 10))
        _ = try r.ledger.append(ActivityInterval(span: s, category: .work, reason: .workWindow))
        _ = try r.ledger.addAdjustment(Adjustment(span: s, category: .privateTime, createdAt: 0))
        let now = at(2025, 6, 13, 12)
        #expect(r.total(.work, LocalDate(2025, 6, 13), now: now) == 0)
        #expect(r.total(.privateTime, LocalDate(2025, 6, 13), now: now) == Duration.hour)
    }

    @Test func manualEntryReplacesRecordedBlocksWithChosenCategory() throws {
        let r = try Rig()
        let fri = LocalDate(2025, 6, 13)
        let recorded = Span(at(2025, 6, 13, 9), at(2025, 6, 13, 10))
        _ = try r.ledger.append(ActivityInterval(span: recorded, category: .work, reason: .workWindow, apps: ["com.apple.Xcode"]))
        let entry = Span(at(2025, 6, 13, 9, 30), at(2025, 6, 13, 10, 30))
        let now = at(2025, 6, 13, 12)
        let id = try ReviewResolver(ledger: r.ledger).addManualEntry(entry, as: .learn, note: "Course", now: now)
        #expect(r.total(.work, fri, now: now) == 30 * Duration.minute)
        #expect(r.total(.learn, fri, now: now) == Duration.hour)
        let replaced = try r.ledger.effectiveBlocks(in: entry)
        #expect(replaced.count == 12)
        #expect(replaced.allSatisfy { $0.amounts == [.learn: ActivityBlock.length] && $0.apps.isEmpty })
        try ReviewResolver(ledger: r.ledger).undo(adjustmentID: id, now: now)
        #expect(r.total(.work, fri, now: now) == Duration.hour)
        #expect(r.total(.learn, fri, now: now) == 0)
    }

    @Test func pomodoroToggleStartsStopsContinuesAndAdvances() throws {
        let r = try Rig()
        let p = PomodoroTimer(ledger: r.ledger)
        func st(_ seconds: Double) -> Stamp { Stamp(wall: Millis(seconds * 1000), mono: seconds) }
        p.toggle(st(0))
        #expect(p.state.status == .running && p.state.phase == .focus)
        p.toggle(st(60))
        #expect(p.state.status == .paused && p.remaining(st(500)) == 24 * Duration.minute)
        p.toggle(st(500))
        #expect(p.state.status == .running)
        p.tick(st(500 + 24 * 60))
        #expect(p.state.status == .waiting)
        p.toggle(st(2000))
        #expect(p.state.status == .running && p.state.phase == .shortBreak)
        p.skipOrEnd(st(2010))
        #expect(p.state.status == .stopped)
    }

    @Test func pomodoroResetReturnsToConfiguredFocusLength() throws {
        let r = try Rig()
        let p = PomodoroTimer(ledger: r.ledger)
        func st(_ seconds: Double) -> Stamp { Stamp(wall: Millis(seconds * 1000), mono: seconds) }
        #expect(p.remaining(st(0)) == 25 * Duration.minute)
        p.toggle(st(0))
        p.toggle(st(120))
        p.reset(st(130))
        #expect(p.state.status == .stopped && p.state.phase == .focus && p.state.completedFocus == 0)
        #expect(p.remaining(st(130)) == 25 * Duration.minute)
        p.setFocusMinutes(40)
        #expect(p.remaining(st(130)) == 40 * Duration.minute)
        #expect(PomodoroTimer(ledger: r.ledger).settings.focusMinutes == 40)
    }

    @Test func alertsFireOncePerThreshold() throws {
        let r = try Rig()
        let wa = WorkAlerts(ledger: r.ledger)
        let sch = r.ledger.schedule()
        let d = LocalDate(2025, 6, 13)
        let now = at(2025, 6, 13, 16)
        let first = wa.newlyCrossed(todayWork: 8 * Duration.hour, date: d, schedule: sch, at: now)
        #expect(first.count == 1)
        #expect(wa.newlyCrossed(todayWork: 8 * Duration.hour, date: d, schedule: sch, at: now).isEmpty)
        #expect(wa.newlyCrossed(todayWork: 9 * Duration.hour, date: d, schedule: sch, at: now).count == 1)
    }

    @Test func csvNeutralisesFormulas() {
        #expect(CSV.escape("=SUM(A1)").hasPrefix("'") || CSV.escape("=SUM(A1)").hasPrefix("\"'"))
        #expect(CSV.escape("a,b") == "\"a,b\"")
    }

    @Test func deleteAllHistory() throws {
        let r = try Rig()
        _ = try r.ledger.append(ActivityInterval(span: Span(at(2025, 6, 13, 9), at(2025, 6, 13, 10)), category: .work, reason: .workWindow))
        try r.ledger.deleteAllHistory()
        #expect(try r.ledger.blocks(in: Span(0, Int64.max / 2)).isEmpty)
    }
}

@Suite struct StorageTests {
    @Test func backupAndRestoreRoundTrip() throws {
        let r = try Rig()
        let s = Span(at(2025, 6, 13, 9), at(2025, 6, 13, 10))
        _ = try r.ledger.append(ActivityInterval(span: s, category: .work, reason: .workWindow))
        let loc = DatabaseLocation(directory: r.dir)
        let mgr = BackupManager(ledger: r.ledger, location: loc)
        let b = r.dir.appendingPathComponent("x.sqlite")
        try mgr.createBackup(to: b)
        try r.ledger.deleteAllHistory()
        try mgr.restore(from: b)
        #expect(try r.ledger.blocks(in: Span(0, Int64.max / 2)).count == 12)
    }

    @Test func invalidBackupRejected() throws {
        let r = try Rig()
        let junk = r.dir.appendingPathComponent("junk.sqlite")
        try Data("not sqlite".utf8).write(to: junk)
        let mgr = BackupManager(ledger: r.ledger, location: DatabaseLocation(directory: r.dir))
        #expect(throws: (any Error).self) { try mgr.restore(from: junk) }
    }

    @Test func inboxIsIdempotentAndBounded() throws {
        let r = try Rig()
        let inbox = try BrowserInbox(path: r.dir.appendingPathComponent("in.sqlite").path)
        let o = BrowserObservation(id: "e1", session: "s", seq: 1, observedAt: 1, state: .domain("a.com"))
        try inbox.enqueue(o); try inbox.enqueue(o)
        #expect(inbox.count() == 1)
        #expect(try inbox.drain().count == 1)
        #expect(inbox.count() == 0)
    }

    @Test func browserMessageParsingRejectsBadHosts() {
        let ok: [String: Any] = ["id": "1", "session": "s", "seq": 1, "observedAt": 5, "state": "domain", "host": "Example.com"]
        #expect(BrowserMessage.parse(ok)?.state == .domain("example.com"))
        var bad = ok; bad["host"] = "https://x.com/path?q=1"
        #expect(BrowserMessage.parse(bad) == nil)
    }

    @Test func snapshotUnavailableWhenMissing() throws {
        let r = try Rig()
        #expect(SnapshotStore(directory: r.dir).load() == .unavailable)
    }

    @Test func widgetReaderLoadsSnapshotPublishedByApp() throws {
        let r = try Rig()
        let sharedDirectory = r.dir.appendingPathComponent("shared")
        let now = at(2025, 6, 13, 12)
        let snapshot = SnapshotBuilder.build(calc: r.calc(now: now), now: now, health: HealthStatus(), status: "Work")
        let writer = SnapshotStore(directory: sharedDirectory)
        let reader = SnapshotStore(directory: sharedDirectory)
        try writer.publish(snapshot)
        #expect(reader.load() == .ok(snapshot))
        var updated = snapshot
        updated.todayLearn = Duration.hour
        try writer.publish(updated)
        #expect(reader.load() == .ok(updated))
    }
}
