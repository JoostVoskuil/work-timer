import Foundation

/// UTC instant in integer milliseconds. All storage uses this unit.
public typealias Millis = Int64

public extension Date {
    var millis: Millis { Millis((timeIntervalSince1970 * 1000).rounded()) }
    init(millis: Millis) { self.init(timeIntervalSince1970: Double(millis) / 1000) }
}

public enum Duration {
    public static let second: Millis = 1_000
    public static let minute: Millis = 60_000
    public static let hour: Millis = 3_600_000
}

/// Half-open range [start, end).
public struct Span: Equatable, Hashable, Codable {
    public var start: Millis
    public var end: Millis
    public init(_ start: Millis, _ end: Millis) { self.start = start; self.end = end }
    public var length: Millis { max(0, end - start) }
    public var isEmpty: Bool { end <= start }
    public func intersection(_ o: Span) -> Span? {
        let s = max(start, o.start), e = min(end, o.end)
        return s < e ? Span(s, e) : nil
    }
    public func overlaps(_ o: Span) -> Bool { intersection(o) != nil }
}

/// How an effective time slice is accounted. Every observed millisecond has exactly one category.
public enum Category: String, Codable, CaseIterable {
    case work
    case learn
    case privateTime = "private"
    case breakTime = "break"
    case idle
    /// Asleep, locked, session inactive, or tracking paused.
    case away
    /// Observation unavailable or context unknown (not evidence of work).
    case gap

    public var title: String {
        switch self {
        case .work: return "Work"
        case .learn: return "Learn"
        case .privateTime: return "Private"
        case .breakTime: return "Break"
        case .idle: return "Idle"
        case .away: return "Away"
        case .gap: return "Unknown"
        }
    }
}

public enum Reason: String, Codable {
    case workWindow, workRule, privateRule, privateBrowsing
    case outsideHours, outsideHoursWork, outsideHoursPrivate
    case learning, outsideHoursLearn
    case idleTimeout, pomodoroBreak
    case asleep, locked, sessionInactive, paused
    case appNotRunning, clockJump, suspension
    case browserUnknown
    case correction, manualEntry

    public var explanation: String {
        switch self {
        case .workWindow: return "Inside the weekday work window"
        case .workRule: return "Matched a work rule"
        case .privateRule: return "Matched a private rule"
        case .privateBrowsing: return "Private browsing (no domain stored)"
        case .outsideHours: return "Outside work hours, awaiting your answer"
        case .outsideHoursWork: return "Outside work hours, you answered Work"
        case .outsideHoursPrivate: return "Outside work hours, private"
        case .learning: return "Learning session"
        case .outsideHoursLearn: return "Outside work hours, you answered Learn"
        case .idleTimeout: return "No input for 5 minutes"
        case .pomodoroBreak: return "Pomodoro break"
        case .asleep: return "Mac was asleep"
        case .locked: return "Screen locked"
        case .sessionInactive: return "User session inactive"
        case .paused: return "Tracking paused"
        case .appNotRunning: return "Tracker was not running"
        case .clockJump: return "Clock changed"
        case .suspension: return "Observation suspended"
        case .browserUnknown: return "Safari website unknown"
        case .correction: return "Manual correction"
        case .manualEntry: return "Manual entry"
        }
    }

    /// Captured reasons that need the user's attention.
    public var needsReview: Bool {
        switch self {
        case .outsideHours, .idleTimeout, .appNotRunning, .clockJump, .suspension, .browserUnknown: return true
        default: return false
        }
    }
}

public struct ActivityInterval: Equatable, Codable {
    public var id: Int64?
    public var span: Span
    public var category: Category
    public var reason: Reason
    public var app: String?
    public var domain: String?
    public var source: String

    public init(id: Int64? = nil, span: Span, category: Category, reason: Reason,
                app: String? = nil, domain: String? = nil, source: String = "tracker") {
        self.id = id; self.span = span; self.category = category; self.reason = reason
        self.app = app; self.domain = domain; self.source = source
    }
}

public enum AdjustmentKind: String, Codable { case reclassify, manual }

public struct Adjustment: Equatable, Codable {
    public var id: Int64?
    public var span: Span
    public var category: Category
    public var kind: AdjustmentKind
    public var note: String
    public var createdAt: Millis
    public var undoneAt: Millis?
    public var reviewID: Int64?
    public init(id: Int64? = nil, span: Span, category: Category, kind: AdjustmentKind = .reclassify,
                note: String = "", createdAt: Millis, undoneAt: Millis? = nil, reviewID: Int64? = nil) {
        self.id = id; self.span = span; self.category = category; self.kind = kind
        self.note = note; self.createdAt = createdAt; self.undoneAt = undoneAt; self.reviewID = reviewID
    }
}

public enum ReviewType: String, Codable { case idle, outsideHours, gap }
public enum ReviewStatus: String, Codable { case pending, resolved }

public struct ReviewItem: Equatable, Codable {
    public var id: Int64?
    public var type: ReviewType
    public var start: Millis
    public var end: Millis?
    public var status: ReviewStatus
    public var createdAt: Millis
    public var resolvedAt: Millis?
    public var resolution: String?
    public var dedupeKey: String
    public init(id: Int64? = nil, type: ReviewType, start: Millis, end: Millis? = nil, status: ReviewStatus = .pending,
                createdAt: Millis, resolvedAt: Millis? = nil, resolution: String? = nil, dedupeKey: String) {
        self.id = id; self.type = type; self.start = start; self.end = end; self.status = status
        self.createdAt = createdAt; self.resolvedAt = resolvedAt; self.resolution = resolution; self.dedupeKey = dedupeKey
    }
}

public enum RuleKind: String, Codable { case app, domain }

public struct ClassificationRule: Equatable, Codable {
    public var id: Int64?
    public var kind: RuleKind
    public var pattern: String
    public var isWork: Bool
    public var note: String
    public init(id: Int64? = nil, kind: RuleKind, pattern: String, isWork: Bool, note: String = "") {
        self.id = id; self.kind = kind; self.pattern = pattern; self.isWork = isWork; self.note = note
    }
}

/// Calendar date in the reporting time zone, ordered and printable as yyyy-MM-dd.
public struct LocalDate: Equatable, Hashable, Comparable, Codable, CustomStringConvertible {
    public var year: Int, month: Int, day: Int
    public init(_ year: Int, _ month: Int, _ day: Int) { self.year = year; self.month = month; self.day = day }
    public init?(_ string: String) {
        let p = string.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        self.init(p[0], p[1], p[2])
    }
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public static func < (a: LocalDate, b: LocalDate) -> Bool { a.description < b.description }
}
