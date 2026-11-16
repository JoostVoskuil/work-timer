import Charts
import SwiftUI
import UniformTypeIdentifiers
import WorkTimerCore

/// Local view state. The Command Line Tools ship no SwiftUIMacros plugin, so @State cannot be used when building with swift build.
final class LocalBox<T>: ObservableObject { @Published var value: T; init(_ v: T) { value = v } }

@propertyWrapper
struct Local<T>: DynamicProperty {
    @StateObject private var box: LocalBox<T>
    init(wrappedValue: T) { _box = StateObject(wrappedValue: LocalBox(wrappedValue)) }
    var wrappedValue: T { get { box.value } nonmutating set { box.value = newValue } }
    var projectedValue: Binding<T> { Binding(get: { box.value }, set: { box.value = $0 }) }
}

func hm(_ ms: Millis, signed: Bool = false) -> String {
    let neg = ms < 0
    let m = Int((abs(ms) + 30_000) / 60_000)
    let s = String(format: "%d:%02d", m / 60, m % 60)
    return signed ? (neg ? "−" : "+") + s : (neg ? "−" : "") + s
}

func timeText(_ t: Millis) -> String {
    Date(timeIntervalSince1970: Double(t) / 1000).formatted(date: .omitted, time: .shortened)
}

private func color(_ c: WorkTimerCore.Category) -> Color {
    switch c {
    case .work: return WorkStyle.accent
    case .learn: return .blue
    case .privateTime: return .purple
    case .breakTime: return .orange
    case .idle: return .gray
    case .away: return .secondary
    case .gap: return .red
    }
}

private enum WorkStyle {
    static let accent = Color.teal
}

private var buildDateText: String {
    Bundle.main.object(forInfoDictionaryKey: "WorkTimerBuildDate") as? String ?? "Unknown"
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.largeTitle.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct DurationMetric: View {
    let title: String
    let value: String
    var tint: Color = .primary
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: prominent ? 42 : 30, weight: .semibold))
                .monospacedDigit().foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Menu bar

private struct PomodoroCountdown: View {
    @ObservedObject var display: PomodoroCountdownDisplay

    var body: some View {
        Text(display.text)
            .monospacedDigit()
    }
}

private struct MenuBarCountdown: View {
    @ObservedObject var display: PomodoroCountdownDisplay
    let icon: String

    var body: some View {
        Text("\(Image(systemName: icon)) \(display.text)").monospacedDigit()
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if !model.health.storageOK { Label("Storage error", systemImage: "exclamationmark.triangle") }
        else if model.pomodoro.status == .running {
            // A single Text: status items render a Label as its icon only, hiding the countdown.
            MenuBarCountdown(display: model.pomodoroDisplay, icon: model.pomodoro.phase.isBreak ? "cup.and.saucer" : "timer")
                .help(model.pomodoro.phase.isBreak ? "Pomodoro break countdown" : "Pomodoro focus countdown")
        }
        else { Image(systemName: "clock.badge.checkmark").help("WorkTimer") }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Label("WorkTimer", systemImage: "clock.badge.checkmark").font(.headline)
                        Spacer()
                        Text(Date(millis: model.now).formatted(Date.FormatStyle(date: .abbreviated, time: .omitted,
                            timeZone: model.calculator?.schedule.timeZone ?? .current)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let err = model.fatalError {
                        Text(err).foregroundStyle(.red)
                    } else if !model.health.storageOK {
                        Text(model.health.messages.joined(separator: "\n")).foregroundStyle(.red)
                    }
                    MenuTodayDashboard(model: model)
                    if model.health.notificationsOK == false {
                        HStack {
                            Label("Notifications are off", systemImage: "bell.slash")
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Enable") { model.openNotificationSettings() }
                        }
                    }
                    Divider()
                    if model.today.pending > 0 || !model.reviews.isEmpty {
                        Text("\(model.reviews.count) item(s) to review · \(hm(model.today.pending)) pending today")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if model.pomodoro.status != .stopped {
                        HStack(spacing: 4) {
                            Text("Pomodoro \(model.pomodoro.phase.rawValue) · \(model.pomodoro.status.rawValue)")
                            Spacer()
                            PomodoroCountdown(display: model.pomodoroDisplay)
                        }.font(.callout)
                    }
                    if let week = model.week {
                        HStack {
                            Text("Week \(hm(week.work)) / \(hm(week.fullWeekTarget))")
                            Spacer()
                            Text(hm(week.toDateBalance, signed: true))
                        }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Text("Work + Learn \(hm(week.workAndLearn)) / \(hm(week.weeklyCeiling)) this week")
                            .font(.caption).foregroundStyle(week.ceilingReached ? Color.red : Color.secondary)
                    }
                    Text("Totals use five-minute blocks and include the full day. The hourly chart hides 23:00–06:00.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ModeButton(title: "Auto", icon: "wand.and.stars", tint: .gray, selected: model.manualMode == nil,
                               help: "Follow your schedule and app/website rules.") { model.resumeAutomaticMode() }
                    ModeButton(title: "Private", icon: "person.fill", tint: .purple, selected: model.manualMode == .privateTime,
                               help: "Count everything as Private until working hours start or end.") { model.answerOutside(.private) }
                    ModeButton(title: "Work", icon: "briefcase.fill", tint: WorkStyle.accent, selected: model.manualMode == .work,
                               help: "Count everything as Work until working hours start or end.") { model.answerOutside(.work) }
                    ModeButton(title: "Learn", icon: "book.fill", tint: .blue, selected: model.manualMode == .learn,
                               help: "Count everything as Learn until working hours start or end.") { model.answerOutside(.learn) }
                }
                .controlSize(.regular)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Tracking mode")
                HStack {
                    Button {
                        setDockIconVisible(true)
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("Open WorkTimer", systemImage: "macwindow")
                    }.buttonStyle(.glassProminent).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    Button("Quit") { model.shutdown(); NSApp.terminate(nil) }
                }
                Text("Quitting stops tracking.").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(width: 440, height: max(420, min(740, (NSScreen.main?.visibleFrame.height ?? 820) - 80)))
        .background(MenuWindowVisibility(model: model).frame(width: 0, height: 0))
        .onAppear { model.setMenuVisible(true) }
        .onDisappear { model.setMenuVisible(false) }
    }
}

private struct ModeButton: View {
    let title: String, icon: String, tint: Color, selected: Bool, help: String
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
        }
        .tint(tint)
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
        if selected { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.glass) }
    }
}

