import Foundation

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
}

public enum SnapshotLoad: Equatable {
    case ok(WidgetSnapshot)
    /// Missing, unreadable or from an unknown version: widgets must say "unavailable", never zero hours.
    case unavailable
}

public struct SnapshotStore {
    public let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("widget-snapshot.json") }

    public func publish(_ s: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(s).write(to: url, options: .atomic)
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
                              balanceLabel: label, currentDayIncomplete: week.currentDayIncomplete, pending: week.pending, health: health, status: status)
    }
}
