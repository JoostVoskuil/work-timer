import SwiftUI
import OSLog

@MainActor
func setDockIconVisible(_ visible: Bool) {
    let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
    guard NSApp.activationPolicy() != policy else { return }
    if !NSApp.setActivationPolicy(policy) {
        Logger(subsystem: "nl.foxhole.worktimer", category: "Lifecycle")
            .error("Could not change Dock visibility to \(visible)")
    }
}

private struct DockWindowVisibility: NSViewRepresentable {
    func makeNSView(context: Context) -> DockWindowView { DockWindowView() }
    func updateNSView(_ nsView: DockWindowView, context: Context) {}
    static func dismantleNSView(_ nsView: DockWindowView, coordinator: ()) {
        nsView.stopObserving()
    }
}

// SwiftUI can retain a closed window's view, so follow native window events.
private final class DockWindowView: NSView {
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { setDockIconVisible(true) }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { setDockIconVisible(false) }
            }
        ]
        if window.isVisible { setDockIconVisible(true) }
    }

    func stopObserving() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}

struct MenuWindowVisibility: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> MenuPopupView {
        MenuPopupView { visible in
            Task { @MainActor in model.setMenuVisible(visible) }
        }
    }

    func updateNSView(_ nsView: MenuPopupView, context: Context) {}

    static func dismantleNSView(_ nsView: MenuPopupView, coordinator: ()) {
        nsView.stopObserving()
        nsView.reportClosed()
    }
}

final class MenuPopupView: NSView {
    private let visibilityChanged: (Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    private var wasVisible = false

    init(visibilityChanged: @escaping (Bool) -> Void) {
        self.visibilityChanged = visibilityChanged
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { reportClosed(); return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.wasVisible = true
                    self?.visibilityChanged(true)
                }
            },
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportClosed() }
            }
        ]
        if window.isVisible {
            wasVisible = true
            visibilityChanged(true)
        }
    }

    private func updateVisibility() {
        let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        guard visible != wasVisible else { return }
        wasVisible = visible
        visibilityChanged(visible)
    }

    func reportClosed() {
        wasVisible = false
        visibilityChanged(false)
    }

    func stopObserving() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}

@main
struct WorkTimerApp: App {
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("WorkTimer", id: "main") {
            MainView(model: model)
                .background(DockWindowVisibility().frame(width: 0, height: 0))
        }
        .handlesExternalEvents(matching: ["main"])
        .defaultSize(width: 1000, height: 740)
        .windowToolbarStyle(.unified)
    }

    init() {
        // Start tracking at launch, not when the menu is first opened.
        DispatchQueue.main.async { AppModel.shared.start() }
    }
}
