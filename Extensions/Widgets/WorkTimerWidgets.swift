import SwiftUI
import WidgetKit
import WorkTimerCore

struct Entry: TimelineEntry {
    let date: Date
    let load: SnapshotLoad
}

struct Provider: TimelineProvider {
    static func store() -> SnapshotStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.nl.worktimer.shared").map { SnapshotStore(directory: $0) }
    }
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), load: .unavailable) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: Date(), load: Self.store()?.load() ?? .unavailable)) }
    func getTimeline(in context: Context, completion: @escaping (WidgetKit.Timeline<Entry>) -> Void) {
        // The app calls WidgetCenter.reloadAllTimelines() on changes; this is only a fallback refresh.
        let e = Entry(date: Date(), load: Self.store()?.load() ?? .unavailable)
        completion(WidgetKit.Timeline(entries: [e], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

private func hm(_ ms: Millis, signed: Bool = false) -> String {
    let m = Int((abs(ms) + 30_000) / 60_000)
    let s = String(format: "%d:%02d", m / 60, m % 60)
    return signed ? (ms < 0 ? "−" : "+") + s : s
}

struct WidgetView: View {
    let entry: Entry
    var body: some View {
        switch entry.load {
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                Label("WorkTimer", systemImage: "clock.badge.checkmark").font(.headline)
                Spacer()
                Label("Data unavailable", systemImage: "exclamationmark.triangle").font(.caption)
                Text("Open WorkTimer").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .ok(let s):
            let age = Date().timeIntervalSince1970 * 1000 - Double(s.generatedAt)
            VStack(alignment: .leading, spacing: 5) {
                Label("WorkTimer", systemImage: "clock.badge.checkmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(hm(s.todayWork)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("Today / \(hm(s.todayTarget))").font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Week \(hm(s.weekWork)) / \(hm(s.weekFullTarget))").font(.caption)
                Text("Balance \(hm(s.balanceToDate, signed: true))").font(.caption.weight(.medium))
                Text(s.balanceLabel).font(.caption2).foregroundStyle(.secondary)
                if s.pending > 0 { Text("\(hm(s.pending)) pending review").font(.caption2).foregroundStyle(.orange) }
                if age > 30 * 60_000 || !s.health.isHealthy { Text("May be outdated · updated \(Date(timeIntervalSince1970: Double(s.generatedAt) / 1000).formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.red) }
            }.widgetURL(URL(string: "worktimer://today"))
        }
    }
}

struct WorkTimerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WorkTimerSummary", provider: Provider()) { entry in
            WidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
            .configurationDisplayName("Work hours")
            .description("Today, week and balance.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main struct WorkTimerWidgetBundle: WidgetBundle { var body: some Widget { WorkTimerWidget() } }
