import Foundation

extension Ledger {
    public var compactionBackup: String? { getSetting("compaction_backup") }

    public func blocks(in span: Span) throws -> [ActivityBlock] {
        try db.query("SELECT counters_json FROM activity_blocks WHERE start_ms<? AND start_ms>=? ORDER BY start_ms",
                     [.int(span.end), .int(ActivityBlock.floor(span.start))]) { row in
            let block = try JSONDecoder().decode(ActivityBlock.self, from: Data(row.text(0).utf8))
            try block.validate()
            return block
        }
    }

    func saveBlock(_ block: ActivityBlock) throws {
        try block.validate()
        guard let end = block.coverage.last?.end else { return }
        let json = String(decoding: try JSONEncoder().encode(block), as: UTF8.self)
        try db.exec("INSERT INTO activity_blocks(start_ms,end_ms,counters_json) VALUES(?,?,?) ON CONFLICT(start_ms) DO UPDATE SET end_ms=excluded.end_ms,counters_json=excluded.counters_json",
                    [.int(block.start), .int(end), .text(json)])
    }

    /// Commits category durations and app sets without domain observations or app-switch history.
    public func record(_ intervals: [ActivityInterval]) throws {
        try db.transaction {
            for addition in try BlockAccounting.aggregate(intervals) {
                var block = try blocks(in: addition.span).first ?? ActivityBlock(start: addition.start)
                guard !block.coverage.contains(where: { old in addition.coverage.contains(where: { old.overlaps($0) }) }) else {
                    throw LedgerError.overlap(addition.span)
                }
                for category in Category.allCases { block.amounts[category, default: 0] += addition[category] }
                block.coverage = ActivityBlock.union(block.coverage + addition.coverage)
                block.apps = Array(Set(block.apps + addition.apps)).sorted()
                try saveBlock(block)
            }
            for interval in intervals {
                guard !interval.span.isEmpty else { throw LedgerError.badRange }
                if interval.category == .gap { try recordGap(interval.span) }
            }
            if let lastKnown = intervals.last(where: { $0.category != .gap }) {
                try db.exec("DELETE FROM gap_runs WHERE end_ms<=? AND end_ms-start_ms<?",
                            [.int(lastKnown.span.start), .int(15 * Duration.minute)])
            }
        }
    }

    func recordGap(_ span: Span) throws {
        let schedule = schedule()
        var day = schedule.localDate(span.start)
        let last = schedule.localDate(span.end - 1)
        while day <= last {
            if let window = schedule.workWindow(day), let cut = window.intersection(span) {
                let previous = try db.query("SELECT start_ms,end_ms FROM gap_runs ORDER BY end_ms DESC LIMIT 1") { ($0.int(0), $0.int(1)) }.first
                let start: Millis
                let resolved = try previous.map { previous in
                    try db.scalar("SELECT 1 FROM review_items WHERE dedupe_key=? AND status='resolved'", [.text("block-gap:\(previous.0)")]) != nil
                } ?? false
                if let previous, !resolved, previous.1 == cut.start, schedule.localDate(previous.0) == day {
                    start = previous.0
                    try db.exec("UPDATE gap_runs SET end_ms=? WHERE start_ms=?", [.int(cut.end), .int(start)])
                } else {
                    start = cut.start
                    try db.exec("INSERT INTO gap_runs(start_ms,end_ms) VALUES(?,?)", [.int(start), .int(cut.end)])
                }
                if cut.end - start >= 15 * Duration.minute {
                    let id = try addReview(ReviewItem(type: .gap, start: start, end: cut.end, createdAt: cut.end, dedupeKey: "block-gap:\(start)"))
                    try setReviewEnd(id: id, end: cut.end)
                }
            }
            day = schedule.addDays(day, 1)
        }
    }

    public func effectiveBlocks(in span: Span, live: [ActivityInterval] = []) throws -> [ActivityBlock] {
        var result = Dictionary(uniqueKeysWithValues: try blocks(in: span).map { ($0.start, $0) })
        for addition in try BlockAccounting.aggregate(live.filter { $0.span.overlaps(span) }) {
            var block = result[addition.start] ?? ActivityBlock(start: addition.start)
            for category in Category.allCases { block.amounts[category, default: 0] += addition[category] }
            guard !block.coverage.contains(where: { old in addition.coverage.contains(where: { old.overlaps($0) }) }) else {
                throw LedgerError.overlap(addition.span)
            }
            block.coverage = ActivityBlock.union(block.coverage + addition.coverage)
            block.apps = Array(Set(block.apps + addition.apps)).sorted()
            try block.validate()
            result[block.start] = block
        }
        let reviewByID = Dictionary(uniqueKeysWithValues: reviews().compactMap { review in review.id.map { ($0, review) } })
        for adjustment in try adjustments(in: span) {
            var start = ActivityBlock.floor(adjustment.span.start)
            while start < adjustment.span.end {
                var block = result[start] ?? ActivityBlock(start: start)
                var reviewSource: Category?
                var reviewAmount: Millis?
                if let reviewID = adjustment.reviewID,
                   let review = reviewByID[reviewID], let end = review.end,
                   let cut = block.span.intersection(Span(review.start, end)) {
                    reviewSource = review.type == .idle ? .away : .gap
                    reviewAmount = cut.length
                }
                try block.apply(adjustment, reviewSource: reviewSource, reviewAmount: reviewAmount)
                if block.observed > 0 { result[start] = block }
                start += ActivityBlock.length
            }
        }
        return result.values.sorted { $0.start < $1.start }
    }

}
