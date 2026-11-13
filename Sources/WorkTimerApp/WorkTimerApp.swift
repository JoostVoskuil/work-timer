import SwiftUI

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
        }
        .handlesExternalEvents(matching: ["main"])
    }

    init() {
        // Start tracking at launch, not when the menu is first opened.
        DispatchQueue.main.async { AppModel.shared.start() }
    }
}
