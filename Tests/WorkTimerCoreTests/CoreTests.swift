import Testing
import Foundation
@testable import WorkTimerCore

final class Recorder: UpdateSteps {
    var calls: [String] = []
    var failPublication = false
    func republishWidgetSnapshot() throws {
        calls.append("publish")
        if failPublication { throw NSError(domain: "t", code: 1) }
    }
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

    @Test func singleInstanceLockRejectsDuplicateAndCanBeReacquired() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("worktimer.lock")
        var first: SingleInstanceLock? = try SingleInstanceLock(at: url)
        #expect(throws: SingleInstanceError.self) { try SingleInstanceLock(at: url) }
        withExtendedLifetime(first) {}
        first = nil
        let next = try SingleInstanceLock(at: url)
        withExtendedLifetime(next) {
            #expect(throws: SingleInstanceError.self) { try SingleInstanceLock(at: url) }
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func singleInstanceLockSurfacesFileErrors() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("worktimer.lock")
        #expect(throws: (any Error).self) { try SingleInstanceLock(at: missing) }
    }

    @Test func testUpdatePublishesAndReloadsWithoutMigration() throws {
        let r = Recorder()
        let c = PostUpdateCoordinator(defaults: defaults(), steps: r)
        #expect(try c.runOnLaunch(currentVersion: "1.1"))
        #expect(r.calls == ["publish", "reload"])
        r.calls = []
        #expect(try !c.runOnLaunch(currentVersion: "1.1"))
        #expect(r.calls == ["publish", "reload"])
    }

    @Test func testFailedPublicationIsRetried() {
        let r = Recorder(); r.failPublication = true
        let c = PostUpdateCoordinator(defaults: defaults(), steps: r)
        #expect(throws: (any Error).self) { try c.runOnLaunch(currentVersion: "2.0") }
        r.failPublication = false
        #expect((try? c.runOnLaunch(currentVersion: "2.0")) ?? false)
    }
}
