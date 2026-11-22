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
        case .iosSafari: return "iOS Safari (Mobile)"
        case .macosSafari: return "macOS Safari (Desktop)"
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
        case .brave: return "Brave Search"
        case .startpage: return "Startpage"
        case .custom: return "Custom"
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
    public static let maxRecentlyClosedTabs = 15

    public private(set) var tabs: [CleanroomWebKitSession] = []
    public var activeTabID: UUID
    public private(set) var bookmarks: [BrowserBookmark] = []
    public private(set) var favoriteFolders: [BrowserFavoriteFolder] = []
    public private(set) var siteRulesByHost: [String: SiteRuleRecord] = [:]
    public private(set) var recentlyClosedTabs: [RecentlyClosedTab] = []
    public private(set) var totalHistoryCount: Int = 0
    public private(set) var historyRevision: Int = 0
    public private(set) var hasClipboardWebURL: Bool = false
    public private(set) var isHydrated: Bool = false

    /// Optional callback invoked during Cookies & Sessions clear to scrub persisted transfer auth headers.
    public var onScrubTransferAuthData: (@MainActor () async -> Void)?
    /// Optional provider returning active transfer IDs so staging reclamation never deletes in-flight downloads.
    public var activeTransferIDsProvider: (@MainActor () -> Set<UUID>)?
    /// Optional predicate exempting tabs with an active download from LRU hibernation.
    public var hasActiveDownloadForTab: (@MainActor (UUID) -> Bool)?

    nonisolated public static let autoWebPageDarkModeDefaultsKey = "dysprosium.browser.autoWebPageDarkMode"
    nonisolated public static let globalShieldEnabledDefaultsKey = "dysprosium.browser.globalShieldEnabled"
    nonisolated private static let palettePresetDefaultsKey = "dysprosium.design.palettePreset"

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
            guard oldValue != userAgentProfile else { return }
            LiveContainerEnvironment.sharedDefaults.set(userAgentProfile.rawValue, forKey: BrowserUserAgentProfile.defaultsKey)
            let activeID = activeTabID
            for tab in tabs {
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
            guard oldValue != searchEngine else { return }
            LiveContainerEnvironment.sharedDefaults.set(searchEngine.rawValue, forKey: BrowserSearchEngine.defaultsKey)
        }
    }

    public var customSearchTemplate: String {
        didSet {
            guard oldValue != customSearchTemplate else { return }
            LiveContainerEnvironment.sharedDefaults.set(customSearchTemplate, forKey: BrowserSearchEngine.customTemplateDefaultsKey)
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
    private var parentTabIDByChildID: [UUID: UUID] = [:]
    private var sharedPrivateWebsiteDataStore: WKWebsiteDataStore?
    private var lifecycleObserverTokens: [NSObjectProtocol] = []
    private var pendingTabsPersistTask: Task<Void, Never>?
    private var initialHydrationTask: Task<Void, Never>?
    private var bookmarksByFolderIndex: [String?: [BrowserBookmark]] = [:]
    public let sqliteStore: BrowserSQLiteStore
    /// Alias preserving clean read-site ergonomics for history queries.
    public var historyStore: BrowserSQLiteStore { sqliteStore }

    private struct SQLiteHydrationSnapshot: Sendable {
        let folders: [BrowserFavoriteFolder]
        let bookmarks: [BrowserBookmark]
        let totalHistoryCount: Int
        let openTabs: [PersistedOpenTab]
        let siteRules: [SiteRuleRecord]
        let dataVersion: Int64
    }

    public init(customStateDirectory: URL? = nil) {
        Self.migratePalettePresetToSharedDefaultsIfNeeded()

        let dir: URL = customStateDirectory
            ?? LiveContainerEnvironment.persistentSubdirectory(named: "BrowserState", excludeFromiCloudBackup: true)
        // Defer SQLite open & bootstrap maintenance off `@MainActor` so cold launch never stalls the UI thread.
        let dbStore = BrowserSQLiteStore(stateDirectory: dir, deferOpen: true)
        self.sqliteStore = dbStore
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
        self.tabs = [makeSession(id: initialID, isPrivate: false)]

        self.initialHydrationTask = Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                dbStore.performDeferredBootstrapIfNeeded()
                return SQLiteHydrationSnapshot(
                    folders: dbStore.loadFolders(),
                    bookmarks: dbStore.loadBookmarks(),
                    totalHistoryCount: dbStore.totalCount(),
                    openTabs: dbStore.loadOpenTabs(),
                    siteRules: dbStore.loadAllSiteRules(),
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
                        if !tab.isExemptFromHibernation {
                            tab.setMediaPlaybackSuspended(true)
                        }
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
                    SystemProxyBridge.sync(dataStore: .default())
                    if let privateStore = self?.sharedPrivateWebsiteDataStore {
                        SystemProxyBridge.sync(dataStore: privateStore)
                    }
                    self?.refreshFromSharedStoreIfChanged()
                }
            }
        )
        let dbForFlush = self.sqliteStore
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            lifecycleObserverTokens.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        let bgGuard = BrowserBackgroundTaskGuard()
                        bgGuard.begin(name: "DysprosiumBrowserSQLiteFlush")
                        Task.detached(priority: .utility) {
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
        pendingTabsPersistTask?.cancel()
        for token in lifecycleObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Awaits completion of the off-main cold-launch SQLite bootstrap hydration.
    public func waitForInitialHydration() async {
        await initialHydrationTask?.value
    }

    private func applyInitialHydration(_ snapshot: SQLiteHydrationSnapshot) {
        self.favoriteFolders = snapshot.folders
        self.bookmarks = snapshot.bookmarks
        self.totalHistoryCount = snapshot.totalHistoryCount
        self.lastObservedDataVersion = snapshot.dataVersion
        self.siteRulesByHost = Dictionary(
            uniqueKeysWithValues: snapshot.siteRules.map {
                (LiveContainerEnvironment.HostNormalizer.normalize($0.host), $0)
            }
        )
        self.rebuildBookmarksFolderIndex()

        if !snapshot.openTabs.isEmpty {
            let userAlreadyInteracted = tabs.count > 1
                || activeSession.isLoading
                || !activeSession.currentURLString.isEmpty

            if !userAlreadyInteracted {
                var builtTabs: [CleanroomWebKitSession] = []
                var chosenActiveID: UUID?
                for rec in snapshot.openTabs {
                    let session = makeSession(id: rec.id, isPrivate: false)
                    builtTabs.append(session)
                    if rec.isActive {
                        chosenActiveID = session.id
                    }
                }
                let targetActiveID = chosenActiveID ?? builtTabs[0].id
                self.tabs = builtTabs
                self.activeTabID = targetActiveID
                self.tabActivationLRU = builtTabs.map(\.id).filter { $0 != targetActiveID } + [targetActiveID]

                for (idx, session) in builtTabs.enumerated() {
                    let saved = snapshot.openTabs[idx]
                    if !saved.urlString.isEmpty {
                        if session.id == targetActiveID {
                            // Hydrate ONLY the active tab at cold launch; all other tabs stay dormant with zero WKWebView.
                            session.load(urlString: saved.urlString)
                        } else {
                            session.stageDeferredRestore(urlString: saved.urlString, title: saved.title)
                        }
                    }
                }
            } else {
                // Preserve the tab the user already started using; append persisted tabs dormantly.
                let existingIDs = Set(tabs.map(\.id))
                for saved in snapshot.openTabs where !existingIDs.contains(saved.id) && !saved.urlString.isEmpty {
                    let session = makeSession(id: saved.id, isPrivate: false)
                    session.stageDeferredRestore(urlString: saved.urlString, title: saved.title)
                    tabs.append(session)
                    tabActivationLRU.insert(session.id, at: 0)
                }
            }
        }

        self.isHydrated = true
        self.historyRevision &+= 1
    }

    /// Checks `PRAGMA data_version` off `@MainActor` on `willEnterForeground` and refreshes shared state
    /// whenever another LiveContainer instance (`LC 1` / `LC 2`) modified the shared `browser.sqlite3` database.
    public func refreshFromSharedStoreIfChanged() {
        let db = sqliteStore
        let previousVersion = lastObservedDataVersion
        Task { @MainActor [weak self] in
            let currentVersion = await Task.detached(priority: .utility) {
                db.dataVersion()
            }.value
            guard let self else { return }

            // Refresh lightweight shared UserDefaults preferences regardless of DB version.
            let latestUA = BrowserUserAgentProfile.persistedCurrent
            if self.userAgentProfile != latestUA { self.userAgentProfile = latestUA }
            DarkReaderEngine.shared.refreshPersistedPreferences()
            let latestDarkMode = DarkReaderEngine.shared.modeBehavior
            if self.webDarkModeBehavior != latestDarkMode { self.webDarkModeBehavior = latestDarkMode }
            let latestDarkPreset = DarkReaderEngine.shared.themePreset
            if self.webDarkThemePreset != latestDarkPreset { self.webDarkThemePreset = latestDarkPreset }
            let latestDark = latestDarkMode.isEnabled
            if self.autoWebPageDarkMode != latestDark { self.autoWebPageDarkMode = latestDark }
            let latestShield = Self.persistedGlobalShieldEnabled
            if self.isShieldEnabled != latestShield { self.isShieldEnabled = latestShield }
            let latestSearch = BrowserSearchEngine.persistedCurrent
            if self.searchEngine != latestSearch { self.searchEngine = latestSearch }
            let latestTemplate = BrowserSearchEngine.persistedCustomTemplate
            if self.customSearchTemplate != latestTemplate { self.customSearchTemplate = latestTemplate }
            let latestPDFAppearance = PDFAppearanceMode.persistedCurrent
            if self.pdfAppearanceMode != latestPDFAppearance { self.pdfAppearanceMode = latestPDFAppearance }
            let latestPDFLayout = PDFDisplayLayoutMode.persistedCurrent
            if self.pdfDisplayLayoutMode != latestPDFLayout { self.pdfDisplayLayoutMode = latestPDFLayout }
            Self.migratePalettePresetToSharedDefaultsIfNeeded()

            guard currentVersion != previousVersion else { return }
            let refreshed = await Task.detached(priority: .utility) {
                (
                    folders: db.loadFolders(),
                    bookmarks: db.loadBookmarks(),
                    totalHistory: db.totalCount(),
                    siteRules: db.loadAllSiteRules(),
                    version: db.dataVersion()
                )
            }.value
            self.favoriteFolders = refreshed.folders
            self.bookmarks = refreshed.bookmarks
            self.totalHistoryCount = refreshed.totalHistory
            self.siteRulesByHost = Dictionary(
                uniqueKeysWithValues: refreshed.siteRules.map {
                    (LiveContainerEnvironment.HostNormalizer.normalize($0.host), $0)
                }
            )
            self.lastObservedDataVersion = refreshed.version
            self.rebuildBookmarksFolderIndex()
            self.historyRevision &+= 1
        }
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
        guard !tabs.contains(where: \.isPrivate),
              let store = sharedPrivateWebsiteDataStore else {
            return
        }
        sharedPrivateWebsiteDataStore = nil
        Task { @MainActor in
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    private func touchTabLRU(_ id: UUID) {
        tabActivationLRU.removeAll { $0 == id }
        tabActivationLRU.append(id)
    }

    /// Hibernates oldest inactive `WKWebView`s when live WebViews exceed `maxLiveWebViews` (`4`) or `1` under memory pressure.
    /// Always exempts the active tab, tabs with active media/PiP/fullscreen/camera/mic, tabs with active downloads,
    /// and tabs running an active media probe or fingerprint audit.
    public func enforceLiveWebViewBudget(aggressive: Bool = false) {
        let budget = aggressive ? 1 : Self.maxLiveWebViews
        var currentLiveCount = liveWebViewCount
        guard currentLiveCount > budget else { return }

        let tabByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let protectedParentIDs = Set(parentTabIDByChildID.values)
        // Build oldest-first eviction order from LRU, including any tab missing from LRU first.
        let lruSet = Set(tabActivationLRU)
        let missingFromLRU = tabs.map(\.id).filter { !lruSet.contains($0) }
        let orderedCandidates = missingFromLRU + tabActivationLRU

        for candidateID in orderedCandidates {
            guard currentLiveCount > budget else { break }
            guard candidateID != activeTabID,
                  !protectedParentIDs.contains(candidateID),
                  let candidate = tabByID[candidateID],
                  candidate.hasLiveWebView else {
                continue
            }
            if candidate.isExemptFromHibernation || (hasActiveDownloadForTab?(candidateID) == true) {
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
    public func openNewTab(urlString: String? = nil, isPrivate: Bool = false, activate: Bool = true) -> CleanroomWebKitSession {
        let departing = activeSession
        let session = makeSession(id: UUID(), isPrivate: isPrivate)
        tabs.append(session)
        if activate {
            departing.capturePreviewSnapshot()
            suspendDepartingTabIfNotPlaying(departing)
            activeTabID = session.id
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
        persistOpenTabsSnapshot()
        return session
    }

    /// Creates a child tab initialized directly with WebKit's `createWebViewWith` configuration
    /// so OAuth `window.opener.postMessage` and `window.close()` operate natively.
    public func openChildTab(
        configuration: WKWebViewConfiguration,
        initialURL: URL?,
        isPrivate: Bool
    ) -> WKWebView {
        let departing = activeSession
        let child = makeSession(id: UUID(), isPrivate: isPrivate)
        let childWebView = child.attachChildWebView(using: configuration, initialURL: initialURL)

        if let parentIdx = tabs.firstIndex(where: { $0.id == departing.id }) {
            tabs.insert(child, at: parentIdx + 1)
        } else {
            tabs.append(child)
        }
        parentTabIDByChildID[child.id] = departing.id

        departing.capturePreviewSnapshot()
        suspendDepartingTabIfNotPlaying(departing)
        activeTabID = child.id
        touchTabLRU(child.id)
        child.setMediaPlaybackSuspended(false)

        enforceLiveWebViewBudget(aggressive: false)
        persistOpenTabsSnapshot()
        return childWebView
    }

    public func switchToTab(id: UUID) {
        guard let target = tabs.first(where: { $0.id == id }) else { return }
        if activeTabID != id {
            let departing = activeSession
            departing.capturePreviewSnapshot()
            suspendDepartingTabIfNotPlaying(departing)
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
        persistOpenTabsSnapshot()
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
           let existing = tabs.first(where: { !$0.isPrivate && $0.activePDF?.localFileURL.standardizedFileURL.path == standardizedPath }) {
            switchToTab(id: existing.id)
            return existing
        }

        let targetSession: CleanroomWebKitSession
        if !activeSession.isPrivate && activeSession.currentURLString.isEmpty && !activeSession.isLoading && activeSession.activePDF == nil {
            targetSession = activeSession
        } else {
            targetSession = openNewTab(urlString: nil, isPrivate: false, activate: true)
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
        let scopedTabs = tabs.filter { $0.isPrivate == scopeIsPrivate }
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
        let copy = makeSession(id: UUID(), isPrivate: source.isPrivate)
        tabs.insert(copy, at: idx + 1)

        departing.capturePreviewSnapshot()
        suspendDepartingTabIfNotPlaying(departing)
        activeTabID = copy.id
        touchTabLRU(copy.id)
        copy.setMediaPlaybackSuspended(false)

        let sourceURL = source.currentURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sourceURL.isEmpty {
            copy.load(urlString: sourceURL)
        }
        enforceLiveWebViewBudget(aggressive: false)
        persistOpenTabsSnapshot()
    }

    public func closeOtherTabs(keeping id: UUID) {
        guard let keeper = tabs.first(where: { $0.id == id }) else { return }
        let scopeIsPrivate = keeper.isPrivate
        let victims = tabs.filter { $0.isPrivate == scopeIsPrivate && $0.id != id }
        guard !victims.isEmpty else { return }

        for tab in victims {
            recordRecentlyClosedIfStandard(tab)
            tab.teardown()
            tabActivationLRU.removeAll { $0 == tab.id }
            parentTabIDByChildID.removeValue(forKey: tab.id)
        }
        let victimIDs = Set(victims.map(\.id))
        parentTabIDByChildID = parentTabIDByChildID.filter { !victimIDs.contains($0.value) }
        tabs.removeAll { $0.isPrivate == scopeIsPrivate && $0.id != id }

        if !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = keeper.id
            touchTabLRU(keeper.id)
            keeper.setMediaPlaybackSuspended(false)
            keeper.hydrateDeferredURLIfNeeded()
        }
        persistOpenTabsSnapshot()
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

    public func closeAllTabs(isPrivate: Bool) {
        let victims = tabs.filter { $0.isPrivate == isPrivate }
        guard !victims.isEmpty else { return }
        let victimIDs = Set(victims.map(\.id))
        for tab in victims {
            recordRecentlyClosedIfStandard(tab)
            tab.teardown()
            tabActivationLRU.removeAll { $0 == tab.id }
            parentTabIDByChildID.removeValue(forKey: tab.id)
        }
        parentTabIDByChildID = parentTabIDByChildID.filter { !victimIDs.contains($0.value) }
        tabs.removeAll { $0.isPrivate == isPrivate }

        if isPrivate {
            discardSharedPrivateWebsiteDataStoreIfNoPrivateTabsRemain()
        }

        if tabs.isEmpty {
            let fresh = makeSession(id: UUID(), isPrivate: false)
            tabs = [fresh]
            activeTabID = fresh.id
            touchTabLRU(fresh.id)
        } else if !tabs.contains(where: { $0.id == activeTabID }) {
            let nextActive = tabs[tabs.count - 1]
            activeTabID = nextActive.id
            touchTabLRU(nextActive.id)
            nextActive.hydrateDeferredURLIfNeeded()
        }
        persistOpenTabsSnapshot()
    }

    public func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removing = tabs[idx]
        let wasPrivate = removing.isPrivate
        let preferredParentID = parentTabIDByChildID.removeValue(forKey: id)
        parentTabIDByChildID = parentTabIDByChildID.filter { $0.value != id }

        recordRecentlyClosedIfStandard(removing)
        removing.teardown()
        tabs.remove(at: idx)
        tabActivationLRU.removeAll { $0 == id }

        if wasPrivate {
            discardSharedPrivateWebsiteDataStoreIfNoPrivateTabsRemain()
        }

        if tabs.isEmpty {
            let fresh = makeSession(id: UUID(), isPrivate: false)
            tabs = [fresh]
            activeTabID = fresh.id
            touchTabLRU(fresh.id)
        } else if activeTabID == id {
            let nextActive: CleanroomWebKitSession
            if let preferredParentID,
               let parentTab = tabs.first(where: { $0.id == preferredParentID }) {
                nextActive = parentTab
            } else {
                let nextIdx = min(idx, tabs.count - 1)
                nextActive = tabs[nextIdx]
            }
            activeTabID = nextActive.id
            touchTabLRU(nextActive.id)
            nextActive.setMediaPlaybackSuspended(false)
            nextActive.hydrateDeferredURLIfNeeded()
        }
        persistOpenTabsSnapshot()
    }

    private func recordRecentlyClosedIfStandard(_ tab: CleanroomWebKitSession) {
        guard !tab.isPrivate else { return }
        let urlStr = tab.currentURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlStr.isEmpty else { return }
        let entry = RecentlyClosedTab(
            id: UUID(),
            urlString: urlStr,
            title: tab.displayTabTitle,
            closedAt: Date()
        )
        recentlyClosedTabs.insert(entry, at: 0)
        if recentlyClosedTabs.count > Self.maxRecentlyClosedTabs {
            recentlyClosedTabs.removeLast(recentlyClosedTabs.count - Self.maxRecentlyClosedTabs)
        }
    }

    @discardableResult
    public func reopenLastClosedTab() -> CleanroomWebKitSession? {
        guard !recentlyClosedTabs.isEmpty else { return nil }
        let last = recentlyClosedTabs.removeFirst()
        return openNewTab(urlString: last.urlString, isPrivate: false, activate: true)
    }

    public func clearRecentlyClosedTabs() {
        recentlyClosedTabs.removeAll()
    }

    private func persistOpenTabsSnapshot() {
        let currentActive = activeTabID
        let vaultRoot = LiveContainerEnvironment.downloadsDirectory.standardizedFileURL.path
        let records: [PersistedOpenTab] = tabs
            .filter { !$0.isPrivate }
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
                    urlString: persistedURL,
                    title: persistedURL.isEmpty ? "" : tab.pageTitle,
                    sortOrder: Double(idx + 1) * 100.0,
                    isActive: tab.id == currentActive
                )
            }
        let db = sqliteStore
        pendingTabsPersistTask?.cancel()
        pendingTabsPersistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            db.saveOpenTabs(records)
        }
    }

    // MARK: - Per-Site Policy Rules (`site_rules` in `browser.sqlite3`)

    public func siteRule(forHost rawHost: String) -> SiteRuleRecord? {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
        guard !host.isEmpty else { return nil }
        if let cached = siteRulesByHost[host] {
            return cached
        }
        if let fromDB = sqliteStore.siteRule(forHost: host) {
            siteRulesByHost[host] = fromDB
            return fromDB
        }
        return nil
    }

    public func updateSiteRule(_ rule: SiteRuleRecord) {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rule.host)
        guard !host.isEmpty else { return }
        let normalizedRule = SiteRuleRecord(
            host: host,
            shieldMode: rule.shieldMode,
            darkMode: rule.darkMode,
            uaMode: rule.uaMode,
            pageZoom: rule.pageZoom
        )
        if normalizedRule.isAllDefault {
            siteRulesByHost.removeValue(forKey: host)
        } else {
            siteRulesByHost[host] = normalizedRule
        }
        let db = sqliteStore
        Task.detached(priority: .utility) {
            db.upsertSiteRule(normalizedRule)
        }
        applySiteRuleToMatchingTabs(host: host, rule: normalizedRule)
    }

    public func updateSiteRule(
        forHost rawHost: String,
        shieldMode: Int? = nil,
        darkMode: Int? = nil,
        uaMode: Int? = nil,
        pageZoom: Double? = nil,
        resetPageZoom: Bool = false
    ) {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
        guard !host.isEmpty else { return }
        var current = siteRule(forHost: host) ?? SiteRuleRecord(host: host)
        if let shieldMode { current.shieldMode = shieldMode }
        if let darkMode { current.darkMode = darkMode }
        if let uaMode { current.uaMode = uaMode }
        if resetPageZoom {
            current.pageZoom = nil
        } else if let pageZoom {
            let clamped = SiteRuleRecord.clampedZoom(pageZoom)
            current.pageZoom = abs(clamped - 1.0) < 0.001 ? nil : clamped
        }
        updateSiteRule(current)
    }

    public func resetSiteRule(forHost rawHost: String) {
        let host = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
        guard !host.isEmpty else { return }
        siteRulesByHost.removeValue(forKey: host)
        let db = sqliteStore
        Task.detached(priority: .utility) {
            db.deleteSiteRule(forHost: host)
        }
        applySiteRuleToMatchingTabs(host: host, rule: SiteRuleRecord(host: host))
    }

    public func effectiveShieldEnabled(forHost rawHost: String?) -> Bool {
        if let rawHost, let rule = siteRule(forHost: rawHost) {
            if rule.shieldMode == 1 { return true }
            if rule.shieldMode == -1 { return false }
        }
        return CleanroomContentBlocker.shared.effectiveShieldEnabled(
            globalEnabled: isShieldEnabled,
            forHost: rawHost
        )
    }

    public func effectiveAutoDark(forHost rawHost: String?) -> Bool {
        if let rawHost, let rule = siteRule(forHost: rawHost) {
            if rule.darkMode == 1 { return true }
            if rule.darkMode == -1 { return false }
        }
        if let rawHost, DarkReaderEngine.shared.isHostBypassed(rawHost) {
            return false
        }
        return autoWebPageDarkMode
    }

    public func effectiveUserAgent(forHost rawHost: String?) -> BrowserUserAgentProfile {
        if let rawHost, let rule = siteRule(forHost: rawHost) {
            if rule.uaMode == 1 { return .iosSafari }
            if rule.uaMode == 2 { return .macosSafari }
        }
        return userAgentProfile
    }

    public func effectivePageZoom(forHost rawHost: String?) -> Double {
        if let rawHost, let zoom = siteRule(forHost: rawHost)?.pageZoom {
            return SiteRuleRecord.clampedZoom(zoom)
        }
        return 1.0
    }

    private func applySiteRuleToMatchingTabs(host: String, rule: SiteRuleRecord) {
        let targetUA = effectiveUserAgent(forHost: host)
        let targetDark = effectiveAutoDark(forHost: host)
        let targetZoom = effectivePageZoom(forHost: host)
        let activeID = activeTabID
        for tab in tabs {
            guard let tabHost = tab.currentBypassableHost,
                  LiveContainerEnvironment.HostNormalizer.normalize(tabHost) == host else {
                continue
            }
            tab.applyPageZoom(targetZoom)
            if tab.id == activeID {
                if rule.shieldMode == -1 {
                    tab.setShieldBypassedForCurrentHost(true)
                } else if rule.shieldMode == 1 {
                    tab.setShieldBypassedForCurrentHost(false)
                }
                tab.applyAutoWebPageDarkMode(targetDark)
                tab.applyUserAgentProfile(targetUA, reloadIfLoaded: false)
            } else {
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
        let nextOrder = (favoriteFolders.map(\.sortOrder).max() ?? 0) + 100.0
        let created = BrowserFavoriteFolder(parentID: parentID, title: trimmed, sortOrder: nextOrder)
        sqliteStore.upsertFolder(created)
        favoriteFolders = sqliteStore.loadFolders()
        rebuildBookmarksFolderIndex()
        return created
    }

    public func renameFolder(id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var target = favoriteFolders.first(where: { $0.id == id }) else { return }
        target.title = trimmed
        sqliteStore.upsertFolder(target)
        favoriteFolders = sqliteStore.loadFolders()
        rebuildBookmarksFolderIndex()
    }

    public func deleteFolder(id: String, keepBookmarks: Bool) {
        sqliteStore.deleteFolder(id: id, keepBookmarks: keepBookmarks)
        favoriteFolders = sqliteStore.loadFolders()
        bookmarks = sqliteStore.loadBookmarks()
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

        if var existing = existingBookmark(for: cleanURL) {
            existing.title = effectiveTitle
            existing.folderID = folderID
            sqliteStore.upsertBookmark(existing)
        } else {
            let nextOrder = (bookmarks.map(\.sortOrder).max() ?? 0) + 100.0
            let created = BrowserBookmark(
                title: effectiveTitle,
                urlString: cleanURL,
                symbolName: "globe",
                folderID: folderID,
                sortOrder: nextOrder
            )
            sqliteStore.upsertBookmark(created)
        }
        bookmarks = sqliteStore.loadBookmarks()
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
        if Self.normalizeURLKey(target.urlString) != Self.normalizeURLKey(cleanURL) {
            sqliteStore.deleteBookmark(id: id)
        }
        target.title = effectiveTitle
        target.urlString = cleanURL
        target.folderID = folderID
        sqliteStore.upsertBookmark(target)
        bookmarks = sqliteStore.loadBookmarks()
        rebuildBookmarksFolderIndex()
    }

    public func moveBookmark(id: String, toFolderID folderID: String?) {
        guard var target = bookmarks.first(where: { $0.id == id }) else { return }
        target.folderID = folderID
        sqliteStore.upsertBookmark(target)
        bookmarks = sqliteStore.loadBookmarks()
        rebuildBookmarksFolderIndex()
    }

    public func removeBookmark(id: String) {
        sqliteStore.deleteBookmark(id: id)
        bookmarks = sqliteStore.loadBookmarks()
        rebuildBookmarksFolderIndex()
    }

    // MARK: - Local FTS5 Omnibox Autocomplete

    /// Returns deduplicated local suggestions combining matching Favorites (prioritized) and
    /// frecency-ranked SQLite FTS5 `places` off `@MainActor`.
    public func omniboxSuggestions(for query: String, limit: Int = 6) async -> [OmniboxSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        let bookmarksSnapshot = bookmarks
        let db = historyStore
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
                let places = db.queryTopPlaces(matching: trimmed, limit: max(limit * 2, 12))
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
                    let targetID = existingFolderIDs.contains(spec.tempID) ? UUID().uuidString : spec.tempID
                    let created = BrowserFavoriteFolder(
                        id: targetID,
                        parentID: resolvedParentID,
                        title: effectiveTitle,
                        sortOrder: nextFolderOrder,
                        createdAt: spec.createdAt
                    )
                    nextFolderOrder += 100.0
                    sqliteStore.upsertFolder(created)
                    existingFolderIDs.insert(created.id)
                    existingFoldersByKey[lookupKey] = created.id
                    resolvedFolderIDByTempID[spec.tempID] = created.id
                }
                progress = true
            }
            remaining = deferred
        }

        var nextBookmarkOrder = (bookmarks.map(\.sortOrder).max() ?? 0) + 100.0
        var importedCount = 0
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
            sqliteStore.upsertBookmark(created)
            importedCount += 1
        }

        favoriteFolders = sqliteStore.loadFolders()
        bookmarks = sqliteStore.loadBookmarks()
        rebuildBookmarksFolderIndex()
        return importedCount
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
        totalHistoryCount = sqliteStore.totalCount()
        historyRevision &+= 1
    }

    public func clearHistoryDay(dayYMD: Int64) {
        sqliteStore.clearDay(dayYMD: dayYMD)
        totalHistoryCount = sqliteStore.totalCount()
        historyRevision &+= 1
    }

    public func clearTodayHistory() {
        clearHistoryDay(dayYMD: BrowserSQLiteStore.calendarDayYMD(for: Date()))
    }

    public func clearHistory() {
        sqliteStore.clearAll()
        sqliteStore.reclaimStorage(fullVacuum: true)
        totalHistoryCount = 0
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

    /// Performs thorough, zero-ghost-storage clearing across SQLite (`VACUUM` + WAL truncation),
    /// WebKit caches/storage/ServiceWorkers/FileSystem/MediaKeys, stubborn `HttpOnly` cookies,
    /// Foundation `URLCache` / `HTTPCookieStorage`, `DarkReaderEngine`, `SiteIconStore`,
    /// orphaned staging/temp files, live tab Web Storage, and optional transfer auth-header scrubbing.
    @discardableResult
    public func performClearBrowsingData(
        since cutoff: Date,
        until endCutoff: Date? = nil,
        options: BrowsingClearOptions,
        activeTransferIDs: Set<UUID>? = nil,
        onScrubTransferAuthData: (@MainActor () async -> Void)? = nil
    ) async -> BrowsingClearReport {
        let beforeFootprint = await computeStorageFootprint()

        var historyEntriesRemoved = 0
        var websiteRecordsRemoved = 0
        var cookiesRemoved = 0
        var temporaryBytesReclaimed: UInt64 = 0
        var closedTabCount = 0

        // 1. History Scope (SQLite delete + physical VACUUM + WAL truncate)
        if options.includeHistory {
            let db = sqliteStore
            let (removedCount, remainingCount, updatedVersion) = await Task.detached(priority: .userInitiated) {
                let matching = db.countEntries(since: cutoff, until: endCutoff)
                db.clearEntries(since: cutoff, until: endCutoff)
                db.reclaimStorage(fullVacuum: true)
                return (matching, db.totalCount(), db.dataVersion())
            }.value
            historyEntriesRemoved = removedCount
            totalHistoryCount = remainingCount
            lastObservedDataVersion = updatedVersion
            historyRevision &+= 1

            if cutoff <= .distantPast && endCutoff == nil {
                await SiteIconStore.shared.clearDiskCache()
                clearRecentlyClosedTabs()
            }
        }

        // 2. Cache Scope
        var websiteTypes = Set<String>()
        if options.includeCache {
            websiteTypes.formUnion(Self.cacheWebsiteDataTypes)
            URLCache.shared.removeAllCachedResponses()
            DarkReaderEngine.shared.purgeMemoryCache()
            await SiteIconStore.shared.clearDiskCache()

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
            let dataStore = WKWebsiteDataStore.default()
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

                // Clear Foundation `HTTPCookieStorage.shared` as well.
                let sharedCookiesBefore = HTTPCookieStorage.shared.cookies?.count ?? 0
                HTTPCookieStorage.shared.removeCookies(since: cutoff)
                let sharedCookiesAfter = HTTPCookieStorage.shared.cookies?.count ?? 0
                if sharedCookiesBefore > sharedCookiesAfter {
                    cookiesRemoved += (sharedCookiesBefore - sharedCookiesAfter)
                }

                // Clear live in-memory Web Storage (`sessionStorage` + `localStorage`) on active standard tabs.
                for tab in tabs where !tab.isPrivate {
                    await tab.clearLiveWebStorageIfLoaded()
                }

                // Scrub persisted transfer auth headers (`Cookie` / `Authorization`) in `TransferStore` if wired.
                if let scrub = onScrubTransferAuthData ?? self.onScrubTransferAuthData {
                    await scrub()
                }
            }

            for tab in tabs where !tab.isPrivate {
                tab.clearCandidates()
            }
        }

        // 4. Close Standard Tabs Scope
        if options.closeStandardTabs {
            closedTabCount = tabs.filter { !$0.isPrivate }.count
            closeAllTabs(isPrivate: false)
            clearRecentlyClosedTabs()
        }

        let afterFootprint = await computeStorageFootprint()
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
    public func clearAllBrowsingData() async -> BrowsingClearReport {
        await performClearBrowsingData(
            since: .distantPast,
            options: BrowsingClearOptions(
                includeHistory: true,
                includeCache: true,
                includeCookiesAndSessions: true,
                closeStandardTabs: false
            )
        )
    }

    // MARK: - Per-Site Website Data & Storage Footprint Inspection

    /// Measures real disk bytes across SQLite (+ WAL/SHM), `SiteIcons`, WebKit cache/data directories,
    /// and `Staging`/temp directories without blocking `@MainActor`.
    public func computeStorageFootprint() async -> BrowserStorageFootprint {
        let db = sqliteStore
        let stagingDir = LiveContainerEnvironment.stagingDirectory
        let tempDir = FileManager.default.temporaryDirectory
        let cachesWebKitDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WebKit", isDirectory: true)
        let libraryWebKitDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WebKit", isDirectory: true)
        let libraryCookiesDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Cookies", isDirectory: true)

        async let diskMetrics: (sqlite: UInt64, webKit: UInt64, staging: UInt64) = Task.detached(priority: .utility) {
            let sqliteBytes = db.databaseDiskUsageBytes()
            var wkBytes: UInt64 = 0
            if let cachesWebKitDir {
                wkBytes &+= LiveContainerEnvironment.directorySizeBytes(at: cachesWebKitDir)
            }
            if let libraryWebKitDir {
                wkBytes &+= LiveContainerEnvironment.directorySizeBytes(at: libraryWebKitDir)
            }
            if let libraryCookiesDir {
                wkBytes &+= LiveContainerEnvironment.directorySizeBytes(at: libraryCookiesDir)
            }
            let stagingBytes = LiveContainerEnvironment.directorySizeBytes(at: stagingDir)
                &+ LiveContainerEnvironment.directorySizeBytes(at: tempDir)
            return (sqliteBytes, wkBytes, stagingBytes)
        }.value

        async let iconBytes = SiteIconStore.shared.diskUsageBytes()
        async let domains = fetchWebsiteDataDomains()

        let (metrics, favBytes, domainList) = await (diskMetrics, iconBytes, domains)
        return BrowserStorageFootprint(
            historySQLiteBytes: metrics.sqlite,
            faviconCacheBytes: favBytes,
            webKitCacheBytes: metrics.webKit,
            stagingTempBytes: metrics.staging,
            websiteDomainCount: domainList.count
        )
    }

    /// Enumerates every website domain currently holding cookies, storage, or caches in `WKWebsiteDataStore.default()`,
    /// merged with any stubborn cookie-only domains from `WKHTTPCookieStore`, sorted alphabetically.
    public func fetchWebsiteDataDomains() async -> [WebsiteDataDomainSummary] {
        let dataStore = WKWebsiteDataStore.default()
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

    /// Completely removes all website data for the specified domains:
    /// `WKWebsiteDataRecord`s, matching `WKHTTPCookieStore` (`HttpOnly`) & `HTTPCookieStorage.shared` cookies,
    /// `SiteIconStore` cached favicons, and live tab `sessionStorage`/`localStorage` — zero ghost remnants.
    public func removeWebsiteData(forDisplayNames names: Set<String>) async {
        let normalizedTargets: Set<String> = Set(
            names.compactMap { raw -> String? in
                let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
                let norm = LiveContainerEnvironment.HostNormalizer.normalize(trimmed)
                return norm.isEmpty ? nil : norm
            }
        )
        guard !normalizedTargets.isEmpty else { return }

        let dataStore = WKWebsiteDataStore.default()
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

        // 3. Remove matching cookies from Foundation HTTPCookieStorage.shared
        if let sharedCookies = HTTPCookieStorage.shared.cookies {
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

        // 4. Remove cached favicons from SiteIconStore
        for host in normalizedTargets {
            await SiteIconStore.shared.removeIcon(forHost: host)
        }

        // 5. Clear live sessionStorage/localStorage & candidates on matching standard tabs
        for tab in tabs where !tab.isPrivate && tab.matchesDomainSet(normalizedTargets) {
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

    private func makeSession(id: UUID, isPrivate: Bool) -> CleanroomWebKitSession {
        let privateStoreProvider: (@MainActor () -> WKWebsiteDataStore)?
        if isPrivate {
            privateStoreProvider = { [weak self] in
                self?.acquireSharedPrivateWebsiteDataStore() ?? .nonPersistent()
            }
        } else {
            privateStoreProvider = nil
        }
        let siteRuleProvider: @MainActor (String) -> SiteRuleRecord? = { [weak self] host in
            self?.siteRule(forHost: host)
        }
        let session = CleanroomWebKitSession(
            id: id,
            isPrivate: isPrivate,
            privateWebsiteDataStoreProvider: privateStoreProvider,
            siteRuleProvider: siteRuleProvider
        )
        wireTabCallbacks(session)
        return session
    }

    private func wireTabCallbacks(_ session: CleanroomWebKitSession) {
        session.onOpenLinkInTab = { [weak self] url, isPrivate, activate in
            self?.openNewTab(urlString: url.absoluteString, isPrivate: isPrivate, activate: activate)
        }
        session.onNavigationCommitted = { [weak self] url, title in
            guard let self else { return }
            self.recordHistoryVisit(url: url, title: title)
            self.persistOpenTabsSnapshot()
        }
        session.onCreateChildWebViewTab = { [weak self, weak session] configuration, initialURL in
            guard let self else { return nil }
            return self.openChildTab(
                configuration: configuration,
                initialURL: initialURL,
                isPrivate: session?.isPrivate ?? false
            )
        }
        session.onRequestCloseSelf = { [weak self, weak session] in
            guard let self, let id = session?.id else { return }
            self.closeTab(id: id)
        }
    }

    private func recordHistoryVisit(url: URL, title: String) {
        let store = sqliteStore
        Task.detached(priority: .utility) { [weak self] in
            store.recordVisit(url: url, title: title, visitedAt: Date())
            let updatedTotal = store.totalCount()
            let updatedVersion = store.dataVersion()
            await MainActor.run {
                guard let self else { return }
                self.totalHistoryCount = updatedTotal
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
