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
        ledger = try Ledger(path: dir.appendingPathComponent("t.sqlite").path, backupsDirectory: dir.appendingPathComponent("b"))
        try ledger.setReportingTimeZone(tz)
        engine = TrackingEngine(ledger: ledger)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }
    func send(_ e: EngineEvent, _ t: Millis) throws {
        mono = Double(t) / 1000
        _ = try engine.handle(e, at: Stamp(wall: t, mono: mono))
    }
    func calc(now: Millis) -> ReportCalculator { ReportCalculator(ledger: ledger, live: { [engine] in engine.liveInterval(now: now) }) }
    func total(_ cat: WorkTimerCore.Category, _ day: LocalDate, now: Millis) -> Millis {
        ReportCalculator(ledger: ledger, live: { [engine] in engine.liveInterval(now: now) }).day(day, now: now).byCategory[cat] ?? 0
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
            #expect(try r.ledger.intervals(in: Span(start, end)).isEmpty)
        }
    }

    @Test func sleepAndLockAreClippedToWorkWindow() throws {
        for unavailable in [EngineEvent.sleep, .lock] {
            let r = try Rig()
            let start = at(2025, 6, 13, 6)
            let end = at(2025, 6, 13, 18)
            try r.send(.launch(app: "a", idleSeconds: 0), start)
            try r.send(unavailable, start)
            try r.send(.tick, end)
            let intervals = try r.ledger.intervals(in: Span(start, end))
            #expect(intervals.count == 1)
            #expect(intervals.first?.category == .away)
            #expect(intervals.first?.span == Span(at(2025, 6, 13, 7), at(2025, 6, 13, 17)))
            #expect(r.total(.work, fri, now: end) == 0)
        }
    }

    @Test func unlockingOutsideHoursResumesOutsidePrompt() throws {
        let r = try Rig()
        try r.send(.launch(app: "a", idleSeconds: 0), at(2025, 6, 13, 18))
        try r.send(.lock, at(2025, 6, 13, 18))
        try r.send(.unlock, at(2025, 6, 13, 19))
        #expect(r.engine.liveStatus()?.outsidePrompt == true)
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
        #expect(r.total(.idle, fri, now: now) == 20 * Duration.minute)
        #expect(r.total(.work, fri, now: now) == 0)
    }

    @Test func idleReviewRetainsForegroundAppContext() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 10)
        try r.send(.launch(app: "com.apple.Xcode", idleSeconds: 0), start)
        try r.send(.idleSample(seconds: 600), start + 10 * Duration.minute)
        try r.send(.idleSample(seconds: 0), start + 20 * Duration.minute)
        let review = try #require(r.ledger.reviews(status: .pending).first { $0.type == .idle })
        let end = try #require(review.end)
        let segments = r.calc(now: end).segments(in: Span(review.start, end))
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { $0.app == "com.apple.Xcode" && $0.category == .idle })
    }

    @Test func idleReturnKeepsIdlePeriodAndResumesWork() throws {
        let r = try Rig()
        let t0 = at(2025, 6, 13, 10)
        try r.send(.launch(app: "a", idleSeconds: 0), t0)
        try r.send(.idleSample(seconds: 600), t0 + 600_000)
        try r.send(.idleSample(seconds: 0), t0 + 1_200_000)
        try r.send(.tick, t0 + 1_800_000)
        let now = t0 + 1_800_000
        #expect(r.total(.idle, fri, now: now) == 20 * Duration.minute)
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

    @Test func outsideHoursIsPendingNotWork() throws {
        let r = try Rig()
        let t0 = at(2025, 6, 13, 16, 50)
        try r.send(.launch(app: "a", idleSeconds: 0), t0)
        try r.send(.tick, at(2025, 6, 13, 17, 20))
        let now = at(2025, 6, 13, 17, 20)
        #expect(r.total(.work, fri, now: now) == 10 * Duration.minute)
        #expect(r.calc(now: now).day(fri, now: now).pending > 0)
    }

    @Test func outsideHoursAnsweredWorkKeepsLaterTimeOnly() throws {
        let r = try Rig()
        try r.send(.launch(app: "a", idleSeconds: 0), at(2025, 6, 13, 16, 50))
        try r.send(.tick, at(2025, 6, 13, 17, 10))
        try r.send(.answerOutside(.work), at(2025, 6, 13, 17, 10))
        try r.send(.tick, at(2025, 6, 13, 17, 20))
        let now = at(2025, 6, 13, 17, 20)
        #expect(r.total(.work, fri, now: now) == 30 * Duration.minute)
        #expect(r.calc(now: now).day(fri, now: now).pending == 0)
    }

    @Test func liveOutsideReviewCanBeAnsweredBeforeItEnds() throws {
        let r = try Rig()
        try r.send(.launch(app: "a", idleSeconds: 0), at(2025, 6, 13, 18))
        let review = try #require(r.ledger.reviews(status: .pending).first { $0.type == .outsideHours })
        #expect(review.end == nil)
        #expect(r.engine.pendingOutsideReviewID == review.id)
        try r.send(.answerOutside(.work), at(2025, 6, 13, 18, 15))
        #expect(r.engine.pendingOutsideReviewID == nil)
        #expect(r.ledger.reviews(status: .pending).isEmpty)
        try r.send(.tick, at(2025, 6, 13, 18, 30))
        #expect(r.total(.work, fri, now: at(2025, 6, 13, 18, 30)) == 30 * Duration.minute)
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
        let iv = try r.ledger.intervals(in: Span(t0 - Duration.hour, t0 + Duration.hour * 2)).sorted { $0.span.start < $1.span.start }
        for (a, b) in zip(iv, iv.dropFirst()) { #expect(a.span.end <= b.span.start) }
    }

    @Test func crashRecoveryRecordsGap() throws {
        let r = try Rig()
        try r.send(.launch(app: "a", idleSeconds: 0), at(2025, 6, 13, 9))
        try r.send(.tick, at(2025, 6, 13, 9, 30))
        let r2 = TrackingEngine(ledger: r.ledger)
        try r2.recover(now: at(2025, 6, 13, 11))
        let calc = ReportCalculator(ledger: r.ledger, live: { r2.liveInterval(now: at(2025, 6, 13, 11)) })
        let gaps = try r.ledger.intervals(in: Span(at(2025, 6, 13, 9), at(2025, 6, 13, 12))).filter { $0.reason == .appNotRunning }
        #expect(!gaps.isEmpty)
        #expect(calc.day(fri, now: at(2025, 6, 13, 11)).work <= 31 * Duration.minute)
    }

    @Test func restartingClosesOldLiveReviewsAtLastObservation() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 18)
        let observed = at(2025, 6, 13, 18, 10)
        let restarted = at(2025, 6, 13, 19)
        try r.send(.launch(app: "a", idleSeconds: 0), start)
        try r.send(.tick, observed)
        let engine = TrackingEngine(ledger: r.ledger)
        try engine.recover(now: restarted)
        let oldReview = try #require(r.ledger.reviews(status: .pending).first)
        #expect(oldReview.start == start)
        #expect(oldReview.end == observed)
        _ = try engine.handle(.launch(app: "a", idleSeconds: 0), at: Stamp(wall: restarted, mono: Double(restarted) / 1000))
        let reviews = r.ledger.reviews(status: .pending).filter { $0.type == .outsideHours }
        #expect(reviews.filter { $0.end == nil }.count == 1)
        #expect(reviews.last?.start == restarted)
    }

    @Test func repairingHistoricalUnfinishedReviewsUsesOnlyTheirOwnEvidence() throws {
        let r = try Rig()
        let first = at(2025, 6, 13, 18)
        let second = at(2025, 6, 13, 19)
        for start in [first, second] {
            _ = try r.ledger.addReview(ReviewItem(type: .outsideHours, start: start, createdAt: start, dedupeKey: "outside:\(start)"))
            _ = try r.ledger.append(ActivityInterval(span: Span(start, start + 10 * Duration.minute), category: .privateTime, reason: .outsideHours))
        }
        try r.ledger.closeInterruptedOutsideReviews(observed: second + 20 * Duration.minute)
        let reviews = r.ledger.reviews(status: .pending)
        #expect(reviews.map(\.end) == [first + 10 * Duration.minute, second + 10 * Duration.minute])
        try r.ledger.closeInterruptedOutsideReviews(observed: second + Duration.hour)
        #expect(r.ledger.reviews(status: .pending) == reviews)
    }
}

