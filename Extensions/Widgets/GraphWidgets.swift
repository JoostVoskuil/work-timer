import SwiftUI
import Charts
import WidgetKit
import WorkTimerCore

enum GraphPeriod {
    case daily, weekly
    var title: String { self == .daily ? "Daily activity" : "Weekly activity" }
}

private enum GraphCategory: String, CaseIterable {
    case work = "Work", personal = "Private", learn = "Learn"
    var color: Color {
        switch self {
        case .work: .teal
        case .personal: .purple
        case .learn: .blue
        }
    }
    func duration(in bucket: WidgetGraphBucket) -> Millis {
        switch self {
        case .work: bucket.work
        case .personal: bucket.personal
        case .learn: bucket.learn
        }
    }
}

private func durationText(_ millis: Millis) -> String {
    let minutes = max(0, millis) / Duration.minute
    return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
}

struct GraphWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    let period: GraphPeriod

    var body: some View {
        Group {
            if entry.isPreview {
                GraphContent(buckets: GraphSamples.buckets(period), period: period,
                             timeZone: .current, generatedAt: Date(), stale: false, large: family == .systemLarge)
            } else if case .ok(let snapshot) = entry.load,
                      let graphs = snapshot.graphs, let timeZone = TimeZone(identifier: snapshot.timeZone) {
                GraphContent(buckets: period == .daily ? graphs.hours : graphs.days, period: period,
                             timeZone: timeZone, generatedAt: Date(timeIntervalSince1970: Double(snapshot.generatedAt) / 1000),
                             stale: entry.date.timeIntervalSince1970 * 1000 - Double(snapshot.generatedAt) > 30 * 60_000,
                             large: family == .systemLarge)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label(period.title, systemImage: "chart.bar.xaxis").font(.headline)
                    Spacer()
                    Text("Graph data unavailable").font(.subheadline.weight(.medium))
                    Text("Open WorkTimer to publish your activity.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
}

private struct GraphContent: View {
    let buckets: [WidgetGraphBucket]
    let period: GraphPeriod
    let timeZone: TimeZone
    let generatedAt: Date
    let stale: Bool
    let large: Bool

    private var chartBuckets: [WidgetGraphBucket] {
        guard period == .daily else { return buckets }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return buckets.filter {
            let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: Double($0.start) / 1000))
            return (6..<23).contains(hour)
        }
    }

    private var unit: Double { Double(period == .daily ? Duration.minute : Duration.hour) }
    private var peak: Double { chartBuckets.map { Double($0.work + $0.personal + $0.learn) / unit }.max() ?? 0 }
    private var upperBound: Double { period == .daily ? max(60, peak) : max(8, (peak / 2).rounded(.up) * 2) }
    private var keys: [String] { chartBuckets.indices.map(String.init) }
    private var ticks: [String] {
        period == .weekly ? keys : chartBuckets.indices.filter { $0 % 4 == 0 }.map(String.init)
    }

    private func label(_ millis: Millis, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    private var dateLabel: String {
        guard let first = buckets.first, let last = buckets.last else { return "" }
        return period == .daily ? label(first.start, format: "d MMM") :
            "\(label(first.start, format: "d MMM")) – \(label(last.start, format: "d MMM"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 16 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(period.title).font(large ? .headline : .subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if stale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange).accessibilityLabel("Data may be outdated. Open WorkTimer to refresh.")
                }
                Text(dateLabel).font(.caption2).foregroundStyle(.secondary)
            }.lineLimit(1).minimumScaleFactor(0.85)

            Chart {
                ForEach(Array(chartBuckets.enumerated()), id: \.offset) { index, bucket in
                    ForEach(GraphCategory.allCases, id: \.self) { category in
                        BarMark(x: .value("Time", String(index)),
                                y: .value(period == .daily ? "Minutes" : "Hours", Double(category.duration(in: bucket)) / unit),
                                width: .ratio(period == .daily ? 0.8 : 0.6))
                            .foregroundStyle(by: .value("Category", category.rawValue))
                            .accessibilityLabel("\(label(bucket.start, format: period == .daily ? "HH:mm z" : "EEEE d MMM")), \(category.rawValue)")
                            .accessibilityValue(durationText(category.duration(in: bucket)))
                    }
                }
            }
            .chartForegroundStyleScale(domain: GraphCategory.allCases.map(\.rawValue), range: GraphCategory.allCases.map(\.color))
            .chartLegend(.hidden)
            .chartXScale(domain: keys)
            .chartYScale(domain: 0...upperBound)
            .chartXAxis {
                AxisMarks(values: ticks) { value in
                    AxisValueLabel {
                        if let key = value.as(String.self), ticks.contains(key),
                           let index = Int(key), chartBuckets.indices.contains(index) {
                            Text(label(chartBuckets[index].start, format: period == .daily ? "HH" : "EEE")).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, upperBound / 2, upperBound]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text("\(Int(amount))\(period == .daily ? "m" : "h")").font(.system(size: 9))
                        }
                    }
                }
            }
            .overlay {
                if peak == 0 {
                    Text(period == .daily ? "No activity between 06:00–23:00" : "No classified time yet").font(.caption).foregroundStyle(.secondary)
                        .padding(6).background(.background, in: RoundedRectangle(cornerRadius: 5))
                }
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(GraphCategory.allCases, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Circle().fill(category.color).frame(width: 6, height: 6)
                            Text(category.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(durationText(buckets.reduce(0) { $0 + category.duration(in: $1) }))
                            .font(.system(size: large ? 20 : 17, weight: .semibold, design: .rounded))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }

            if large {
                HStack {
                    Text(period == .daily ? "06:00–23:00 · full-day totals" : "Monday – Sunday")
                    Spacer()
                    Text("Updated \(label(Millis(generatedAt.timeIntervalSince1970 * 1000), format: "HH:mm"))")
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct DailyGraphWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WorkTimerDailyGraph", provider: Provider()) { entry in
            GraphWidgetView(entry: entry, period: .daily)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Daily graph")
        .description("Activity from 06:00 to 23:00, with full-day Work, Private and Learn totals.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct WeeklyGraphWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WorkTimerWeeklyGraph", provider: Provider()) { entry in
            GraphWidgetView(entry: entry, period: .weekly)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Weekly graph")
        .description("Monday to Sunday, with Work, Private and Learn totals.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private enum GraphSamples {
    static func buckets(_ period: GraphPeriod) -> [WidgetGraphBucket] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let start = period == .daily ? calendar.startOfDay(for: Date()) : calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        let work = period == .daily ? [0, 0, 0, 0, 0, 0, 0, 0, 40, 55, 45, 30, 0, 50, 35, 40, 20, 0, 0, 0, 0, 0, 0, 0] :
            [390, 360, 300, 420, 330, 0, 0]
        let personal = period == .daily ? [0, 0, 0, 0, 0, 0, 0, 15, 10, 0, 5, 15, 35, 0, 10, 0, 10, 35, 50, 20, 0, 0, 0, 0] :
            [45, 70, 55, 35, 80, 150, 90]
        let learn = period == .daily ? [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 10, 15, 15, 20, 0, 0, 35, 0, 0, 0, 0] :
            [60, 90, 120, 30, 60, 90, 0]
        return work.indices.map { i in
            let component: Calendar.Component = period == .daily ? .hour : .day
            let from = calendar.date(byAdding: component, value: i, to: start)!
            let to = calendar.date(byAdding: component, value: i + 1, to: start)!
            return WidgetGraphBucket(start: Millis(from.timeIntervalSince1970 * 1000), end: Millis(to.timeIntervalSince1970 * 1000),
                                     work: Millis(work[i]) * Duration.minute, personal: Millis(personal[i]) * Duration.minute,
                                     learn: Millis(learn[i]) * Duration.minute)
        }
    }
}

#Preview(as: .systemMedium) {
    DailyGraphWidget()
} timeline: {
    Entry(date: Date(), load: .unavailable, isPreview: true)
}

#Preview(as: .systemLarge) {
    WeeklyGraphWidget()
} timeline: {
    Entry(date: Date(), load: .unavailable, isPreview: true)
}
