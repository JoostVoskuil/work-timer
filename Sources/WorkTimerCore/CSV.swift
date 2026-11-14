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

    /// Effective timeline rows (after corrections) with classification, reason and pending status.
    public static func timeline(_ calc: ReportCalculator, range: ClosedRange<LocalDate>) -> String {
        let span = Span(calc.schedule.startOfDay(range.lowerBound), calc.schedule.startOfDay(calc.schedule.addDays(range.upperBound, 1)))
        let f = ISO8601DateFormatter()
        f.timeZone = calc.schedule.timeZone
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        var lines = ["start,end,time_zone,duration_s,classification,reason,source,pending,app,domain"]
        for s in calc.segments(in: span) {
            let src: String
            switch s.source { case .captured: src = "captured"; case .live: src = "live"; case .correction: src = "correction"; case .manual: src = "manual" }
            lines.append([f.string(from: Date(millis: s.span.start)), f.string(from: Date(millis: s.span.end)), calc.schedule.timeZone.identifier,
                          String(format: "%.3f", Double(s.span.length) / 1000), s.category.rawValue, s.explanation, src, s.pending ? "pending" : "",
                          s.app ?? "", s.domain ?? ""].map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
