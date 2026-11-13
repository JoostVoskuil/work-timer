import Foundation

public protocol UpdateSteps {
    /// Backs up the database, then runs migrations. Must preserve data on failure.
    func backupAndMigrate() throws
    func republishWidgetSnapshot() throws
    func reloadWidgets()
}

/// Migrates once per bundle-version change; republishes and reloads widgets on every launch.
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
        if updated { try steps.backupAndMigrate() }
        try steps.republishWidgetSnapshot()
        steps.reloadWidgets()
        // Recorded last so a failed migration is retried on next launch.
        if updated { defaults.set(currentVersion, forKey: Self.key) }
        return updated
    }
}
