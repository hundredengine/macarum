import Foundation
import SQLite3

/// SQLITE_TRANSIENT: makes SQLite copy bound bytes before the call returns.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// A small wrapper over the system SQLite. Not thread safe: owned by one actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw SQLiteError(code: rc, message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw lastError(rc) }
        return Statement(stmt: stmt, db: self)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    fileprivate func lastError(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }
}

final class Statement {
    private let stmt: OpaquePointer
    private unowned let db: SQLiteDatabase

    fileprivate init(stmt: OpaquePointer, db: SQLiteDatabase) {
        self.stmt = stmt
        self.db = db
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case null
    }

    @discardableResult
    func bind(_ values: [Value]) -> Statement {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(stmt, index, v)
            case .double(let v): sqlite3_bind_double(stmt, index, v)
            case .text(let v): sqlite3_bind_text(stmt, index, v, -1, transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: sqlite3_bind_null(stmt, index)
            }
        }
        return self
    }

    /// Runs a statement that returns no rows.
    func run(_ values: [Value] = []) throws {
        bind(values)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw db.lastError(rc) }
    }

    /// Steps through result rows.
    func rows(_ values: [Value] = [], _ each: (Row) throws -> Void) throws {
        bind(values)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw db.lastError(rc) }
            try each(Row(stmt: stmt))
        }
    }
}

struct Row {
    let stmt: OpaquePointer

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }

    func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    func blob(_ i: Int32) -> Data? {
        guard !isNull(i) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, i))
        guard count > 0, let bytes = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
