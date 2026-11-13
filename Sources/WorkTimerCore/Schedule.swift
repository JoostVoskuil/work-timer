import Foundation

/// Effective-dated working schedule. Applies from `effectiveFrom` (inclusive) until the next version.
public struct ScheduleVersion: Equatable, Codable {
    public var id: Int64?
    public var effectiveFrom: LocalDate
    /// Calendar weekday numbers, 1 = Sunday ... 7 = Saturday.
    public var workingDays: Set<Int>
    public var windowStartMinute: Int
    public var windowEndMinute: Int
    public var dailyTargetMinutes: Int
    public var weeklyTargetMinutes: Int
    public var dailyCeilingMinutes: Int
    public var weeklyCeilingMinutes: Int

    public init(id: Int64? = nil, effectiveFrom: LocalDate = LocalDate(2000, 1, 1),
                workingDays: Set<Int> = [2, 3, 4, 5, 6], windowStartMinute: Int = 7 * 60, windowEndMinute: Int = 17 * 60,
                dailyTargetMinutes: Int = 8 * 60, weeklyTargetMinutes: Int = 40 * 60,
                dailyCeilingMinutes: Int = 9 * 60, weeklyCeilingMinutes: Int = 45 * 60) {
        self.id = id; self.effectiveFrom = effectiveFrom; self.workingDays = workingDays
        self.windowStartMinute = windowStartMinute; self.windowEndMinute = windowEndMinute
        self.dailyTargetMinutes = dailyTargetMinutes; self.weeklyTargetMinutes = weeklyTargetMinutes
        self.dailyCeilingMinutes = dailyCeilingMinutes; self.weeklyCeilingMinutes = weeklyCeilingMinutes
    }
}

public struct DayOverride: Equatable, Codable {
    public var date: LocalDate
    public var targetMinutes: Int
    public var note: String
    public init(date: LocalDate, targetMinutes: Int = 0, note: String = "") {
        self.date = date; self.targetMinutes = targetMinutes; self.note = note
    }
}

/// Pure schedule math in one explicit reporting time zone. Weeks start on Monday.
public struct Schedule {
    public var versions: [ScheduleVersion]
    public var overrides: [LocalDate: DayOverride]
    public var calendar: Calendar

    public init(versions: [ScheduleVersion] = [ScheduleVersion()], overrides: [DayOverride] = [], timeZone: TimeZone) {
        self.versions = versions.sorted { $0.effectiveFrom < $1.effectiveFrom }
        self.overrides = Dictionary(uniqueKeysWithValues: overrides.map { ($0.date, $0) })
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        self.calendar = cal
    }

    public var timeZone: TimeZone { calendar.timeZone }

    public func version(on date: LocalDate) -> ScheduleVersion {
        versions.last(where: { $0.effectiveFrom <= date }) ?? versions.first ?? ScheduleVersion()
    }

    // MARK: Date conversion

    public func localDate(_ t: Millis) -> LocalDate {
        let c = calendar.dateComponents([.year, .month, .day], from: Date(millis: t))
        return LocalDate(c.year!, c.month!, c.day!)
    }

    public func startOfDay(_ d: LocalDate) -> Millis {
        let date = calendar.date(from: DateComponents(timeZone: timeZone, year: d.year, month: d.month, day: d.day))!
        return calendar.startOfDay(for: date).millis
    }

    public func addDays(_ d: LocalDate, _ n: Int) -> LocalDate {
        let base = calendar.date(from: DateComponents(timeZone: timeZone, year: d.year, month: d.month, day: d.day, hour: 12))!
        let r = calendar.date(byAdding: .day, value: n, to: base)!
        let c = calendar.dateComponents([.year, .month, .day], from: r)
        return LocalDate(c.year!, c.month!, c.day!)
    }

    public func daySpan(_ d: LocalDate) -> Span { Span(startOfDay(d), startOfDay(addDays(d, 1))) }

    public func weekday(_ d: LocalDate) -> Int {
        let base = calendar.date(from: DateComponents(timeZone: timeZone, year: d.year, month: d.month, day: d.day, hour: 12))!
        return calendar.component(.weekday, from: base)
    }

    public func weekStart(containing d: LocalDate) -> LocalDate {
        let wd = weekday(d)
        let sinceMonday = (wd + 5) % 7
        return addDays(d, -sinceMonday)
    }

    public func monthRange(containing d: LocalDate) -> ClosedRange<LocalDate> {
        let first = LocalDate(d.year, d.month, 1)
        let next = d.month == 12 ? LocalDate(d.year + 1, 1, 1) : LocalDate(d.year, d.month + 1, 1)
        return first...addDays(next, -1)
    }

    // MARK: Targets

    public func isScheduled(_ d: LocalDate) -> Bool { version(on: d).workingDays.contains(weekday(d)) }

    /// Contractual target in minutes (days off and unscheduled days are 0).
    public func targetMinutes(_ d: LocalDate) -> Int {
        if let o = overrides[d] { return o.targetMinutes }
        let v = version(on: d)
        return v.workingDays.contains(weekday(d)) ? v.dailyTargetMinutes : 0
    }

    public func targetMillis(_ d: LocalDate) -> Millis { Millis(targetMinutes(d)) * Duration.minute }

    public func dates(_ range: ClosedRange<LocalDate>) -> [LocalDate] {
        var out: [LocalDate] = []
        var d = range.lowerBound
        while d <= range.upperBound { out.append(d); d = addDays(d, 1) }
        return out
    }

    // MARK: Work window

    /// The default work window on a date, or nil when it is not a scheduled weekday.
    public func workWindow(_ d: LocalDate) -> Span? {
        let v = version(on: d)
        guard v.workingDays.contains(weekday(d)) else { return nil }
        let sod = startOfDay(d)
        let next = startOfDay(addDays(d, 1))
        let s = wallMinute(d, v.windowStartMinute, fallback: sod)
        let e = min(wallMinute(d, v.windowEndMinute, fallback: next), next)
        return s < e ? Span(s, e) : nil
    }

    private func wallMinute(_ d: LocalDate, _ minute: Int, fallback: Millis) -> Millis {
        let comps = DateComponents(timeZone: timeZone, year: d.year, month: d.month, day: d.day, hour: minute / 60, minute: minute % 60)
        return calendar.date(from: comps)?.millis ?? fallback
    }

    public func inWorkWindow(_ t: Millis) -> Bool {
        guard let w = workWindow(localDate(t)) else { return false }
        return t >= w.start && t < w.end
    }

    /// Next instant strictly after `t` at which the default classification can change (window edges or midnight).
    public func nextBoundary(after t: Millis) -> Millis {
        let d = localDate(t)
        var candidates = [startOfDay(addDays(d, 1))]
        if let w = workWindow(d) { candidates += [w.start, w.end] }
        return candidates.filter { $0 > t }.min()!
    }
}
