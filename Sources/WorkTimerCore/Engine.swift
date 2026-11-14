import Foundation

public let safariBundleID = "com.apple.Safari"

public enum BrowserState: Equatable {
    case domain(String)
    case privateBrowsing
    case unsupported
    case unavailable
}

public struct BrowserObservation: Equatable {
    public var id: String
    public var session: String
    public var seq: Int
    public var observedAt: Millis
    public var state: BrowserState
    public init(id: String, session: String, seq: Int, observedAt: Millis, state: BrowserState) {
        self.id = id; self.session = session; self.seq = seq; self.observedAt = observedAt; self.state = state
    }
}

public enum OutsideAnswer: String { case work, `private`, later }

public enum EngineEvent {
    case launch(app: String?, idleSeconds: Double)
    case appActivated(String?)
    case browser(BrowserObservation)
    case idleSample(seconds: Double)
    case sleep, wake, lock, unlock, sessionResigned, sessionActivated
    case pause, resume
    case pomodoroBreak(Bool)
    case tick
    case answerOutside(OutsideAnswer)
    case shutdown
}

/// Wall-clock instant plus a monotonic reading (seconds) so clock jumps can be detected.
public struct Stamp {
    public var wall: Millis
    public var mono: Double
    public init(wall: Millis, mono: Double) { self.wall = wall; self.mono = mono }
}

public struct EngineConfig {
    public var idleThresholdSeconds: Double = 300
    public var browserFreshness: Millis = 15_000
    public var checkpointInterval: Millis = 15_000
    public var maxObservationAge: Millis = 60_000
    public var suspensionThreshold: Millis = 30_000
    public var clockJumpBackThreshold: Millis = 5_000
    public var minGapReview: Millis = 60_000
    public init() {}
}

public struct LiveStatus: Equatable {
    public var category: Category
    public var reason: Reason
    public var app: String?
    public var domain: String?
    public var since: Millis
    public var outsidePrompt: Bool
}

private struct CheckpointState: Codable {
    var openStart: Millis?
    var category: Category?
    var reason: Reason?
    var app: String?
    var domain: String?
}

/// Serialized, event-driven tracker producing non-overlapping half-open intervals. Classification follows the
/// plan's precedence: unavailable > break > idle > rules > session answer > work window > outside hours.
public final class TrackingEngine {
    private struct Open {
        var start: Millis
        var category: Category
        var reason: Reason
        var app: String?
        var domain: String?
        func sameKey(_ o: Open) -> Bool { category == o.category && reason == o.reason && app == o.app && domain == o.domain }
    }
    private struct Outside { var start: Millis; var answer: OutsideAnswer?; var reviewID: Int64? }

    public let ledger: Ledger
    public var config: EngineConfig
    private var schedule: Schedule
    private var rules: RuleSet

    private var open: Open?
    private var started = false
    private var lastWall: Millis = 0
    private var lastMono: Double = 0
    private var clockOffset: Millis = 0
    private var lastCheckpoint: Millis = 0

    private var asleep = false, locked = false, inactive = false, paused = false
    private var userIdle = false
    private var idleStart: Millis = 0
    private var breakActive = false
    private var app: String?
    private var browserCtx: (state: BrowserState, receivedAt: Millis)?
    private var outside: Outside?
    private var lastSeq: [String: Int] = [:]
    private var seenIDs: [String] = []

    public init(ledger: Ledger, config: EngineConfig = EngineConfig()) {
        self.ledger = ledger
        self.config = config
        self.schedule = ledger.schedule()
        self.rules = RuleSet(ledger.rules())
    }

    public func reloadConfiguration() {
        schedule = ledger.schedule()
        rules = RuleSet(ledger.rules())
    }

    // MARK: Recovery

