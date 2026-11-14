import AppKit
import CoreGraphics
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications
import WidgetKit
import WorkTimerCore
import OSLog

private final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let answer: OutsideAnswer?
        switch response.actionIdentifier {
        case "AFTER_HOURS_WORK": answer = .work
        case "AFTER_HOURS_LEARN": answer = .learn
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
    let pomodoroDisplay = PomodoroCountdownDisplay()

    var livePomodoroRemaining: Millis { pomo?.remaining(stamp()) ?? 0 }
    @Published var paused = false
    @Published var learning = false
    @Published var manualMode: WorkTimerCore.Category?
    @Published var scheduledMode: WorkTimerCore.Category = .privateTime
    @Published var health = HealthStatus()
    @Published var launchAtLogin = false
    @Published var fatalError: String?
    @Published var reviewError: String?
    @Published var notificationTestStatus: String?
    @Published var isSendingTestNotification = false
    @Published var activityBlocks: [ActivityBlock] = []
    @Published var menuHours: [WidgetGraphBucket] = []
    private var menuIsVisible = false
    @Published private(set) var selectedActivityDate: LocalDate?
    @Published var activityDay = DaySummary(date: LocalDate(2000, 1, 1), byCategory: [:], pending: 0, targetMillis: 0, isToday: true)
    @Published var blockCorrections: [Adjustment] = []
    @Published var compactionNotice: String?

    private(set) var ledger: Ledger?
    private(set) var location: DatabaseLocation?
    private var instanceLock: SingleInstanceLock?
    private var engine: TrackingEngine?
    private var pomo: PomodoroTimer?
    private var alerts: WorkAlerts?
    private var inbox: BrowserInbox?
    private var snapshots: SnapshotStore?
    private var appNames: [String: String] = [:]
    private var timer: Timer?
    private var ingestionSuspended = false
    private var lastSnapshot: Millis = 0
    private var lastWidgetReload: Millis?
    private var widgetPublishError: String?
    private let widgetLogger = Logger(subsystem: "nl.foxhole.worktimer", category: "WidgetPublishing")
    private var lastBreakActive = false
    private var didPromptNotificationSettings = false
    private let notificationHandler = NotificationHandler()

    static func wallNow() -> Millis { Millis(Date().timeIntervalSince1970 * 1000) }
    private func stamp() -> Stamp { Stamp(wall: Self.wallNow(), mono: ProcessInfo.processInfo.systemUptime) }

    var calculator: ReportCalculator? {
        guard let ledger, let engine else { return nil }
        let t = now
        return ReportCalculator(ledger: ledger, liveBlocks: { engine.liveIntervals(now: t) })
    }

    /// Apps seen in the last two weeks plus currently running regular apps, sorted by name, for picking app rules.
    func knownAppIdentifiers() -> [String] {
        var ids = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier))
        if let calc = calculator {
            let today = calc.schedule.localDate(now)
            let span = Span(calc.schedule.startOfDay(calc.schedule.addDays(today, -13)), max(now, calc.schedule.startOfDay(today) + 1))
            for block in (try? calc.blocks(in: span)) ?? [] { ids.formUnion(block.apps) }
        }
        ids.remove(Bundle.main.bundleIdentifier ?? "")
        return ids.sorted { appName(for: $0).localizedCaseInsensitiveCompare(appName(for: $1)) == .orderedAscending }
    }

    func addAppRule(_ identifier: String, category: WorkTimerCore.Category) {
        upsert(ClassificationRule(kind: .app, pattern: identifier, category: category))
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func appName(for identifier: String) -> String {
        if let name = appNames[identifier] { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            appNames[identifier] = identifier
            return identifier
        }
        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        appNames[identifier] = name
        return name
    }

    // MARK: Startup

    func start() {
        guard instanceLock == nil else { return }
        do {
            let loc = try DatabaseLocation.userProfile()
            try loc.prepare()
            do {
                instanceLock = try SingleInstanceLock(at: loc.directory.appendingPathComponent("worktimer.lock"))
            } catch SingleInstanceError.alreadyRunning {
                Logger(subsystem: "nl.foxhole.worktimer", category: "Lifecycle")
                    .notice("Another WorkTimer instance already owns the tracking lock; exiting")
                NSApplication.shared.terminate(nil)
                return
            }
            location = loc
            let ledger = try Ledger(path: loc.databaseURL.path)
            self.ledger = ledger
            if let backup = ledger.compactionBackup {
                compactionNotice = "History compacted into five-minute blocks. Original detail is backed up at \(backup)"
            }
            if let backup = ledger.getSetting("late_legacy_backup") {
                compactionNotice = (compactionNotice.map { $0 + "\n" } ?? "") + "Late records from an older copy were reconciled. Backup: \(backup). Use only /Applications/WorkTimer.app."
            }
            if let backup = ledger.getSetting("inactive_cleanup_backup") {
                compactionNotice = (compactionNotice.map { $0 + "\n" } ?? "") + "Outside-hours Away cleanup backup: \(backup). Mixed or corrected blocks were preserved."
            }
            if let error = ledger.getSetting("compaction_maintenance_error") { health.messages.append(error) }
            let engine = TrackingEngine(ledger: ledger)
            self.engine = engine
            let pomo = PomodoroTimer(ledger: ledger)
            self.pomo = pomo
            alerts = WorkAlerts(ledger: ledger)
            snapshots = SnapshotStore(directory: loc.directory)
            do {
                inbox = try BrowserInbox(path: SnapshotStore.sharedDirectory().appendingPathComponent("browser-inbox.sqlite").path)
            } catch {
                health.safariOK = false
                health.messages.append("Could not open shared Safari inbox: \(error.localizedDescription)")
            }

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
        pomodoroDisplay.stop()
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
        synchronizePomodoroUI()
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
        let d = calc.schedule.localDate(now)
        today = calc.day(d, now: now)
        week = calc.week(containing: d, now: now)
        reviews = ledger.reviews(status: .pending)
        let activityDate = selectedActivityDate ?? d
        activityDay = activityDate == d ? today : calc.day(activityDate, now: now)
        do {
            activityBlocks = try calc.blocks(in: calc.schedule.daySpan(activityDate))
            blockCorrections = try ledger.adjustments(in: calc.schedule.daySpan(activityDate))
        } catch {
            activityBlocks = []
            blockCorrections = []
            health.storageOK = false
            health.messages = ["Activity could not be loaded: \(error)"]
        }
        if menuIsVisible {
            menuHours = SnapshotBuilder.hourlyBuckets(calc: calc, day: d)
        }
        if let error = ledger.accountingError {
            health.storageOK = false
            health.messages = [error]
        }
        paused = engine?.isTrackingPaused ?? false
        learning = engine?.isLearning ?? false
        manualMode = engine?.manualMode
        scheduledMode = engine?.scheduledCategory(at: now) ?? (calc.schedule.inWorkWindow(now) ? .work : .privateTime)
        evaluateAlerts(calc: calc, date: d)
        if now - lastSnapshot > 30_000 { publishSnapshot(); lastSnapshot = now }
    }

    // MARK: Snapshot, alerts, notifications

    func publishSnapshot() {
        guard let calc = calculator, let snapshots else { return }
        var h = health
        h.trackingPaused = paused
        do {
            let snapshot = SnapshotBuilder.build(calc: calc, now: now, health: h, status: status?.category.title ?? "Stopped")
            guard ledger?.accountingError == nil else { throw SQLiteError.invalid(ledger?.accountingError ?? "Accounting unavailable") }
            try snapshots.publish(snapshot)
            try SnapshotStore.sharedContainer().publish(snapshot)
            if let widgetPublishError { health.messages.removeAll { $0 == widgetPublishError } }
            widgetPublishError = nil
            if lastWidgetReload == nil || now - (lastWidgetReload ?? now) >= 15 * Duration.minute {
                widgetLogger.notice("Shared widget snapshot published; requesting timeline reload")
                WidgetCenter.shared.reloadAllTimelines()
                lastWidgetReload = now
            }
        } catch {
            let message = "Could not publish widget data: \(error.localizedDescription)"
            if let widgetPublishError { health.messages.removeAll { $0 == widgetPublishError } }
            widgetPublishError = message
            health.messages.append(message)
            widgetLogger.error("Widget snapshot publication failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func evaluateAlerts(calc: ReportCalculator, date: LocalDate) {
        guard let alerts else { return }
        for a in alerts.newlyCrossed(todayWork: today.work, date: date, schedule: calc.schedule, at: now) {
            notify(title: a.title, body: a.body, id: "alert-\(a.minutes)")
        }
        do {
            if let week, let alert = try alerts.newlyReachedWeeklyCeiling(week, at: now) {
                notify(title: alert.title, body: alert.body, id: "weekly-ceiling-\(week.weekStart)")
            }
        } catch {
            health.messages = ["Could not save weekly limit notification: \(error.localizedDescription)"]
            NSLog("%@", health.messages[0])
        }
    }

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func configureNotifications() {
        guard canNotify else { return }
        let work = UNNotificationAction(identifier: "AFTER_HOURS_WORK", title: "Work")
        let learn = UNNotificationAction(identifier: "AFTER_HOURS_LEARN", title: "Learn")
        let privateTime = UNNotificationAction(identifier: "AFTER_HOURS_PRIVATE", title: "Private")
        let later = UNNotificationAction(identifier: "AFTER_HOURS_LATER", title: "Ask Later")
        let category = UNNotificationCategory(identifier: "AFTER_HOURS",
                                              actions: [work, learn, privateTime, later],
                                              intentIdentifiers: [])
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationHandler
        center.setNotificationCategories([category])
    }

    func requestNotificationAuthorization() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in self?.health.notificationsOK = true }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in self?.health.notificationsOK = granted }
                }
            case .denied:
                Task { @MainActor in
                    guard let self else { return }
                    self.health.notificationsOK = false
                    self.promptForNotificationSettings()
                }
            @unknown default:
                Task { @MainActor in self?.health.notificationsOK = false }
            }
        }
    }

    private func promptForNotificationSettings() {
        guard !didPromptNotificationSettings else { return }
        didPromptNotificationSettings = true
        let alert = NSAlert()
        alert.messageText = "Enable WorkTimer notifications?"
        alert.informativeText = "Notifications are needed to ask whether activity outside your working hours is work or private time."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Notification Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openNotificationSettings() }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func notify(title: String, body: String, id: String = UUID().uuidString, category: String? = nil) {
        guard canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        if let category { c.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { [weak self] error in
            guard let error else { return }
            let message = "Notification failed: \(error.localizedDescription)"
            NSLog("%@", message)
            Task { @MainActor in self?.notificationTestStatus = message }
        }
    }

    func sendTestNotification() {
        guard !isSendingTestNotification else { return }
        guard canNotify else {
            notificationTestStatus = "Run the installed WorkTimer app to send notifications."
            return
        }
        isSendingTestNotification = true
        notificationTestStatus = "Checking notification permission…"
        Task {
            defer { isSendingTestNotification = false }
            let center = UNUserNotificationCenter.current()
            do {
                var settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                    settings = await center.notificationSettings()
                }
                guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
                    health.notificationsOK = false
                    notificationTestStatus = "Notifications are blocked. Open Notification Settings and allow WorkTimer."
                    return
                }
                health.notificationsOK = true
                let content = UNMutableNotificationContent()
                content.title = "WorkTimer test"
                content.body = "Notifications are working."
                content.sound = .default
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                if settings.alertSetting == .disabled {
                    notificationTestStatus = "Test sent, but banners are disabled. Enable alerts for WorkTimer in Notification Settings."
                } else {
                    notificationTestStatus = "Test sent. If no banner appears, check Notification Center and allow WorkTimer in your active Focus mode."
                }
            } catch {
                notificationTestStatus = "Notification failed: \(error.localizedDescription)"
                NSLog("%@", notificationTestStatus ?? "Notification failed")
            }
        }
    }

    // MARK: Pomodoro

    private func handlePomodoro(_ e: PomodoroEvent) {
        switch e {
        case .focusCompleted(let next): notify(title: "Focus complete", body: next == .longBreak ? "Time for a long break." : "Time for a short break.")
        case .breakCompleted: notify(title: "Break over", body: "Ready for the next focus session.")
        }
    }

    private func synchronizePomodoroUI() {
        let state = pomo?.state ?? PomodoroState()
        if pomodoro != state { pomodoro = state }
        pomodoroDisplay.synchronize(with: pomo)
    }

    private func autoPausePomodoro() {
        pomo?.autoPause(stamp())
        synchronizePomodoroUI()
    }
    func pomodoroToggle() { pomo?.toggle(stamp()); tick() }
    func pomodoroReset() { pomo?.reset(stamp()); tick() }

    var pomodoroFocusMinutes: Int { pomo?.settings.focusMinutes ?? PomodoroSettings().focusMinutes }

    func setPomodoroFocusMinutes(_ minutes: Int) {
        pomo?.setFocusMinutes(minutes)
        objectWillChange.send()
        synchronizePomodoroUI()
    }

    // MARK: Tracking controls

    func togglePause() { send(paused ? .resume : .pause); refresh() }
    func toggleLearning() { send(.learning(!learning)); refresh() }
    func resumeAutomaticMode() { send(.automaticMode); refresh() }
    func answerOutside(_ a: OutsideAnswer) {
        send(.answerOutside(a))
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["after-hours-\(status?.since ?? now)"])
        refresh()
    }

    // MARK: Corrections

    func canAnswerLiveReview(_ review: ReviewItem) -> Bool {
        review.id != nil && review.id == engine?.pendingOutsideReviewID
    }

    func resolve(_ r: ReviewItem, as a: ReviewAnswer) {
        reviewError = nil
        guard let ledger else {
            reviewError = "Reviews could not be saved because storage is unavailable."
            return
        }
        do {
            if r.end == nil {
                guard canAnswerLiveReview(r), a == .work || a == .learn || a == .privateTime else {
                    reviewError = "This period is still open. Wait until it ends before classifying it."
                    return
                }
                _ = try engine?.handle(.answerOutside(a == .work ? .work : a == .learn ? .learn : .private), at: stamp())
            } else {
                try ReviewResolver(ledger: ledger).resolve(r, as: a, now: Self.wallNow())
            }
            refresh()
        } catch {
            reviewError = "Could not save your answer: \(error.localizedDescription). Please try again."
            NSLog("%@", reviewError ?? "Could not save review")
        }
    }

    func reclassify(_ span: Span, as c: WorkTimerCore.Category, note: String) {
        guard let ledger else { return }
        do {
            _ = try ReviewResolver(ledger: ledger).reclassify(span, as: c, note: note, now: Self.wallNow())
            reviewError = nil
        } catch { reviewError = "Could not correct this block: \(error)" }
        refresh()
    }

    func selectActivityDay(_ date: LocalDate?) {
        guard let schedule = calculator?.schedule else { reviewError = "Storage is unavailable."; return }
        let today = schedule.localDate(Self.wallNow())
        if let date, date > today { reviewError = "Choose today or an earlier date."; return }
        selectedActivityDate = date == today ? nil : date
        reviewError = nil
        refresh()
    }

    func setMenuVisible(_ visible: Bool) {
        menuIsVisible = visible
        if visible { refresh() }
    }

    @discardableResult
    func reclassifyBlocks(_ ids: Set<Millis>, as category: WorkTimerCore.Category) -> Bool {
        guard let ledger else { reviewError = "Storage is unavailable."; return false }
        let blocks = activityBlocks.filter { ids.contains($0.id) }
        guard !ids.isEmpty, blocks.count == ids.count else {
            reviewError = "The selection changed. Select the blocks again."
            return false
        }
        do {
            try ReviewResolver(ledger: ledger).reclassify(blocks.map(\.span), as: category,
                                                        note: "Bulk block correction", now: Self.wallNow())
            reviewError = nil
            refresh()
            return true
        } catch {
            reviewError = "Could not correct the selected blocks: \(error)"
            return false
        }
    }

    @discardableResult
    func addManualEntry(_ span: Span, as category: WorkTimerCore.Category, note: String) -> Bool {
        guard let ledger else { reviewError = "Storage is unavailable."; return false }
        do {
            _ = try ReviewResolver(ledger: ledger).addManualEntry(span, as: category, note: note, now: Self.wallNow())
            reviewError = nil
        } catch { reviewError = "Could not add manual time: \(error)"; return false }
        refresh()
        return true
    }

    func undo(_ id: Int64) {
        guard let ledger else { return }
        do {
            try ReviewResolver(ledger: ledger).undo(adjustmentID: id, now: Self.wallNow())
            reviewError = nil
        } catch { reviewError = "Could not undo correction: \(error)" }
        refresh()
    }

    // MARK: Data management

    func backup(to url: URL) throws {
        guard let ledger, let location else { return }
        try engine?.checkpointNow(at: stamp())
        try BackupManager(ledger: ledger, location: location).createBackup(to: url)
    }

    func restore(from url: URL) throws {
        guard let ledger, let location else { return }
        ingestionSuspended = true
        defer { ingestionSuspended = false }
        try engine?.checkpointNow(at: stamp())
        try BackupManager(ledger: ledger, location: location).restore(from: url)
        let replacement = TrackingEngine(ledger: ledger)
        try replacement.recover(now: Self.wallNow())
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        try replacement.handle(.launch(app: app, idleSeconds: Self.idleSeconds()), at: stamp())
        engine = replacement
        pomo = PomodoroTimer(ledger: ledger)
        pomo?.recover(at: Self.wallNow())
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
        guard let ledger else { return }
        do {
            try ledger.deleteAllHistory()
            let replacement = TrackingEngine(ledger: ledger)
            try replacement.handle(.launch(app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, idleSeconds: Self.idleSeconds()), at: stamp())
            engine = replacement
        } catch {
            health.storageOK = false
            health.messages = ["History could not be deleted: \(error)"]
            return
        }
        inbox?.clear()
        snapshots?.delete()
        publishSnapshot(); refresh()
    }

    func exportCSV(range: ClosedRange<LocalDate>, timeline: Bool) throws -> String {
        guard let calc = calculator else { throw SQLiteError.invalid("Storage unavailable") }
        let csv = try timeline ? CSV.timeline(calc, range: range) : CSV.summary(calc, range: range, now: now)
        if let error = ledger?.accountingError { throw SQLiteError.invalid(error) }
        return csv
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

/// Republishes widget data and reloads widget timelines after launch and updates.
struct AppUpdateSteps: UpdateSteps {
    let model: AppModel
    func republishWidgetSnapshot() throws { DispatchQueue.main.async { Task { @MainActor in model.publishSnapshot() } } }
    func reloadWidgets() { WidgetCenter.shared.reloadAllTimelines() }
}
