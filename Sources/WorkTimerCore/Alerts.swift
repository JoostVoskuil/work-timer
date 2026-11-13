import Foundation

public struct AlertThreshold: Equatable {
    public var minutes: Int
    public var title: String
    public var body: String
}

public enum LimitState: Equatable { case below, contractDone, ceilingReached }

/// Live threshold evaluation with persistent per-date/threshold deduplication.
public struct WorkAlerts {
    public let ledger: Ledger
    public init(ledger: Ledger) { self.ledger = ledger }

    public static func thresholds(for v: ScheduleVersion) -> [AlertThreshold] {
        [AlertThreshold(minutes: v.dailyTargetMinutes, title: "\(v.dailyTargetMinutes / 60) hours worked today",
                        body: "\(v.dailyTargetMinutes / 60) hours worked today - your contractual day is complete."),
         AlertThreshold(minutes: v.dailyCeilingMinutes, title: "\(v.dailyCeilingMinutes / 60) hours worked today",
                        body: "\(v.dailyCeilingMinutes / 60) hours worked today - your personal daily ceiling is reached.")]
    }

    public static func limitState(work: Millis, version v: ScheduleVersion) -> LimitState {
        if work >= Millis(v.dailyCeilingMinutes) * Duration.minute { return .ceilingReached }
        if work >= Millis(v.dailyTargetMinutes) * Duration.minute { return .contractDone }
        return .below
    }

    /// Returns thresholds newly crossed for `today`, recording them so restarts and later corrections never repeat them.
    /// Only the running app evaluates this; historical edits, imports and restores never replay old alerts.
    public func newlyCrossed(todayWork: Millis, date: LocalDate, schedule: Schedule, at now: Millis) -> [AlertThreshold] {
        var out: [AlertThreshold] = []
        for t in Self.thresholds(for: schedule.version(on: date)) where todayWork >= Millis(t.minutes) * Duration.minute {
            if (try? ledger.recordDelivery(date: date, thresholdMinutes: t.minutes, at: now)) == true { out.append(t) }
        }
        return out
    }

    /// After restore/import: mark what is already crossed today as delivered without notifying.
    public func suppressCrossed(todayWork: Millis, date: LocalDate, schedule: Schedule, at now: Millis) {
        _ = newlyCrossed(todayWork: todayWork, date: date, schedule: schedule, at: now)
    }
}
