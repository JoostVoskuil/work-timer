import Foundation

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

/// Single source of truth for menu bar, reports, widget snapshots and CSV exports.
public struct ReportCalculator {
    public let ledger: Ledger
    public let schedule: Schedule
    public let live: () -> ActivityInterval?
    public let liveBlocks: () -> [ActivityInterval]

    public init(ledger: Ledger, schedule: Schedule? = nil, live: @escaping () -> ActivityInterval? = { nil },
                liveBlocks: @escaping () -> [ActivityInterval] = { [] }) {
        self.ledger = ledger
        self.schedule = schedule ?? ledger.schedule()
        self.live = live
        self.liveBlocks = liveBlocks
    }

    public func blocks(in span: Span) throws -> [ActivityBlock] {
        try ledger.effectiveBlocks(in: span, live: liveBlocks() + (live().map { [$0] } ?? []))
            .compactMap { BlockAccounting.accounted($0, schedule: schedule) }
    }

    public func pending(in block: ActivityBlock) -> Millis {
        pending(in: block, ranges: pendingRanges())
    }

    private func pendingRanges() -> [Span] {
        ActivityBlock.union(ledger.reviews(status: .pending).compactMap { review in
            guard review.type == .gap, let end = review.end else { return nil }
            return Span(review.start, end)
        })
    }

    private func pending(in block: ActivityBlock, ranges: [Span]) -> Millis {
        min(block[.gap], ranges.compactMap { block.span.intersection($0) }.reduce(0) { $0 + $1.length })
    }

    public func day(_ d: LocalDate, now: Millis) -> DaySummary {
        days(d...d, now: now).first!
    }

    private func summarize(_ d: LocalDate, _ blocks: [ActivityBlock], now: Millis, pendingRanges: [Span] = []) -> DaySummary {
        var by: [Category: Millis] = [:]
        var pending: Millis = 0
        for block in blocks {
            for category in Category.allCases { by[category, default: 0] += block[category] }
            pending += self.pending(in: block, ranges: pendingRanges)
        }
        return DaySummary(date: d, byCategory: by, pending: pending, targetMillis: schedule.targetMillis(d), isToday: schedule.localDate(now) == d)
    }

    public func days(_ range: ClosedRange<LocalDate>, now: Millis) -> [DaySummary] {
        let all: [ActivityBlock]
        do {
            all = try blocks(in: Span(schedule.startOfDay(range.lowerBound), schedule.startOfDay(schedule.addDays(range.upperBound, 1))))
        } catch {
            ledger.accountingError = "Could not read activity blocks: \(error)"
            NSLog("%@", ledger.accountingError!)
            return schedule.dates(range).map { summarize($0, [], now: now) }
        }
        let pending = pendingRanges()
        return schedule.dates(range).map { d in
            let span = schedule.daySpan(d)
            return summarize(d, all.filter { $0.span.overlaps(span) }, now: now, pendingRanges: pending)
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

}
