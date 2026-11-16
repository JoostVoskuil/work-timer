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

public enum OutsideAnswer: String { case work, learn, `private`, later }

public enum EngineEvent {
    case launch(app: String?, idleSeconds: Double)
    case appActivated(String?)
    case browser(BrowserObservation)
    case idleSample(seconds: Double)
    case sleep, wake, lock, unlock, sessionResigned, sessionActivated
    case pause, resume
    case pomodoroBreak(Bool)
    case learning(Bool)
    case tick
    case answerOutside(OutsideAnswer)
    /// Clears a manual mode so the schedule and rules decide again.
    case automaticMode
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
    var pending: [ActivityInterval]? = nil
    var appsByBlock: [Millis: [String]]? = nil
}

/// Serialized, event-driven tracker producing non-overlapping half-open intervals. Classification follows the
/// plan's precedence: unavailable > break > idle > rules > session answer > work window > outside hours.
public final class TrackingEngine {
    private static let shortIdleLimit = 15 * Duration.minute

    private struct Open {
        var start: Millis
        var category: Category
        var reason: Reason
        var app: String?
        var domain: String?
        func sameKey(_ o: Open) -> Bool { category == o.category && reason == o.reason && app == o.app }
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
    private var learningActive = false
    private var app: String?
    private var browserCtx: (state: BrowserState, receivedAt: Millis)?
    private var outside: Outside?
    private var lastSeq: [String: Int] = [:]
    private var seenIDs: [String] = []
    private var pending: [ActivityInterval] = []
    private var sessionStart: Millis = 0

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
            if !cp.cleanQuit {
                let st = try JSONDecoder().decode(CheckpointState.self, from: Data(cp.stateJSON.utf8))
                for interval in st.pending ?? [] {
                    if let cut = interval.span.intersection(Span(floor, observed)) {
                        let apps = st.appsByBlock?[ActivityBlock.floor(cut.start)] ?? interval.apps
                        for fragment in accountedIntervals(ActivityInterval(span: cut, category: interval.category, reason: interval.reason, apps: apps)) {
                            try ledger.append(fragment)
                        }
                    }
                }
                if let start = st.openStart, let cat = st.category, let reason = st.reason {
                    let s = max(start, ledger.lastIntervalEnd() ?? floor)
                    if observed > s {
                        for fragment in accountedIntervals(ActivityInterval(span: Span(s, observed), category: cat, reason: reason)) {
                            try ledger.append(fragment)
                        }
                    }
                }
            }
            if now > observed {
                try appendGap(Span(observed, now), reason: .appNotRunning)
            }
            try ledger.writeCheckpoint(observed: max(now, observed), cleanQuit: true, stateJSON: "{}")
        }
    }

    private func appendGap(_ span: Span, reason: Reason) throws {
        buffer(ActivityInterval(span: span, category: .gap, reason: reason, source: "recovered"))
        if !started {
            try ledger.record(pending)
            pending = []
        }
    }

    // MARK: Event handling

    /// Processes one event atomically. Returns false only for a rejected browser observation.
    @discardableResult
    public func handle(_ event: EngineEvent, at stamp: Stamp) throws -> Bool {
        do {
            var accepted = true
            var eff = try advance(stamp)
            switch event {
            case .launch(let a, let idle):
                started = true
                sessionStart = eff
                lastWall = eff; lastMono = stamp.mono
                app = a
                if idle >= config.idleThresholdSeconds { userIdle = true; idleStart = eff }
            case .appActivated(let a):
                if Self.isLoginWindow(a) && !Self.isLoginWindow(app) {
                    try endPrompt(at: eff)
                    try endIdle(at: eff)
                }
                app = a
            case .browser(let o):
                accepted = accept(o, at: eff)
                if accepted { browserCtx = (o.state, eff) }
            case .idleSample(let secs):
                try applyIdle(seconds: secs, at: &eff)
            case .sleep: try endPrompt(at: eff); try endIdle(at: eff); asleep = true
            case .wake: asleep = false
            case .lock: try endPrompt(at: eff); try endIdle(at: eff); locked = true
            case .unlock: locked = false
            case .sessionResigned: try endPrompt(at: eff); try endIdle(at: eff); inactive = true
            case .sessionActivated: inactive = false
            case .pause: try endPrompt(at: eff); try endIdle(at: eff); paused = true
            case .resume: paused = false
            case .pomodoroBreak(let b): breakActive = b
            case .learning(let enabled):
                try endOutside(at: eff)
                learningActive = enabled
            case .tick: break
            case .answerOutside(let a): try answer(a, at: eff)
            case .automaticMode: try endOutside(at: eff)
            case .shutdown:
                try closeOpen(at: eff)
                try endOutside(at: eff)
                try ledger.db.transaction {
                    try ledger.record(pending)
                    try ledger.writeCheckpoint(observed: eff, cleanQuit: true, stateJSON: "{}")
                }
                pending = []
                started = false
                lastWall = eff
                return accepted
            }
            guard started else { return accepted }
            try reclassify(at: eff)
            lastWall = max(lastWall, eff)
            lastMono = stamp.mono
            let force: Bool
            switch event {
            case .launch, .sleep, .lock, .pause, .sessionResigned: force = true
            default: force = false
            }
            try checkpoint(at: eff, force: force)
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
                try endPrompt(at: lastWall)
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

    private static func isLoginWindow(_ app: String?) -> Bool {
        app?.caseInsensitiveCompare("com.apple.loginwindow") == .orderedSame
    }

    private var tracking: Bool { !(asleep || locked || inactive || paused || Self.isLoginWindow(app)) }

    private func applyIdle(seconds: Double, at eff: inout Millis) throws {
        guard started, tracking else { return }
        if !userIdle && seconds >= config.idleThresholdSeconds {
            let floor = max(sessionStart, ledger.lastIntervalEnd() ?? sessionStart)
            let start = max(eff - Millis(seconds * 1000), floor)
            if let o = open, o.start < start { try closeOpen(at: start) }
            else { open = nil }
            pending = pending.compactMap { interval in
                guard interval.span.start < start else { return nil }
                var interval = interval
                interval.span.end = min(interval.span.end, start)
                return interval
            }
            try endPrompt(at: start)
            userIdle = true
            idleStart = start
            if eff > start {
                buffer(ActivityInterval(span: Span(start, eff), category: breakActive ? .breakTime : .away,
                                        reason: breakActive ? .pomodoroBreak : .idleTimeout))
            }
        } else if userIdle && seconds < config.idleThresholdSeconds {
            let end = max(eff - Millis(seconds * 1000), idleStart)
            try endIdle(at: end)
            try finishIdle(at: end)
            try reclassify(at: end)
        }
    }

    private func finishIdle(at end: Millis) throws {
        let spans = schedule.workingSpans(in: Span(idleStart, end))
        guard !spans.isEmpty else { return }
        let duration = spans.reduce(0) { $0 + $1.length }
        let isShortBreak = duration <= Self.shortIdleLimit
        try ledger.db.transaction {
            for span in spans {
                let id = try ledger.addReview(ReviewItem(type: .idle, start: span.start, end: span.end,
                                                         createdAt: end, dedupeKey: "idle:\(span.start)"))
                if isShortBreak {
                    try ledger.addAdjustment(Adjustment(span: span, category: .work,
                                                        note: "Short break counted as work", createdAt: end,
                                                        reviewID: id))
                    try ledger.resolveReview(id: id, resolution: "short-break-work", at: end)
                }
            }
        }
    }

    private func endIdle(at t: Millis) throws {
        guard userIdle else { return }
        try closeOpen(at: t)
        userIdle = false
    }

    // MARK: Outside-hours sessions

    private func endOutside(at t: Millis) throws {
        guard let o = outside else { return }
        if o.answer == nil, let id = o.reviewID { try ledger.setReviewEnd(id: id, end: max(t, o.start + 1)) }
        outside = nil
    }

    /// Ends an unanswered after-hours prompt. A chosen manual mode survives idle, lock and sleep.
    private func endPrompt(at t: Millis) throws {
        guard outside?.answer == nil else { return }
        try endOutside(at: t)
    }

    /// A manual mode overrides the schedule and app/domain rules until Automatic or the next work-window boundary.
    private func answer(_ a: OutsideAnswer, at t: Millis) throws {
        guard a != .later else { return }
        try closeOpen(at: t)
        learningActive = false
        outside = Outside(start: t, answer: a, reviewID: nil)
    }

    // MARK: Classification

    private func freshBrowser(at t: Millis) -> BrowserState? {
        guard let c = browserCtx, t - c.receivedAt <= config.browserFreshness else { return nil }
        return c.state
    }

    private func desired(at t: Millis) throws -> Open? {
        func ex(_ c: Category, _ r: Reason, app: String? = nil, domain: String? = nil) -> Open { Open(start: t, category: c, reason: r, app: app, domain: domain) }
        if !tracking && !schedule.inWorkWindow(t) { return nil }
        if asleep { return ex(.away, .asleep) }
        if locked { return ex(.away, .locked) }
        if inactive { return ex(.away, .sessionInactive) }
        if paused { return ex(.away, .paused) }
        if Self.isLoginWindow(app) { return ex(.away, .locked) }
        if breakActive { return ex(.breakTime, .pomodoroBreak, app: userIdle ? nil : app) }
        if userIdle { return schedule.inWorkWindow(t) ? ex(.away, .idleTimeout) : nil }
        guard let appID = app else { return ex(.gap, .suspension) }
        var domain: String?
        let manual = manualMode
        if appID == safariBundleID {
            switch freshBrowser(at: t) {
            case .domain(let h)?: domain = DomainMatcher.normalize(h)
            case .privateBrowsing?: return ex(.privateTime, .privateBrowsing, app: appID)
            default: if manual == nil { return ex(.gap, .browserUnknown, app: appID) }
            }
        }
        if let manual { return ex(manual, .manualMode, app: appID, domain: domain) }
        if let d = rules.decide(app: appID, domain: domain) {
            if d.isWork && learningActive { return ex(.learn, .learning, app: appID, domain: domain) }
            return ex(d.category, d.reason, app: appID, domain: domain)
        }
        if learningActive { return ex(.learn, .learning, app: appID, domain: domain) }
        if schedule.inWorkWindow(t) { return ex(.work, .workWindow, app: appID, domain: domain) }
        return ex(.privateTime, .outsideHoursPrivate, app: appID, domain: domain)
    }

    private func reclassify(at t: Millis, boundary: Bool = false) throws {
        guard started else { return }
        if boundary { try endOutside(at: t) }
        if !tracking || userIdle { try endPrompt(at: t) }
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
        buffer(ActivityInterval(span: span, category: o.category, reason: o.reason, apps: o.app.map { [$0] } ?? []))
    }

    private func buffer(_ interval: ActivityInterval) {
        for fragment in accountedIntervals(interval) {
            var start = fragment.span.start
            while start < fragment.span.end {
                var part = fragment
                part.span = Span(start, min(fragment.span.end, ActivityBlock.floor(start) + ActivityBlock.length))
                if let last = pending.last, last.span.end == part.span.start,
                   ActivityBlock.floor(last.span.start) == ActivityBlock.floor(part.span.start),
                   last.category == part.category, last.reason == part.reason {
                    pending[pending.count - 1].span.end = part.span.end
                    pending[pending.count - 1].apps = Array(Set(last.apps + part.apps)).sorted()
                } else { pending.append(part) }
                start = part.span.end
            }
        }
    }

    private func accountedIntervals(_ interval: ActivityInterval) -> [ActivityInterval] {
        guard interval.category == .away || interval.category == .idle else { return [interval] }
        return schedule.workingSpans(in: interval.span).map { span in
            var fragment = interval
            fragment.span = span
            return fragment
        }
    }

    private func checkpoint(at t: Millis, force: Bool) throws {
        guard force || t - lastCheckpoint >= config.checkpointInterval else { return }
        if var current = open, t > current.start {
            buffer(ActivityInterval(span: Span(current.start, t), category: current.category, reason: current.reason,
                                    apps: current.app.map { [$0] } ?? []))
            current.start = t
            open = current
        }
        let cutoff = ActivityBlock.floor(t - Millis(config.idleThresholdSeconds * 1000))
        var durable: [ActivityInterval] = [], tail: [ActivityInterval] = []
        for interval in pending {
            if interval.span.start < cutoff {
                var part = interval; part.span.end = min(cutoff, interval.span.end); durable.append(part)
            }
            if interval.span.end > cutoff {
                var part = interval; part.span.start = max(cutoff, interval.span.start); tail.append(part)
            }
        }
        let appsByBlock = Dictionary(uniqueKeysWithValues: try BlockAccounting.aggregate(tail)
            .filter { !$0.apps.isEmpty }.map { ($0.start, $0.apps) })
        let storedTail = tail.map { interval in
            var interval = interval
            interval.apps = []
            return interval
        }
        let st = CheckpointState(openStart: open?.start, category: open?.category, reason: open?.reason,
                                 app: nil, domain: nil, pending: storedTail, appsByBlock: appsByBlock)
        let json = String(decoding: try JSONEncoder().encode(st), as: UTF8.self)
        try ledger.db.transaction {
            try ledger.record(durable)
            try ledger.writeCheckpoint(observed: t, cleanQuit: false, stateJSON: json)
        }
        pending = tail
        lastCheckpoint = t
    }

    // MARK: Live view

    /// The running (not yet stored) interval, clipped to `now`, so totals include the present moment.
    public func liveInterval(now: Millis) -> ActivityInterval? {
        guard let o = open, now > o.start else { return nil }
        return ActivityInterval(span: Span(o.start, now), category: o.category, reason: o.reason, app: o.app,
                                domain: o.domain, source: "live", apps: o.app.map { [$0] } ?? [])
    }

    public func liveIntervals(now: Millis) -> [ActivityInterval] {
        pending + (liveInterval(now: now).map { [$0] } ?? [])
    }

    public func checkpointNow(at stamp: Stamp) throws {
        try handle(.tick, at: stamp)
        try checkpoint(at: lastWall, force: true)
    }

    public func liveStatus() -> LiveStatus? {
        guard let o = open else { return nil }
        return LiveStatus(category: o.category, reason: o.reason, app: o.app, domain: o.domain, since: o.start,
                          outsidePrompt: false)
    }

    public var isRunning: Bool { started }
    public var isTrackingPaused: Bool { paused }
    public var isLearning: Bool { learningActive }
    /// The category chosen with the menu mode buttons, or nil when the schedule and rules decide.
    public var manualMode: Category? {
        switch outside?.answer {
        case .work?: return .work
        case .private?: return .privateTime
        case .learn?: return .learn
        default: return nil
        }
    }
    /// The category the schedule alone would assign at `t`, ignoring rules and manual mode.
    public func scheduledCategory(at t: Millis) -> Category {
        schedule.inWorkWindow(t) ? .work : .privateTime
    }
    public var pendingOutsideReviewID: Int64? {
        outside?.answer == nil ? outside?.reviewID : nil
    }
}
