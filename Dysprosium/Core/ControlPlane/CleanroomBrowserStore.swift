import Foundation
import Observation
import UIKit
import WebKit

public enum BrowserUserAgentProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case iosSafari
    case macosSafari

    public var id: String { rawValue }

    public static let defaultsKey = "dysprosium.browser.userAgentProfile"

    public static var persistedCurrent: BrowserUserAgentProfile {
        let raw = CleanroomBrowserStore.readSharedString(forKey: defaultsKey) ?? ""
        return BrowserUserAgentProfile(rawValue: raw) ?? .iosSafari
    }

    public var title: String {
        switch self {
        case .iosSafari: return L("iOS Safari (Mobile)")
        case .macosSafari: return L("macOS Safari (Desktop)")
        }
    }

    public var shortLabel: String {
        switch self {
        case .iosSafari: return "iOS"
        case .macosSafari: return "macOS"
        }
    }

    public var systemImage: String {
        switch self {
        case .iosSafari: return "iphone"
        case .macosSafari: return "laptopcomputer"
        }
    }

    public var userAgentString: String {
        switch self {
        case .iosSafari: return HLSStreamEngine.iosSafariUserAgent
        case .macosSafari: return HLSStreamEngine.macosSafariUserAgent
        }
    }

    @MainActor
    public var preferredContentMode: WKWebpagePreferences.ContentMode {
        switch self {
        case .iosSafari: return .mobile
        case .macosSafari: return .desktop
        }
    }
}

public enum BrowserSearchEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case duckDuckGo
    case google
    case kagi
    case brave
    case startpage
    case custom

    public var id: String { rawValue }

    public static let defaultsKey = "dysprosium.browser.searchEngine"
    public static let customTemplateDefaultsKey = "dysprosium.browser.customSearchTemplate"
    public static let defaultCustomTemplate = "https://duckduckgo.com/?q=%s"

    public static var persistedCurrent: BrowserSearchEngine {
        let raw = CleanroomBrowserStore.readSharedString(forKey: defaultsKey) ?? ""
        return BrowserSearchEngine(rawValue: raw) ?? .duckDuckGo
    }

    public static var persistedCustomTemplate: String {
        let saved = CleanroomBrowserStore.readSharedString(forKey: customTemplateDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultCustomTemplate : saved
    }

    public var title: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .kagi: return "Kagi"
        case .brave: return L("Brave Search")
        case .startpage: return "Startpage"
        case .custom: return L("Custom")
        }
    }

    public var host: String {
        switch self {
        case .duckDuckGo: return "duckduckgo.com"
        case .google: return "www.google.com"
        case .kagi: return "kagi.com"
        case .brave: return "search.brave.com"
        case .startpage: return "www.startpage.com"
        case .custom: return URL(string: Self.persistedCustomTemplate)?.host() ?? "custom"
        }
    }

    public var systemImage: String {
        switch self {
        case .duckDuckGo: return "shield.lefthalf.filled"
        case .google: return "magnifyingglass"
        case .kagi: return "sparkles"
        case .brave: return "flame"
        case .startpage: return "eye.slash"
        case .custom: return "slider.horizontal.3"
        }
    }

    private var queryBaseURLString: String {
        switch self {
        case .duckDuckGo: return "https://duckduckgo.com/"
        case .google: return "https://www.google.com/search"
        case .kagi: return "https://kagi.com/search"
        case .brave: return "https://search.brave.com/search"
        case .startpage: return "https://www.startpage.com/sp/search"
        case .custom: return "https://duckduckgo.com/"
        }
    }

    private var queryParamName: String {
        switch self {
        case .startpage: return "query"
        case .duckDuckGo, .google, .kagi, .brave, .custom: return "q"
        }
    }

    /// Strict RFC 3986 query-value character set that percent-encodes `+`, `&`, `=`, `#`, `;`, `/`, `?`, `:`
    /// so queries like `"C++ & a=b #1"` are never mangled into spaces or broken parameters.
    private static let strictQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "+&=#;/?:")
        return cs
    }()

    public func searchURL(for query: String, customTemplate: String? = nil) -> URL? {
        let encodedValue = query.addingPercentEncoding(withAllowedCharacters: Self.strictQueryValueAllowed) ?? query

        if self == .custom {
            let template = (customTemplate ?? Self.persistedCustomTemplate)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !template.isEmpty {
                if template.contains("%s") {
                    let substituted = template.replacingOccurrences(of: "%s", with: encodedValue)
                    if let url = URL(string: substituted),
                       let scheme = url.scheme?.lowercased(),
                       scheme == "http" || scheme == "https" {
                        return url
                    }
                } else if template.contains("{searchTerms}") {
                    let substituted = template.replacingOccurrences(of: "{searchTerms}", with: encodedValue)
                    if let url = URL(string: substituted),
                       let scheme = url.scheme?.lowercased(),
                       scheme == "http" || scheme == "https" {
                        return url
                    }
                } else if var comps = URLComponents(string: template),
                          let scheme = comps.scheme?.lowercased(),
                          scheme == "http" || scheme == "https" {
                    var items = comps.percentEncodedQueryItems ?? []
                    items.append(URLQueryItem(name: "q", value: encodedValue))
                    comps.percentEncodedQueryItems = items
                    if let url = comps.url {
                        return url
                    }
                }
            }
        }

        guard var comps = URLComponents(string: queryBaseURLString) else {
            return nil
        }
        comps.percentEncodedQueryItems = [URLQueryItem(name: queryParamName, value: encodedValue)]
        return comps.url
    }
}

/// Alias matching ergonomic naming across views and tests.
public typealias SearchEngine = BrowserSearchEngine

public struct BrowserFavoriteFolder: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var parentID: String?
    public var title: String
    public var sortOrder: Double
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        parentID: String? = nil,
        title: String,
        sortOrder: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentID, title, sortOrder, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        self.title = try c.decode(String.self, forKey: .title)
        self.sortOrder = try c.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public struct BrowserBookmark: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var urlString: String
    public var symbolName: String
    public var folderID: String?
    public var sortOrder: Double

    public init(
        id: String = UUID().uuidString,
        title: String,
        urlString: String,
        symbolName: String = "globe",
        folderID: String? = nil,
        sortOrder: Double = 0
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.symbolName = symbolName
        self.folderID = folderID
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, urlString, symbolName, folderID, sortOrder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.urlString = try c.decode(String.self, forKey: .urlString)
        self.symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? "globe"
        self.folderID = try c.decodeIfPresent(String.self, forKey: .folderID)
        self.sortOrder = try c.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
    }

    public var displayHost: String {
        if let host = URL(string: urlString)?.host() {
            let normalized = LiveContainerEnvironment.HostNormalizer.normalize(host)
            return normalized.isEmpty ? host : normalized
        }
        return urlString
    }
}

public struct BrowserHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var urlString: String
    public var visitedAt: Date

    public init(id: String = UUID().uuidString, title: String, urlString: String, visitedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.visitedAt = visitedAt
    }

    public var displayHost: String {
        if let host = URL(string: urlString)?.host() {
            let normalized = LiveContainerEnvironment.HostNormalizer.normalize(host)
            return normalized.isEmpty ? host : normalized
        }
        return urlString
    }
}

public struct RecentlyClosedTab: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let urlString: String
    public let title: String
    public let closedAt: Date

    public init(id: UUID = UUID(), urlString: String, title: String, closedAt: Date = Date()) {
        self.id = id
        self.urlString = urlString
        self.title = title
        self.closedAt = closedAt
    }

    public var displayHost: String {
        if let host = URL(string: urlString)?.host() {
            let normalized = LiveContainerEnvironment.HostNormalizer.normalize(host)
            return normalized.isEmpty ? host : normalized
        }
        return urlString
    }
}

public struct WebsiteDataDomainSummary: Identifiable, Equatable, Sendable {
    public var id: String { displayName }
    public let displayName: String
    public let dataTypes: Set<String>
    public let hasCookies: Bool
    public let hasStorage: Bool
    public let hasCache: Bool

    public init(
        displayName: String,
        dataTypes: Set<String>,
        hasCookies: Bool,
        hasStorage: Bool,
        hasCache: Bool
    ) {
        self.displayName = displayName
        self.dataTypes = dataTypes
        self.hasCookies = hasCookies
        self.hasStorage = hasStorage
        self.hasCache = hasCache
    }
}

public struct BrowserStorageFootprint: Equatable, Sendable {
    public let historySQLiteBytes: UInt64
    public let faviconCacheBytes: UInt64
    public let webKitCacheBytes: UInt64
    public let stagingTempBytes: UInt64
    public let websiteDomainCount: Int
    public let totalBytes: UInt64

    public init(
        historySQLiteBytes: UInt64,
        faviconCacheBytes: UInt64,
        webKitCacheBytes: UInt64,
        stagingTempBytes: UInt64,
        websiteDomainCount: Int,
        totalBytes: UInt64? = nil
    ) {
        self.historySQLiteBytes = historySQLiteBytes
        self.faviconCacheBytes = faviconCacheBytes
        self.webKitCacheBytes = webKitCacheBytes
        self.stagingTempBytes = stagingTempBytes
        self.websiteDomainCount = websiteDomainCount
        self.totalBytes = totalBytes ?? (historySQLiteBytes &+ faviconCacheBytes &+ webKitCacheBytes &+ stagingTempBytes)
    }
}

public struct BrowsingClearReport: Equatable, Sendable {
    public let bytesReclaimed: UInt64
    public let historyEntriesRemoved: Int
    public let websiteRecordsRemoved: Int
    public let cookiesRemoved: Int
    public let temporaryBytesReclaimed: UInt64
    public let closedTabCount: Int

    public init(
        bytesReclaimed: UInt64 = 0,
        historyEntriesRemoved: Int = 0,
        websiteRecordsRemoved: Int = 0,
        cookiesRemoved: Int = 0,
        temporaryBytesReclaimed: UInt64 = 0,
        closedTabCount: Int = 0
    ) {
        self.bytesReclaimed = bytesReclaimed
        self.historyEntriesRemoved = historyEntriesRemoved
        self.websiteRecordsRemoved = websiteRecordsRemoved
        self.cookiesRemoved = cookiesRemoved
        self.temporaryBytesReclaimed = temporaryBytesReclaimed
        self.closedTabCount = closedTabCount
    }
}

/// Top-level alias matching nested `CleanroomBrowserStore.OmniboxSuggestion`.
public typealias OmniboxSuggestion = CleanroomBrowserStore.OmniboxSuggestion

/// Manages multi-tab `CleanroomWebKitSession` instances, unified `BrowserSQLiteStore` (`browser.sqlite3`),
/// lazy `WKWebView` LRU hibernation, shared ephemeral Private session store, per-site rules,
/// zero-ghost-storage clearing, website data inspection, recently closed tabs, and clipboard perception.
@Observable
@MainActor
public final class CleanroomBrowserStore {
    public struct OmniboxSuggestion: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let urlString: String
        public let isFavorite: Bool

