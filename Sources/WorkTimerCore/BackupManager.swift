import Foundation

public struct BackupInfo: Equatable {
    public var schemaVersion: Int
    public var intervalCount: Int
    public var firstStart: Millis?
    public var lastEnd: Millis?
}

public enum BackupError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { if case .invalid(let m) = self { return m }; return "" }
}

/// Backup, validated restore and deletion helpers. Backups are plain SQLite files and are NOT encrypted by the app.
public struct BackupManager {
    public let ledger: Ledger
    public let location: DatabaseLocation
    public init(ledger: Ledger, location: DatabaseLocation) { self.ledger = ledger; self.location = location }

    @discardableResult
    public func createBackup(to destination: URL) throws -> URL {
        try? FileManager.default.removeItem(at: destination)
        try ledger.db.backup(to: destination.path)
        return destination
    }

    /// Validates a backup without touching live data.
    public func inspect(_ url: URL) throws -> BackupInfo {
        guard FileManager.default.fileExists(atPath: url.path) else { throw BackupError.invalid("File not found") }
        let db: SQLiteDB
        do { db = try SQLiteDB(path: url.path, readOnly: true) } catch { throw BackupError.invalid("Not a readable SQLite file") }
        guard (try? db.integrityCheck()) == true else { throw BackupError.invalid("Integrity check failed") }
        let v = db.userVersion
        guard v == Ledger.schemaVersion else {
            throw BackupError.invalid("Unsupported backup schema \(v). Only current-format block backups can be restored; legacy backups must first be converted with the earlier WorkTimer version.")
        }
        let count = Int(try db.scalar("SELECT COUNT(*) FROM activity_blocks") ?? 0)
        return BackupInfo(schemaVersion: v, intervalCount: count,
                          firstStart: try db.scalar("SELECT MIN(start_ms) FROM activity_blocks"),
                          lastEnd: try db.scalar("SELECT MAX(end_ms) FROM activity_blocks"))
    }

    /// Validate a scratch copy, preserve the current database, then replace it. No format conversion is performed.
    /// The caller must suspend ingestion first and rebuild summaries afterwards.
    public func restore(from url: URL, now: Date = Date()) throws {
        _ = try inspect(url)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: scratch.path + suffix) } }
        let src = try SQLiteDB(path: url.path, readOnly: true)
        try src.backup(to: scratch.path)
        do { _ = try Ledger(path: scratch.path) } catch { throw BackupError.invalid("Backup validation failed: \(error)") }

        try FileManager.default.createDirectory(at: location.backupsDirectory, withIntermediateDirectories: true)
        let stamp = Int(now.timeIntervalSince1970)
        try ledger.db.backup(to: location.backupsDirectory.appendingPathComponent("pre-restore-\(stamp).sqlite").path)
        try ledger.db.restore(from: scratch.path)
    }
}
