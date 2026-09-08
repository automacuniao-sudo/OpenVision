import Foundation
import SQLite3

enum BrainDatabaseLocation: Sendable {
    case applicationSupport
    case file(URL)
    case inMemory
}

enum BrainStoreError: Error, Equatable {
    case openFailed(String)
    case sqlite(code: Int32, message: String)
    case migrationUnsupported(found: Int32, supported: Int32)
    case invalidData(String)
    case notFound
    case notInitialized
    case initializationFailed
}

enum SQLiteBinding: Sendable {
    case text(String)
    case double(Double)
    case int64(Int64)
    case null
}

final class BrainDatabase {
    private var connection: OpaquePointer?

    init(location: BrainDatabaseLocation) throws {
        let path = try Self.databasePath(for: location)
        var openedConnection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openCode = sqlite3_open_v2(path, &openedConnection, flags, nil)

        guard openCode == SQLITE_OK, let openedConnection else {
            let message: String
            if let openedConnection, let error = sqlite3_errmsg(openedConnection) {
                message = String(cString: error)
                sqlite3_close_v2(openedConnection)
            } else {
                message = "Unable to open SQLite database"
            }
            throw BrainStoreError.openFailed(message)
        }

        connection = openedConnection

        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA busy_timeout = 5000")
            try execute("PRAGMA journal_mode = WAL")
        } catch {
            sqlite3_close_v2(openedConnection)
            connection = nil
            throw error
        }
    }

    deinit {
        if let connection {
            sqlite3_close_v2(connection)
        }
    }

    func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        while true {
            let stepCode = sqlite3_step(statement)
            switch stepCode {
            case SQLITE_ROW:
                continue
            case SQLITE_DONE:
                return
            default:
                throw sqliteError(code: stepCode)
            }
        }
    }

    func scalarInt(_ sql: String, bindings: [SQLiteBinding] = []) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        let stepCode = sqlite3_step(statement)
        guard stepCode == SQLITE_ROW else {
            if stepCode == SQLITE_DONE {
                throw BrainStoreError.invalidData("Expected SQLite scalar row")
            }
            throw sqliteError(code: stepCode)
        }

        return sqlite3_column_int64(statement, 0)
    }

    func userVersion() throws -> Int32 {
        Int32(try scalarInt("PRAGMA user_version"))
    }

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

    private static func databasePath(for location: BrainDatabaseLocation) throws -> String {
        switch location {
        case .inMemory:
            return ":memory:"

        case .file(let url):
            return url.path

        case .applicationSupport:
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = support.appendingPathComponent("JARVISBrain", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )
            return directory.appendingPathComponent("JARVIS-Brain.sqlite").path
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let connection else {
            throw BrainStoreError.notInitialized
        }

        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw sqliteError(code: prepareCode)
        }
        return statement
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let bindCode: Int32

            switch binding {
            case .text(let value):
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                bindCode = value.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, -1, transient)
                }
            case .double(let value):
                bindCode = sqlite3_bind_double(statement, index, value)
            case .int64(let value):
                bindCode = sqlite3_bind_int64(statement, index, value)
            case .null:
                bindCode = sqlite3_bind_null(statement, index)
            }

            guard bindCode == SQLITE_OK else {
                throw sqliteError(code: bindCode)
            }
        }
    }

    private func sqliteError(code: Int32) -> BrainStoreError {
        guard let connection, let error = sqlite3_errmsg(connection) else {
            return .sqlite(code: code, message: "SQLite error")
        }
        return .sqlite(code: code, message: String(cString: error))
    }
}
