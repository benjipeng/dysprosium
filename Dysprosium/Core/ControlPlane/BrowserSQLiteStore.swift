import Darwin
import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct BrowserHistoryDaySummary: Identifiable, Equatable, Sendable {
    private enum DisplayKind: Equatable, Sendable {
        case today
        case yesterday
        case earlier
        case calendarDate
        case custom(String, String)
    }

    /// Timezone-immune calendar key `YYYYMMDD` (e.g. `20261118`).
    public let dayYMD: Int64
    public let dayStart: Date
    public let count: Int
    private let kind: DisplayKind

    public var id: Int64 { dayYMD }

    public init(
        dayYMD: Int64,
        dayStart: Date,
        displayTitle: String,
        chipTitle: String,
        count: Int
    ) {
        self.dayYMD = dayYMD
        self.dayStart = dayStart
        self.count = count
        if displayTitle == "Today" && chipTitle == "Today" {
            self.kind = .today
        } else if displayTitle == "Yesterday" && chipTitle == "Yesterday" {
            self.kind = .yesterday
        } else if displayTitle == "Earlier" && chipTitle == "Earlier" {
            self.kind = .earlier
        } else {
            self.kind = .custom(displayTitle, chipTitle)
        }
    }

    private init(dayYMD: Int64, dayStart: Date, count: Int, kind: DisplayKind) {
        self.dayYMD = dayYMD
        self.dayStart = dayStart
        self.count = count
        self.kind = kind
    }

    public static func calendarDay(dayYMD: Int64, dayStart: Date, count: Int) -> BrowserHistoryDaySummary {
        BrowserHistoryDaySummary(dayYMD: dayYMD, dayStart: dayStart, count: count, kind: .calendarDate)
    }

    public static func earlier(dayYMD: Int64, dayStart: Date, count: Int) -> BrowserHistoryDaySummary {
        BrowserHistoryDaySummary(dayYMD: dayYMD, dayStart: dayStart, count: count, kind: .earlier)
    }

    public var displayTitle: String {
        switch kind {
        case .today: return L("Today")
        case .yesterday: return L("Yesterday")
        case .earlier: return L("Earlier")
        case .calendarDate:
            return dayStart.formatted(
                .dateTime.weekday(.wide).month(.abbreviated).day()
                    .locale(AppLocalization.currentLocale)
            )
        case .custom(let display, _):
            return display
        }
    }

    public var chipTitle: String {
        switch kind {
        case .today: return L("Today")
        case .yesterday: return L("Yesterday")
        case .earlier: return L("Earlier")
        case .calendarDate:
            return dayStart.formatted(
                .dateTime.month(.abbreviated).day()
                    .locale(AppLocalization.currentLocale)
            )
        case .custom(_, let chip):
            return chip
        }
    }
}

