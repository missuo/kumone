import Foundation
import SQLite3

/// Used exclusively on OfflineStore's actor. The payload is versioned by the
/// database schema; indexed identity fields keep local playback lookups small.
final class OfflineAudioDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open offline index"
            sqlite3_close(handle)
            handle = nil
            throw OfflineAudioError.database(message)
        }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        let version = try statement("PRAGMA user_version") { statement -> Int32 in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
            return sqlite3_column_int(statement, 0)
        }
        guard version <= 1 else { throw OfflineAudioError.database("Unsupported offline index version") }
        try execute("CREATE TABLE IF NOT EXISTS assets (id TEXT PRIMARY KEY, scope TEXT NOT NULL, track_id INTEGER NOT NULL, payload BLOB NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS assets_track ON assets(scope, track_id)")
        try execute("PRAGMA user_version=1")
    }

    deinit { sqlite3_close(handle) }

    func save(_ record: OfflineAudioRecord) throws {
        let data = try JSONEncoder().encode(record)
        try statement("INSERT INTO assets VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload") { stmt in
            try bind(record.id, to: stmt, at: 1)
            try bind(record.descriptor.identity.accountScope, to: stmt, at: 2)
            guard sqlite3_bind_int64(stmt, 3, Int64(record.descriptor.identity.trackID)) == SQLITE_OK else { throw failure() }
            let result = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32($0.count), transient) }
            guard result == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        }
    }

    func record(id: String) throws -> OfflineAudioRecord? {
        try records(sql: "SELECT payload FROM assets WHERE id=?", values: [id]).first
    }

    func records(scope: String, trackID: Int) throws -> [OfflineAudioRecord] {
        try records(sql: "SELECT payload FROM assets WHERE scope=? AND track_id=?", values: [scope, String(trackID)])
    }

    func allRecords() throws -> [OfflineAudioRecord] {
        try records(sql: "SELECT payload FROM assets", values: [])
    }

    func remove(id: String) throws {
        try statement("DELETE FROM assets WHERE id=?") { stmt in
            try bind(id, to: stmt, at: 1)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func records(sql: String, values: [String]) throws -> [OfflineAudioRecord] {
        try statement(sql) { stmt in
            for (index, value) in values.enumerated() { try bind(value, to: stmt, at: Int32(index + 1)) }
            var rows: [OfflineAudioRecord] = []
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw failure() }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
                rows.append(try JSONDecoder().decode(OfflineAudioRecord.self, from: data))
            }
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func bind(_ text: String, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else { throw failure() }
    }

    private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw failure() }
        defer { sqlite3_finalize(pointer) }
        return try body(pointer)
    }

    private func failure() -> OfflineAudioError {
        .database(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Offline index is closed")
    }
}
