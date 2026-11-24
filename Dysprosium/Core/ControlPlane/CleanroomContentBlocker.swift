import CryptoKit
import Foundation
import Observation
import WebKit

/// Persisted metadata for an external, community-maintained content-blocking filter subscription.
public struct FilterSubscription: Identifiable, Codable, Hashable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case ads = "Ads & Trackers"
        case regional = "Chinese & Regional"
        case privacy = "Privacy & Telemetry"
        case security = "Malware & Badware"
        case popups = "Popups & Annoyances"
        case antiAdblock = "Anti-Adblock Bypass"
        case custom = "Custom List"

        public var localizedTitle: String {
            switch self {
            case .ads: return L("Ads & Trackers")
            case .regional: return L("Chinese & Regional")
            case .privacy: return L("Privacy & Telemetry")
            case .security: return L("Malware & Badware")
            case .popups: return L("Popups & Annoyances")
            case .antiAdblock: return L("Anti-Adblock Bypass")
            case .custom: return L("Custom List")
            }
        }
    }

    public var localizedTitle: String {
        guard isBuiltInSeed else { return title }
        switch id {
        case "ubol-core": return L("uBlock Origin Lite · Core Filters")
        case "adguard-ios-base": return L("AdGuard Base + EasyList (iOS)")
        case "adguard-ios-chinese": return L("AdGuard Chinese Filter (iOS)")
        case "cjx-annoyance": return L("CJX's Annoyance List")
        case "ubo-privacy": return L("uBlock Origin · Privacy")
        case "adguard-ios-tracking": return L("AdGuard Tracking Protection (iOS)")
        case "ubo-badware": return L("uBlock Origin · Badware Risks")
        case "ubol-annoyances": return L("uBlock Origin Lite · Popups & Overlays")
        case "adguard-ios-annoyances": return L("AdGuard Popups & Annoyances (iOS)")
        case "easylist-anti-adblock": return L("Anti-Adblock Warning Removal")
        case "ubo-unbreak": return L("uBlock Origin · Unbreak")
        case "ubo-quick-fixes": return L("uBlock Origin · Quick Fixes")
        case "adguard-ios-mobile": return L("AdGuard Mobile Ads Filter (iOS)")
        case "adguard-ios-cookies": return L("AdGuard Cookie Notices (iOS)")
        case "adguard-ios-social": return L("AdGuard Social Media Widgets (iOS)")
        case "peter-lowe-blocklist": return L("Peter Lowe's Ad & Tracking Server List")
        default: return title
        }
    }

    public var localizedSubtitle: String {
        guard isBuiltInSeed else { return subtitle }
        switch id {
        case "ubol-core": return L("uBOL-home MV3 network & video ad ruleset")
        case "adguard-ios-base": return L("WebKit-optimized global ad & pre-roll filter feed")
        case "adguard-ios-chinese": return L("WebKit-optimized domestic ad SDKs & 'Open in App' overlays")
        case "cjx-annoyance": return L("Removes Chinese self-promo banners, QR prompts & nags")
        case "ubo-privacy": return L("Blocks telemetry beacons, session replay & analytics scripts")
        case "adguard-ios-tracking": return L("WebKit-optimized tracker, pixel & fingerprinting defense")
        case "ubo-badware": return L("Blocks known malware, phishing & browser-mining hosts")
        case "ubol-annoyances": return L("uBOL-home popunder, modal & overlay shield")
        case "adguard-ios-annoyances": return L("Blocks hostile popups ($popup) & floating banners")
        case "easylist-anti-adblock": return L("Community rules bypassing anti-adblock walls")
        case "ubo-unbreak": return L("Scriptlets fixing broken media players & anti-adblock walls")
        case "ubo-quick-fixes": return L("Rapid-response anti-adblock & video player scriptlets")
        case "adguard-ios-mobile": return L("Optional mobile WAP/banner ad network rules")
        case "adguard-ios-cookies": return L("Optional GDPR / EU cookie consent banner suppressor")
        case "adguard-ios-social": return L("Optional third-party share buttons & social embed blocker")
        case "peter-lowe-blocklist": return L("Optional compact host-level ad & tracker domain list")
        default: return subtitle
        }
    }

    public enum Format: String, Codable, Sendable {
        case dnrJSON
        case abpFilterList
    }

    public let id: String
    public var title: String
    public var subtitle: String
    public var sourceURL: URL
    public var category: Category
    public var format: Format
    public var maxRuleBudget: Int
    public var isEnabled: Bool
    public var isBuiltInSeed: Bool
    public var etag: String?
    public var lastModified: String?
    public var lastSyncedAt: Date?
    public var compiledRuleCount: Int
    public var lastError: String?

    public init(
        id: String,
        title: String,
        subtitle: String,
        sourceURL: URL,
        category: Category,
        format: Format,
        maxRuleBudget: Int = 18_000,
        isEnabled: Bool = true,
        isBuiltInSeed: Bool = false,
        etag: String? = nil,
        lastModified: String? = nil,
        lastSyncedAt: Date? = nil,
        compiledRuleCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sourceURL = sourceURL
        self.category = category
        self.format = format
        self.maxRuleBudget = maxRuleBudget
        self.isEnabled = isEnabled
        self.isBuiltInSeed = isBuiltInSeed
        self.etag = etag
        self.lastModified = lastModified
        self.lastSyncedAt = lastSyncedAt
        self.compiledRuleCount = compiledRuleCount
        self.lastError = lastError
    }
}

/// Subscription lifecycle & `WKContentRuleListStore` orchestrator.
/// Delegates CPU-bound DNR/ABP parsing to `WebKitRuleCompiler` (`nonisolated` background execution)
/// and injects scripts from `BrowserInjectedScripts`.
@Observable
@MainActor
public final class CleanroomContentBlocker {
    public static let shared = CleanroomContentBlocker()
    public typealias CompiledRuleBuckets = WebKitRuleCompiler.CompiledRuleBuckets

    public private(set) var subscriptions: [FilterSubscription] = []
    public private(set) var compiledLists: [WKContentRuleList] = []
    /// Monotonically incremented whenever `compiledLists` changes so `CleanroomWebKitSession`
    /// only re-attaches `WKContentRuleList` bytecode when the effective list actually changed.
    public private(set) var compiledListsGeneration: UInt64 = 0
    public private(set) var compiledScriptletRules: [WebKitRuleCompiler.CompiledScriptletRule] = []
    /// Computed on demand (never pinned in RAM or read from disk at cold launch).
    public var compiledScriptletRuntimeSource: String {
        BrowserInjectedScripts.buildScriptletRuntimeScript(rules: compiledScriptletRules)
    }
    public private(set) var activeRuleCount: Int = 0
    public private(set) var isSyncing: Bool = false
    public private(set) var lastGlobalSyncDate: Date?
    /// Normalized hostnames (lowercase, leading `www.` stripped) where Content Shield is paused
    /// while keeping media stream capture active.
    public private(set) var bypassedHosts: Set<String> = []

    private struct AttachedControllerEntry {
        weak var controller: WKUserContentController?
        var profileID: String?
        var isEnabledProvider: @MainActor () -> Bool
        var currentHostProvider: @MainActor () -> String?
        var fingerprintSeedProvider: @MainActor () -> String?
        var userAgentProfileProvider: @MainActor () -> BrowserUserAgentProfile?
        var autoWebPageDarkModeProvider: @MainActor () -> Bool?
        var storedExplicitSeedOverride: String?
        var lastMaskFoldableScreenOverride: Bool?
        var lastUserAgentProfile: BrowserUserAgentProfile?
        var lastAutoWebPageDarkMode: Bool?
        var lastAppliedRuleListEnabled: Bool?
        var lastAppliedRuleListGeneration: UInt64?
    }

    private final class SubframeHostTracker {
        var currentMainHost: String?
        var injectedHosts: Set<String> = []
        var injectedSources: Set<String> = []
        var baseScripts: [WKUserScript] = []
        var subframeScripts: [(host: String, source: String, script: WKUserScript)] = []
    }

    private var attachedControllers: [AttachedControllerEntry] = []
    private var scriptletIndexByHost: [String: [Int]] = [:]
    private var perHostScriptletCache: [String: String] = [:]
    @ObservationIgnored
    private let injectedSubframeHostsByController = NSMapTable<WKUserContentController, SubframeHostTracker>.weakToStrongObjects()
    private var inFlightEnsureTask: Task<[WKContentRuleList], Never>?
    private var inFlightFastRestoreTask: Task<[WKContentRuleList], Never>?
    private var warmupTask: Task<Void, Never>?
    private var didStartPrewarm = false
    private var didMutateSubscriptionsBeforeWarmup = false
    private var didBootstrap = false

    private static let refreshIntervalSeconds: TimeInterval = 12 * 3600
    private static let maxRulesPerChunk = 35_000
    private static let maxGlobalCosmeticSelectors = 4_000
    private static let maxGlobalAllowRules = 1_500
    private static let maxGlobalScriptletRules = WebKitRuleCompiler.maxCompiledScriptletRules
    private static let maxSubframeScriptsPerController = 8
    private static let compilerSchemaVersion = "v10"
    private static let chunkIdentifierPrefix = "dysprosium.filters.chunk."
    private static let compiledSignatureKey = "dysprosium.filters.compiledSignature"
    private static let compiledCompilerVersionKey = "dysprosium.filters.compilerVersion"
    private static let compiledChunkCountKey = "dysprosium.filters.compiledChunkCount"
    private static let compiledChunkIDsKey = "dysprosium.filters.compiledChunkIDs"
    private static let compiledRuleTotalKey = "dysprosium.filters.compiledRuleTotal"
    private static let bypassedHostsKey = "dysprosium.filters.bypassedHosts"

