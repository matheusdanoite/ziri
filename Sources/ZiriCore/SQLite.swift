import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String, Int32)
    case exec(String, String)
    case prepare(String, String)

    public var description: String {
        switch self {
        case .open(let path, let code): "não consegui abrir \(path) (código \(code))"
        case .exec(let sql, let msg): "erro executando \(sql.prefix(60))…: \(msg)"
        case .prepare(let sql, let msg): "erro preparando \(sql.prefix(60))…: \(msg)"
        }
    }
}

/// Wrapper mínimo sobre a API C do SQLite. Zero dependências externas.
public final class DB {
    let handle: OpaquePointer

    public init(path: String, readOnly: Bool = false) throws {
        var h: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            if let h { sqlite3_close_v2(h) }
            throw SQLiteError.open(path, rc)
        }
        handle = h
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    public func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.exec(sql, lastError)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(sql, lastError)
        }
        return Statement(stmt: stmt, db: self)
    }

    /// Percorre todas as linhas de uma query, chamando `body` para cada uma.
    public func query(_ sql: String, _ body: (Statement) throws -> Void) throws {
        let stmt = try prepare(sql)
        defer { stmt.finalize() }
        while try stmt.step() { try body(stmt) }
    }

    public func scalarInt(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { stmt.finalize() }
        return try stmt.step() ? stmt.int(0) : 0
    }

    public func scalarDouble(_ sql: String) throws -> Double {
        let stmt = try prepare(sql)
        defer { stmt.finalize() }
        return try stmt.step() ? stmt.double(0) : 0
    }
}

public final class Statement {
    let stmt: OpaquePointer
    unowned let db: DB

    init(stmt: OpaquePointer, db: DB) {
        self.stmt = stmt
        self.db = db
    }

    public func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.exec("step", db.lastError)
        }
    }

    public func run() throws {
        _ = try step()
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    public func finalize() { sqlite3_finalize(stmt) }

    public func bind(_ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, i) }
    }
    public func bind(_ i: Int32, _ v: Double) { sqlite3_bind_double(stmt, i, v) }
    public func bind(_ i: Int32, _ v: Int) { sqlite3_bind_int64(stmt, i, Int64(v)) }
    public func bind(_ i: Int32, _ v: Bool) { sqlite3_bind_int(stmt, i, v ? 1 : 0) }
    public func bind(_ i: Int32, _ v: Data) {
        _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
    }

    public func string(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
    public func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func bool(_ i: Int32) -> Bool { sqlite3_column_int(stmt, i) != 0 }
    public func data(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}
