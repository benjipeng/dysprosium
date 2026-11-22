import Darwin
import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct BrowserHistoryDaySummary: Identifiable, Equatable, Sendable {
    /// Timezone-immune calendar key `YYYYMMDD` (e.g. `20261118`).
    public let dayYMD: Int64
    public let dayStart: Date
    public let displayTitle: String
    public let chipTitle: String
    public let count: Int

    public var id: Int64 { dayYMD }
}

public struct PersistedOpenTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var urlString: String
    public var title: String
    public var sortOrder: Double
    public var isActive: Bool

    public init(id: UUID, urlString: String, title: String, sortOrder: Double, isActive: Bool) {
        self.id = id
        self.urlString = urlString
        self.title = title
        self.sortOrder = sortOrder
        self.isActive = isActive
    }
}

public struct SiteRuleRecord: Equatable, Sendable {
    public static let minPageZoom: Double = 0.5
    public static let maxPageZoom: Double = 2.0

    public let host: String
    /// `0 = inherit`, `1 = force on`, `-1 = force off`
    public var shieldMode: Int
    /// `0 = inherit`, `1 = force dark`, `-1 = force light`
    public var darkMode: Int
    /// `0 = inherit`, `1 = iosSafari`, `2 = macosSafari`
    public var uaMode: Int
    /// `nil = inherit (1.0)`, otherwise clamped to `0.5...2.0`
    public var pageZoom: Double?

    public init(
        host: String,
        shieldMode: Int = 0,
        darkMode: Int = 0,
        uaMode: Int = 0,
        pageZoom: Double? = nil
    ) {
        self.host = host
        self.shieldMode = shieldMode
        self.darkMode = darkMode
        self.uaMode = uaMode
        self.pageZoom = pageZoom.map { Self.clampedZoom($0) }
    }

    public static func clampedZoom(_ raw: Double) -> Double {
        min(maxPageZoom, max(minPageZoom, raw))
    }

    public var isAllDefault: Bool {
        shieldMode == 0 && darkMode == 0 && uaMode == 0 && pageZoom == nil
    }
}

/// Unified Safari `History.db` / Firefox `places.sqlite`-architecture relational storage engine (`browser.sqlite3`).
/// - Governed by transactional `PRAGMA user_version` migrations (`currentSchemaVersion = 3`).
/// - Normalizes `places` (canonical URL dictionary + `visit_count` frecency) and `history_visits` (~24 bytes/visit).
/// - Uses Apple `libsqlite3` native `FTS5(tokenize='trigram case_sensitive 0')` external-content index (`0` duplicate string bloat).
/// - Stores hierarchical `favorite_folders`, `favorites` (`FOREIGN KEY` + `sort_order REAL`), `open_tabs`, and `site_rules`.
public final class BrowserSQLiteStore: @unchecked Sendable {
    public static let currentSchemaVersion: Int32 = 3
    public static let maxRetainedVisits = 50_000

    private struct FavoritesBackupSnapshot: Codable {
        let folders: [BrowserFavoriteFolder]
        let bookmarks: [BrowserBookmark]
    }

    private let lock = NSLock()
    private var db: OpaquePointer?
    private let stateDirectory: URL
    private let databasePath: String
    private let favoritesBackupURL: URL
    private var didRunBootstrapMaintenance: Bool = false
    private var protectedWALInode: UInt64?
    private var protectedSHMInode: UInt64?
    private var insertCounter: Int = 0

    private static let dayHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    private static let dayChipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    public init(stateDirectory: URL, deferOpen: Bool = false) {
        self.stateDirectory = stateDirectory
        let databaseURL = stateDirectory.appendingPathComponent("browser.sqlite3")
        self.databasePath = databaseURL.path
        self.favoritesBackupURL = stateDirectory.appendingPathComponent("favorites_backup.json")

        if !deferOpen {
            lock.lock()
            _ = ensureOpenLocked()
            lock.unlock()
            performDeferredBootstrapIfNeeded()
        }
    }

    deinit {
        lock.lock()
        if let db {
            _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            sqlite3_close_v2(db)
            self.db = nil
        }
        lock.unlock()
    }

    /// Runs legacy JSON/SQLite ingestion, backup-mirror recovery, and initial WAL flush once.
    /// Safe to invoke from a background utility/userInitiated task so cold launch never stalls `@MainActor`.
    public func performDeferredBootstrapIfNeeded() {
        lock.lock()
        let shouldRun = !didRunBootstrapMaintenance
        if shouldRun {
            didRunBootstrapMaintenance = true
            _ = ensureOpenLocked()
        }
        lock.unlock()
        guard shouldRun else { return }

        ingestLegacyStateIfNeeded(in: stateDirectory)
        restoreFavoritesFromBackupMirrorIfDatabaseEmpty()
        flushForBackground()
    }

    private func ensureOpenLocked() -> OpaquePointer? {
        if let db {
            return db
        }
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &handle, flags, nil) == SQLITE_OK, let handle else {
            return nil
        }
        self.db = handle
        Self.exec(handle, sql: "PRAGMA auto_vacuum = INCREMENTAL;")
        Self.exec(handle, sql: "PRAGMA journal_mode = WAL;")
        Self.exec(handle, sql: "PRAGMA synchronous = FULL;")
        Self.exec(handle, sql: "PRAGMA busy_timeout = 3000;")
        Self.exec(handle, sql: "PRAGMA journal_size_limit = 8388608;")
        Self.exec(handle, sql: "PRAGMA foreign_keys = ON;")
        Self.exec(handle, sql: "PRAGMA temp_store = MEMORY;")

        Self.migrateSchemaIfNeeded(handle)