@Suite struct AccountingTests {
    @Test func personalTimeExcludesUnansweredAfterHoursAndRemainsSeparateFromWork() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 18)
        _ = try r.ledger.append(ActivityInterval(span: Span(start, start + Duration.hour), category: .privateTime, reason: .privateRule))
        _ = try r.ledger.append(ActivityInterval(span: Span(start + Duration.hour, start + 2 * Duration.hour), category: .privateTime, reason: .outsideHours))
        let id = try r.ledger.addReview(ReviewItem(type: .outsideHours, start: start + Duration.hour,
                                                 end: start + 2 * Duration.hour, createdAt: start, dedupeKey: "personal-pending"))
        let now = start + 2 * Duration.hour
        let day = LocalDate(2025, 6, 13)
        #expect(r.calc(now: now).day(day, now: now).personal == Duration.hour)
        #expect(r.calc(now: now).day(day, now: now).work == 0)
        let review = try #require(r.ledger.reviews(status: .pending).first { $0.id == id })
        try ReviewResolver(ledger: r.ledger).resolve(review, as: .privateTime, now: now)
        let summary = r.calc(now: now).day(day, now: now)
        #expect(summary.personal == 2 * Duration.hour)
        #expect(summary.pending == 0)
        #expect(summary.work == 0)
    }

    @Test func unknownTimeWithoutReviewIsNotReportedAsPending() throws {
        let r = try Rig()
        let span = Span(at(2025, 6, 13, 10), at(2025, 6, 13, 11))
        _ = try r.ledger.append(ActivityInterval(span: span, category: .gap, reason: .browserUnknown))
        let summary = r.calc(now: span.end).day(LocalDate(2025, 6, 13), now: span.end)
        #expect(r.ledger.reviews(status: .pending).isEmpty)
        #expect(summary.pending == 0)
        #expect(summary.work == 0)
        #expect(summary.byCategory[.gap] == Duration.hour)
    }

    @Test func pendingTotalsAreClippedToUnansweredReviewRange() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 10)
        let end = start + Duration.hour
        _ = try r.ledger.append(ActivityInterval(span: Span(start, end), category: .gap, reason: .appNotRunning))
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

    @Test func reviewingIdleAsWorkIncludesPhoneCallWithoutRewritingEvidence() throws {
        let r = try Rig()
        let start = at(2025, 6, 13, 10)
        let end = at(2025, 6, 13, 10, 30)
        let span = Span(start, end)
        _ = try r.ledger.append(ActivityInterval(span: span, category: .idle, reason: .idleTimeout))
        let id = try r.ledger.addReview(ReviewItem(type: .idle, start: start, end: end, createdAt: end, dedupeKey: "test-idle"))
        let review = try #require(r.ledger.reviews(status: .pending).first { $0.id == id })
        try ReviewResolver(ledger: r.ledger).resolve(review, as: .work, now: end)
        #expect(r.total(.work, LocalDate(2025, 6, 13), now: end) == 30 * Duration.minute)
        #expect(r.ledger.reviews(status: .pending).isEmpty)
        #expect(try r.ledger.intervals(in: span).first?.category == .idle)
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
        #expect(try r.ledger.intervals(in: Span(0, Int64.max / 2)).isEmpty)
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
        #expect(try r.ledger.intervals(in: Span(0, Int64.max / 2)).count == 1)
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
}
