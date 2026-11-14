import Foundation

/// Only aggregate durations leave the app; widget graphs contain no app names or browsing history.
public struct WidgetGraphBucket: Codable, Equatable {
    public var start: Millis
    public var end: Millis
    public var work: Millis
    public var personal: Millis
    public var learn: Millis

    public init(start: Millis, end: Millis, work: Millis, personal: Millis, learn: Millis) {
        self.start = start; self.end = end
        self.work = work; self.personal = personal; self.learn = learn
    }
}

public struct WidgetGraphs: Codable, Equatable {
    public var hours: [WidgetGraphBucket]
    public var days: [WidgetGraphBucket]

    public init(hours: [WidgetGraphBucket], days: [WidgetGraphBucket]) {
        self.hours = hours; self.days = days
    }
}

public struct HealthStatus: Codable, Equatable {
    public var storageOK = true
    public var safariOK: Bool? = nil
    public var notificationsOK: Bool? = nil
    public var trackingPaused = false
    public var messages: [String] = []
    public init() {}
    public var isHealthy: Bool { storageOK && safariOK != false && notificationsOK != false && messages.isEmpty }
}

/// Compact, versioned summary the widgets read. The app is the only writer.
public struct WidgetSnapshot: Codable, Equatable {
    public static let currentVersion = 1
    public var version = WidgetSnapshot.currentVersion
    public var generatedAt: Millis
    public var timeZone: String
    public var todayWork: Millis
    public var todayTarget: Millis
    public var todayCeiling: Millis
    public var weekWork: Millis
    public var weekFullTarget: Millis
    public var weekToDateTarget: Millis
    public var weekCeiling: Millis
    public var balanceToDate: Millis
    public var balanceLabel: String
    public var currentDayIncomplete: Bool
    public var pending: Millis
    public var health: HealthStatus
    public var status: String
    public var todayLearn: Millis? = nil
    public var weekLearn: Millis? = nil
    /// Optional so widgets can still decode snapshots published before graphs were added.
    public var graphs: WidgetGraphs? = nil
}

public enum SnapshotLoad: Equatable {
    case ok(WidgetSnapshot)
    /// Missing, unreadable or from an unknown version: widgets must say "unavailable", never zero hours.
    case unavailable
}

public struct SnapshotStore {
    public static func sharedDirectory() throws -> URL {
        guard let appGroupIdentifier = Bundle.main.object(forInfoDictionaryKey: "WorkTimerAppGroup") as? String,
              !appGroupIdentifier.hasPrefix("."), !appGroupIdentifier.contains("$"),
              appGroupIdentifier.hasSuffix(".nl.foxhole.worktimer.shared") else {
            throw SharedSnapshotError.containerUnavailable
        }
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw SharedSnapshotError.containerUnavailable
        }
        return directory
    }

    public static func sharedContainer() throws -> SnapshotStore {
        SnapshotStore(directory: try sharedDirectory())
    }

    public let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("widget-snapshot.json") }

    public func publish(_ s: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(s).write(to: url, options: .atomic)
    }

    public enum SharedSnapshotError: LocalizedError {
        case containerUnavailable
        public var errorDescription: String? {
            "The WorkTimer App Group is unavailable. Install the signed app with its App Group entitlement."
        }
    }

    public func load() -> SnapshotLoad {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              s.version == WidgetSnapshot.currentVersion else { return .unavailable }
        return .ok(s)
    }

    public func delete() { try? FileManager.default.removeItem(at: url) }
}

public enum SnapshotBuilder {
    public static func build(calc: ReportCalculator, now: Millis, health: HealthStatus, status: String) -> WidgetSnapshot {
        let today = calc.schedule.localDate(now)
        let day = calc.day(today, now: now)
        let week = calc.week(containing: today, now: now)
        let v = calc.schedule.version(on: today)
        let label = "Week to date through \(week.asOf)" + (week.currentDayIncomplete ? " (today incomplete)" : "")
        return WidgetSnapshot(generatedAt: now, timeZone: calc.schedule.timeZone.identifier, todayWork: day.work, todayTarget: day.targetMillis,
                              todayCeiling: Millis(v.dailyCeilingMinutes) * Duration.minute, weekWork: week.work, weekFullTarget: week.fullWeekTarget,
                              weekToDateTarget: week.toDateTarget, weekCeiling: week.weeklyCeiling, balanceToDate: week.toDateBalance,
                              balanceLabel: label, currentDayIncomplete: week.currentDayIncomplete, pending: week.pending, health: health, status: status,
                              todayLearn: day.learn, weekLearn: week.learn,
                              graphs: WidgetGraphs(hours: hourlyBuckets(calc: calc, day: today),
                                                   days: week.days.map { d in
                                  let span = calc.schedule.daySpan(d.date)
                                  return WidgetGraphBucket(start: span.start, end: span.end, work: d.work, personal: d.personal, learn: d.learn)
                              }))
    }

    public static func hourlyBuckets(calc: ReportCalculator, day: LocalDate) -> [WidgetGraphBucket] {
        let span = calc.schedule.daySpan(day)
        let blocks: [ActivityBlock]
        do { blocks = try calc.blocks(in: span) }
        catch {
            calc.ledger.accountingError = "Could not build widget graph: \(error)"
            NSLog("%@", calc.ledger.accountingError!)
            return []
        }
        var start = span.start
        var buckets: [WidgetGraphBucket] = []
        while start < span.end {
            // Calendar boundaries preserve short/long days and repeated hours in the reporting timezone.
            let hour = calc.schedule.calendar.dateInterval(of: .hour, for: Date(millis: start))!
            let end = min(span.end, hour.end.millis)
            let range = Span(start, end)
            var bucket = WidgetGraphBucket(start: start, end: end, work: 0, personal: 0, learn: 0)
            for block in blocks where block.span.overlaps(range) {
                bucket.work += block[.work]
                bucket.personal += block[.privateTime]
                bucket.learn += block[.learn]
            }
            buckets.append(bucket)
            start = end
        }
        return buckets
    }
}
