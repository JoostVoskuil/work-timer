import Foundation

public enum LedgerError: Error, CustomStringConvertible {
    case overlap(Span), badRange
    public var description: String {
        switch self {
        case .overlap(let s): return "Interval \(s.start)-\(s.end) overlaps existing canonical time"
        case .badRange: return "Invalid time range"
        }
    }
}

/// Canonical block store. The app is the only writer.
public final class Ledger {
    public static let schemaVersion = 2
    public let db: SQLiteDB
    public var accountingError: String?

    /// Opens the current schema or initializes a new database without converting existing data.
    public init(path: String) throws {
        db = try SQLiteDB(path: path)
        let version = db.userVersion
        guard version == 0 || version == Self.schemaVersion else {
            throw SQLiteError.invalid(version < Self.schemaVersion
                ? "Legacy database schema \(version) is no longer supported. Use the earlier WorkTimer version to convert it first; existing data was preserved."
                : "This database requires a newer WorkTimer.")
        }
        if version == 0 {
            guard try db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") == 0 else {
                throw SQLiteError.invalid("Unversioned database is not empty; existing data was preserved.")
            }
            try db.transaction {
                for sql in Self.schema { try db.exec(sql) }
                try seedDefaults()
                try db.setUserVersion(Self.schemaVersion)
            }
        }
    }

    public static func inMemory() throws -> Ledger { try Ledger(path: ":memory:") }

    private static let schema: [String] = [
        "CREATE TABLE activity_blocks(start_ms INTEGER PRIMARY KEY,end_ms INTEGER NOT NULL,counters_json TEXT NOT NULL)",
        "CREATE TABLE gap_runs(start_ms INTEGER PRIMARY KEY,end_ms INTEGER NOT NULL CHECK(end_ms>start_ms))",
        "CREATE TABLE tracking_checkpoint(id INTEGER PRIMARY KEY CHECK(id = 1), observed_ms INTEGER NOT NULL, clean_quit INTEGER NOT NULL, state_json TEXT NOT NULL)",
        "CREATE TABLE classification_rules(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, pattern TEXT NOT NULL, is_work INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '', UNIQUE(kind, pattern))",
        """
        CREATE TABLE schedule_versions(
          id INTEGER PRIMARY KEY AUTOINCREMENT, effective_from TEXT NOT NULL UNIQUE, working_days INTEGER NOT NULL,
          window_start_min INTEGER NOT NULL, window_end_min INTEGER NOT NULL, daily_target_min INTEGER NOT NULL,
          weekly_target_min INTEGER NOT NULL, daily_ceiling_min INTEGER NOT NULL, weekly_ceiling_min INTEGER NOT NULL)
        """,
        "CREATE TABLE day_overrides(date TEXT PRIMARY KEY, target_min INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '')",
        """
        CREATE TABLE review_items(
          id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER,
          status TEXT NOT NULL, created_ms INTEGER NOT NULL, resolved_ms INTEGER, resolution TEXT, dedupe_key TEXT NOT NULL UNIQUE)
        """,
        "CREATE INDEX idx_reviews_status ON review_items(status)",
        """
        CREATE TABLE manual_adjustments(
          id INTEGER PRIMARY KEY AUTOINCREMENT, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL CHECK(end_ms > start_ms),
          category TEXT NOT NULL, kind TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', created_ms INTEGER NOT NULL,
          undone_ms INTEGER, review_id INTEGER)
        """,
        "CREATE INDEX idx_adjust_start ON manual_adjustments(start_ms)",
        """
        CREATE TABLE pomodoro_sessions(
          id INTEGER PRIMARY KEY AUTOINCREMENT, phase TEXT NOT NULL, planned_ms INTEGER NOT NULL,
          started_ms INTEGER NOT NULL, ended_ms INTEGER, outcome TEXT)
        """,
        "CREATE TABLE notification_deliveries(date TEXT NOT NULL, threshold_min INTEGER NOT NULL, delivered_ms INTEGER NOT NULL, PRIMARY KEY(date, threshold_min))",
        "CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1)",
    ]

    private func seedDefaults() throws {
        if try db.scalar("SELECT COUNT(*) FROM schedule_versions") == 0 { try addScheduleVersion(ScheduleVersion()) }
        if getSetting("rules_seeded") == nil {
            for r in RuleSet.defaults { try upsertRule(r) }
            try setSetting("rules_seeded", "1")
        }
    }

    // MARK: Settings

    public func getSetting(_ key: String) -> String? {
        (try? db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { $0.text(0) })?.first
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try db.exec("INSERT INTO settings(key,value,version) VALUES(?,?,1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }

    public func reportingTimeZone() -> TimeZone {
        getSetting("reporting_zone").flatMap { TimeZone(identifier: $0) } ?? .current
    }

    /// Deliberate change only; history is re-bucketed in the new zone.
    public func setReportingTimeZone(_ tz: TimeZone) throws { try setSetting("reporting_zone", tz.identifier) }

    // MARK: Intervals

    @discardableResult
    public func append(_ i: ActivityInterval) throws -> Int64 {
        try record([i])
        return ActivityBlock.floor(i.span.start)
    }

    public func lastIntervalEnd() -> Millis? { try? db.scalar("SELECT MAX(end_ms) FROM activity_blocks") }

    // MARK: Checkpoint

    public func writeCheckpoint(observed: Millis, cleanQuit: Bool, stateJSON: String) throws {
        try db.exec("INSERT INTO tracking_checkpoint(id,observed_ms,clean_quit,state_json) VALUES(1,?,?,?) ON CONFLICT(id) DO UPDATE SET observed_ms=excluded.observed_ms, clean_quit=excluded.clean_quit, state_json=excluded.state_json",
                    [.int(observed), .int(cleanQuit ? 1 : 0), .text(stateJSON)])
    }

    public func readCheckpoint() -> (observed: Millis, cleanQuit: Bool, stateJSON: String)? {
        (try? db.query("SELECT observed_ms, clean_quit, state_json FROM tracking_checkpoint WHERE id=1") { ($0.int(0), $0.int(1) == 1, $0.text(2)) })?.first
    }

    // MARK: Rules

    public func upsertRule(_ r: ClassificationRule) throws {
        guard let p = r.kind == .domain ? DomainMatcher.normalize(r.pattern) : r.pattern.lowercased() as String?, !p.isEmpty else { throw LedgerError.badRange }
        try db.exec("INSERT INTO classification_rules(kind,pattern,is_work,note) VALUES(?,?,?,?) ON CONFLICT(kind,pattern) DO UPDATE SET is_work=excluded.is_work, note=excluded.note",
                    [.text(r.kind.rawValue), .text(p), .int(Self.ruleCode(r.category)), .text(r.note)])
    }

    public func deleteRule(id: Int64) throws { try db.exec("DELETE FROM classification_rules WHERE id=?", [.int(id)]) }

    public func rules() -> [ClassificationRule] {
        (try? db.query("SELECT id,kind,pattern,is_work,note FROM classification_rules ORDER BY kind, pattern") {
            ClassificationRule(id: $0.int(0), kind: RuleKind(rawValue: $0.text(1)) ?? .app, pattern: $0.text(2), category: Self.ruleCategory($0.int(3)), note: $0.text(4))
        }) ?? []
    }

    /// `is_work` stores 0 = Private, 1 = Work, 2 = Learn; older databases only contain 0 and 1.
    static func ruleCode(_ c: Category) -> Int64 { c == .work ? 1 : c == .learn ? 2 : 0 }
    static func ruleCategory(_ code: Int64) -> Category { code == 1 ? .work : code == 2 ? .learn : .privateTime }

    // MARK: Schedule

    public func addScheduleVersion(_ v: ScheduleVersion) throws {
        let mask = v.workingDays.reduce(0) { $0 | (1 << $1) }
        try db.exec("""
            INSERT INTO schedule_versions(effective_from,working_days,window_start_min,window_end_min,daily_target_min,weekly_target_min,daily_ceiling_min,weekly_ceiling_min)
            VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(effective_from) DO UPDATE SET working_days=excluded.working_days,
            window_start_min=excluded.window_start_min, window_end_min=excluded.window_end_min, daily_target_min=excluded.daily_target_min,
            weekly_target_min=excluded.weekly_target_min, daily_ceiling_min=excluded.daily_ceiling_min, weekly_ceiling_min=excluded.weekly_ceiling_min
            """, [.text(v.effectiveFrom.description), .int(Int64(mask)), .int(Int64(v.windowStartMinute)), .int(Int64(v.windowEndMinute)),
                  .int(Int64(v.dailyTargetMinutes)), .int(Int64(v.weeklyTargetMinutes)), .int(Int64(v.dailyCeilingMinutes)), .int(Int64(v.weeklyCeilingMinutes))])
    }

    public func scheduleVersions() -> [ScheduleVersion] {
        (try? db.query("SELECT id,effective_from,working_days,window_start_min,window_end_min,daily_target_min,weekly_target_min,daily_ceiling_min,weekly_ceiling_min FROM schedule_versions ORDER BY effective_from") { r in
            let mask = Int(r.int(2))
            return ScheduleVersion(id: r.int(0), effectiveFrom: LocalDate(r.text(1)) ?? LocalDate(2000, 1, 1),
                                   workingDays: Set((1...7).filter { mask & (1 << $0) != 0 }),
                                   windowStartMinute: Int(r.int(3)), windowEndMinute: Int(r.int(4)), dailyTargetMinutes: Int(r.int(5)),
                                   weeklyTargetMinutes: Int(r.int(6)), dailyCeilingMinutes: Int(r.int(7)), weeklyCeilingMinutes: Int(r.int(8)))
        }) ?? []
    }

    public func setDayOverride(_ o: DayOverride) throws {
        try db.exec("INSERT INTO day_overrides(date,target_min,note) VALUES(?,?,?) ON CONFLICT(date) DO UPDATE SET target_min=excluded.target_min, note=excluded.note",
                    [.text(o.date.description), .int(Int64(o.targetMinutes)), .text(o.note)])
    }

    public func removeDayOverride(_ d: LocalDate) throws { try db.exec("DELETE FROM day_overrides WHERE date=?", [.text(d.description)]) }

    public func dayOverrides() -> [DayOverride] {
        (try? db.query("SELECT date,target_min,note FROM day_overrides ORDER BY date") {
            DayOverride(date: LocalDate($0.text(0)) ?? LocalDate(2000, 1, 1), targetMinutes: Int($0.int(1)), note: $0.text(2))
        }) ?? []
    }

    public func schedule() -> Schedule {
        Schedule(versions: scheduleVersions(), overrides: dayOverrides(), timeZone: reportingTimeZone())
    }

    // MARK: Reviews

    /// Idempotent on `dedupeKey`: one pending review per session/interval.
    @discardableResult
    public func addReview(_ r: ReviewItem) throws -> Int64 {
        if let id = try db.scalar("SELECT id FROM review_items WHERE dedupe_key = ?", [.text(r.dedupeKey)]) { return id }
        try db.exec("INSERT INTO review_items(type,start_ms,end_ms,status,created_ms,dedupe_key) VALUES(?,?,?,?,?,?)",
                    [.text(r.type.rawValue), .int(r.start), SQLValue(r.end), .text(r.status.rawValue), .int(r.createdAt), .text(r.dedupeKey)])
        return db.lastInsertID
    }

    public func setReviewEnd(id: Int64, end: Millis) throws {
        try db.exec("UPDATE review_items SET end_ms = ? WHERE id = ?", [.int(end), .int(id)])
    }

    public func resolveReview(id: Int64, resolution: String, at: Millis) throws {
        try db.exec("UPDATE review_items SET status='resolved', resolved_ms=?, resolution=? WHERE id=?", [.int(at), .text(resolution), .int(id)])
    }

    public func reviews(status: ReviewStatus? = nil) -> [ReviewItem] {
        let sql = "SELECT id,type,start_ms,end_ms,status,created_ms,resolved_ms,resolution,dedupe_key FROM review_items" + (status == nil ? "" : " WHERE status = ?") + " ORDER BY start_ms"
        return (try? db.query(sql, status.map { [.text($0.rawValue)] } ?? []) { r in
            ReviewItem(id: r.int(0), type: ReviewType(rawValue: r.text(1)) ?? .gap, start: r.int(2), end: r.optInt(3),
                       status: ReviewStatus(rawValue: r.text(4)) ?? .pending, createdAt: r.int(5), resolvedAt: r.optInt(6),
                       resolution: r.optText(7), dedupeKey: r.text(8))
        }) ?? []
    }

    // MARK: Adjustments

    @discardableResult
    public func addAdjustment(_ a: Adjustment) throws -> Int64 {
        guard a.span.end > a.span.start else { throw LedgerError.badRange }
        guard a.kind == .manual || a.reviewID != nil ||
                (a.span.start == ActivityBlock.floor(a.span.start) && a.span.end == ActivityBlock.floor(a.span.end)) else {
            throw SQLiteError.invalid("Select complete five-minute blocks for a correction.")
        }
        try db.exec("INSERT INTO manual_adjustments(start_ms,end_ms,category,kind,note,created_ms,review_id) VALUES(?,?,?,?,?,?,?)",
                    [.int(a.span.start), .int(a.span.end), .text(a.category.rawValue), .text(a.kind.rawValue), .text(a.note), .int(a.createdAt), SQLValue(a.reviewID)])
        return db.lastInsertID
    }

    public func undoAdjustment(id: Int64, at: Millis) throws {
        try db.transaction {
            let reviewID = try db.scalar("SELECT review_id FROM manual_adjustments WHERE id=? AND undone_ms IS NULL", [.int(id)])
            try db.exec("UPDATE manual_adjustments SET undone_ms = ? WHERE id = ? AND undone_ms IS NULL", [.int(at), .int(id)])
            if let reviewID {
                try db.exec("UPDATE review_items SET status='pending',resolved_ms=NULL,resolution=NULL WHERE id=?", [.int(reviewID)])
            }
        }
    }

    public func adjustments(in span: Span, includeUndone: Bool = false) throws -> [Adjustment] {
        try db.query("SELECT id,start_ms,end_ms,category,kind,note,created_ms,undone_ms,review_id FROM manual_adjustments WHERE end_ms > ? AND start_ms < ?" + (includeUndone ? "" : " AND undone_ms IS NULL") + " ORDER BY created_ms, id",
                     [.int(span.start), .int(span.end)]) { r in
            Adjustment(id: r.int(0), span: Span(r.int(1), r.int(2)), category: Category(rawValue: r.text(3)) ?? .gap,
                       kind: AdjustmentKind(rawValue: r.text(4)) ?? .reclassify, note: r.text(5), createdAt: r.int(6), undoneAt: r.optInt(7), reviewID: r.optInt(8))
        }
    }

    // MARK: Notification deliveries

    public func recordDelivery(date: LocalDate, thresholdMinutes: Int, at: Millis) throws -> Bool {
        try db.exec("INSERT OR IGNORE INTO notification_deliveries(date,threshold_min,delivered_ms) VALUES(?,?,?)",
                    [.text(date.description), .int(Int64(thresholdMinutes)), .int(at)])
        return db.changes == 1
    }

    public func wasDelivered(date: LocalDate, thresholdMinutes: Int) -> Bool {
        ((try? db.scalar("SELECT 1 FROM notification_deliveries WHERE date=? AND threshold_min=?", [.text(date.description), .int(Int64(thresholdMinutes))])) ?? nil) != nil
    }

    // MARK: Pomodoro sessions

    @discardableResult
    public func startPomodoroRecord(phase: String, plannedMs: Millis, at: Millis) throws -> Int64 {
        try db.exec("INSERT INTO pomodoro_sessions(phase,planned_ms,started_ms) VALUES(?,?,?)", [.text(phase), .int(plannedMs), .int(at)])
        return db.lastInsertID
    }

    public func endPomodoroRecord(id: Int64, outcome: String, at: Millis) throws {
        try db.exec("UPDATE pomodoro_sessions SET ended_ms=?, outcome=? WHERE id=? AND ended_ms IS NULL", [.int(at), .text(outcome), .int(id)])
    }

    // MARK: Data management

    /// Deletes blocks, corrections and reviews in [span). Straddling corrections are trimmed.
    public func deleteRange(_ span: Span) throws {
        guard span.start == ActivityBlock.floor(span.start), span.end == ActivityBlock.floor(span.end) else {
            throw SQLiteError.invalid("Deletion boundaries must align to five-minute blocks.")
        }
        try db.transaction {
            try db.exec("DELETE FROM activity_blocks WHERE start_ms>=? AND start_ms<?", [.int(span.start), .int(span.end)])
            try db.exec("DELETE FROM gap_runs WHERE start_ms>=? AND end_ms<=?", [.int(span.start), .int(span.end)])
            let args: [SQLValue] = [.int(span.start), .int(span.end)]
            for adjustment in try adjustments(in: span, includeUndone: true) {
                guard let id = adjustment.id else { continue }
                if adjustment.span.start < span.start {
                    try db.exec("UPDATE manual_adjustments SET end_ms=? WHERE id=?", [.int(span.start), .int(id)])
                    if adjustment.span.end > span.end {
                        var right = adjustment
                        right.span.start = span.end
                        let newID = try addAdjustment(right)
                        if let undone = adjustment.undoneAt {
                            try db.exec("UPDATE manual_adjustments SET undone_ms=? WHERE id=?", [.int(undone), .int(newID)])
                        }
                    }
                } else if adjustment.span.end > span.end {
                    try db.exec("UPDATE manual_adjustments SET start_ms=? WHERE id=?", [.int(span.end), .int(id)])
                } else { try db.exec("DELETE FROM manual_adjustments WHERE id=?", [.int(id)]) }
            }
            try db.exec("DELETE FROM review_items WHERE start_ms >= ? AND start_ms < ?", args)
        }
    }

    public func deleteAllHistory() throws {
        try db.transaction {
            for t in ["activity_blocks", "gap_runs", "manual_adjustments", "review_items", "notification_deliveries", "pomodoro_sessions", "tracking_checkpoint"] {
                try db.exec("DELETE FROM \(t)")
            }
        }
        db.checkpoint()
    }
}