        public init(id: String, title: String, urlString: String, isFavorite: Bool) {
            self.id = id
            self.title = title
            self.urlString = urlString
            self.isFavorite = isFavorite
        }
    }

    public static let maxLiveWebViews = 4
    public static let maxInactiveProfileLiveWebViews = 1
    public static let maxRecentlyClosedTabs = 15

    public private(set) var profiles: [BrowserProfile] = [BrowserProfile.makeDefaultProfile()]
    public private(set) var activeProfileID: String = BrowserProfile.defaultID
    public private(set) var tabs: [CleanroomWebKitSession] = []
    public var activeTabID: UUID
    public private(set) var bookmarks: [BrowserBookmark] = []
    public private(set) var favoriteFolders: [BrowserFavoriteFolder] = []
    public private(set) var siteRulesByHost: [String: SiteRuleRecord] = [:]
    private var recentlyClosedTabsByProfile: [String: [RecentlyClosedTab]] = [:]
    public var recentlyClosedTabs: [RecentlyClosedTab] {
        recentlyClosedTabsByProfile[activeProfileID] ?? []
    }
    public private(set) var totalHistoryCount: Int = 0
    public private(set) var historyRevision: Int = 0
    public private(set) var hasClipboardWebURL: Bool = false
    public private(set) var isHydrated: Bool = false

    public var activeProfile: BrowserProfile {
        profiles.first(where: { $0.id == activeProfileID })
            ?? profiles.first
            ?? BrowserProfile.makeDefaultProfile()
    }

    public var isMultiProfileEnabled: Bool {
        profiles.count >= 2
    }

    public var activeProfileTabs: [CleanroomWebKitSession] {
        tabs.filter { !$0.isPrivate && $0.profileID == activeProfileID }
    }

    public var privateTabs: [CleanroomWebKitSession] {
        tabs.filter(\.isPrivate)
    }

    public func tabs(forProfileID id: String) -> [CleanroomWebKitSession] {
        tabs.filter { !$0.isPrivate && $0.profileID == id }
    }

    public func profile(for id: String?) -> BrowserProfile? {
        guard let id else { return nil }
        return profiles.first(where: { $0.id == id })
    }

    public func recentlyClosedTabs(forProfileID id: String) -> [RecentlyClosedTab] {
        recentlyClosedTabsByProfile[id] ?? []
    }

    /// Optional callback invoked during Cookies & Sessions clear to scrub persisted transfer auth headers
    /// scoped to the cleared profile ID (`nil` = all).
    public var onScrubTransferAuthData: (@MainActor (String?) async -> Void)?
    /// Optional provider returning active transfer IDs so staging reclamation never deletes in-flight downloads.
    public var activeTransferIDsProvider: (@MainActor () -> Set<UUID>)?
    /// Optional predicate exempting tabs with an active download from LRU hibernation.
    public var hasActiveDownloadForTab: (@MainActor (UUID) -> Bool)?

    nonisolated public static let autoWebPageDarkModeDefaultsKey = "dysprosium.browser.autoWebPageDarkMode"
    nonisolated public static let globalShieldEnabledDefaultsKey = "dysprosium.browser.globalShieldEnabled"
    nonisolated private static let palettePresetDefaultsKey = "dysprosium.design.palettePreset"
    /// Stored strictly in host-local `UserDefaults.standard` so side-by-side LC 1 / LC 2 Split View instances
    /// never yank each other onto a different profile on foreground.
    nonisolated private static let activeProfileIDDefaultsKey = "dysprosium.browser.activeProfileID.v1"

    // MARK: - Shared App Group UserDefaults Helpers (with one-time legacy `.standard` fallback)

    nonisolated internal static func readSharedString(forKey key: String) -> String? {
        let shared = LiveContainerEnvironment.sharedDefaults
        if let value = shared.string(forKey: key) {
            return value
        }
        if shared !== UserDefaults.standard, let legacy = UserDefaults.standard.string(forKey: key) {
            shared.set(legacy, forKey: key)
            return legacy
        }
        return nil
    }

    nonisolated internal static func readSharedBool(forKey key: String, defaultValue: Bool) -> Bool {
        let shared = LiveContainerEnvironment.sharedDefaults
        if shared.object(forKey: key) != nil {
            return shared.bool(forKey: key)
        }
        if shared !== UserDefaults.standard, UserDefaults.standard.object(forKey: key) != nil {
            let legacy = UserDefaults.standard.bool(forKey: key)
            shared.set(legacy, forKey: key)
            return legacy
        }
        return defaultValue
    }

    nonisolated private static func migratePalettePresetToSharedDefaultsIfNeeded() {
        let shared = LiveContainerEnvironment.sharedDefaults
        guard shared !== UserDefaults.standard else { return }
        if let sharedValue = shared.string(forKey: palettePresetDefaultsKey), !sharedValue.isEmpty {
            if UserDefaults.standard.string(forKey: palettePresetDefaultsKey) != sharedValue {
                UserDefaults.standard.set(sharedValue, forKey: palettePresetDefaultsKey)
            }
        } else if let legacy = UserDefaults.standard.string(forKey: palettePresetDefaultsKey), !legacy.isEmpty {
            shared.set(legacy, forKey: palettePresetDefaultsKey)
        }
    }

    nonisolated public static var persistedAutoWebPageDarkMode: Bool {
        readSharedBool(forKey: autoWebPageDarkModeDefaultsKey, defaultValue: true)
    }

    nonisolated public static var persistedGlobalShieldEnabled: Bool {
        readSharedBool(forKey: globalShieldEnabledDefaultsKey, defaultValue: true)
    }

    public var userAgentProfile: BrowserUserAgentProfile {
        didSet {
            guard oldValue != userAgentProfile, !isSyncingProfilePreferences else { return }
            let targetProfileID = activeProfileID
            if let idx = profiles.firstIndex(where: { $0.id == targetProfileID }) {
                profiles[idx].userAgentProfile = userAgentProfile
                let updated = profiles[idx]
                let db = sqliteStore
                Task.detached(priority: .utility) {
                    db.upsertProfile(updated)
                }
            }
            if targetProfileID == BrowserProfile.defaultID {
                LiveContainerEnvironment.sharedDefaults.set(userAgentProfile.rawValue, forKey: BrowserUserAgentProfile.defaultsKey)
            }
            let activeID = activeTabID
            for tab in tabs where tab.profileID == targetProfileID || tab.isPrivate {
                if tab.id == activeID {
                    tab.applyUserAgentProfile(userAgentProfile, reloadIfLoaded: true)
                } else {
                    tab.markNeedsSettingsSyncOnActivate()
                }
            }
        }
    }

    public var webDarkModeBehavior: DarkReaderEngine.WebDarkModeBehavior {
        didSet {
            guard oldValue != webDarkModeBehavior else { return }
            DarkReaderEngine.shared.modeBehavior = webDarkModeBehavior
            let nextBool = webDarkModeBehavior.isEnabled
            if autoWebPageDarkMode != nextBool {
                autoWebPageDarkMode = nextBool
            } else {
                broadcastWebDarkConfigChange()
            }
        }
    }

    public var webDarkThemePreset: DarkReaderEngine.WebDarkThemePreset {
        didSet {
            guard oldValue != webDarkThemePreset else { return }
            DarkReaderEngine.shared.themePreset = webDarkThemePreset
            broadcastWebDarkConfigChange()
        }
    }

    public var autoWebPageDarkMode: Bool {
        didSet {
            guard oldValue != autoWebPageDarkMode else { return }
            LiveContainerEnvironment.sharedDefaults.set(autoWebPageDarkMode, forKey: Self.autoWebPageDarkModeDefaultsKey)
            let desiredBehavior: DarkReaderEngine.WebDarkModeBehavior = autoWebPageDarkMode
                ? (webDarkModeBehavior == .off ? .auto : webDarkModeBehavior)
                : .off
            if webDarkModeBehavior != desiredBehavior {
                webDarkModeBehavior = desiredBehavior
                return
            }
            broadcastWebDarkConfigChange()
        }
    }

    private func broadcastWebDarkConfigChange() {
        let activeID = activeTabID
        for tab in tabs {
            if tab.id == activeID {
                tab.applyAutoWebPageDarkMode(autoWebPageDarkMode)
            } else {
                tab.markNeedsSettingsSyncOnActivate()
            }
        }
    }

    public var isShieldEnabled: Bool {
        didSet {
            guard oldValue != isShieldEnabled else { return }
            LiveContainerEnvironment.sharedDefaults.set(isShieldEnabled, forKey: Self.globalShieldEnabledDefaultsKey)
            for tab in tabs {
                tab.setShieldEnabled(isShieldEnabled)
            }
        }
    }

    public var searchEngine: BrowserSearchEngine {
        didSet {
            guard oldValue != searchEngine, !isSyncingProfilePreferences else { return }
            let targetProfileID = activeProfileID
            if let idx = profiles.firstIndex(where: { $0.id == targetProfileID }) {
                profiles[idx].searchEngine = searchEngine
                let updated = profiles[idx]
                let db = sqliteStore
                Task.detached(priority: .utility) {
                    db.upsertProfile(updated)
                }
            }
            if targetProfileID == BrowserProfile.defaultID {
                LiveContainerEnvironment.sharedDefaults.set(searchEngine.rawValue, forKey: BrowserSearchEngine.defaultsKey)
            }
        }
    }

    public var customSearchTemplate: String {
        didSet {
            guard oldValue != customSearchTemplate, !isSyncingProfilePreferences else { return }
            let targetProfileID = activeProfileID
            if let idx = profiles.firstIndex(where: { $0.id == targetProfileID }) {
                profiles[idx].customSearchTemplate = customSearchTemplate
                let updated = profiles[idx]
                let db = sqliteStore
                Task.detached(priority: .utility) {
                    db.upsertProfile(updated)
                }
            }
            if targetProfileID == BrowserProfile.defaultID {
                LiveContainerEnvironment.sharedDefaults.set(customSearchTemplate, forKey: BrowserSearchEngine.customTemplateDefaultsKey)
            }
        }
    }

    public var pdfAppearanceMode: PDFAppearanceMode {
        didSet {
            guard oldValue != pdfAppearanceMode else { return }
            LiveContainerEnvironment.sharedDefaults.set(pdfAppearanceMode.rawValue, forKey: PDFAppearanceMode.defaultsKey)
            broadcastPDFAppearanceChange()
        }
    }

    private func broadcastPDFAppearanceChange() {
        let activeID = activeTabID
        for tab in tabs where tab.activePDF != nil {
            tab.activePDF?.document.appearanceMode = pdfAppearanceMode
            if tab.id == activeID {
                tab.capturePreviewSnapshot()
            } else {
                tab.purgePreviewSnapshotForMemoryRelief()
            }
        }
    }

    public var pdfDisplayLayoutMode: PDFDisplayLayoutMode {
        didSet {
            guard oldValue != pdfDisplayLayoutMode else { return }
            LiveContainerEnvironment.sharedDefaults.set(pdfDisplayLayoutMode.rawValue, forKey: PDFDisplayLayoutMode.defaultsKey)
        }
    }

    private var lastHandledPasteboardChangeCount: Int = -1
    private var lastObservedDataVersion: Int64 = 0
    private var tabActivationLRU: [UUID] = []
    private var lastActiveTabIDByProfile: [String: UUID] = [:]
    private var parentTabIDByChildID: [UUID: UUID] = [:]
    private var sharedPrivateWebsiteDataStore: WKWebsiteDataStore?
    private let dataStoreRegistry = ProfileWebsiteDataStoreRegistry()
    private var isSyncingProfilePreferences: Bool = false
    private var lifecycleObserverTokens: [NSObjectProtocol] = []
    private var pendingTabsPersistTasksByProfile: [String: Task<Void, Never>] = [:]
    private var pendingOpenTabsSnapshotsByProfile: [String: [PersistedOpenTab]] = [:]
    private var pendingProfileUpsertTasks: [String: Task<Void, Never>] = [:]
    private var pendingProfileUpserts: [String: BrowserProfile] = [:]
    private var initialHydrationTask: Task<Void, Never>?
    private var lazyOrphanGCTask: Task<Void, Never>?
    private var bookmarksByFolderIndex: [String?: [BrowserBookmark]] = [:]
    private var bookmarkCountsByProfileID: [String: Int] = [:]
    private var siteRulesByProfileID: [String: [String: SiteRuleRecord]] = [:]
    /// Ephemeral per-site rules for Private Browsing tabs — never written to `browser.sqlite3`
    /// and purged immediately when the last Private tab closes.
    public private(set) var privateSiteRulesByHost: [String: SiteRuleRecord] = [:]
    public let sqliteStore: BrowserSQLiteStore
    /// Alias preserving clean read-site ergonomics for history queries.
    public var historyStore: BrowserSQLiteStore { sqliteStore }

    private struct SQLiteHydrationSnapshot: Sendable {
        let profiles: [BrowserProfile]
        let resolvedActiveProfileID: String
        let folders: [BrowserFavoriteFolder]
        let bookmarks: [BrowserBookmark]
        let bookmarkCountsByProfile: [String: Int]
        let totalHistoryCount: Int
        let openTabs: [PersistedOpenTab]
        let siteRulesByProfile: [String: [SiteRuleRecord]]
        let dataVersion: Int64
    }

    public init(customStateDirectory: URL? = nil) {
        Self.migratePalettePresetToSharedDefaultsIfNeeded()

        let dir: URL = customStateDirectory
            ?? LiveContainerEnvironment.persistentSubdirectory(named: "BrowserState", excludeFromiCloudBackup: true)
        // Defer SQLite open & bootstrap maintenance off `@MainActor` so cold launch never stalls the UI thread.
        let dbStore = BrowserSQLiteStore(stateDirectory: dir, deferOpen: true)
        self.sqliteStore = dbStore
        let preferredHostProfileID = (customStateDirectory == nil)
            ? (UserDefaults.standard.string(forKey: Self.activeProfileIDDefaultsKey) ?? BrowserProfile.defaultID)
            : BrowserProfile.defaultID
        self.activeProfileID = preferredHostProfileID
        self.userAgentProfile = BrowserUserAgentProfile.persistedCurrent
        let persistedMode = DarkReaderEngine.shared.modeBehavior
        self.webDarkModeBehavior = persistedMode
        self.webDarkThemePreset = DarkReaderEngine.shared.themePreset
        self.autoWebPageDarkMode = persistedMode.isEnabled
        self.isShieldEnabled = Self.persistedGlobalShieldEnabled
        self.searchEngine = BrowserSearchEngine.persistedCurrent
        self.customSearchTemplate = BrowserSearchEngine.persistedCustomTemplate
        self.pdfAppearanceMode = PDFAppearanceMode.persistedCurrent
        self.pdfDisplayLayoutMode = PDFDisplayLayoutMode.persistedCurrent

        // Seed a single lightweight dormant tab (zero `WKWebView` allocation until accessed/hydrated).
        let initialID = UUID()
        self.activeTabID = initialID
        self.tabActivationLRU = [initialID]
        self.tabs = [makeSession(id: initialID, isPrivate: false, profileID: preferredHostProfileID)]

        self.initialHydrationTask = Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                dbStore.performDeferredBootstrapIfNeeded()
                let loadedProfiles = dbStore.loadProfiles()
                let resolvedID = loadedProfiles.contains(where: { $0.id == preferredHostProfileID })
                    ? preferredHostProfileID
                    : (loadedProfiles.first(where: \.isDefault)?.id ?? BrowserProfile.defaultID)
                var allRules: [String: [SiteRuleRecord]] = [:]
                for p in loadedProfiles {
                    allRules[p.id] = dbStore.loadAllSiteRules(profileID: p.id)
                }
                return SQLiteHydrationSnapshot(
                    profiles: loadedProfiles,
                    resolvedActiveProfileID: resolvedID,
                    folders: dbStore.loadFolders(profileID: resolvedID),
                    bookmarks: dbStore.loadBookmarks(profileID: resolvedID),
                    bookmarkCountsByProfile: dbStore.bookmarkCountsByProfile(),
                    totalHistoryCount: dbStore.totalCount(profileID: resolvedID),
                    openTabs: dbStore.loadOpenTabs(profileID: nil),
                    siteRulesByProfile: allRules,
                    dataVersion: dbStore.dataVersion()
                )
            }.value
            guard let self else { return }
            self.applyInitialHydration(snapshot)
        }

        let nc = NotificationCenter.default
        lifecycleObserverTokens.append(
            nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let activeID = self.activeTabID
                    for tab in self.tabs where tab.id != activeID {
                        tab.purgePreviewSnapshotForMemoryRelief()
                        tab.setMediaPlaybackSuspended(true)
                    }
                    self.enforceLiveWebViewBudget(aggressive: true)
                    DarkReaderEngine.shared.purgeMemoryCache()
                    CleanroomContentBlocker.shared.purgeMemoryCache()
                }
            }
        )
        lifecycleObserverTokens.append(
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    SystemProxyBridge.syncAllTrackedDataStores()
                    self?.refreshFromSharedStoreIfChanged()
                }
            }
        )
        let dbForFlush = self.sqliteStore
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            lifecycleObserverTokens.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        let pendingTabs = self?.drainPendingOpenTabsSnapshots() ?? [:]
                        let pendingProfiles = self?.drainPendingProfileUpserts() ?? []
                        let bgGuard = BrowserBackgroundTaskGuard()
                        bgGuard.begin(name: "DysprosiumBrowserSQLiteFlush")
                        Task.detached(priority: .utility) {
                            for profile in pendingProfiles {
                                dbForFlush.upsertProfile(profile, checkpoint: false)
                            }
                            for (pid, records) in pendingTabs {
                                dbForFlush.saveOpenTabs(records, forProfileID: pid)
                            }
                            dbForFlush.flushForBackground()
                            await bgGuard.end()
                        }
                    }
                }
            )
        }
    }

    isolated deinit {
        initialHydrationTask?.cancel()
        lazyOrphanGCTask?.cancel()
        for task in pendingTabsPersistTasksByProfile.values {
            task.cancel()
        }
        for task in pendingProfileUpsertTasks.values {
            task.cancel()
        }
        for token in lifecycleObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func drainPendingOpenTabsSnapshots() -> [String: [PersistedOpenTab]] {
        for task in pendingTabsPersistTasksByProfile.values {
            task.cancel()
        }
        pendingTabsPersistTasksByProfile.removeAll()
        let snapshot = pendingOpenTabsSnapshotsByProfile
        pendingOpenTabsSnapshotsByProfile.removeAll()
        return snapshot
    }

    private func drainPendingProfileUpserts() -> [BrowserProfile] {
        for task in pendingProfileUpsertTasks.values {
            task.cancel()
        }
        pendingProfileUpsertTasks.removeAll()
        let pending = Array(pendingProfileUpserts.values)
        pendingProfileUpserts.removeAll()
        return pending
    }

    /// Awaits completion of the off-main cold-launch SQLite bootstrap hydration.
    public func waitForInitialHydration() async {
        await initialHydrationTask?.value
    }

    private func applyInitialHydration(_ snapshot: SQLiteHydrationSnapshot) {
        // Legacy global bypassed-host defaults have now been migrated into Default Profile `site_rules`.
        CleanroomContentBlocker.shared.clearLegacyBypassedHosts()
        DarkReaderEngine.shared.clearLegacyBypassedHosts()

        self.profiles = snapshot.profiles
        let resolvedProfileID = snapshot.resolvedActiveProfileID
        self.activeProfileID = resolvedProfileID
        if let defaultProfile = snapshot.profiles.first(where: \.isDefault) {
            FingerprintShieldEngine.shared.syncStandardSeed(defaultProfile.fingerprintSeed)
        }
        syncPreferencesFromActiveProfile(updateThemeStore: true)

        self.favoriteFolders = snapshot.folders
        self.bookmarks = snapshot.bookmarks
        self.bookmarkCountsByProfileID = snapshot.bookmarkCountsByProfile
        self.bookmarkCountsByProfileID[resolvedProfileID] = snapshot.bookmarks.count
        self.totalHistoryCount = snapshot.totalHistoryCount
        self.lastObservedDataVersion = snapshot.dataVersion
        self.siteRulesByProfileID = snapshot.siteRulesByProfile.mapValues { rules in
            Dictionary(
                uniqueKeysWithValues: rules.map {
                    (LiveContainerEnvironment.HostNormalizer.normalize($0.host), $0)
                }
            )
        }
        self.siteRulesByHost = self.siteRulesByProfileID[resolvedProfileID] ?? [:]
        self.rebuildBookmarksFolderIndex()

        let validProfileIDs = Set(snapshot.profiles.map(\.id))
        let persistedTabs = snapshot.openTabs.filter { validProfileIDs.contains($0.profileID) }

        if !persistedTabs.isEmpty {
            let userAlreadyInteracted = tabs.count > 1
                || activeSession.isLoading
                || !activeSession.currentURLString.isEmpty

            if !userAlreadyInteracted {
                for preTab in tabs {
                    preTab.teardown()
                }
                var builtTabs: [CleanroomWebKitSession] = []
                var chosenActiveForActiveProfile: UUID?
                for rec in persistedTabs {
                    let session = makeSession(id: rec.id, isPrivate: false, profileID: rec.profileID)
                    builtTabs.append(session)
                    if rec.isActive {
                        lastActiveTabIDByProfile[rec.profileID] = session.id
                        if rec.profileID == resolvedProfileID {
                            chosenActiveForActiveProfile = session.id
                        }
                    }
                }
                if !builtTabs.contains(where: { $0.profileID == resolvedProfileID }) {
                    let fresh = makeSession(id: UUID(), isPrivate: false, profileID: resolvedProfileID)
                    builtTabs.append(fresh)
                    chosenActiveForActiveProfile = fresh.id
                }
                let targetActiveID = chosenActiveForActiveProfile
                    ?? builtTabs.first(where: { $0.profileID == resolvedProfileID })?.id
                    ?? builtTabs[0].id
                self.tabs = builtTabs
                self.activeTabID = targetActiveID
                self.lastActiveTabIDByProfile[resolvedProfileID] = targetActiveID
                self.tabActivationLRU = builtTabs.map(\.id).filter { $0 != targetActiveID } + [targetActiveID]

                for (idx, session) in builtTabs.enumerated() where idx < persistedTabs.count {
                    let saved = persistedTabs[idx]
                    if !saved.urlString.isEmpty {
                        if session.id == targetActiveID {
                            // Hydrate ONLY the active profile's active tab at cold launch.
                            session.load(urlString: saved.urlString)
                        } else {
                            session.stageDeferredRestore(urlString: saved.urlString, title: saved.title)
                        }
                    }
                }
            } else {
                // If the pre-hydration tab on a secondary profile already materialized a fallback
                // `.nonPersistent()` WebView before `profiles` loaded, rebuild it against the real store.
                if let first = tabs.first,
                   !first.isPrivate,
                   let pid = first.profileID,
                   pid != BrowserProfile.defaultID,
                   first.hasLiveWebView {
                    let pendingURL = first.currentURLString
                    let rebuilt = makeSession(id: first.id, isPrivate: false, profileID: pid)
                    first.teardown()
                    tabs[0] = rebuilt
                    if !pendingURL.isEmpty {
                        rebuilt.load(urlString: pendingURL)
                    }
                }
                // Preserve the tab the user already started using; append persisted tabs dormantly.
                let existingIDs = Set(tabs.map(\.id))
                for saved in persistedTabs where !existingIDs.contains(saved.id) && !saved.urlString.isEmpty {
                    let session = makeSession(id: saved.id, isPrivate: false, profileID: saved.profileID)
                    session.stageDeferredRestore(urlString: saved.urlString, title: saved.title)
                    tabs.append(session)
                    tabActivationLRU.insert(session.id, at: 0)
                }
            }
        } else if tabs.first?.profileID != resolvedProfileID
                    || (resolvedProfileID != BrowserProfile.defaultID && tabs.first?.hasLiveWebView == true) {
            let pendingURL = tabs.first?.currentURLString ?? ""
            for preTab in tabs {
                preTab.teardown()
            }
            let fresh = makeSession(id: UUID(), isPrivate: false, profileID: resolvedProfileID)
            self.tabs = [fresh]
            self.activeTabID = fresh.id
            self.tabActivationLRU = [fresh.id]
            self.lastActiveTabIDByProfile[resolvedProfileID] = fresh.id
            if !pendingURL.isEmpty {
                fresh.load(urlString: pendingURL)
            }
        }

        self.isHydrated = true
        self.historyRevision &+= 1
        scheduleLazyOrphanStoreGC()
    }

    private func scheduleLazyOrphanStoreGC() {
        lazyOrphanGCTask?.cancel()
        let activeUUIDs = Set(profiles.compactMap(\.webkitStoreID))
        lazyOrphanGCTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            await self.dataStoreRegistry.collectOrphanedStores(keeping: activeUUIDs)
        }
    }

    private func syncPreferencesFromActiveProfile(updateThemeStore: Bool) {
        let current = activeProfile
        isSyncingProfilePreferences = true
        if userAgentProfile != current.userAgentProfile {
            userAgentProfile = current.userAgentProfile
        }
        if searchEngine != current.searchEngine {
            searchEngine = current.searchEngine
        }
        if customSearchTemplate != current.customSearchTemplate {
            customSearchTemplate = current.customSearchTemplate
        }
        isSyncingProfilePreferences = false

        if updateThemeStore && DysprosiumThemeStore.shared.selectedPreset != current.palettePreset {
            DysprosiumThemeStore.shared.select(current.palettePreset)
        }
    }

    /// Checks `PRAGMA data_version` off `@MainActor` on `willEnterForeground` and refreshes shared state
    /// whenever another LiveContainer instance (`LC 1` / `LC 2`) modified the shared `browser.sqlite3` database.
    public func refreshFromSharedStoreIfChanged() {
        let db = sqliteStore
        let previousVersion = lastObservedDataVersion
        let currentHostProfileID = activeProfileID
        Task { @MainActor [weak self] in
            let currentVersion = await Task.detached(priority: .utility) {
                db.dataVersion()
            }.value
            guard let self else { return }

            // Refresh global engine preferences regardless of DB version.
            DarkReaderEngine.shared.refreshPersistedPreferences()
            let latestDarkMode = DarkReaderEngine.shared.modeBehavior
            if self.webDarkModeBehavior != latestDarkMode { self.webDarkModeBehavior = latestDarkMode }
            let latestDarkPreset = DarkReaderEngine.shared.themePreset
            if self.webDarkThemePreset != latestDarkPreset { self.webDarkThemePreset = latestDarkPreset }
            let latestDark = latestDarkMode.isEnabled
            if self.autoWebPageDarkMode != latestDark { self.autoWebPageDarkMode = latestDark }
            let latestShield = Self.persistedGlobalShieldEnabled
            if self.isShieldEnabled != latestShield { self.isShieldEnabled = latestShield }
            let latestPDFAppearance = PDFAppearanceMode.persistedCurrent
            if self.pdfAppearanceMode != latestPDFAppearance { self.pdfAppearanceMode = latestPDFAppearance }
            let latestPDFLayout = PDFDisplayLayoutMode.persistedCurrent
            if self.pdfDisplayLayoutMode != latestPDFLayout { self.pdfDisplayLayoutMode = latestPDFLayout }

            guard currentVersion != previousVersion else { return }
            let previousProfilesByID = Dictionary(uniqueKeysWithValues: self.profiles.map { ($0.id, $0) })
            let refreshed = await Task.detached(priority: .utility) { () -> (
                profiles: [BrowserProfile],
                resolvedProfileID: String,
                folders: [BrowserFavoriteFolder],
                bookmarks: [BrowserBookmark],
                bookmarkCounts: [String: Int],
                totalHistory: Int,
                siteRulesByProfile: [String: [SiteRuleRecord]],
                openTabs: [PersistedOpenTab],
                version: Int64
            ) in
                let latestProfiles = db.loadProfiles()
                let resolvedID = latestProfiles.contains(where: { $0.id == currentHostProfileID })
                    ? currentHostProfileID
                    : (latestProfiles.first(where: \.isDefault)?.id ?? BrowserProfile.defaultID)
                var allRules: [String: [SiteRuleRecord]] = [:]
                for p in latestProfiles {
                    allRules[p.id] = db.loadAllSiteRules(profileID: p.id)
                }
                return (
                    profiles: latestProfiles,
                    resolvedProfileID: resolvedID,
                    folders: db.loadFolders(profileID: resolvedID),
                    bookmarks: db.loadBookmarks(profileID: resolvedID),
                    bookmarkCounts: db.bookmarkCountsByProfile(),
                    totalHistory: db.totalCount(profileID: resolvedID),
                    siteRulesByProfile: allRules,
                    openTabs: db.loadOpenTabs(profileID: nil),
                    version: db.dataVersion()
                )
            }.value
            let removedProfileIDs = Set(self.profiles.map(\.id)).subtracting(Set(refreshed.profiles.map(\.id)))
            self.profiles = refreshed.profiles
            if let defaultProfile = refreshed.profiles.first(where: \.isDefault) {
                FingerprintShieldEngine.shared.syncStandardSeed(defaultProfile.fingerprintSeed)
            }
            if self.activeProfileID != refreshed.resolvedProfileID {
                self.activeProfileID = refreshed.resolvedProfileID
                UserDefaults.standard.set(refreshed.resolvedProfileID, forKey: Self.activeProfileIDDefaultsKey)
            }
            self.syncPreferencesFromActiveProfile(updateThemeStore: true)

            if !removedProfileIDs.isEmpty {
                for victim in self.tabs where victim.profileID.map({ removedProfileIDs.contains($0) }) == true {
                    victim.teardown()
                    self.tabActivationLRU.removeAll { $0 == victim.id }
                }
                self.tabs.removeAll { $0.profileID.map({ removedProfileIDs.contains($0) }) == true }
                for deadID in removedProfileIDs {
                    self.recentlyClosedTabsByProfile.removeValue(forKey: deadID)
                    self.lastActiveTabIDByProfile.removeValue(forKey: deadID)
                    self.bookmarkCountsByProfileID.removeValue(forKey: deadID)
                    self.siteRulesByProfileID.removeValue(forKey: deadID)
                }
                if !self.tabs.contains(where: { $0.id == self.activeTabID }) {
                    let targetTab = self.ensureAtLeastOneTab(forProfileID: self.activeProfileID)
                    self.activeTabID = targetTab.id
                    self.touchTabLRU(targetTab.id)
                    targetTab.hydrateDeferredURLIfNeeded()
                    targetTab.syncDeferredSettingsIfNeeded(
                        userAgentProfile: self.userAgentProfile,
                        autoWebPageDarkMode: self.autoWebPageDarkMode
                    )
                }
                let activeUUIDs = Set(self.profiles.compactMap(\.webkitStoreID))
                Task { @MainActor [weak self] in
                    await self?.dataStoreRegistry.collectOrphanedStores(keeping: activeUUIDs)
                }
            }

            // Refresh dormant (unhydrated) profiles' `open_tabs` so switching profiles in Split View
            // (`LC 1` / `LC 2`) reflects tabs opened in the sibling host rather than clobbering them.
            let tabsByProfile = Dictionary(grouping: refreshed.openTabs, by: \.profileID)
            for p in refreshed.profiles where p.id != self.activeProfileID {
                let existingTabs = self.tabs.filter { !$0.isPrivate && $0.profileID == p.id }
                let hasAnyLiveTab = existingTabs.contains { $0.hasLiveWebView || $0.isHibernated }
                guard !hasAnyLiveTab, let remoteRecords = tabsByProfile[p.id], !remoteRecords.isEmpty else {
                    continue
                }
                let existingIDs = existingTabs.map(\.id)
                let remoteIDs = remoteRecords.map(\.id)
                let existingURLs = existingTabs.map(\.currentURLString)
                let remoteURLs = remoteRecords.map(\.urlString)
                guard existingIDs != remoteIDs || existingURLs != remoteURLs else { continue }

                for victim in existingTabs {
                    victim.teardown()
                    self.tabActivationLRU.removeAll { $0 == victim.id }
                }
                self.tabs.removeAll { !$0.isPrivate && $0.profileID == p.id }
                for rec in remoteRecords {
                    let session = self.makeSession(id: rec.id, isPrivate: false, profileID: p.id)
                    if !rec.urlString.isEmpty {
                        session.stageDeferredRestore(urlString: rec.urlString, title: rec.title)
                    }
                    self.tabs.append(session)
                    self.tabActivationLRU.insert(session.id, at: 0)
                    if rec.isActive {
                        self.lastActiveTabIDByProfile[p.id] = session.id
                    }
                }
            }

            // Propagate remote UA / Fingerprint Seed edits made in a sibling LiveContainer host.
            let activeID = self.activeTabID
            for updated in refreshed.profiles {
                guard let prev = previousProfilesByID[updated.id] else { continue }
                if prev.userAgentProfile != updated.userAgentProfile {
                    for tab in self.tabs where tab.profileID == updated.id {
                        if tab.id == activeID {
                            tab.applyUserAgentProfile(updated.userAgentProfile, reloadIfLoaded: true)
                        } else {
                            tab.markNeedsSettingsSyncOnActivate()
                        }
                    }
                }
                if prev.fingerprintSeed != updated.fingerprintSeed {
                    for tab in self.tabs where tab.profileID == updated.id {
                        tab.refreshCustomUserAgentForActivePersona()
                    }
                    let pid = updated.id
                    Task { @MainActor in
                        await CleanroomContentBlocker.shared.reapplyToAttachedControllers(matchingProfileID: pid)
                    }
                }
            }

            self.favoriteFolders = refreshed.folders
            self.bookmarks = refreshed.bookmarks
            self.bookmarkCountsByProfileID = refreshed.bookmarkCounts
            self.bookmarkCountsByProfileID[self.activeProfileID] = refreshed.bookmarks.count
            self.totalHistoryCount = refreshed.totalHistory
            self.siteRulesByProfileID = refreshed.siteRulesByProfile.mapValues { rules in
                Dictionary(
                    uniqueKeysWithValues: rules.map {
                        (LiveContainerEnvironment.HostNormalizer.normalize($0.host), $0)
                    }
                )
            }
            self.siteRulesByHost = self.siteRulesByProfileID[self.activeProfileID] ?? [:]
            self.lastObservedDataVersion = refreshed.version
            self.rebuildBookmarksFolderIndex()
            self.historyRevision &+= 1
        }
    }

    // MARK: - Multi-Profile Management & Zero-Restart Switching

    public func switchToProfile(id targetProfileID: String, activateTab: Bool = true) {
        guard profiles.contains(where: { $0.id == targetProfileID }) else { return }

        let departing = activeSession
        let departingProfileID = departing.profileID
        if !departing.isPrivate, let departingProfileID {
            lastActiveTabIDByProfile[departingProfileID] = departing.id
        }

        let needsProfileSwap = (activeProfileID != targetProfileID)
        if needsProfileSwap {
            applyActiveProfileMetadata(id: targetProfileID)
        }

        if activateTab {
            let targetTab: CleanroomWebKitSession = {
                if let rememberedID = lastActiveTabIDByProfile[targetProfileID],
                   let existing = tabs.first(where: { $0.id == rememberedID && !$0.isPrivate && $0.profileID == targetProfileID }) {
                    return existing
                }
                return ensureAtLeastOneTab(forProfileID: targetProfileID)
            }()

            if activeTabID != targetTab.id {
                departing.capturePreviewSnapshot()
                suspendDepartingTabIfNotPlaying(departing)
                activeTabID = targetTab.id
                touchTabLRU(targetTab.id)
                lastActiveTabIDByProfile[targetProfileID] = targetTab.id
                targetTab.setMediaPlaybackSuspended(false)
                targetTab.hydrateDeferredURLIfNeeded()
                targetTab.syncDeferredSettingsIfNeeded(
                    userAgentProfile: userAgentProfile,
                    autoWebPageDarkMode: autoWebPageDarkMode
                )
                enforceLiveWebViewBudget(aggressive: false)
                persistOpenTabsSnapshot(forProfileID: targetProfileID)
            }
        }
    }

    private func applyActiveProfileMetadata(id targetProfileID: String) {
        activeProfileID = targetProfileID
        UserDefaults.standard.set(targetProfileID, forKey: Self.activeProfileIDDefaultsKey)
        syncPreferencesFromActiveProfile(updateThemeStore: true)

        favoriteFolders = sqliteStore.loadFolders(profileID: targetProfileID)
        bookmarks = sqliteStore.loadBookmarks(profileID: targetProfileID)
        bookmarkCountsByProfileID[targetProfileID] = bookmarks.count
        totalHistoryCount = sqliteStore.totalCount(profileID: targetProfileID)
        if let cachedRules = siteRulesByProfileID[targetProfileID] {
            siteRulesByHost = cachedRules
        } else {
            let loaded = Dictionary(
                uniqueKeysWithValues: sqliteStore.loadAllSiteRules(profileID: targetProfileID).map {
                    (LiveContainerEnvironment.HostNormalizer.normalize($0.host), $0)
                }
            )
            siteRulesByProfileID[targetProfileID] = loaded
            siteRulesByHost = loaded
        }
        lastObservedDataVersion = sqliteStore.dataVersion()
        rebuildBookmarksFolderIndex()
        historyRevision &+= 1
    }

    private func ensureAtLeastOneTab(forProfileID profileID: String) -> CleanroomWebKitSession {
        if let existing = tabs.last(where: { !$0.isPrivate && $0.profileID == profileID }) {
            return existing
        }
        let fresh = makeSession(id: UUID(), isPrivate: false, profileID: profileID)
        tabs.append(fresh)
        tabActivationLRU.insert(fresh.id, at: 0)
        return fresh
    }

    @discardableResult
    public func createProfile(
        name: String,
        symbolName: String = "briefcase.fill",
        palettePreset: DysprosiumPalettePreset? = nil,
        userAgentProfile: BrowserUserAgentProfile = .iosSafari,
        searchEngine: BrowserSearchEngine = .duckDuckGo,
        customSearchTemplate: String = BrowserSearchEngine.defaultCustomTemplate,
        copyFavoritesFromDefault: Bool = false,
        activate: Bool = true
    ) -> BrowserProfile? {
        guard profiles.count < BrowserProfile.maxProfileCount else { return nil }
        let existingSeeds = Set(profiles.map(\.fingerprintSeed))
        let freshSeed = FingerprintShieldEngine.generateDistinctCryptographicSeed(
            avoidingSeeds: existingSeeds,
            profile: userAgentProfile
        )
        let chosenPalette: DysprosiumPalettePreset = {
            if let palettePreset { return palettePreset }
            let used = Set(profiles.map(\.palettePreset))
            return DysprosiumPalettePreset.allCases.first(where: { !used.contains($0) }) ?? .ultramarine
        }()
        let nextOrder = (profiles.map(\.sortOrder).max() ?? 0) + 100.0
        let created = BrowserProfile(
            id: UUID().uuidString,
            name: name,
            symbolName: symbolName,
            palettePreset: chosenPalette,
            isDefault: false,
            webkitStoreID: UUID(),
            fingerprintSeed: freshSeed,
            userAgentProfile: userAgentProfile,
            searchEngine: searchEngine,
            customSearchTemplate: customSearchTemplate,
            sortOrder: nextOrder,
            createdAt: Date()
        )
        sqliteStore.upsertProfile(created)
        if copyFavoritesFromDefault {
            sqliteStore.copyFavorites(fromProfileID: BrowserProfile.defaultID, toProfileID: created.id)
        }
        profiles = sqliteStore.loadProfiles()
        bookmarkCountsByProfileID = sqliteStore.bookmarkCountsByProfile()
        siteRulesByProfileID[created.id] = [:]
        lastObservedDataVersion = sqliteStore.dataVersion()

        if activate {
            switchToProfile(id: created.id, activateTab: true)
        }
        return profiles.first(where: { $0.id == created.id }) ?? created
    }

    public func updateProfile(_ updated: BrowserProfile, debounced: Bool = false) {
        guard let idx = profiles.firstIndex(where: { $0.id == updated.id }) else { return }
        let previous = profiles[idx]
        var mutableSanitized = updated
        mutableSanitized.name = BrowserProfile.sanitizedName(updated.name, fallback: updated.isDefault ? BrowserProfile.defaultName : "Profile")
        let sanitized = mutableSanitized
        profiles[idx] = sanitized

        let db = sqliteStore
        let pid = sanitized.id
        pendingProfileUpsertTasks[pid]?.cancel()
        if debounced {
            pendingProfileUpserts[pid] = sanitized
            pendingProfileUpsertTasks[pid] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.pendingProfileUpserts.removeValue(forKey: pid)
                self?.pendingProfileUpsertTasks.removeValue(forKey: pid)
                let ver = await Task.detached(priority: .utility) {
                    db.upsertProfile(sanitized, checkpoint: false)
                    return db.dataVersion()
                }.value
                self?.lastObservedDataVersion = ver
            }
        } else {
            pendingProfileUpserts.removeValue(forKey: pid)
            pendingProfileUpsertTasks.removeValue(forKey: pid)
            Task.detached(priority: .utility) {
                db.upsertProfile(sanitized, checkpoint: true)
            }
        }

        if sanitized.isDefault {
            FingerprintShieldEngine.shared.syncStandardSeed(sanitized.fingerprintSeed)
            LiveContainerEnvironment.sharedDefaults.set(sanitized.userAgentProfile.rawValue, forKey: BrowserUserAgentProfile.defaultsKey)
            LiveContainerEnvironment.sharedDefaults.set(sanitized.searchEngine.rawValue, forKey: BrowserSearchEngine.defaultsKey)
            LiveContainerEnvironment.sharedDefaults.set(sanitized.customSearchTemplate, forKey: BrowserSearchEngine.customTemplateDefaultsKey)
        }
        if sanitized.id == activeProfileID {
            syncPreferencesFromActiveProfile(updateThemeStore: true)
        }
        if previous.userAgentProfile != sanitized.userAgentProfile {
            let activeID = activeTabID
            for tab in tabs where tab.profileID == sanitized.id {
                if tab.id == activeID {
                    tab.applyUserAgentProfile(sanitized.userAgentProfile, reloadIfLoaded: true)
                } else {
                    tab.markNeedsSettingsSyncOnActivate()
                }
            }
        }
        if previous.fingerprintSeed != sanitized.fingerprintSeed {
            for tab in tabs where tab.profileID == sanitized.id {
                tab.refreshCustomUserAgentForActivePersona()
            }
            Task { @MainActor in
                await CleanroomContentBlocker.shared.reapplyToAttachedControllers(matchingProfileID: sanitized.id)
            }
        }
    }

    public func setActiveProfilePalette(_ preset: DysprosiumPalettePreset) {
        var current = activeProfile
        if current.palettePreset != preset {
            current.palettePreset = preset
            updateProfile(current, debounced: true)
        }
        DysprosiumThemeStore.shared.select(preset)
    }

    /// Refreshes `WKWebView.customUserAgent` across all live persistent tabs whenever global
    /// `FingerprintShieldEngine.shared.isEnabled` toggles so HTTP/Worker UA parity never drifts.
    public func refreshLiveUserAgentsForFingerprintShieldToggle() {
        for tab in tabs where !tab.isPrivate {
            tab.refreshCustomUserAgentForActivePersona()
        }
    }

    @discardableResult
    public func rotateFingerprintSeed(forProfileID profileID: String) -> String {
        guard let idx = profiles.firstIndex(where: { $0.id == profileID }) else {
            return FingerprintShieldEngine.generateCryptographicSeed()
        }
        let target = profiles[idx]
        let existingSeeds = Set(profiles.map(\.fingerprintSeed))
        let fresh = FingerprintShieldEngine.generateDistinctCryptographicSeed(
            avoidingSeeds: existingSeeds,
            profile: target.userAgentProfile
        )
        profiles[idx].fingerprintSeed = fresh
        let updated = profiles[idx]
        sqliteStore.upsertProfile(updated)
        lastObservedDataVersion = sqliteStore.dataVersion()
        if updated.isDefault {
            FingerprintShieldEngine.shared.syncStandardSeed(fresh)
        }
        for tab in tabs where !tab.isPrivate && tab.profileID == profileID {
            tab.refreshCustomUserAgentForActivePersona()
        }
        Task { @MainActor in
            await CleanroomContentBlocker.shared.reapplyToAttachedControllers(matchingProfileID: profileID)
        }
        return fresh
    }

    public func deleteProfile(id targetProfileID: String) async {
        guard targetProfileID != BrowserProfile.defaultID,
              let target = profiles.first(where: { $0.id == targetProfileID }) else {
            return
        }
        let storeUUID = target.webkitStoreID

        // Remove from `profiles` synchronously BEFORE any `await` to eliminate async reentrancy
        // windows where UI actions could re-enter the doomed profile during teardown.
        pendingProfileUpsertTasks[targetProfileID]?.cancel()
        pendingProfileUpsertTasks.removeValue(forKey: targetProfileID)
        pendingProfileUpserts.removeValue(forKey: targetProfileID)
        pendingTabsPersistTasksByProfile[targetProfileID]?.cancel()
        pendingTabsPersistTasksByProfile.removeValue(forKey: targetProfileID)
        pendingOpenTabsSnapshotsByProfile.removeValue(forKey: targetProfileID)

        if activeProfileID == targetProfileID || activeSession.profileID == targetProfileID {
            switchToProfile(id: BrowserProfile.defaultID, activateTab: true)
        }

        profiles.removeAll { $0.id == targetProfileID }
        bookmarkCountsByProfileID.removeValue(forKey: targetProfileID)
        siteRulesByProfileID.removeValue(forKey: targetProfileID)

        let victims = tabs.filter { !$0.isPrivate && $0.profileID == targetProfileID }
        let victimIDs = Set(victims.map(\.id))
        for tab in victims {
            tab.teardown()
            tabActivationLRU.removeAll { $0 == tab.id }
            parentTabIDByChildID.removeValue(forKey: tab.id)
        }
        parentTabIDByChildID = parentTabIDByChildID.filter { !victimIDs.contains($0.value) }
        tabs.removeAll { !$0.isPrivate && $0.profileID == targetProfileID }
        recentlyClosedTabsByProfile.removeValue(forKey: targetProfileID)
        lastActiveTabIDByProfile.removeValue(forKey: targetProfileID)

        // Scrub any persisted download auth headers (`Cookie` / `Authorization`) attributed to this profile.
        if let scrub = onScrubTransferAuthData {
            await scrub(targetProfileID)
        }

        let db = sqliteStore
        let updated = await Task.detached(priority: .userInitiated) { () -> ([BrowserProfile], [String: Int], Int64) in
            db.deleteProfile(id: targetProfileID)
            return (db.loadProfiles(), db.bookmarkCountsByProfile(), db.dataVersion())
        }.value
        profiles = updated.0
        bookmarkCountsByProfileID = updated.1
        bookmarkCountsByProfileID[activeProfileID] = bookmarks.count
        lastObservedDataVersion = updated.2
        historyRevision &+= 1

        if let storeUUID {
            await dataStoreRegistry.removeStore(forIdentifier: storeUUID)
        }
    }

    public func bookmarkCount(forProfileID id: String) -> Int {
        if id == activeProfileID {
            return bookmarks.count
        }
        return bookmarkCountsByProfileID[id] ?? 0
    }

    public func historyCount(forProfileID id: String) -> Int {
        if id == activeProfileID {
            return totalHistoryCount
        }
        return sqliteStore.totalCount(profileID: id)
    }

    public var activeSession: CleanroomWebKitSession {
        tabs.first(where: { $0.id == activeTabID }) ?? tabs[0]
    }

    public var totalDetectedMediaCount: Int {
        tabs.reduce(0) { $0 + $1.discoveredMediaBadgeCount }
    }

    public var liveWebViewCount: Int {
        tabs.reduce(0) { $0 + ($1.hasLiveWebView ? 1 : 0) }
    }

    // MARK: - Shared Ephemeral Private Store & LRU WebView Hibernation

    private func acquireSharedPrivateWebsiteDataStore() -> WKWebsiteDataStore {
        if let existing = sharedPrivateWebsiteDataStore {
            return existing
        }
        let created = WKWebsiteDataStore.nonPersistent()
        sharedPrivateWebsiteDataStore = created
        return created
    }

    private func discardSharedPrivateWebsiteDataStoreIfNoPrivateTabsRemain() {
        guard !tabs.contains(where: \.isPrivate) else { return }
        privateSiteRulesByHost.removeAll(keepingCapacity: false)
        if let scrub = onScrubTransferAuthData {
            Task { @MainActor in
                await scrub(BrowserProfile.privateTransferProfileID)
            }
        }
        guard let store = sharedPrivateWebsiteDataStore else { return }
        sharedPrivateWebsiteDataStore = nil
        Task { @MainActor in
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    private func touchTabLRU(_ id: UUID) {
        tabActivationLRU.removeAll { $0 == id }
        tabActivationLRU.append(id)
    }

    /// Hibernates oldest inactive `WKWebView`s when live WebViews exceed `maxLiveWebViews` (`4`) or `1` under memory pressure,
    /// AND caps idle live WebViews across inactive profiles to `<= 1` (`0` under memory pressure) so toggling back
    /// between your two most recent profiles (`Personal ↔ Work`) is instant while 3–6 profiles never multiply WebContent RAM.
    /// Always exempts the active tab, tabs with active downloads, and active-profile tabs with live media/PiP/fullscreen/camera/mic.
    public func enforceLiveWebViewBudget(aggressive: Bool = false) {
        let tabByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        // Drop permanent `window.open` opener protection under memory pressure so old openers cannot defeat Jetsam relief.
        let protectedParentIDs: Set<UUID> = aggressive ? [] : Set(parentTabIDByChildID.values)
        let lruSet = Set(tabActivationLRU)
        let missingFromLRU = tabs.map(\.id).filter { !lruSet.contains($0) }
        let orderedCandidates = missingFromLRU + tabActivationLRU

        let activeTab = activeSession
        let activeBucketIsPrivate = activeTab.isPrivate
        let activeBucketProfileID = activeTab.profileID

        func isHibernationExempt(_ tab: CleanroomWebKitSession, isInactiveProfile: Bool) -> Bool {
            if hasActiveDownloadForTab?(tab.id) == true || tab.hasActiveWKDownload || tab.hasActiveDownload {
                return true
            }
            if aggressive || isInactiveProfile {
                // Under memory pressure or across inactive profiles, do not let latched autoplay `.playing`
                // block reclamation; only protect active fullscreen / camera / microphone / PiP capture.
                if let wv = tab.liveWebViewIfLoaded,
                   (wv.fullscreenState != .notInFullscreen || wv.cameraCaptureState != .none || wv.microphoneCaptureState != .none) {
                    return true
                }
                return false
            }
            return tab.isExemptFromHibernation
        }

        // Pass 1: Enforce inactive-profile idle live WebView cap (`<= 1` normal, `0` aggressive).
        let inactiveProfileCap = aggressive ? 0 : Self.maxInactiveProfileLiveWebViews
        var inactiveProfileLiveCount = tabs.reduce(0) { acc, tab in
            let sameBucket = (tab.isPrivate == activeBucketIsPrivate && tab.profileID == activeBucketProfileID)
            return acc + ((!sameBucket && tab.hasLiveWebView) ? 1 : 0)
        }
        if inactiveProfileLiveCount > inactiveProfileCap {
            for candidateID in orderedCandidates {
                guard inactiveProfileLiveCount > inactiveProfileCap else { break }
                guard candidateID != activeTabID,
                      let candidate = tabByID[candidateID],
                      candidate.hasLiveWebView else {
                    continue
                }
                let sameBucket = (candidate.isPrivate == activeBucketIsPrivate && candidate.profileID == activeBucketProfileID)
                guard !sameBucket else { continue }
                if isHibernationExempt(candidate, isInactiveProfile: true) {
                    continue
                }
                candidate.hibernateWebView()
                inactiveProfileLiveCount -= 1
            }
        }

        // Pass 2: Enforce global live WebView cap across all profiles + Private combined.
        let budget = aggressive ? 1 : Self.maxLiveWebViews
        var currentLiveCount = liveWebViewCount
        guard currentLiveCount > budget else { return }

        for candidateID in orderedCandidates {
            guard currentLiveCount > budget else { break }
            guard candidateID != activeTabID,
                  !protectedParentIDs.contains(candidateID),
                  let candidate = tabByID[candidateID],
                  candidate.hasLiveWebView else {
                continue
            }
            let sameBucket = (candidate.isPrivate == activeBucketIsPrivate && candidate.profileID == activeBucketProfileID)
            if isHibernationExempt(candidate, isInactiveProfile: !sameBucket) {
                continue
            }
            candidate.hibernateWebView()
            currentLiveCount -= 1
        }
    }

    /// Captures a preview snapshot lazily for the currently active tab right before presenting the Tab Switcher.
    public func prepareTabSwitcherPreviews() {
        activeSession.capturePreviewSnapshot()
    }

    // MARK: - Multi-Tab Lifecycle, Recently Closed Tabs & Session Persistence

    @discardableResult
    public func openNewTab(
        urlString: String? = nil,
        isPrivate: Bool = false,
        activate: Bool = true,
        profileID: String? = nil
    ) -> CleanroomWebKitSession {
        let departing = activeSession
        let targetProfileID: String? = isPrivate ? nil : (profileID ?? activeProfileID)
        let session = makeSession(id: UUID(), isPrivate: isPrivate, profileID: targetProfileID)
        tabs.append(session)
        if activate {
            departing.capturePreviewSnapshot()
            suspendDepartingTabIfNotPlaying(departing)
            if !departing.isPrivate, let departingPID = departing.profileID {
                lastActiveTabIDByProfile[departingPID] = departing.id
            }
            if !isPrivate, let targetProfileID, targetProfileID != activeProfileID {
                applyActiveProfileMetadata(id: targetProfileID)
            }
            activeTabID = session.id
            if let targetProfileID {
                lastActiveTabIDByProfile[targetProfileID] = session.id
            }
            touchTabLRU(session.id)
            session.setMediaPlaybackSuspended(false)
        } else {
            tabActivationLRU.insert(session.id, at: 0)
        }
        if let urlString, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if activate {
                session.load(urlString: urlString)
            } else {
                // Keep background-opened tabs dormant with zero WKWebView / network / autoplay heat until tapped.
                session.stageDeferredRestore(urlString: urlString, title: "")
            }
        }
        enforceLiveWebViewBudget(aggressive: false)
        if let targetProfileID {
            persistOpenTabsSnapshot(forProfileID: targetProfileID)
        }
        return session
    }

    /// Creates a child tab initialized directly with WebKit's `createWebViewWith` configuration
    /// so OAuth `window.opener.postMessage` and `window.close()` operate natively.
    public func openChildTab(
        configuration: WKWebViewConfiguration,
        initialURL: URL?,
        isPrivate: Bool,
        profileID: String? = nil,
        openerTabID: UUID? = nil
    ) -> WKWebView {
        let departing = activeSession
        let resolvedOpener = openerTabID.flatMap { id in tabs.first(where: { $0.id == id }) } ?? departing
        let resolvedProfileID: String? = isPrivate ? nil : (profileID ?? resolvedOpener.profileID ?? activeProfileID)
        let child = makeSession(id: UUID(), isPrivate: isPrivate, profileID: resolvedProfileID)
        let childWebView = child.attachChildWebView(using: configuration, initialURL: initialURL)

        if let parentIdx = tabs.firstIndex(where: { $0.id == resolvedOpener.id }) {
            tabs.insert(child, at: parentIdx + 1)
        } else {
            tabs.append(child)
        }
        parentTabIDByChildID[child.id] = resolvedOpener.id

        departing.capturePreviewSnapshot()
        suspendDepartingTabIfNotPlaying(departing)
        if !isPrivate, let resolvedProfileID, resolvedProfileID != activeProfileID {
            applyActiveProfileMetadata(id: resolvedProfileID)
        }
        activeTabID = child.id
        if let resolvedProfileID {
            lastActiveTabIDByProfile[resolvedProfileID] = child.id
        }
        touchTabLRU(child.id)
        child.setMediaPlaybackSuspended(false)

        enforceLiveWebViewBudget(aggressive: false)
        if let resolvedProfileID {
            persistOpenTabsSnapshot(forProfileID: resolvedProfileID)
        }
        return childWebView
    }

    public func switchToTab(id: UUID) {
        guard let target = tabs.first(where: { $0.id == id }) else { return }
        if activeTabID != id {
            let departing = activeSession
            departing.capturePreviewSnapshot()
            suspendDepartingTabIfNotPlaying(departing)
            if !departing.isPrivate, let departingPID = departing.profileID {
                lastActiveTabIDByProfile[departingPID] = departing.id
            }
        }
        if !target.isPrivate, let targetPID = target.profileID {
            if targetPID != activeProfileID {
                applyActiveProfileMetadata(id: targetPID)
            }
            lastActiveTabIDByProfile[targetPID] = target.id
        }
        activeTabID = id
        touchTabLRU(id)
        target.setMediaPlaybackSuspended(false)
        target.hydrateDeferredURLIfNeeded()
        target.syncDeferredSettingsIfNeeded(
            userAgentProfile: userAgentProfile,
            autoWebPageDarkMode: autoWebPageDarkMode
        )
        enforceLiveWebViewBudget(aggressive: false)
        if let targetPID = target.profileID {
            persistOpenTabsSnapshot(forProfileID: targetPID)
        }
    }

    /// Opens a local `.pdf` file (from Downloads Vault or iOS Files / Share Sheet) directly in a browser tab.
    /// Reuses an existing tab if the same Vault file is already open, or reuses an empty Start Page tab;
    /// copies security-scoped external files into temporary preview storage so sandbox revocation never breaks viewing.
    @discardableResult
    public func openLocalPDFTab(
        fileURL: URL,
        displayTitle: String? = nil,
        copyIfExternalSecurityScoped: Bool = false
    ) -> CleanroomWebKitSession {
        let standardizedPath = fileURL.standardizedFileURL.path
        if !copyIfExternalSecurityScoped,
           let existing = tabs.first(where: { !$0.isPrivate && $0.profileID == activeProfileID && $0.activePDF?.localFileURL.standardizedFileURL.path == standardizedPath }) {
            switchToTab(id: existing.id)
            return existing
        }

        let targetSession: CleanroomWebKitSession
        if !activeSession.isPrivate && activeSession.profileID == activeProfileID && activeSession.currentURLString.isEmpty && !activeSession.isLoading && activeSession.activePDF == nil {
            targetSession = activeSession
        } else {
            targetSession = openNewTab(urlString: nil, isPrivate: false, activate: true, profileID: activeProfileID)
        }

        if copyIfExternalSecurityScoped {
            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            let vaultRoot = LiveContainerEnvironment.downloadsDirectory.standardizedFileURL.path
            if standardizedPath.hasPrefix(vaultRoot + "/") {
                targetSession.openLocalPDF(fileURL: fileURL, displayTitle: displayTitle, isTemporaryPreviewFile: false)
            } else {
                let tempCopy = PDFTabDocument.makeTemporaryPreviewFileURL(
                    tabID: targetSession.id,
                    suggestedFilename: displayTitle ?? fileURL.lastPathComponent
                )
                if (try? FileManager.default.copyItem(at: fileURL, to: tempCopy)) != nil {
                    targetSession.openLocalPDF(
                        fileURL: tempCopy,
                        displayTitle: displayTitle ?? fileURL.lastPathComponent,
                        isTemporaryPreviewFile: true,
                        sourceURLOverride: fileURL
                    )
                } else {
                    targetSession.openLocalPDF(fileURL: fileURL, displayTitle: displayTitle, isTemporaryPreviewFile: false)
                }
            }
        } else {
            targetSession.openLocalPDF(fileURL: fileURL, displayTitle: displayTitle, isTemporaryPreviewFile: false)
        }

        persistOpenTabsSnapshot()
        return targetSession
    }

    public func switchToAdjacentTab(delta: Int) {
        guard delta != 0 else { return }
        let scopeIsPrivate = activeSession.isPrivate
        let scopeProfileID = activeSession.profileID
        let scopedTabs = tabs.filter { $0.isPrivate == scopeIsPrivate && $0.profileID == scopeProfileID }
        guard scopedTabs.count > 1,
              let currentIndex = scopedTabs.firstIndex(where: { $0.id == activeTabID }) else {
            return
        }
        let count = scopedTabs.count
        let nextIndex = ((currentIndex + delta) % count + count) % count
        switchToTab(id: scopedTabs[nextIndex].id)
    }

    public func duplicateTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let source = tabs[idx]
        let departing = activeSession
        let copy = makeSession(id: UUID(), isPrivate: source.isPrivate, profileID: source.profileID)
        tabs.insert(copy, at: idx + 1)

        departing.capturePreviewSnapshot()
        suspendDepartingTabIfNotPlaying(departing)
        if !source.isPrivate, let srcPID = source.profileID {
            if srcPID != activeProfileID {
                applyActiveProfileMetadata(id: srcPID)
            }
            lastActiveTabIDByProfile[srcPID] = copy.id
        }
        activeTabID = copy.id
        touchTabLRU(copy.id)
        copy.setMediaPlaybackSuspended(false)

        let sourceURL = source.currentURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sourceURL.isEmpty {
            copy.load(urlString: sourceURL)
        }
        enforceLiveWebViewBudget(aggressive: false)
        if let srcPID = source.profileID {
            persistOpenTabsSnapshot(forProfileID: srcPID)
        }
    }

    public func closeOtherTabs(keeping id: UUID) {
        guard let keeper = tabs.first(where: { $0.id == id }) else { return }
        let scopeIsPrivate = keeper.isPrivate
        let scopeProfileID = keeper.profileID
        let victims = tabs.filter { $0.isPrivate == scopeIsPrivate && $0.profileID == scopeProfileID && $0.id != id }
        guard !victims.isEmpty else { return }

        for tab in victims {
            recordRecentlyClosedIfStandard(tab)
            tab.teardown()
            tabActivationLRU.removeAll { $0 == tab.id }
            parentTabIDByChildID.removeValue(forKey: tab.id)
        }
        let victimIDs = Set(victims.map(\.id))
        parentTabIDByChildID = parentTabIDByChildID.filter { !victimIDs.contains($0.value) }
        tabs.removeAll { $0.isPrivate == scopeIsPrivate && $0.profileID == scopeProfileID && $0.id != id }

        if !tabs.contains(where: { $0.id == activeTabID }) {
            if !keeper.isPrivate, let pid = keeper.profileID, pid != activeProfileID {
                applyActiveProfileMetadata(id: pid)
            }
            activeTabID = keeper.id
            if let pid = keeper.profileID {
                lastActiveTabIDByProfile[pid] = keeper.id
            }
            touchTabLRU(keeper.id)
            keeper.setMediaPlaybackSuspended(false)
            keeper.hydrateDeferredURLIfNeeded()
            keeper.syncDeferredSettingsIfNeeded(
                userAgentProfile: userAgentProfile,
                autoWebPageDarkMode: autoWebPageDarkMode
            )
        }
        if let scopeProfileID {
            persistOpenTabsSnapshot(forProfileID: scopeProfileID)
        }
    }

    private func suspendDepartingTabIfNotPlaying(_ departing: CleanroomWebKitSession) {
        guard departing.hasLiveWebView else { return }
        if departing.isExemptFromHibernation {
            return
        }
        Task { @MainActor [weak self, weak departing] in
            guard let departing else { return }
            let playbackState = await departing.refreshMediaPlaybackState()
            guard let self, self.activeTabID != departing.id else { return }
            if playbackState != .playing && !departing.isExemptFromHibernation {
                departing.setMediaPlaybackSuspended(true)
            }
        }
    }

    public func closeAllTabs(isPrivate: Bool, profileID: String? = nil) {
        let targetProfileID: String? = isPrivate ? nil : (profileID ?? activeProfileID)
        let victims = tabs.filter { $0.isPrivate == isPrivate && $0.profileID == targetProfileID }
        guard !victims.isEmpty else { return }
        let victimIDs = Set(victims.map(\.id))
        for tab in victims {
            recordRecentlyClosedIfStandard(tab)
            tab.teardown()
            tabActivationLRU.removeAll { $0 == tab.id }
            parentTabIDByChildID.removeValue(forKey: tab.id)
        }
        parentTabIDByChildID = parentTabIDByChildID.filter { !victimIDs.contains($0.value) }
        tabs.removeAll { $0.isPrivate == isPrivate && $0.profileID == targetProfileID }

        if isPrivate {
            discardSharedPrivateWebsiteDataStoreIfNoPrivateTabsRemain()
        } else if let targetProfileID {
            lastActiveTabIDByProfile.removeValue(forKey: targetProfileID)
        }

        if !tabs.contains(where: { $0.id == activeTabID }) {
            let fallbackProfileID = targetProfileID ?? activeProfileID
            let nextActive = ensureAtLeastOneTab(forProfileID: fallbackProfileID)
            if fallbackProfileID != activeProfileID {
                applyActiveProfileMetadata(id: fallbackProfileID)
            }
            activeTabID = nextActive.id
            lastActiveTabIDByProfile[fallbackProfileID] = nextActive.id
            touchTabLRU(nextActive.id)
            nextActive.hydrateDeferredURLIfNeeded()
            nextActive.syncDeferredSettingsIfNeeded(
                userAgentProfile: userAgentProfile,
                autoWebPageDarkMode: autoWebPageDarkMode
            )
        }
        if let targetProfileID {
            persistOpenTabsSnapshot(forProfileID: targetProfileID)
        }
    }

    public func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removing = tabs[idx]
        let wasPrivate = removing.isPrivate
        let removedProfileID = removing.profileID
        let preferredParentID = parentTabIDByChildID.removeValue(forKey: id)
        parentTabIDByChildID = parentTabIDByChildID.filter { $0.value != id }

        recordRecentlyClosedIfStandard(removing)
        removing.teardown()
        tabs.remove(at: idx)
        tabActivationLRU.removeAll { $0 == id }

        if wasPrivate {
            discardSharedPrivateWebsiteDataStoreIfNoPrivateTabsRemain()
        } else if let removedProfileID, lastActiveTabIDByProfile[removedProfileID] == id {
            lastActiveTabIDByProfile.removeValue(forKey: removedProfileID)
        }

        let sameBucketRemaining = tabs.filter { $0.isPrivate == wasPrivate && $0.profileID == removedProfileID }
        if !wasPrivate, let removedProfileID, sameBucketRemaining.isEmpty && activeTabID == id {
            let fresh = makeSession(id: UUID(), isPrivate: false, profileID: removedProfileID)
            tabs.append(fresh)
            activeTabID = fresh.id
            lastActiveTabIDByProfile[removedProfileID] = fresh.id
            touchTabLRU(fresh.id)
        } else if tabs.isEmpty {
            let fresh = makeSession(id: UUID(), isPrivate: false, profileID: activeProfileID)
            tabs = [fresh]
            activeTabID = fresh.id
            lastActiveTabIDByProfile[activeProfileID] = fresh.id
            touchTabLRU(fresh.id)
        } else if activeTabID == id {
            let nextActive: CleanroomWebKitSession
            if let preferredParentID,
               let parentTab = tabs.first(where: { $0.id == preferredParentID }) {
                nextActive = parentTab
            } else if let lastInSameBucket = sameBucketRemaining.last {
                nextActive = lastInSameBucket
            } else {
                nextActive = ensureAtLeastOneTab(forProfileID: activeProfileID)
            }
            if !nextActive.isPrivate, let nextPID = nextActive.profileID {
                if nextPID != activeProfileID {
                    applyActiveProfileMetadata(id: nextPID)
                }
                lastActiveTabIDByProfile[nextPID] = nextActive.id
            }
            activeTabID = nextActive.id
            touchTabLRU(nextActive.id)
            nextActive.setMediaPlaybackSuspended(false)
            nextActive.hydrateDeferredURLIfNeeded()
            nextActive.syncDeferredSettingsIfNeeded(
                userAgentProfile: userAgentProfile,
                autoWebPageDarkMode: autoWebPageDarkMode
            )
        }
        if let removedProfileID {
            persistOpenTabsSnapshot(forProfileID: removedProfileID)
        } else if let activePID = activeSession.profileID {
            persistOpenTabsSnapshot(forProfileID: activePID)
        }
    }

    private func recordRecentlyClosedIfStandard(_ tab: CleanroomWebKitSession) {
        guard !tab.isPrivate, let profileID = tab.profileID else { return }
        let urlStr = tab.currentURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlStr.isEmpty else { return }
        let entry = RecentlyClosedTab(
            id: UUID(),
            urlString: urlStr,
            title: tab.displayTabTitle,
            closedAt: Date()
        )
        var stack = recentlyClosedTabsByProfile[profileID] ?? []
        stack.insert(entry, at: 0)
        if stack.count > Self.maxRecentlyClosedTabs {
            stack.removeLast(stack.count - Self.maxRecentlyClosedTabs)
        }
        recentlyClosedTabsByProfile[profileID] = stack
    }

    @discardableResult
    public func reopenLastClosedTab(profileID: String? = nil) -> CleanroomWebKitSession? {
        let targetPID = profileID ?? activeProfileID
        guard var stack = recentlyClosedTabsByProfile[targetPID], !stack.isEmpty else { return nil }
        let last = stack.removeFirst()
        recentlyClosedTabsByProfile[targetPID] = stack
        return openNewTab(urlString: last.urlString, isPrivate: false, activate: true, profileID: targetPID)
    }

    public func clearRecentlyClosedTabs(profileID: String? = nil) {
        let targetPID = profileID ?? activeProfileID
        recentlyClosedTabsByProfile[targetPID] = []
    }

    private func persistOpenTabsSnapshot(forProfileID profileID: String? = nil) {
        let targetProfileID = profileID ?? activeProfileID
        let currentActiveForProfile = (activeSession.profileID == targetProfileID)
            ? activeTabID
            : lastActiveTabIDByProfile[targetProfileID]
        let vaultRoot = LiveContainerEnvironment.downloadsDirectory.standardizedFileURL.path
        let records: [PersistedOpenTab] = tabs
            .filter { !$0.isPrivate && $0.profileID == targetProfileID }
            .enumerated()
            .map { idx, tab in
                let rawURL = tab.currentURLString
                let persistedURL: String
                if rawURL.lowercased().hasPrefix("file://"),
                   let parsed = URL(string: rawURL),
                   !parsed.standardizedFileURL.path.hasPrefix(vaultRoot + "/") {
                    // Never persist ephemeral Files-picker copies or temporary preview paths across launches.
                    persistedURL = ""
                } else {
                    persistedURL = rawURL
                }
                return PersistedOpenTab(
                    id: tab.id,
                    profileID: targetProfileID,
                    urlString: persistedURL,
                    title: persistedURL.isEmpty ? "" : tab.pageTitle,
                    sortOrder: Double(idx + 1) * 100.0,
                    isActive: tab.id == currentActiveForProfile
                )
            }
        let db = sqliteStore
        pendingOpenTabsSnapshotsByProfile[targetProfileID] = records
        pendingTabsPersistTasksByProfile[targetProfileID]?.cancel()
        pendingTabsPersistTasksByProfile[targetProfileID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.pendingOpenTabsSnapshotsByProfile.removeValue(forKey: targetProfileID)
            self?.pendingTabsPersistTasksByProfile.removeValue(forKey: targetProfileID)
            let version = await Task.detached(priority: .utility) {
                db.saveOpenTabs(records, forProfileID: targetProfileID)
                return db.dataVersion()
            }.value
            self?.lastObservedDataVersion = version
        }
    }

    // MARK: - Per-Site Policy Rules (`site_rules` in `browser.sqlite3` + Ephemeral Private Map)

    public func siteRule(forHost rawHost: String, profileID: String? = nil, isPrivate: Bool = false) -> SiteRuleRecord? {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
        guard !host.isEmpty else { return nil }
        if isPrivate {
            return privateSiteRulesByHost[host]
        }
        let targetPID = profileID ?? activeProfileID
        if targetPID == activeProfileID {
            return siteRulesByHost[host]
        }
        if let profileMap = siteRulesByProfileID[targetPID] {
            return profileMap[host]
        }
        // Only hits SQLite if a profile has never been loaded into `siteRulesByProfileID`.
        let loaded = Dictionary(
            uniqueKeysWithValues: sqliteStore.loadAllSiteRules(profileID: targetPID).map {
                (LiveContainerEnvironment.HostNormalizer.normalize($0.host), $0)
            }
        )
        siteRulesByProfileID[targetPID] = loaded
        return loaded[host]
    }

    public func updateSiteRule(_ rule: SiteRuleRecord, profileID: String? = nil, isPrivate: Bool = false) {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rule.host)
        guard !host.isEmpty else { return }
        let normalizedRule = SiteRuleRecord(
            host: host,
            shieldMode: rule.shieldMode,
            darkMode: rule.darkMode,
            uaMode: rule.uaMode,
            pageZoom: rule.pageZoom
        )

        if isPrivate {
            let previousRule = privateSiteRulesByHost[host]
            if normalizedRule.isAllDefault {
                privateSiteRulesByHost.removeValue(forKey: host)
            } else {
                privateSiteRulesByHost[host] = normalizedRule
            }
            applySiteRuleToMatchingTabs(
                host: host,
                previousRule: previousRule,
                rule: normalizedRule,
                profileID: nil,
                isPrivate: true
            )
            return
        }

        let targetPID = profileID ?? activeProfileID
        let previousRule = siteRule(forHost: host, profileID: targetPID)
        var profileMap = siteRulesByProfileID[targetPID] ?? (targetPID == activeProfileID ? siteRulesByHost : [:])
        if normalizedRule.isAllDefault {
            profileMap.removeValue(forKey: host)
        } else {
            profileMap[host] = normalizedRule
        }
        siteRulesByProfileID[targetPID] = profileMap
        if targetPID == activeProfileID {
            siteRulesByHost = profileMap
        }
        let db = sqliteStore
        Task.detached(priority: .utility) {
            db.upsertSiteRule(normalizedRule, profileID: targetPID)
        }
        applySiteRuleToMatchingTabs(
            host: host,
            previousRule: previousRule,
            rule: normalizedRule,
            profileID: targetPID,
            isPrivate: false
        )
    }

    public func updateSiteRule(
        forHost rawHost: String,
        shieldMode: Int? = nil,
        darkMode: Int? = nil,
        uaMode: Int? = nil,
        pageZoom: Double? = nil,
        resetPageZoom: Bool = false,
        profileID: String? = nil,
        isPrivate: Bool = false
    ) {
        let targetPID = profileID ?? activeProfileID
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
        guard !host.isEmpty else { return }
        var current = siteRule(forHost: host, profileID: targetPID, isPrivate: isPrivate) ?? SiteRuleRecord(host: host)
        if let shieldMode { current.shieldMode = shieldMode }
        if let darkMode { current.darkMode = darkMode }
        if let uaMode { current.uaMode = uaMode }
        if resetPageZoom {
            current.pageZoom = nil
        } else if let pageZoom {
            let clamped = SiteRuleRecord.clampedZoom(pageZoom)
            current.pageZoom = abs(clamped - 1.0) < 0.001 ? nil : clamped
        }
        updateSiteRule(current, profileID: targetPID, isPrivate: isPrivate)
    }

    public func resetSiteRule(forHost rawHost: String, profileID: String? = nil, isPrivate: Bool = false) {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
        guard !host.isEmpty else { return }
        if isPrivate {
            let previousRule = privateSiteRulesByHost.removeValue(forKey: host)
            applySiteRuleToMatchingTabs(
                host: host,
                previousRule: previousRule,
                rule: SiteRuleRecord(host: host),
                profileID: nil,
                isPrivate: true
            )
            return
        }
        let targetPID = profileID ?? activeProfileID
        let previousRule = siteRule(forHost: host, profileID: targetPID)
        var profileMap = siteRulesByProfileID[targetPID] ?? (targetPID == activeProfileID ? siteRulesByHost : [:])
        profileMap.removeValue(forKey: host)
        siteRulesByProfileID[targetPID] = profileMap
        if targetPID == activeProfileID {
            siteRulesByHost = profileMap
        }
        let db = sqliteStore
        Task.detached(priority: .utility) {
            db.deleteSiteRule(forHost: host, profileID: targetPID)
        }
        applySiteRuleToMatchingTabs(
            host: host,
            previousRule: previousRule,
            rule: SiteRuleRecord(host: host),
            profileID: targetPID,
            isPrivate: false
        )
    }

    public func effectiveShieldEnabled(forHost rawHost: String?, profileID: String? = nil, isPrivate: Bool = false) -> Bool {
        let targetPID = profileID ?? activeProfileID
        if let rawHost, let rule = siteRule(forHost: rawHost, profileID: targetPID, isPrivate: isPrivate) {
            if rule.shieldMode == 1 { return true }
            if rule.shieldMode == -1 { return false }
        }
        if !isPrivate && targetPID == BrowserProfile.defaultID {
            return CleanroomContentBlocker.shared.effectiveShieldEnabled(
                globalEnabled: isShieldEnabled,
                forHost: rawHost
            )
        }
        return isShieldEnabled
    }

    public func effectiveAutoDark(forHost rawHost: String?, profileID: String? = nil, isPrivate: Bool = false) -> Bool {
        let targetPID = profileID ?? activeProfileID
        if let rawHost, let rule = siteRule(forHost: rawHost, profileID: targetPID, isPrivate: isPrivate) {
            if rule.darkMode == 1 { return true }
            if rule.darkMode == -1 { return false }
        }
        if !isPrivate && targetPID == BrowserProfile.defaultID,
           let rawHost,
           DarkReaderEngine.shared.isHostBypassed(rawHost) {
            return false
        }
        return autoWebPageDarkMode
    }

    public func effectiveUserAgent(forHost rawHost: String?, profileID: String? = nil, isPrivate: Bool = false) -> BrowserUserAgentProfile {
        let targetPID = profileID ?? activeProfileID
        if let rawHost, let rule = siteRule(forHost: rawHost, profileID: targetPID, isPrivate: isPrivate) {
            if rule.uaMode == 1 { return .iosSafari }
            if rule.uaMode == 2 { return .macosSafari }
        }
        return profile(for: targetPID)?.userAgentProfile ?? userAgentProfile
    }

    public func effectivePageZoom(forHost rawHost: String?, profileID: String? = nil, isPrivate: Bool = false) -> Double {
        let targetPID = profileID ?? activeProfileID
        if let rawHost, let zoom = siteRule(forHost: rawHost, profileID: targetPID, isPrivate: isPrivate)?.pageZoom {
            return SiteRuleRecord.clampedZoom(zoom)
        }
        return 1.0
    }

    private func applySiteRuleToMatchingTabs(
        host: String,
        previousRule: SiteRuleRecord?,
        rule: SiteRuleRecord,
        profileID: String?,
        isPrivate: Bool
    ) {
        let prev = previousRule ?? SiteRuleRecord(host: host)
        let shieldChanged = prev.shieldMode != rule.shieldMode
        let darkChanged = prev.darkMode != rule.darkMode
        let uaChanged = prev.uaMode != rule.uaMode
        let zoomChanged = prev.pageZoom != rule.pageZoom

        let targetUA = effectiveUserAgent(forHost: host, profileID: profileID, isPrivate: isPrivate)
        let targetDark = effectiveAutoDark(forHost: host, profileID: profileID, isPrivate: isPrivate)
        let targetZoom = effectivePageZoom(forHost: host, profileID: profileID, isPrivate: isPrivate)
        let activeID = activeTabID
        for tab in tabs where tab.isPrivate == isPrivate && (isPrivate || tab.profileID == profileID) {
            guard let tabHost = tab.currentBypassableHost,
                  LiveContainerEnvironment.HostNormalizer.normalize(tabHost) == host else {
                continue
            }
            if zoomChanged {
                tab.applyPageZoom(targetZoom)
            }
            if tab.id == activeID {
                if darkChanged {
                    tab.applyAutoWebPageDarkMode(targetDark)
                }
                if uaChanged {
                    tab.applyUserAgentProfile(targetUA, reloadIfLoaded: !shieldChanged)
                }
                if shieldChanged {
                    tab.syncShieldRulesForCurrentHost(reloadIfChanged: true)
                }
            } else if shieldChanged || darkChanged || uaChanged {
                tab.markNeedsSettingsSyncOnActivate()
            }
        }
    }

    // MARK: - Favorites & Hierarchical Folder Organization (`browser.sqlite3`)

    private func rebuildBookmarksFolderIndex() {
        let validFolderIDs = Set(favoriteFolders.map(\.id))
        var grouped: [String?: [BrowserBookmark]] = [:]
        for bm in bookmarks {
            let effectiveFolder = bm.folderID.flatMap { validFolderIDs.contains($0) ? $0 : nil }
            grouped[effectiveFolder, default: []].append(bm)
        }
        bookmarksByFolderIndex = grouped
    }

    public func bookmarks(inFolder folderID: String?) -> [BrowserBookmark] {
        bookmarksByFolderIndex[folderID] ?? []
    }

    public func folder(for id: String?) -> BrowserFavoriteFolder? {
        guard let id else { return nil }
        return favoriteFolders.first { $0.id == id }
    }

    @discardableResult
    public func createFolder(title: String, parentID: String? = nil) -> BrowserFavoriteFolder? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pid = activeProfileID
        let nextOrder = (favoriteFolders.map(\.sortOrder).max() ?? 0) + 100.0
        let created = BrowserFavoriteFolder(parentID: parentID, title: trimmed, sortOrder: nextOrder)
        sqliteStore.upsertFolder(created, profileID: pid)
        favoriteFolders = sqliteStore.loadFolders(profileID: pid)
        rebuildBookmarksFolderIndex()
        return created
    }

    public func renameFolder(id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var target = favoriteFolders.first(where: { $0.id == id }) else { return }
        let pid = activeProfileID
        target.title = trimmed
        sqliteStore.upsertFolder(target, profileID: pid)
        favoriteFolders = sqliteStore.loadFolders(profileID: pid)
        rebuildBookmarksFolderIndex()
    }

    public func deleteFolder(id: String, keepBookmarks: Bool) {
        let pid = activeProfileID
        sqliteStore.deleteFolder(id: id, keepBookmarks: keepBookmarks, profileID: pid)
        favoriteFolders = sqliteStore.loadFolders(profileID: pid)
        bookmarks = sqliteStore.loadBookmarks(profileID: pid)
        bookmarkCountsByProfileID[pid] = bookmarks.count
        rebuildBookmarksFolderIndex()
    }

    public func existingBookmark(for urlString: String) -> BrowserBookmark? {
        guard !urlString.isEmpty else { return nil }
        let normalized = Self.normalizeURLKey(urlString)
        return bookmarks.first { Self.normalizeURLKey($0.urlString) == normalized }
    }

    public func isBookmarked(urlString: String) -> Bool {
        existingBookmark(for: urlString) != nil
    }

    public func toggleBookmarkForCurrentPage(folderID: String? = nil) {
        let session = activeSession
        let urlStr = session.currentURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlStr.isEmpty else { return }

        if let existing = existingBookmark(for: urlStr) {
            removeBookmark(id: existing.id)
        } else {
            let title = session.pageTitle.isEmpty ? session.displayHost : session.pageTitle
            addBookmark(title: title, urlString: urlStr, folderID: folderID)
        }
    }

    public func addBookmark(title: String, urlString: String, folderID: String? = nil) {
        var cleanURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        if !cleanURL.contains("://") {
            cleanURL = "https://\(cleanURL)"
        }
        guard URL(string: cleanURL) != nil else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle: String
        if cleanTitle.isEmpty {
            let host = URL(string: cleanURL)?.host() ?? ""
            let normalized = LiveContainerEnvironment.HostNormalizer.normalize(host)
            effectiveTitle = normalized.isEmpty ? cleanURL : normalized
        } else {
            effectiveTitle = cleanTitle
        }

        let pid = activeProfileID
        if var existing = existingBookmark(for: cleanURL) {
            existing.title = effectiveTitle
            existing.folderID = folderID
            sqliteStore.upsertBookmark(existing, profileID: pid)
        } else {
            let nextOrder = (bookmarks.map(\.sortOrder).max() ?? 0) + 100.0
            let created = BrowserBookmark(
                title: effectiveTitle,
                urlString: cleanURL,
                symbolName: "globe",
                folderID: folderID,
                sortOrder: nextOrder
            )
            sqliteStore.upsertBookmark(created, profileID: pid)
        }
        bookmarks = sqliteStore.loadBookmarks(profileID: pid)
        bookmarkCountsByProfileID[pid] = bookmarks.count
        rebuildBookmarksFolderIndex()
    }

    public func updateBookmark(id: String, title: String, urlString: String, folderID: String?) {
        guard var target = bookmarks.first(where: { $0.id == id }) else { return }
        var cleanURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        if !cleanURL.contains("://") {
            cleanURL = "https://\(cleanURL)"
        }
        guard URL(string: cleanURL) != nil else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle: String
        if cleanTitle.isEmpty {
            let host = URL(string: cleanURL)?.host() ?? ""
            let normalized = LiveContainerEnvironment.HostNormalizer.normalize(host)
            effectiveTitle = normalized.isEmpty ? cleanURL : normalized
        } else {
            effectiveTitle = cleanTitle
        }
        let pid = activeProfileID
        if Self.normalizeURLKey(target.urlString) != Self.normalizeURLKey(cleanURL) {
            sqliteStore.deleteBookmark(id: id, profileID: pid)
        }
        target.title = effectiveTitle
        target.urlString = cleanURL
        target.folderID = folderID
        sqliteStore.upsertBookmark(target, profileID: pid)
        bookmarks = sqliteStore.loadBookmarks(profileID: pid)
        bookmarkCountsByProfileID[pid] = bookmarks.count
        rebuildBookmarksFolderIndex()
    }

    public func moveBookmark(id: String, toFolderID folderID: String?) {
        guard var target = bookmarks.first(where: { $0.id == id }) else { return }
        let pid = activeProfileID
        target.folderID = folderID
        sqliteStore.upsertBookmark(target, profileID: pid)
        bookmarks = sqliteStore.loadBookmarks(profileID: pid)
        bookmarkCountsByProfileID[pid] = bookmarks.count
        rebuildBookmarksFolderIndex()
    }

    public func removeBookmark(id: String) {
        let pid = activeProfileID
        sqliteStore.deleteBookmark(id: id, profileID: pid)
        bookmarks = sqliteStore.loadBookmarks(profileID: pid)
        bookmarkCountsByProfileID[pid] = bookmarks.count
        rebuildBookmarksFolderIndex()
    }

    // MARK: - Local FTS5 Omnibox Autocomplete

    /// Returns deduplicated local suggestions combining matching Favorites (prioritized) and
    /// frecency-ranked SQLite FTS5 `places` off `@MainActor`, strictly scoped to `activeProfileID`.
    public func omniboxSuggestions(for query: String, limit: Int = 6) async -> [OmniboxSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        let bookmarksSnapshot = bookmarks
        let db = historyStore
        let pid = activeProfileID
        return await Task.detached(priority: .userInitiated) {
            let lowerQuery = trimmed.lowercased()
            var results: [OmniboxSuggestion] = []
            results.reserveCapacity(limit)
            var seenKeys: Set<String> = []

            // 1. Prioritize matching bookmarks (prefix matches first, then substring matches, stable by sortOrder).
            let matchedBookmarks: [(bookmark: BrowserBookmark, rank: Int)] = bookmarksSnapshot.compactMap { bm in
                let lowerTitle = bm.title.lowercased()
                let lowerURL = bm.urlString.lowercased()
                let lowerHost = bm.displayHost.lowercased()
                if lowerHost.hasPrefix(lowerQuery) || lowerTitle.hasPrefix(lowerQuery) {
                    return (bm, 0)
                }
                if lowerTitle.contains(lowerQuery) || lowerURL.contains(lowerQuery) {
                    return (bm, 1)
                }
                return nil
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.bookmark.sortOrder < rhs.bookmark.sortOrder
            }

            for entry in matchedBookmarks {
                guard results.count < limit else { break }
                let key = Self.normalizeURLKey(entry.bookmark.urlString)
                guard !key.isEmpty, !seenKeys.contains(key) else { continue }
                seenKeys.insert(key)
                let title = entry.bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(
                    OmniboxSuggestion(
                        id: key,
                        title: title.isEmpty ? entry.bookmark.displayHost : title,
                        urlString: entry.bookmark.urlString,
                        isFavorite: true
                    )
                )
            }

            // 2. Append frecency-ranked FTS5 history places deduplicated by canonical URL.
            if results.count < limit {
                let places = db.queryTopPlaces(matching: trimmed, limit: max(limit * 2, 12), profileID: pid)
                for place in places {
                    guard results.count < limit else { break }
                    let key = Self.normalizeURLKey(place.url)
                    guard !key.isEmpty, !seenKeys.contains(key) else { continue }
                    seenKeys.insert(key)
                    let trimmedTitle = place.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fallbackHost = URL(string: place.url)?.host().map {
                        LiveContainerEnvironment.HostNormalizer.normalize($0)
                    } ?? place.url
                    results.append(
                        OmniboxSuggestion(
                            id: key,
                            title: trimmedTitle.isEmpty ? fallbackHost : trimmedTitle,
                            urlString: place.url,
                            isFavorite: false
                        )
                    )
                }
            }

            return results
        }.value
    }

    // MARK: - Bookmarks Portability (Netscape HTML & Dysprosium JSON)

    private struct BookmarksExportArchive: Codable {
        let format: String
        let version: Int
        let exportedAt: Date
        let folders: [BrowserFavoriteFolder]
        let bookmarks: [BrowserBookmark]
    }

    private struct BookmarksBackupEnvelope: Codable {
        let folders: [BrowserFavoriteFolder]
        let bookmarks: [BrowserBookmark]
    }

    public func exportBookmarksNetscapeHTML() -> Data {
        var lines: [String] = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file. -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>"
        ]

        let validFolderIDs = Set(favoriteFolders.map(\.id))
        let foldersByParent: [String?: [BrowserFavoriteFolder]] = Dictionary(grouping: favoriteFolders) { folder in
            if let parentID = folder.parentID, validFolderIDs.contains(parentID) {
                return parentID
            }
            return nil
        }.mapValues { $0.sorted { $0.sortOrder < $1.sortOrder } }

        let bookmarksByFolder: [String?: [BrowserBookmark]] = Dictionary(grouping: bookmarks) { bm in
            if let folderID = bm.folderID, validFolderIDs.contains(folderID) {
                return folderID
            }
            return nil
        }.mapValues { $0.sorted { $0.sortOrder < $1.sortOrder } }

        var visitedFolders: Set<String> = []

        func appendSection(parentID: String?, indentLevel: Int) {
            let indent = String(repeating: "    ", count: indentLevel)
            for bm in bookmarksByFolder[parentID] ?? [] {
                let href = Self.escapeHTMLAttribute(bm.urlString)
                let title = Self.escapeHTMLText(bm.title.isEmpty ? bm.displayHost : bm.title)
                lines.append("\(indent)<DT><A HREF=\"\(href)\">\(title)</A>")
            }
            for folder in foldersByParent[parentID] ?? [] {
                guard !visitedFolders.contains(folder.id) else { continue }
                visitedFolders.insert(folder.id)
                let addDate = Int64(folder.createdAt.timeIntervalSince1970)
                let title = Self.escapeHTMLText(folder.title)
                lines.append("\(indent)<DT><H3 ADD_DATE=\"\(addDate)\">\(title)</H3>")
                lines.append("\(indent)<DL><p>")
                appendSection(parentID: folder.id, indentLevel: indentLevel + 1)
                lines.append("\(indent)</DL><p>")
            }
        }

        appendSection(parentID: nil, indentLevel: 1)
        lines.append("</DL><p>")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public func exportBookmarksJSON() -> Data {
        let archive = BookmarksExportArchive(
            format: "dysprosium.bookmarks",
            version: 1,
            exportedAt: Date(),
            folders: favoriteFolders,
            bookmarks: bookmarks
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(archive)) ?? Data("{}".utf8)
    }

    /// Imports bookmarks (and folders) from either Netscape Bookmark HTML (`<DT><A HREF=...>`, `<H3>`)
    /// or Dysprosium JSON, deduplicating strictly against existing bookmarks by normalized URL.
    /// Returns the number of newly imported bookmarks.
    @discardableResult
    public func importBookmarks(from data: Data) -> Int {
        guard !data.isEmpty else { return 0 }

        // 1. Try Dysprosium JSON formats first (versioned archive, backup envelope, or flat bookmark array).
        if let decoded = Self.decodeJSONBookmarksPayload(from: data) {
            return applyImportedFoldersAndBookmarks(
                importedFolders: decoded.folders,
                importedBookmarks: decoded.bookmarks
            )
        }

        // 2. Fallback to Netscape Bookmark HTML (`<!DOCTYPE NETSCAPE-Bookmark-file-1>` / `<DT><A HREF=...>`).
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        guard let html, !html.isEmpty else { return 0 }
        let parsed = Self.parseNetscapeBookmarkHTML(html)
        guard !parsed.bookmarks.isEmpty else { return 0 }
        return applyImportedFoldersAndBookmarks(
            importedFolders: parsed.folders,
            importedBookmarks: parsed.bookmarks
        )
    }

    private struct ImportedFolderSpec {
        let tempID: String
        let parentTempID: String?
        let title: String
        let sortOrder: Double
        let createdAt: Date
    }

    private struct ImportedBookmarkSpec {
        let title: String
        let urlString: String
        let symbolName: String
        let folderTempID: String?
        let sortOrder: Double
    }

    private static func decodeJSONBookmarksPayload(
        from data: Data
    ) -> (folders: [ImportedFolderSpec], bookmarks: [ImportedBookmarkSpec])? {
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        let defaultDecoder = JSONDecoder()

        for decoder in [isoDecoder, defaultDecoder] {
            if let archive = try? decoder.decode(BookmarksExportArchive.self, from: data) {
                return (
                    folders: archive.folders.map {
                        ImportedFolderSpec(
                            tempID: $0.id,
                            parentTempID: $0.parentID,
                            title: $0.title,
                            sortOrder: $0.sortOrder,
                            createdAt: $0.createdAt
                        )
                    },
                    bookmarks: archive.bookmarks.map {
                        ImportedBookmarkSpec(
                            title: $0.title,
                            urlString: $0.urlString,
                            symbolName: $0.symbolName,
                            folderTempID: $0.folderID,
                            sortOrder: $0.sortOrder
                        )
                    }
                )
            }
            if let envelope = try? decoder.decode(BookmarksBackupEnvelope.self, from: data) {
                return (
                    folders: envelope.folders.map {
                        ImportedFolderSpec(
                            tempID: $0.id,
                            parentTempID: $0.parentID,
                            title: $0.title,
                            sortOrder: $0.sortOrder,
                            createdAt: $0.createdAt
                        )
                    },
                    bookmarks: envelope.bookmarks.map {
                        ImportedBookmarkSpec(
                            title: $0.title,
                            urlString: $0.urlString,
                            symbolName: $0.symbolName,
                            folderTempID: $0.folderID,
                            sortOrder: $0.sortOrder
                        )
                    }
                )
            }
            if let flatBookmarks = try? decoder.decode([BrowserBookmark].self, from: data) {
                return (
                    folders: [],
                    bookmarks: flatBookmarks.map {
                        ImportedBookmarkSpec(
                            title: $0.title,
                            urlString: $0.urlString,
                            symbolName: $0.symbolName,
                            folderTempID: $0.folderID,
                            sortOrder: $0.sortOrder
                        )
                    }
                )
            }
        }
        return nil
    }

    private func applyImportedFoldersAndBookmarks(
        importedFolders: [ImportedFolderSpec],
        importedBookmarks: [ImportedBookmarkSpec]
    ) -> Int {
        var existingFoldersByKey: [String: String] = [:]
        var existingFolderIDs: Set<String> = Set(favoriteFolders.map(\.id))
        for folder in favoriteFolders {
            let key = "\(folder.parentID ?? "")|\(folder.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            existingFoldersByKey[key] = folder.id
        }

        // First validate & deduplicate candidate bookmarks so empty/already-imported files don't create unused folders.
        var seenURLKeys = Set(bookmarks.map { Self.normalizeURLKey($0.urlString) })
        var newBookmarks: [ImportedBookmarkSpec] = []
        newBookmarks.reserveCapacity(importedBookmarks.count)

        for item in importedBookmarks {
            let trimmedURL = item.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedURL.isEmpty,
                  let parsedURL = URL(string: trimmedURL),
                  let scheme = parsedURL.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https") else {
                continue
            }
            let key = Self.normalizeURLKey(trimmedURL)
            guard !key.isEmpty, !seenURLKeys.contains(key) else { continue }
            seenURLKeys.insert(key)
            newBookmarks.append(
                ImportedBookmarkSpec(
                    title: item.title,
                    urlString: trimmedURL,
                    symbolName: item.symbolName,
                    folderTempID: item.folderTempID,
                    sortOrder: item.sortOrder
                )
            )
        }

        guard !newBookmarks.isEmpty else { return 0 }

        // Resolve only folders referenced (directly or as ancestors) by newly imported bookmarks, parents-first.
        let importedFolderByTempID = Dictionary(uniqueKeysWithValues: importedFolders.map { ($0.tempID, $0) })
        var neededFolderTempIDs: Set<String> = []
        for bm in newBookmarks {
            var cursor = bm.folderTempID
            var depth = 0
            while let fID = cursor, depth < 32, !neededFolderTempIDs.contains(fID) {
                guard let spec = importedFolderByTempID[fID] else { break }
                neededFolderTempIDs.insert(fID)
                cursor = spec.parentTempID
                depth += 1
            }
        }

        var resolvedFolderIDByTempID: [String: String] = [:]
        var foldersToInsert: [BrowserFavoriteFolder] = []
        var nextFolderOrder = (favoriteFolders.map(\.sortOrder).max() ?? 0) + 100.0
        var remaining = importedFolders.filter { neededFolderTempIDs.contains($0.tempID) }
        var progress = true

        while !remaining.isEmpty && progress {
            progress = false
            var deferred: [ImportedFolderSpec] = []
            for spec in remaining {
                let resolvedParentID: String?
                if let parentTemp = spec.parentTempID, importedFolderByTempID[parentTemp] != nil {
                    if let mapped = resolvedFolderIDByTempID[parentTemp] {
                        resolvedParentID = mapped
                    } else {
                        deferred.append(spec)
                        continue
                    }
                } else if let parentTemp = spec.parentTempID, existingFolderIDs.contains(parentTemp) {
                    resolvedParentID = parentTemp
                } else {
                    resolvedParentID = nil
                }

                let cleanTitle = spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveTitle = cleanTitle.isEmpty ? "Imported" : cleanTitle
                let lookupKey = "\(resolvedParentID ?? "")|\(effectiveTitle.lowercased())"
                if let existingID = existingFoldersByKey[lookupKey] {
                    resolvedFolderIDByTempID[spec.tempID] = existingID
                } else {
                    // Always mint a fresh UUID so importing a Dysprosium JSON backup exported from
                    // another profile never collides on `favorite_folders.id` primary key.
                    let created = BrowserFavoriteFolder(
                        id: UUID().uuidString,
                        parentID: resolvedParentID,
                        title: effectiveTitle,
                        sortOrder: nextFolderOrder,
                        createdAt: spec.createdAt
                    )
                    nextFolderOrder += 100.0
                    foldersToInsert.append(created)
                    existingFolderIDs.insert(created.id)
                    existingFoldersByKey[lookupKey] = created.id
                    resolvedFolderIDByTempID[spec.tempID] = created.id
                }
                progress = true
            }
            remaining = deferred
        }

        var nextBookmarkOrder = (bookmarks.map(\.sortOrder).max() ?? 0) + 100.0
        var bookmarksToInsert: [BrowserBookmark] = []
        bookmarksToInsert.reserveCapacity(newBookmarks.count)
        for item in newBookmarks {
            let cleanTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveTitle: String
            if cleanTitle.isEmpty {
                let host = URL(string: item.urlString)?.host() ?? ""
                let normalized = LiveContainerEnvironment.HostNormalizer.normalize(host)
                effectiveTitle = normalized.isEmpty ? item.urlString : normalized
            } else {
                effectiveTitle = cleanTitle
            }

            let targetFolderID: String? = item.folderTempID.flatMap { tempID in
                if let mapped = resolvedFolderIDByTempID[tempID] {
                    return mapped
                }
                return existingFolderIDs.contains(tempID) ? tempID : nil
            }

            let created = BrowserBookmark(
                title: effectiveTitle,
                urlString: item.urlString,
                symbolName: item.symbolName.isEmpty ? "globe" : item.symbolName,
                folderID: targetFolderID,
                sortOrder: nextBookmarkOrder
            )
            nextBookmarkOrder += 100.0
            bookmarksToInsert.append(created)
        }

        let pid = activeProfileID
        sqliteStore.importFavoritesBatch(
            folders: foldersToInsert,
            bookmarks: bookmarksToInsert,
            profileID: pid
        )
        favoriteFolders = sqliteStore.loadFolders(profileID: pid)
        bookmarks = sqliteStore.loadBookmarks(profileID: pid)
        bookmarkCountsByProfileID[pid] = bookmarks.count
        rebuildBookmarksFolderIndex()
        return bookmarksToInsert.count
    }

    private static func parseNetscapeBookmarkHTML(
        _ html: String
    ) -> (folders: [ImportedFolderSpec], bookmarks: [ImportedBookmarkSpec]) {
        var folders: [ImportedFolderSpec] = []
        var bookmarks: [ImportedBookmarkSpec] = []
        var folderStack: [String?] = [nil]
        var pendingFolderTempID: String?

        var cursor = html.startIndex
        while cursor < html.endIndex {
            guard let ltIndex = html[cursor...].firstIndex(of: "<") else { break }

            // Skip HTML comments (`<!-- ... -->`)
            if html[ltIndex...].hasPrefix("<!--") {
                if let commentEnd = html.range(of: "-->", range: ltIndex..<html.endIndex) {
                    cursor = commentEnd.upperBound
                    continue
                }
                break
            }

            guard let gtIndex = findTagCloseIndex(in: html, from: html.index(after: ltIndex)) else {
                break
            }

            let rawTag = String(html[html.index(after: ltIndex)..<gtIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let afterTag = html.index(after: gtIndex)

            if rawTag.isEmpty || rawTag.hasPrefix("!") || rawTag.hasPrefix("?") {
                cursor = afterTag
                continue
            }

            let isClosing = rawTag.hasPrefix("/")
            let body = isClosing ? String(rawTag.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) : rawTag
            let nameEnd = body.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? body.endIndex
            let tagName = body[..<nameEnd].lowercased()

            switch (isClosing, tagName) {
            case (false, "dl"):
                if let nextFolder = pendingFolderTempID {
                    folderStack.append(nextFolder)
                    pendingFolderTempID = nil
                } else {
                    folderStack.append(folderStack.last ?? nil)
                }
                cursor = afterTag

            case (true, "dl"):
                if folderStack.count > 1 {
                    folderStack.removeLast()
                }
                pendingFolderTempID = nil
                cursor = afterTag

            case (false, "h3"):
                let (innerText, nextCursor) = extractElementInnerText(
                    in: html,
                    afterOpenTag: afterTag,
                    closingTagName: "h3"
                )
                let decodedTitle = decodeHTMLEntities(stripHTMLTags(innerText))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !decodedTitle.isEmpty {
                    let tempID = UUID().uuidString
                    let parentID = folderStack.last ?? nil
                    folders.append(
                        ImportedFolderSpec(
                            tempID: tempID,
                            parentTempID: parentID,
                            title: decodedTitle,
                            sortOrder: Double(folders.count + 1) * 100.0,
                            createdAt: Date()
                        )
                    )
                    pendingFolderTempID = tempID
                } else {
                    pendingFolderTempID = nil
                }
                cursor = nextCursor

            case (false, "a"):
                // An anchor directly after an `<H3>` without a `<DL>` means that heading had no list.
                pendingFolderTempID = nil
                let attrSlice = String(body[nameEnd...])
                let (innerText, nextCursor) = extractElementInnerText(
                    in: html,
                    afterOpenTag: afterTag,
                    closingTagName: "a"
                )
                if let rawHref = extractHTMLAttribute(named: "href", from: attrSlice) {
                    let decodedHref = decodeHTMLEntities(rawHref)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let decodedTitle = decodeHTMLEntities(stripHTMLTags(innerText))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !decodedHref.isEmpty {
                        bookmarks.append(
                            ImportedBookmarkSpec(
                                title: decodedTitle,
                                urlString: decodedHref,
                                symbolName: "globe",
                                folderTempID: folderStack.last ?? nil,
                                sortOrder: Double(bookmarks.count + 1) * 100.0
                            )
                        )
                    }
                }
                cursor = nextCursor

            default:
                cursor = afterTag
            }
        }

        return (folders, bookmarks)
    }

    private static func findTagCloseIndex(in html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var idx = start
        while idx < html.endIndex {
            let ch = html[idx]
            if let q = quote {
                if ch == q { quote = nil }
            } else {
                if ch == "\"" || ch == "'" {
                    quote = ch
                } else if ch == ">" {
                    return idx
                }
            }
            idx = html.index(after: idx)
        }
        return nil
    }

    private static func extractElementInnerText(
        in html: String,
        afterOpenTag: String.Index,
        closingTagName: String
    ) -> (text: String, nextCursor: String.Index) {
        let closeToken = "</\(closingTagName)"
        if let closeRange = html.range(
            of: closeToken,
            options: [.caseInsensitive],
            range: afterOpenTag..<html.endIndex
        ) {
            let text = String(html[afterOpenTag..<closeRange.lowerBound])
            if let closeGT = html[closeRange.upperBound...].firstIndex(of: ">") {
                return (text, html.index(after: closeGT))
            }
            return (text, closeRange.upperBound)
        }
        if let nextTag = html[afterOpenTag...].firstIndex(of: "<") {
            return (String(html[afterOpenTag..<nextTag]), nextTag)
        }
        return (String(html[afterOpenTag...]), html.endIndex)
    }

    private static func extractHTMLAttribute(named targetName: String, from attributes: String) -> String? {
        let targetLower = targetName.lowercased()
        var idx = attributes.startIndex
        while idx < attributes.endIndex {
            while idx < attributes.endIndex && (attributes[idx].isWhitespace || attributes[idx] == "/") {
                idx = attributes.index(after: idx)
            }
            guard idx < attributes.endIndex else { break }

            let nameStart = idx
            while idx < attributes.endIndex,
                  !attributes[idx].isWhitespace,
                  attributes[idx] != "=",
                  attributes[idx] != "/" {
                idx = attributes.index(after: idx)
            }
            let attrName = attributes[nameStart..<idx].lowercased()

            while idx < attributes.endIndex && attributes[idx].isWhitespace {
                idx = attributes.index(after: idx)
            }
            guard idx < attributes.endIndex, attributes[idx] == "=" else {
                continue
            }
            idx = attributes.index(after: idx)
            while idx < attributes.endIndex && attributes[idx].isWhitespace {
                idx = attributes.index(after: idx)
            }
            guard idx < attributes.endIndex else { break }

            let value: String
            let first = attributes[idx]
            if first == "\"" || first == "'" {
                let quote = first
                idx = attributes.index(after: idx)
                let valStart = idx
                while idx < attributes.endIndex && attributes[idx] != quote {
                    idx = attributes.index(after: idx)
                }
                value = String(attributes[valStart..<idx])
                if idx < attributes.endIndex {
                    idx = attributes.index(after: idx)
                }
            } else {
                let valStart = idx
                while idx < attributes.endIndex && !attributes[idx].isWhitespace {
                    idx = attributes.index(after: idx)
                }
                value = String(attributes[valStart..<idx])
            }

            if attrName == targetLower {
                return value
            }
        }
        return nil
    }

    private static func stripHTMLTags(_ input: String) -> String {
        guard input.contains("<") else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        var insideTag = false
        for ch in input {
            if ch == "<" {
                insideTag = true
            } else if ch == ">" {
                insideTag = false
            } else if !insideTag {
                out.append(ch)
            }
        }
        return out
    }

    private static func escapeHTMLText(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        for ch in input {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            default: out.append(ch)
            }
        }
        return out
    }

    private static func escapeHTMLAttribute(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        for ch in input {
            switch ch {
            case "&": out.append("&amp;")
            case "\"": out.append("&quot;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            default: out.append(ch)
            }
        }
        return out
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        var idx = input.startIndex
        while idx < input.endIndex {
            if input[idx] == "&",
               let semi = input[idx...].firstIndex(of: ";"),
               input.distance(from: idx, to: semi) <= 12 {
                let entity = String(input[input.index(after: idx)..<semi])
                if let decoded = decodeSingleHTMLEntity(entity) {
                    out.append(decoded)
                    idx = input.index(after: semi)
                    continue
                }
            }
            out.append(input[idx])
            idx = input.index(after: idx)
        }
        return out
    }

    private static func decodeSingleHTMLEntity(_ entity: String) -> String? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                if let code = UInt32(entity.dropFirst(2), radix: 16),
                   let scalar = UnicodeScalar(code) {
                    return String(scalar)
                }
            } else if entity.hasPrefix("#") {
                if let code = UInt32(entity.dropFirst(1), radix: 10),
                   let scalar = UnicodeScalar(code) {
                    return String(scalar)
                }
            }
            return nil
        }
    }

    // MARK: - SQLite3 WAL-Backed History & Zero-Ghost-Storage Clearing

    public func removeHistoryEntry(id: String) {
        sqliteStore.deleteEntry(id: id)
        totalHistoryCount = sqliteStore.totalCount(profileID: activeProfileID)
        historyRevision &+= 1
    }

    public func clearHistoryDay(dayYMD: Int64) {
        let pid = activeProfileID
        sqliteStore.clearDay(dayYMD: dayYMD, profileID: pid)
        totalHistoryCount = sqliteStore.totalCount(profileID: pid)
        historyRevision &+= 1
    }

    public func clearTodayHistory() {
        clearHistoryDay(dayYMD: BrowserSQLiteStore.calendarDayYMD(for: Date()))
    }

    public func clearHistory(profileID: String? = nil) {
        let pid = profileID ?? activeProfileID
        sqliteStore.clearAll(profileID: pid)
        sqliteStore.reclaimStorage(fullVacuum: true)
        if pid == activeProfileID {
            totalHistoryCount = 0
        }
        historyRevision &+= 1
    }

    public struct BrowsingClearOptions: Sendable {
        public var includeHistory: Bool
        public var includeCache: Bool
        public var includeCookiesAndSessions: Bool
        public var closeStandardTabs: Bool

        public init(
            includeHistory: Bool = true,
            includeCache: Bool = true,
            includeCookiesAndSessions: Bool = false,
            closeStandardTabs: Bool = false
        ) {
            self.includeHistory = includeHistory
            self.includeCache = includeCache
            self.includeCookiesAndSessions = includeCookiesAndSessions
            self.closeStandardTabs = closeStandardTabs
        }

        public var hasAnySelection: Bool {
            includeHistory || includeCache || includeCookiesAndSessions || closeStandardTabs
        }
    }

    private static let cacheWebsiteDataTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeFetchCache
    ]

    private static let cookieAndSessionWebsiteDataTypes: Set<String> = [
        WKWebsiteDataTypeCookies,
        WKWebsiteDataTypeSessionStorage,
        WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeIndexedDBDatabases,
        WKWebsiteDataTypeWebSQLDatabases,
        WKWebsiteDataTypeServiceWorkerRegistrations,
        WKWebsiteDataTypeFileSystem,
        WKWebsiteDataTypeMediaKeys,
        WKWebsiteDataTypeHashSalt,
        WKWebsiteDataTypeSearchFieldRecentSearches
    ]

    /// Performs thorough, zero-ghost-storage clearing scoped to `profileID` (defaulting to `activeProfileID`)
    /// across SQLite (`VACUUM` + WAL truncation), that profile's WebKit store, stubborn `HttpOnly` cookies,
    /// `DarkReaderEngine`, `SiteIconStore`, orphaned staging/temp files, live tab Web Storage, and scoped transfer auth headers.
    @discardableResult
    public func performClearBrowsingData(
        since cutoff: Date,
        until endCutoff: Date? = nil,
        options: BrowsingClearOptions,
        profileID: String? = nil,
        activeTransferIDs: Set<UUID>? = nil,
        onScrubTransferAuthData: (@MainActor () async -> Void)? = nil
    ) async -> BrowsingClearReport {
        let targetProfileID = profileID ?? activeProfileID
        guard let targetProfile = profile(for: targetProfileID) else {
            return BrowsingClearReport(
                bytesReclaimed: 0,
                historyEntriesRemoved: 0,
                websiteRecordsRemoved: 0,
                cookiesRemoved: 0,
                temporaryBytesReclaimed: 0,
                closedTabCount: 0
            )
        }
        let beforeFootprint = await computeStorageFootprint(profileID: targetProfileID)

        var historyEntriesRemoved = 0
        var websiteRecordsRemoved = 0
        var cookiesRemoved = 0
        var temporaryBytesReclaimed: UInt64 = 0
        var closedTabCount = 0

        // 1. History Scope (SQLite delete + physical VACUUM + WAL truncate)
        if options.includeHistory {
            let db = sqliteStore
            let (removedCount, remainingCount, updatedVersion) = await Task.detached(priority: .userInitiated) {
                let matching = db.countEntries(since: cutoff, until: endCutoff, profileID: targetProfileID)
                db.clearEntries(since: cutoff, until: endCutoff, profileID: targetProfileID)
                db.reclaimStorage(fullVacuum: true)
                return (matching, db.totalCount(profileID: targetProfileID), db.dataVersion())
            }.value
            historyEntriesRemoved = removedCount
            if targetProfileID == activeProfileID {
                totalHistoryCount = remainingCount
            }
            lastObservedDataVersion = updatedVersion
            historyRevision &+= 1

            if cutoff <= .distantPast && endCutoff == nil {
                if profiles.count <= 1 {
                    await SiteIconStore.shared.clearDiskCache()
                }
                clearRecentlyClosedTabs(profileID: targetProfileID)
            }
        }

        // 2. Cache Scope
        var websiteTypes = Set<String>()
        if options.includeCache {
            websiteTypes.formUnion(Self.cacheWebsiteDataTypes)
            if targetProfile.isDefault {
                URLCache.shared.removeAllCachedResponses()
            }
            DarkReaderEngine.shared.purgeMemoryCache()
            if profiles.count <= 1 {
                await SiteIconStore.shared.clearDiskCache()
            }

            let protectedTransferIDs = activeTransferIDs ?? activeTransferIDsProvider?() ?? []
            temporaryBytesReclaimed = await Task.detached(priority: .utility) {
                LiveContainerEnvironment.reclaimOrphanedTemporaryFiles(activeTransferIDs: protectedTransferIDs)
            }.value
        }

        // 3. Cookies & Sessions Scope
        if options.includeCookiesAndSessions {
            if options.includeCache {
                websiteTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            } else {
                websiteTypes.formUnion(Self.cookieAndSessionWebsiteDataTypes)
            }
        }

        if !websiteTypes.isEmpty {
            if let dataStore = await dataStoreRegistry.liveStoreIfAllocated(for: targetProfile) {
                let existingRecords = await dataStore.dataRecords(ofTypes: websiteTypes)
                websiteRecordsRemoved = existingRecords.count

                await dataStore.removeData(ofTypes: websiteTypes, modifiedSince: cutoff)

                if options.includeCookiesAndSessions {
                    // Explicitly enumerate & delete stubborn `HttpOnly` cookies in `WKHTTPCookieStore`.
                    let cookieStore = dataStore.httpCookieStore
                    let remainingCookies = await cookieStore.allCookies()
                    let clearAllCookies = (cutoff <= .distantPast)
                    for cookie in remainingCookies {
                        if clearAllCookies || cookie.isSessionOnly {
                            await cookieStore.deleteCookie(cookie)
                            cookiesRemoved += 1
                        }
                    }
                }
            }

            if options.includeCookiesAndSessions {
                // Gate Foundation `HTTPCookieStorage.shared` strictly to the Default Profile.
                if targetProfile.isDefault {
                    let sharedCookiesBefore = HTTPCookieStorage.shared.cookies?.count ?? 0
                    HTTPCookieStorage.shared.removeCookies(since: cutoff)
                    let sharedCookiesAfter = HTTPCookieStorage.shared.cookies?.count ?? 0
                    if sharedCookiesBefore > sharedCookiesAfter {
                        cookiesRemoved += (sharedCookiesBefore - sharedCookiesAfter)
                    }
                }

                // Clear live in-memory Web Storage (`sessionStorage` + `localStorage`) ONLY on this profile's tabs.
                for tab in tabs where !tab.isPrivate && tab.profileID == targetProfileID {
                    await tab.clearLiveWebStorageIfLoaded()
                }

                // Scrub persisted transfer auth headers (`Cookie` / `Authorization`) ONLY for this profile.
                if let explicitScrub = onScrubTransferAuthData {
                    await explicitScrub()
                } else if let wiredScrub = self.onScrubTransferAuthData {
                    await wiredScrub(targetProfileID)
                }
            }

            for tab in tabs where !tab.isPrivate && tab.profileID == targetProfileID {
                tab.clearCandidates()
            }
        }

        // 4. Close Standard Tabs Scope (strictly for this profile)
        if options.closeStandardTabs {
            closedTabCount = tabs.filter { !$0.isPrivate && $0.profileID == targetProfileID }.count
            closeAllTabs(isPrivate: false, profileID: targetProfileID)
            clearRecentlyClosedTabs(profileID: targetProfileID)
        }

        let afterFootprint = await computeStorageFootprint(profileID: targetProfileID)
        let footprintDelta: UInt64 = beforeFootprint.totalBytes > afterFootprint.totalBytes
            ? (beforeFootprint.totalBytes - afterFootprint.totalBytes)
            : 0
        let totalReclaimed = max(footprintDelta, temporaryBytesReclaimed)

        return BrowsingClearReport(
            bytesReclaimed: totalReclaimed,
            historyEntriesRemoved: historyEntriesRemoved,
            websiteRecordsRemoved: websiteRecordsRemoved,
            cookiesRemoved: cookiesRemoved,
            temporaryBytesReclaimed: temporaryBytesReclaimed,
            closedTabCount: closedTabCount
        )
    }

    @discardableResult
    public func clearAllBrowsingData(profileID: String? = nil) async -> BrowsingClearReport {
        await performClearBrowsingData(
            since: .distantPast,
            options: BrowsingClearOptions(
                includeHistory: true,
                includeCache: true,
                includeCookiesAndSessions: true,
                closeStandardTabs: false
            ),
            profileID: profileID
        )
    }

    // MARK: - Per-Site Website Data & Storage Footprint Inspection

    /// Measures real disk bytes across SQLite (+ WAL/SHM), `SiteIcons`, WebKit cache/data directories
    /// scoped to `profileID` (excluding compiled adblock `ContentRuleLists/`), and `Staging`/temp directories.
    public func computeStorageFootprint(profileID: String? = nil) async -> BrowserStorageFootprint {
        let targetProfileID = profileID ?? activeProfileID
        guard let targetProfile = profile(for: targetProfileID) else {
            return BrowserStorageFootprint(
                historySQLiteBytes: 0,
                faviconCacheBytes: 0,
                webKitCacheBytes: 0,
                stagingTempBytes: 0,
                websiteDomainCount: 0
            )
        }
        let db = sqliteStore
        let stagingDir = LiveContainerEnvironment.stagingDirectory
        let tempDir = FileManager.default.temporaryDirectory
        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let libraryWebKitDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WebKit", isDirectory: true)
        let libraryCookiesDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Cookies", isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier
        let secondaryStoreDirs = targetProfile.webkitStoreID.map {
            ProfileWebsiteDataStoreRegistry.existingDiskDirectories(forStoreIdentifier: $0)
        } ?? []
        let isDefaultTarget = targetProfile.isDefault

        async let diskMetrics: (sqlite: UInt64, webKit: UInt64, staging: UInt64) = Task.detached(priority: .utility) {
            let sqliteBytes = db.databaseDiskUsageBytes()
            var wkBytes: UInt64 = 0
            let fm = FileManager.default
            if isDefaultTarget {
                // Default WebKit caches (`Library/Caches/WebKit` and iOS 27.2 `Library/Caches/<BundleID>/WebKit`).
                if let cachesRoot {
                    let legacyCache = cachesRoot.appendingPathComponent("WebKit", isDirectory: true)
                    wkBytes &+= LiveContainerEnvironment.directorySizeBytes(at: legacyCache)
                    if let bundleID, !bundleID.isEmpty {
                        let bundleCache = cachesRoot
                            .appendingPathComponent(bundleID, isDirectory: true)
                            .appendingPathComponent("WebKit", isDirectory: true)
                        wkBytes &+= LiveContainerEnvironment.directorySizeBytes(at: bundleCache)
                    }
                }
                // Enumerate `Library/WebKit` excluding shared `ContentRuleLists` and secondary `WebsiteDataStore`
                // both at top-level and inside `<BundleID>/` subdirectories.
                if let libraryWebKitDir,
                   let topEntries = try? fm.contentsOfDirectory(at: libraryWebKitDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                    for entry in topEntries {
                        let name = entry.lastPathComponent
                        if name == "ContentRuleLists" || name == "WebsiteDataStore" { continue }
                        let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        if isDir,
                           let nested = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil),
                           nested.contains(where: { $0.lastPathComponent == "ContentRuleLists" || $0.lastPathComponent == "WebsiteDataStore" }) {
                            for child in nested {
                                let childName = child.lastPathComponent
                                if childName == "ContentRuleLists" || childName == "WebsiteDataStore" { continue }
                                wkBytes &+= LiveContainerEnvironment.directorySizeBytes(at: child)
                            }
                        } else {
                            wkBytes &+= LiveContainerEnvironment.directorySizeBytes(at: entry)
                        }
                    }
                }
                if let libraryCookiesDir {
                    wkBytes &+= LiveContainerEnvironment.directorySizeBytes(at: libraryCookiesDir)
                }
            } else {
                for dir in secondaryStoreDirs {
                    wkBytes &+= LiveContainerEnvironment.directorySizeBytes(at: dir)
                }
            }
            let stagingBytes = LiveContainerEnvironment.directorySizeBytes(at: stagingDir)
                &+ LiveContainerEnvironment.directorySizeBytes(at: tempDir)
            return (sqliteBytes, wkBytes, stagingBytes)
        }.value

        async let iconBytes = SiteIconStore.shared.diskUsageBytes()
        async let domains = fetchWebsiteDataDomains(profileID: targetProfileID)

        let (metrics, favBytes, domainList) = await (diskMetrics, iconBytes, domains)
        return BrowserStorageFootprint(
            historySQLiteBytes: metrics.sqlite,
            faviconCacheBytes: favBytes,
            webKitCacheBytes: metrics.webKit,
            stagingTempBytes: metrics.staging,
            websiteDomainCount: domainList.count
        )
    }

    /// Enumerates every website domain currently holding cookies, storage, or caches in `profileID`'s
    /// `WKWebsiteDataStore`, merged with stubborn cookie-only domains from `WKHTTPCookieStore`.
    public func fetchWebsiteDataDomains(profileID: String? = nil) async -> [WebsiteDataDomainSummary] {
        let targetProfileID = profileID ?? activeProfileID
        guard let targetProfile = profile(for: targetProfileID),
              let dataStore = await dataStoreRegistry.liveStoreIfAllocated(for: targetProfile) else {
            return []
        }
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: allTypes)
        let liveCookies = await dataStore.httpCookieStore.allCookies()

        var typesByDisplayName: [String: Set<String>] = [:]
        for record in records {
            let name = record.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            typesByDisplayName[name, default: []].formUnion(record.dataTypes)
        }

        // Merge cookie-only domains so HttpOnly cookies without a WKWebsiteDataRecord are never hidden.
        for cookie in liveCookies {
            let cleanDomain = cookie.domain
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                .lowercased()
            guard !cleanDomain.isEmpty else { continue }
            let alreadyCovered = typesByDisplayName.keys.contains { existing in
                let lower = existing.lowercased()
                return lower == cleanDomain || cleanDomain.hasSuffix(".\(lower)") || lower.hasSuffix(".\(cleanDomain)")
            }
            if alreadyCovered {
                if let matchedKey = typesByDisplayName.keys.first(where: {
                    let lower = $0.lowercased()
                    return lower == cleanDomain || cleanDomain.hasSuffix(".\(lower)") || lower.hasSuffix(".\(cleanDomain)")
                }) {
                    typesByDisplayName[matchedKey, default: []].insert(WKWebsiteDataTypeCookies)
                }
            } else {
                typesByDisplayName[cleanDomain, default: []].insert(WKWebsiteDataTypeCookies)
            }
        }

        let storageTypes: Set<String> = [
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeWebSQLDatabases,
            WKWebsiteDataTypeServiceWorkerRegistrations,
            WKWebsiteDataTypeFileSystem,
            WKWebsiteDataTypeMediaKeys,
            WKWebsiteDataTypeHashSalt
        ]

        return typesByDisplayName.map { displayName, dataTypes in
            WebsiteDataDomainSummary(
                displayName: displayName,
                dataTypes: dataTypes,
                hasCookies: dataTypes.contains(WKWebsiteDataTypeCookies),
                hasStorage: !dataTypes.isDisjoint(with: storageTypes),
                hasCache: !dataTypes.isDisjoint(with: Self.cacheWebsiteDataTypes)
            )
        }
        .sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Completely removes all website data for the specified domains strictly inside `profileID`'s store.
    public func removeWebsiteData(forDisplayNames names: Set<String>, profileID: String? = nil) async {
        let targetProfileID = profileID ?? activeProfileID
        guard let targetProfile = profile(for: targetProfileID) else { return }
        let normalizedTargets: Set<String> = Set(
            names.compactMap { raw -> String? in
                let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
                let norm = LiveContainerEnvironment.HostNormalizer.normalize(trimmed)
                return norm.isEmpty ? nil : norm
            }
        )
        guard !normalizedTargets.isEmpty else { return }

        if let dataStore = await dataStoreRegistry.liveStoreIfAllocated(for: targetProfile) {
            let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()

            // 1. Remove matching WKWebsiteDataRecords
            let records = await dataStore.dataRecords(ofTypes: allTypes)
            let matchingRecords = records.filter { record in
                let recName = LiveContainerEnvironment.HostNormalizer.normalize(record.displayName)
                return normalizedTargets.contains { target in
                    recName == target || recName.hasSuffix(".\(target)") || target.hasSuffix(".\(recName)")
                }
            }
            if !matchingRecords.isEmpty {
                await dataStore.removeData(ofTypes: allTypes, for: matchingRecords)
            }

            // 2. Remove matching HttpOnly / persistent cookies from WKHTTPCookieStore
            let cookieStore = dataStore.httpCookieStore
            let liveCookies = await cookieStore.allCookies()
            for cookie in liveCookies {
                let dom = LiveContainerEnvironment.HostNormalizer.normalize(
                    cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                )
                let matches = normalizedTargets.contains { target in
                    dom == target || dom.hasSuffix(".\(target)") || target.hasSuffix(".\(dom)")
                }
                if matches {
                    await cookieStore.deleteCookie(cookie)
                }
            }
        }

        // 3. Remove matching cookies from Foundation HTTPCookieStorage.shared (Default Profile only)
        if targetProfile.isDefault, let sharedCookies = HTTPCookieStorage.shared.cookies {
            for cookie in sharedCookies {
                let dom = LiveContainerEnvironment.HostNormalizer.normalize(
                    cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                )
                let matches = normalizedTargets.contains { target in
                    dom == target || dom.hasSuffix(".\(target)") || target.hasSuffix(".\(dom)")
                }
                if matches {
                    HTTPCookieStorage.shared.deleteCookie(cookie)
                }
            }
        }

        // 4. Remove cached favicons only if not referenced by any remaining profile
        let otherProfileHosts: Set<String> = profiles.count > 1
            ? sqliteStore.allReferencedHosts(excludingProfileID: targetProfileID)
            : []
        for host in normalizedTargets where !otherProfileHosts.contains(host) {
            await SiteIconStore.shared.removeIcon(forHost: host)
        }

        // 5. Clear live sessionStorage/localStorage & candidates ONLY on matching tabs of this profile
        for tab in tabs where !tab.isPrivate && tab.profileID == targetProfileID && tab.matchesDomainSet(normalizedTargets) {
            await tab.clearLiveWebStorageIfLoaded()
            tab.clearCandidates()
        }
    }

    // MARK: - Zero-Permission Clipboard Link Perception

    public func checkClipboardForNewURL() {
        let pb = UIPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastHandledPasteboardChangeCount else { return }
        guard pb.hasURLs || pb.hasStrings else {
            hasClipboardWebURL = false
            return
        }

        Task { @MainActor [weak self] in
            let detected = await Self.probeClipboardHasWebURL()
            guard let self else { return }
            if detected {
                self.hasClipboardWebURL = true
            } else {
                self.lastHandledPasteboardChangeCount = currentCount
                self.hasClipboardWebURL = false
            }
        }
    }

    nonisolated private static func probeClipboardHasWebURL() async -> Bool {
        guard let patterns = try? await UIPasteboard.general.detectedPatterns(for: [\.probableWebURL]) else {
            return false
        }
        return patterns.contains(\.probableWebURL)
    }

    public func consumeOrDismissClipboardURL() {
        lastHandledPasteboardChangeCount = UIPasteboard.general.changeCount
        hasClipboardWebURL = false
    }

    // MARK: - Internal Wiring

    private func makeSession(
        id: UUID,
        isPrivate: Bool,
        profileID: String? = nil
    ) -> CleanroomWebKitSession {
        let resolvedProfileID: String? = isPrivate ? nil : (profileID ?? activeProfileID)
        let storeProvider: @MainActor () -> WKWebsiteDataStore
        if isPrivate {
            storeProvider = { [weak self] in
                self?.acquireSharedPrivateWebsiteDataStore() ?? .nonPersistent()
            }
        } else {
            let pid = resolvedProfileID ?? BrowserProfile.defaultID
            storeProvider = { [weak self] in
                guard let self else {
                    return pid == BrowserProfile.defaultID ? .default() : .nonPersistent()
                }
                if let targetProfile = self.profile(for: pid) {
                    return self.dataStoreRegistry.websiteDataStore(for: targetProfile)
                }
                // Fail closed: NEVER fall back to `.default()` for a secondary profile before
                // hydration finishes or after deletion, preventing cross-profile cookie leakage.
                if pid == BrowserProfile.defaultID {
                    let store = WKWebsiteDataStore.default()
                    SystemProxyBridge.sync(dataStore: store)
                    return store
                }
                return .nonPersistent()
            }
        }
        let siteRuleProvider: @MainActor (String) -> SiteRuleRecord? = { [weak self] host in
            guard let self else { return nil }
            if isPrivate {
                return self.siteRule(forHost: host, isPrivate: true)
            }
            let lookupPID = resolvedProfileID ?? self.activeProfileID
            return self.siteRule(forHost: host, profileID: lookupPID, isPrivate: false)
        }
        let seedProvider: (@MainActor () -> String?)?
        let uaProvider: (@MainActor () -> BrowserUserAgentProfile?)?
        let searchProvider: @MainActor () -> (BrowserSearchEngine, String)
        if let pid = resolvedProfileID {
            seedProvider = { [weak self] in
                self?.profile(for: pid)?.fingerprintSeed ?? FingerprintShieldEngine.shared.standardSeed
            }
            uaProvider = { [weak self] in
                self?.profile(for: pid)?.userAgentProfile ?? self?.userAgentProfile
            }
            searchProvider = { [weak self] in
                guard let self else {
                    return (BrowserSearchEngine.persistedCurrent, BrowserSearchEngine.persistedCustomTemplate)
                }
                if let target = self.profile(for: pid) {
                    return (target.searchEngine, target.customSearchTemplate)
                }
                return (self.searchEngine, self.customSearchTemplate)
            }
        } else {
            seedProvider = nil
            uaProvider = nil
            searchProvider = { [weak self] in
                guard let self else {
                    return (BrowserSearchEngine.persistedCurrent, BrowserSearchEngine.persistedCustomTemplate)
                }
                return (self.activeProfile.searchEngine, self.activeProfile.customSearchTemplate)
            }
        }
        let session = CleanroomWebKitSession(
            id: id,
            isPrivate: isPrivate,
            profileID: resolvedProfileID,
            websiteDataStoreProvider: storeProvider,
            siteRuleProvider: siteRuleProvider,
            profileFingerprintSeedProvider: seedProvider,
            profileUserAgentProvider: uaProvider,
            profileSearchProvider: searchProvider
        )
        wireTabCallbacks(session)
        return session
    }

    private func wireTabCallbacks(_ session: CleanroomWebKitSession) {
        let owningProfileID = session.profileID
        let sessionIsPrivate = session.isPrivate
        session.onOpenLinkInTab = { [weak self] url, isPrivate, activate in
            self?.openNewTab(
                urlString: url.absoluteString,
                isPrivate: isPrivate,
                activate: activate,
                profileID: isPrivate ? nil : owningProfileID
            )
        }
        session.onNavigationCommitted = { [weak self, weak session] url, title in
            guard let self, let session else { return }
            if !session.isPrivate, let pid = session.profileID {
                self.recordHistoryVisit(url: url, title: title, profileID: pid)
                self.persistOpenTabsSnapshot(forProfileID: pid)
            }
        }
        session.onCreateChildWebViewTab = { [weak self, weak session] configuration, initialURL in
            guard let self else { return nil }
            return self.openChildTab(
                configuration: configuration,
                initialURL: initialURL,
                isPrivate: session?.isPrivate ?? false,
                profileID: session?.profileID,
                openerTabID: session?.id
            )
        }
        session.onRequestCloseSelf = { [weak self, weak session] in
            guard let self, let id = session?.id else { return }
            self.closeTab(id: id)
        }
        if let owningProfileID {
            session.onRotateProfileFingerprintSeed = { [weak self] in
                self?.rotateFingerprintSeed(forProfileID: owningProfileID)
                    ?? FingerprintShieldEngine.generateCryptographicSeed()
            }
        }
        session.onUpdateSiteRule = { [weak self] host, shieldMode, darkMode in
            self?.updateSiteRule(
                forHost: host,
                shieldMode: shieldMode,
                darkMode: darkMode,
                profileID: owningProfileID,
                isPrivate: sessionIsPrivate
            )
        }
    }

    private func recordHistoryVisit(url: URL, title: String, profileID: String) {
        let store = sqliteStore
        Task.detached(priority: .utility) { [weak self] in
            store.recordVisit(url: url, title: title, visitedAt: Date(), profileID: profileID)
            let updatedTotal = store.totalCount(profileID: profileID)
            let updatedVersion = store.dataVersion()
            await MainActor.run {
                guard let self else { return }
                if self.activeProfileID == profileID {
                    self.totalHistoryCount = updatedTotal
                }
                self.lastObservedDataVersion = updatedVersion
                self.historyRevision &+= 1
            }
        }
    }

    nonisolated private static func normalizeURLKey(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
    }
}

@MainActor
private final class BrowserBackgroundTaskGuard {
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    func begin(name: String) {
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor [weak self] in
                self?.end()
            }
        }
    }

    func end() {
        guard taskID != .invalid else { return }
        let current = taskID
        taskID = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
}
