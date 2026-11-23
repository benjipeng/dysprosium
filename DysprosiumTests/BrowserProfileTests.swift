import Foundation
import SQLite3
import WebKit
import XCTest
@testable import Dysprosium

final class BrowserProfileTests: XCTestCase {

    // MARK: - Scoped Test Fixtures

    private func withTemporaryStateDirectory(
        _ prefix: String,
        body: (URL) throws -> Void
    ) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        try body(tempDir)
    }

    @MainActor
    private func withTemporaryBrowserStore(
        _ prefix: String,
        body: (CleanroomBrowserStore) async throws -> Void
    ) async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let previousTheme = DysprosiumThemeStore.shared.selectedPreset
        weak var weakDB: BrowserSQLiteStore?
        defer {
            DysprosiumThemeStore.shared.select(previousTheme)
            try? fm.removeItem(at: tempDir)
        }
        do {
            let store = CleanroomBrowserStore(customStateDirectory: tempDir)
            weakDB = store.sqliteStore
            await store.waitForInitialHydration()
            try await body(store)
        }
        // Wait briefly for any trailing detached persistence tasks to drop their strong reference
        // to `BrowserSQLiteStore` so `sqlite3_close_v2` completes before `tempDir` is unlinked.
        let deadline = ContinuousClock.now + .milliseconds(500)
        while weakDB != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - 1. Atomic v3 -> v4 Migration Preserves History Visits, FTS5, Favorites, Tabs & Site Rules

    func testAtomicSchemaV3ToV4MigrationPreservesVisitsAndFTSWithoutRebuild() throws {
        try withTemporaryStateDirectory("dys-v3-migrate") { tempDir in
            let dbPath = tempDir.appendingPathComponent("browser.sqlite3").path
            var rawDB: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(dbPath, &rawDB, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
            let db = try XCTUnwrap(rawDB)

            let v3SeedSQL = """
                PRAGMA foreign_keys = ON;
                BEGIN IMMEDIATE TRANSACTION;
                CREATE TABLE places (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    url_key TEXT NOT NULL UNIQUE,
                    url TEXT NOT NULL,
                    host TEXT NOT NULL,
                    title TEXT NOT NULL,
                    visit_count INTEGER NOT NULL DEFAULT 1,
                    last_visited_at_ms INTEGER NOT NULL
                );
                CREATE VIRTUAL TABLE places_fts USING fts5(
                    title, url, content='places', content_rowid='id', tokenize='trigram case_sensitive 0'
                );
                CREATE TRIGGER trg_places_ai AFTER INSERT ON places BEGIN
                    INSERT INTO places_fts(rowid, title, url) VALUES (new.id, new.title, new.url);
                END;
                CREATE TABLE history_visits (
                    id TEXT PRIMARY KEY NOT NULL,
                    place_id INTEGER NOT NULL REFERENCES places(id) ON DELETE CASCADE,
                    day_ymd INTEGER NOT NULL,
                    visited_at_ms INTEGER NOT NULL,
                    UNIQUE(day_ymd, place_id)
                );
                CREATE TABLE favorite_folders (
                    id TEXT PRIMARY KEY NOT NULL,
                    parent_id TEXT REFERENCES favorite_folders(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    sort_order REAL NOT NULL,
                    created_at_ms INTEGER NOT NULL
                );
                CREATE TABLE favorites (
                    id TEXT PRIMARY KEY NOT NULL,
                    folder_id TEXT REFERENCES favorite_folders(id) ON DELETE SET NULL,
                    title TEXT NOT NULL,
                    url_key TEXT NOT NULL UNIQUE,
                    url TEXT NOT NULL,
                    symbol_name TEXT NOT NULL DEFAULT 'globe',
                    sort_order REAL NOT NULL,
                    created_at_ms INTEGER NOT NULL
                );
                CREATE TABLE open_tabs (
                    id TEXT PRIMARY KEY NOT NULL,
                    url TEXT NOT NULL,
                    title TEXT NOT NULL,
                    sort_order REAL NOT NULL,
                    is_active INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE site_rules (
                    host TEXT PRIMARY KEY NOT NULL,
                    shield_mode INTEGER NOT NULL DEFAULT 0,
                    dark_mode INTEGER NOT NULL DEFAULT 0,
                    ua_mode INTEGER NOT NULL DEFAULT 0,
                    page_zoom REAL,
                    updated_at_ms INTEGER NOT NULL
                );

                INSERT INTO places (id, url_key, url, host, title, visit_count, last_visited_at_ms)
                VALUES (42, 'https://webkit.org/blog', 'https://webkit.org/blog', 'webkit.org', 'WebKit Blog 引擎', 5, 1763800000000);
                INSERT INTO history_visits (id, place_id, day_ymd, visited_at_ms)
                VALUES ('visit-42', 42, 20261123, 1763800000000);
                INSERT INTO favorite_folders (id, parent_id, title, sort_order, created_at_ms)
                VALUES ('f-dev', NULL, 'Dev', 100.0, 1763800000000);
                INSERT INTO favorites (id, folder_id, title, url_key, url, symbol_name, sort_order, created_at_ms)
                VALUES ('bm-1', 'f-dev', 'Apple Docs', 'https://developer.apple.com', 'https://developer.apple.com', 'globe', 100.0, 1763800000000);
                INSERT INTO open_tabs (id, url, title, sort_order, is_active)
                VALUES ('11111111-1111-4111-8111-111111111111', 'https://webkit.org/blog', 'WebKit Blog', 100.0, 1);
                INSERT INTO site_rules (host, shield_mode, dark_mode, ua_mode, page_zoom, updated_at_ms)
                VALUES ('webkit.org', -1, 1, 2, 1.15, 1763800000000);
                PRAGMA user_version = 3;
                COMMIT;
                """
            XCTAssertEqual(sqlite3_exec(db, v3SeedSQL, nil, nil, nil), SQLITE_OK)
            sqlite3_close_v2(db)

            // Open with BrowserSQLiteStore -> executes atomic v3 -> v4 migration
            let store = BrowserSQLiteStore(stateDirectory: tempDir)
            XCTAssertEqual(store.schemaVersion, 4)

            let profiles = store.loadProfiles()
            XCTAssertEqual(profiles.count, 1)
            XCTAssertEqual(profiles[0].id, BrowserProfile.defaultID)
            XCTAssertTrue(profiles[0].isDefault)
            XCTAssertNil(profiles[0].webkitStoreID)

            // Verify zero cascade deletion of `history_visits` AND intact external-content FTS5 trigram lookup
            XCTAssertEqual(store.totalCount(profileID: BrowserProfile.defaultID), 1)
            let ftsMatches = store.queryTopPlaces(matching: "引擎", profileID: BrowserProfile.defaultID)
            XCTAssertEqual(ftsMatches.count, 1)
            XCTAssertEqual(ftsMatches[0].url, "https://webkit.org/blog")
            XCTAssertEqual(ftsMatches[0].visitCount, 5)

            // Verify favorites, folders, open tabs, and site rules migrated cleanly to Default profile
            XCTAssertEqual(store.loadFolders(profileID: BrowserProfile.defaultID).map(\.title), ["Dev"])
            XCTAssertEqual(store.loadBookmarks(profileID: BrowserProfile.defaultID).map(\.title), ["Apple Docs"])
            XCTAssertEqual(store.loadOpenTabs(profileID: BrowserProfile.defaultID).count, 1)
            let migratedRule = store.siteRule(forHost: "webkit.org", profileID: BrowserProfile.defaultID)
            XCTAssertEqual(migratedRule?.shieldMode, -1)
            XCTAssertEqual(migratedRule?.darkMode, 1)
            XCTAssertEqual(migratedRule?.uaMode, 2)
            XCTAssertEqual(migratedRule?.pageZoom ?? 0, 1.15, accuracy: 0.001)
        }
    }

    // MARK: - 2. Per-Profile SQLite Isolation, Composite Keys & Scoped `saveOpenTabs`

    func testPerProfileSQLiteIsolationFavoritesCopyAndScopedOpenTabs() throws {
        try withTemporaryStateDirectory("dys-prof-iso") { tempDir in
            let store = BrowserSQLiteStore(stateDirectory: tempDir)
            let personalID = BrowserProfile.defaultID
            let workProfile = BrowserProfile(
                name: "Work",
                symbolName: "briefcase.fill",
                palettePreset: .ultramarine,
                isDefault: false,
                webkitStoreID: UUID(),
                fingerprintSeed: FingerprintShieldEngine.generateCryptographicSeed()
            )
            store.upsertProfile(workProfile)

            // Identical URLs in both profiles must NOT collide on `UNIQUE(profile_id, url_key)` or `PK(profile_id, host)`
            let sharedURL = URL(string: "https://github.com/benjipeng/dysprosium")!
            store.recordVisit(url: sharedURL, title: "Personal GitHub", profileID: personalID)
            store.recordVisit(url: URL(string: "https://news.ycombinator.com")!, title: "Personal HN", profileID: personalID)
            store.recordVisit(url: sharedURL, title: "Work GitHub", profileID: workProfile.id)

            XCTAssertEqual(store.totalCount(profileID: personalID), 2)
            XCTAssertEqual(store.totalCount(profileID: workProfile.id), 1)
            XCTAssertTrue(store.queryTopPlaces(matching: "Personal HN", profileID: workProfile.id).isEmpty)
            XCTAssertEqual(store.queryTopPlaces(matching: "Work GitHub", profileID: workProfile.id).count, 1)

            // Favorites & folders isolated + optional `copyFavorites`
            let folder = BrowserFavoriteFolder(id: "f-reading", title: "Reading")
            store.upsertFolder(folder, profileID: personalID)
            store.upsertBookmark(
                BrowserBookmark(title: "GitHub Personal", urlString: sharedURL.absoluteString, folderID: folder.id),
                profileID: personalID
            )
            store.upsertBookmark(
                BrowserBookmark(title: "GitHub Work", urlString: sharedURL.absoluteString),
                profileID: workProfile.id
            )
            XCTAssertEqual(store.loadBookmarks(profileID: personalID).first?.title, "GitHub Personal")
            XCTAssertEqual(store.loadBookmarks(profileID: workProfile.id).first?.title, "GitHub Work")

            // Copy favorites into a third profile preserving folder hierarchy with fresh UUIDs
            let studyProfile = BrowserProfile(
                name: "Study",
                symbolName: "graduationcap.fill",
                palettePreset: .terbium,
                isDefault: false,
                webkitStoreID: UUID(),
                fingerprintSeed: FingerprintShieldEngine.generateCryptographicSeed()
            )
            store.upsertProfile(studyProfile)
            store.copyFavorites(fromProfileID: personalID, toProfileID: studyProfile.id)
            let studyFolders = store.loadFolders(profileID: studyProfile.id)
            let studyBookmarks = store.loadBookmarks(profileID: studyProfile.id)
            XCTAssertEqual(studyFolders.map(\.title), ["Reading"])
            XCTAssertNotEqual(studyFolders.first?.id, folder.id, "Cloned folders must receive distinct IDs")
            XCTAssertEqual(studyBookmarks.first?.folderID, studyFolders.first?.id)

            // Site rules isolated per profile
            store.upsertSiteRule(SiteRuleRecord(host: "github.com", shieldMode: -1, darkMode: 1), profileID: personalID)
            store.upsertSiteRule(SiteRuleRecord(host: "github.com", shieldMode: 1, darkMode: -1), profileID: workProfile.id)
            XCTAssertEqual(store.siteRule(forHost: "github.com", profileID: personalID)?.shieldMode, -1)
            XCTAssertEqual(store.siteRule(forHost: "github.com", profileID: workProfile.id)?.shieldMode, 1)

            // `saveOpenTabs(..., forProfileID:)` must NOT wipe dormant profiles' persisted tabs
            let personalTab = PersistedOpenTab(id: UUID(), profileID: personalID, urlString: "https://example.com/p", title: "P", sortOrder: 100, isActive: true)
            let workTab = PersistedOpenTab(id: UUID(), profileID: workProfile.id, urlString: "https://example.com/w", title: "W", sortOrder: 100, isActive: true)
            store.saveOpenTabs([personalTab], forProfileID: personalID)
            store.saveOpenTabs([workTab], forProfileID: workProfile.id)
            XCTAssertEqual(store.loadOpenTabs(profileID: personalID).map(\.id), [personalTab.id])
            XCTAssertEqual(store.loadOpenTabs(profileID: workProfile.id).map(\.id), [workTab.id])

            // Deleting Work profile cascades Work's rows while keeping Personal untouched
            store.deleteProfile(id: workProfile.id)
            XCTAssertEqual(store.totalCount(profileID: personalID), 2)
            XCTAssertEqual(store.totalCount(profileID: workProfile.id), 0)
            XCTAssertTrue(store.loadOpenTabs(profileID: workProfile.id).isEmpty)
            XCTAssertEqual(store.loadOpenTabs(profileID: personalID).map(\.id), [personalTab.id])
            XCTAssertNil(store.siteRule(forHost: "github.com", profileID: workProfile.id))
            XCTAssertEqual(store.siteRule(forHost: "github.com", profileID: personalID)?.shieldMode, -1)
        }
    }

    // MARK: - 3. Multi-Profile BrowserStore Zero-Restart Switching, De-Collided Seeds & Scoped Clear

    @MainActor
    func testMultiProfileStoreLifecycleZeroRestartSwitchAndScopedClear() async throws {
        try await withTemporaryBrowserStore("dys-store-prof") { store in
            XCTAssertEqual(store.profiles.count, 1)
            XCTAssertFalse(store.isMultiProfileEnabled)
            let personal = store.activeProfile
            XCTAssertTrue(personal.isDefault)
            store.addBookmark(title: "Personal Only", urlString: "https://personal.example")

            // Create Work profile -> activates Work with distinct theme, distinct store UUID, and de-collided persona
            let work = try XCTUnwrap(
                store.createProfile(
                    name: "Work",
                    symbolName: "briefcase.fill",
                    palettePreset: .europium,
                    userAgentProfile: .macosSafari,
                    searchEngine: .kagi,
                    copyFavoritesFromDefault: false,
                    activate: true
                )
            )
            XCTAssertTrue(store.isMultiProfileEnabled)
            XCTAssertEqual(store.activeProfileID, work.id)
            XCTAssertNotNil(work.webkitStoreID)
            XCTAssertEqual(DysprosiumThemeStore.shared.selectedPreset, .europium)
            XCTAssertEqual(store.userAgentProfile, .macosSafari)
            XCTAssertEqual(store.searchEngine, .kagi)
            XCTAssertTrue(store.bookmarks.isEmpty, "Clean Work profile must not inherit Personal bookmarks unless opted in")

            let personalPersona = FingerprintShieldEngine.persona(forSeed: personal.fingerprintSeed, profile: .iosSafari)
            let workPersona = FingerprintShieldEngine.persona(forSeed: work.fingerprintSeed, profile: .iosSafari)
            XCTAssertNotEqual(personal.fingerprintSeed, work.fingerprintSeed)
            XCTAssertTrue(
                personalPersona.userAgent != workPersona.userAgent || personalPersona.preferredIndex != workPersona.preferredIndex,
                "Distinct profiles must avoid colliding on the same Safari build + screen class persona bucket"
            )

            store.addBookmark(title: "Work Docs", urlString: "https://work.example")
            XCTAssertEqual(store.bookmarks.map(\.title), ["Work Docs"])

            // Zero-restart switch back to Personal restores Personal bookmarks, palette, and tabs immediately
            store.switchToProfile(id: personal.id, activateTab: true)
            XCTAssertEqual(store.activeProfileID, personal.id)
            XCTAssertTrue(store.bookmarks.contains(where: { $0.title == "Personal Only" }))
            XCTAssertFalse(store.bookmarks.contains(where: { $0.title == "Work Docs" }))

            // Duplicating a Work tab while Personal is active preserves Work parentage
            let workTab = try XCTUnwrap(store.tabs(forProfileID: work.id).first)
            store.duplicateTab(id: workTab.id)
            XCTAssertEqual(store.activeSession.profileID, work.id)
            XCTAssertEqual(store.tabs(forProfileID: work.id).count, 2)

            // Scoped `performClearBrowsingData` on Work must pass Work's profileID to auth scrub and spare Personal
            store.sqliteStore.recordVisit(url: URL(string: "https://personal.example/page")!, title: "Personal Page", profileID: personal.id)
            store.sqliteStore.recordVisit(url: URL(string: "https://work.example/secret")!, title: "Work Secret", profileID: work.id)
            var scrubbedProfileIDs: [String?] = []
            store.onScrubTransferAuthData = { pid in
                scrubbedProfileIDs.append(pid)
            }
            let report = await store.performClearBrowsingData(
                since: .distantPast,
                options: .init(includeHistory: true, includeCache: false, includeCookiesAndSessions: true, closeStandardTabs: true),
                profileID: work.id
            )
            XCTAssertEqual(report.historyEntriesRemoved, 1)
            XCTAssertEqual(scrubbedProfileIDs, [work.id])
            XCTAssertEqual(store.sqliteStore.totalCount(profileID: work.id), 0)
            XCTAssertEqual(store.sqliteStore.totalCount(profileID: personal.id), 1, "Personal history must be untouched")

            // Delete Work profile cleanly switches back to Personal and removes Work's WebKit store
            await store.deleteProfile(id: work.id)
            XCTAssertEqual(store.profiles.count, 1)
            XCTAssertEqual(store.activeProfileID, personal.id)
            XCTAssertTrue(store.tabs(forProfileID: work.id).isEmpty)
        }
    }

    // MARK: - 4. Weak Object-Identity Cache in `ProfileWebsiteDataStoreRegistry`

    @MainActor
    func testProfileWebsiteDataStoreRegistryPreservesObjectIdentityAndReleasesWhenIdle() async {
        let registry = ProfileWebsiteDataStoreRegistry()
        let uuid = UUID()

        var strongA: WKWebsiteDataStore? = registry.websiteDataStore(forIdentifier: uuid)
        let strongB: WKWebsiteDataStore? = registry.websiteDataStore(forIdentifier: uuid)
        XCTAssertTrue(strongA === strongB, "Repeated calls for the same UUID must share one WKWebsiteDataStore object identity")

        strongA = nil
        _ = strongB
        await registry.removeStore(forIdentifier: uuid)
    }

    // MARK: - 5. Regression Guards: Ephemeral Private Site Rules, Disappeared Profile Guard & Cross-Profile Bookmark Import

    @MainActor
    func testPrivateSiteRulesStayEphemeralAndDisappearedProfileClearNeverWipesPersonal() async throws {
        try await withTemporaryBrowserStore("dys-prof-reg") { store in
            // 1. Private Browsing per-site rules must NEVER touch `browser.sqlite3` and must purge when last Private tab closes
            let privateTab = store.openNewTab(urlString: nil, isPrivate: true, activate: true)
            store.updateSiteRule(forHost: "secret-private.example", shieldMode: -1, darkMode: 1, uaMode: 2, pageZoom: 1.25, isPrivate: true)
            XCTAssertEqual(store.siteRule(forHost: "secret-private.example", isPrivate: true)?.shieldMode, -1)
            XCTAssertNil(store.sqliteStore.siteRule(forHost: "secret-private.example", profileID: BrowserProfile.defaultID))

            var scrubbedIDs: [String?] = []
            store.onScrubTransferAuthData = { pid in
                scrubbedIDs.append(pid)
            }
            store.closeTab(id: privateTab.id)
            XCTAssertNil(store.siteRule(forHost: "secret-private.example", isPrivate: true))
            let deadline = ContinuousClock.now + .seconds(1)
            while !scrubbedIDs.contains(BrowserProfile.privateTransferProfileID), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(scrubbedIDs.contains(BrowserProfile.privateTransferProfileID))

            // 2. Deleting a secondary profile scrubs its transfer auth headers AND subsequent clear targeting deleted ID is a safe no-op
            let work = try XCTUnwrap(store.createProfile(name: "Work", palettePreset: .terbium, activate: true))
            store.sqliteStore.recordVisit(url: URL(string: "https://personal-safe.example")!, title: "Safe", profileID: BrowserProfile.defaultID)
            await store.deleteProfile(id: work.id)
            XCTAssertTrue(scrubbedIDs.contains(work.id))

            let ghostReport = await store.performClearBrowsingData(
                since: .distantPast,
                options: .init(includeHistory: true, includeCache: true, includeCookiesAndSessions: true, closeStandardTabs: true),
                profileID: work.id
            )
            XCTAssertEqual(ghostReport.historyEntriesRemoved, 0)
            XCTAssertEqual(store.sqliteStore.totalCount(profileID: BrowserProfile.defaultID), 1, "Missing target profile must never fall back to wiping Personal")
        }
    }

    @MainActor
    func testCrossProfileBookmarkJSONImportMintsDistinctFolderIDs() async throws {
        try await withTemporaryBrowserStore("dys-prof-import") { store in
            // Fresh installs seed default starter bookmarks (e.g. Google / DuckDuckGo) into Personal
            // when `dysprosium.bookmarks.seedVersion < 2`; assert relative to that baseline so the
            // test is deterministic across both virgin CI simulators and previously-launched ones.
            let baselineBookmarkCount = store.bookmarks.count

            let personalFolder = try XCTUnwrap(store.createFolder(title: "Engineering"))
            store.addBookmark(title: "Swift", urlString: "https://swift.org", folderID: personalFolder.id)
            let exportedJSON = store.exportBookmarksJSON()

            let work = try XCTUnwrap(store.createProfile(name: "Work", palettePreset: .ultramarine, copyFavoritesFromDefault: false, activate: true))
            XCTAssertTrue(store.bookmarks.isEmpty, "Fresh secondary profile must start without Personal starter bookmarks")

            let importedCount = store.importBookmarks(from: exportedJSON)
            XCTAssertEqual(importedCount, baselineBookmarkCount + 1)
            XCTAssertEqual(store.favoriteFolders.map(\.title), ["Engineering"])
            let workFolder = try XCTUnwrap(store.favoriteFolders.first)
            XCTAssertNotEqual(workFolder.id, personalFolder.id, "Imported folder must mint a new UUID to avoid cross-profile PK collision")

            // Deleting Engineering in Personal must NOT affect Work's imported folder or bookmark
            store.switchToProfile(id: BrowserProfile.defaultID, activateTab: true)
            store.deleteFolder(id: personalFolder.id, keepBookmarks: false)
            store.switchToProfile(id: work.id, activateTab: true)
            XCTAssertEqual(store.favoriteFolders.map(\.title), ["Engineering"])
            let workSwiftBookmark = try XCTUnwrap(store.bookmarks.first(where: { $0.title == "Swift" }))
            XCTAssertEqual(workSwiftBookmark.folderID, workFolder.id)
            XCTAssertEqual(store.bookmarks.count, baselineBookmarkCount + 1)
        }
    }

    func testHistoryVisitsProfileIndexSupportsCoveringQueriesAndPerProfileIsolation() throws {
        try withTemporaryStateDirectory("dys-prof-idx") { tempDir in
            let store = BrowserSQLiteStore(stateDirectory: tempDir)
            let work = BrowserProfile(
                name: "Work",
                symbolName: "briefcase.fill",
                palettePreset: .ultramarine,
                isDefault: false,
                webkitStoreID: UUID(),
                fingerprintSeed: FingerprintShieldEngine.generateCryptographicSeed()
            )
            store.upsertProfile(work)

            let now = Date()
            let earlier = now.addingTimeInterval(-3600)
            store.recordVisit(url: URL(string: "https://personal-1.example")!, title: "P1", visitedAt: earlier, profileID: BrowserProfile.defaultID)
            store.recordVisit(url: URL(string: "https://work-1.example")!, title: "W1", visitedAt: now, profileID: work.id)

            XCTAssertEqual(store.queryDaySummaries(profileID: work.id).first?.count, 1)
            XCTAssertEqual(store.queryEntriesPage(profileID: work.id).map(\.title), ["W1"])
            XCTAssertEqual(store.queryEntriesPage(profileID: BrowserProfile.defaultID).map(\.title), ["P1"])
            XCTAssertNotNil(store.earliestVisitDate(profileID: work.id))

            // Verify SQLite query planner uses `idx_visits_profile_day_time` without a TEMP B-TREE sort
            let dbPath = tempDir.appendingPathComponent("browser.sqlite3").path
            var rawDB: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(dbPath, &rawDB, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
            let db = try XCTUnwrap(rawDB)
            defer { sqlite3_close_v2(db) }

            let explainSQL = """
                EXPLAIN QUERY PLAN
                SELECT v.id, p.title, p.url, v.visited_at_ms
                FROM history_visits v
                JOIN places p ON p.id = v.place_id
                WHERE v.profile_id = '\(work.id)'
                ORDER BY v.day_ymd DESC, v.visited_at_ms DESC
                LIMIT 80 OFFSET 0;
                """
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, explainSQL, -1, &stmt, nil), SQLITE_OK)
            var planLines: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 3) {
                    planLines.append(String(cString: cStr))
                }
            }
            sqlite3_finalize(stmt)
            let planText = planLines.joined(separator: "\n")
            XCTAssertTrue(planText.contains("idx_visits_profile_day_time"), "Expected idx_visits_profile_day_time in plan:\n\(planText)")
            XCTAssertFalse(planText.contains("TEMP B-TREE"), "Expected zero temp B-tree sort in plan:\n\(planText)")
        }
    }
}
