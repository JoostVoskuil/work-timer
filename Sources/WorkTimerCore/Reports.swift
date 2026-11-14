import Foundation

public enum SegmentSource: Equatable {
    case captured, live
    case correction(Int64)
    case manual(Int64)
}

/// One slice of the effective timeline after corrections are applied. Captured evidence is never rewritten.
public struct Segment: Equatable {
    public var span: Span
    public var category: Category
    public var reason: Reason
    public var app: String?
    public var domain: String?
    public var source: SegmentSource
    public var note: String
    /// True while the slice still awaits the user's answer.
    public var pending: Bool
    public var isConfirmedPersonal: Bool { category == .privateTime && reason != .outsideHours }

    public var explanation: String {
        switch source {
        case .correction(let id): return "Correction #\(id)" + (note.isEmpty ? "" : ": \(note)")
        case .manual(let id): return "Manual entry #\(id)" + (note.isEmpty ? "" : ": \(note)")
        default: return reason.explanation
        }
    }
}

public enum Timeline {
    /// Captured intervals (plus an optional live one) with non-undone adjustments applied in creation order; later wins.
    /// Manual entries also fill time that was never observed.
    public static func effective(intervals: [ActivityInterval], live: ActivityInterval?, adjustments: [Adjustment], in range: Span) -> [Segment] {
        var segs: [Segment] = []
        for i in intervals + (live.map { [$0] } ?? []) {
            guard let cut = i.span.intersection(range) else { continue }
            segs.append(Segment(span: cut, category: i.category, reason: i.reason, app: i.app, domain: i.domain,
                                source: i.source == "live" ? .live : .captured, note: "", pending: i.reason.needsReview))
        }
        for a in adjustments where a.undoneAt == nil {
            guard let aspan = a.span.intersection(range), let id = a.id else { continue }
            var out: [Segment] = []
            var covered: [Span] = []
            for s in segs {
                guard let cut = s.span.intersection(aspan) else { out.append(s); continue }
                covered.append(cut)
                if cut.start > s.span.start { var l = s; l.span = Span(s.span.start, cut.start); out.append(l) }
                if cut.end < s.span.end { var r = s; r.span = Span(cut.end, s.span.end); out.append(r) }
                out.append(Segment(span: cut, category: a.category, reason: .correction, app: s.app, domain: s.domain,
                                   source: .correction(id), note: a.note, pending: false))
            }
            if a.kind == .manual {
                var cursor = aspan.start
                for c in covered.sorted(by: { $0.start < $1.start }) {
                    if c.start > cursor { out.append(manualSegment(Span(cursor, c.start), a, id)) }
                    cursor = max(cursor, c.end)
                }
                if cursor < aspan.end { out.append(manualSegment(Span(cursor, aspan.end), a, id)) }
            }
            segs = out
        }
        return segs.sorted { $0.span.start < $1.span.start }
    }

    private static func manualSegment(_ s: Span, _ a: Adjustment, _ id: Int64) -> Segment {
        Segment(span: s, category: a.category, reason: .manualEntry, app: nil, domain: nil, source: .manual(id), note: a.note, pending: false)
    }
}

public struct DaySummary: Equatable {
    public var date: LocalDate
    public var byCategory: [Category: Millis]
    public var pending: Millis
    public var targetMillis: Millis
    public var isToday: Bool
    public var personal: Millis
    public init(date: LocalDate, byCategory: [Category: Millis], pending: Millis, targetMillis: Millis, isToday: Bool, personal: Millis? = nil) {
        self.date = date; self.byCategory = byCategory; self.pending = pending; self.targetMillis = targetMillis; self.isToday = isToday
        self.personal = personal ?? byCategory[.privateTime, default: 0]
    }
    public var work: Millis { byCategory[.work] ?? 0 }
    public var learn: Millis { byCategory[.learn] ?? 0 }
    public var balance: Millis { work - targetMillis }
}

public struct WeekSummary: Equatable {
    public var weekStart: LocalDate
    public var days: [DaySummary]
    public var work: Millis
    /// Contractual target of the whole week (reflects days off).
    public var fullWeekTarget: Millis
    /// Targets of the scheduled days from Monday through `asOf` (the current day counts fully, so it is incomplete).
    public var toDateTarget: Millis
    public var weeklyCeiling: Millis
    public var pending: Millis
    public var asOf: LocalDate
    public var currentDayIncomplete: Bool
    public var toDateBalance: Millis { workToDate - toDateTarget }
    public var workToDate: Millis
    public var fullWeekBalance: Millis { work - fullWeekTarget }
    public var learn: Millis { days.reduce(0) { $0 + $1.learn } }
    public var workAndLearn: Millis { work + learn }
    public var remainingBeforeCeiling: Millis { max(0, weeklyCeiling - workAndLearn) }
    public var ceilingReached: Bool { workAndLearn >= weeklyCeiling }
    public var ceilingProgress: Double { weeklyCeiling > 0 ? Double(workAndLearn) / Double(weeklyCeiling) : 0 }
}

public struct MonthSummary: Equatable {
    public var range: ClosedRange<LocalDate>
    public var days: [DaySummary]
    public var work: Millis
    public var target: Millis
    public var pending: Millis
    public var balance: Millis { work - target }
    public var learn: Millis { days.reduce(0) { $0 + $1.learn } }
}

