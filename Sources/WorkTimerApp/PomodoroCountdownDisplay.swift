import Combine
import Foundation
import WorkTimerCore

@MainActor
final class PomodoroCountdownDisplay: ObservableObject {
    @Published private(set) var text = "00:00"
    private var source: PomodoroTimer?
    private var ticker: Timer?
    private let now: () -> Stamp

    init(now: @escaping () -> Stamp = {
        Stamp(wall: Date().millis, mono: ProcessInfo.processInfo.systemUptime)
    }) {
        self.now = now
    }

    func synchronize(with source: PomodoroTimer?) {
        self.source = source
        guard source != nil else {
            if text != "00:00" { text = "00:00" }
            stop()
            return
        }
        refresh()
        guard source?.state.status == .running, ticker == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        source = nil
    }

    private func refresh() {
        guard let source else { return }
        let remaining = max(0, source.remaining(now()))
        let seconds = remaining / WorkTimerCore.Duration.second
            + (remaining % WorkTimerCore.Duration.second == 0 ? 0 : 1)
        let value = String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
        if text != value { text = value }
        if source.state.status != .running { stop() }
    }
}
