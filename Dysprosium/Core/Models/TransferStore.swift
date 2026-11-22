import Darwin
import Foundation
import SQLite3
import UIKit

/// Crash-safe SQLite3 WAL journal persisting transfer jobs and byte-range progress bitmaps.
/// Hardened against iOS `0xdead10cc` via inode-tracked `com.apple.runningboard.can-suspend-locked`
/// xattr stamping and background `SQLITE_CHECKPOINT_TRUNCATE` flushes.
public actor TransferStore {
    nonisolated(unsafe) private let db: OpaquePointer?
    nonisolated(unsafe) private var upsertStmt: OpaquePointer?
    nonisolated(unsafe) private var lifecycleObserverTokens: [NSObjectProtocol] = []
    private let databaseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var protectedInodes: [String: UInt64] = [:]

    public init(databaseURL: URL = LiveContainerEnvironment.stateDatabaseURL) throws {
        self.databaseURL = databaseURL
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = dec

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "Dysprosium.TransferStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        self.db = handle

        Self.exec(handle, sql: "PRAGMA journal_mode = WAL;")
        Self.exec(handle, sql: "PRAGMA auto_vacuum = INCREMENTAL;")
        Self.exec(handle, sql: "PRAGMA synchronous = NORMAL;")
        Self.exec(handle, sql: "PRAGMA busy_timeout = 3000;")
        Self.exec(handle, sql: "PRAGMA journal_size_limit = 8388608;")
        Self.migrateSchemaIfNeeded(handle)

        let upsertSQL = """
            INSERT INTO transfer_jobs (id, created_at, updated_at, lifecycle, payload)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(id) DO UPDATE SET
                updated_at = excluded.updated_at,
                lifecycle = excluded.lifecycle,
                payload = excluded.payload;
            """
        var prepared: OpaquePointer?
        if sqlite3_prepare_v2(handle, upsertSQL, -1, &prepared, nil) == SQLITE_OK {
            self.upsertStmt = prepared
        }

        self.protectedInodes = Self.stampSuspendLockedAttributes(at: databaseURL.path, existingInodes: [:], force: true)
        self.lifecycleObserverTokens = Self.installLifecycleObservers(for: self)
    }

    private static func installLifecycleObservers(for store: TransferStore) -> [NSObjectProtocol] {
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification
        ]
        return names.map { name in
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak store] _ in
                guard let store else { return }
                MainActor.assumeIsolated {
                    let bgGuard = BackgroundTaskGuard(name: "Dysprosium.TransferStore.WALCheckpoint")
                    Task.detached(priority: .userInitiated) {
                        await store.flushForBackground()
                        await bgGuard.end()
                    }
                }
            }
        }
    }

    private static func migrateSchemaIfNeeded(_ db: OpaquePointer) {
        var version: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            version = sqlite3_column_int(stmt, 0)
        }
        sqlite3_finalize(stmt)

        if version < 1 {
            exec(db, sql: """
                BEGIN IMMEDIATE TRANSACTION;
                CREATE TABLE IF NOT EXISTS transfer_jobs (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    lifecycle TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_transfer_jobs_created
                    ON transfer_jobs(created_at DESC);
                PRAGMA user_version = 1;
                COMMIT;
                """)
        }
    }

    deinit {
        for token in lifecycleObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        if let upsertStmt {
            sqlite3_finalize(upsertStmt)
        }
        if let db {
            _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            sqlite3_close_v2(db)
        }
    }

    public func loadAllJobs() -> [TransferJob] {
        guard let db else { return [] }
        let sql = "SELECT payload FROM transfer_jobs ORDER BY created_at DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var jobs: [TransferJob] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let byteCount = Int(sqlite3_column_bytes(stmt, 0))
            guard byteCount > 0, let rawPtr = sqlite3_column_blob(stmt, 0) else { continue }
            let data = Data(bytes: rawPtr, count: byteCount)
            if var job = try? decoder.decode(TransferJob.self, from: data) {
                // Any job left mid-flight when LiveContainer swapped guests or terminated
                // transitions cleanly to `.paused` so its exact byte slices can resume.
                if job.lifecycle.isActive {
                    job.lifecycle = .paused
                    job.activeLanes = 0
                    job.speedBytesPerSec = 0
                    for idx in job.slices.indices {
                        job.slices[idx].isActiveLane = false
                    }
                }
                jobs.append(job)
            }
        }
        return jobs
    }

    public func upsert(_ job: TransferJob) {
        let persistedJob = (job.lifecycle == .completed) ? job.strippingAuthHeaders() : job
        guard let stmt = upsertStmt, let payload = try? encoder.encode(persistedJob) else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, persistedJob.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_double(stmt, 2, persistedJob.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, persistedJob.updatedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 4, persistedJob.lifecycle.rawValue, -1, sqliteTransient)
        _ = payload.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, 5, rawBuffer.baseAddress, Int32(rawBuffer.count), sqliteTransient)
        }
        _ = sqlite3_step(stmt)

        ensureWALSidecarProtection(force: false)
    }

    public func delete(id: UUID) {
        guard let db else { return }
        let sql = "DELETE FROM transfer_jobs WHERE id = ?1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, sqliteTransient)
        _ = sqlite3_step(stmt)
        ensureWALSidecarProtection(force: false)
    }

    /// Truncates the SQLite WAL cleanly into the main database file and re-stamps
    /// `com.apple.runningboard.can-suspend-locked` on any newly created `-wal`/`-shm` inodes.
    public func flushForBackground() {
        guard let db else { return }
        if let upsertStmt {
            sqlite3_reset(upsertStmt)
            sqlite3_clear_bindings(upsertStmt)
        }
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtection(force: true)
    }

    /// Scrubs `Cookie` and `Authorization` headers from every persisted transfer record in
    /// `dysprosium_state.sqlite3` and truncates the WAL so no plaintext tokens remain on disk.
    public func scrubStoredAuthHeaders() {
        guard let db else { return }
        var updates: [(id: String, payload: Data)] = []

        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, payload FROM transfer_jobs;", -1, &selectStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(selectStmt) }
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                guard let idC = sqlite3_column_text(selectStmt, 0) else { continue }
                let idStr = String(cString: idC)
                let byteCount = Int(sqlite3_column_bytes(selectStmt, 1))
                guard byteCount > 0, let rawPtr = sqlite3_column_blob(selectStmt, 1) else { continue }
                let data = Data(bytes: rawPtr, count: byteCount)
                guard let job = try? decoder.decode(TransferJob.self, from: data) else { continue }
                let scrubbed = job.strippingAuthHeaders()
                if scrubbed != job, let newData = try? encoder.encode(scrubbed) {
                    updates.append((idStr, newData))
                }
            }
        }

        if !updates.isEmpty {
            Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
            var updateStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE transfer_jobs SET payload = ?1 WHERE id = ?2;", -1, &updateStmt, nil) == SQLITE_OK {
                let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                for item in updates {
                    sqlite3_reset(updateStmt)
                    sqlite3_clear_bindings(updateStmt)
                    _ = item.payload.withUnsafeBytes { rawBuf in
                        sqlite3_bind_blob(updateStmt, 1, rawBuf.baseAddress, Int32(rawBuf.count), sqliteTransient)
                    }
                    sqlite3_bind_text(updateStmt, 2, item.id, -1, sqliteTransient)
                    _ = sqlite3_step(updateStmt)
                }
                sqlite3_finalize(updateStmt)
            }
            Self.exec(db, sql: "COMMIT;")
        }

        flushForBackground()
    }

    /// Reclaims deleted/scrubbed SQLite pages, compacts the database file, truncates the WAL,
    /// and re-applies `com.apple.runningboard.can-suspend-locked` xattrs.
    public func reclaimStorage() {
        guard let db else { return }
        if let upsertStmt {
            sqlite3_reset(upsertStmt)
            sqlite3_clear_bindings(upsertStmt)
        }
        Self.exec(db, sql: "PRAGMA incremental_vacuum;")
        Self.exec(db, sql: "VACUUM;")
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        Self.exec(db, sql: "PRAGMA optimize;")
        ensureWALSidecarProtection(force: true)
    }

    private func ensureWALSidecarProtection(force: Bool) {
        protectedInodes = Self.stampSuspendLockedAttributes(
            at: databaseURL.path,
            existingInodes: protectedInodes,
            force: force
        )
    }

    private static func stampSuspendLockedAttributes(
        at databasePath: String,
        existingInodes: [String: UInt64],
        force: Bool
    ) -> [String: UInt64] {
        var updated = existingInodes
        let candidates = [databasePath, databasePath + "-wal", databasePath + "-shm"]
        var flag: UInt8 = 1

        for candidate in candidates {
            var st = Darwin.stat()
            let exists = candidate.withCString { Darwin.lstat($0, &st) == 0 }
            guard exists else {
                updated.removeValue(forKey: candidate)
                continue
            }
            let inode = UInt64(st.st_ino)
            if force || updated[candidate] != inode {
                _ = candidate.withCString { cPath in
                    setxattr(cPath, "com.apple.runningboard.can-suspend-locked", &flag, MemoryLayout<UInt8>.size, 0, 0)
                }
                updated[candidate] = inode
            }
        }
        return updated
    }

    private static func exec(_ db: OpaquePointer, sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

@MainActor
private final class BackgroundTaskGuard {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.end()
                }
            } else {
                Task { @MainActor in
                    self?.end()
                }
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let id = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }
}
