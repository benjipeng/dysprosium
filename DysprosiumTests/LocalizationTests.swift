import Foundation
import XCTest
@testable import Dysprosium

final class LocalizationTests: XCTestCase {
    private let englishLocale = Locale(identifier: "en")
    private let simplifiedChineseLocale = Locale(identifier: "zh-Hans")

    @MainActor
    private func withRestoredGlobalLanguageState(
        _ body: @MainActor () throws -> Void
    ) rethrows {
        let defaults = UserDefaults.standard
        let appDomainName = Bundle.main.bundleIdentifier ?? ""
        let previousAppDomain = appDomainName.isEmpty ? nil : defaults.persistentDomain(forName: appDomainName)
        let hadPersistedLanguage = previousAppDomain?[AppLanguageStore.defaultsKey] != nil
        let previousPersistedLanguage = previousAppDomain?[AppLanguageStore.defaultsKey]
        let hadAppDomainAppleLanguages = previousAppDomain?["AppleLanguages"] != nil
        let previousAppDomainAppleLanguages = previousAppDomain?["AppleLanguages"]
        let previousSelection = AppLanguageStore.shared.selection

        defer {
            AppLanguageStore.shared.select(previousSelection)
            if hadPersistedLanguage, let previousPersistedLanguage {
                defaults.set(previousPersistedLanguage, forKey: AppLanguageStore.defaultsKey)
            } else {
                defaults.removeObject(forKey: AppLanguageStore.defaultsKey)
            }
            if hadAppDomainAppleLanguages, let previousAppDomainAppleLanguages {
                defaults.set(previousAppDomainAppleLanguages, forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }

        try body()
    }

    // MARK: - 1. String Catalog & Compiled Bundle Integrity

    func testCompiledBundleAndSourceCatalogIntegrity() throws {
        let bundle = Bundle.main
        let localizations = Set(bundle.localizations)
        XCTAssertTrue(
            localizations.contains("en"),
            "Compiled host bundle must declare 'en' localization (found: \(bundle.localizations))"
        )
        XCTAssertTrue(
            localizations.contains("zh-Hans"),
            "Compiled host bundle must declare 'zh-Hans' localization (found: \(bundle.localizations))"
        )

        let hasLoctable = bundle.url(forResource: "Localizable", withExtension: "loctable") != nil
        let hasLprojStrings = bundle.path(forResource: "en", ofType: "lproj") != nil
            && bundle.path(forResource: "zh-Hans", ofType: "lproj") != nil
        XCTAssertTrue(
            hasLoctable || hasLprojStrings,
            "Host bundle must contain compiled Localizable.loctable or en/zh-Hans .lproj resources"
        )

        let sourceCatalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Dysprosium/Resources/Localizable.xcstrings")

        if FileManager.default.fileExists(atPath: sourceCatalogURL.path) {
            let data = try Data(contentsOf: sourceCatalogURL)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(root["sourceLanguage"] as? String, "en")

            let strings = try XCTUnwrap(root["strings"] as? [String: Any])
            XCTAssertGreaterThanOrEqual(strings.count, 800, "Expected complete String Catalog coverage")

            for (key, rawEntry) in strings {
                let entry = try XCTUnwrap(rawEntry as? [String: Any], "Malformed entry for key: \(key)")
                let locs = try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for key: \(key)")
                for requiredLang in ["en", "zh-Hans"] {
                    let langObj = try XCTUnwrap(
                        locs[requiredLang] as? [String: Any],
                        "Missing '\(requiredLang)' localization for key: \(key)"
                    )
                    let hasStringUnit = (langObj["stringUnit"] as? [String: Any])?["state"] as? String == "translated"
                    let hasPluralVariation = (langObj["variations"] as? [String: Any])?["plural"] != nil
                    XCTAssertTrue(
                        hasStringUnit || hasPluralVariation,
                        "Key '\(key)' in '\(requiredLang)' must have a translated stringUnit or plural variation"
                    )
                }
            }
        }
    }

    // MARK: - 2. Core UI, Homographs, Positional Specifiers & ICU Plurals (`en` + `zh-Hans`)

    func testCoreStringsHomographsAndPositionalReorderingResolveInEnglishAndSimplifiedChinese() {
        // Core workspace tabs & navigation headers
        XCTAssertEqual(AppLocalization.string("Browser", locale: englishLocale), "Browser")
        XCTAssertEqual(AppLocalization.string("Browser", locale: simplifiedChineseLocale), "浏览")

        XCTAssertEqual(AppLocalization.string("Downloads", locale: englishLocale), "Downloads")
        XCTAssertEqual(AppLocalization.string("Downloads", locale: simplifiedChineseLocale), "下载")

        XCTAssertEqual(AppLocalization.string("Engine", locale: englishLocale), "Engine")
        XCTAssertEqual(AppLocalization.string("Engine", locale: simplifiedChineseLocale), "引擎")

        XCTAssertEqual(AppLocalization.string("Engine & Host", locale: englishLocale), "Engine & Host")
        XCTAssertEqual(AppLocalization.string("Engine & Host", locale: simplifiedChineseLocale), "引擎与宿主")

        // Settings, menus & sheets
        XCTAssertEqual(AppLocalization.string("Appearance", locale: englishLocale), "Appearance")
        XCTAssertEqual(AppLocalization.string("Appearance", locale: simplifiedChineseLocale), "外观")

        XCTAssertEqual(AppLocalization.string("Language", locale: englishLocale), "Language")
        XCTAssertEqual(AppLocalization.string("Language", locale: simplifiedChineseLocale), "语言")

        XCTAssertEqual(AppLocalization.string("Automatic", locale: englishLocale), "Automatic")
        XCTAssertEqual(AppLocalization.string("Automatic", locale: simplifiedChineseLocale), "跟随系统")

        XCTAssertEqual(AppLocalization.string("Private Browsing", locale: englishLocale), "Private Browsing")
        XCTAssertEqual(AppLocalization.string("Private Browsing", locale: simplifiedChineseLocale), "无痕浏览")

        XCTAssertEqual(AppLocalization.string("Content Shield", locale: englishLocale), "Content Shield")
        XCTAssertEqual(AppLocalization.string("Content Shield", locale: simplifiedChineseLocale), "内容拦截")

        XCTAssertEqual(AppLocalization.string("Clear Browsing Data", locale: englishLocale), "Clear Browsing Data")
        XCTAssertEqual(AppLocalization.string("Clear Browsing Data", locale: simplifiedChineseLocale), "清除浏览数据")

        XCTAssertEqual(AppLocalization.string("Start Page", locale: englishLocale), "Start Page")
        XCTAssertEqual(AppLocalization.string("Start Page", locale: simplifiedChineseLocale), "起始页")

        XCTAssertEqual(AppLocalization.string("Favorites", locale: englishLocale), "Favorites")
        XCTAssertEqual(AppLocalization.string("Favorites", locale: simplifiedChineseLocale), "个人收藏")

        // Homograph disambiguation (`Active` profile badge vs runtime subsystem state)
        XCTAssertEqual(AppLocalization.string("profile.status.active", locale: englishLocale), "Active")
        XCTAssertEqual(AppLocalization.string("profile.status.active", locale: simplifiedChineseLocale), "当前")

        XCTAssertEqual(AppLocalization.string("Active", locale: englishLocale), "Active")
        XCTAssertEqual(AppLocalization.string("Active", locale: simplifiedChineseLocale), "运行中")

        // Error message with positional argument reordering in Simplified Chinese
        let statusCode = 404
        let targetURL = "https://example.com/stream.m3u8"
        XCTAssertEqual(
            AppLocalization.string("HTTP \(statusCode) while fetching \(targetURL)", locale: englishLocale),
            "HTTP 404 while fetching https://example.com/stream.m3u8"
        )
        XCTAssertEqual(
            AppLocalization.string("HTTP \(statusCode) while fetching \(targetURL)", locale: simplifiedChineseLocale),
            "获取 https://example.com/stream.m3u8 时返回 HTTP 404"
        )
    }

    func testICUPluralsAndMultiArgumentSubstitutionsAcrossZeroOneTwoFiveCounts() {
        let counts = [0, 1, 2, 5]

        // 1. Tabs (`%lld tabs` and Title-Case pill `%lld Tabs`)
        let expectedEnTabs = ["0 tabs", "1 tab", "2 tabs", "5 tabs"]
        let expectedEnTitleTabs = ["0 Tabs", "1 Tab", "2 Tabs", "5 Tabs"]
        for (idx, count) in counts.enumerated() {
            XCTAssertEqual(
                AppLocalization.string("\(count) tabs", locale: englishLocale),
                expectedEnTabs[idx]
            )
            XCTAssertEqual(
                AppLocalization.string("\(count) Tabs", locale: englishLocale),
                expectedEnTitleTabs[idx]
            )
            XCTAssertEqual(
                AppLocalization.string("\(count) tabs", locale: simplifiedChineseLocale),
                "\(count) 个标签页"
            )
            XCTAssertEqual(
                AppLocalization.string("\(count) Tabs", locale: simplifiedChineseLocale),
                "\(count) 个标签页"
            )
        }

        // 2. Sites (`%lld sites` and `%@ · %lld sites`)
        let expectedEnSites = ["0 sites", "1 site", "2 sites", "5 sites"]
        for (idx, count) in counts.enumerated() {
            XCTAssertEqual(
                AppLocalization.string("\(count) sites", locale: englishLocale),
                expectedEnSites[idx]
            )
            XCTAssertEqual(
                AppLocalization.string("\(count) sites", locale: simplifiedChineseLocale),
                "\(count) 个网站"
            )
            XCTAssertEqual(
                AppLocalization.string("\("4.2 MB") · \(count) sites", locale: englishLocale),
                "4.2 MB · \(expectedEnSites[idx])"
            )
            XCTAssertEqual(
                AppLocalization.string("\("4.2 MB") · \(count) sites", locale: simplifiedChineseLocale),
                "4.2 MB · \(count) 个网站"
            )
        }

        // 3. Files (`%@ · %lld files`)
        let expectedEnFiles = ["0 files", "1 file", "2 files", "5 files"]
        for (idx, count) in counts.enumerated() {
            XCTAssertEqual(
                AppLocalization.string("\("12 MB") · \(count) files", locale: englishLocale),
                "12 MB · \(expectedEnFiles[idx])"
            )
            XCTAssertEqual(
                AppLocalization.string("\("12 MB") · \(count) files", locale: simplifiedChineseLocale),
                "12 MB · \(count) 个文件"
            )
        }

        // 4. Byte-range slices (`%lld slices` & `%lld× Lanes · %lld Byte-Range Slices`)
        let expectedEnSlices = ["0 slices", "1 slice", "2 slices", "5 slices"]
        for (idx, count) in counts.enumerated() {
            XCTAssertEqual(
                AppLocalization.string("\(count) slices", locale: englishLocale),
                expectedEnSlices[idx]
            )
            XCTAssertEqual(
                AppLocalization.string("\(count) slices", locale: simplifiedChineseLocale),
                "\(count) 个分片"
            )
        }

        XCTAssertEqual(
            AppLocalization.string("\(1)× Lanes · \(1) Byte-Range Slices", locale: englishLocale),
            "1× Lane · 1 Byte-Range Slice"
        )
        XCTAssertEqual(
            AppLocalization.string("\(16)× Lanes · \(2) Byte-Range Slices", locale: englishLocale),
            "16× Lanes · 2 Byte-Range Slices"
        )
        XCTAssertEqual(
            AppLocalization.string("\(16)× Lanes · \(2) Byte-Range Slices", locale: simplifiedChineseLocale),
            "16× 并发 · 2 个字节分片"
        )

        // 5. Reordered profile tab-closing confirmation (`Close All %lld Tabs in %@?`)
        XCTAssertEqual(
            AppLocalization.string("Close All \(1) Tabs in \("Work")?", locale: englishLocale),
            "Close All 1 Tab in Work?"
        )
        XCTAssertEqual(
            AppLocalization.string("Close All \(5) Tabs in \("Work")?", locale: englishLocale),
            "Close All 5 Tabs in Work?"
        )
        XCTAssertEqual(
            AppLocalization.string("Close All \(1) Tabs in \("工作")?", locale: simplifiedChineseLocale),
            "关闭「工作」的全部 1 个标签页？"
        )
        XCTAssertEqual(
            AppLocalization.string("Close All \(5) Tabs in \("工作")?", locale: simplifiedChineseLocale),
            "关闭「工作」的全部 5 个标签页？"
        )
    }

    // MARK: - 3. AppLanguageStore Persistence & AppleLanguages Synchronization

    @MainActor
    func testAppLanguageStorePersistenceAndAppleLanguagesSync() throws {
        try withRestoredGlobalLanguageState {
            let suiteName = "com.appautomaton.dysprosium.tests.lang.\(UUID().uuidString)"
            let isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer {
                isolatedDefaults.removePersistentDomain(forName: suiteName)
            }

            let store = AppLanguageStore(userDefaults: isolatedDefaults)

            // Select English -> persists `en` and sets `AppleLanguages = ["en"]`
            store.select(.english)
            XCTAssertEqual(store.selection, .english)
            XCTAssertEqual(store.effectiveLocale, Locale(identifier: "en"))
            XCTAssertEqual(AppLocalization.currentLocale, Locale(identifier: "en"))
            XCTAssertEqual(isolatedDefaults.string(forKey: AppLanguageStore.defaultsKey), "en")
            XCTAssertEqual(isolatedDefaults.stringArray(forKey: "AppleLanguages"), ["en"])
            XCTAssertEqual(L("Browser"), "Browser")
            XCTAssertEqual(AppLanguage.system.pickerTitle, "Automatic")
            XCTAssertEqual(AppLanguage.english.pickerTitle, "English")
            XCTAssertEqual(AppLanguage.simplifiedChinese.pickerTitle, "简体中文")

            // Select Simplified Chinese -> persists `zh-Hans` and sets `AppleLanguages = ["zh-Hans"]`
            store.select(.simplifiedChinese)
            XCTAssertEqual(store.selection, .simplifiedChinese)
            XCTAssertEqual(store.effectiveLocale, Locale(identifier: "zh-Hans"))
            XCTAssertEqual(AppLocalization.currentLocale, Locale(identifier: "zh-Hans"))
            XCTAssertEqual(isolatedDefaults.string(forKey: AppLanguageStore.defaultsKey), "zh-Hans")
            XCTAssertEqual(isolatedDefaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])
            XCTAssertEqual(L("Browser"), "浏览")
            XCTAssertEqual(AppLanguage.system.pickerTitle, "跟随系统")
            XCTAssertEqual(AppLanguage.english.pickerTitle, "English")
            XCTAssertEqual(AppLanguage.simplifiedChinese.pickerTitle, "简体中文")

            // Re-hydrate from persisted defaults
            let rehydrated = AppLanguageStore(userDefaults: isolatedDefaults)
            XCTAssertEqual(rehydrated.selection, .simplifiedChinese)
            XCTAssertEqual(rehydrated.effectiveLocale, Locale(identifier: "zh-Hans"))

            // Select `.system` -> persists `system` and removes app-domain `AppleLanguages` override
            // (so `UserDefaults` falls back cleanly to `NSGlobalDomain`'s OS language list)
            store.select(.system)
            XCTAssertEqual(store.selection, .system)
            XCTAssertEqual(store.effectiveLocale, .autoupdatingCurrent)
            XCTAssertEqual(isolatedDefaults.string(forKey: AppLanguageStore.defaultsKey), "system")
            XCTAssertNil(isolatedDefaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
            XCTAssertNil(AppLanguage.system.appleLanguagesOverride)
        }
    }

    // MARK: - 4. BrowserProfile Localized Display Name & Suggestions

    @MainActor
    func testBrowserProfileLocalizedDisplayNamePreservesPersistedAndCustomNames() {
        withRestoredGlobalLanguageState {
            let defaultProfile = BrowserProfile.makeDefaultProfile(
                seed: String(repeating: "a", count: 64)
            )
            XCTAssertEqual(defaultProfile.id, BrowserProfile.defaultID)
            XCTAssertEqual(defaultProfile.name, "Personal", "Persisted SQLite default profile name must remain 'Personal'")

            var renamedDefault = defaultProfile
            renamedDefault.name = "AC Studio"

            let customProfile = BrowserProfile(
                name: "Research Lab",
                fingerprintSeed: String(repeating: "b", count: 64)
            )
            let customNamedPersonal = BrowserProfile(
                name: "Personal",
                fingerprintSeed: String(repeating: "c", count: 64)
            )

            AppLanguageStore.shared.select(.english)
            XCTAssertEqual(defaultProfile.localizedDisplayName, "Personal")
            XCTAssertEqual(renamedDefault.localizedDisplayName, "AC Studio")
            XCTAssertEqual(customProfile.localizedDisplayName, "Research Lab")
            XCTAssertEqual(customNamedPersonal.localizedDisplayName, "Personal")
            XCTAssertEqual(BrowserProfile.quickNameSuggestions.map(\.name), ["Work", "Study", "Research", "Media"])

            AppLanguageStore.shared.select(.simplifiedChinese)
            XCTAssertEqual(defaultProfile.localizedDisplayName, "个人")
            XCTAssertEqual(renamedDefault.localizedDisplayName, "AC Studio")
            XCTAssertEqual(customProfile.localizedDisplayName, "Research Lab")
            XCTAssertEqual(
                customNamedPersonal.localizedDisplayName,
                "Personal",
                "User-created non-default profile named 'Personal' must preserve its custom name verbatim"
            )
            XCTAssertEqual(BrowserProfile.quickNameSuggestions.map(\.name), ["工作", "学习", "研究", "影音"])
        }
    }

    // MARK: - 5. Locale-Aware DysprosiumFormatters

    @MainActor
    func testDysprosiumFormattersInEnglishAndSimplifiedChinese() {
        withRestoredGlobalLanguageState {
            AppLanguageStore.shared.select(.english)
            XCTAssertEqual(DysprosiumFormatters.speed(0), "0 B/s")
            XCTAssertTrue(DysprosiumFormatters.speed(2_097_152).hasSuffix("/s"))
            XCTAssertFalse(DysprosiumFormatters.bytes(10_485_760).isEmpty)
            XCTAssertEqual(DysprosiumFormatters.eta(nil), "—")
            XCTAssertEqual(DysprosiumFormatters.eta(25), "25s")
            XCTAssertEqual(DysprosiumFormatters.eta(138), "2m 18s")
            XCTAssertEqual(DysprosiumFormatters.eta(3840), "1h 04m")
            XCTAssertEqual(DysprosiumFormatters.duration(4.2), "4.2s")
            XCTAssertEqual(DysprosiumFormatters.duration(14.2), "14s")
            XCTAssertEqual(DysprosiumFormatters.duration(138), "2m 18s")
            XCTAssertEqual(DysprosiumFormatters.duration(3840), "1h 04m")

            AppLanguageStore.shared.select(.simplifiedChinese)
            XCTAssertEqual(DysprosiumFormatters.speed(0), "0 B/s")
            XCTAssertTrue(DysprosiumFormatters.speed(2_097_152).hasSuffix("/s"))
            XCTAssertFalse(DysprosiumFormatters.bytes(10_485_760).isEmpty)
            XCTAssertEqual(DysprosiumFormatters.eta(nil), "—")
            XCTAssertEqual(DysprosiumFormatters.eta(25), "25秒")
            XCTAssertEqual(DysprosiumFormatters.eta(138), "2分18秒")
            XCTAssertEqual(DysprosiumFormatters.eta(3840), "1小时04分")
            XCTAssertEqual(DysprosiumFormatters.duration(4.2), "4.2秒")
            XCTAssertEqual(DysprosiumFormatters.duration(14.2), "14秒")
            XCTAssertEqual(DysprosiumFormatters.duration(138), "2分18秒")
            XCTAssertEqual(DysprosiumFormatters.duration(3840), "1小时04分")
        }
    }
}
