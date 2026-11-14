import Foundation
import SQLite3

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String), prepare(String), step(String), constraint(String), invalid(String)
    public var description: String {
        switch self {
        case .open(let m), .prepare(let m), .step(let m), .constraint(let m), .invalid(let m): return m
        }
    }
}

public enum SQLValue {
    case int(Int64), text(String), null
    public init(_ v: Int64?) { self = v.map { .int($0) } ?? .null }
    public init(_ v: String?) { self = v.map { .text($0) } ?? .null }
}

public struct Row {
    let stmt: OpaquePointer
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func optInt(_ i: Int32) -> Int64? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : int(i) }
    public func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
    public func optText(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : text(i) }
}

/// Minimal serialized SQLite connection (WAL, busy timeout, transactions, backup API).
public final class SQLiteDB {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var txDepth = 0
    public let path: String

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError.open(m)
        }
        sqlite3_busy_timeout(db, 5_000)
        if !readOnly {
            try exec("PRAGMA foreign_keys = ON")
            if path != ":memory:" { try exec("PRAGMA journal_mode = WAL") }
        }
    }

    deinit { sqlite3_close(db) }

    private var message: String { String(cString: sqlite3_errmsg(db)) }

    public func exec(_ sql: String, _ args: [SQLValue] = []) throws {
        try withLock {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, args)
            try stepDone(stmt)
        }
    }

    public func query<T>(_ sql: String, _ args: [SQLValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        try withLock {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, args)
            var out: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW { out.append(try map(Row(stmt: stmt))) }
                else if rc == SQLITE_DONE { break }
                else { throw SQLiteError.step(message) }
            }
            return out
        }
    }

    public func scalar(_ sql: String, _ args: [SQLValue] = []) throws -> Int64? {
        try query(sql, args) { $0.optInt(0) }.first ?? nil
    }

    public var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }
    public var changes: Int { Int(sqlite3_changes(db)) }

    /// Runs `body` in a transaction (nesting joins the outer one). Rolls back on error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try withLock {
            if txDepth > 0 { return try body() }
            try exec("BEGIN IMMEDIATE")
            txDepth = 1
            defer { txDepth = 0 }
            do {
                let r = try body()
                try exec("COMMIT")
                return r
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    public var userVersion: Int {
        get { Int((try? scalar("PRAGMA user_version")) ?? 0) }
    }

    public func setUserVersion(_ v: Int) throws { try exec("PRAGMA user_version = \(v)") }

    /// Consistent online backup through SQLite's backup API (safe with WAL).
    public func backup(to destination: String) throws {
        try withLock {
            let dest = try SQLiteDB(path: destination)
            guard let b = sqlite3_backup_init(dest.db, "main", db, "main") else { throw SQLiteError.step(dest.message) }
            let rc = sqlite3_backup_step(b, -1)
            sqlite3_backup_finish(b)
            guard rc == SQLITE_DONE else { throw SQLiteError.step("backup failed (\(rc))") }
        }
    }

    /// Replaces this database's contents with `source` through the backup API (works with an open WAL connection).
    public func restore(from source: String) throws {
        try withLock {
            let src = try SQLiteDB(path: source, readOnly: true)
            guard let b = sqlite3_backup_init(db, "main", src.db, "main") else { throw SQLiteError.step(message) }
            let rc = sqlite3_backup_step(b, -1)
            sqlite3_backup_finish(b)
            guard rc == SQLITE_DONE else { throw SQLiteError.step("restore failed (\(rc))") }
        }
    }

    public func integrityCheck() throws -> Bool {
        try query("PRAGMA integrity_check") { $0.text(0) }.first == "ok"
    }

    public func checkpoint() { try? exec("PRAGMA wal_checkpoint(TRUNCATE)") }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SQLiteError.prepare("\(message) in: \(sql)")
        }
        return s
    }

    private func bind(_ stmt: OpaquePointer, _ args: [SQLValue]) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE || rc == SQLITE_ROW { return }
        if rc == SQLITE_CONSTRAINT { throw SQLiteError.constraint(message) }
        throw SQLiteError.step(message)
    }
}
