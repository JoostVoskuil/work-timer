import Foundation

public enum ReviewAnswer: String { case work, learn, breakTime, privateTime, away, later
    var category: Category? {
        switch self {
        case .work: return .work
        case .learn: return .learn
        case .breakTime: return .breakTime
        case .privateTime: return .privateTime
        case .away: return .away
        case .later: return nil
        }
    }
}

/// Applies user answers as correction overlays; captured evidence is never rewritten.
public struct ReviewResolver {
    public let ledger: Ledger
    public init(ledger: Ledger) { self.ledger = ledger }

    /// Answers a review, optionally split into several consecutive pieces (e.g. a meeting then a break).
    /// `pieces` must lie inside the review range. "Review later" keeps it pending.
    public func resolve(_ review: ReviewItem, pieces: [(Span, ReviewAnswer)], now: Millis) throws {
        guard let id = review.id, let end = review.end else { throw LedgerError.badRange }
        let range = Span(review.start, end)
        try ledger.db.transaction {
            var kept = false
            for (span, answer) in pieces {
                guard let cut = span.intersection(range) else { continue }
                guard let cat = answer.category else { kept = true; continue }
                switch review.type {
                case .gap:
                    guard cut == range, cat != .away else {
                        throw SQLiteError.invalid("Answer the complete tracking gap. Other time can be corrected by five-minute block.")
                    }
                case .idle:
                    guard cut == range, cat == .work || cat == .away else {
                        throw SQLiteError.invalid("Choose Work or Away for this idle period.")
                    }
                case .outsideHours:
                    throw SQLiteError.invalid("This review cannot be answered here.")
                }
                try ledger.addAdjustment(Adjustment(span: cut, category: cat, note: "Review answer", createdAt: now, reviewID: id))
            }
            if !kept { try ledger.resolveReview(id: id, resolution: "answered", at: now) }
        }
    }

    public func resolve(_ review: ReviewItem, as answer: ReviewAnswer, now: Millis) throws {
        guard let end = review.end else { throw LedgerError.badRange }
        try resolve(review, pieces: [(Span(review.start, end), answer)], now: now)
    }

    /// Manual correction of any selected interval or part of it.
    @discardableResult
    public func reclassify(_ span: Span, as category: Category, note: String, now: Millis) throws -> Int64 {
        guard span.end <= ActivityBlock.floor(now) else { throw SQLiteError.invalid("Wait for this five-minute block to finish before correcting it.") }
        let category = category == .idle ? Category.away : category
        if category == .away {
            let schedule = ledger.schedule()
            let blocks = try ledger.effectiveBlocks(in: span)
            guard blocks.allSatisfy({ block in
                block.coverage.allSatisfy { coverage in
                    schedule.workingSpans(in: coverage).reduce(0) { $0 + $1.length } == coverage.length
                }
            }) else { throw SQLiteError.invalid("Away time can only be assigned within scheduled working hours.") }
        }
        return try ledger.addAdjustment(Adjustment(span: span, category: category, note: note, createdAt: now))
    }

    @discardableResult
    public func reclassify(_ spans: [Span], as category: Category, note: String, now: Millis) throws -> [Int64] {
        guard !spans.isEmpty, spans.allSatisfy({ $0.length == ActivityBlock.length }) else {
            throw SQLiteError.invalid("Select one or more five-minute blocks.")
        }
        return try ledger.db.transaction {
            try Set(spans).sorted { $0.start < $1.start }.map {
                try reclassify($0, as: category, note: note, now: now)
            }
        }
    }

    /// Manual entry for a period; it replaces every recorded block in the range and can be undone.
    @discardableResult
    public func addManualEntry(_ span: Span, as category: Category, note: String, now: Millis) throws -> Int64 {
        guard span.end <= ActivityBlock.floor(now), span.start == ActivityBlock.floor(span.start),
              span.end == ActivityBlock.floor(span.end) else { throw SQLiteError.invalid("Choose completed five-minute boundaries for a manual entry.") }
        guard [.work, .learn, .privateTime, .breakTime].contains(category) else {
            throw SQLiteError.invalid("Choose Work, Learn, Private or Break for a manual entry.")
        }
        return try ledger.addAdjustment(Adjustment(span: span, category: category, kind: .manual, note: note, createdAt: now))
    }

    public func undo(adjustmentID: Int64, now: Millis) throws { try ledger.undoAdjustment(id: adjustmentID, at: now) }
}