    /// Closes any open interval left by a crash/quit at its last durable observation and records the unobserved remainder as a gap.
    public func recover(now: Millis) throws {
        guard let cp = ledger.readCheckpoint() else { return }
        try ledger.db.transaction {
            let floor = ledger.lastIntervalEnd() ?? 0
            let observed = max(cp.observed, floor)
            if !cp.cleanQuit, let st = try? JSONDecoder().decode(CheckpointState.self, from: Data(cp.stateJSON.utf8)),
               let start = st.openStart, let cat = st.category, let reason = st.reason {
                let s = max(start, floor)
                if observed > s {
                    try ledger.append(ActivityInterval(span: Span(s, observed), category: cat, reason: reason, app: st.app, domain: st.domain, source: "recovered"))
                }
            }
            if now > observed {
                try appendGap(Span(observed, now), reason: .appNotRunning)
            }
            try ledger.writeCheckpoint(observed: max(now, observed), cleanQuit: true, stateJSON: "{}")
        }
    }

    private func appendGap(_ span: Span, reason: Reason) throws {
        try ledger.append(ActivityInterval(span: span, category: .gap, reason: reason, source: "recovered"))
        try maybeReviewGap(span)
    }

    private func maybeReviewGap(_ span: Span) throws {
        guard span.length >= config.minGapReview else { return }
        let d0 = schedule.localDate(span.start), d1 = schedule.localDate(span.end - 1)
        var d = d0
        while d <= d1 {
            if let w = schedule.workWindow(d), let cut = w.intersection(span), cut.length >= config.minGapReview {
                try ledger.addReview(ReviewItem(type: .gap, start: span.start, end: span.end, createdAt: span.end, dedupeKey: "gap:\(span.start)"))
                return
            }
            d = schedule.addDays(d, 1)
        }
    }

    // MARK: Event handling

    /// Processes one event atomically. Returns false only for a rejected browser observation.
    @discardableResult
    public func handle(_ event: EngineEvent, at stamp: Stamp) throws -> Bool {
        try ledger.db.transaction {
            var accepted = true
            var eff = try advance(stamp)
            var transition = true
            switch event {
            case .launch(let a, let idle):
                started = true
                lastWall = eff; lastMono = stamp.mono
                app = a
                if idle >= config.idleThresholdSeconds { userIdle = true; idleStart = eff }
            case .appActivated(let a):
                app = a
            case .browser(let o):
                accepted = accept(o, at: eff)
                if accepted { browserCtx = (o.state, eff) }
                transition = false
            case .idleSample(let secs):
                try applyIdle(seconds: secs, at: &eff)
                transition = false
            case .sleep: try endOutside(at: eff); try endIdle(at: eff); asleep = true
            case .wake: asleep = false
            case .lock: try endOutside(at: eff); try endIdle(at: eff); locked = true
            case .unlock: locked = false
            case .sessionResigned: try endOutside(at: eff); try endIdle(at: eff); inactive = true
            case .sessionActivated: inactive = false
            case .pause: try endOutside(at: eff); try endIdle(at: eff); paused = true
            case .resume: paused = false
            case .pomodoroBreak(let b): breakActive = b
            case .tick: transition = false
            case .answerOutside(let a): try answer(a, at: eff)
            case .shutdown:
                try closeOpen(at: eff)
                try endOutside(at: eff)
                try ledger.writeCheckpoint(observed: eff, cleanQuit: true, stateJSON: "{}")
                started = false
                lastWall = eff
                return accepted
            }
            guard started else { return accepted }
            try reclassify(at: eff)
            lastWall = max(lastWall, eff)
            lastMono = stamp.mono
            try checkpoint(at: eff, force: transition)
            return accepted
        }
    }