private struct MenuTodayDashboard: View {
    @ObservedObject var model: AppModel

    private var categories: [WorkTimerCore.Category] { [.work, .privateTime, .learn, .breakTime, .away, .gap] }
    private var activeCategories: [WorkTimerCore.Category] {
        categories.filter { model.today.byCategory[$0, default: 0] > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let schedule = model.calculator?.schedule {
                scheduleContext(schedule)
            }
            modeSummary
            if let status = model.status {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Tracking: \(status.category.title)", systemImage: "record.circle")
                        .font(.headline).foregroundStyle(color(status.category))
                    Text(status.reason.explanation).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label(model.paused ? "Tracking paused" : "Tracking unavailable", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                DurationMetric(title: "Work", value: hm(model.today.work), tint: WorkStyle.accent)
                DurationMetric(title: "Private", value: hm(model.today.personal), tint: .purple)
                DurationMetric(title: "Learn", value: hm(model.today.learn), tint: .blue)
            }
            if model.today.targetMillis > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Work target \(hm(model.today.targetMillis))")
                        Spacer()
                        Text("\(hm(max(0, model.today.targetMillis - model.today.work))) remaining")
                    }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    ProgressView(value: min(1, max(0, Double(model.today.work) / Double(model.today.targetMillis))))
                        .tint(WorkStyle.accent)
                }
            } else {
                Text("No work target today").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Accounted \(hm(model.today.byCategory.values.reduce(0, +)))")
                Spacer()
                Text("Balance \(hm(model.today.balance, signed: true))")
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if model.today.targetMillis > 0 {
                Text("Balance includes today's full target; today is still in progress.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if model.health.storageOK, let schedule = model.calculator?.schedule {
                hourlyChart(schedule)
                categoryChart
            }
        }
    }

