import Foundation

/// Resolves the canonical database location inside the user's profile
/// (~/Library/Application Support/<appName>/worktimer.sqlite).
public struct DatabaseLocation {
    public let directory: URL
    public var databaseURL: URL { directory.appendingPathComponent("worktimer.sqlite") }
    public var backupsDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }

    public init(directory: URL) { self.directory = directory }

    public static func userProfile(appName: String = "WorkTimer", fileManager: FileManager = .default) throws -> DatabaseLocation {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        return DatabaseLocation(directory: base.appendingPathComponent(appName, isDirectory: true))
    }

    /// Creates the directory with user-only permissions.
    public func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }
}