        var mutableURL = URL(fileURLWithPath: databasePath)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(rv)
        ensureWALSidecarProtectionLocked(force: true)
        return handle
    }

    /// Flushes WAL frames cleanly into `browser.sqlite3` so abrupt termination (`SIGKILL` / LiveContainer swap)
    /// can never lose favorites, folders, tabs, or recent history.
    public func flushForBackground() {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
    }

    /// Physically reclaims freed pages (`VACUUM` or `PRAGMA incremental_vacuum`), truncates the WAL file,
    /// runs `PRAGMA optimize`, and re-applies `com.apple.runningboard.can-suspend-locked` on any sidecars.
    public func reclaimStorage(fullVacuum: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        if fullVacuum {
            Self.exec(db, sql: "PRAGMA auto_vacuum = INCREMENTAL;")
            Self.exec(db, sql: "VACUUM;")
        } else {
            Self.exec(db, sql: "PRAGMA incremental_vacuum;")
        }
        Self.exec(db, sql: "PRAGMA optimize;")
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
    }

    /// Returns exact bytes consumed on disk by `browser.sqlite3` plus its `-wal` and `-shm` sidecars.
    public func databaseDiskUsageBytes() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let paths = [databasePath, databasePath + "-wal", databasePath + "-shm"]
        return paths.reduce(0) { $0 &+ Self.fileSizeBytes(at: $1) }
    }

    /// Returns SQLite's `PRAGMA data_version`, which increments whenever another process (e.g., LC 1 vs LC 2)
    /// modifies the shared `browser.sqlite3` database.
    public func dataVersion() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "PRAGMA data_version;", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return 0
    }

    private func ensureWALSidecarProtectionLocked(force: Bool = false) {
        let walPath = databasePath + "-wal"
        let shmPath = databasePath + "-shm"
        let walInode = Self.fileInode(at: walPath)
        let shmInode = Self.fileInode(at: shmPath)
        let needsProtection = force
            || (walInode != nil && walInode != protectedWALInode)
            || (shmInode != nil && shmInode != protectedSHMInode)
        guard needsProtection else { return }
        LiveContainerEnvironment.applySuspendLockedProtection(at: databasePath)
        protectedWALInode = walInode
        protectedSHMInode = shmInode
    }

    public var schemaVersion: Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return 0 }
        return Self.readUserVersion(db)
    }

    // MARK: - Transactional `PRAGMA user_version` Schema Migrator

    private static func migrateSchemaIfNeeded(_ db: OpaquePointer) {
        let version = readUserVersion(db)
        if version < 1 {
            exec(db, sql: """
                BEGIN IMMEDIATE TRANSACTION;

                CREATE TABLE IF NOT EXISTS places (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    url_key TEXT NOT NULL UNIQUE,
                    url TEXT NOT NULL,
                    host TEXT NOT NULL,
                    title TEXT NOT NULL,
                    visit_count INTEGER NOT NULL DEFAULT 1,
                    last_visited_at_ms INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_places_frecency
                    ON places(visit_count DESC, last_visited_at_ms DESC);

                CREATE VIRTUAL TABLE IF NOT EXISTS places_fts USING fts5(
                    title,
                    url,
                    content='places',
                    content_rowid='id',
                    tokenize='trigram case_sensitive 0'
                );

                CREATE TRIGGER IF NOT EXISTS trg_places_ai AFTER INSERT ON places BEGIN
                    INSERT INTO places_fts(rowid, title, url) VALUES (new.id, new.title, new.url);
                END;
                CREATE TRIGGER IF NOT EXISTS trg_places_ad AFTER DELETE ON places BEGIN
                    INSERT INTO places_fts(places_fts, rowid, title, url) VALUES ('delete', old.id, old.title, old.url);
                END;
                CREATE TRIGGER IF NOT EXISTS trg_places_au AFTER UPDATE OF title, url ON places BEGIN
                    INSERT INTO places_fts(places_fts, rowid, title, url) VALUES ('delete', old.id, old.title, old.url);
                    INSERT INTO places_fts(rowid, title, url) VALUES (new.id, new.title, new.url);
                END;

                CREATE TABLE IF NOT EXISTS history_visits (
                    id TEXT PRIMARY KEY NOT NULL,
                    place_id INTEGER NOT NULL REFERENCES places(id) ON DELETE CASCADE,
                    day_ymd INTEGER NOT NULL,
                    visited_at_ms INTEGER NOT NULL,
                    UNIQUE(day_ymd, place_id)
                );
                CREATE INDEX IF NOT EXISTS idx_visits_day_time
                    ON history_visits(day_ymd DESC, visited_at_ms DESC);
                CREATE INDEX IF NOT EXISTS idx_visits_time
                    ON history_visits(visited_at_ms DESC);
                CREATE INDEX IF NOT EXISTS idx_visits_place
                    ON history_visits(place_id);

                CREATE TRIGGER IF NOT EXISTS trg_visits_cleanup_orphan_place AFTER DELETE ON history_visits BEGIN
                    DELETE FROM places
                    WHERE id = old.place_id
                      AND NOT EXISTS (SELECT 1 FROM history_visits WHERE place_id = old.place_id);
                END;

                CREATE TABLE IF NOT EXISTS favorite_folders (
                    id TEXT PRIMARY KEY NOT NULL,
                    parent_id TEXT REFERENCES favorite_folders(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    sort_order REAL NOT NULL,
                    created_at_ms INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_folders_parent_order
                    ON favorite_folders(parent_id, sort_order ASC);

                CREATE TABLE IF NOT EXISTS favorites (
                    id TEXT PRIMARY KEY NOT NULL,
                    folder_id TEXT REFERENCES favorite_folders(id) ON DELETE SET NULL,
                    title TEXT NOT NULL,
                    url_key TEXT NOT NULL UNIQUE,
                    url TEXT NOT NULL,
                    symbol_name TEXT NOT NULL DEFAULT 'globe',
                    sort_order REAL NOT NULL,
                    created_at_ms INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_favorites_folder_order
                    ON favorites(folder_id, sort_order ASC);

                CREATE TABLE IF NOT EXISTS open_tabs (
                    id TEXT PRIMARY KEY NOT NULL,
                    url TEXT NOT NULL,
                    title TEXT NOT NULL,
                    sort_order REAL NOT NULL,
                    is_active INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE IF NOT EXISTS site_rules (
                    host TEXT PRIMARY KEY NOT NULL,
                    shield_mode INTEGER NOT NULL DEFAULT 0,
                    dark_mode INTEGER NOT NULL DEFAULT 0,
                    ua_mode INTEGER NOT NULL DEFAULT 0,
                    page_zoom REAL,
                    updated_at_ms INTEGER NOT NULL
                );

                PRAGMA user_version = 3;
                COMMIT;
                """)
            return
        }
        if version < 2 {
            exec(db, sql: """
                BEGIN IMMEDIATE TRANSACTION;
                CREATE INDEX IF NOT EXISTS idx_visits_place
                    ON history_visits(place_id);
                PRAGMA user_version = 2;
                COMMIT;
                """)
        }
        if version < 3 {
            exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
            if !tableHasColumn(db, table: "site_rules", column: "page_zoom") {
                exec(db, sql: "ALTER TABLE site_rules ADD COLUMN page_zoom REAL;")
            }
            exec(db, sql: "PRAGMA user_version = 3; COMMIT;")
        }
    }

    private static func tableHasColumn(_ db: OpaquePointer, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnText(stmt, index: 1).caseInsensitiveCompare(column) == .orderedSame {
                return true
            }
        }
        return false
    }

    private static func readUserVersion(_ db: OpaquePointer) -> Int32 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0)
        }
        return 0
    }

    // MARK: - History Write Path (`places` + `history_visits`)

    public func recordVisit(url: URL, title: String, visitedAt: Date = Date()) {
        let urlStr = url.absoluteString
        let urlKey = Self.normalizeURLKey(urlStr)
        let normalizedHost = url.host().map { LiveContainerEnvironment.HostNormalizer.normalize($0) } ?? ""
        let host = normalizedHost.isEmpty ? urlStr : normalizedHost
        let effectiveTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : title
        let visitedMs = Self.epochMilliseconds(visitedAt)
        let dayYMD = Self.calendarDayYMD(for: visitedAt)

        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }

        Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        upsertVisitLocked(
            db: db,
            visitID: UUID().uuidString,
            urlKey: urlKey,
            urlStr: urlStr,
            host: host,
            title: effectiveTitle,
            dayYMD: dayYMD,
            visitedMs: visitedMs
        )
        insertCounter &+= 1
        if insertCounter >= 250 {
            insertCounter = 0
            pruneOverflowLocked(db)
        }
        Self.exec(db, sql: "COMMIT;")
        ensureWALSidecarProtectionLocked()
    }

    public func bulkInsertHistory(_ entries: [BrowserHistoryEntry]) {
        guard !entries.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }

        Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        for entry in entries {
            let urlKey = Self.normalizeURLKey(entry.urlString)
            let host = entry.displayHost.lowercased()
            let cleanTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveTitle = cleanTitle.isEmpty ? host : cleanTitle
            upsertVisitLocked(
                db: db,
                visitID: entry.id,
                urlKey: urlKey,
                urlStr: entry.urlString,
                host: host,
                title: effectiveTitle,
                dayYMD: Self.calendarDayYMD(for: entry.visitedAt),
                visitedMs: Self.epochMilliseconds(entry.visitedAt)
            )
        }
        pruneOverflowLocked(db)
        Self.exec(db, sql: "COMMIT;")
        ensureWALSidecarProtectionLocked()
    }

    private func upsertVisitLocked(
        db: OpaquePointer,
        visitID: String,
        urlKey: String,
        urlStr: String,
        host: String,
        title: String,
        dayYMD: Int64,
        visitedMs: Int64
    ) {
        let placeSQL = """
            INSERT INTO places (url_key, url, host, title, visit_count, last_visited_at_ms)
            VALUES (?1, ?2, ?3, ?4, 1, ?5)
            ON CONFLICT(url_key) DO UPDATE SET
                url = excluded.url,
                host = excluded.host,
                title = CASE WHEN excluded.last_visited_at_ms >= places.last_visited_at_ms THEN excluded.title ELSE places.title END,
                visit_count = places.visit_count + 1,
                last_visited_at_ms = MAX(places.last_visited_at_ms, excluded.last_visited_at_ms);
            """
        var pStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, placeSQL, -1, &pStmt, nil) == SQLITE_OK {
            Self.bindText(pStmt, index: 1, value: urlKey)
            Self.bindText(pStmt, index: 2, value: urlStr)
            Self.bindText(pStmt, index: 3, value: host)
            Self.bindText(pStmt, index: 4, value: title)
            sqlite3_bind_int64(pStmt, 5, visitedMs)
            _ = sqlite3_step(pStmt)
        }
        sqlite3_finalize(pStmt)

        var idStmt: OpaquePointer?
        var placeID: Int64 = 0
        if sqlite3_prepare_v2(db, "SELECT id FROM places WHERE url_key = ?1;", -1, &idStmt, nil) == SQLITE_OK {
            Self.bindText(idStmt, index: 1, value: urlKey)
            if sqlite3_step(idStmt) == SQLITE_ROW {
                placeID = sqlite3_column_int64(idStmt, 0)
            }
        }
        sqlite3_finalize(idStmt)
        guard placeID > 0 else { return }

        let visitSQL = """
            INSERT INTO history_visits (id, place_id, day_ymd, visited_at_ms)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(day_ymd, place_id) DO UPDATE SET
                visited_at_ms = MAX(history_visits.visited_at_ms, excluded.visited_at_ms);
            """
        var vStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, visitSQL, -1, &vStmt, nil) == SQLITE_OK {
            Self.bindText(vStmt, index: 1, value: visitID)
            sqlite3_bind_int64(vStmt, 2, placeID)
            sqlite3_bind_int64(vStmt, 3, dayYMD)
            sqlite3_bind_int64(vStmt, 4, visitedMs)
            _ = sqlite3_step(vStmt)
        }
        sqlite3_finalize(vStmt)
    }

    public func deleteEntry(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM history_visits WHERE id = ?1;", -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: id)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        ensureWALSidecarProtectionLocked()
    }

    public func clearDay(dayYMD: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM history_visits WHERE day_ymd = ?1;", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, dayYMD)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        ensureWALSidecarProtectionLocked()
    }

    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        // Deleting `places` cascades into `history_visits` via `ON DELETE CASCADE` without O(N^2) orphan-trigger scans.
        Self.exec(db, sql: """
            BEGIN IMMEDIATE TRANSACTION;
            DELETE FROM places;
            DELETE FROM history_visits;
            INSERT INTO places_fts(places_fts) VALUES('rebuild');
            COMMIT;
            """)
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
    }

    public func clearEntries(since cutoff: Date, until endCutoff: Date? = nil) {
        if cutoff <= .distantPast && endCutoff == nil {
            clearAll()
            return
        }
        let startMs = Self.epochMilliseconds(cutoff)
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        var stmt: OpaquePointer?
        if let endCutoff {
            let endMs = Self.epochMilliseconds(endCutoff)
            if sqlite3_prepare_v2(
                db,
                "DELETE FROM history_visits WHERE visited_at_ms >= ?1 AND visited_at_ms < ?2;",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, startMs)
                sqlite3_bind_int64(stmt, 2, endMs)
                _ = sqlite3_step(stmt)
            }
        } else {
            if sqlite3_prepare_v2(
                db,
                "DELETE FROM history_visits WHERE visited_at_ms >= ?1;",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, startMs)
                _ = sqlite3_step(stmt)
            }
        }
        sqlite3_finalize(stmt)
        ensureWALSidecarProtectionLocked()
    }

    // MARK: - History Read Path (`FTS5 trigram` + Covering Index Day Aggregation + Frecency)

    public func totalCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM history_visits;", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    public func earliestVisitDate() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT MIN(visited_at_ms) FROM history_visits;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
            return nil
        }
        let ms = sqlite3_column_int64(stmt, 0)
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    public func countEntries(since cutoff: Date, until endCutoff: Date? = nil) -> Int {
        if cutoff <= .distantPast && endCutoff == nil {
            return totalCount()
        }
        let startMs = Self.epochMilliseconds(cutoff)
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if let endCutoff {
            let endMs = Self.epochMilliseconds(endCutoff)
            guard sqlite3_prepare_v2(
                db,
                "SELECT COUNT(*) FROM history_visits WHERE visited_at_ms >= ?1 AND visited_at_ms < ?2;",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK else { return 0 }
            sqlite3_bind_int64(stmt, 1, startMs)
            sqlite3_bind_int64(stmt, 2, endMs)
        } else {
            guard sqlite3_prepare_v2(
                db,
                "SELECT COUNT(*) FROM history_visits WHERE visited_at_ms >= ?1;",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK else { return 0 }
            sqlite3_bind_int64(stmt, 1, startMs)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    public func queryDaySummaries(
        searchQuery rawQuery: String = "",
        startDate: Date? = nil,
        endDate: Date? = nil,
        maxDays: Int = 90
    ) -> [BrowserHistoryDaySummary] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }

        var clauses: [String] = []
        if let startDate {
            clauses.append("v.visited_at_ms >= \(Self.epochMilliseconds(startDate))")
        }
        if let endDate {
            clauses.append("v.visited_at_ms < \(Self.epochMilliseconds(endDate))")
        }

        let useFTS = trimmed.unicodeScalars.count >= 3
        let joinSQL: String
        if trimmed.isEmpty {
            joinSQL = ""
        } else if useFTS {
            joinSQL = ""
            clauses.append("v.place_id IN (SELECT rowid FROM places_fts WHERE places_fts MATCH ?1)")
        } else {
            joinSQL = "JOIN places p ON p.id = v.place_id"
            clauses.append("(instr(lower(p.title), ?1) > 0 OR instr(lower(p.url), ?1) > 0)")
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let limitIdx: Int32 = trimmed.isEmpty ? 1 : 2

        let sql = """
            SELECT v.day_ymd, COUNT(*)
            FROM history_visits v
            \(joinSQL)
            \(whereSQL)
            GROUP BY v.day_ymd
            ORDER BY v.day_ymd DESC
            LIMIT ?\(limitIdx);
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        if !trimmed.isEmpty {
            let param = useFTS ? Self.ftsPhraseLiteral(trimmed) : trimmed.lowercased()
            Self.bindText(stmt, index: 1, value: param)
        }
        sqlite3_bind_int(stmt, limitIdx, Int32(maxDays))

        let todayYMD = Self.calendarDayYMD(for: Date())
        let yesterdayYMD = Self.calendarDayYMD(
            for: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date().addingTimeInterval(-86_400)
        )

        var results: [BrowserHistoryDaySummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ymd = sqlite3_column_int64(stmt, 0)
            let cnt = Int(sqlite3_column_int64(stmt, 1))
            let dayDate = Self.date(fromDayYMD: ymd)
            let displayTitle: String
            let chipTitle: String
            if ymd == todayYMD {
                displayTitle = "Today"
                chipTitle = "Today"
            } else if ymd == yesterdayYMD {
                displayTitle = "Yesterday"
                chipTitle = "Yesterday"
            } else {
                displayTitle = Self.dayHeaderFormatter.string(from: dayDate)
                chipTitle = Self.dayChipFormatter.string(from: dayDate)
            }
            results.append(
                BrowserHistoryDaySummary(
                    dayYMD: ymd,
                    dayStart: dayDate,
                    displayTitle: displayTitle,
                    chipTitle: chipTitle,
                    count: cnt
                )
            )
        }
        return results
    }

    public func queryEntriesPage(
        searchQuery rawQuery: String = "",
        dayYMD: Int64? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        limit: Int = 80,
        offset: Int = 0
    ) -> [BrowserHistoryEntry] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }

        var clauses: [String] = []
        if let dayYMD {
            clauses.append("v.day_ymd = \(dayYMD)")
        }
        if let startDate {
            clauses.append("v.visited_at_ms >= \(Self.epochMilliseconds(startDate))")
        }
        if let endDate {
            clauses.append("v.visited_at_ms < \(Self.epochMilliseconds(endDate))")
        }

        let useFTS = trimmed.unicodeScalars.count >= 3
        if !trimmed.isEmpty {
            if useFTS {
                clauses.append("v.place_id IN (SELECT rowid FROM places_fts WHERE places_fts MATCH ?1)")
            } else {
                clauses.append("(instr(lower(p.title), ?1) > 0 OR instr(lower(p.url), ?1) > 0)")
            }
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let limitIdx: Int32 = trimmed.isEmpty ? 1 : 2
        let offsetIdx: Int32 = trimmed.isEmpty ? 2 : 3

        let sql = """
            SELECT v.id, p.title, p.url, v.visited_at_ms
            FROM history_visits v
            JOIN places p ON p.id = v.place_id
            \(whereSQL)
            ORDER BY v.day_ymd DESC, v.visited_at_ms DESC
            LIMIT ?\(limitIdx) OFFSET ?\(offsetIdx);
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        if !trimmed.isEmpty {
            let param = useFTS ? Self.ftsPhraseLiteral(trimmed) : trimmed.lowercased()
            Self.bindText(stmt, index: 1, value: param)
        }
        sqlite3_bind_int(stmt, limitIdx, Int32(max(1, limit)))
        sqlite3_bind_int(stmt, offsetIdx, Int32(max(0, offset)))

        var items: [BrowserHistoryEntry] = []
        items.reserveCapacity(min(limit, 128))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Self.columnText(stmt, index: 0)
            let title = Self.columnText(stmt, index: 1)
            let url = Self.columnText(stmt, index: 2)
            let ms = sqlite3_column_int64(stmt, 3)
            items.append(
                BrowserHistoryEntry(
                    id: id,
                    title: title,
                    urlString: url,
                    visitedAt: Date(timeIntervalSince1970: Double(ms) / 1000.0)
                )
            )
        }
        return items
    }

    /// Frecency-ranked URL/Title lookup ready for Omnibox instant autocomplete.
    public func queryTopPlaces(matching rawQuery: String, limit: Int = 8) -> [(url: String, title: String, visitCount: Int)] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }

        let useFTS = trimmed.unicodeScalars.count >= 3
        let sql: String
        if useFTS {
            sql = """
                SELECT url, title, visit_count
                FROM places
                WHERE id IN (SELECT rowid FROM places_fts WHERE places_fts MATCH ?1)
                ORDER BY visit_count DESC, last_visited_at_ms DESC
                LIMIT ?2;
                """
        } else {
            sql = """
                SELECT url, title, visit_count
                FROM places
                WHERE instr(lower(title), ?1) > 0 OR instr(lower(url), ?1) > 0
                ORDER BY visit_count DESC, last_visited_at_ms DESC
                LIMIT ?2;
                """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let param = useFTS ? Self.ftsPhraseLiteral(trimmed) : trimmed.lowercased()
        Self.bindText(stmt, index: 1, value: param)
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))

        var matches: [(String, String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            matches.append((
                Self.columnText(stmt, index: 0),
                Self.columnText(stmt, index: 1),
                Int(sqlite3_column_int64(stmt, 2))
            ))
        }
        return matches
    }

    // MARK: - Favorites & Hierarchical Folders (`favorite_folders` + `favorites`)

    public func loadFolders() -> [BrowserFavoriteFolder] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id, parent_id, title, sort_order, created_at_ms FROM favorite_folders ORDER BY sort_order ASC, created_at_ms ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var folders: [BrowserFavoriteFolder] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Self.columnText(stmt, index: 0)
            let parentID = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Self.columnText(stmt, index: 1)
            let title = Self.columnText(stmt, index: 2)
            let order = sqlite3_column_double(stmt, 3)
            let createdMs = sqlite3_column_int64(stmt, 4)
            folders.append(
                BrowserFavoriteFolder(
                    id: id,
                    parentID: parentID,
                    title: title,
                    sortOrder: order,
                    createdAt: Date(timeIntervalSince1970: Double(createdMs) / 1000.0)
                )
            )
        }
        return folders
    }

    public func upsertFolder(_ folder: BrowserFavoriteFolder) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        let sql = """
            INSERT INTO favorite_folders (id, parent_id, title, sort_order, created_at_ms)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(id) DO UPDATE SET
                parent_id = excluded.parent_id,
                title = excluded.title,
                sort_order = excluded.sort_order;
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: folder.id)
            Self.bindOptionalText(stmt, index: 2, value: folder.parentID)
            Self.bindText(stmt, index: 3, value: folder.title)
            sqlite3_bind_double(stmt, 4, folder.sortOrder)
            sqlite3_bind_int64(stmt, 5, Self.epochMilliseconds(folder.createdAt))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
        writeFavoritesBackupMirrorLocked(db)
    }

    public func deleteFolder(id: String, keepBookmarks: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        if !keepBookmarks {
            var delBm: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM favorites WHERE folder_id = ?1;", -1, &delBm, nil) == SQLITE_OK {
                Self.bindText(delBm, index: 1, value: id)
                _ = sqlite3_step(delBm)
            }
            sqlite3_finalize(delBm)
        }
        // When `keepBookmarks == true`, `ON DELETE SET NULL` automatically moves bookmarks back to Root (`folder_id = NULL`).
        var delFolder: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM favorite_folders WHERE id = ?1;", -1, &delFolder, nil) == SQLITE_OK {
            Self.bindText(delFolder, index: 1, value: id)
            _ = sqlite3_step(delFolder)
        }
        sqlite3_finalize(delFolder)
        Self.exec(db, sql: "COMMIT;")
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
        writeFavoritesBackupMirrorLocked(db)
    }

    public func loadBookmarks() -> [BrowserBookmark] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id, folder_id, title, url, symbol_name, sort_order FROM favorites ORDER BY sort_order ASC, created_at_ms ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var items: [BrowserBookmark] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Self.columnText(stmt, index: 0)
            let folderID = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Self.columnText(stmt, index: 1)
            let title = Self.columnText(stmt, index: 2)
            let url = Self.columnText(stmt, index: 3)
            let symbol = Self.columnText(stmt, index: 4)
            let sortOrder = sqlite3_column_double(stmt, 5)
            items.append(
                BrowserBookmark(
                    id: id,
                    title: title,
                    urlString: url,
                    symbolName: symbol,
                    folderID: folderID,
                    sortOrder: sortOrder
                )
            )
        }
        return items
    }

    public func upsertBookmark(_ bm: BrowserBookmark) {
        let urlKey = Self.normalizeURLKey(bm.urlString)
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        let sql = """
            INSERT INTO favorites (id, folder_id, title, url_key, url, symbol_name, sort_order, created_at_ms)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(url_key) DO UPDATE SET
                folder_id = excluded.folder_id,
                title = excluded.title,
                url = excluded.url,
                symbol_name = excluded.symbol_name,
                sort_order = excluded.sort_order;
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: bm.id)
            Self.bindOptionalText(stmt, index: 2, value: bm.folderID)
            Self.bindText(stmt, index: 3, value: bm.title)
            Self.bindText(stmt, index: 4, value: urlKey)
            Self.bindText(stmt, index: 5, value: bm.urlString)
            Self.bindText(stmt, index: 6, value: bm.symbolName)
            sqlite3_bind_double(stmt, 7, bm.sortOrder)
            sqlite3_bind_int64(stmt, 8, Self.epochMilliseconds(Date()))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
        writeFavoritesBackupMirrorLocked(db)
    }

    public func deleteBookmark(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM favorites WHERE id = ?1;", -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: id)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
        writeFavoritesBackupMirrorLocked(db)
    }

    private func loadFoldersLocked(_ db: OpaquePointer) -> [BrowserFavoriteFolder] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id, parent_id, title, sort_order, created_at_ms FROM favorite_folders ORDER BY sort_order ASC, created_at_ms ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var folders: [BrowserFavoriteFolder] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Self.columnText(stmt, index: 0)
            let parentID = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Self.columnText(stmt, index: 1)
            let title = Self.columnText(stmt, index: 2)
            let order = sqlite3_column_double(stmt, 3)
            let createdMs = sqlite3_column_int64(stmt, 4)
            folders.append(
                BrowserFavoriteFolder(
                    id: id,
                    parentID: parentID,
                    title: title,
                    sortOrder: order,
                    createdAt: Date(timeIntervalSince1970: Double(createdMs) / 1000.0)
                )
            )
        }
        return folders
    }

    private func loadBookmarksLocked(_ db: OpaquePointer) -> [BrowserBookmark] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id, folder_id, title, url, symbol_name, sort_order FROM favorites ORDER BY sort_order ASC, created_at_ms ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var items: [BrowserBookmark] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Self.columnText(stmt, index: 0)
            let folderID = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Self.columnText(stmt, index: 1)
            let title = Self.columnText(stmt, index: 2)
            let url = Self.columnText(stmt, index: 3)
            let symbol = Self.columnText(stmt, index: 4)
            let sortOrder = sqlite3_column_double(stmt, 5)
            items.append(
                BrowserBookmark(
                    id: id,
                    title: title,
                    urlString: url,
                    symbolName: symbol,
                    folderID: folderID,
                    sortOrder: sortOrder
                )
            )
        }
        return items
    }

    private func writeFavoritesBackupMirrorLocked(_ db: OpaquePointer) {
        let snapshot = FavoritesBackupSnapshot(
            folders: loadFoldersLocked(db),
            bookmarks: loadBookmarksLocked(db)
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: favoritesBackupURL, options: .atomic)
        }
    }

    private func restoreFavoritesFromBackupMirrorIfDatabaseEmpty() {
        let existingFolders = loadFolders()
        let existingBookmarks = loadBookmarks()
        if !existingFolders.isEmpty || !existingBookmarks.isEmpty {
            lock.lock()
            if let db { writeFavoritesBackupMirrorLocked(db) }
            lock.unlock()
            return
        }
        guard FileManager.default.fileExists(atPath: favoritesBackupURL.path),
              let data = try? Data(contentsOf: favoritesBackupURL),
              let snapshot = try? JSONDecoder().decode(FavoritesBackupSnapshot.self, from: data),
              (!snapshot.folders.isEmpty || !snapshot.bookmarks.isEmpty) else {
            return
        }
        for folder in snapshot.folders {
            upsertFolder(folder)
        }
        let validFolderIDs = Set(snapshot.folders.map(\.id))
        for var bm in snapshot.bookmarks {
            if let fID = bm.folderID, !validFolderIDs.contains(fID) {
                bm.folderID = nil
            }
            upsertBookmark(bm)
        }
    }

    // MARK: - Open Standard Tabs Session Persistence (`open_tabs`)

    public func loadOpenTabs() -> [PersistedOpenTab] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, url, title, sort_order, is_active FROM open_tabs ORDER BY sort_order ASC;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return [] }

        var tabs: [PersistedOpenTab] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uuid = UUID(uuidString: Self.columnText(stmt, index: 0)) else { continue }
            tabs.append(
                PersistedOpenTab(
                    id: uuid,
                    urlString: Self.columnText(stmt, index: 1),
                    title: Self.columnText(stmt, index: 2),
                    sortOrder: sqlite3_column_double(stmt, 3),
                    isActive: sqlite3_column_int(stmt, 4) != 0
                )
            )
        }
        return tabs
    }

    public func saveOpenTabs(_ tabs: [PersistedOpenTab]) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION; DELETE FROM open_tabs;")
        let sql = "INSERT INTO open_tabs (id, url, title, sort_order, is_active) VALUES (?1, ?2, ?3, ?4, ?5);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for tab in tabs {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                Self.bindText(stmt, index: 1, value: tab.id.uuidString)
                Self.bindText(stmt, index: 2, value: tab.urlString)
                Self.bindText(stmt, index: 3, value: tab.title)
                sqlite3_bind_double(stmt, 4, tab.sortOrder)
                sqlite3_bind_int(stmt, 5, tab.isActive ? 1 : 0)
                _ = sqlite3_step(stmt)
            }
        }
        sqlite3_finalize(stmt)
        Self.exec(db, sql: "COMMIT;")
        ensureWALSidecarProtectionLocked()
    }

    // MARK: - Per-Site Policy Rules (`site_rules`)

    public func loadAllSiteRules() -> [SiteRuleRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT host, shield_mode, dark_mode, ua_mode, page_zoom FROM site_rules ORDER BY host ASC;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return [] }

        var rules: [SiteRuleRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let host = Self.columnText(stmt, index: 0)
            let zoom: Double? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 4)
            rules.append(
                SiteRuleRecord(
                    host: host,
                    shieldMode: Int(sqlite3_column_int(stmt, 1)),
                    darkMode: Int(sqlite3_column_int(stmt, 2)),
                    uaMode: Int(sqlite3_column_int(stmt, 3)),
                    pageZoom: zoom
                )
            )
        }
        return rules
    }

    public func siteRule(forHost rawHost: String) -> SiteRuleRecord? {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
        guard !host.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT shield_mode, dark_mode, ua_mode, page_zoom FROM site_rules WHERE host = ?1;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return nil }
        Self.bindText(stmt, index: 1, value: host)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let zoom: Double? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
        return SiteRuleRecord(
            host: host,
            shieldMode: Int(sqlite3_column_int(stmt, 0)),
            darkMode: Int(sqlite3_column_int(stmt, 1)),
            uaMode: Int(sqlite3_column_int(stmt, 2)),
            pageZoom: zoom
        )
    }

    public func upsertSiteRule(_ rule: SiteRuleRecord) {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rule.host)
        guard !host.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        if rule.isAllDefault {
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM site_rules WHERE host = ?1;", -1, &delStmt, nil) == SQLITE_OK {
                Self.bindText(delStmt, index: 1, value: host)
                _ = sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)
            ensureWALSidecarProtectionLocked()
            return
        }
        let sql = """
            INSERT INTO site_rules (host, shield_mode, dark_mode, ua_mode, page_zoom, updated_at_ms)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(host) DO UPDATE SET
                shield_mode = excluded.shield_mode,
                dark_mode = excluded.dark_mode,
                ua_mode = excluded.ua_mode,
                page_zoom = excluded.page_zoom,
                updated_at_ms = excluded.updated_at_ms;
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: host)
            sqlite3_bind_int(stmt, 2, Int32(rule.shieldMode))
            sqlite3_bind_int(stmt, 3, Int32(rule.darkMode))
            sqlite3_bind_int(stmt, 4, Int32(rule.uaMode))
            if let zoom = rule.pageZoom {
                sqlite3_bind_double(stmt, 5, SiteRuleRecord.clampedZoom(zoom))
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_int64(stmt, 6, Self.epochMilliseconds(Date()))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        ensureWALSidecarProtectionLocked()
    }

    public func deleteSiteRule(forHost rawHost: String) {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
        guard !host.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM site_rules WHERE host = ?1;", -1, &delStmt, nil) == SQLITE_OK {
            Self.bindText(delStmt, index: 1, value: host)
            _ = sqlite3_step(delStmt)
        }
        sqlite3_finalize(delStmt)
        ensureWALSidecarProtectionLocked()
    }

    // MARK: - Lossless Legacy Ingestion (`favorite_folders.json`, `bookmarks.json`, `history.sqlite3`, `history.json`)

    private func ingestLegacyStateIfNeeded(in dir: URL) {
        let fm = FileManager.default
        let legacyFoldersJSON = dir.appendingPathComponent("favorite_folders.json")
        let legacyBookmarksJSON = dir.appendingPathComponent("bookmarks.json")
        let legacyHistoryJSON = dir.appendingPathComponent("history.json")
        let legacyHistorySQLite = dir.appendingPathComponent("history.sqlite3")

        // 1. Folders JSON -> `favorite_folders`
        if fm.fileExists(atPath: legacyFoldersJSON.path) {
            if let data = try? Data(contentsOf: legacyFoldersJSON),
               let decoded = try? JSONDecoder().decode([BrowserFavoriteFolder].self, from: data) {
                for (idx, var folder) in decoded.enumerated() {
                    if folder.sortOrder == 0 { folder.sortOrder = Double(idx + 1) * 100.0 }
                    upsertFolder(folder)
                }
            }
            try? fm.removeItem(at: legacyFoldersJSON)
        }

        // 2. Bookmarks JSON -> `favorites` (or initial seed on brand-new install)
        let seedVersionKey = "dysprosium.bookmarks.seedVersion"
        if fm.fileExists(atPath: legacyBookmarksJSON.path) {
            let validFolderIDs = Set(loadFolders().map(\.id))
            if let data = try? Data(contentsOf: legacyBookmarksJSON),
               let decoded = try? JSONDecoder().decode([BrowserBookmark].self, from: data) {
                for (idx, var bm) in decoded.enumerated() {
                    if let fID = bm.folderID, !validFolderIDs.contains(fID) {
                        bm.folderID = nil
                    }
                    if bm.sortOrder == 0 { bm.sortOrder = Double(idx + 1) * 100.0 }
                    upsertBookmark(bm)
                }
            }
            LiveContainerEnvironment.sharedDefaults.set(2, forKey: seedVersionKey)
            try? fm.removeItem(at: legacyBookmarksJSON)
        } else if loadBookmarks().isEmpty && Self.readSharedInt(forKey: seedVersionKey) < 2 {
            upsertBookmark(BrowserBookmark(title: "Google", urlString: "https://www.google.com", symbolName: "globe", sortOrder: 100))
            upsertBookmark(BrowserBookmark(title: "DuckDuckGo", urlString: "https://duckduckgo.com", symbolName: "magnifyingglass", sortOrder: 200))
            LiveContainerEnvironment.sharedDefaults.set(2, forKey: seedVersionKey)
        }

        // 3. Legacy `history.json` -> `places` + `history_visits`
        if fm.fileExists(atPath: legacyHistoryJSON.path) {
            if let data = try? Data(contentsOf: legacyHistoryJSON),
               let decoded = try? JSONDecoder().decode([BrowserHistoryEntry].self, from: data),
               !decoded.isEmpty {
                bulkInsertHistory(decoded)
            }
            try? fm.removeItem(at: legacyHistoryJSON)
        }

        // 4. Intermediate `history.sqlite3` -> `places` + `history_visits`
        if fm.fileExists(atPath: legacyHistorySQLite.path) {
            var oldDB: OpaquePointer?
            if sqlite3_open_v2(legacyHistorySQLite.path, &oldDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let oldDB {
                var stmt: OpaquePointer?
                var imported: [BrowserHistoryEntry] = []
                if sqlite3_prepare_v2(oldDB, "SELECT id, title, url, visited_at FROM browser_history ORDER BY visited_at ASC;", -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        imported.append(
                            BrowserHistoryEntry(
                                id: Self.columnText(stmt, index: 0),
                                title: Self.columnText(stmt, index: 1),
                                urlString: Self.columnText(stmt, index: 2),
                                visitedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                            )
                        )
                    }
                }
                sqlite3_finalize(stmt)
                sqlite3_close_v2(oldDB)
                if !imported.isEmpty {
                    bulkInsertHistory(imported)
                }
            }
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(atPath: legacyHistorySQLite.path + suffix)
            }
        }
    }

    // MARK: - Calendar & SQLite Primitives

    public static func calendarDayYMD(for date: Date) -> Int64 {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let y = Int64(comps.year ?? 2026)
        let m = Int64(comps.month ?? 1)
        let d = Int64(comps.day ?? 1)
        return y * 10_000 + m * 100 + d
    }

    public static func date(fromDayYMD ymd: Int64) -> Date {
        var comps = DateComponents()
        comps.year = Int(ymd / 10_000)
        comps.month = Int((ymd / 100) % 100)
        comps.day = Int(ymd % 100)
        return Calendar.current.date(from: comps) ?? Date()
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }

    private static func normalizeURLKey(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
    }

    private static func ftsPhraseLiteral(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func pruneOverflowLocked(_ db: OpaquePointer) {
        let sql = """
            DELETE FROM history_visits
            WHERE id IN (
                SELECT id FROM history_visits
                ORDER BY day_ymd DESC, visited_at_ms DESC
                LIMIT -1 OFFSET \(Self.maxRetainedVisits)
            );
            """
        Self.exec(db, sql: sql)
    }

    private static func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        value.withCString { cStr in
            _ = sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        }
    }

    private static func bindOptionalText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let value {
            bindText(stmt, index: index, value: value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func columnText(_ stmt: OpaquePointer?, index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private static func exec(_ db: OpaquePointer, sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK, let errMsg {
            sqlite3_free(errMsg)
        }
    }

    private static func fileInode(at path: String) -> UInt64? {
        var st = Darwin.stat()
        guard path.withCString({ Darwin.lstat($0, &st) }) == 0 else { return nil }
        return UInt64(st.st_ino)
    }

    private static func fileSizeBytes(at path: String) -> UInt64 {
        var st = Darwin.stat()
        guard path.withCString({ Darwin.lstat($0, &st) }) == 0, st.st_size > 0 else { return 0 }
        return UInt64(st.st_size)
    }

    private static func readSharedInt(forKey key: String) -> Int {
        let shared = LiveContainerEnvironment.sharedDefaults
        if shared.object(forKey: key) != nil {
            return shared.integer(forKey: key)
        }
        if shared !== UserDefaults.standard, UserDefaults.standard.object(forKey: key) != nil {
            let legacy = UserDefaults.standard.integer(forKey: key)
            shared.set(legacy, forKey: key)
            return legacy
        }
        return 0
    }
}