    /// Normalises the stamp (clock-jump handling) and walks work-window/midnight boundaries up to it.
    private func advance(_ stamp: Stamp) throws -> Millis {
        var eff = stamp.wall + clockOffset
        guard started else { return eff }
        let dMono = Millis(max(0, stamp.mono - lastMono) * 1000)
        if !asleep {
            let drift = (eff - lastWall) - dMono
            if drift < -config.clockJumpBackThreshold {
                clockOffset += (lastWall + dMono) - eff
                eff = lastWall + dMono
            } else if drift > config.suspensionThreshold {
                try closeOpen(at: lastWall)
                try endOutside(at: lastWall)
                if eff > lastWall { try appendGap(Span(lastWall, eff), reason: .suspension) }
                lastWall = eff
            }
        }
        eff = max(eff, lastWall)
        var t = lastWall
        while true {
            let b = schedule.nextBoundary(after: t)
            // A browser context silently goes stale between events; split there so unknown time is not counted as work.
            if let c = browserCtx {
                let stale = c.receivedAt + config.browserFreshness + 1
                if stale > t, stale <= eff, stale < b {
                    try reclassify(at: stale)
                    t = stale
                    continue
                }
            }
            if b > eff { break }
            try reclassify(at: b, boundary: true)
            t = b
        }
        return eff
    }

    private func accept(_ o: BrowserObservation, at now: Millis) -> Bool {
        if seenIDs.contains(o.id) { return false }
        if abs(o.observedAt - now) > config.maxObservationAge { return false }
        if let last = lastSeq[o.session], o.seq <= last { return false }
        if case .domain(let h) = o.state, DomainMatcher.normalize(h) == nil { return false }
        lastSeq[o.session] = o.seq
        seenIDs.append(o.id)
        if seenIDs.count > 256 { seenIDs.removeFirst(128) }
        return true
    }

    // MARK: Idle

    private var tracking: Bool { !(asleep || locked || inactive || paused) }

    private func applyIdle(seconds: Double, at eff: inout Millis) throws {
        guard started, tracking else { return }
        if !userIdle && seconds >= config.idleThresholdSeconds {
            let floor = open?.start ?? lastWall
            let start = max(eff - Millis(seconds * 1000), floor)
            try closeOpen(at: start)
            try endOutside(at: start)
            userIdle = true
            idleStart = start
            try reclassify(at: start)
        } else if userIdle && seconds < config.idleThresholdSeconds {
            let end = max(eff - Millis(seconds * 1000), idleStart)
            try endIdle(at: end)
            try reclassify(at: end)
        }
    }

    private func endIdle(at t: Millis) throws {
        guard userIdle else { return }
        try closeOpen(at: t)
        userIdle = false
        let span = Span(idleStart, t)
        guard span.length > 0 else { return }
        let idle = try ledger.intervals(in: span).filter { $0.category == .idle && $0.reason == .idleTimeout }
        if let first = idle.first, let last = idle.last {
            try ledger.addReview(ReviewItem(type: .idle, start: first.span.start, end: last.span.end, createdAt: t, dedupeKey: "idle:\(first.span.start)"))
        }
    }

    // MARK: Outside-hours sessions

    private func endOutside(at t: Millis) throws {
        guard let o = outside else { return }
        if o.answer == nil, let id = o.reviewID { try ledger.setReviewEnd(id: id, end: max(t, o.start + 1)) }
        outside = nil
    }

    private func answer(_ a: OutsideAnswer, at t: Millis) throws {
        guard var o = outside, o.answer == nil, a != .later else { return }
        try closeOpen(at: t)
        o.answer = a
        let cat: Category = a == .work ? .work : .privateTime
        let reason: Reason = a == .work ? .outsideHoursWork : .outsideHoursPrivate
        if t > o.start { try ledger.reclassify(span: Span(o.start, t), fromReason: .outsideHours, to: cat, reason: reason) }
        if let id = o.reviewID { try ledger.resolveReview(id: id, resolution: a.rawValue, at: t) }
        outside = o
    }

    // MARK: Classification

    private func freshBrowser(at t: Millis) -> BrowserState? {
        guard let c = browserCtx, t - c.receivedAt <= config.browserFreshness else { return nil }
        return c.state
    }

