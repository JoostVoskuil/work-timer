import Foundation

public enum PomodoroPhase: String, Codable { case focus, shortBreak, longBreak
    public var isBreak: Bool { self != .focus }
}
public enum PomodoroStatus: String, Codable { case stopped, running, paused, waiting }

public struct PomodoroSettings: Equatable, Codable {
    public var focusMinutes = 25
    public var shortBreakMinutes = 5
    public var longBreakMinutes = 15
    public var focusPhasesPerCycle = 4
    public init() {}
    func planned(_ p: PomodoroPhase) -> Millis {
        Millis(p == .focus ? focusMinutes : p == .shortBreak ? shortBreakMinutes : longBreakMinutes) * Duration.minute
    }
}

public struct PomodoroState: Codable, Equatable {
    public var phase: PomodoroPhase = .focus
    public var status: PomodoroStatus = .stopped
    public var completedFocus = 0
    public var plannedMs: Millis = 0
    /// Remaining time as of the last resume/persist; while running, elapsed monotonic time is subtracted.
    public var remainingMs: Millis = 0
    /// Wall-clock deadline persisted while running (informational; recovery never trusts it).
    public var deadline: Millis?
    public var recordID: Int64?
    public init() {}
}

public enum PomodoroEvent: Equatable {
    case focusCompleted(offerBreak: PomodoroPhase)
    case breakCompleted
}

/// Break-aware Pomodoro. Phases start manually. Running time is measured with a monotonic clock, not tick counting.
public final class PomodoroTimer {
    public private(set) var state: PomodoroState
    public var settings: PomodoroSettings
    private let ledger: Ledger
    private var anchorMono: Double = 0

    public init(ledger: Ledger, settings: PomodoroSettings = PomodoroSettings()) {
        self.ledger = ledger
        self.settings = settings
        if let json = ledger.getSetting("pomodoro_state"), let s = try? JSONDecoder().decode(PomodoroState.self, from: Data(json.utf8)) {
            state = s
        } else { state = PomodoroState() }
    }

    /// After a restart a running phase becomes paused with the last persisted remaining time:
    /// unobserved time is never credited as completed focus.
    public func recover(at wall: Millis) {
        if state.status == .running {
            state.status = .paused
            state.deadline = nil
            persist()
        }
    }

    /// Breaks (running, paused, or elapsed and waiting) are excluded from work.
    public var isBreakActive: Bool { state.phase.isBreak && state.status != .stopped }

    public var nextBreak: PomodoroPhase { state.completedFocus >= settings.focusPhasesPerCycle ? .longBreak : .shortBreak }

    public func remaining(_ s: Stamp) -> Millis {
        guard state.status == .running else { return state.status == .waiting ? 0 : state.remainingMs }
        return max(0, state.remainingMs - Millis((s.mono - anchorMono) * 1000))
    }

    /// Fire time for a phase-end notification, or nil if nothing is running. Reschedule/cancel on every change.
    public func scheduledDeadline(_ s: Stamp) -> Millis? {
        state.status == .running ? s.wall + remaining(s) : nil
    }

    public func startFocus(_ s: Stamp) { begin(.focus, s) }
    public func startBreak(_ s: Stamp) { begin(nextBreak, s) }

    private func begin(_ p: PomodoroPhase, _ s: Stamp) {
        finishRecord("cancelled", s)
        state.phase = p
        state.plannedMs = settings.planned(p)
        state.remainingMs = state.plannedMs
        state.status = .running
        state.deadline = s.wall + state.plannedMs
        anchorMono = s.mono
        state.recordID = try? ledger.startPomodoroRecord(phase: p.rawValue, plannedMs: state.plannedMs, at: s.wall)
        persist()
    }

    public func pause(_ s: Stamp) {
        guard state.status == .running else { return }
        state.remainingMs = remaining(s)
        state.status = .paused
        state.deadline = nil
        persist()
    }

    public func resume(_ s: Stamp) {
        guard state.status == .paused else { return }
        anchorMono = s.mono
        state.status = .running
        state.deadline = s.wall + state.remainingMs
        persist()
    }

    /// Sleep/lock pause the phase; waking requires an explicit resume.
    public func autoPause(_ s: Stamp) { pause(s) }

    /// Cancels or skips the phase. An unfinished focus is never counted as completed; ending a break returns to stopped.
    public func skipOrEnd(_ s: Stamp) {
        guard state.status != .stopped else { return }
        finishRecord(state.status == .waiting ? "completed" : "skipped", s)
        state.status = .stopped
        state.remainingMs = 0
        state.deadline = nil
        persist()
    }

    /// Detects phase completion from the monotonic clock. Call from the tick.
    @discardableResult
    public func tick(_ s: Stamp) -> PomodoroEvent? {
        guard state.status == .running, remaining(s) <= 0 else { return nil }
        finishRecord("completed", s)
        state.status = .waiting
        state.remainingMs = 0
        state.deadline = nil
        if state.phase == .focus {
            state.completedFocus += 1
            persist()
            return .focusCompleted(offerBreak: nextBreak)
        }
        if state.phase == .longBreak { state.completedFocus = 0 }
        persist()
        return .breakCompleted
    }

    private func finishRecord(_ outcome: String, _ s: Stamp) {
        if let id = state.recordID { try? ledger.endPomodoroRecord(id: id, outcome: outcome, at: s.wall) }
        state.recordID = nil
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(state), let s = String(data: d, encoding: .utf8) { try? ledger.setSetting("pomodoro_state", s) }
    }

    /// Periodic snapshot of the remaining time so recovery after a crash is bounded.
    public func persistProgress(_ s: Stamp) {
        guard state.status == .running else { return }
        var copy = state
        copy.remainingMs = remaining(s)
        if let d = try? JSONEncoder().encode(copy), let str = String(data: d, encoding: .utf8) { try? ledger.setSetting("pomodoro_state", str) }
    }
}
