import XCTest
@testable import JARVIS

final class BrainDatabaseTests: XCTestCase {
    func testInMemoryMigrationCreatesSchemaV1() throws {
        let db = try BrainDatabase(location: .inMemory)
        try BrainMigrations.migrate(db)
        XCTAssertEqual(try db.userVersion(), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='memories'"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='person_profiles'"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='learning_events'"), 1)
    }

    func testForeignKeysAreEnabled() throws {
        let db = try BrainDatabase(location: .inMemory)
        XCTAssertEqual(try db.scalarInt("PRAGMA foreign_keys"), 1)
    }

    func testMigrationIsIdempotent() throws {
        let db = try BrainDatabase(location: .inMemory)
        try BrainMigrations.migrate(db)
        try BrainMigrations.migrate(db)
        XCTAssertEqual(try db.userVersion(), 1)
    }
}