    private var modeSummary: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Normal mode").foregroundStyle(.secondary)
                Label(model.scheduledMode.title, systemImage: model.scheduledMode == .work ? "briefcase" : "moon")
                    .foregroundStyle(color(model.scheduledMode))
            }
            GridRow {
                Text("Manual mode").foregroundStyle(.secondary)
                if let manual = model.manualMode {
                    HStack(spacing: 6) {
                        Label(manual.title, systemImage: "hand.tap.fill").foregroundStyle(color(manual))
                        if let schedule = model.calculator?.schedule {
                            Text("until \(Date(millis: schedule.nextBoundary(after: model.now)).formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: schedule.timeZone)))")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Off · automatic").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func scheduleContext(_ schedule: Schedule) -> some View {
        let day = model.today.date
        let working = schedule.inWorkWindow(model.now)
        let dayLabel = !schedule.isScheduled(day) ? "Non-working day"
            : model.today.targetMillis == 0 ? "Day off" : "Working day"
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(dayLabel, systemImage: "calendar")
                Spacer()
                Label(working ? "Work hours" : "Private hours", systemImage: working ? "briefcase" : "moon")
                    .foregroundStyle(working ? WorkStyle.accent : Color.purple)
            }.font(.callout)
            if let window = schedule.workWindow(day) {
                let format = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: schedule.timeZone)
                Text("Scheduled work window \(Date(millis: window.start).formatted(format))–\(Date(millis: window.end).formatted(format))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No scheduled work window today").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func hourlyChart(_ schedule: Schedule) -> some View {
        let hours = model.menuHours.filter {
            let hour = schedule.calendar.component(.hour, from: Date(millis: $0.start))
            return hour >= 6 && hour < 23
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Today by hour").font(.headline)
                Spacer()
                Text("06:00–23:00").font(.caption).foregroundStyle(.secondary)
            }
            if let first = hours.first, let last = hours.last, hours.contains(where: { $0.work + $0.personal + $0.learn > 0 }) {
                Chart {
                    ForEach(hours, id: \.start) { hour in
                        BarMark(x: .value("Hour", Date(millis: hour.start), unit: .hour),
                                y: .value("Minutes", Double(hour.work) / Double(Duration.minute)))
                            .foregroundStyle(by: .value("Category", "Work"))
                        BarMark(x: .value("Hour", Date(millis: hour.start), unit: .hour),
                                y: .value("Minutes", Double(hour.personal) / Double(Duration.minute)))
                            .foregroundStyle(by: .value("Category", "Private"))
                        BarMark(x: .value("Hour", Date(millis: hour.start), unit: .hour),
                                y: .value("Minutes", Double(hour.learn) / Double(Duration.minute)))
                            .foregroundStyle(by: .value("Category", "Learn"))
                    }
                    if model.now >= first.start, model.now < last.end {
                        RuleMark(x: .value("Now", Date(millis: model.now)))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top) { Text("Now").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .environment(\.calendar, schedule.calendar)
                .environment(\.timeZone, schedule.timeZone)
                .chartXScale(domain: Date(millis: first.start)...Date(millis: last.end))
                .chartYScale(domain: 0...60)
                .chartForegroundStyleScale(domain: ["Work", "Private", "Learn"], range: [WorkStyle.accent, Color.purple, Color.blue])
                .chartLegend(position: .bottom)
                .chartYAxisLabel("min")
                .chartXAxis {
                    AxisMarks(values: hours.enumerated().filter { $0.offset % 4 == 0 }.map { Date(millis: $0.element.start) }) {
                        AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 30, 60]) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        AxisValueLabel()
                    }
                }
                .frame(height: 170)
            } else {
                Text("No Work, Private or Learn activity recorded in these hours yet.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }

    private var categoryChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Activity mix · full day").font(.headline)
            if activeCategories.isEmpty {
                Text("Today's statistics will appear as activity is recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(activeCategories, id: \.self) { category in
                    BarMark(x: .value("Minutes", Double(model.today.byCategory[category, default: 0]) / Double(Duration.minute)),
                            y: .value("Category", category.title))
                        .foregroundStyle(color(category))
                        .cornerRadius(3)
                        .annotation(position: .trailing) {
                            Text(hm(model.today.byCategory[category, default: 0])).font(.caption2).monospacedDigit()
                        }
                }
                .chartXScale(domain: 0...max(5, Double(model.today.byCategory.values.max() ?? 0) / Double(Duration.minute) * 1.3))
                .chartXAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: CGFloat(max(2, activeCategories.count)) * 25)
            }
        }
    }
}

// MARK: Main window

private enum WorkSection: String, CaseIterable, Identifiable {
    case today = "Today", reports = "Reports", pomodoro = "Pomodoro", settings = "Settings"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .today: return "clock.badge.checkmark"
        case .reports: return "chart.bar.xaxis"
        case .pomodoro: return "timer"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @Local private var selection: WorkSection? = .today

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(WorkSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.symbol).tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .navigationTitle("WorkTimer")
            Text("Build \(buildDateText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        } detail: {
            Group {
                switch selection ?? .today {
                case .today: TodayView(model: model)
                case .reports: ScrollView { ReportsView(model: model) }
                case .pomodoro: PomodoroView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .padding(24)
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle((selection ?? .today).rawValue)
            .toolbar {
                if !model.health.storageOK {
                    ToolbarItem {
                        Label("Storage error", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .help("WorkTimer cannot write its database. See Settings → Health.")
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 640)
    }
}

/// Lists and plans days off (Work target 0), including future dates.
private struct DaysOffPanel: View {
    @ObservedObject var model: AppModel
    let schedule: Schedule
    @State private var date = Date()

    var body: some View {
        let days = model.overrides().sorted { $0.date < $1.date }
        VStack(alignment: .leading, spacing: 10) {
            Text("Days off").font(.headline)
            Text("A day off has a Work target of 0.").font(.caption).foregroundStyle(.secondary)
            if days.isEmpty {
                Text("No days off planned").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(days, id: \.date) { o in
                            HStack {
                                Text(Date(millis: schedule.startOfDay(o.date))
                                    .formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: schedule.timeZone)))
                                if o.targetMinutes != 0 { Text("target \(o.targetMinutes) min").foregroundStyle(.secondary) }
                                Spacer()
                                Button { model.removeOverride(o.date) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                                    .help("Remove day off").accessibilityLabel("Remove day off")
                            }
                        }
                    }
                }.frame(maxHeight: 220)
            }
            Divider()
            HStack {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.timeZone, schedule.timeZone)
                    .environment(\.calendar, schedule.calendar)
                Button("Add day off") {
                    model.setOverride(DayOverride(date: schedule.localDate(date.millis), targetMinutes: 0, note: "Day off"))
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

private enum ActivityFilter: String, CaseIterable {
    case all, away, unknown

    var title: String {
        switch self {
        case .all: return "All"
        case .away: return "Away"
        case .unknown: return "Unknown"
        }
    }
}

private struct ActivityFilterPicker: View {
    @Binding var selection: ActivityFilter

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ActivityFilter.allCases, id: \.self) { filter in
                Button {
                    selection = filter
                } label: {
                    Text(filter.title)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .foregroundStyle(selection == filter ? WorkStyle.accent : .secondary)
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .background {
                    if selection == filter {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(WorkStyle.accent.opacity(0.18))
                    }
                }
                .accessibilityAddTraits(selection == filter ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(width: 240, height: 30)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.quaternary, lineWidth: 1)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity filter")
    }
}

struct TodayView: View {
    @ObservedObject var model: AppModel
    @Local private var showManual = false
    @Local private var selectedBlocks: Set<Millis> = []
    @Local private var selectionAnchor: Millis? = nil
    @Local private var showDaysOff = false
    @Local private var activityFilter: ActivityFilter = .all
    var body: some View {
        let schedule = model.calculator?.schedule
        let day = model.activityDay
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeading(title: day.isToday ? "Today" : "Activity",
                               subtitle: Date(millis: schedule?.startOfDay(day.date) ?? model.now)
                                .formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: schedule?.timeZone ?? .current)),
                               symbol: day.isToday ? "sun.max" : "calendar")
                Spacer()
                if let schedule {
                    HStack(spacing: 8) {
                        Button { model.selectActivityDay(schedule.addDays(day.date, -1)) } label: {
                            Image(systemName: "chevron.left")
                        }.help("Previous day").accessibilityLabel("Previous day")
                        DatePicker("Activity date", selection: Binding(
                            get: { Date(millis: schedule.startOfDay(day.date)) },
                            set: { model.selectActivityDay(schedule.localDate($0.millis)) }),
                                   in: ...Date(millis: model.now), displayedComponents: .date)
                            .labelsHidden()
                            .environment(\.timeZone, schedule.timeZone)
                            .environment(\.calendar, schedule.calendar)
                        Button { model.selectActivityDay(schedule.addDays(day.date, 1)) } label: {
                            Image(systemName: "chevron.right")
                        }.disabled(day.date >= schedule.localDate(model.now))
                            .help("Next day").accessibilityLabel("Next day")
                        Button("Today") { model.selectActivityDay(nil) }
                            .disabled(model.selectedActivityDate == nil)
                    }.fixedSize()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                DurationMetric(title: "Work", value: hm(day.work), tint: WorkStyle.accent, prominent: true)
                DurationMetric(title: "Private", value: hm(day.personal), tint: .purple)
                DurationMetric(title: "Learn", value: hm(day.learn), tint: .blue)
            }
            .padding(.vertical, 12)
            HStack {
                Text("Work target \(hm(day.targetMillis))")
                if let schedule {
                    let isOff = model.overrides().contains { $0.date == day.date && $0.targetMinutes == 0 }
                    Toggle("Day off", isOn: Binding(get: { isOff }, set: { off in
                        if off { model.setOverride(DayOverride(date: day.date, targetMinutes: 0, note: "Day off")) }
                        else { model.removeOverride(day.date) }
                    }))
                    .toggleStyle(.checkbox)
                    .help("Day off sets this day's Work target to 0")
                    Button { showDaysOff.toggle() } label: { Label("Days off", systemImage: "calendar.badge.minus") }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showDaysOff, arrowEdge: .bottom) { DaysOffPanel(model: model, schedule: schedule) }
                }
                Spacer()
                Text("Balance \(hm(day.balance, signed: true))\(day.isToday ? " · today incomplete" : "")")
            }.font(.callout).foregroundStyle(.secondary).monospacedDigit()
            if day.pending > 0 {
                Label("\(hm(day.pending)) awaiting review", systemImage: "tray")
                    .font(.callout).foregroundStyle(.orange)
            }
            Divider()
            if let error = model.reviewError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if !model.health.storageOK {
                Text(model.health.messages.joined(separator: "\n")).foregroundStyle(.red)
            }
            HStack {
                Text("Activity · five-minute blocks").font(.headline)
                Spacer()
                ActivityFilterPicker(selection: $activityFilter)
                Button { showManual = true } label: { Label("Add manual entry", systemImage: "plus") }
            }
            HStack {
                Text("\(selectedBlocks.count) selected · \(hm(Millis(selectedBlocks.count) * ActivityBlock.length))")
                    .font(.callout).monospacedDigit()
                Spacer()
                Button("Select all") { selectedBlocks = completedBlockIDs; selectionAnchor = nil }
                    .disabled(completedBlockIDs.isEmpty)
                Button("Clear") { clearBlockSelection() }.disabled(selectedBlocks.isEmpty)
                Menu("Set category") {
                    ForEach([WorkTimerCore.Category.work, .learn, .privateTime, .breakTime, .away], id: \.self) { category in
                        Button(category.title) {
                            if model.reclassifyBlocks(selectedBlocks, as: category) { clearBlockSelection() }
                        }
                        .disabled(category == .away && !canAssignAwayToSelection(schedule: schedule))
                    }
                }.disabled(selectedBlocks.isEmpty)
            }
            Text("Check blocks to select them. Shift-click a checkbox to check or clear a range, including blocks in collapsed Away groups. Only completed blocks can be changed.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(ActivityBlockGroup.groupingAway(displayedBlocks, completedThrough: ActivityBlock.floor(model.now)).reversed()) { group in
                    if group.blocks.count > 1 {
                        DisclosureGroup {
                            ForEach(group.blocks.reversed()) { activityBlockRow($0, schedule: schedule) }
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(timeText(group.span.start))–\(timeText(group.span.end))")
                                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                Circle().fill(color(.away)).frame(width: 7, height: 7)
                                Text("Away").font(.callout)
                                Text(hm(group.observed)).monospacedDigit().foregroundStyle(.secondary)
                                Spacer()
                                let selectedCount = group.blocks.filter { selectedBlocks.contains($0.id) }.count
                                if selectedCount > 0 {
                                    Text("\(selectedCount) selected").font(.caption).foregroundStyle(WorkStyle.accent)
                                }
                                Text("\(group.blocks.count) blocks").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        }.help("Expand to view or correct individual five-minute blocks.")
                    } else {
                        activityBlockRow(group.blocks[0], schedule: schedule)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
            .transaction { transaction in
                transaction.animation = nil
            }
            .overlay {
                if displayedBlocks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").font(.title).foregroundStyle(.secondary)
                        Text(activityFilter == .all
                             ? (day.isToday ? "No activity yet" : "No activity recorded")
                             : "No \(activityFilter.title.lowercased()) blocks")
                            .font(.headline)
                        Text(activityFilter == .all
                             ? (day.isToday ? "Tracked activity will appear here." : "Choose another day or add a manual entry.")
                             : "Choose another filter or change the activity day.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.allowsHitTesting(false)
                }
            }
        }
        .onChange(of: day.date) { clearBlockSelection() }
        .onChange(of: activityFilter) { clearBlockSelection() }
        .onChange(of: model.activityBlocks.map(\.id)) {
            selectedBlocks.formIntersection(completedBlockIDs)
            if let anchor = selectionAnchor, !completedBlockIDs.contains(anchor) { selectionAnchor = nil }
        }
        .sheet(isPresented: $showManual) { ManualEntryView(model: model, isPresented: $showManual) }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .animation(nil, value: activityFilter)
    }

    private var displayedBlocks: [ActivityBlock] {
        switch activityFilter {
        case .all: return model.activityBlocks
        case .away: return model.activityBlocks.filter { $0[.away] > 0 }
        case .unknown: return model.activityBlocks.filter { $0[.gap] > 0 }
        }
    }

    private var completedBlockIDs: Set<Millis> {
        Set(displayedBlocks.filter { $0.span.end <= ActivityBlock.floor(model.now) }.map(\.id))
    }

    private func clearBlockSelection() {
        selectedBlocks = []
        selectionAnchor = nil
    }

    private func blockSelection(_ id: Millis) -> Binding<Bool> {
        Binding(get: { selectedBlocks.contains(id) }, set: { checked in
            let eligible = completedBlockIDs
            let orderedIDs = model.activityBlocks.reversed().map(\.id).filter { eligible.contains($0) }
            let shift = (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift)
            let affected = ActivityBlock.selectionRange(orderedIDs: orderedIDs,
                                                       anchor: shift ? selectionAnchor : nil, target: id)
            if checked { selectedBlocks.formUnion(affected) }
            else { selectedBlocks.subtract(affected) }
            if !shift { selectionAnchor = id }
        })
    }

    private func canAssignAwayToSelection(schedule: Schedule?) -> Bool {
        guard let schedule else { return false }
        return displayedBlocks.filter { selectedBlocks.contains($0.id) }.allSatisfy { block in
            schedule.workingSpans(in: block.span).reduce(0) { $0 + $1.length } == block.span.length
        }
    }

    private func activityBlockRow(_ block: ActivityBlock, schedule: Schedule?) -> some View {
        let apps = block.apps.map { model.appName(for: $0) }.sorted().joined(separator: ", ")
        let canAssignAway = schedule.map { schedule in
            block.coverage.allSatisfy { coverage in
                schedule.workingSpans(in: coverage).reduce(0) { $0 + $1.length } == coverage.length
            }
        } ?? false
        return HStack(spacing: 12) {
            Toggle("Select block \(timeText(block.span.start))–\(timeText(block.span.end))", isOn: blockSelection(block.id))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!completedBlockIDs.contains(block.id))
                .help("Shift-click to check or clear all completed blocks between this block and the last checkbox clicked.")
            Text("\(timeText(block.span.start))–\(timeText(block.span.end))")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(WorkTimerCore.Category.allCases.filter { block[$0] > 0 }, id: \.self) { category in
                    HStack(spacing: 6) {
                        Circle().fill(color(category)).frame(width: 7, height: 7)
                        Text(category.title)
                        Text("\(block[category] / Duration.minute)m \((block[category] % Duration.minute) / Duration.second)s")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }.font(.caption)
                }
                Text(apps.isEmpty ? "No apps recorded" : "Apps: \(apps)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(apps.isEmpty ? "App lists were not retained in older blocks or during inactivity."
                          : block.apps.map { "\(model.appName(for: $0)) — \($0)" }.sorted().joined(separator: "\n")
                            + "\nRight-click to copy a bundle ID or add an app rule.")
                    .contextMenu {
                        ForEach(block.apps.sorted { model.appName(for: $0) < model.appName(for: $1) }, id: \.self) { id in
                            Menu("\(model.appName(for: id)) (\(id))") {
                                Button("Copy bundle ID") { model.copyToPasteboard(id) }
                                Divider()
                                Button("Always classify as Work") { model.addAppRule(id, category: .work) }
                                Button("Always classify as Learn") { model.addAppRule(id, category: .learn) }
                                Button("Always classify as Private") { model.addAppRule(id, category: .privateTime) }
                            }
                        }
                    }
            }
            Spacer()
            Menu("Change") {
                ForEach([WorkTimerCore.Category.work, .learn, .privateTime, .breakTime, .away], id: \.self) { c in
                    Button(c.title) { model.reclassify(block.span, as: c, note: "Block correction") }
                        .disabled(c == .away && !canAssignAway)
                }
                ForEach(model.blockCorrections.filter { $0.span.overlaps(block.span) }, id: \.id) { correction in
                    if let id = correction.id {
                        Button("Undo \(correction.category.title) correction") { model.undo(id) }
                    }
                }
            }.fixedSize().disabled(block.span.end > ActivityBlock.floor(model.now))
        }.padding(.vertical, 8)
    }
}

struct ManualEntryView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @Local private var start = Date(millis: ActivityBlock.floor(Date().millis) - Duration.hour)
    @Local private var end = Date(millis: ActivityBlock.floor(Date().millis))
    @Local private var note = ""
    @Local private var category: WorkTimerCore.Category = .work
    var body: some View {
        Form {
            Picker("Category", selection: $category) {
                ForEach([WorkTimerCore.Category.work, .learn, .privateTime, .breakTime], id: \.self) { c in
                    Text(c.title).tag(c)
                }
            }
            .pickerStyle(.segmented)
            DatePicker("Start", selection: Binding(get: { start }, set: { start = Date(millis: ActivityBlock.floor($0.millis)) }))
            DatePicker("End", selection: Binding(get: { end }, set: { end = Date(millis: ActivityBlock.floor($0.millis)) }))
            Text("Choose completed five-minute boundaries, for example 09:00–09:15. All recorded blocks in this period are replaced; undo the entry to restore them.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Note", text: $note)
            if let error = model.reviewError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    let s = Millis(start.timeIntervalSince1970 * 1000), e = Millis(end.timeIntervalSince1970 * 1000)
                    if e > s, model.addManualEntry(Span(s, e), as: category, note: note) { isPresented = false }
                }.disabled(end <= start)
            }
        }.padding().frame(width: 380)
    }
}

// MARK: Reports

struct ReportsView: View {
    @ObservedObject var model: AppModel
    @Local private var scope = 0
    @Local private var anchor = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeading(title: "Reports", subtitle: "Your work over time", symbol: "chart.bar.xaxis")
            HStack {
                Picker("", selection: $scope) { Text("Week").tag(0); Text("Month").tag(1) }.pickerStyle(.segmented).frame(width: 180)
                DatePicker("", selection: $anchor, displayedComponents: .date).labelsHidden()
                Spacer()
                Button("Export summary CSV") { export(timeline: false) }
                Button("Export blocks CSV") { export(timeline: true) }
            }
            if let calc = model.calculator {
                let d = calc.schedule.localDate(Millis(anchor.timeIntervalSince1970 * 1000))
                if scope == 0 { weekView(calc, d) } else { monthView(calc, d) }
            } else {
                ContentUnavailableView("Reports unavailable", systemImage: "chart.bar.xaxis",
                                       description: Text(model.fatalError ?? "Tracking storage is not available."))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func weekView(_ calc: ReportCalculator, _ d: LocalDate) -> some View {
        let w = calc.week(containing: d, now: model.now)
        HStack(spacing: 24) {
            DurationMetric(title: "Work", value: hm(w.work), tint: WorkStyle.accent)
            DurationMetric(title: "Private", value: hm(w.days.reduce(0) { $0 + $1.personal }), tint: .purple)
            DurationMetric(title: "Learn", value: hm(w.learn), tint: .blue)
        }.padding(.vertical, 8)
        HStack {
            Text("Full-week Work target \(hm(w.fullWeekTarget))")
            Spacer()
            Text("To-date balance \(hm(w.toDateBalance, signed: true))\(w.currentDayIncomplete ? " · today incomplete" : "")")
        }.font(.callout).foregroundStyle(.secondary).monospacedDigit()
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Work + Learn", systemImage: "briefcase")
                    Spacer()
                    Text("\(hm(w.workAndLearn)) / \(hm(w.weeklyCeiling))")
                        .monospacedDigit().foregroundStyle(w.ceilingReached ? Color.red : Color.primary)
                }
                Text(w.ceilingReached ? "Weekly limit reached" : "\(hm(w.remainingBeforeCeiling)) remaining this week")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if w.pending > 0 { Text("Includes \(hm(w.pending)) pending review, not counted as work.").font(.caption).foregroundStyle(.orange) }
        chart(w.days, schedule: calc.schedule)
    }

    @ViewBuilder private func monthView(_ calc: ReportCalculator, _ d: LocalDate) -> some View {
        let m = calc.month(containing: d, now: model.now)
        HStack(spacing: 24) {
            DurationMetric(title: "Work", value: hm(m.work), tint: WorkStyle.accent)
            DurationMetric(title: "Private", value: hm(m.days.reduce(0) { $0 + $1.personal }), tint: .purple)
            DurationMetric(title: "Learn", value: hm(m.learn), tint: .blue)
        }.padding(.vertical, 8)
        HStack {
            Text("Work target \(hm(m.target))")
            Spacer()
            Text("Balance \(hm(m.balance, signed: true))")
        }.font(.callout).foregroundStyle(.secondary).monospacedDigit()
        chart(m.days, schedule: calc.schedule)
    }

    private func chart(_ days: [DaySummary], schedule: Schedule) -> some View {
        Chart(days, id: \.date) { d in
            BarMark(x: .value("Day", Date(millis: schedule.startOfDay(d.date)), unit: .day), y: .value("Hours", Double(d.work) / Double(Duration.hour)))
                .foregroundStyle(by: .value("Activity", "Work"))
            BarMark(x: .value("Day", Date(millis: schedule.startOfDay(d.date)), unit: .day), y: .value("Hours", Double(d.personal) / Double(Duration.hour)))
                .foregroundStyle(by: .value("Activity", "Private"))
            BarMark(x: .value("Day", Date(millis: schedule.startOfDay(d.date)), unit: .day), y: .value("Hours", Double(d.learn) / Double(Duration.hour)))
                .foregroundStyle(by: .value("Activity", "Learn"))
        }
        .environment(\.calendar, schedule.calendar)
        .environment(\.timeZone, schedule.timeZone)
        .chartForegroundStyleScale(domain: ["Work", "Private", "Learn"], range: [WorkStyle.accent, Color.purple, Color.blue])
        .chartLegend(position: .bottom)
        .chartYAxisLabel("Hours")
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: days.count > 7 ? 7 : 1)) {
                AxisValueLabel(format: days.count > 7 ? .dateTime.day() : .dateTime.weekday(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel()
            }
        }
        .frame(height: 280)
    }

    private func export(timeline: Bool) {
        guard let calc = model.calculator else { return }
        let d = calc.schedule.localDate(Millis(anchor.timeIntervalSince1970 * 1000))
        let range = scope == 0 ? calc.schedule.weekStart(containing: d)...calc.schedule.addDays(calc.schedule.weekStart(containing: d), 6) : calc.schedule.monthRange(containing: d)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "worktimer-\(timeline ? "blocks" : "summary")-\(range.lowerBound).csv"
        if panel.runModal() == .OK, let url = panel.url {
            do { try model.exportCSV(range: range, timeline: timeline).write(to: url, atomically: true, encoding: .utf8) }
            catch { model.reviewError = "CSV export failed: \(error)" }
        }
    }
}

