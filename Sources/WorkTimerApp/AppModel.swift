import AppKit
import CoreGraphics
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications
import WidgetKit
import WorkTimerCore

private final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let answer: OutsideAnswer?
        switch response.actionIdentifier {
        case "AFTER_HOURS_WORK": answer = .work
        case "AFTER_HOURS_PRIVATE": answer = .private
        case "AFTER_HOURS_LATER": answer = .later
        default: answer = nil
        }
        guard let answer else { return }
        await AppModel.shared.answerOutside(answer)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    // Published state for the UI.
    @Published var now: Millis = AppModel.wallNow()
    @Published var status: LiveStatus?
    @Published var today = DaySummary(date: LocalDate(2000, 1, 1), byCategory: [:], pending: 0, targetMillis: 0, isToday: true)
    @Published var week: WeekSummary?
    @Published var reviews: [ReviewItem] = []
    @Published var pomodoro = PomodoroState()
    @Published var pomodoroRemaining: Millis = 0
    @Published var paused = false
    @Published var health = HealthStatus()
    @Published var launchAtLogin = false
    @Published var fatalError: String?

    private(set) var ledger: Ledger?
    private(set) var location: DatabaseLocation?
    private var engine: TrackingEngine?
    private var pomo: PomodoroTimer?
    private var alerts: WorkAlerts?
    private var inbox: BrowserInbox?
    private var snapshots: SnapshotStore?
    private var timer: Timer?
    private var ingestionSuspended = false
    private var lastSnapshot: Millis = 0
    private var lastBreakActive = false
    private var lastOutsidePrompt = false
    private let notificationHandler = NotificationHandler()

    static func wallNow() -> Millis { Millis(Date().timeIntervalSince1970 * 1000) }
    private func stamp() -> Stamp { Stamp(wall: Self.wallNow(), mono: ProcessInfo.processInfo.systemUptime) }

    var calculator: ReportCalculator? {
        guard let ledger, let engine else { return nil }
        let t = now
        return ReportCalculator(ledger: ledger, live: { engine.liveInterval(now: t) })
    }

    // MARK: Startup

    func start() {
        do {
            let loc = try DatabaseLocation.userProfile()
            try loc.prepare()
            location = loc
            let ledger = try Ledger(path: loc.databaseURL.path, backupsDirectory: loc.backupsDirectory)
            self.ledger = ledger
            let engine = TrackingEngine(ledger: ledger)
            self.engine = engine
            let pomo = PomodoroTimer(ledger: ledger)
            self.pomo = pomo
            alerts = WorkAlerts(ledger: ledger)
            snapshots = SnapshotStore(directory: loc.directory)
            inbox = try? BrowserInbox(path: loc.directory.appendingPathComponent("browser-inbox.sqlite").path)

            let steps = AppUpdateSteps(model: self)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            _ = try PostUpdateCoordinator(defaults: .standard, steps: steps).runOnLaunch(currentVersion: version)

            try engine.recover(now: Self.wallNow())
            pomo.recover(at: Self.wallNow())
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            try engine.handle(.launch(app: app, idleSeconds: Self.idleSeconds()), at: stamp())
            observeSystem()
            configureNotifications()
            requestNotificationAuthorization()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            tick()
        } catch {
            fatalError = "Storage could not be opened: \(error). Tracking is stopped; your data was not modified."
            health.storageOK = false
            health.messages = [fatalError ?? ""]
        }
    }

    func shutdown() {
        _ = try? engine?.handle(.shutdown, at: stamp())
    }

    // MARK: Event sources

    private static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func send(_ e: EngineEvent) {
        guard let engine, !ingestionSuspended else { return }
        do { _ = try engine.handle(e, at: stamp()) } catch {
            health.storageOK = false
            health.messages = ["Storage error: \(error)"]
        }
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self?.send(.appActivated(app)) }
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.send(.sleep); self?.autoPausePomodoro() } }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.send(.wake) } }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.send(.sessionResigned) } }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.send(.sessionActivated) } }
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.send(.lock); self?.autoPausePomodoro() } }
        dc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.send(.unlock) } }
    }

    // MARK: Tick

    private func tick() {
        guard engine != nil else { return }
        let st = stamp()
        send(.idleSample(seconds: Self.idleSeconds()))
        drainBrowserInbox()
        send(.tick)
        if let ev = pomo?.tick(st) { handlePomodoro(ev) }
        pomo?.persistProgress(st)
        pomodoro = pomo?.state ?? PomodoroState()
        pomodoroRemaining = pomo?.remaining(st) ?? 0
        let breakActive = pomo?.isBreakActive ?? false
        if breakActive != lastBreakActive { lastBreakActive = breakActive; send(.pomodoroBreak(breakActive)) }
        refresh()
    }

    private func drainBrowserInbox() {
        guard let inbox else { return }
        for o in (try? inbox.drain()) ?? [] { send(.browser(o)) }
    }

    func refresh() {
        now = Self.wallNow()
        guard let calc = calculator, let ledger else { return }
        status = engine?.liveStatus()
        evaluateAfterHoursPrompt()
        let d = calc.schedule.localDate(now)
        today = calc.day(d, now: now)
        week = calc.week(containing: d, now: now)
        reviews = ledger.reviews(status: .pending)
        paused = engine?.isTrackingPaused ?? false
        evaluateAlerts(calc: calc, date: d)
        if now - lastSnapshot > 30_000 { publishSnapshot(); lastSnapshot = now }
    }

    // MARK: Snapshot, alerts, notifications

    func publishSnapshot() {
        guard let calc = calculator, let snapshots else { return }
        var h = health
        h.trackingPaused = paused
        if (try? snapshots.publish(SnapshotBuilder.build(calc: calc, now: now, health: h, status: status?.category.title ?? "Stopped"))) == nil {
            health.messages = ["Could not write widget data"]
        }
    }

    private func evaluateAlerts(calc: ReportCalculator, date: LocalDate) {
        guard let alerts else { return }
        for a in alerts.newlyCrossed(todayWork: today.work, date: date, schedule: calc.schedule, at: now) {
            notify(title: a.title, body: a.body, id: "alert-\(a.minutes)")
        }
    }

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func configureNotifications() {
        guard canNotify else { return }
        let work = UNNotificationAction(identifier: "AFTER_HOURS_WORK", title: "Work")
        let privateTime = UNNotificationAction(identifier: "AFTER_HOURS_PRIVATE", title: "Private")
        let later = UNNotificationAction(identifier: "AFTER_HOURS_LATER", title: "Ask Later")
        let category = UNNotificationCategory(identifier: "AFTER_HOURS",
                                              actions: [work, privateTime, later],
                                              intentIdentifiers: [])
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationHandler
        center.setNotificationCategories([category])
    }

    private func evaluateAfterHoursPrompt() {
        let isPrompting = status?.outsidePrompt == true
        if isPrompting && !lastOutsidePrompt {
            notify(title: "What are you doing?",
                   body: "You’re active outside your working hours. Count this as work or private time?",
                   id: "after-hours-\(status?.since ?? now)",
                   category: "AFTER_HOURS")
        }
        lastOutsidePrompt = isPrompting
    }

    func requestNotificationAuthorization() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.health.notificationsOK = granted }
        }
    }

    func notify(title: String, body: String, id: String = UUID().uuidString, category: String? = nil) {
        guard canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        if let category { c.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    func sendTestNotification() { notify(title: "WorkTimer", body: "Notifications are working.") }

    // MARK: Pomodoro

    private func handlePomodoro(_ e: PomodoroEvent) {
        switch e {
        case .focusCompleted(let next): notify(title: "Focus complete", body: next == .longBreak ? "Time for a long break." : "Time for a short break.")
        case .breakCompleted: notify(title: "Break over", body: "Ready for the next focus session.")
        }
    }

    private func autoPausePomodoro() { if let p = pomo { p.autoPause(stamp()); pomodoro = p.state } }
    func pomodoroStartFocus() { pomo?.startFocus(stamp()); tick() }
    func pomodoroStartBreak() { pomo?.startBreak(stamp()); tick() }
    func pomodoroPause() { pomo?.pause(stamp()); tick() }
    func pomodoroResume() { pomo?.resume(stamp()); tick() }
    func pomodoroEnd() { pomo?.skipOrEnd(stamp()); tick() }

    // MARK: Tracking controls

    func togglePause() { send(paused ? .resume : .pause); refresh() }
    func answerOutside(_ a: OutsideAnswer) {
        send(.answerOutside(a))
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["after-hours-\(status?.since ?? now)"])
        refresh()
    }

    // MARK: Corrections

    func resolve(_ r: ReviewItem, as a: ReviewAnswer) {
        guard let ledger else { return }
        try? ReviewResolver(ledger: ledger).resolve(r, as: a, now: Self.wallNow())
        refresh()
    }

    func reclassify(_ span: Span, as c: WorkTimerCore.Category, note: String) {
        guard let ledger else { return }
        _ = try? ReviewResolver(ledger: ledger).reclassify(span, as: c, note: note, now: Self.wallNow())
        refresh()
    }

    func addManualWork(_ span: Span, note: String) {
        guard let ledger else { return }
        _ = try? ReviewResolver(ledger: ledger).addManualWork(span, note: note, now: Self.wallNow())
        refresh()
    }

    func undo(_ id: Int64) {
        guard let ledger else { return }
        try? ReviewResolver(ledger: ledger).undo(adjustmentID: id, now: Self.wallNow())
        refresh()
    }

    // MARK: Data management

    func backup(to url: URL) throws {
        guard let ledger, let location else { return }
        try BackupManager(ledger: ledger, location: location).createBackup(to: url)
    }

    func restore(from url: URL) throws {
        guard let ledger, let location else { return }
        ingestionSuspended = true
        defer { ingestionSuspended = false }
        try BackupManager(ledger: ledger, location: location).restore(from: url)
        engine?.reloadConfiguration()
        publishSnapshot()
        refresh()
    }

    func inspectBackup(_ url: URL) throws -> BackupInfo {
        guard let ledger, let location else { throw BackupError.invalid("Storage unavailable") }
        return try BackupManager(ledger: ledger, location: location).inspect(url)
    }

    func deleteRange(_ span: Span) {
        try? ledger?.deleteRange(span)
        publishSnapshot(); refresh()
    }

    func deleteAllHistory() {
        try? ledger?.deleteAllHistory()
        inbox?.clear()
        snapshots?.delete()
        publishSnapshot(); refresh()
    }

    func exportCSV(range: ClosedRange<LocalDate>, timeline: Bool) -> String {
        guard let calc = calculator else { return "" }
        return timeline ? CSV.timeline(calc, range: range) : CSV.summary(calc, range: range, now: now)
    }

    func revealDataFolder() {
        if let d = location?.directory { NSWorkspace.shared.activateFileViewerSelecting([d]) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {
            health.messages = ["Launch at login failed: \(error.localizedDescription)"]
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Settings access

    func rules() -> [ClassificationRule] { ledger?.rules() ?? [] }
    func upsert(_ r: ClassificationRule) { try? ledger?.upsertRule(r); engine?.reloadConfiguration(); refresh() }
    func deleteRule(_ id: Int64) { try? ledger?.deleteRule(id: id); engine?.reloadConfiguration(); refresh() }
    func overrides() -> [DayOverride] { ledger?.dayOverrides() ?? [] }
    func setOverride(_ o: DayOverride) { try? ledger?.setDayOverride(o); engine?.reloadConfiguration(); refresh() }
    func removeOverride(_ d: LocalDate) { try? ledger?.removeDayOverride(d); engine?.reloadConfiguration(); refresh() }
    func currentSchedule() -> Schedule? { ledger?.schedule() }
}

/// Real implementation of the post-update steps: migrate with a backup, republish widget data, reload widget timelines.
struct AppUpdateSteps: UpdateSteps {
    let model: AppModel
    func backupAndMigrate() throws {}  // Ledger.init already backs up and migrates before this runs.
    func republishWidgetSnapshot() throws { DispatchQueue.main.async { Task { @MainActor in model.publishSnapshot() } } }
    func reloadWidgets() { WidgetCenter.shared.reloadAllTimelines() }
}