public struct PersistedOpenTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var profileID: String
    public var urlString: String
    public var title: String
    public var sortOrder: Double
    public var isActive: Bool

    public init(
        id: UUID,
        profileID: String = BrowserProfile.defaultID,
        urlString: String,
        title: String,
        sortOrder: Double,
        isActive: Bool
    ) {
        self.id = id
        self.profileID = profileID
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
/// - Governed by transactional `PRAGMA user_version` migrations (`currentSchemaVersion = 4`).
/// - Isolates `places`/`history_visits`, `favorite_folders`/`favorites`, `open_tabs`, and `site_rules` by `profile_id`.
/// - Normalizes `places` (canonical URL dictionary + `visit_count` frecency) and `history_visits` (~24 bytes/visit).
/// - Uses Apple `libsqlite3` native `FTS5(tokenize='trigram case_sensitive 0')` external-content index (`0` duplicate string bloat).
public final class BrowserSQLiteStore: @unchecked Sendable {
    public static let currentSchemaVersion: Int32 = 4
    public static let maxRetainedVisits = 50_000

    private struct ProfileFavoritesBucket: Codable {
        let folders: [BrowserFavoriteFolder]
        let bookmarks: [BrowserBookmark]
    }

    private struct FavoritesBackupSnapshotV2: Codable {
        let version: Int
        let profiles: [String: ProfileFavoritesBucket]
    }

    private struct FavoritesBackupSnapshotV1: Codable {
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
        let defaultID = BrowserProfile.defaultID

        if version < 1 {
            exec(db, sql: """
                BEGIN IMMEDIATE TRANSACTION;

                CREATE TABLE IF NOT EXISTS profiles (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    symbol_name TEXT NOT NULL DEFAULT 'person.crop.circle',
                    palette_preset TEXT NOT NULL DEFAULT 'cerulean',
                    is_default INTEGER NOT NULL DEFAULT 0,
                    webkit_store_id TEXT,
                    fingerprint_seed TEXT NOT NULL,
                    ua_profile TEXT NOT NULL DEFAULT 'iosSafari',
                    search_engine TEXT NOT NULL DEFAULT 'duckDuckGo',
                    custom_search_template TEXT NOT NULL DEFAULT '',
                    sort_order REAL NOT NULL DEFAULT 100.0,
                    created_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS places (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    profile_id TEXT NOT NULL DEFAULT '\(defaultID)' REFERENCES profiles(id) ON DELETE CASCADE,
                    url_key TEXT NOT NULL,
                    url TEXT NOT NULL,
                    host TEXT NOT NULL,
                    title TEXT NOT NULL,
                    visit_count INTEGER NOT NULL DEFAULT 1,
                    last_visited_at_ms INTEGER NOT NULL,
                    UNIQUE(profile_id, url_key)
                );
                CREATE INDEX IF NOT EXISTS idx_places_frecency
                    ON places(visit_count DESC, last_visited_at_ms DESC);
                CREATE INDEX IF NOT EXISTS idx_places_profile_frecency
                    ON places(profile_id, visit_count DESC, last_visited_at_ms DESC);

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
                    profile_id TEXT NOT NULL DEFAULT '\(defaultID)',
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
                CREATE INDEX IF NOT EXISTS idx_visits_profile_day_time
                    ON history_visits(profile_id, day_ymd DESC, visited_at_ms DESC);
                CREATE INDEX IF NOT EXISTS idx_visits_profile_time
                    ON history_visits(profile_id, visited_at_ms DESC);

                CREATE TRIGGER IF NOT EXISTS trg_visits_cleanup_orphan_place AFTER DELETE ON history_visits BEGIN
                    DELETE FROM places
                    WHERE id = old.place_id
                      AND NOT EXISTS (SELECT 1 FROM history_visits WHERE place_id = old.place_id);
                END;

                CREATE TABLE IF NOT EXISTS favorite_folders (
                    id TEXT PRIMARY KEY NOT NULL,
                    profile_id TEXT NOT NULL DEFAULT '\(defaultID)' REFERENCES profiles(id) ON DELETE CASCADE,
                    parent_id TEXT REFERENCES favorite_folders(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    sort_order REAL NOT NULL,
                    created_at_ms INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_folders_parent_order
                    ON favorite_folders(parent_id, sort_order ASC);
                CREATE INDEX IF NOT EXISTS idx_folders_profile_parent_order
                    ON favorite_folders(profile_id, parent_id, sort_order ASC);

                CREATE TABLE IF NOT EXISTS favorites (
                    id TEXT PRIMARY KEY NOT NULL,
                    profile_id TEXT NOT NULL DEFAULT '\(defaultID)' REFERENCES profiles(id) ON DELETE CASCADE,
                    folder_id TEXT REFERENCES favorite_folders(id) ON DELETE SET NULL,
                    title TEXT NOT NULL,
                    url_key TEXT NOT NULL,
                    url TEXT NOT NULL,
                    symbol_name TEXT NOT NULL DEFAULT 'globe',
                    sort_order REAL NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    UNIQUE(profile_id, url_key)
                );
                CREATE INDEX IF NOT EXISTS idx_favorites_folder_order
                    ON favorites(folder_id, sort_order ASC);
                CREATE INDEX IF NOT EXISTS idx_favorites_profile_folder_order
                    ON favorites(profile_id, folder_id, sort_order ASC);

                CREATE TABLE IF NOT EXISTS open_tabs (
                    id TEXT PRIMARY KEY NOT NULL,
                    profile_id TEXT NOT NULL DEFAULT '\(defaultID)' REFERENCES profiles(id) ON DELETE CASCADE,
                    url TEXT NOT NULL,
                    title TEXT NOT NULL,
                    sort_order REAL NOT NULL,
                    is_active INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS idx_open_tabs_profile_order
                    ON open_tabs(profile_id, sort_order ASC);

                CREATE TABLE IF NOT EXISTS site_rules (
                    profile_id TEXT NOT NULL DEFAULT '\(defaultID)' REFERENCES profiles(id) ON DELETE CASCADE,
                    host TEXT NOT NULL,
                    shield_mode INTEGER NOT NULL DEFAULT 0,
                    dark_mode INTEGER NOT NULL DEFAULT 0,
                    ua_mode INTEGER NOT NULL DEFAULT 0,
                    page_zoom REAL,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (profile_id, host)
                );

                PRAGMA user_version = 4;
                COMMIT;
                """)
            seedDefaultProfileIfMissing(db)
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
        if version < 4 {
            // Follow SQLite's official 12-step atomic schema migration:
            // Disable foreign_keys OUTSIDE the transaction so replacing `places` does NOT trigger
            // `ON DELETE CASCADE` on `history_visits`. Preserving exact `places.id` rows avoids
            // rebuilding the external-content `places_fts` trigram index completely.
            _ = exec(db, sql: "PRAGMA foreign_keys = OFF;")
            var migrationOK = exec(db, sql: """
                BEGIN IMMEDIATE TRANSACTION;

                CREATE TABLE IF NOT EXISTS profiles (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    symbol_name TEXT NOT NULL DEFAULT 'person.crop.circle',
                    palette_preset TEXT NOT NULL DEFAULT 'cerulean',
                    is_default INTEGER NOT NULL DEFAULT 0,
                    webkit_store_id TEXT,
                    fingerprint_seed TEXT NOT NULL,
                    ua_profile TEXT NOT NULL DEFAULT 'iosSafari',
                    search_engine TEXT NOT NULL DEFAULT 'duckDuckGo',
                    custom_search_template TEXT NOT NULL DEFAULT '',
                    sort_order REAL NOT NULL DEFAULT 100.0,
                    created_at_ms INTEGER NOT NULL
                );
                """)
            if migrationOK {
                seedDefaultProfileIfMissing(db)
            }

            // 1. O(1) column additions on tables with no single-column UNIQUE constraint change
            if migrationOK && !tableHasColumn(db, table: "favorite_folders", column: "profile_id") {
                migrationOK = exec(db, sql: "ALTER TABLE favorite_folders ADD COLUMN profile_id TEXT NOT NULL DEFAULT '\(defaultID)';")
            }
            if migrationOK {
                migrationOK = exec(db, sql: "CREATE INDEX IF NOT EXISTS idx_folders_profile_parent_order ON favorite_folders(profile_id, parent_id, sort_order ASC);")
            }

            if migrationOK && !tableHasColumn(db, table: "open_tabs", column: "profile_id") {
                migrationOK = exec(db, sql: "ALTER TABLE open_tabs ADD COLUMN profile_id TEXT NOT NULL DEFAULT '\(defaultID)';")
            }
            if migrationOK {
                migrationOK = exec(db, sql: "CREATE INDEX IF NOT EXISTS idx_open_tabs_profile_order ON open_tabs(profile_id, sort_order ASC);")
            }

            if migrationOK && !tableHasColumn(db, table: "history_visits", column: "profile_id") {
                migrationOK = exec(db, sql: "ALTER TABLE history_visits ADD COLUMN profile_id TEXT NOT NULL DEFAULT '\(defaultID)';")
            }
            if migrationOK {
                migrationOK = exec(db, sql: """
                    CREATE INDEX IF NOT EXISTS idx_visits_profile_day_time
                        ON history_visits(profile_id, day_ymd DESC, visited_at_ms DESC);
                    CREATE INDEX IF NOT EXISTS idx_visits_profile_time
                        ON history_visits(profile_id, visited_at_ms DESC);
                    """)
            }

            // 2. Rebuild `places` preserving exact `id` values (zero FTS5 re-indexing)
            if migrationOK && !tableHasColumn(db, table: "places", column: "profile_id") {
                migrationOK = exec(db, sql: """
                    DROP TRIGGER IF EXISTS trg_places_ai;
                    DROP TRIGGER IF EXISTS trg_places_ad;
                    DROP TRIGGER IF EXISTS trg_places_au;
                    DROP TABLE IF EXISTS places_v4;

                    CREATE TABLE places_v4 (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        profile_id TEXT NOT NULL DEFAULT '\(defaultID)' REFERENCES profiles(id) ON DELETE CASCADE,
                        url_key TEXT NOT NULL,
                        url TEXT NOT NULL,
                        host TEXT NOT NULL,
                        title TEXT NOT NULL,
                        visit_count INTEGER NOT NULL DEFAULT 1,
                        last_visited_at_ms INTEGER NOT NULL,
                        UNIQUE(profile_id, url_key)
                    );
                    INSERT INTO places_v4 (id, profile_id, url_key, url, host, title, visit_count, last_visited_at_ms)
                    SELECT id, '\(defaultID)', url_key, url, host, title, visit_count, last_visited_at_ms FROM places;

                    DROP TABLE places;
                    ALTER TABLE places_v4 RENAME TO places;

                    CREATE INDEX IF NOT EXISTS idx_places_frecency
                        ON places(visit_count DESC, last_visited_at_ms DESC);
                    CREATE INDEX IF NOT EXISTS idx_places_profile_frecency
                        ON places(profile_id, visit_count DESC, last_visited_at_ms DESC);

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
                    """)
            }

            // 3. Rebuild `favorites` for composite `UNIQUE(profile_id, url_key)`
            if migrationOK && !tableHasColumn(db, table: "favorites", column: "profile_id") {
                migrationOK = exec(db, sql: """
                    DROP TABLE IF EXISTS favorites_v4;
                    CREATE TABLE favorites_v4 (
                        id TEXT PRIMARY KEY NOT NULL,
                        profile_id TEXT NOT NULL DEFAULT '\(defaultID)' REFERENCES profiles(id) ON DELETE CASCADE,
                        folder_id TEXT REFERENCES favorite_folders(id) ON DELETE SET NULL,
                        title TEXT NOT NULL,
                        url_key TEXT NOT NULL,
                        url TEXT NOT NULL,
                        symbol_name TEXT NOT NULL DEFAULT 'globe',
                        sort_order REAL NOT NULL,
                        created_at_ms INTEGER NOT NULL,
                        UNIQUE(profile_id, url_key)
                    );
                    INSERT INTO favorites_v4 (id, profile_id, folder_id, title, url_key, url, symbol_name, sort_order, created_at_ms)
                    SELECT id, '\(defaultID)', folder_id, title, url_key, url, symbol_name, sort_order, created_at_ms FROM favorites;

                    DROP TABLE favorites;
                    ALTER TABLE favorites_v4 RENAME TO favorites;

                    CREATE INDEX IF NOT EXISTS idx_favorites_folder_order
                        ON favorites(folder_id, sort_order ASC);
                    CREATE INDEX IF NOT EXISTS idx_favorites_profile_folder_order
                        ON favorites(profile_id, folder_id, sort_order ASC);
                    """)
            }

            // 4. Rebuild `site_rules` for composite `PRIMARY KEY (profile_id, host)`
            if migrationOK && !tableHasColumn(db, table: "site_rules", column: "profile_id") {
                migrationOK = exec(db, sql: """
                    DROP TABLE IF EXISTS site_rules_v4;
                    CREATE TABLE site_rules_v4 (
                        profile_id TEXT NOT NULL DEFAULT '\(defaultID)' REFERENCES profiles(id) ON DELETE CASCADE,
                        host TEXT NOT NULL,
                        shield_mode INTEGER NOT NULL DEFAULT 0,
                        dark_mode INTEGER NOT NULL DEFAULT 0,
                        ua_mode INTEGER NOT NULL DEFAULT 0,
                        page_zoom REAL,
                        updated_at_ms INTEGER NOT NULL,
                        PRIMARY KEY (profile_id, host)
                    );
                    INSERT INTO site_rules_v4 (profile_id, host, shield_mode, dark_mode, ua_mode, page_zoom, updated_at_ms)
                    SELECT '\(defaultID)', host, shield_mode, dark_mode, ua_mode, page_zoom, updated_at_ms FROM site_rules;

                    DROP TABLE site_rules;
                    ALTER TABLE site_rules_v4 RENAME TO site_rules;
                    """)
            }

            // 5. Fold legacy global bypassed hosts into Default Profile's `site_rules` without overwriting explicit rules.
            if migrationOK {
                migrateLegacyBypassedHostsIntoDefaultProfile(db)
                migrationOK = exec(db, sql: "PRAGMA user_version = 4; COMMIT;")
            }
            if !migrationOK {
                _ = exec(db, sql: "ROLLBACK;")
            } else {
                clearLegacyBypassedHostsDefaults()
            }
            _ = exec(db, sql: "PRAGMA foreign_keys = ON;")
        }

        // Idempotent self-heal for any pre-release v4 database created before `history_visits.profile_id`.
        if !tableHasColumn(db, table: "history_visits", column: "profile_id") {
            let ok = exec(db, sql: """
                BEGIN IMMEDIATE TRANSACTION;
                ALTER TABLE history_visits ADD COLUMN profile_id TEXT NOT NULL DEFAULT '\(defaultID)';
                UPDATE history_visits
                SET profile_id = COALESCE(
                    (SELECT p.profile_id FROM places p WHERE p.id = history_visits.place_id),
                    '\(defaultID)'
                );
                CREATE INDEX IF NOT EXISTS idx_visits_profile_day_time
                    ON history_visits(profile_id, day_ymd DESC, visited_at_ms DESC);
                CREATE INDEX IF NOT EXISTS idx_visits_profile_time
                    ON history_visits(profile_id, visited_at_ms DESC);
                COMMIT;
                """)
            if !ok {
                _ = exec(db, sql: "ROLLBACK;")
            }
        }
        seedDefaultProfileIfMissing(db)
    }

    private static func seedDefaultProfileIfMissing(_ db: OpaquePointer) {
        let profile = BrowserProfile.makeDefaultProfile()
        let sql = """
            INSERT OR IGNORE INTO profiles (
                id, name, symbol_name, palette_preset, is_default, webkit_store_id,
                fingerprint_seed, ua_profile, search_engine, custom_search_template,
                sort_order, created_at_ms
            ) VALUES (?1, ?2, ?3, ?4, 1, NULL, ?5, ?6, ?7, ?8, 0.0, ?9);
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bindText(stmt, index: 1, value: profile.id)
            bindText(stmt, index: 2, value: profile.name)
            bindText(stmt, index: 3, value: profile.symbolName)
            bindText(stmt, index: 4, value: profile.palettePreset.rawValue)
            bindText(stmt, index: 5, value: profile.fingerprintSeed)
            bindText(stmt, index: 6, value: profile.userAgentProfile.rawValue)
            bindText(stmt, index: 7, value: profile.searchEngine.rawValue)
            bindText(stmt, index: 8, value: profile.customSearchTemplate)
            sqlite3_bind_int64(stmt, 9, epochMilliseconds(profile.createdAt))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private static func migrateLegacyBypassedHostsIntoDefaultProfile(_ db: OpaquePointer) {
        let defaults = LiveContainerEnvironment.sharedDefaults
        let nowMs = epochMilliseconds(Date())
        let defaultID = BrowserProfile.defaultID

        let shieldBypassed = defaults.stringArray(forKey: "dysprosium.filters.bypassedHosts")
            ?? UserDefaults.standard.stringArray(forKey: "dysprosium.filters.bypassedHosts")
            ?? []
        for rawHost in shieldBypassed {
            let host = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
            guard !host.isEmpty else { continue }
            let sql = """
                INSERT INTO site_rules (profile_id, host, shield_mode, dark_mode, ua_mode, page_zoom, updated_at_ms)
                VALUES (?1, ?2, -1, 0, 0, NULL, ?3)
                ON CONFLICT(profile_id, host) DO UPDATE SET
                    shield_mode = CASE WHEN site_rules.shield_mode = 0 THEN -1 ELSE site_rules.shield_mode END,
                    updated_at_ms = excluded.updated_at_ms;
                """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, index: 1, value: defaultID)
                bindText(stmt, index: 2, value: host)
                sqlite3_bind_int64(stmt, 3, nowMs)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        let darkBypassed = defaults.stringArray(forKey: "dysprosium.autoDark.bypassedHosts")
            ?? UserDefaults.standard.stringArray(forKey: "dysprosium.autoDark.bypassedHosts")
            ?? []
        for rawHost in darkBypassed {
            let host = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
            guard !host.isEmpty else { continue }
            let sql = """
                INSERT INTO site_rules (profile_id, host, shield_mode, dark_mode, ua_mode, page_zoom, updated_at_ms)
                VALUES (?1, ?2, 0, -1, 0, NULL, ?3)
                ON CONFLICT(profile_id, host) DO UPDATE SET
                    dark_mode = CASE WHEN site_rules.dark_mode = 0 THEN -1 ELSE site_rules.dark_mode END,
                    updated_at_ms = excluded.updated_at_ms;
                """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, index: 1, value: defaultID)
                bindText(stmt, index: 2, value: host)
                sqlite3_bind_int64(stmt, 3, nowMs)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    private static func clearLegacyBypassedHostsDefaults() {
        let keys = ["dysprosium.filters.bypassedHosts", "dysprosium.autoDark.bypassedHosts"]
        let shared = LiveContainerEnvironment.sharedDefaults
        for key in keys {
            shared.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Browser Profiles (`profiles`)

    public func loadProfiles() -> [BrowserProfile] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [BrowserProfile.makeDefaultProfile()] }
        return loadProfilesLocked(db)
    }

    private func loadProfilesLocked(_ db: OpaquePointer) -> [BrowserProfile] {
        let sql = """
            SELECT id, name, symbol_name, palette_preset, is_default, webkit_store_id,
                   fingerprint_seed, ua_profile, search_engine, custom_search_template,
                   sort_order, created_at_ms
            FROM profiles
            ORDER BY is_default DESC, sort_order ASC, created_at_ms ASC;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return [BrowserProfile.makeDefaultProfile()]
        }
        var results: [BrowserProfile] = []
        var repairedStoreIDs: [(profileID: String, storeID: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Self.columnText(stmt, index: 0)
            let name = Self.columnText(stmt, index: 1)
            let symbol = Self.columnText(stmt, index: 2)
            let palette = DysprosiumPalettePreset(rawValue: Self.columnText(stmt, index: 3)) ?? .cerulean
            let isDefault = sqlite3_column_int(stmt, 4) != 0
            let storeIDStr = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Self.columnText(stmt, index: 5)
            let parsedStoreUUID = storeIDStr.flatMap(UUID.init(uuidString:))
            let seed = Self.columnText(stmt, index: 6)
            let ua = BrowserUserAgentProfile(rawValue: Self.columnText(stmt, index: 7)) ?? .iosSafari
            let search = BrowserSearchEngine(rawValue: Self.columnText(stmt, index: 8)) ?? .duckDuckGo
            let template = Self.columnText(stmt, index: 9)
            let sortOrder = sqlite3_column_double(stmt, 10)
            let createdMs = sqlite3_column_int64(stmt, 11)
            let profile = BrowserProfile(
                id: id,
                name: name,
                symbolName: symbol,
                palettePreset: palette,
                isDefault: isDefault,
                webkitStoreID: isDefault ? nil : parsedStoreUUID,
                fingerprintSeed: seed,
                userAgentProfile: ua,
                searchEngine: search,
                customSearchTemplate: template,
                sortOrder: sortOrder,
                createdAt: Date(timeIntervalSince1970: Double(createdMs) / 1000.0)
            )
            if !isDefault && parsedStoreUUID == nil, let repaired = profile.webkitStoreID?.uuidString {
                repairedStoreIDs.append((id, repaired))
            }
            results.append(profile)
        }
        for repair in repairedStoreIDs {
            var fixStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE profiles SET webkit_store_id = ?1 WHERE id = ?2 AND is_default = 0;", -1, &fixStmt, nil) == SQLITE_OK {
                Self.bindText(fixStmt, index: 1, value: repair.storeID)
                Self.bindText(fixStmt, index: 2, value: repair.profileID)
                _ = sqlite3_step(fixStmt)
            }
            sqlite3_finalize(fixStmt)
        }
        if results.isEmpty {
            Self.seedDefaultProfileIfMissing(db)
            return [BrowserProfile.makeDefaultProfile()]
        }
        return results
    }

    public func upsertProfile(_ profile: BrowserProfile, checkpoint: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        let sql = """
            INSERT INTO profiles (
                id, name, symbol_name, palette_preset, is_default, webkit_store_id,
                fingerprint_seed, ua_profile, search_engine, custom_search_template,
                sort_order, created_at_ms
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                symbol_name = excluded.symbol_name,
                palette_preset = excluded.palette_preset,
                fingerprint_seed = excluded.fingerprint_seed,
                ua_profile = excluded.ua_profile,
                search_engine = excluded.search_engine,
                custom_search_template = excluded.custom_search_template,
                sort_order = excluded.sort_order;
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: profile.id)
            Self.bindText(stmt, index: 2, value: BrowserProfile.sanitizedName(profile.name))
            Self.bindText(stmt, index: 3, value: profile.symbolName)
            Self.bindText(stmt, index: 4, value: profile.palettePreset.rawValue)
            sqlite3_bind_int(stmt, 5, profile.isDefault ? 1 : 0)
            Self.bindOptionalText(stmt, index: 6, value: profile.isDefault ? nil : profile.webkitStoreID?.uuidString)
            Self.bindText(stmt, index: 7, value: profile.fingerprintSeed)
            Self.bindText(stmt, index: 8, value: profile.userAgentProfile.rawValue)
            Self.bindText(stmt, index: 9, value: profile.searchEngine.rawValue)
            Self.bindText(stmt, index: 10, value: profile.customSearchTemplate)
            sqlite3_bind_double(stmt, 11, profile.sortOrder)
            sqlite3_bind_int64(stmt, 12, Self.epochMilliseconds(profile.createdAt))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        if checkpoint {
            _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            ensureWALSidecarProtectionLocked(force: true)
        } else {
            ensureWALSidecarProtectionLocked()
        }
    }

    public func deleteProfile(id: String) {
        guard id != BrowserProfile.defaultID else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }

        Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        let deleteStatements = [
            "DELETE FROM open_tabs WHERE profile_id = ?1;",
            "DELETE FROM favorites WHERE profile_id = ?1;",
            "DELETE FROM favorite_folders WHERE profile_id = ?1;",
            "DELETE FROM site_rules WHERE profile_id = ?1;",
            "DELETE FROM places WHERE profile_id = ?1;",
            "DELETE FROM profiles WHERE id = ?1 AND is_default = 0;"
        ]
        for sql in deleteStatements {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                Self.bindText(stmt, index: 1, value: id)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        Self.exec(db, sql: "COMMIT;")
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
        writeFavoritesBackupMirrorLocked(db)
    }

    public func copyFavorites(fromProfileID sourceProfileID: String, toProfileID destinationProfileID: String) {
        guard sourceProfileID != destinationProfileID else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }

        let sourceFolders = loadFoldersLocked(db, profileID: sourceProfileID)
        let sourceBookmarks = loadBookmarksLocked(db, profileID: sourceProfileID)
        guard !sourceFolders.isEmpty || !sourceBookmarks.isEmpty else { return }

        var idMap: [String: String] = [:]
        for folder in sourceFolders {
            idMap[folder.id] = UUID().uuidString
        }

        // Insert folders parents-first so self-referencing `parent_id` FK always resolves cleanly.
        var remaining = sourceFolders
        var insertedIDs: Set<String> = []
        Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        var progress = true
        while !remaining.isEmpty && progress {
            progress = false
            var deferred: [BrowserFavoriteFolder] = []
            for folder in remaining {
                if let parentID = folder.parentID, idMap[parentID] != nil, !insertedIDs.contains(parentID) {
                    deferred.append(folder)
                    continue
                }
                let newID = idMap[folder.id] ?? UUID().uuidString
                let newParentID = folder.parentID.flatMap { idMap[$0] }
                let sql = """
                    INSERT INTO favorite_folders (id, profile_id, parent_id, title, sort_order, created_at_ms)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6);
                    """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    Self.bindText(stmt, index: 1, value: newID)
                    Self.bindText(stmt, index: 2, value: destinationProfileID)
                    Self.bindOptionalText(stmt, index: 3, value: newParentID)
                    Self.bindText(stmt, index: 4, value: folder.title)
                    sqlite3_bind_double(stmt, 5, folder.sortOrder)
                    sqlite3_bind_int64(stmt, 6, Self.epochMilliseconds(folder.createdAt))
                    _ = sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
                insertedIDs.insert(folder.id)
                progress = true
            }
            remaining = deferred
        }

        let nowMs = Self.epochMilliseconds(Date())
        for bm in sourceBookmarks {
            let newFolderID = bm.folderID.flatMap { insertedIDs.contains($0) ? idMap[$0] : nil }
            let sql = """
                INSERT OR IGNORE INTO favorites (id, profile_id, folder_id, title, url_key, url, symbol_name, sort_order, created_at_ms)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
                """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                Self.bindText(stmt, index: 1, value: UUID().uuidString)
                Self.bindText(stmt, index: 2, value: destinationProfileID)
                Self.bindOptionalText(stmt, index: 3, value: newFolderID)
                Self.bindText(stmt, index: 4, value: bm.title)
                Self.bindText(stmt, index: 5, value: Self.normalizeURLKey(bm.urlString))
                Self.bindText(stmt, index: 6, value: bm.urlString)
                Self.bindText(stmt, index: 7, value: bm.symbolName)
                sqlite3_bind_double(stmt, 8, bm.sortOrder)
                sqlite3_bind_int64(stmt, 9, nowMs)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        Self.exec(db, sql: "COMMIT;")
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
        writeFavoritesBackupMirrorLocked(db)
    }

    public func bookmarkCount(profileID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM favorites WHERE profile_id = ?1;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        Self.bindText(stmt, index: 1, value: profileID)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    public func bookmarkCountsByProfile() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [:] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT profile_id, COUNT(*) FROM favorites GROUP BY profile_id;", -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        var counts: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            counts[Self.columnText(stmt, index: 0)] = Int(sqlite3_column_int64(stmt, 1))
        }
        return counts
    }

    /// Returns all normalized hosts still referenced by bookmarks or history in profiles other than `excludingProfileID`.
    public func allReferencedHosts(excludingProfileID: String? = nil) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }
        var hosts: Set<String> = []
        let queries: [String]
        if excludingProfileID != nil {
            queries = [
                "SELECT DISTINCT host FROM places WHERE profile_id != ?1;",
                "SELECT DISTINCT url FROM favorites WHERE profile_id != ?1;"
            ]
        } else {
            queries = [
                "SELECT DISTINCT host FROM places;",
                "SELECT DISTINCT url FROM favorites;"
            ]
        }
        for (idx, sql) in queries.enumerated() {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if let excludingProfileID {
                    Self.bindText(stmt, index: 1, value: excludingProfileID)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let raw = Self.columnText(stmt, index: 0)
                    let hostStr = idx == 0 ? raw : (URL(string: raw)?.host() ?? raw)
                    let norm = LiveContainerEnvironment.HostNormalizer.normalize(hostStr)
                    if !norm.isEmpty {
                        hosts.insert(norm)
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        return hosts
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

    public func recordVisit(
        url: URL,
        title: String,
        visitedAt: Date = Date(),
        profileID: String = BrowserProfile.defaultID
    ) {
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
            profileID: profileID,
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
            pruneOverflowLocked(db, profileID: profileID)
        }
        Self.exec(db, sql: "COMMIT;")
        ensureWALSidecarProtectionLocked()
    }

    public func bulkInsertHistory(
        _ entries: [BrowserHistoryEntry],
        profileID: String = BrowserProfile.defaultID
    ) {
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
                profileID: profileID,
                visitID: entry.id,
                urlKey: urlKey,
                urlStr: entry.urlString,
                host: host,
                title: effectiveTitle,
                dayYMD: Self.calendarDayYMD(for: entry.visitedAt),
                visitedMs: Self.epochMilliseconds(entry.visitedAt)
            )
        }
        pruneOverflowLocked(db, profileID: profileID)
        Self.exec(db, sql: "COMMIT;")
        ensureWALSidecarProtectionLocked()
    }

    private func upsertVisitLocked(
        db: OpaquePointer,
        profileID: String,
        visitID: String,
        urlKey: String,
        urlStr: String,
        host: String,
        title: String,
        dayYMD: Int64,
        visitedMs: Int64
    ) {
        let placeSQL = """
            INSERT INTO places (profile_id, url_key, url, host, title, visit_count, last_visited_at_ms)
            VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6)
            ON CONFLICT(profile_id, url_key) DO UPDATE SET
                url = excluded.url,
                host = excluded.host,
                title = CASE WHEN excluded.last_visited_at_ms >= places.last_visited_at_ms THEN excluded.title ELSE places.title END,
                visit_count = places.visit_count + 1,
                last_visited_at_ms = MAX(places.last_visited_at_ms, excluded.last_visited_at_ms);
            """
        var pStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, placeSQL, -1, &pStmt, nil) == SQLITE_OK {
            Self.bindText(pStmt, index: 1, value: profileID)
            Self.bindText(pStmt, index: 2, value: urlKey)
            Self.bindText(pStmt, index: 3, value: urlStr)
            Self.bindText(pStmt, index: 4, value: host)
            Self.bindText(pStmt, index: 5, value: title)
            sqlite3_bind_int64(pStmt, 6, visitedMs)
            _ = sqlite3_step(pStmt)
        }
        sqlite3_finalize(pStmt)

        var idStmt: OpaquePointer?
        var placeID: Int64 = 0
        if sqlite3_prepare_v2(db, "SELECT id FROM places WHERE profile_id = ?1 AND url_key = ?2;", -1, &idStmt, nil) == SQLITE_OK {
            Self.bindText(idStmt, index: 1, value: profileID)
            Self.bindText(idStmt, index: 2, value: urlKey)
            if sqlite3_step(idStmt) == SQLITE_ROW {
                placeID = sqlite3_column_int64(idStmt, 0)
            }
        }
        sqlite3_finalize(idStmt)
        guard placeID > 0 else { return }

        let visitSQL = """
            INSERT INTO history_visits (id, place_id, profile_id, day_ymd, visited_at_ms)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(day_ymd, place_id) DO UPDATE SET
                profile_id = excluded.profile_id,
                visited_at_ms = MAX(history_visits.visited_at_ms, excluded.visited_at_ms);
            """
        var vStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, visitSQL, -1, &vStmt, nil) == SQLITE_OK {
            Self.bindText(vStmt, index: 1, value: visitID)
            sqlite3_bind_int64(vStmt, 2, placeID)
            Self.bindText(vStmt, index: 3, value: profileID)
            sqlite3_bind_int64(vStmt, 4, dayYMD)
            sqlite3_bind_int64(vStmt, 5, visitedMs)
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

    public func clearDay(dayYMD: Int64, profileID: String = BrowserProfile.defaultID) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM history_visits WHERE profile_id = ?1 AND day_ymd = ?2;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: profileID)
            sqlite3_bind_int64(stmt, 2, dayYMD)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        ensureWALSidecarProtectionLocked()
    }

    public func clearAll(profileID: String = BrowserProfile.defaultID) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        // Deleting `places` for this profile cascades into `history_visits` via `ON DELETE CASCADE`
        // and updates `places_fts` via `trg_places_ad` without touching other profiles' history.
        Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM places WHERE profile_id = ?1;", -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: profileID)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        Self.exec(db, sql: "COMMIT;")
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
    }

    public func clearEntries(
        since cutoff: Date,
        until endCutoff: Date? = nil,
        profileID: String = BrowserProfile.defaultID
    ) {
        if cutoff <= .distantPast && endCutoff == nil {
            clearAll(profileID: profileID)
            return
        }
        let startMs = Self.epochMilliseconds(cutoff)
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        var stmt: OpaquePointer?
        if let endCutoff {
            let endMs = Self.epochMilliseconds(endCutoff)
            let sql = """
                DELETE FROM history_visits
                WHERE profile_id = ?1 AND visited_at_ms >= ?2 AND visited_at_ms < ?3;
                """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                Self.bindText(stmt, index: 1, value: profileID)
                sqlite3_bind_int64(stmt, 2, startMs)
                sqlite3_bind_int64(stmt, 3, endMs)
                _ = sqlite3_step(stmt)
            }
        } else {
            let sql = """
                DELETE FROM history_visits
                WHERE profile_id = ?1 AND visited_at_ms >= ?2;
                """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                Self.bindText(stmt, index: 1, value: profileID)
                sqlite3_bind_int64(stmt, 2, startMs)
                _ = sqlite3_step(stmt)
            }
        }
        sqlite3_finalize(stmt)
        ensureWALSidecarProtectionLocked()
    }

    // MARK: - History Read Path (`FTS5 trigram` + Covering Index Day Aggregation + Frecency)

    public func totalCount(profileID: String = BrowserProfile.defaultID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COUNT(*) FROM history_visits WHERE profile_id = ?1;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: profileID)
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int64(stmt, 0))
            }
        }
        return 0
    }

    public func earliestVisitDate(profileID: String = BrowserProfile.defaultID) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        // Uses `idx_visits_profile_time` directly (`O(1)` reverse index lookup).
        let sql = "SELECT MIN(visited_at_ms) FROM history_visits WHERE profile_id = ?1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        Self.bindText(stmt, index: 1, value: profileID)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
            return nil
        }
        let ms = sqlite3_column_int64(stmt, 0)
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    public func countEntries(
        since cutoff: Date,
        until endCutoff: Date? = nil,
        profileID: String = BrowserProfile.defaultID
    ) -> Int {
        if cutoff <= .distantPast && endCutoff == nil {
            return totalCount(profileID: profileID)
        }
        let startMs = Self.epochMilliseconds(cutoff)
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if let endCutoff {
            let endMs = Self.epochMilliseconds(endCutoff)
            let sql = """
                SELECT COUNT(*)
                FROM history_visits
                WHERE profile_id = ?1 AND visited_at_ms >= ?2 AND visited_at_ms < ?3;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            Self.bindText(stmt, index: 1, value: profileID)
            sqlite3_bind_int64(stmt, 2, startMs)
            sqlite3_bind_int64(stmt, 3, endMs)
        } else {
            let sql = """
                SELECT COUNT(*)
                FROM history_visits
                WHERE profile_id = ?1 AND visited_at_ms >= ?2;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            Self.bindText(stmt, index: 1, value: profileID)
            sqlite3_bind_int64(stmt, 2, startMs)
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
        maxDays: Int = 90,
        profileID: String = BrowserProfile.defaultID
    ) -> [BrowserHistoryDaySummary] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }

        var clauses: [String] = ["v.profile_id = ?1"]
        if let startDate {
            clauses.append("v.visited_at_ms >= \(Self.epochMilliseconds(startDate))")
        }
        if let endDate {
            clauses.append("v.visited_at_ms < \(Self.epochMilliseconds(endDate))")
        }

        let useFTS = trimmed.unicodeScalars.count >= 3
        let needsPlacesJoin = !trimmed.isEmpty && !useFTS
        if !trimmed.isEmpty {
            if useFTS {
                clauses.append("v.place_id IN (SELECT rowid FROM places_fts WHERE places_fts MATCH ?2)")
            } else {
                clauses.append("(instr(lower(p.title), ?2) > 0 OR instr(lower(p.url), ?2) > 0)")
            }
        }

        let whereSQL = "WHERE " + clauses.joined(separator: " AND ")
        let limitIdx: Int32 = trimmed.isEmpty ? 2 : 3
        let joinSQL = needsPlacesJoin ? "JOIN places p ON p.id = v.place_id" : ""

        // Covered directly by `idx_visits_profile_day_time (profile_id, day_ymd DESC, visited_at_ms DESC)`
        // with zero temp B-tree sort or `places` table scan when unfiltered.
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

        Self.bindText(stmt, index: 1, value: profileID)
        if !trimmed.isEmpty {
            let param = useFTS ? Self.ftsPhraseLiteral(trimmed) : trimmed.lowercased()
            Self.bindText(stmt, index: 2, value: param)
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
            if ymd == todayYMD {
                results.append(
                    BrowserHistoryDaySummary(
                        dayYMD: ymd,
                        dayStart: dayDate,
                        displayTitle: "Today",
                        chipTitle: "Today",
                        count: cnt
                    )
                )
            } else if ymd == yesterdayYMD {
                results.append(
                    BrowserHistoryDaySummary(
                        dayYMD: ymd,
                        dayStart: dayDate,
                        displayTitle: "Yesterday",
                        chipTitle: "Yesterday",
                        count: cnt
                    )
                )
            } else {
                results.append(.calendarDay(dayYMD: ymd, dayStart: dayDate, count: cnt))
            }
        }
        return results
    }

    public func queryEntriesPage(
        searchQuery rawQuery: String = "",
        dayYMD: Int64? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        limit: Int = 80,
        offset: Int = 0,
        profileID: String = BrowserProfile.defaultID
    ) -> [BrowserHistoryEntry] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }

        var clauses: [String] = ["v.profile_id = ?1"]
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
                clauses.append("v.place_id IN (SELECT rowid FROM places_fts WHERE places_fts MATCH ?2)")
            } else {
                clauses.append("(instr(lower(p.title), ?2) > 0 OR instr(lower(p.url), ?2) > 0)")
            }
        }

        let whereSQL = "WHERE " + clauses.joined(separator: " AND ")
        let limitIdx: Int32 = trimmed.isEmpty ? 2 : 3
        let offsetIdx: Int32 = trimmed.isEmpty ? 3 : 4

        // Driven by `idx_visits_profile_day_time (profile_id, day_ymd DESC, visited_at_ms DESC)`:
        // O(limit) index walk + PK lookup into `places`, zero temp B-tree sort.
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

        Self.bindText(stmt, index: 1, value: profileID)
        if !trimmed.isEmpty {
            let param = useFTS ? Self.ftsPhraseLiteral(trimmed) : trimmed.lowercased()
            Self.bindText(stmt, index: 2, value: param)
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
    public func queryTopPlaces(
        matching rawQuery: String,
        limit: Int = 8,
        profileID: String = BrowserProfile.defaultID
    ) -> [(url: String, title: String, visitCount: Int)] {
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
                WHERE profile_id = ?1
                  AND id IN (SELECT rowid FROM places_fts WHERE places_fts MATCH ?2)
                ORDER BY visit_count DESC, last_visited_at_ms DESC
                LIMIT ?3;
                """
        } else {
            sql = """
                SELECT url, title, visit_count
                FROM places
                WHERE profile_id = ?1
                  AND (instr(lower(title), ?2) > 0 OR instr(lower(url), ?2) > 0)
                ORDER BY visit_count DESC, last_visited_at_ms DESC
                LIMIT ?3;
                """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        Self.bindText(stmt, index: 1, value: profileID)
        let param = useFTS ? Self.ftsPhraseLiteral(trimmed) : trimmed.lowercased()
        Self.bindText(stmt, index: 2, value: param)
        sqlite3_bind_int(stmt, 3, Int32(max(1, limit)))

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

    public func loadFolders(profileID: String = BrowserProfile.defaultID) -> [BrowserFavoriteFolder] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }
        return loadFoldersLocked(db, profileID: profileID)
    }

    public func upsertFolder(_ folder: BrowserFavoriteFolder, profileID: String = BrowserProfile.defaultID) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        upsertFolderLocked(db, folder: folder, profileID: profileID)
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
        writeFavoritesBackupMirrorLocked(db)
    }

    private func upsertFolderLocked(_ db: OpaquePointer, folder: BrowserFavoriteFolder, profileID: String) {
        let sql = """
            INSERT INTO favorite_folders (id, profile_id, parent_id, title, sort_order, created_at_ms)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(id) DO UPDATE SET
                parent_id = excluded.parent_id,
                title = excluded.title,
                sort_order = excluded.sort_order
            WHERE favorite_folders.profile_id = excluded.profile_id;
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: folder.id)
            Self.bindText(stmt, index: 2, value: profileID)
            Self.bindOptionalText(stmt, index: 3, value: folder.parentID)
            Self.bindText(stmt, index: 4, value: folder.title)
            sqlite3_bind_double(stmt, 5, folder.sortOrder)
            sqlite3_bind_int64(stmt, 6, Self.epochMilliseconds(folder.createdAt))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    public func deleteFolder(id: String, keepBookmarks: Bool, profileID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        if !keepBookmarks {
            var delBm: OpaquePointer?
            let bmSQL = profileID != nil
                ? "DELETE FROM favorites WHERE folder_id = ?1 AND profile_id = ?2;"
                : "DELETE FROM favorites WHERE folder_id = ?1;"
            if sqlite3_prepare_v2(db, bmSQL, -1, &delBm, nil) == SQLITE_OK {
                Self.bindText(delBm, index: 1, value: id)
                if let profileID {
                    Self.bindText(delBm, index: 2, value: profileID)
                }
                _ = sqlite3_step(delBm)
            }
            sqlite3_finalize(delBm)
        }
        // When `keepBookmarks == true`, `ON DELETE SET NULL` automatically moves bookmarks back to Root (`folder_id = NULL`).
        var delFolder: OpaquePointer?
        let folderSQL = profileID != nil
            ? "DELETE FROM favorite_folders WHERE id = ?1 AND profile_id = ?2;"
            : "DELETE FROM favorite_folders WHERE id = ?1;"
        if sqlite3_prepare_v2(db, folderSQL, -1, &delFolder, nil) == SQLITE_OK {
            Self.bindText(delFolder, index: 1, value: id)
            if let profileID {
                Self.bindText(delFolder, index: 2, value: profileID)
            }
            _ = sqlite3_step(delFolder)
        }
        sqlite3_finalize(delFolder)
        Self.exec(db, sql: "COMMIT;")
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
        writeFavoritesBackupMirrorLocked(db)
    }

    public func loadBookmarks(profileID: String = BrowserProfile.defaultID) -> [BrowserBookmark] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }
        return loadBookmarksLocked(db, profileID: profileID)
    }

    public func upsertBookmark(_ bm: BrowserBookmark, profileID: String = BrowserProfile.defaultID) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        upsertBookmarkLocked(db, bm: bm, profileID: profileID)
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
        writeFavoritesBackupMirrorLocked(db)
    }

    private func upsertBookmarkLocked(_ db: OpaquePointer, bm: BrowserBookmark, profileID: String) {
        let urlKey = Self.normalizeURLKey(bm.urlString)
        let sql = """
            INSERT INTO favorites (id, profile_id, folder_id, title, url_key, url, symbol_name, sort_order, created_at_ms)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            ON CONFLICT(profile_id, url_key) DO UPDATE SET
                folder_id = excluded.folder_id,
                title = excluded.title,
                url = excluded.url,
                symbol_name = excluded.symbol_name,
                sort_order = excluded.sort_order;
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: bm.id)
            Self.bindText(stmt, index: 2, value: profileID)
            Self.bindOptionalText(stmt, index: 3, value: bm.folderID)
            Self.bindText(stmt, index: 4, value: bm.title)
            Self.bindText(stmt, index: 5, value: urlKey)
            Self.bindText(stmt, index: 6, value: bm.urlString)
            Self.bindText(stmt, index: 7, value: bm.symbolName)
            sqlite3_bind_double(stmt, 8, bm.sortOrder)
            sqlite3_bind_int64(stmt, 9, Self.epochMilliseconds(Date()))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    public func deleteBookmark(id: String, profileID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        var stmt: OpaquePointer?
        let sql = profileID != nil
            ? "DELETE FROM favorites WHERE id = ?1 AND profile_id = ?2;"
            : "DELETE FROM favorites WHERE id = ?1;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: id)
            if let profileID {
                Self.bindText(stmt, index: 2, value: profileID)
            }
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
        writeFavoritesBackupMirrorLocked(db)
    }

    /// Batch-imports folders (parents-first so `FOREIGN KEY(parent_id)` never fails) and bookmarks
    /// inside a single transaction with one WAL checkpoint and one backup mirror write.
    public func importFavoritesBatch(
        folders: [BrowserFavoriteFolder],
        bookmarks: [BrowserBookmark],
        profileID: String
    ) {
        guard !folders.isEmpty || !bookmarks.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        insertFavoritesHierarchyLocked(db, folders: folders, bookmarks: bookmarks, profileID: profileID)
        Self.exec(db, sql: "COMMIT;")
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        ensureWALSidecarProtectionLocked(force: true)
        writeFavoritesBackupMirrorLocked(db)
    }

    private func insertFavoritesHierarchyLocked(
        _ db: OpaquePointer,
        folders: [BrowserFavoriteFolder],
        bookmarks: [BrowserBookmark],
        profileID: String
    ) {
        let existingFolderIDs = Set(loadFoldersLocked(db, profileID: profileID).map(\.id))
        let batchFolderIDs = Set(folders.map(\.id))
        var insertedIDs = existingFolderIDs
        var remaining = folders
        var progress = true
        while !remaining.isEmpty && progress {
            progress = false
            var deferred: [BrowserFavoriteFolder] = []
            for var folder in remaining {
                if let parentID = folder.parentID {
                    if insertedIDs.contains(parentID) {
                        // Ready to insert.
                    } else if batchFolderIDs.contains(parentID) {
                        deferred.append(folder)
                        continue
                    } else {
                        folder.parentID = nil
                    }
                }
                upsertFolderLocked(db, folder: folder, profileID: profileID)
                insertedIDs.insert(folder.id)
                progress = true
            }
            remaining = deferred
        }

        for var bm in bookmarks {
            if let fID = bm.folderID, !insertedIDs.contains(fID) {
                bm.folderID = nil
            }
            upsertBookmarkLocked(db, bm: bm, profileID: profileID)
        }
    }

    private func loadFoldersLocked(_ db: OpaquePointer, profileID: String) -> [BrowserFavoriteFolder] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id, parent_id, title, sort_order, created_at_ms FROM favorite_folders WHERE profile_id = ?1 ORDER BY sort_order ASC, created_at_ms ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        Self.bindText(stmt, index: 1, value: profileID)
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

    private func loadBookmarksLocked(_ db: OpaquePointer, profileID: String) -> [BrowserBookmark] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id, folder_id, title, url, symbol_name, sort_order FROM favorites WHERE profile_id = ?1 ORDER BY sort_order ASC, created_at_ms ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        Self.bindText(stmt, index: 1, value: profileID)
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
        let profiles = loadProfilesLocked(db)
        var buckets: [String: ProfileFavoritesBucket] = [:]
        for profile in profiles {
            let folders = loadFoldersLocked(db, profileID: profile.id)
            let bookmarks = loadBookmarksLocked(db, profileID: profile.id)
            if !folders.isEmpty || !bookmarks.isEmpty {
                buckets[profile.id] = ProfileFavoritesBucket(folders: folders, bookmarks: bookmarks)
            }
        }
        let snapshot = FavoritesBackupSnapshotV2(version: 2, profiles: buckets)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: favoritesBackupURL, options: .atomic)
        }
    }

    private func restoreFavoritesFromBackupMirrorIfDatabaseEmpty() {
        let allProfiles = loadProfiles()
        let hasAnyExisting = allProfiles.contains {
            !loadFolders(profileID: $0.id).isEmpty || !loadBookmarks(profileID: $0.id).isEmpty
        }
        if hasAnyExisting {
            // Avoid rewriting `favorites_backup.json` on every cold launch unless the mirror is missing.
            if !FileManager.default.fileExists(atPath: favoritesBackupURL.path) {
                lock.lock()
                if let db { writeFavoritesBackupMirrorLocked(db) }
                lock.unlock()
            }
            return
        }
        guard FileManager.default.fileExists(atPath: favoritesBackupURL.path),
              let data = try? Data(contentsOf: favoritesBackupURL) else {
            return
        }
        let validProfileIDs = Set(allProfiles.map(\.id))
        if let v2 = try? JSONDecoder().decode(FavoritesBackupSnapshotV2.self, from: data),
           !v2.profiles.isEmpty {
            lock.lock()
            if let db = ensureOpenLocked() {
                Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
                for (profileID, bucket) in v2.profiles {
                    let targetProfile = validProfileIDs.contains(profileID) ? profileID : BrowserProfile.defaultID
                    insertFavoritesHierarchyLocked(
                        db,
                        folders: bucket.folders,
                        bookmarks: bucket.bookmarks,
                        profileID: targetProfile
                    )
                }
                Self.exec(db, sql: "COMMIT;")
                _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
                ensureWALSidecarProtectionLocked(force: true)
            }
            lock.unlock()
            return
        }
        if let v1 = try? JSONDecoder().decode(FavoritesBackupSnapshotV1.self, from: data),
           (!v1.folders.isEmpty || !v1.bookmarks.isEmpty) {
            importFavoritesBatch(
                folders: v1.folders,
                bookmarks: v1.bookmarks,
                profileID: BrowserProfile.defaultID
            )
        }
    }

    // MARK: - Open Standard Tabs Session Persistence (`open_tabs`)

    public func loadOpenTabs(profileID: String? = nil) -> [PersistedOpenTab] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql: String
        if profileID != nil {
            sql = "SELECT id, profile_id, url, title, sort_order, is_active FROM open_tabs WHERE profile_id = ?1 ORDER BY sort_order ASC;"
        } else {
            sql = "SELECT id, profile_id, url, title, sort_order, is_active FROM open_tabs ORDER BY profile_id ASC, sort_order ASC;"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        if let profileID {
            Self.bindText(stmt, index: 1, value: profileID)
        }

        var tabs: [PersistedOpenTab] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uuid = UUID(uuidString: Self.columnText(stmt, index: 0)) else { continue }
            let pid = Self.columnText(stmt, index: 1)
            tabs.append(
                PersistedOpenTab(
                    id: uuid,
                    profileID: pid.isEmpty ? BrowserProfile.defaultID : pid,
                    urlString: Self.columnText(stmt, index: 2),
                    title: Self.columnText(stmt, index: 3),
                    sortOrder: sqlite3_column_double(stmt, 4),
                    isActive: sqlite3_column_int(stmt, 5) != 0
                )
            )
        }
        return tabs
    }

    /// Replaces persisted open tabs strictly for `profileID` (`DELETE FROM open_tabs WHERE profile_id = ?1`),
    /// preventing sibling LiveContainer hosts or active-profile writes from clobbering dormant profiles' tabs.
    public func saveOpenTabs(_ tabs: [PersistedOpenTab], forProfileID profileID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM open_tabs WHERE profile_id = ?1;", -1, &delStmt, nil) == SQLITE_OK {
            Self.bindText(delStmt, index: 1, value: profileID)
            _ = sqlite3_step(delStmt)
        }
        sqlite3_finalize(delStmt)

        let sql = "INSERT INTO open_tabs (id, profile_id, url, title, sort_order, is_active) VALUES (?1, ?2, ?3, ?4, ?5, ?6);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for tab in tabs {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                Self.bindText(stmt, index: 1, value: tab.id.uuidString)
                Self.bindText(stmt, index: 2, value: profileID)
                Self.bindText(stmt, index: 3, value: tab.urlString)
                Self.bindText(stmt, index: 4, value: tab.title)
                sqlite3_bind_double(stmt, 5, tab.sortOrder)
                sqlite3_bind_int(stmt, 6, tab.isActive ? 1 : 0)
                _ = sqlite3_step(stmt)
            }
        }
        sqlite3_finalize(stmt)
        Self.exec(db, sql: "COMMIT;")
        ensureWALSidecarProtectionLocked()
    }

    /// Saves open tabs grouped by each tab's `profileID` (or clears Default profile when empty).
    public func saveOpenTabs(_ tabs: [PersistedOpenTab]) {
        if tabs.isEmpty {
            saveOpenTabs([], forProfileID: BrowserProfile.defaultID)
            return
        }
        let grouped = Dictionary(grouping: tabs, by: \.profileID)
        for (pid, group) in grouped {
            saveOpenTabs(group, forProfileID: pid)
        }
    }

    // MARK: - Per-Site Policy Rules (`site_rules`)

    public func loadAllSiteRules(profileID: String = BrowserProfile.defaultID) -> [SiteRuleRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT host, shield_mode, dark_mode, ua_mode, page_zoom FROM site_rules WHERE profile_id = ?1 ORDER BY host ASC;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return [] }
        Self.bindText(stmt, index: 1, value: profileID)

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

    public func siteRule(forHost rawHost: String, profileID: String = BrowserProfile.defaultID) -> SiteRuleRecord? {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
        guard !host.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT shield_mode, dark_mode, ua_mode, page_zoom FROM site_rules WHERE profile_id = ?1 AND host = ?2;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return nil }
        Self.bindText(stmt, index: 1, value: profileID)
        Self.bindText(stmt, index: 2, value: host)
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

    public func upsertSiteRule(_ rule: SiteRuleRecord, profileID: String = BrowserProfile.defaultID) {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rule.host)
        guard !host.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        if rule.isAllDefault {
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM site_rules WHERE profile_id = ?1 AND host = ?2;", -1, &delStmt, nil) == SQLITE_OK {
                Self.bindText(delStmt, index: 1, value: profileID)
                Self.bindText(delStmt, index: 2, value: host)
                _ = sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)
            ensureWALSidecarProtectionLocked()
            return
        }
        let sql = """
            INSERT INTO site_rules (profile_id, host, shield_mode, dark_mode, ua_mode, page_zoom, updated_at_ms)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(profile_id, host) DO UPDATE SET
                shield_mode = excluded.shield_mode,
                dark_mode = excluded.dark_mode,
                ua_mode = excluded.ua_mode,
                page_zoom = excluded.page_zoom,
                updated_at_ms = excluded.updated_at_ms;
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: profileID)
            Self.bindText(stmt, index: 2, value: host)
            sqlite3_bind_int(stmt, 3, Int32(rule.shieldMode))
            sqlite3_bind_int(stmt, 4, Int32(rule.darkMode))
            sqlite3_bind_int(stmt, 5, Int32(rule.uaMode))
            if let zoom = rule.pageZoom {
                sqlite3_bind_double(stmt, 6, SiteRuleRecord.clampedZoom(zoom))
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_int64(stmt, 7, Self.epochMilliseconds(Date()))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        ensureWALSidecarProtectionLocked()
    }

    public func deleteSiteRule(forHost rawHost: String, profileID: String = BrowserProfile.defaultID) {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
        guard !host.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db = ensureOpenLocked() else { return }
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM site_rules WHERE profile_id = ?1 AND host = ?2;", -1, &delStmt, nil) == SQLITE_OK {
            Self.bindText(delStmt, index: 1, value: profileID)
            Self.bindText(delStmt, index: 2, value: host)
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

    private func pruneOverflowLocked(_ db: OpaquePointer, profileID: String) {
        let sql = """
            DELETE FROM history_visits
            WHERE id IN (
                SELECT id FROM history_visits
                WHERE profile_id = ?1
                ORDER BY day_ymd DESC, visited_at_ms DESC
                LIMIT -1 OFFSET \(Self.maxRetainedVisits)
            );
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, index: 1, value: profileID)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
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

    @discardableResult
    private static func exec(_ db: OpaquePointer, sql: String) -> Bool {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK, let errMsg {
            sqlite3_free(errMsg)
        }
        return rc == SQLITE_OK
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
