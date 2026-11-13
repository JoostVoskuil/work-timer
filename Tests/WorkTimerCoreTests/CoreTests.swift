import Testing
import Foundation
@testable import WorkTimerCore

final class Recorder: UpdateSteps {
    var calls: [String] = []
    var failMigration = false
    func backupAndMigrate() throws {
        calls.append("migrate")
        if failMigration { throw NSError(domain: "t", code: 1) }
    }
    func republishWidgetSnapshot() throws { calls.append("publish") }
    func reloadWidgets() { calls.append("reload") }
}

@Suite struct CoreTests {
    func defaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func testDatabaseInUserProfile() throws {
        let loc = try DatabaseLocation.userProfile(appName: "WorkTimerTest")
        #expect(loc.databaseURL.path.contains("/Library/Application Support/WorkTimerTest/"))
    }

    @Test func testPrepareCreatesPrivateDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try DatabaseLocation(directory: dir).prepare()
        let perms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }

    @Test func testUpdateMigratesAndReloadsOnce() throws {
        let r = Recorder()
        let c = PostUpdateCoordinator(defaults: defaults(), steps: r)
        #expect(try c.runOnLaunch(currentVersion: "1.1"))
        #expect(r.calls == ["migrate", "publish", "reload"])
        r.calls = []
        #expect(try !c.runOnLaunch(currentVersion: "1.1"))
        #expect(r.calls == ["publish", "reload"])
    }

    @Test func testFailedMigrationIsRetried() {
        let r = Recorder(); r.failMigration = true
        let c = PostUpdateCoordinator(defaults: defaults(), steps: r)
        #expect(throws: (any Error).self) { try c.runOnLaunch(currentVersion: "2.0") }
        r.failMigration = false
        #expect((try? c.runOnLaunch(currentVersion: "2.0")) ?? false)
    }
}
