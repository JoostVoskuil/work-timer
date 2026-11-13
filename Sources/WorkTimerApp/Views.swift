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

// MARK: Menu bar

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.paused { Label("Paused", systemImage: "pause.circle") }
        else if !model.health.storageOK { Label("Storage error", systemImage: "exclamationmark.triangle") }
        else { Text("Work \(hm(model.today.work))") }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = model.fatalError { Text(err).foregroundStyle(.red) }
            Text("Today \(hm(model.today.work)) of \(hm(model.today.targetMillis))").font(.headline)
            if let w = model.week {
                Text("Week \(hm(w.work)) / \(hm(w.fullWeekTarget)) · balance \(hm(w.toDateBalance, signed: true))\(w.currentDayIncomplete ? " (today incomplete)" : "")")
                    .font(.caption)
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
            Button(model.paused ? "Resume tracking" : "Pause tracking") { model.togglePause() }
            Button("Open WorkTimer…") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button("Quit") { model.shutdown(); NSApp.terminate(nil) }
            Text("Quitting stops tracking; time while the app is closed shows as unknown.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 320)
    }
}

// MARK: Main window

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView {
            TodayView(model: model).tabItem { Label("Today", systemImage: "clock") }
            ReportsView(model: model).tabItem { Label("Reports", systemImage: "chart.bar") }
            ReviewView(model: model).tabItem { Label("Review (\(model.reviews.count))", systemImage: "questionmark.circle") }
            PomodoroView(model: model).tabItem { Label("Pomodoro", systemImage: "timer") }
            SettingsView(model: model).tabItem { Label("Settings", systemImage: "gear") }
        }
        .frame(minWidth: 760, minHeight: 520)
        .padding()
    }
}

struct TodayView: View {
    @ObservedObject var model: AppModel
    @Local private var showManual = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                stat("Work", hm(model.today.work))
                stat("Target", hm(model.today.targetMillis))
                stat("Balance", hm(model.today.balance, signed: true) + (model.today.isToday ? " (incomplete)" : ""))
                stat("Pending", hm(model.today.pending))
            }
            let segs = model.calculator?.segments(in: model.calculator!.schedule.daySpan(model.today.date)) ?? []
            List(segs.reversed(), id: \.span.start) { s in
                HStack {
                    Circle().fill(color(s.category)).frame(width: 10, height: 10)
                    Text("\(timeText(s.span.start))–\(timeText(s.span.end))").monospacedDigit()
                    Text(s.category.title).bold()
                    Text(s.domain ?? s.app ?? "").foregroundStyle(.secondary)
                    Spacer()
                    Text(s.explanation).font(.caption).foregroundStyle(.secondary)
                    if s.pending { Text("pending").font(.caption).foregroundStyle(.orange) }
                    Menu("Change") {
                        ForEach([WorkTimerCore.Category.work, .privateTime, .breakTime], id: \.self) { c in
                            Button("Mark as \(c.title)") { model.reclassify(s.span, as: c, note: "Manual change") }
                        }
                        if case .correction(let id) = s.source { Button("Undo correction") { model.undo(id) } }
                    }.fixedSize()
                }
            }
            Button("Add manual work entry…") { showManual = true }
        }
        .sheet(isPresented: $showManual) { ManualEntryView(model: model, isPresented: $showManual) }
    }
    private func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading) { Text(t).font(.caption).foregroundStyle(.secondary); Text(v).font(.title2).monospacedDigit() }
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
        }.frame(height: 200)
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
        if model.reviews.isEmpty { Text("Nothing to review.").foregroundStyle(.secondary) }
        else {
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

// MARK: Pomodoro

struct PomodoroView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Text(model.pomodoro.status == .stopped ? "Not running" : "\(model.pomodoro.phase.rawValue.capitalized) · \(model.pomodoro.status.rawValue)").font(.headline)
            Text(hm(model.pomodoroRemaining)).font(.system(size: 56, weight: .light)).monospacedDigit()
            Text("Completed focus sessions: \(model.pomodoro.completedFocus)")
            HStack {
                Button("Start focus") { model.pomodoroStartFocus() }
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
                GroupBox("General") {
                    VStack(alignment: .leading) {
                        Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        Button("Send test notification") { model.sendTestNotification() }
                        Button("Reveal data folder") { model.revealDataFolder() }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Health") {
                    VStack(alignment: .leading) {
                        Text("Storage: \(model.health.storageOK ? "OK" : "Problem")")
                        Text("Notifications: \(model.health.notificationsOK.map { $0 ? "Allowed" : "Not allowed" } ?? "Unknown")")
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
