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
    case .work: return .green
    case .privateTime: return .purple
    case .breakTime: return .orange
    case .idle: return .gray
    case .away: return .secondary
    case .gap: return .red
    }
}

private enum WorkStyle {
    static let accent = Color(red: 0.06, green: 0.48, blue: 0.44)
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(WorkStyle.accent)
                .frame(width: 38, height: 38)
                .background(WorkStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: Menu bar

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.paused { Label("Paused", systemImage: "pause.circle") }
        else if !model.health.storageOK { Label("Storage error", systemImage: "exclamationmark.triangle") }
        else { Label(hm(model.today.work), systemImage: "clock.badge.checkmark") }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("WorkTimer", systemImage: "clock.badge.checkmark")
                    .font(.headline)
                Spacer()
                Text(Date().formatted(.dateTime.weekday(.wide)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let err = model.fatalError { Text(err).foregroundStyle(.red) }
            if model.health.notificationsOK == false {
                HStack {
                    Label("Notifications are off", systemImage: "bell.slash")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Enable") { model.openNotificationSettings() }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(hm(model.today.work)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("/ \(hm(model.today.targetMillis)) today").foregroundStyle(.secondary)
            }
            if model.today.targetMillis > 0 {
                ProgressView(value: max(0, min(Double(model.today.work) / Double(model.today.targetMillis), 1)))
                    .tint(WorkStyle.accent)
            }
            if let w = model.week {
                HStack {
                    Label("Week \(hm(w.work)) / \(hm(w.fullWeekTarget))", systemImage: "calendar")
                    Spacer()
                    Text(hm(w.toDateBalance, signed: true))
                }.font(.caption).foregroundStyle(.secondary)
                if w.currentDayIncomplete { Text("Today’s target is included in balance.").font(.caption2).foregroundStyle(.secondary) }
            }
            if let s = model.status {
                Label("\(s.category.title): \(s.reason.explanation)", systemImage: "circle.fill").foregroundStyle(color(s.category)).font(.caption)
                if s.outsidePrompt {
                    Text("Outside work hours. Is this work?").font(.caption)
                    HStack {
                        Button("Work") { model.answerOutside(.work) }
                        Button("Private") { model.answerOutside(.private) }
                        Button("Later") { model.answerOutside(.later) }
                    }
                }
            }
            if model.today.pending > 0 || !model.reviews.isEmpty {
                Text("\(model.reviews.count) item(s) to review").font(.caption).foregroundStyle(.orange)
            }
            if model.pomodoro.status != .stopped {
                Text("Pomodoro \(model.pomodoro.phase.rawValue): \(hm(model.pomodoroRemaining))").font(.caption)
            }
            Divider()
            Button { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } label: {
                Label("Open WorkTimer", systemImage: "macwindow")
            }.buttonStyle(.borderedProminent).tint(WorkStyle.accent).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button { model.togglePause() } label: {
                    Label(model.paused ? "Resume tracking" : "Pause tracking", systemImage: model.paused ? "play.fill" : "pause.fill")
                }
                Spacer()
                Button("Quit") { model.shutdown(); NSApp.terminate(nil) }
            }
            Text("Quitting stops tracking; time while the app is closed shows as unknown.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 340)
    }
}

// MARK: Main window

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView {
            TodayView(model: model).tabItem { Label("Today", systemImage: "clock.badge.checkmark") }
            ReportsView(model: model).tabItem { Label("Reports", systemImage: "chart.bar.xaxis") }
            ReviewView(model: model).tabItem { Label("Review (\(model.reviews.count))", systemImage: "tray.full") }
            PomodoroView(model: model).tabItem { Label("Pomodoro", systemImage: "timer") }
            SettingsView(model: model).tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .frame(minWidth: 760, minHeight: 520)
        .padding(20)
        .tint(WorkStyle.accent)
    }
}

struct TodayView: View {
    @ObservedObject var model: AppModel
    @Local private var showManual = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Today", subtitle: Date().formatted(date: .complete, time: .omitted), symbol: "sun.max")
            HStack(spacing: 0) {
                stat("Work", hm(model.today.work))
                stat("Target", hm(model.today.targetMillis))
                stat("Balance", hm(model.today.balance, signed: true) + (model.today.isToday ? " (incomplete)" : ""))
                stat("Pending", hm(model.today.pending))
            }
            .padding(16)
            .background(WorkStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button { showManual = true } label: { Label("Add manual entry", systemImage: "plus") }
            }
            let segs = model.calculator?.segments(in: model.calculator!.schedule.daySpan(model.today.date)) ?? []
            List(segs.reversed(), id: \.span.start) { s in
                HStack(spacing: 12) {
                    Circle().fill(color(s.category)).frame(width: 10, height: 10)
                    Text("\(timeText(s.span.start))–\(timeText(s.span.end))").monospacedDigit().foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.category.title).fontWeight(.semibold)
                        if let detail = s.domain ?? s.app { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Text(s.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if s.pending { Text("pending").font(.caption).foregroundStyle(.orange) }
                    Menu("Change") {
                        ForEach([WorkTimerCore.Category.work, .privateTime, .breakTime], id: \.self) { c in
                            Button("Mark as \(c.title)") { model.reclassify(s.span, as: c, note: "Manual change") }
                        }
                        if case .correction(let id) = s.source { Button("Undo correction") { model.undo(id) } }
                    }.fixedSize()
                }.padding(.vertical, 4)
            }
            .overlay {
                if segs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").font(.title).foregroundStyle(.secondary)
                        Text("No activity yet").font(.headline)
                        Text("Tracked activity will appear here.").font(.caption).foregroundStyle(.secondary)
                    }.allowsHitTesting(false)
                }
            }
        }
        .sheet(isPresented: $showManual) { ManualEntryView(model: model, isPresented: $showManual) }
    }
    private func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ManualEntryView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @Local private var start = Calendar.current.date(byAdding: .hour, value: -1, to: Date())!
    @Local private var end = Date()
    @Local private var note = ""
    var body: some View {
        Form {
            DatePicker("Start", selection: $start)
            DatePicker("End", selection: $end)
            TextField("Note", text: $note)
            HStack {
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    let s = Millis(start.timeIntervalSince1970 * 1000), e = Millis(end.timeIntervalSince1970 * 1000)
                    if e > s { model.addManualWork(Span(s, e), note: note) }
                    isPresented = false
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
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Reports", subtitle: "Your work over time", symbol: "chart.bar.xaxis")
            HStack {
                Picker("", selection: $scope) { Text("Week").tag(0); Text("Month").tag(1) }.pickerStyle(.segmented).frame(width: 180)
                DatePicker("", selection: $anchor, displayedComponents: .date).labelsHidden()
                Spacer()
                Button("Export summary CSV") { export(timeline: false) }
                Button("Export timeline CSV") { export(timeline: true) }
            }
            if let calc = model.calculator {
                let d = calc.schedule.localDate(Millis(anchor.timeIntervalSince1970 * 1000))
                if scope == 0 { weekView(calc, d) } else { monthView(calc, d) }
            }
        }
    }

    @ViewBuilder private func weekView(_ calc: ReportCalculator, _ d: LocalDate) -> some View {
        let w = calc.week(containing: d, now: model.now)
        Text("Work \(hm(w.work)) · full-week target \(hm(w.fullWeekTarget)) · to-date balance \(hm(w.toDateBalance, signed: true))\(w.currentDayIncomplete ? " (today incomplete)" : "") · ceiling \(hm(w.weeklyCeiling))")
        if w.pending > 0 { Text("Includes \(hm(w.pending)) pending review, not counted as work.").font(.caption).foregroundStyle(.orange) }
        chart(w.days)
        attribution(calc, Span(calc.schedule.startOfDay(w.weekStart), calc.schedule.startOfDay(calc.schedule.addDays(w.weekStart, 7))))
    }

    @ViewBuilder private func monthView(_ calc: ReportCalculator, _ d: LocalDate) -> some View {
        let m = calc.month(containing: d, now: model.now)
        Text("Work \(hm(m.work)) · target \(hm(m.target)) · balance \(hm(m.balance, signed: true))")
        chart(m.days)
        attribution(calc, Span(calc.schedule.startOfDay(m.range.lowerBound), calc.schedule.startOfDay(calc.schedule.addDays(m.range.upperBound, 1))))
    }

    private func chart(_ days: [DaySummary]) -> some View {
        Chart(days, id: \.date) { d in
            BarMark(x: .value("Day", d.date.description), y: .value("Hours", Double(d.work) / Double(Duration.hour)))
            RuleMark(y: .value("Target", Double(d.targetMillis) / Double(Duration.hour))).foregroundStyle(.secondary)
        }.foregroundStyle(WorkStyle.accent).frame(height: 200)
    }

    private func attribution(_ calc: ReportCalculator, _ span: Span) -> some View {
        let a = calc.attribution(in: span)
        return HStack(alignment: .top) {
            List(Array(a.apps.prefix(8)), id: \.key) { row in HStack { Text(row.key); Spacer(); Text(hm(row.millis)) } }
            List(Array(a.domains.prefix(8)), id: \.key) { row in HStack { Text(row.key); Spacer(); Text(hm(row.millis)) } }
        }
    }

    private func export(timeline: Bool) {
        guard let calc = model.calculator else { return }
        let d = calc.schedule.localDate(Millis(anchor.timeIntervalSince1970 * 1000))
        let range = scope == 0 ? calc.schedule.weekStart(containing: d)...calc.schedule.addDays(calc.schedule.weekStart(containing: d), 6) : calc.schedule.monthRange(containing: d)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "worktimer-\(timeline ? "timeline" : "summary")-\(range.lowerBound).csv"
        if panel.runModal() == .OK, let url = panel.url { try? model.exportCSV(range: range, timeline: timeline).write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: Review

struct ReviewView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
          SectionHeading(title: "Review", subtitle: "Resolve time that needs your input", symbol: "tray.full")
          if model.reviews.isEmpty {
              VStack(spacing: 8) {
                  Image(systemName: "checkmark.circle").font(.system(size: 36)).foregroundStyle(WorkStyle.accent)
                  Text("All caught up").font(.headline)
                  Text("Time needing review will appear here.").foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            List(model.reviews, id: \.id) { r in
                HStack {
                    VStack(alignment: .leading) {
                        Text(r.type == .idle ? "Idle period" : r.type == .gap ? "Unknown gap" : "Outside work hours").bold()
                        Text("\(timeText(r.start))–\(r.end.map(timeText) ?? "ongoing")").font(.caption).monospacedDigit()
                    }
                    Spacer()
                    Button("Work") { model.resolve(r, as: .work) }
                    Button("Break") { model.resolve(r, as: .breakTime) }
                    Button("Private") { model.resolve(r, as: .privateTime) }
                    Button("Later") { model.resolve(r, as: .later) }
                }
              }
            }
        }
    }
}

// MARK: Pomodoro

struct PomodoroView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "timer").font(.system(size: 28, weight: .medium)).foregroundStyle(WorkStyle.accent)
            Text(model.pomodoro.status == .stopped ? "Not running" : "\(model.pomodoro.phase.rawValue.capitalized) · \(model.pomodoro.status.rawValue)").font(.headline)
            Text(hm(model.pomodoroRemaining)).font(.system(size: 64, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("Completed focus sessions: \(model.pomodoro.completedFocus)")
            HStack {
                Button("Start focus") { model.pomodoroStartFocus() }.buttonStyle(.borderedProminent)
                Button("Start break") { model.pomodoroStartBreak() }
                if model.pomodoro.status == .running { Button("Pause") { model.pomodoroPause() } }
                if model.pomodoro.status == .paused { Button("Resume") { model.pomodoroResume() } }
                Button("End / skip") { model.pomodoroEnd() }
            }
            Text("Break phases are excluded from work time. Pausing happens automatically on sleep and lock.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Settings

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Local private var newPattern = ""
    @Local private var newKind = RuleKind.domain
    @Local private var newIsWork = false
    @Local private var rules: [ClassificationRule] = []
    @Local private var offDate = Date()
    @Local private var message = ""
    @Local private var confirmDeleteAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: "Settings", subtitle: "Tracking, rules and your data", symbol: "slider.horizontal.3")
                GroupBox("General") {
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
                GroupBox("Health") {
                    VStack(alignment: .leading) {
                        Text("Storage: \(model.health.storageOK ? "OK" : "Problem")")
                        Text("Notifications: \(model.health.notificationsOK.map { $0 ? "Allowed" : "Not allowed" } ?? "Unknown")")
                        if model.health.notificationsOK == false {
                            Button("Open Notification Settings") { model.openNotificationSettings() }
                        }
                        ForEach(model.health.messages, id: \.self) { Text($0).foregroundStyle(.red) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Rules (private domains beat work; domain rules beat app rules)") {
                    VStack(alignment: .leading) {
                        ForEach(rules, id: \.id) { r in
                            HStack {
                                Text("\(r.kind == .domain ? "Domain" : "App") \(r.pattern) → \(r.isWork ? "Work" : "Private")")
                                Spacer()
                                Button("Remove") { if let id = r.id { model.deleteRule(id); rules = model.rules() } }
                            }
                        }
                        HStack {
                            Picker("", selection: $newKind) { Text("Domain").tag(RuleKind.domain); Text("App bundle ID").tag(RuleKind.app) }.frame(width: 140)
                            TextField("pattern", text: $newPattern)
                            Picker("", selection: $newIsWork) { Text("Private").tag(false); Text("Work").tag(true) }.frame(width: 100)
                            Button("Add") {
                                let p = newKind == .domain ? (DomainMatcher.normalize(newPattern) ?? "") : newPattern.trimmingCharacters(in: .whitespaces)
                                if !p.isEmpty { model.upsert(ClassificationRule(kind: newKind, pattern: p, isWork: newIsWork)); newPattern = ""; rules = model.rules() }
                            }
                        }
                    }
                }
                GroupBox("Days off (target 0)") {
                    VStack(alignment: .leading) {
                        ForEach(model.overrides(), id: \.date) { o in
                            HStack { Text("\(o.date.description) target \(o.targetMinutes) min"); Spacer(); Button("Remove") { model.removeOverride(o.date); rules = model.rules() } }
                        }
                        HStack {
                            DatePicker("", selection: $offDate, displayedComponents: .date).labelsHidden()
                            Button("Mark day off") {
                                if let tz = model.currentSchedule()?.timeZone {
                                    var c = Calendar(identifier: .gregorian); c.timeZone = tz
                                    let p = c.dateComponents([.year, .month, .day], from: offDate)
                                    model.setOverride(DayOverride(date: LocalDate(p.year!, p.month!, p.day!), targetMinutes: 0, note: "Day off"))
                                    rules = model.rules()
                                }
                            }
                        }
                    }
                }
                GroupBox("Data (stored in your user profile; backups are not encrypted)") {
                    VStack(alignment: .leading) {
                        HStack {
                            Button("Create backup…") { backup() }
                            Button("Restore backup…") { restore() }
                            Button("Delete all history…") { confirmDeleteAll = true }
                        }
                        if !message.isEmpty { Text(message).font(.caption) }
                    }
                }
            }.padding()
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

    private func restore() {
        let p = NSOpenPanel()
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let info = try model.inspectBackup(url)
            let a = NSAlert()
            a.messageText = "Restore this backup?"
            a.informativeText = "\(info.intervalCount) intervals. Current data is saved to the Backups folder first."
            a.addButton(withTitle: "Restore"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { try model.restore(from: url); message = "Restored." }
        } catch { message = "Restore failed: \(error)" }
    }
}
