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

/// Canonical store. The app is the only writer of `activity_intervals`.
public final class Ledger {
    public static let schemaVersion = 1
    public let db: SQLiteDB

    /// Opens (and migrates) the database. A pre-migration backup is made for an existing file; a failed migration
    /// is rolled back and the previous data stays intact.
    public init(path: String, backupsDirectory: URL? = nil) throws {
        db = try SQLiteDB(path: path)
        try migrate(path: path, backupsDirectory: backupsDirectory)
    }

    public static func inMemory() throws -> Ledger { try Ledger(path: ":memory:") }

    private static let migrations: [[String]] = [[
        """
        CREATE TABLE activity_intervals(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL CHECK(end_ms > start_ms),
          category TEXT NOT NULL, reason TEXT NOT NULL, app TEXT, domain TEXT, source TEXT NOT NULL)
        """,
        "CREATE INDEX idx_intervals_start ON activity_intervals(start_ms)",
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
    ]]

    private func migrate(path: String, backupsDirectory: URL?) throws {
        let current = db.userVersion
        guard current < Self.migrations.count else { return }
        if current > 0, let dir = backupsDirectory {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try db.backup(to: dir.appendingPathComponent("pre-migration-v\(current).sqlite").path)
        }
        for v in current..<Self.migrations.count {
            do {
                try db.transaction {
                    for sql in Self.migrations[v] { try db.exec(sql) }
                    try db.setUserVersion(v + 1)
                }
            } catch { throw SQLiteError.migration("Migration \(v + 1) failed; existing data preserved: \(error)") }
        }
        try seedDefaults()
    }

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
        guard i.span.end > i.span.start else { throw LedgerError.badRange }
        return try db.transaction {
            if let maxEnd = try db.scalar("SELECT MAX(end_ms) FROM activity_intervals"), i.span.start < maxEnd {
                throw LedgerError.overlap(i.span)
            }
            // Coalesce with an identical, adjacent previous interval.
            if let prev = try db.query("SELECT id, end_ms, category, reason, app, domain, source FROM activity_intervals ORDER BY start_ms DESC LIMIT 1", [], { r in
                (r.int(0), r.int(1), r.text(2), r.text(3), r.optText(4), r.optText(5), r.text(6)) }).first,
               prev.1 == i.span.start, prev.2 == i.category.rawValue, prev.3 == i.reason.rawValue,
               prev.4 == i.app, prev.5 == i.domain, prev.6 == i.source {
                try db.exec("UPDATE activity_intervals SET end_ms = ? WHERE id = ?", [.int(i.span.end), .int(prev.0)])
                return prev.0
            }
            try db.exec("INSERT INTO activity_intervals(start_ms,end_ms,category,reason,app,domain,source) VALUES(?,?,?,?,?,?,?)",
                        [.int(i.span.start), .int(i.span.end), .text(i.category.rawValue), .text(i.reason.rawValue),
                         SQLValue(i.app), SQLValue(i.domain), .text(i.source)])
            return db.lastInsertID
        }
    }

    public func intervals(in span: Span) throws -> [ActivityInterval] {
        try db.query("SELECT id,start_ms,end_ms,category,reason,app,domain,source FROM activity_intervals WHERE end_ms > ? AND start_ms < ? ORDER BY start_ms",
                     [.int(span.start), .int(span.end)]) { r in
            ActivityInterval(id: r.int(0), span: Span(r.int(1), r.int(2)), category: Category(rawValue: r.text(3)) ?? .gap,
                             reason: Reason(rawValue: r.text(4)) ?? .correction, app: r.optText(5), domain: r.optText(6), source: r.text(7))
        }
    }

    public func lastIntervalEnd() -> Millis? { try? db.scalar("SELECT MAX(end_ms) FROM activity_intervals") }

    /// Rewrites captured pending intervals of one reason inside `span` (used when an outside-hours session is answered).
    public func reclassify(span: Span, fromReason: Reason, to category: Category, reason: Reason) throws {
        try db.transaction {
            let rows = try intervals(in: span).filter { $0.reason == fromReason }
            for row in rows {
                guard let cut = row.span.intersection(span), let id = row.id else { continue }
                if cut.start > row.span.start {
                    try db.exec("INSERT INTO activity_intervals(start_ms,end_ms,category,reason,app,domain,source) VALUES(?,?,?,?,?,?,?)",
                                [.int(row.span.start), .int(cut.start), .text(row.category.rawValue), .text(row.reason.rawValue), SQLValue(row.app), SQLValue(row.domain), .text(row.source)])
                }
                if cut.end < row.span.end {
                    try db.exec("INSERT INTO activity_intervals(start_ms,end_ms,category,reason,app,domain,source) VALUES(?,?,?,?,?,?,?)",
                                [.int(cut.end), .int(row.span.end), .text(row.category.rawValue), .text(row.reason.rawValue), SQLValue(row.app), SQLValue(row.domain), .text(row.source)])
                }
                try db.exec("UPDATE activity_intervals SET start_ms=?, end_ms=?, category=?, reason=? WHERE id=?",
                            [.int(cut.start), .int(cut.end), .text(category.rawValue), .text(reason.rawValue), .int(id)])
            }
        }
    }

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
                    [.text(r.kind.rawValue), .text(p), .int(r.isWork ? 1 : 0), .text(r.note)])
    }

    public func deleteRule(id: Int64) throws { try db.exec("DELETE FROM classification_rules WHERE id=?", [.int(id)]) }

    public func rules() -> [ClassificationRule] {
        (try? db.query("SELECT id,kind,pattern,is_work,note FROM classification_rules ORDER BY kind, pattern") {
            ClassificationRule(id: $0.int(0), kind: RuleKind(rawValue: $0.text(1)) ?? .app, pattern: $0.text(2), isWork: $0.int(3) == 1, note: $0.text(4))
        }) ?? []
    }

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

    /// A process restart ends every previous live session, even if it never wrote an end event.
    public func closeInterruptedOutsideReviews(observed: Millis) throws {
        let unfinished = try db.query(
            "SELECT id,start_ms FROM review_items WHERE type='outsideHours' AND status='pending' AND end_ms IS NULL ORDER BY start_ms"
        ) { ($0.int(0), $0.int(1)) }
        for (id, start) in unfinished {
            let nextStart = try db.scalar(
                "SELECT MIN(start_ms) FROM review_items WHERE type='outsideHours' AND start_ms>?", [.int(start)]
            ) ?? observed
            let limit = min(observed, nextStart)
            let lastEvidence = try db.scalar(
                "SELECT MAX(MIN(end_ms,?)) FROM activity_intervals WHERE reason=? AND start_ms>=? AND start_ms<?",
                [.int(limit), .text(Reason.outsideHours.rawValue), .int(start), .int(limit)]
            )
            try setReviewEnd(id: id, end: max(start + 1, lastEvidence ?? start + 1))
        }
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
        try db.exec("INSERT INTO manual_adjustments(start_ms,end_ms,category,kind,note,created_ms,review_id) VALUES(?,?,?,?,?,?,?)",
                    [.int(a.span.start), .int(a.span.end), .text(a.category.rawValue), .text(a.kind.rawValue), .text(a.note), .int(a.createdAt), SQLValue(a.reviewID)])
        return db.lastInsertID
    }

    public func undoAdjustment(id: Int64, at: Millis) throws {
        try db.exec("UPDATE manual_adjustments SET undone_ms = ? WHERE id = ? AND undone_ms IS NULL", [.int(at), .int(id)])
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

    /// Deletes captured time, corrections, reviews and delivery records in [span). Intervals straddling the edge are trimmed.
    public func deleteRange(_ span: Span) throws {
        try db.transaction {
            let args: [SQLValue] = [.int(span.start), .int(span.end)]
            try db.exec("DELETE FROM activity_intervals WHERE start_ms >= ? AND end_ms <= ?", args)
            for row in try intervals(in: span) {
                guard let id = row.id else { continue }
                let left = row.span.start < span.start, right = row.span.end > span.end
                if left && right {
                    try db.exec("UPDATE activity_intervals SET end_ms=? WHERE id=?", [.int(span.start), .int(id)])
                    try db.exec("INSERT INTO activity_intervals(start_ms,end_ms,category,reason,app,domain,source) VALUES(?,?,?,?,?,?,?)",
                                [.int(span.end), .int(row.span.end), .text(row.category.rawValue), .text(row.reason.rawValue), SQLValue(row.app), SQLValue(row.domain), .text(row.source)])
                } else if left {
                    try db.exec("UPDATE activity_intervals SET end_ms=? WHERE id=?", [.int(span.start), .int(id)])
                } else if right {
                    try db.exec("UPDATE activity_intervals SET start_ms=? WHERE id=?", [.int(span.end), .int(id)])
                }
            }
            try db.exec("DELETE FROM manual_adjustments WHERE start_ms >= ? AND end_ms <= ?", args)
            try db.exec("DELETE FROM review_items WHERE start_ms >= ? AND start_ms < ?", args)
        }
    }

    public func deleteAllHistory() throws {
        try db.transaction {
            for t in ["activity_intervals", "manual_adjustments", "review_items", "notification_deliveries", "pomodoro_sessions", "tracking_checkpoint"] {
                try db.exec("DELETE FROM \(t)")
            }
        }
        db.checkpoint()
    }
}
