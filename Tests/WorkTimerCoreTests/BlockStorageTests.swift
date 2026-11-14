import Foundation
import Testing
@testable import WorkTimerCore

@Suite struct BlockStorageTests {
    @Test func olderBlockAndCheckpointPayloadsDecodeWithoutAppLists() throws {
        let blockJSON = #"{"start":0,"amounts":["work",60000],"coverage":[{"start":0,"end":60000}]}"#
        let block = try JSONDecoder().decode(ActivityBlock.self, from: Data(blockJSON.utf8))
        try block.validate()
        #expect(block.apps.isEmpty)
        let intervalJSON = #"{"span":{"start":0,"end":60000},"category":"work","reason":"workWindow","source":"tracker"}"#
        let interval = try JSONDecoder().decode(ActivityInterval.self, from: Data(intervalJSON.utf8))
        #expect(interval.apps.isEmpty)
    }

    @Test func currentDatabaseReopensWithBlocksCorrectionsAndBackupNoticeIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        let span = Span(0, ActivityBlock.length)
        let ledger = try Ledger(path: path)
        try ledger.record([ActivityInterval(span: Span(0, 60_000), category: .work, reason: .workWindow, apps: ["editor.a", "editor.b"])])
        try ledger.addAdjustment(Adjustment(span: span, category: .learn, createdAt: span.end))
        try ledger.setSetting("compaction_backup", "preserved-original.sqlite")
        let original = try ledger.blocks(in: span)
        let effective = try ledger.effectiveBlocks(in: span)
        let reopened = try Ledger(path: path)
        #expect(reopened.db.userVersion == Ledger.schemaVersion)
        #expect(try reopened.blocks(in: span) == original)
        #expect(original.first?.apps == ["editor.a", "editor.b"])
        #expect(try reopened.effectiveBlocks(in: span) == effective)
        #expect(effective.first?[.learn] == 60_000)
        #expect(reopened.compactionBackup == "preserved-original.sqlite")
        #expect(try reopened.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='activity_intervals'") == 0)
        #expect(try reopened.db.integrityCheck())
    }

    @Test(arguments: [0, 1, 3])
    func unsupportedDatabaseAndRestoreLeaveExistingDataUntouched(version: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("unsupported.sqlite")
        let db = try SQLiteDB(path: source.path)
        try db.exec("CREATE TABLE preserved(value TEXT)")
        try db.exec("INSERT INTO preserved VALUES('history')")
        try db.setUserVersion(version)
        #expect(throws: SQLiteError.self) { try Ledger(path: source.path) }
        #expect(db.userVersion == version)
        #expect(try db.scalar("SELECT COUNT(*) FROM preserved") == 1)
        let ledger = try Ledger(path: directory.appendingPathComponent("current.sqlite").path)
        let span = Span(0, ActivityBlock.length)
        try ledger.record([ActivityInterval(span: span, category: .privateTime, reason: .outsideHoursPrivate)])
        let before = try ledger.blocks(in: span)
        let manager = BackupManager(ledger: ledger, location: DatabaseLocation(directory: directory))
        #expect(throws: BackupError.self) { try manager.restore(from: source) }
        #expect(try ledger.blocks(in: span) == before)
        #expect(db.userVersion == version)
        #expect(try db.scalar("SELECT COUNT(*) FROM preserved") == 1)
    }

    @Test func currentBackupRestoresBlocksAndUndoableCorrections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try Ledger(path: directory.appendingPathComponent("history.sqlite").path)
        let span = Span(0, ActivityBlock.length)
        try ledger.record([ActivityInterval(span: Span(0, 60_000), category: .work, reason: .workWindow, apps: ["editor.a"])])
        let correction = try ledger.addAdjustment(Adjustment(span: span, category: .learn, createdAt: span.end))
        let original = try ledger.effectiveBlocks(in: span)
        let manager = BackupManager(ledger: ledger, location: DatabaseLocation(directory: directory))
        let backup = directory.appendingPathComponent("blocks.sqlite")
        try manager.createBackup(to: backup)
        #expect(try manager.inspect(backup).intervalCount == 1)
        try ledger.deleteAllHistory()
        try manager.restore(from: backup)
        #expect(try ledger.effectiveBlocks(in: span) == original)
        #expect(original.first?.apps == ["editor.a"])
        try ledger.undoAdjustment(id: correction, at: span.end + 1)
        #expect(try ledger.effectiveBlocks(in: span).first?[.work] == 60_000)
    }
}