public struct AttributionRow: Equatable {
    public var key: String
    public var millis: Millis
}

/// Single source of truth for menu bar, reports, widget snapshots and CSV exports.
public struct ReportCalculator {
    public let ledger: Ledger
    public let schedule: Schedule
    public let live: () -> ActivityInterval?

    public init(ledger: Ledger, schedule: Schedule? = nil, live: @escaping () -> ActivityInterval? = { nil }) {
        self.ledger = ledger
        self.schedule = schedule ?? ledger.schedule()
        self.live = live
    }

    public func segments(in span: Span) -> [Segment] {
        let intervals = (try? ledger.intervals(in: span)) ?? []
        let adjustments = (try? ledger.adjustments(in: span)) ?? []
        let pendingReviews = ledger.reviews(status: .pending)
        return Timeline.effective(intervals: intervals, live: live(), adjustments: adjustments, in: span).flatMap { segment -> [Segment] in
            guard segment.pending else { return [segment] }
            let reviewSpans = pendingReviews.compactMap { review -> Span? in
                let matches: Bool
                switch review.type {
                case .outsideHours: matches = segment.reason == .outsideHours
                case .idle: matches = segment.reason == .idleTimeout
                case .gap: matches = segment.category == .gap
                }
                guard matches else { return nil }
                return segment.span.intersection(Span(review.start, review.end ?? segment.span.end))
            }
            let boundaries = Array(Set([segment.span.start, segment.span.end] + reviewSpans.flatMap { [$0.start, $0.end] })).sorted()
            return zip(boundaries, boundaries.dropFirst()).map { start, end in
                var slice = segment
                slice.span = Span(start, end)
                slice.pending = reviewSpans.contains { $0.start <= start && end <= $0.end }
                return slice
            }
        }
    }

    public func day(_ d: LocalDate, now: Millis) -> DaySummary {
        summarize(d, segments(in: schedule.daySpan(d)), now: now)
    }

    private func summarize(_ d: LocalDate, _ segs: [Segment], now: Millis) -> DaySummary {
        var by: [Category: Millis] = [:]
        var pending: Millis = 0
        for s in segs {
            by[s.category, default: 0] += s.span.length
            if s.pending && s.category != .work { pending += s.span.length }
        }
        let personal = segs.filter(\.isConfirmedPersonal).reduce(Millis(0)) { $0 + $1.span.length }
        return DaySummary(date: d, byCategory: by, pending: pending, targetMillis: schedule.targetMillis(d), isToday: schedule.localDate(now) == d, personal: personal)
    }

    public func days(_ range: ClosedRange<LocalDate>, now: Millis) -> [DaySummary] {
        let all = segments(in: Span(schedule.startOfDay(range.lowerBound), schedule.startOfDay(schedule.addDays(range.upperBound, 1))))
        return schedule.dates(range).map { d in
            let span = schedule.daySpan(d)
            let segs = all.compactMap { s -> Segment? in
                guard let cut = s.span.intersection(span) else { return nil }
                var c = s; c.span = cut; return c
            }
            return summarize(d, segs, now: now)
        }
    }

    public func week(containing d: LocalDate, now: Millis) -> WeekSummary {
        let start = schedule.weekStart(containing: d)
        let end = schedule.addDays(start, 6)
        let ds = days(start...end, now: now)
        let today = schedule.localDate(now)
        let asOf = min(max(start, min(today, end)), end)
        let upTo = ds.filter { $0.date <= asOf }
        let v = schedule.version(on: start)
        return WeekSummary(weekStart: start, days: ds, work: ds.reduce(0) { $0 + $1.work },
                           fullWeekTarget: ds.reduce(0) { $0 + $1.targetMillis },
                           toDateTarget: upTo.reduce(0) { $0 + $1.targetMillis },
                           weeklyCeiling: Millis(v.weeklyCeilingMinutes) * Duration.minute,
                           pending: ds.reduce(0) { $0 + $1.pending }, asOf: asOf,
                           currentDayIncomplete: end >= today && start <= today && asOf == today,
                           workToDate: upTo.reduce(0) { $0 + $1.work })
    }

    public func month(containing d: LocalDate, now: Millis) -> MonthSummary {
        let r = schedule.monthRange(containing: d)
        let ds = days(r, now: now)
        return MonthSummary(range: r, days: ds, work: ds.reduce(0) { $0 + $1.work }, target: ds.reduce(0) { $0 + $1.targetMillis },
                            pending: ds.reduce(0) { $0 + $1.pending })
    }

    /// Work time by app and by domain; work without attribution (manual entries, corrections) is reported separately.
    public func attribution(in span: Span, category: Category = .work) -> (apps: [AttributionRow], domains: [AttributionRow], unattributed: Millis) {
        var apps: [String: Millis] = [:], doms: [String: Millis] = [:]
        var unattributed: Millis = 0
        for s in segments(in: span) where s.category == category {
            if let a = s.app { apps[a, default: 0] += s.span.length } else { unattributed += s.span.length }
            if let d = s.domain { doms[d, default: 0] += s.span.length }
        }
        func rows(_ m: [String: Millis]) -> [AttributionRow] { m.map { AttributionRow(key: $0.key, millis: $0.value) }.sorted { $0.millis > $1.millis } }
        return (rows(apps), rows(doms), unattributed)
    }
}