// MARK: Review

struct ReviewView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Review", subtitle: "You decide what counts as work", symbol: "tray.full")
            Text("Tracking gaps of at least 15 minutes and idle periods longer than 15 minutes during working hours need your input. Short idle periods count as Work; outside-hours activity defaults to Private.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("What needs reviewing?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tracking gap: the app was closed, interrupted, or could not observe activity.")
                    Text("After you resume, longer idle periods let you choose Away or Work. Short gaps and ordinary outside-hours activity do not create review tasks.")
                    Text("For calls or other misclassified activity, correct completed five-minute blocks in Today.")
                    Text("Work counts toward your work target. Learn is separate, but shares the 45-hour weekly limit. Break and Private count toward neither. Leave an item unanswered if you are unsure.")
                }.font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }
            if let error = model.reviewError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if model.reviews.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 36)).foregroundStyle(WorkStyle.accent)
                    Text("All caught up").font(.headline)
                    Text("No uncertain periods need your input.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.reviews, id: \.id) { r in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(title(r), systemImage: symbol(r)).font(.headline)
                            Spacer()
                            Text(r.end.map { hm(max(0, $0 - r.start)) } ?? "Ongoing")
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text(period(r)).font(.caption).foregroundStyle(.secondary)
                        Text(explanation(r)).font(.callout).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if r.type == .idle {
                                Button("Work") { model.resolve(r, as: .work) }
                                Button("Away") { model.resolve(r, as: .away) }
                            } else {
                                Button("Work") { model.resolve(r, as: .work) }
                                    .disabled(r.end == nil && !model.canAnswerLiveReview(r))
                                Button("Learn") { model.resolve(r, as: .learn) }
                                    .disabled(r.end == nil && !model.canAnswerLiveReview(r))
                                Button("Break") { model.resolve(r, as: .breakTime) }.disabled(r.end == nil)
                                Button("Private") { model.resolve(r, as: .privateTime) }
                                    .disabled(r.end == nil && !model.canAnswerLiveReview(r))
                            }
                            Spacer()
                            Text(r.type == .idle ? "Currently Away" : "Not counted as work")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if r.end == nil {
                            Text(model.canAnswerLiveReview(r)
                                 ? "Work, Learn or Private also applies to the rest of this after-hours session."
                                 : "This period has no end yet and cannot be answered here.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 10)
                }.listStyle(.inset)
            }
            if !reviewBlocks.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Unknown and Away timeblocks").font(.headline)
                    Text("Recorded five-minute blocks for the displayed activity day. Use Today to correct a completed block.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(reviewBlocks) { block in
                                HStack(spacing: 10) {
                                    Circle().fill(color(blockCategory(block))).frame(width: 7, height: 7)
                                    Text("\(timeText(block.span.start))–\(timeText(block.span.end))")
                                        .font(.callout).monospacedDigit()
                                    Text(blockCategory(block).title)
                                    Spacer()
                                    Text(hm(block.observed)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 7)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
    }

    private var reviewBlocks: [ActivityBlock] {
        model.activityBlocks.filter { $0[.gap] > 0 || $0[.away] > 0 }.reversed()
    }

    private func blockCategory(_ block: ActivityBlock) -> WorkTimerCore.Category {
        block[.gap] > 0 ? .gap : .away
    }

    private func title(_ review: ReviewItem) -> String {
        switch review.type {
        case .idle: return "Were you away, or were you working?"
        case .gap: return "What happened while tracking was unavailable?"
        case .outsideHours: return "Was this after-hours activity work?"
        }
    }

    private func symbol(_ review: ReviewItem) -> String {
        switch review.type {
        case .idle: return "keyboard"
        case .gap: return "questionmark.circle"
        case .outsideHours: return "moon"
        }
    }

    private func explanation(_ review: ReviewItem) -> String {
        switch review.type {
        case .idle: return "No keyboard or mouse input was detected for more than 15 minutes. Choose Work to count this period as work, or Away to exclude it."
        case .gap: return "WorkTimer has no reliable activity record for this period. Only count it as work if you know you were working."
        case .outsideHours: return "This activity was outside your configured working hours. Counting it as work keeps existing private-app and private-domain exclusions."
        }
    }

    private func period(_ review: ReviewItem) -> String {
        let start = Date(timeIntervalSince1970: Double(review.start) / 1000)
        let end = review.end.map { Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .shortened) } ?? "now"
        return "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end)"
    }
}

