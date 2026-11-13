import Foundation

public enum ReviewAnswer: String { case work, breakTime, privateTime, later
    var category: Category? {
        switch self {
        case .work: return .work
        case .breakTime: return .breakTime
        case .privateTime: return .privateTime
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
                // A late outside-hours answer only affects the still-pending part; private-domain and break exclusions stay.
                if review.type == .outsideHours, cat == .work || cat == .privateTime {
                    try ledger.reclassify(span: cut, fromReason: .outsideHours, to: cat, reason: cat == .work ? .outsideHoursWork : .outsideHoursPrivate)
                    continue
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
        try ledger.addAdjustment(Adjustment(span: span, category: category, note: note, createdAt: now))
    }

    /// Manual entry for work done away from the Mac.
    @discardableResult
    public func addManualWork(_ span: Span, note: String, now: Millis) throws -> Int64 {
        try ledger.addAdjustment(Adjustment(span: span, category: .work, kind: .manual, note: note, createdAt: now))
    }

    public func undo(adjustmentID: Int64, now: Millis) throws { try ledger.undoAdjustment(id: adjustmentID, at: now) }
}