    private func persistedChunkIdentifiers() -> [String] {
        let idsKey = Self.compiledChunkIDsKey + stateDefaultsNamespace
        if let saved = UserDefaults.standard.stringArray(forKey: idsKey) {
            return saved
        }
        let legacyCount = UserDefaults.standard.integer(forKey: Self.compiledChunkCountKey + stateDefaultsNamespace)
        guard legacyCount > 0 else { return [] }
        return (0..<legacyCount).map { "\(Self.chunkIdentifierPrefix)\(stateDefaultsNamespace)\($0)" }
    }

    private let storageDirectory: URL
    private let manifestURL: URL
    private let compiledScriptletsURL: URL
    private let stateDefaultsNamespace: String
    private let urlSession: URLSession

    public init(storageDirectory: URL? = nil) {
        let isCustomDirectory = (storageDirectory != nil)
        let baseDir: URL = storageDirectory
            ?? LiveContainerEnvironment.persistentAppSupportDirectory.appendingPathComponent("FilterLists", isDirectory: true)
        self.storageDirectory = baseDir
        self.manifestURL = baseDir.appendingPathComponent("subscriptions.json", isDirectory: false)
        self.compiledScriptletsURL = baseDir.appendingPathComponent("scriptlets_compiled.json", isDirectory: false)
        if storageDirectory == nil {
            self.stateDefaultsNamespace = ""
        } else {
            let digest = SHA256.hash(data: Data(baseDir.standardizedFileURL.path.utf8))
            self.stateDefaultsNamespace = "." + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 18
        cfg.timeoutIntervalForResource = 35
        self.urlSession = URLSession(configuration: cfg)

        // Bypassed hosts live in shared App Group defaults (`LC 1` / `LC 2` parity) with one-time legacy fallback.
        let shared = LiveContainerEnvironment.sharedDefaults
        let standard = UserDefaults.standard
        let bypassKey = Self.bypassedHostsKey + self.stateDefaultsNamespace
        if shared.stringArray(forKey: bypassKey) == nil,
           standard !== shared,
           let legacyBypass = standard.stringArray(forKey: bypassKey) {
            shared.set(legacyBypass, forKey: bypassKey)
        }
        let savedBypassed = shared.stringArray(forKey: bypassKey) ?? []
        self.bypassedHosts = Set(savedBypassed.compactMap { Self.normalizeBypassHostValue($0) })

        // `WKContentRuleListStore.default()` bytecode is per-LC container, so its compiled metadata stays local.
        let savedRuleTotal = standard.integer(forKey: Self.compiledRuleTotalKey + self.stateDefaultsNamespace)
        self.activeRuleCount = savedRuleTotal

        if isCustomDirectory {
            Self.prepareStorageDirectory(baseDir)
            self.subscriptions = Self.loadOrSeedSubscriptions(from: self.manifestURL)
            self.lastGlobalSyncDate = self.subscriptions.compactMap(\.lastSyncedAt).max()
        } else {
            self.subscriptions = Self.defaultCommunitySubscriptions
            self.lastGlobalSyncDate = nil
        }

        let manifestFileURL = self.manifestURL
        let scriptletsURL = self.compiledScriptletsURL
        self.warmupTask = Task.detached(priority: .userInitiated) { [weak self] in
            var loadedSubs: [FilterSubscription]?
            if !isCustomDirectory {
                _ = LiveContainerEnvironment.persistentSubdirectory(named: "FilterLists", excludeFromiCloudBackup: true)
                Self.prepareStorageDirectory(baseDir)
                loadedSubs = Self.loadOrSeedSubscriptions(from: manifestFileURL)
            }

            var decodedScriptlets: [WebKitRuleCompiler.CompiledScriptletRule]?
            var scriptletIndex: [String: [Int]] = [:]
            if let data = try? Data(contentsOf: scriptletsURL),
               let decoded = try? JSONDecoder().decode([WebKitRuleCompiler.CompiledScriptletRule].self, from: data) {
                decodedScriptlets = decoded
                scriptletIndex = Self.buildScriptletHostIndex(from: decoded)
            }

            await MainActor.run {
                guard let self else { return }
                if let loadedSubs, !self.didMutateSubscriptionsBeforeWarmup {
                    self.subscriptions = loadedSubs
                    self.lastGlobalSyncDate = loadedSubs.compactMap(\.lastSyncedAt).max()
                }
                if let decodedScriptlets, self.compiledScriptletRules.isEmpty {
                    self.compiledScriptletRules = decodedScriptlets
                    self.scriptletIndexByHost = scriptletIndex
                    self.perHostScriptletCache.removeAll(keepingCapacity: true)
                    self.activeRuleCount = max(self.activeRuleCount, decodedScriptlets.count)
                }
            }
        }
    }

    public func purgeMemoryCache() {
        perHostScriptletCache.removeAll(keepingCapacity: false)
    }

    public var hasEnabledAntiAdblockSubscription: Bool {
        subscriptions.contains { $0.isEnabled && $0.category == .antiAdblock }
    }

    // Forwarding helpers preserving unit-test API surface
    nonisolated public static func parseDNRJSONToBuckets(_ jsonData: Data, maxRules: Int = 14_000) -> CompiledRuleBuckets {
        WebKitRuleCompiler.parseDNRJSONToBuckets(jsonData, maxRules: maxRules)
    }

    nonisolated public static func parseABPFilterTextToBuckets(_ text: String, maxRules: Int = 24_000) -> CompiledRuleBuckets {
        WebKitRuleCompiler.parseABPFilterTextToBuckets(text, maxRules: maxRules)
    }

    // MARK: - Per-Site Content Shield Bypass

    nonisolated private static func normalizeBypassHostValue(_ rawHost: String?) -> String? {
        guard let rawHost else { return nil }
        let normalized = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }

    public func normalizeBypassHost(_ rawHost: String?) -> String? {
        Self.normalizeBypassHostValue(rawHost)
    }

    public func isHostBypassed(_ rawHost: String?) -> Bool {
        guard let normalized = normalizeBypassHost(rawHost) else { return false }
        return bypassedHosts.contains(normalized)
    }

    public func effectiveShieldEnabled(globalEnabled: Bool, forHost rawHost: String?) -> Bool {
        globalEnabled && !isHostBypassed(rawHost)
    }

    public func setHostBypassed(_ bypassed: Bool, for rawHost: String?) async {
        guard let normalized = normalizeBypassHost(rawHost) else { return }
        let changed: Bool
        if bypassed {
            changed = bypassedHosts.insert(normalized).inserted
        } else {
            changed = bypassedHosts.remove(normalized) != nil
        }
        if changed {
            persistBypassedHosts()
        }
        await reapplyToAttachedControllers(matchingHost: normalized)
    }

    private func persistBypassedHosts() {
        LiveContainerEnvironment.sharedDefaults.set(
            bypassedHosts.sorted(),
            forKey: Self.bypassedHostsKey + stateDefaultsNamespace
        )
    }

    /// Clears legacy global bypassed hosts from memory once `BrowserSQLiteStore` migrates them
    /// into Default Profile's `site_rules` so secondary profiles stay strictly isolated.
    public func clearLegacyBypassedHosts() {
        guard stateDefaultsNamespace.isEmpty else { return }
        bypassedHosts.removeAll(keepingCapacity: false)
    }

    // MARK: - WebKit Attachment & Host-Scoped Script Injection

    private func normalizeScriptletHost(_ rawHost: String?) -> String? {
        guard let rawHost else { return nil }
        let normalized = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }

    private func hasScriptletIndexHit(forNormalizedHost normalized: String) -> Bool {
        if scriptletIndexByHost[normalized] != nil {
            return true
        }
        var dotIdx = normalized.firstIndex(of: ".")
        while let dot = dotIdx {
            let nextStart = normalized.index(after: dot)
            let remainder = normalized[nextStart...]
            guard remainder.contains(".") else { break }
            if scriptletIndexByHost[String(remainder)] != nil {
                return true
            }
            dotIdx = remainder.firstIndex(of: ".")
        }
        return false
    }

    /// O(1) lookup returning a deterministic cache token (`""` on ~95% of websites with zero matching scriptlets)
    /// so `CleanroomWebKitSession` skips redundant `removeAllUserScripts()` across routine cross-site navigations.
    public func scriptletCacheKey(forHost rawHost: String?) -> String {
        guard !scriptletIndexByHost.isEmpty,
              let normalized = normalizeScriptletHost(rawHost),
              hasScriptletIndexHit(forNormalizedHost: normalized) else {
            return ""
        }
        guard let source = scriptletSource(forHost: normalized), !source.isEmpty else {
            return ""
        }
        return normalized
    }

    /// Prunes extra third-party subframe scriptlets when navigating to a new main-frame host
    /// without tearing down base `WKUserScript`s when the base script signature is unchanged.
    public func pruneSubframeScriptletsIfMainHostChanged(
        to rawMainHost: String?,
        on controller: WKUserContentController
    ) {
        let normalizedMain = normalizeScriptletHost(rawMainHost)
        guard let tracker = injectedSubframeHostsByController.object(forKey: controller) else { return }
        guard tracker.currentMainHost != normalizedMain else { return }
        tracker.currentMainHost = normalizedMain
        guard !tracker.subframeScripts.isEmpty else { return }
        controller.removeAllUserScripts()
        for base in tracker.baseScripts {
            controller.addUserScript(base)
        }
        tracker.subframeScripts.removeAll(keepingCapacity: true)
        tracker.injectedSources.removeAll(keepingCapacity: true)
        tracker.injectedHosts.removeAll(keepingCapacity: true)
        if let normalizedMain {
            tracker.injectedHosts.insert(normalizedMain)
        }
    }

    /// Builds or retrieves the cached minimal scriptlet runtime for a single host (~2–6 KB instead of 398 KB).
    /// Returns `nil` when zero scriptlet rules match the host (`0 KB` injected on ~95% of websites).
    public func scriptletSource(forHost rawHost: String?) -> String? {
        guard !scriptletIndexByHost.isEmpty,
              let normalized = normalizeScriptletHost(rawHost) else {
            return nil
        }

        if let cached = perHostScriptletCache[normalized] {
            return cached.isEmpty ? nil : cached
        }

        var matched: [WebKitRuleCompiler.CompiledScriptletRule] = []
        var suffix = normalized
        while !suffix.isEmpty {
            if let bucket = scriptletIndexByHost[suffix] {
                for ruleIndex in bucket where ruleIndex < compiledScriptletRules.count {
                    let rule = compiledScriptletRules[ruleIndex]
                    let excluded = rule.excludedDomains.contains { ex in
                        normalized == ex || normalized.hasSuffix(".\(ex)")
                    }
                    if !excluded {
                        matched.append(rule)
                    }
                }
            }
            guard let dot = suffix.firstIndex(of: ".") else { break }
            suffix = String(suffix[suffix.index(after: dot)...])
        }

        if perHostScriptletCache.count >= 128 {
            perHostScriptletCache.removeAll(keepingCapacity: true)
        }
        guard !matched.isEmpty else {
            perHostScriptletCache[normalized] = ""
            return nil
        }

        let built = BrowserInjectedScripts.buildScriptletRuntimeScript(rules: matched)
        perHostScriptletCache[normalized] = built
        return built.isEmpty ? nil : built
    }

    /// Lazily appends host-scoped uBO/AdGuard scriptlets for a third-party iframe host on `controller`
    /// without clearing existing user scripts. Performs an O(1) index check, deduplicates by both host and
    /// canonical scriptlet source, and prunes stale subframe scripts on main-host changes or when capped.
    @discardableResult
    public func ensureSubframeScriptlets(
        forHost subframeHost: String?,
        on controller: WKUserContentController,
        shieldEnabled: Bool,
        mainHost: String?
    ) -> Bool {
        let trustCallerShield = attachedControllers.first(where: { $0.controller === controller })?.profileID != nil
        guard trustCallerShield ? shieldEnabled : effectiveShieldEnabled(globalEnabled: shieldEnabled, forHost: mainHost) else {
            return false
        }
        guard !scriptletIndexByHost.isEmpty,
              let normalizedSubframe = normalizeScriptletHost(subframeHost) else {
            return false
        }
        let normalizedMain = normalizeScriptletHost(mainHost)

        if let tracker = injectedSubframeHostsByController.object(forKey: controller) {
            if let prevMain = tracker.currentMainHost,
               let nextMain = normalizedMain,
               prevMain != nextMain {
                if !tracker.subframeScripts.isEmpty {
                    controller.removeAllUserScripts()
                    for base in tracker.baseScripts {
                        controller.addUserScript(base)
                    }
                    tracker.subframeScripts.removeAll(keepingCapacity: true)
                    tracker.injectedSources.removeAll(keepingCapacity: true)
                    tracker.injectedHosts.removeAll(keepingCapacity: true)
                    tracker.injectedHosts.insert(nextMain)
                }
                tracker.currentMainHost = nextMain
            } else if tracker.currentMainHost == nil, let nextMain = normalizedMain {
                tracker.currentMainHost = nextMain
            }

            if tracker.injectedHosts.contains(normalizedSubframe) {
                return false
            }
        }

        guard hasScriptletIndexHit(forNormalizedHost: normalizedSubframe) else {
            return false
        }
        guard let source = scriptletSource(forHost: normalizedSubframe) else {
            return false
        }

        let tracker: SubframeHostTracker
        if let existing = injectedSubframeHostsByController.object(forKey: controller) {
            tracker = existing
        } else {
            tracker = SubframeHostTracker()
            tracker.currentMainHost = normalizedMain
            tracker.baseScripts = controller.userScripts
            injectedSubframeHostsByController.setObject(tracker, forKey: controller)
        }

        if tracker.injectedSources.contains(source) {
            tracker.injectedHosts.insert(normalizedSubframe)
            return false
        }

        if tracker.subframeScripts.count >= Self.maxSubframeScriptsPerController {
            tracker.subframeScripts.removeFirst(tracker.subframeScripts.count - (Self.maxSubframeScriptsPerController - 1))
            controller.removeAllUserScripts()
            for base in tracker.baseScripts {
                controller.addUserScript(base)
            }
            tracker.injectedHosts.removeAll(keepingCapacity: true)
            if let currentMain = tracker.currentMainHost {
                tracker.injectedHosts.insert(currentMain)
            }
            tracker.injectedSources.removeAll(keepingCapacity: true)
            for item in tracker.subframeScripts {
                controller.addUserScript(item.script)
                tracker.injectedHosts.insert(item.host)
                tracker.injectedSources.insert(item.source)
            }
        }

        let script = WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(script)
        tracker.injectedHosts.insert(normalizedSubframe)
        tracker.injectedSources.insert(source)
        tracker.subframeScripts.append((normalizedSubframe, source, script))
        return true
    }

    nonisolated private static func buildScriptletHostIndex(from rules: [WebKitRuleCompiler.CompiledScriptletRule]) -> [String: [Int]] {
        var idx: [String: [Int]] = [:]
        idx.reserveCapacity(min(rules.count, 2048))
        for (ruleIndex, rule) in rules.enumerated() {
            for domain in rule.positiveDomains {
                idx[domain.lowercased(), default: []].append(ruleIndex)
            }
        }
        return idx
    }

    public func installUserScripts(
        on controller: WKUserContentController,
        shieldEnabled: Bool,
        forHost host: String? = nil,
        includeFingerprintShield: Bool = true,
        fingerprintSeedOverride: String? = nil,
        maskFoldableScreenOverride: Bool? = nil,
        userAgentProfileOverride: BrowserUserAgentProfile? = nil,
        autoWebPageDarkModeOverride: Bool? = nil
    ) {
        let entryIdx = attachedControllers.firstIndex(where: { $0.controller === controller })
        let entry = entryIdx.map { attachedControllers[$0] }

        let effectiveUAProfile = userAgentProfileOverride
            ?? entry?.userAgentProfileProvider()
            ?? entry?.lastUserAgentProfile
            ?? BrowserUserAgentProfile.persistedCurrent
        let effectiveAutoDark = autoWebPageDarkModeOverride
            ?? entry?.autoWebPageDarkModeProvider()
            ?? entry?.lastAutoWebPageDarkMode
            ?? CleanroomBrowserStore.persistedAutoWebPageDarkMode

        if let entryIdx {
            if let userAgentProfileOverride {
                attachedControllers[entryIdx].lastUserAgentProfile = userAgentProfileOverride
            }
            if let autoWebPageDarkModeOverride {
                attachedControllers[entryIdx].lastAutoWebPageDarkMode = autoWebPageDarkModeOverride
            }
            if let maskFoldableScreenOverride {
                attachedControllers[entryIdx].lastMaskFoldableScreenOverride = maskFoldableScreenOverride
            }
            if let fingerprintSeedOverride {
                attachedControllers[entryIdx].storedExplicitSeedOverride =
                    (attachedControllers[entryIdx].profileID != nil) ? nil : fingerprintSeedOverride
            }
        }

        controller.removeAllUserScripts()
        injectedSubframeHostsByController.removeObject(forKey: controller)

        // 0-Frame Pre-Execution: install stealth Seeded Farbling FIRST before any page JS or other scripts run.
        // Desktop macOS Navigator identity is folded directly into FingerprintShieldEngine's WeakMap-cloaked realm.
        var installedCloakedIdentity = false
        if includeFingerprintShield {
            let shieldEngine = FingerprintShieldEngine.shared
            let resolvedSeed = fingerprintSeedOverride
                ?? entry?.fingerprintSeedProvider()
                ?? entry?.storedExplicitSeedOverride
                ?? (shieldEngine.isEnabled ? shieldEngine.standardSeed : nil)
            if let resolvedSeed {
                let maskScreen = maskFoldableScreenOverride
                    ?? entry?.lastMaskFoldableScreenOverride
                    ?? shieldEngine.maskFoldableScreen
                controller.addUserScript(
                    FingerprintShieldEngine.makeUserScript(
                        seed: resolvedSeed,
                        maskFoldableScreen: maskScreen,
                        profile: effectiveUAProfile
                    )
                )
                installedCloakedIdentity = true
            }
        }
        if !installedCloakedIdentity && effectiveUAProfile == .macosSafari {
            controller.addUserScript(FingerprintShieldEngine.makeMacOSNavigatorIdentityUserScript())
        }

        // Gate Dark Reader detector strictly when Auto Dark is enabled (0 bytes when off), main-frame only.
        if effectiveAutoDark,
           let darkDetectorSource = DarkReaderEngine.shared.makeDetectorUserScriptSource(forHost: host, enabled: true) {
            controller.addUserScript(
                WKUserScript(
                    source: darkDetectorSource,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        var installedHostScriptletSource: String?
        let trustCallerShield = attachedControllers.first(where: { $0.controller === controller })?.profileID != nil
        let effectiveShield = trustCallerShield ? shieldEnabled : effectiveShieldEnabled(globalEnabled: shieldEnabled, forHost: host)
        if effectiveShield {
            if hasEnabledAntiAdblockSubscription {
                controller.addUserScript(
                    WKUserScript(
                        source: BrowserInjectedScripts.genericAntiAdblockDefuser,
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: true
                    )
                )
            }
            if let hostScriptlet = scriptletSource(forHost: host) {
                installedHostScriptletSource = hostScriptlet
                controller.addUserScript(
                    WKUserScript(
                        source: hostScriptlet,
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: false
                    )
                )
            }
        }

        controller.addUserScript(
            WKUserScript(
                source: BrowserInjectedScripts.allFramesStreamInterceptor,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        controller.addUserScript(
            WKUserScript(
                source: BrowserInjectedScripts.topFrameMediaDOMScanner,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let tracker = SubframeHostTracker()
        tracker.currentMainHost = normalizeScriptletHost(host)
        tracker.baseScripts = controller.userScripts
        if let normalizedHost = tracker.currentMainHost, let installedHostScriptletSource {
            tracker.injectedHosts.insert(normalizedHost)
            tracker.injectedSources.insert(installedHostScriptletSource)
        }
        injectedSubframeHostsByController.setObject(tracker, forKey: controller)
    }

    /// Registers a `WKUserContentController` synchronously so future filter updates propagate to it
    /// without forcing a redundant `removeAllUserScripts()` / `removeAllContentRuleLists()` cycle at tab boot.
    public func registerController(
        _ controller: WKUserContentController,
        profileID: String? = nil,
        currentHostProvider: @escaping @MainActor () -> String? = { nil },
        isEnabledProvider: @escaping @MainActor () -> Bool,
        fingerprintSeedProvider: @escaping @MainActor () -> String? = { nil },
        userAgentProfileProvider: @escaping @MainActor () -> BrowserUserAgentProfile? = { nil },
        autoWebPageDarkModeProvider: @escaping @MainActor () -> Bool? = { nil }
    ) {
        let initialSeed = fingerprintSeedProvider()
        let initialUA = userAgentProfileProvider()
        let initialAutoDark = autoWebPageDarkModeProvider()
        attachedControllers.removeAll { $0.controller == nil || $0.controller === controller }
        attachedControllers.append(
            AttachedControllerEntry(
                controller: controller,
                profileID: profileID,
                isEnabledProvider: isEnabledProvider,
                currentHostProvider: currentHostProvider,
                fingerprintSeedProvider: fingerprintSeedProvider,
                userAgentProfileProvider: userAgentProfileProvider,
                autoWebPageDarkModeProvider: autoWebPageDarkModeProvider,
                storedExplicitSeedOverride: (profileID != nil || initialSeed == FingerprintShieldEngine.shared.standardSeed) ? nil : initialSeed,
                lastMaskFoldableScreenOverride: nil,
                lastUserAgentProfile: initialUA,
                lastAutoWebPageDarkMode: initialAutoDark
            )
        )
    }

    public func registerAndApply(
        to controller: WKUserContentController,
        profileID: String? = nil,
        currentHostProvider: @escaping @MainActor () -> String? = { nil },
        isEnabledProvider: @escaping @MainActor () -> Bool,
        fingerprintSeedProvider: @escaping @MainActor () -> String? = { nil },
        userAgentProfileProvider: @escaping @MainActor () -> BrowserUserAgentProfile? = { nil },
        autoWebPageDarkModeProvider: @escaping @MainActor () -> Bool? = { nil }
    ) async {
        registerController(
            controller,
            profileID: profileID,
            currentHostProvider: currentHostProvider,
            isEnabledProvider: isEnabledProvider,
            fingerprintSeedProvider: fingerprintSeedProvider,
            userAgentProfileProvider: userAgentProfileProvider,
            autoWebPageDarkModeProvider: autoWebPageDarkModeProvider
        )
        let initialSeed = fingerprintSeedProvider()
        let initialUA = userAgentProfileProvider()
        let initialAutoDark = autoWebPageDarkModeProvider()
        await apply(
            enabled: isEnabledProvider(),
            to: controller,
            forHost: currentHostProvider(),
            fingerprintSeedOverride: initialSeed,
            userAgentProfileOverride: initialUA,
            autoWebPageDarkModeOverride: initialAutoDark
        )
    }

    public func apply(
        enabled: Bool,
        to controller: WKUserContentController,
        forHost host: String? = nil,
        includeFingerprintShield: Bool = true,
        fingerprintSeedOverride: String? = nil,
        maskFoldableScreenOverride: Bool? = nil,
        userAgentProfileOverride: BrowserUserAgentProfile? = nil,
        autoWebPageDarkModeOverride: Bool? = nil
    ) async {
        let entryIndex = attachedControllers.firstIndex(where: { $0.controller === controller })
        let entry = entryIndex.map { attachedControllers[$0] }
        let resolvedSeed = fingerprintSeedOverride
            ?? entry?.fingerprintSeedProvider()
            ?? entry?.storedExplicitSeedOverride
        let resolvedUA = userAgentProfileOverride ?? entry?.userAgentProfileProvider() ?? entry?.lastUserAgentProfile
        let resolvedAutoDark = autoWebPageDarkModeOverride ?? entry?.autoWebPageDarkModeProvider() ?? entry?.lastAutoWebPageDarkMode
        let resolvedMask = maskFoldableScreenOverride ?? entry?.lastMaskFoldableScreenOverride
        let trustCallerShield = entry?.profileID != nil
        let effectiveEnabled = trustCallerShield ? enabled : effectiveShieldEnabled(globalEnabled: enabled, forHost: host)

        guard effectiveEnabled else {
            if entry?.lastAppliedRuleListEnabled != false {
                controller.removeAllContentRuleLists()
            }
            if let idx = attachedControllers.firstIndex(where: { $0.controller === controller }) {
                attachedControllers[idx].lastAppliedRuleListEnabled = false
                attachedControllers[idx].lastAppliedRuleListGeneration = compiledListsGeneration
            }
            installUserScripts(
                on: controller,
                shieldEnabled: false,
                forHost: host,
                includeFingerprintShield: includeFingerprintShield,
                fingerprintSeedOverride: resolvedSeed,
                maskFoldableScreenOverride: resolvedMask,
                userAgentProfileOverride: resolvedUA,
                autoWebPageDarkModeOverride: resolvedAutoDark
            )
            return
        }

        let lists = await ensureCompiledLists()
        let stillEnabled = trustCallerShield ? enabled : effectiveShieldEnabled(globalEnabled: enabled, forHost: host)
        guard stillEnabled else {
            controller.removeAllContentRuleLists()
            if let idx = attachedControllers.firstIndex(where: { $0.controller === controller }) {
                attachedControllers[idx].lastAppliedRuleListEnabled = false
                attachedControllers[idx].lastAppliedRuleListGeneration = compiledListsGeneration
            }
            installUserScripts(
                on: controller,
                shieldEnabled: false,
                forHost: host,
                includeFingerprintShield: includeFingerprintShield,
                fingerprintSeedOverride: resolvedSeed,
                maskFoldableScreenOverride: resolvedMask,
                userAgentProfileOverride: resolvedUA,
                autoWebPageDarkModeOverride: resolvedAutoDark
            )
            return
        }
        installUserScripts(
            on: controller,
            shieldEnabled: true,
            forHost: host,
            includeFingerprintShield: includeFingerprintShield,
            fingerprintSeedOverride: resolvedSeed,
            maskFoldableScreenOverride: resolvedMask,
            userAgentProfileOverride: resolvedUA,
            autoWebPageDarkModeOverride: resolvedAutoDark
        )
        let currentIndex = attachedControllers.firstIndex(where: { $0.controller === controller })
        let currentEntry = currentIndex.map { attachedControllers[$0] }
        let needsRuleListIPC = currentEntry == nil
            || currentEntry?.lastAppliedRuleListEnabled != true
            || currentEntry?.lastAppliedRuleListGeneration != compiledListsGeneration
        if needsRuleListIPC {
            controller.removeAllContentRuleLists()
            for list in lists {
                controller.add(list)
            }
            if let idx = currentIndex {
                attachedControllers[idx].lastAppliedRuleListEnabled = true
                attachedControllers[idx].lastAppliedRuleListGeneration = compiledListsGeneration
            }
        }
    }

    public func reapplyToAttachedControllers(
        matchingHost normalizedTargetHost: String? = nil,
        matchingProfileID targetProfileID: String? = nil
    ) async {
        attachedControllers.removeAll { $0.controller == nil }
        let entries = attachedControllers
        for entry in entries {
            guard let controller = entry.controller else { continue }
            if let targetProfileID, entry.profileID != targetProfileID {
                continue
            }
            let host = entry.currentHostProvider()
            if let normalizedTargetHost, normalizeBypassHost(host) != normalizedTargetHost {
                continue
            }
            let seed = entry.fingerprintSeedProvider() ?? entry.storedExplicitSeedOverride
            let ua = entry.userAgentProfileProvider() ?? entry.lastUserAgentProfile
            let autoDark = entry.autoWebPageDarkModeProvider() ?? entry.lastAutoWebPageDarkMode
            await apply(
                enabled: entry.isEnabledProvider(),
                to: controller,
                forHost: host,
                fingerprintSeedOverride: seed,
                maskFoldableScreenOverride: entry.lastMaskFoldableScreenOverride,
                userAgentProfileOverride: ua,
                autoWebPageDarkModeOverride: autoDark
            )
        }
    }

    private func ensureWarmedUp() async {
        if let task = warmupTask {
            await task.value
            warmupTask = nil
        }
    }

    /// Kicks off non-blocking startup pre-warming of already-compiled `WKContentRuleListStore` bytecode
    /// and background staleness checks so the first page load starts DNS/TLS with zero blocker wait.
    public func prewarmInBackground() {
        guard !didStartPrewarm else { return }
        didStartPrewarm = true
        Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.fastRestoreCachedListsIfAvailable()
            _ = await self.ensureCompiledLists()
            if !self.compiledLists.isEmpty {
                await self.propagateUpdatedListsToControllers()
            }
        }
    }

    private func loadCompleteRuleLists(
        ids: [String],
        from store: WKContentRuleListStore
    ) async -> [WKContentRuleList]? {
        guard !ids.isEmpty else { return nil }
        var restored: [WKContentRuleList] = []
        restored.reserveCapacity(ids.count)
        for id in ids {
            guard let list = try? await store.contentRuleList(forIdentifier: id) else {
                return nil
            }
            restored.append(list)
        }
        return restored
    }

    /// Fast-path bytecode restore (~5–15 ms) that ONLY loads already-compiled chunks from
    /// `WKContentRuleListStore.default()` without ever blocking a navigation on multi-second
    /// rule recompilation or 12-file disk staleness probes. If bytecode is missing or stale,
    /// full compilation runs asynchronously in the background and attaches via `propagateUpdatedListsToControllers()`.
    public func fastRestoreCachedListsIfAvailable() async -> [WKContentRuleList] {
        if !compiledLists.isEmpty {
            return compiledLists
        }
        if let existing = inFlightFastRestoreTask {
            return await existing.value
        }

        let task = Task<[WKContentRuleList], Never> { @MainActor [weak self] in
            guard let self else { return [] }
            defer { self.inFlightFastRestoreTask = nil }
            let savedChunkIDs = self.persistedChunkIdentifiers()
            let savedCompilerVersion = UserDefaults.standard.string(forKey: Self.compiledCompilerVersionKey + self.stateDefaultsNamespace)
            if savedCompilerVersion == Self.compilerSchemaVersion,
               let store = WKContentRuleListStore.default(),
               let restored = await self.loadCompleteRuleLists(ids: savedChunkIDs, from: store) {
                if self.compiledLists.isEmpty {
                    self.compiledLists = restored
                    self.compiledListsGeneration &+= 1
                    let savedTotal = UserDefaults.standard.integer(forKey: Self.compiledRuleTotalKey + self.stateDefaultsNamespace)
                    self.activeRuleCount = max(savedTotal, self.compiledScriptletRules.count)
                }
                // Verify signature freshness & trigger background sync without stalling navigation.
                Task(priority: .utility) { @MainActor [weak self] in
                    guard let self else { return }
                    await self.ensureWarmedUp()
                    let currentSig = self.computeStateSignature()
                    let savedSig = UserDefaults.standard.string(forKey: Self.compiledSignatureKey + self.stateDefaultsNamespace)
                    if savedSig != currentSig {
                        await self.recompileFromCachedFiles()
                        await self.propagateUpdatedListsToControllers()
                    }
                    self.scheduleAutoRefreshIfStale()
                }
                return self.compiledLists
            }

            // Bytecode store missed (fresh install / post-update re-container): compile in background
            // instead of stalling the user's first navigation before DNS.
            Task(priority: .utility) { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.ensureCompiledLists()
                if !self.compiledLists.isEmpty {
                    await self.propagateUpdatedListsToControllers()
                }
            }
            return []
        }
        inFlightFastRestoreTask = task
        return await task.value
    }

    public func ensureCompiledLists() async -> [WKContentRuleList] {
        await ensureWarmedUp()
        if !compiledLists.isEmpty {
            if compiledScriptletRules.isEmpty {
                await reloadPersistedScriptletsFromDisk()
            }
            scheduleAutoRefreshIfStale()
            return compiledLists
        }
        if let existingTask = inFlightEnsureTask {
            return await existingTask.value
        }

        let task = Task<[WKContentRuleList], Never> { @MainActor in
            defer { self.inFlightEnsureTask = nil }
            let currentSig = self.computeStateSignature()
            let savedSig = UserDefaults.standard.string(forKey: Self.compiledSignatureKey + self.stateDefaultsNamespace)
            let savedChunkIDs = self.persistedChunkIdentifiers()

            let scriptletsURL = self.compiledScriptletsURL
            let enabledCacheURLs = self.subscriptions
                .filter(\.isEnabled)
                .map { ($0.lastSyncedAt != nil, self.cacheFileURL(for: $0.id)) }

            let diskProbe = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let hasScriptlets = fm.fileExists(atPath: scriptletsURL.path)
                var hasUnsynced = false
                var hasAnyCache = false
                for (hasSyncDate, url) in enabledCacheURLs {
                    let exists = fm.fileExists(atPath: url.path)
                    if exists { hasAnyCache = true }
                    if !hasSyncDate || !exists { hasUnsynced = true }
                }
                return (hasScriptlets, hasUnsynced, hasAnyCache)
            }.value

            let hasPersistedScriptletsFile = diskProbe.0
            let hasUnsyncedEnabledSeeds = diskProbe.1
            let hasAnyCacheOnDisk = diskProbe.2

            let savedCompilerVersion = UserDefaults.standard.string(forKey: Self.compiledCompilerVersionKey + self.stateDefaultsNamespace)
            if savedCompilerVersion == Self.compilerSchemaVersion,
               (savedSig == currentSig || hasUnsyncedEnabledSeeds),
               hasPersistedScriptletsFile,
               let store = WKContentRuleListStore.default(),
               let restored = await self.loadCompleteRuleLists(ids: savedChunkIDs, from: store) {
                self.compiledLists = restored
                self.compiledListsGeneration &+= 1
                if self.compiledScriptletRules.isEmpty {
                    await self.reloadPersistedScriptletsFromDisk()
                }
                let savedTotal = UserDefaults.standard.integer(forKey: Self.compiledRuleTotalKey + self.stateDefaultsNamespace)
                self.activeRuleCount = max(savedTotal, self.compiledScriptletRules.count)
                self.scheduleAutoRefreshIfStale()
                return restored
            }

            if hasAnyCacheOnDisk {
                await self.recompileFromCachedFiles()
            }

            self.scheduleAutoRefreshIfStale()
            return self.compiledLists
        }
        inFlightEnsureTask = task
        return await task.value
    }

    private func scheduleAutoRefreshIfStale() {
        guard !didBootstrap else { return }
        didBootstrap = true
        // Keep unit tests strictly air-gapped and deterministic: never trigger background
        // internet filter downloads or mid-suite WKContentRuleList mutations under XCTest.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        let now = Date()
        let checks: [(Bool, TimeInterval, URL)] = subscriptions.filter(\.isEnabled).map { sub in
            let elapsed = sub.lastSyncedAt.map { now.timeIntervalSince($0) } ?? .infinity
            return (sub.lastSyncedAt != nil, elapsed, cacheFileURL(for: sub.id))
        }
        let refreshThreshold = Self.refreshIntervalSeconds

        Task(priority: .utility) { [weak self] in
            let needsSync = await Task.detached(priority: .utility) {
                let fm = FileManager.default
                for (hasDate, elapsed, url) in checks {
                    if !hasDate {
                        return true
                    }
                    if elapsed >= refreshThreshold || !fm.fileExists(atPath: url.path) {
                        return true
                    }
                }
                return false
            }.value

            if needsSync {
                await self?.refreshAllSubscriptions(force: false)
            }
        }
    }

    // MARK: - Subscription Management & Live Sync

    public func refreshAllSubscriptions(force: Bool = true) async {
        await ensureWarmedUp()
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let snapshot = subscriptions
        var didAnyPayloadChange = false

        await withTaskGroup(of: (String, Data?, String?, String?, String?).self) { group in
            for sub in snapshot where sub.isEnabled {
                let cacheURL = cacheFileURL(for: sub.id)
                let session = self.urlSession
                group.addTask {
                    let cachedExists = FileManager.default.fileExists(atPath: cacheURL.path)
                    var req = URLRequest(url: sub.sourceURL)
                    req.setValue("Dysprosium/1.0 (iOS WebKit ContentRuleList)", forHTTPHeaderField: "User-Agent")
                    if !force && cachedExists {
                        if let etag = sub.etag {
                            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
                        }
                        if let lm = sub.lastModified {
                            req.setValue(lm, forHTTPHeaderField: "If-Modified-Since")
                        }
                    }

                    do {
                        let (data, resp) = try await session.data(for: req)
                        guard let http = resp as? HTTPURLResponse else {
                            return (sub.id, nil, nil, nil, L("Non-HTTP response"))
                        }
                        if http.statusCode == 304 {
                            return (sub.id, nil, sub.etag, sub.lastModified, nil)
                        }
                        guard (200...299).contains(http.statusCode), !data.isEmpty else {
                            return (sub.id, nil, nil, nil, L("HTTP \(http.statusCode)"))
                        }
                        let newETag = http.value(forHTTPHeaderField: "ETag")
                        let newLM = http.value(forHTTPHeaderField: "Last-Modified")
                        return (sub.id, data, newETag, newLM, nil)
                    } catch {
                        return (sub.id, nil, nil, nil, error.localizedDescription)
                    }
                }
            }

            var pendingWrites: [(URL, Data)] = []
            for await (subID, maybeData, newETag, newLM, errText) in group {
                guard let idx = subscriptions.firstIndex(where: { $0.id == subID }) else { continue }
                if let errText {
                    subscriptions[idx].lastError = errText
                } else {
                    subscriptions[idx].lastError = nil
                    subscriptions[idx].lastSyncedAt = Date()
                    if let newETag { subscriptions[idx].etag = newETag }
                    if let newLM { subscriptions[idx].lastModified = newLM }
                    if let data = maybeData {
                        pendingWrites.append((cacheFileURL(for: subID), data))
                        didAnyPayloadChange = true
                    }
                }
            }

            if !pendingWrites.isEmpty {
                await Task.detached(priority: .utility) {
                    for (url, data) in pendingWrites {
                        try? data.write(to: url, options: .atomic)
                    }
                }.value
            }
        }

        didMutateSubscriptionsBeforeWarmup = true
        lastGlobalSyncDate = subscriptions.compactMap(\.lastSyncedAt).max()
        await persistSubscriptionsAsync()

        let scriptletsPath = compiledScriptletsURL.path
        let hasScriptletsFile = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: scriptletsPath)
        }.value

        if didAnyPayloadChange
            || compiledLists.isEmpty
            || !hasScriptletsFile {
            await recompileFromCachedFiles()
            await propagateUpdatedListsToControllers()
        }
    }

    public func toggleSubscription(id: String) async {
        await ensureWarmedUp()
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        didMutateSubscriptionsBeforeWarmup = true
        subscriptions[idx].isEnabled.toggle()
        let nowEnabled = subscriptions[idx].isEnabled
        let cachePath = cacheFileURL(for: id).path
        let missingCache = await Task.detached(priority: .utility) {
            !FileManager.default.fileExists(atPath: cachePath)
        }.value
        await persistSubscriptionsAsync()

        if nowEnabled && missingCache {
            await refreshAllSubscriptions(force: false)
        } else {
            await recompileFromCachedFiles()
            await propagateUpdatedListsToControllers()
        }
    }

    public func addCustomSubscription(title: String, urlString: String, category: FilterSubscription.Category = .custom) async -> Bool {
        await ensureWarmedUp()
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http") else {
            return false
        }
        if subscriptions.contains(where: { $0.sourceURL == url }) {
            return false
        }

        didMutateSubscriptionsBeforeWarmup = true
        let format: FilterSubscription.Format = url.pathExtension.lowercased() == "json" ? .dnrJSON : .abpFilterList
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = cleanTitle.isEmpty ? (url.host() ?? L("Custom Filter")) : cleanTitle
        let newSub = FilterSubscription(
            id: "custom-\(UUID().uuidString.prefix(8).lowercased())",
            title: effectiveTitle,
            subtitle: url.absoluteString,
            sourceURL: url,
            category: category,
            format: format,
            maxRuleBudget: 15_000,
            isEnabled: true,
            isBuiltInSeed: false
        )
        subscriptions.append(newSub)
        await persistSubscriptionsAsync()
        await refreshAllSubscriptions(force: false)
        return true
    }

    public func removeSubscription(id: String) async {
        await ensureWarmedUp()
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        didMutateSubscriptionsBeforeWarmup = true
        subscriptions.remove(at: idx)
        let cacheURL = cacheFileURL(for: id)
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: cacheURL)
        }.value
        await persistSubscriptionsAsync()
        await recompileFromCachedFiles()
        await propagateUpdatedListsToControllers()
    }

    // MARK: - Background Parsing + WebKit Bytecode Compilation

    private struct SubscriptionParseInput: Sendable {
        let id: String
        let isEnabled: Bool
        let fileURL: URL
        let format: FilterSubscription.Format
        let budget: Int
    }

    private struct BackgroundParseResult: Sendable {
        let countsByID: [String: Int]
        let chunkJSONPayloads: [String]
        let totalDFARules: Int
        let scriptletRules: [WebKitRuleCompiler.CompiledScriptletRule]
        let scriptletHostIndex: [String: [Int]]
    }

    private func recompileFromCachedFiles() async {
        let inputs: [SubscriptionParseInput] = subscriptions.map { sub in
            SubscriptionParseInput(
                id: sub.id,
                isEnabled: sub.isEnabled,
                fileURL: cacheFileURL(for: sub.id),
                format: sub.format,
                budget: sub.maxRuleBudget
            )
        }
        let maxPerChunk = Self.maxRulesPerChunk
        let maxGlobalCosmetics = Self.maxGlobalCosmeticSelectors
        let maxAllows = Self.maxGlobalAllowRules
        let maxScriptlets = Self.maxGlobalScriptletRules
        let scriptletsOutputURL = self.compiledScriptletsURL

        // Parse & serialize 58k+ rules + scriptlets off `@MainActor` so scrolling and animations never drop a frame!
        let parsed: BackgroundParseResult = await Task.detached(priority: .userInitiated) {
            var anchoredNetworkBlocks: [[String: Any]] = []
            var wildcardNetworkBlocks: [[String: Any]] = []
            var cosmeticRules: [[String: Any]] = []
            var seenNetworkRuleKeys = Set<String>()
            var seenAllowRuleKeys = Set<String>()
            var seenGlobalCosmeticSelectors = Set<String>()
            var uniqueGlobalCosmeticSelectors: [String] = []
            var combinedAllows: [[String: Any]] = []
            var rawScriptlets: [WebKitRuleCompiler.CompiledScriptletRule] = []
            var rawScriptletExceptions: [WebKitRuleCompiler.ScriptletExceptionRule] = []
            var counts: [String: Int] = [:]

            func networkRuleDedupKey(_ rule: [String: Any]) -> String? {
                guard let trigger = rule["trigger"] as? [String: Any],
                      let urlFilter = trigger["url-filter"] as? String else { return nil }
                let actionType = (rule["action"] as? [String: Any])?["type"] as? String ?? ""
                let load = (trigger["load-type"] as? [String])?.joined(separator: ",") ?? ""
                let res = (trigger["resource-type"] as? [String])?.sorted().joined(separator: ",") ?? ""
                let ifD = (trigger["if-domain"] as? [String])?.joined(separator: ",") ?? ""
                let unlessD = (trigger["unless-domain"] as? [String])?.joined(separator: ",") ?? ""
                let cs = (trigger["url-filter-is-case-sensitive"] as? Bool) == true ? "1" : "0"
                return "\(actionType)|\(cs)|\(load)|\(res)|\(ifD)|\(unlessD)|\(urlFilter)"
            }

            for input in inputs {
                guard input.isEnabled,
                      let rawData = try? Data(contentsOf: input.fileURL),
                      !rawData.isEmpty else {
                    counts[input.id] = 0
                    continue
                }

                let buckets: WebKitRuleCompiler.CompiledRuleBuckets
                switch input.format {
                case .dnrJSON:
                    buckets = WebKitRuleCompiler.parseDNRJSONToBuckets(rawData, maxRules: input.budget)
                case .abpFilterList:
                    let text = String(data: rawData, encoding: .utf8) ?? String(data: rawData, encoding: .isoLatin1) ?? ""
                    buckets = WebKitRuleCompiler.parseABPFilterTextToBuckets(text, maxRules: input.budget)
                }

                counts[input.id] = buckets.totalCount
                for rule in buckets.blockAndCosmeticRules {
                    if let action = rule["action"] as? [String: Any],
                       (action["type"] as? String) == "css-display-none" {
                        if let selectorCSV = action["selector"] as? String,
                           let trigger = rule["trigger"] as? [String: Any],
                           trigger["if-domain"] == nil,
                           trigger["unless-domain"] == nil {
                            if uniqueGlobalCosmeticSelectors.count < maxGlobalCosmetics {
                                for rawSel in selectorCSV.split(separator: ",") {
                                    let sel = rawSel.trimmingCharacters(in: .whitespaces)
                                    guard !sel.isEmpty else { continue }
                                    if seenGlobalCosmeticSelectors.insert(sel).inserted {
                                        uniqueGlobalCosmeticSelectors.append(sel)
                                        if uniqueGlobalCosmeticSelectors.count >= maxGlobalCosmetics { break }
                                    }
                                }
                            }
                        } else {
                            cosmeticRules.append(rule)
                        }
                        continue
                    }

                    if let key = networkRuleDedupKey(rule), !seenNetworkRuleKeys.insert(key).inserted {
                        continue
                    }
                    let urlFilter = ((rule["trigger"] as? [String: Any])?["url-filter"] as? String) ?? ""
                    // Partition anchored prefix-trie domain rules away from unanchored / `.*` wildcard rules
                    // so WebKit's CombinedURLFilters compiles lean ~2–6 MB DFAs instead of 100+ MB cross-product DFAs.
                    if urlFilter.hasPrefix("^") && !urlFilter.contains(".*") {
                        anchoredNetworkBlocks.append(rule)
                    } else {
                        wildcardNetworkBlocks.append(rule)
                    }
                }
                for allowRule in buckets.allowRules {
                    if let key = networkRuleDedupKey(allowRule), !seenAllowRuleKeys.insert(key).inserted {
                        continue
                    }
                    combinedAllows.append(allowRule)
                }
                rawScriptlets.append(contentsOf: buckets.scriptletRules)
                rawScriptletExceptions.append(contentsOf: buckets.scriptletExceptions)
            }

            // Re-pack deduplicated global cosmetic selectors into compact 20-selector rules.
            var gIdx = 0
            while gIdx < uniqueGlobalCosmeticSelectors.count {
                let gEnd = min(gIdx + 20, uniqueGlobalCosmeticSelectors.count)
                cosmeticRules.append([
                    "trigger": ["url-filter": "^https?://"],
                    "action": [
                        "type": "css-display-none",
                        "selector": uniqueGlobalCosmeticSelectors[gIdx..<gEnd].joined(separator: ", ")
                    ]
                ])
                gIdx = gEnd
            }

            let finalScriptlets = WebKitRuleCompiler.resolveScriptletRules(
                rawScriptlets,
                exceptions: rawScriptletExceptions,
                maxRules: maxScriptlets
            )
            let hostIndex = Self.buildScriptletHostIndex(from: finalScriptlets)
            if let encodedScriptlets = try? JSONEncoder().encode(finalScriptlets) {
                try? encodedScriptlets.write(to: scriptletsOutputURL, options: .atomic)
            }

            let globalAllowTail = Array(combinedAllows.prefix(maxAllows))
            let totalNetworkBlocks = anchoredNetworkBlocks.count + wildcardNetworkBlocks.count
            let totalDFARules = totalNetworkBlocks + cosmeticRules.count + globalAllowTail.count
            guard totalDFARules > 0 else {
                return BackgroundParseResult(
                    countsByID: counts,
                    chunkJSONPayloads: [],
                    totalDFARules: 0,
                    scriptletRules: finalScriptlets,
                    scriptletHostIndex: hostIndex
                )
            }

            // WebKit `ignore-previous-rules` only cancels rules inside the SAME `WKContentRuleList`.
            // Keep all potentially intersecting network allow rules in every network block chunk so
            // unanchored/wildcard exceptions (`@@/player-init*`) still unblock anchored rules, and
            // preserve document-level exceptions inside cosmetic chunks so `$document`/`$elemhide`
            // whitelists still suppress `css-display-none`.
            let cosmeticAllowTail = globalAllowTail.filter { rule in
                guard let trigger = rule["trigger"] as? [String: Any] else { return false }
                if let resTypes = trigger["resource-type"] as? [String], !resTypes.isEmpty {
                    return resTypes.contains("document")
                }
                return true
            }

            var payloads: [String] = []

            func appendChunked(_ rules: [[String: Any]], allowTail: [[String: Any]]) {
                guard !rules.isEmpty else { return }
                let stride = max(4_000, maxPerChunk - allowTail.count)
                var cursor = 0
                while cursor < rules.count {
                    let end = min(cursor + stride, rules.count)
                    let chunkRules = allowTail.isEmpty ? Array(rules[cursor..<end]) : (Array(rules[cursor..<end]) + allowTail)
                    if let encoded = Self.encodeJSONString(chunkRules) {
                        payloads.append(encoded)
                    }
                    cursor = end
                }
            }

            appendChunked(anchoredNetworkBlocks, allowTail: globalAllowTail)
            appendChunked(wildcardNetworkBlocks, allowTail: globalAllowTail)
            appendChunked(cosmeticRules, allowTail: cosmeticAllowTail)

            if payloads.isEmpty && !globalAllowTail.isEmpty {
                if let encoded = Self.encodeJSONString(globalAllowTail) {
                    payloads.append(encoded)
                }
            }

            return BackgroundParseResult(
                countsByID: counts,
                chunkJSONPayloads: payloads,
                totalDFARules: totalDFARules,
                scriptletRules: finalScriptlets,
                scriptletHostIndex: hostIndex
            )
        }.value

        self.compiledScriptletRules = parsed.scriptletRules
        self.scriptletIndexByHost = parsed.scriptletHostIndex
        self.perHostScriptletCache.removeAll(keepingCapacity: true)

        for idx in subscriptions.indices {
            subscriptions[idx].compiledRuleCount = parsed.countsByID[subscriptions[idx].id] ?? 0
        }
        await persistSubscriptionsAsync()

        let sigKey = Self.compiledSignatureKey + stateDefaultsNamespace
        let verKey = Self.compiledCompilerVersionKey + stateDefaultsNamespace
        let chunkKey = Self.compiledChunkCountKey + stateDefaultsNamespace
        let chunkIDsKey = Self.compiledChunkIDsKey + stateDefaultsNamespace
        let totalKey = Self.compiledRuleTotalKey + stateDefaultsNamespace
        let previousChunkIDs = Set(persistedChunkIdentifiers())

        guard let store = WKContentRuleListStore.default() else {
            self.activeRuleCount = parsed.scriptletRules.count
            return
        }

        if parsed.chunkJSONPayloads.isEmpty {
            for staleID in previousChunkIDs {
                try? await store.removeContentRuleList(forIdentifier: staleID)
            }
            self.compiledLists = []
            self.compiledListsGeneration &+= 1
            self.activeRuleCount = parsed.scriptletRules.count
            UserDefaults.standard.set(computeStateSignature(), forKey: sigKey)
            UserDefaults.standard.set(Self.compilerSchemaVersion, forKey: verKey)
            UserDefaults.standard.set(0, forKey: chunkKey)
            UserDefaults.standard.set([String](), forKey: chunkIDsKey)
            UserDefaults.standard.set(self.activeRuleCount, forKey: totalKey)
            return
        }

        var builtLists: [WKContentRuleList] = []
        var builtIDs: [String] = []
        for (chunkIndex, jsonPayload) in parsed.chunkJSONPayloads.enumerated() {
            let identifier = "\(Self.chunkIdentifierPrefix)\(stateDefaultsNamespace)\(chunkIndex)"
            if let compiled = await compileEncodedChunkResiliently(jsonPayload: jsonPayload, identifier: identifier, store: store) {
                builtLists.append(compiled)
                builtIDs.append(identifier)
            }
        }

        let builtIDSet = Set(builtIDs)
        for staleID in previousChunkIDs.subtracting(builtIDSet) {
            try? await store.removeContentRuleList(forIdentifier: staleID)
        }

        self.compiledLists = builtLists
        self.compiledListsGeneration &+= 1
        let dfaTotal = builtLists.isEmpty ? 0 : parsed.totalDFARules
        self.activeRuleCount = dfaTotal + parsed.scriptletRules.count
        UserDefaults.standard.set(computeStateSignature(), forKey: sigKey)
        UserDefaults.standard.set(Self.compilerSchemaVersion, forKey: verKey)
        UserDefaults.standard.set(builtIDs.count, forKey: chunkKey)
        UserDefaults.standard.set(builtIDs, forKey: chunkIDsKey)
        UserDefaults.standard.set(self.activeRuleCount, forKey: totalKey)
    }

    private func compileEncodedChunkResiliently(
        jsonPayload: String,
        identifier: String,
        store: WKContentRuleListStore
    ) async -> WKContentRuleList? {
        if let compiled = try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: jsonPayload) {
            return compiled
        }
        guard let data = jsonPayload.data(using: .utf8),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let cleanSubset = await isolateValidRules(rules, store: store, depth: 0)
        for d in 0...8 {
            try? await store.removeContentRuleList(forIdentifier: "dysprosium.filters.probe.\(d)")
        }
        guard !cleanSubset.isEmpty, let encoded = Self.encodeJSONString(cleanSubset) else {
            return nil
        }
        return try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded)
    }

    private func isolateValidRules(
        _ slice: [[String: Any]],
        store: WKContentRuleListStore,
        depth: Int
    ) async -> [[String: Any]] {
        guard !slice.isEmpty, depth <= 8 else { return [] }
        if let encoded = Self.encodeJSONString(slice),
           (try? await store.compileContentRuleList(
               forIdentifier: "dysprosium.filters.probe.\(depth)",
               encodedContentRuleList: encoded
           )) != nil {
            return slice
        }
        guard slice.count > 1 else { return [] }
        let mid = slice.count / 2
        let left = await isolateValidRules(Array(slice[..<mid]), store: store, depth: depth + 1)
        let right = await isolateValidRules(Array(slice[mid...]), store: store, depth: depth + 1)
        return left + right
    }

    private func propagateUpdatedListsToControllers() async {
        attachedControllers.removeAll { $0.controller == nil }
        let entries = attachedControllers
        for entry in entries {
            guard let controller = entry.controller else { continue }
            let host = entry.currentHostProvider()
            let rawEnabled = entry.isEnabledProvider()
            let effectiveEnabled = entry.profileID != nil
                ? rawEnabled
                : effectiveShieldEnabled(globalEnabled: rawEnabled, forHost: host)
            let seed = entry.fingerprintSeedProvider() ?? entry.storedExplicitSeedOverride
            let ua = entry.userAgentProfileProvider() ?? entry.lastUserAgentProfile
            let autoDark = entry.autoWebPageDarkModeProvider() ?? entry.lastAutoWebPageDarkMode
            installUserScripts(
                on: controller,
                shieldEnabled: effectiveEnabled,
                forHost: host,
                includeFingerprintShield: true,
                fingerprintSeedOverride: seed,
                maskFoldableScreenOverride: entry.lastMaskFoldableScreenOverride,
                userAgentProfileOverride: ua,
                autoWebPageDarkModeOverride: autoDark
            )
            controller.removeAllContentRuleLists()
            if effectiveEnabled {
                for list in compiledLists {
                    controller.add(list)
                }
            }
            if let idx = attachedControllers.firstIndex(where: { $0.controller === controller }) {
                attachedControllers[idx].lastAppliedRuleListEnabled = effectiveEnabled
                attachedControllers[idx].lastAppliedRuleListGeneration = compiledListsGeneration
            }
        }
    }

    // MARK: - Persistence & Seed Subscription Catalog

    public nonisolated static var defaultCommunitySubscriptions: [FilterSubscription] {
        [
            // 1. Core Global Ad Networks (Enabled by Default)
            FilterSubscription(
                id: "ubol-core",
                title: "uBlock Origin Lite · Core Filters",
                subtitle: "uBOL-home MV3 network & video ad ruleset",
                sourceURL: URL(string: "https://cdn.jsdelivr.net/gh/uBlockOrigin/uBOL-home@main/chromium/rulesets/main/ublock-filters.json")!,
                category: .ads,
                format: .dnrJSON,
                maxRuleBudget: 18_000,
                isEnabled: true,
                isBuiltInSeed: true
            ),
            FilterSubscription(
                id: "adguard-ios-base",
                title: "AdGuard Base + EasyList (iOS)",
                subtitle: "WebKit-optimized global ad & pre-roll filter feed",
                sourceURL: URL(string: "https://filters.adtidy.org/ios/filters/2_optimized.txt")!,
                category: .ads,
                format: .abpFilterList,
                maxRuleBudget: 45_000,
                isEnabled: true,
                isBuiltInSeed: true
            ),

            // 2. Chinese Regional & App-Redirect Annoyance Filters (Enabled by Default)
            FilterSubscription(
                id: "adguard-ios-chinese",
                title: "AdGuard Chinese Filter (iOS)",
                subtitle: "WebKit-optimized domestic ad SDKs & 'Open in App' overlays",
                sourceURL: URL(string: "https://filters.adtidy.org/ios/filters/224_optimized.txt")!,
                category: .regional,
                format: .abpFilterList,
                maxRuleBudget: 28_000,
                isEnabled: true,
                isBuiltInSeed: true
            ),
            FilterSubscription(
                id: "cjx-annoyance",
                title: "CJX's Annoyance List",
                subtitle: "Removes Chinese self-promo banners, QR prompts & nags",
                sourceURL: URL(string: "https://raw.githubusercontent.com/cjx82630/cjxlist/master/cjx-annoyance.txt")!,
                category: .regional,
                format: .abpFilterList,
                maxRuleBudget: 8_000,
                isEnabled: true,
                isBuiltInSeed: true
            ),

            // 3. Privacy, Telemetry & Fingerprinting Protection (Enabled by Default)
            FilterSubscription(
                id: "ubo-privacy",
                title: "uBlock Origin · Privacy",
                subtitle: "Blocks telemetry beacons, session replay & analytics scripts",
                sourceURL: URL(string: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt")!,
                category: .privacy,
                format: .abpFilterList,
                maxRuleBudget: 12_000,
                isEnabled: true,
                isBuiltInSeed: true
            ),
            FilterSubscription(
                id: "adguard-ios-tracking",
                title: "AdGuard Tracking Protection (iOS)",
                subtitle: "WebKit-optimized tracker, pixel & fingerprinting defense",
                sourceURL: URL(string: "https://filters.adtidy.org/ios/filters/3_optimized.txt")!,
                category: .privacy,
                format: .abpFilterList,
                maxRuleBudget: 30_000,
                isEnabled: true,
                isBuiltInSeed: true
            ),

            // 4. Malware, Phishing & Cryptojacking Defense (Enabled by Default)
            FilterSubscription(
                id: "ubo-badware",
                title: "uBlock Origin · Badware Risks",
                subtitle: "Blocks known malware, phishing & browser-mining hosts",
                sourceURL: URL(string: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/badware.txt")!,
                category: .security,
                format: .abpFilterList,
                maxRuleBudget: 12_000,
                isEnabled: true,
                isBuiltInSeed: true
            ),

            // 5. Popups, Overlays & Anti-Adblock Scriptlets (Enabled by Default)
            FilterSubscription(
                id: "ubol-annoyances",
                title: "uBlock Origin Lite · Popups & Overlays",
                subtitle: "uBOL-home popunder, modal & overlay shield",
                sourceURL: URL(string: "https://cdn.jsdelivr.net/gh/uBlockOrigin/uBOL-home@main/chromium/rulesets/main/annoyances-overlays.json")!,
                category: .popups,
                format: .dnrJSON,
                maxRuleBudget: 5_000,
                isEnabled: true,
                isBuiltInSeed: true
            ),
            FilterSubscription(
                id: "adguard-ios-annoyances",
                title: "AdGuard Popups & Annoyances (iOS)",
                subtitle: "Blocks hostile popups ($popup) & floating banners",
                sourceURL: URL(string: "https://filters.adtidy.org/ios/filters/14_optimized.txt")!,
                category: .popups,
                format: .abpFilterList,
                maxRuleBudget: 30_000,
                isEnabled: true,
                isBuiltInSeed: true
            ),
            FilterSubscription(
                id: "easylist-anti-adblock",
                title: "Anti-Adblock Warning Removal",
                subtitle: "Community rules bypassing anti-adblock walls",
                sourceURL: URL(string: "https://easylist-downloads.adblockplus.org/antiadblockfilters.txt")!,
                category: .antiAdblock,
                format: .abpFilterList,
                maxRuleBudget: 8_000,
                isEnabled: true,
                isBuiltInSeed: true
            ),
            FilterSubscription(
                id: "ubo-unbreak",
                title: "uBlock Origin · Unbreak",
                subtitle: "Scriptlets fixing broken media players & anti-adblock walls",
                sourceURL: URL(string: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/unbreak.txt")!,
                category: .antiAdblock,
                format: .abpFilterList,
                maxRuleBudget: 12_000,
                isEnabled: true,
                isBuiltInSeed: true
            ),
            FilterSubscription(
                id: "ubo-quick-fixes",
                title: "uBlock Origin · Quick Fixes",
                subtitle: "Rapid-response anti-adblock & video player scriptlets",
                sourceURL: URL(string: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt")!,
                category: .antiAdblock,
                format: .abpFilterList,
                maxRuleBudget: 12_000,
                isEnabled: true,
                isBuiltInSeed: true
            ),

            // 6. Pre-Seeded Optional Presets (Off by Default — Zero Memory Cost Until Toggled On)
            FilterSubscription(
                id: "adguard-ios-mobile",
                title: "AdGuard Mobile Ads Filter (iOS)",
                subtitle: "Optional mobile WAP/banner ad network rules",
                sourceURL: URL(string: "https://filters.adtidy.org/ios/filters/11_optimized.txt")!,
                category: .ads,
                format: .abpFilterList,
                maxRuleBudget: 20_000,
                isEnabled: false,
                isBuiltInSeed: true
            ),
            FilterSubscription(
                id: "adguard-ios-cookies",
                title: "AdGuard Cookie Notices (iOS)",
                subtitle: "Optional GDPR / EU cookie consent banner suppressor",
                sourceURL: URL(string: "https://filters.adtidy.org/ios/filters/18_optimized.txt")!,
                category: .popups,
                format: .abpFilterList,
                maxRuleBudget: 24_000,
                isEnabled: false,
                isBuiltInSeed: true
            ),
            FilterSubscription(
                id: "adguard-ios-social",
                title: "AdGuard Social Media Widgets (iOS)",
                subtitle: "Optional third-party share buttons & social embed blocker",
                sourceURL: URL(string: "https://filters.adtidy.org/ios/filters/4_optimized.txt")!,
                category: .popups,
                format: .abpFilterList,
                maxRuleBudget: 16_000,
                isEnabled: false,
                isBuiltInSeed: true
            ),
            FilterSubscription(
                id: "peter-lowe-blocklist",
                title: "Peter Lowe's Ad & Tracking Server List",
                subtitle: "Optional compact host-level ad & tracker domain list",
                sourceURL: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext")!,
                category: .privacy,
                format: .abpFilterList,
                maxRuleBudget: 6_000,
                isEnabled: false,
                isBuiltInSeed: true
            )
        ]
    }

    private func reloadPersistedScriptletsFromDisk() async {
        let url = compiledScriptletsURL
        let result: ([WebKitRuleCompiler.CompiledScriptletRule], [String: [Int]])? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([WebKitRuleCompiler.CompiledScriptletRule].self, from: data) else {
                return nil
            }
            let index = Self.buildScriptletHostIndex(from: decoded)
            return (decoded, index)
        }.value
        guard let result else { return }
        self.compiledScriptletRules = result.0
        self.scriptletIndexByHost = result.1
        self.perHostScriptletCache.removeAll(keepingCapacity: true)
    }

    private func cacheFileURL(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return storageDirectory.appendingPathComponent("\(safe).cache", isDirectory: false)
    }

    private func computeStateSignature() -> String {
        let joined = "\(Self.compilerSchemaVersion)|\(stateDefaultsNamespace)|" + subscriptions
            .filter(\.isEnabled)
            .map {
                let syncEpoch = Int(($0.lastSyncedAt?.timeIntervalSince1970 ?? 0).rounded())
                return "\($0.id):\($0.maxRuleBudget):\(syncEpoch):\($0.compiledRuleCount)"
            }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func persistSubscriptionsAsync() async {
        let snapshot = subscriptions
        let url = manifestURL
        await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }.value
    }

    nonisolated private static func loadOrSeedSubscriptions(from manifestURL: URL) -> [FilterSubscription] {
        let seeds = defaultCommunitySubscriptions
        let seedByID = Dictionary(uniqueKeysWithValues: seeds.map { ($0.id, $0) })
        if let data = try? Data(contentsOf: manifestURL),
           var decoded = try? JSONDecoder().decode([FilterSubscription].self, from: data),
           !decoded.isEmpty {
            var didMutate = false
            for idx in decoded.indices {
                if decoded[idx].isBuiltInSeed, let latestSeed = seedByID[decoded[idx].id] {
                    if decoded[idx].maxRuleBudget < latestSeed.maxRuleBudget {
                        decoded[idx].maxRuleBudget = latestSeed.maxRuleBudget
                        didMutate = true
                    }
                }
            }
            let existingIDs = Set(decoded.map(\.id))
            for seed in seeds where !existingIDs.contains(seed.id) {
                decoded.append(seed)
                didMutate = true
            }
            if didMutate {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let updated = try? encoder.encode(decoded) {
                    try? updated.write(to: manifestURL, options: .atomic)
                }
            }
            return decoded
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(seeds) {
            try? data.write(to: manifestURL, options: .atomic)
        }
        return seeds
    }

    nonisolated private static func prepareStorageDirectory(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var mutable = dir
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? mutable.setResourceValues(rv)
    }

    nonisolated private static func encodeJSONString(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
