import Foundation

public enum CSV {
    /// Neutralises spreadsheet formula injection and quotes fields as needed.
    public static func escape(_ s: String) -> String {
        var v = s
        if let f = v.first, "=+-@\t\r".contains(f) { v = "'" + v }
        if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            v = "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }

    static func hours(_ ms: Millis) -> String { String(format: "%.4f", Double(ms) / Double(Duration.hour)) }

    /// Daily summary rows for a range, using the same calculator as the app screens.
    public static func summary(_ calc: ReportCalculator, range: ClosedRange<LocalDate>, now: Millis) -> String {
        var lines = ["date,time_zone,work_h,learn_h,private_h,break_h,idle_h,away_h,unknown_h,pending_h,target_h,balance_h"]
        for d in calc.days(range, now: now) {
            let c: (Category) -> String = { hours(d.byCategory[$0] ?? 0) }
            lines.append([d.date.description, calc.schedule.timeZone.identifier, c(.work), c(.learn), c(.privateTime), c(.breakTime), c(.idle), c(.away), c(.gap),
                          hours(d.pending), hours(d.targetMillis), hours(d.balance)].map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One credited category per five-minute block, without switch history.
    public static func timeline(_ calc: ReportCalculator, range: ClosedRange<LocalDate>) throws -> String {
        let span = Span(calc.schedule.startOfDay(range.lowerBound), calc.schedule.startOfDay(calc.schedule.addDays(range.upperBound, 1)))
        let f = ISO8601DateFormatter()
        f.timeZone = calc.schedule.timeZone
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        var lines = ["block_start,block_end,time_zone,observed_s,work_s,learn_s,private_s,break_s,away_s,unknown_s,pending_s"]
        func seconds(_ millis: Millis) -> String { String(format: "%.3f", Double(millis) / 1000) }
        for block in try calc.blocks(in: span) {
            lines.append(([f.string(from: Date(millis: block.span.start)), f.string(from: Date(millis: block.span.end)), calc.schedule.timeZone.identifier,
                           seconds(block.observed)] + [Category.work, .learn, .privateTime, .breakTime, .away, .gap].map { seconds(block[$0]) }
                          + [seconds(calc.pending(in: block))]).map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
