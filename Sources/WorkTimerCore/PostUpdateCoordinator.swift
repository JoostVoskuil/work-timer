import Foundation

public protocol UpdateSteps {
    func republishWidgetSnapshot() throws
    func reloadWidgets()
}

/// Records bundle-version changes; republishes and reloads widgets on every launch.
public struct PostUpdateCoordinator {
    static let key = "lastRunVersion"
    let defaults: UserDefaults
    let steps: UpdateSteps

    public init(defaults: UserDefaults, steps: UpdateSteps) {
        self.defaults = defaults
        self.steps = steps
    }

    /// Returns true if an update (version change) was detected and handled.
    @discardableResult
    public func runOnLaunch(currentVersion: String) throws -> Bool {
        let updated = defaults.string(forKey: Self.key) != currentVersion
        try steps.republishWidgetSnapshot()
        steps.reloadWidgets()
        // Recorded last so failed publication is retried on next launch.
        if updated { defaults.set(currentVersion, forKey: Self.key) }
        return updated
    }
}
