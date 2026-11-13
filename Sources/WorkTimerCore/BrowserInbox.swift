import Foundation

/// Raw native-bridge message -> validated minimal observation. Anything beyond the hostname is discarded.
public enum BrowserMessage {
    public static func parse(_ json: [String: Any]) -> BrowserObservation? {
        guard let id = json["id"] as? String, !id.isEmpty, id.count <= 64,
              let session = json["session"] as? String, !session.isEmpty, session.count <= 64,
              let seq = (json["seq"] as? NSNumber)?.intValue, seq >= 0,
              let observed = (json["observedAt"] as? NSNumber)?.int64Value,
              let kind = json["state"] as? String else { return nil }
        let state: BrowserState
        switch kind {
        case "domain":
            guard let raw = json["host"] as? String, raw.count <= 255, let host = DomainMatcher.normalize(raw) else { return nil }
            state = .domain(host)
        case "private": state = .privateBrowsing
        case "unsupported": state = .unsupported
        case "unavailable": state = .unavailable
        default: return nil
        }
        return BrowserObservation(id: id, session: session, seq: seq, observedAt: observed, state: state)
    }
}

/// Bounded SQLite inbox in the App Group. The Safari handler enqueues with short transactions; only the app drains it.
public final class BrowserInbox {
    public static let capacity = 1_000
    private let db: SQLiteDB

    public init(path: String) throws {
        db = try SQLiteDB(path: path)
        try db.exec("CREATE TABLE IF NOT EXISTS inbox(rowid_ INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE, session TEXT NOT NULL, seq INTEGER NOT NULL, observed_ms INTEGER NOT NULL, state TEXT NOT NULL, host TEXT)")
    }

    /// Idempotent on the event id; drops the oldest rows beyond the capacity.
    public func enqueue(_ o: BrowserObservation) throws {
        let (state, host): (String, String?)
        switch o.state {
        case .domain(let h): (state, host) = ("domain", h)
        case .privateBrowsing: (state, host) = ("private", nil)
        case .unsupported: (state, host) = ("unsupported", nil)
        case .unavailable: (state, host) = ("unavailable", nil)
        }
        var attempts = 0
        while true {
            do {
                try db.transaction {
                    try db.exec("INSERT OR IGNORE INTO inbox(event_id,session,seq,observed_ms,state,host) VALUES(?,?,?,?,?,?)",
                                [.text(o.id), .text(o.session), .int(Int64(o.seq)), .int(o.observedAt), .text(state), SQLValue(host)])
                    try db.exec("DELETE FROM inbox WHERE rowid_ <= (SELECT MAX(rowid_) FROM inbox) - ?", [.int(Int64(Self.capacity))])
                }
                return
            } catch {
                attempts += 1
                if attempts >= 3 { throw error }
                usleep(50_000)
            }
        }
    }

    /// Reads pending observations in order, then acknowledges (deletes) them.
    public func drain(limit: Int = 200) throws -> [BrowserObservation] {
        let rows: [(Int64, BrowserObservation)] = try db.query("SELECT rowid_,event_id,session,seq,observed_ms,state,host FROM inbox ORDER BY rowid_ LIMIT ?", [.int(Int64(limit))]) { r in
            let state: BrowserState
            switch r.text(5) {
            case "domain": state = .domain(r.optText(6) ?? "")
            case "private": state = .privateBrowsing
            case "unsupported": state = .unsupported
            default: state = .unavailable
            }
            return (r.int(0), BrowserObservation(id: r.text(1), session: r.text(2), seq: Int(r.int(3)), observedAt: r.int(4), state: state))
        }
        if let maxID = rows.map({ $0.0 }).max() { try db.exec("DELETE FROM inbox WHERE rowid_ <= ?", [.int(maxID)]) }
        return rows.map { $0.1 }
    }

    public func count() -> Int { Int((try? db.scalar("SELECT COUNT(*) FROM inbox")) ?? 0) }
    public func clear() { try? db.exec("DELETE FROM inbox") }
}