    private func desired(at t: Millis) throws -> Open? {
        func ex(_ c: Category, _ r: Reason, app: String? = nil, domain: String? = nil) -> Open { Open(start: t, category: c, reason: r, app: app, domain: domain) }
        if (asleep || locked) && !schedule.inWorkWindow(t) { return nil }
        if asleep { return ex(.away, .asleep) }
        if locked { return ex(.away, .locked) }
        if inactive { return ex(.away, .sessionInactive) }
        if paused { return ex(.away, .paused) }
        if breakActive { return ex(.breakTime, .pomodoroBreak) }
        if userIdle { return ex(.idle, .idleTimeout) }
        guard let appID = app else { return ex(.gap, .suspension) }
        var domain: String?
        if appID == safariBundleID {
            switch freshBrowser(at: t) {
            case .domain(let h)?: domain = DomainMatcher.normalize(h)
            case .privateBrowsing?: return ex(.privateTime, .privateBrowsing)
            default: return ex(.gap, .browserUnknown, app: appID)
            }
        }
        if let d = rules.decide(app: appID, domain: domain) {
            return ex(d.isWork ? .work : .privateTime, d.reason, app: appID, domain: domain)
        }
        if let a = outside?.answer, a != .later {
            return a == .work ? ex(.work, .outsideHoursWork, app: appID, domain: domain) : ex(.privateTime, .outsideHoursPrivate, app: appID, domain: domain)
        }
        if schedule.inWorkWindow(t) { return ex(.work, .workWindow, app: appID, domain: domain) }
        if outside == nil {
            let id = try ledger.addReview(ReviewItem(type: .outsideHours, start: t, createdAt: t, dedupeKey: "outside:\(t)"))
            outside = Outside(start: t, answer: nil, reviewID: id)
        }
        return ex(.privateTime, .outsideHours, app: appID, domain: domain)
    }

    private func reclassify(at t: Millis, boundary: Bool = false) throws {
        guard started else { return }
        if boundary { try endOutside(at: t) }
        if !tracking || userIdle { try endOutside(at: t) }
        guard let d = try desired(at: t) else {
            try closeOpen(at: t)
            return
        }
        if let o = open, o.sameKey(d) { return }
        try closeOpen(at: t)
        open = d
    }

    private func closeOpen(at t: Millis) throws {
        guard let o = open else { return }
        open = nil
        guard t > o.start else { return }
        let span = Span(o.start, t)
        try ledger.append(ActivityInterval(span: span, category: o.category, reason: o.reason, app: o.app, domain: o.domain))
        if o.category == .gap { try maybeReviewGap(span) }
    }

    private func checkpoint(at t: Millis, force: Bool) throws {
        guard force || t - lastCheckpoint >= config.checkpointInterval else { return }
        lastCheckpoint = t
        let st = CheckpointState(openStart: open?.start, category: open?.category, reason: open?.reason, app: open?.app, domain: open?.domain)
        let json = String(data: (try? JSONEncoder().encode(st)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        try ledger.writeCheckpoint(observed: t, cleanQuit: false, stateJSON: json)
    }

    // MARK: Live view

    /// The running (not yet stored) interval, clipped to `now`, so totals include the present moment.
    public func liveInterval(now: Millis) -> ActivityInterval? {
        guard let o = open, now > o.start else { return nil }
        return ActivityInterval(span: Span(o.start, now), category: o.category, reason: o.reason, app: o.app, domain: o.domain, source: "live")
    }

    public func liveStatus() -> LiveStatus? {
        guard let o = open else { return nil }
        return LiveStatus(category: o.category, reason: o.reason, app: o.app, domain: o.domain, since: o.start,
                          outsidePrompt: outside != nil && outside?.answer == nil)
    }

    public var isRunning: Bool { started }
    public var isTrackingPaused: Bool { paused }
    public var pendingOutsideReviewID: Int64? {
        outside?.answer == nil ? outside?.reviewID : nil
    }
}