// MARK: Pomodoro

struct PomodoroView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "timer").font(.system(size: 36, weight: .regular)).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
            Text(model.pomodoro.status == .stopped ? "Not running" : "\(model.pomodoro.phase.rawValue.capitalized) · \(model.pomodoro.status.rawValue)").font(.headline)
            PomodoroCountdown(display: model.pomodoroDisplay).font(.system(size: 72, weight: .light))
            Text("Completed focus sessions: \(model.pomodoro.completedFocus)")
            HStack {
                let running = model.pomodoro.status == .running
                Button { model.pomodoroToggle() } label: {
                    Label(running ? "Stop" : "Start", systemImage: running ? "stop.fill" : "play.fill").frame(minWidth: 90)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.space, modifiers: [])
                Button { model.pomodoroReset() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise").frame(minWidth: 90)
                }
                .buttonStyle(.glass)
                .disabled(model.pomodoro.status == .stopped && model.pomodoro.completedFocus == 0)
            }.controlSize(.large)
            Text("Start runs the next phase or continues a stopped one; Reset returns to a fresh \(model.pomodoroFocusMinutes)-minute focus. Change the focus length in Settings. Break phases are excluded from work time, and the timer stops automatically on sleep and lock.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Settings

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Local private var newPattern = ""
    @Local private var newKind = RuleKind.domain
    @Local private var newCategory = WorkTimerCore.Category.privateTime
    @Local private var rules: [ClassificationRule] = []
    @Local private var message = ""
    @Local private var confirmDeleteAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: "Settings", subtitle: "Tracking, rules and your data", symbol: "slider.horizontal.3")
            Form {
                Section("General") {
                    VStack(alignment: .leading) {
                        Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        Button("Send test notification") { model.sendTestNotification() }
                            .disabled(model.isSendingTestNotification)
                        if let status = model.notificationTestStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Button("Open Notification Settings") { model.openNotificationSettings() }
                        }
                        Button("Reveal data folder") { model.revealDataFolder() }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Section("Pomodoro") {
                    VStack(alignment: .leading) {
                        Stepper(value: Binding(get: { model.pomodoroFocusMinutes }, set: { model.setPomodoroFocusMinutes($0) }),
                                in: PomodoroTimer.focusMinutesRange) {
                            Text("Focus length: \(model.pomodoroFocusMinutes) min")
                        }
                        Text("Default 25 minutes. Applies to the next focus phase and to Reset; a running phase keeps its length.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Section("Health") {
                    VStack(alignment: .leading) {
                        Text("Storage: \(model.health.storageOK ? "OK" : "Problem")")
                        Text("Notifications: \(model.health.notificationsOK.map { $0 ? "Allowed" : "Not allowed" } ?? "Unknown")")
                        if model.health.notificationsOK == false {
                            Button("Open Notification Settings") { model.openNotificationSettings() }
                        }
                        ForEach(model.health.messages, id: \.self) { Text($0).foregroundStyle(.red) }
                        if let notice = model.compactionNotice {
                            Text(notice).font(.caption).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Section("Classification rules") {
                    VStack(alignment: .leading) {
                        Text("Rules classify an app or website as Private, Work or Learn. Domain rules beat app rules; on ties Private beats Learn, which beats Work.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(rules, id: \.id) { r in
                            HStack {
                                if r.kind == .app {
                                    let name = model.appName(for: r.pattern)
                                    Text("App \(name == r.pattern ? r.pattern : "\(name) (\(r.pattern))") → \(r.category.title)")
                                } else {
                                    Text("Domain \(r.pattern) → \(r.category.title)")
                                }
                                Spacer()
                                Button("Remove") { if let id = r.id { model.deleteRule(id); rules = model.rules() } }
                            }
                        }
                        HStack {
                            Picker("", selection: $newKind) { Text("Domain").tag(RuleKind.domain); Text("App bundle ID").tag(RuleKind.app) }.frame(width: 140)
                            TextField(newKind == .domain ? "example.com" : "com.example.App", text: $newPattern)
                            if newKind == .app {
                                Menu("Choose app") {
                                    ForEach(model.knownAppIdentifiers(), id: \.self) { id in
                                        Button("\(model.appName(for: id)) (\(id))") { newPattern = id }
                                    }
                                    Divider()
                                    Button("Browse Applications…") { if let id = chooseApplication() { newPattern = id } }
                                }.fixedSize()
                            }
                            Picker("", selection: $newCategory) {
                                ForEach([WorkTimerCore.Category.privateTime, .work, .learn], id: \.self) { Text($0.title).tag($0) }
                            }.frame(width: 100)
                            Button("Add") {
                                let p = newKind == .domain ? (DomainMatcher.normalize(newPattern) ?? "") : newPattern.trimmingCharacters(in: .whitespaces)
                                if !p.isEmpty { model.upsert(ClassificationRule(kind: newKind, pattern: p, category: newCategory)); newPattern = ""; rules = model.rules() }
                            }
                        }
                        if newKind == .app {
                            let id = newPattern.trimmingCharacters(in: .whitespaces)
                            Text(id.isEmpty ? "Choose an app, or right-click the app list of a block in Today to copy its bundle ID."
                                 : model.appName(for: id) == id ? "No installed app found for this bundle ID." : "App: \(model.appName(for: id))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Data") {
                    VStack(alignment: .leading) {
                        Text("Stored in your user profile. Backups are not encrypted.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Create backup…") { backup() }
                            Button("Restore backup…") { restore() }
                            Button("Delete all history…") { confirmDeleteAll = true }
                        }
                        if !message.isEmpty { Text(message).font(.caption) }
                    }
                }
            }.formStyle(.grouped)
        }
        .onAppear { rules = model.rules() }
        .confirmationDialog("Delete all tracked history, corrections and widget data? Rules and schedule are kept.", isPresented: $confirmDeleteAll) {
            Button("Delete everything", role: .destructive) { model.deleteAllHistory(); message = "History deleted." }
        }
    }

    private func backup() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "worktimer-backup.sqlite"
        if p.runModal() == .OK, let url = p.url {
            do { try model.backup(to: url); message = "Backup saved." } catch { message = "Backup failed: \(error)" }
        }
    }

    private func chooseApplication() -> String? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    private func restore() {
        let p = NSOpenPanel()
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let info = try model.inspectBackup(url)
            let a = NSAlert()
            a.messageText = "Restore this backup?"
            a.informativeText = "\(info.intervalCount) \(info.schemaVersion == 1 ? "legacy intervals" : "five-minute blocks"). Current data is saved to the Backups folder first."
            a.addButton(withTitle: "Restore"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { try model.restore(from: url); message = "Restored." }
        } catch { message = "Restore failed: \(error)" }
    }
}
