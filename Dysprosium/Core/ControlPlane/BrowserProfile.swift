import Foundation
import WebKit

/// Persistent isolated browser profile (`Personal`, `Work`, `Research`, etc.).
///
/// Architecture invariants:
/// - The built-in Default profile (`isDefault == true`, `id == BrowserProfile.defaultID`) keeps
///   `webkitStoreID == nil` so it uses `WKWebsiteDataStore.default()` with zero login/cookie migration loss.
/// - Every secondary profile carries a unique non-zero `webkitStoreID: UUID` mapped through
///   `ProfileWebsiteDataStoreRegistry` (`WeakBox` cache over `WKWebsiteDataStore(forIdentifier:)`),
///   giving hard per-profile isolation for Cookies, LocalStorage, IndexedDB, Cache, HSTS, ITP, and proxies.
/// - Private Browsing remains a single orthogonal ephemeral pool (`isPrivate == true`, `profileID == nil`).
public struct BrowserProfile: Identifiable, Codable, Equatable, Sendable {
    public static let defaultID = "00000000-0000-4000-8000-000000000001"
    /// Sentinel `sourceProfileID` tagged on transfers initiated from ephemeral Private tabs so
    /// Private cookies are never conflated with Default profile auth headers and are scrubbed when
    /// the last Private tab closes.
    public static let privateTransferProfileID = "__private__"
    public static let maxProfileCount = 6
    public static let maxNameLength = 20

    public struct SymbolOption: Identifiable, Equatable, Sendable {
        public let symbol: String
        public let label: String
        public var id: String { symbol }

        public init(symbol: String, label: String) {
            self.symbol = symbol
            self.label = label
        }
    }

    public static let curatedSymbols: [SymbolOption] = [
        .init(symbol: "person.crop.circle", label: "Personal"),
        .init(symbol: "briefcase.fill", label: "Work"),
        .init(symbol: "graduationcap.fill", label: "Study"),
        .init(symbol: "flask.fill", label: "Research"),
        .init(symbol: "play.rectangle.fill", label: "Media"),
        .init(symbol: "cart.fill", label: "Shopping"),
        .init(symbol: "gamecontroller.fill", label: "Gaming"),
        .init(symbol: "terminal.fill", label: "Dev"),
        .init(symbol: "airplane", label: "Travel"),
        .init(symbol: "book.closed.fill", label: "Reading"),
        .init(symbol: "building.columns.fill", label: "Finance"),
        .init(symbol: "sparkles", label: "Focus")
    ]

    public static let quickNameSuggestions: [(name: String, symbol: String, palette: DysprosiumPalettePreset)] = [
        ("Work", "briefcase.fill", .ultramarine),
        ("Study", "graduationcap.fill", .terbium),
        ("Research", "flask.fill", .europium),
        ("Media", "play.rectangle.fill", .obsidian)
    ]

    public let id: String
    public var name: String
    public var symbolName: String
    public var palettePreset: DysprosiumPalettePreset
    public let isDefault: Bool
    /// `nil` for the Default profile (`WKWebsiteDataStore.default()`); non-nil UUIDv4 for secondary profiles.
    public let webkitStoreID: UUID?
    public var fingerprintSeed: String
    public var userAgentProfile: BrowserUserAgentProfile
    public var searchEngine: BrowserSearchEngine
    public var customSearchTemplate: String
    public var sortOrder: Double
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        symbolName: String = "person.crop.circle",
        palettePreset: DysprosiumPalettePreset = .cerulean,
        isDefault: Bool = false,
        webkitStoreID: UUID? = nil,
        fingerprintSeed: String,
        userAgentProfile: BrowserUserAgentProfile = .iosSafari,
        searchEngine: BrowserSearchEngine = .duckDuckGo,
        customSearchTemplate: String = BrowserSearchEngine.defaultCustomTemplate,
        sortOrder: Double = 100.0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = Self.sanitizedName(name, fallback: isDefault ? "Personal" : "Profile")
        self.symbolName = symbolName.isEmpty ? "person.crop.circle" : symbolName
        self.palettePreset = palettePreset
        self.isDefault = isDefault
        self.webkitStoreID = isDefault ? nil : (webkitStoreID ?? UUID())
        self.fingerprintSeed = fingerprintSeed.count >= 32
            ? fingerprintSeed
            : FingerprintShieldEngine.generateCryptographicSeed()
        self.userAgentProfile = userAgentProfile
        self.searchEngine = searchEngine
        let trimmedTemplate = customSearchTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        self.customSearchTemplate = trimmedTemplate.isEmpty
            ? BrowserSearchEngine.defaultCustomTemplate
            : trimmedTemplate
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    public var shortSeedSpecimen: String {
        let prefix = String(fingerprintSeed.prefix(8))
        guard prefix.count == 8 else { return fingerprintSeed }
        return "\(prefix.prefix(4))·\(prefix.suffix(4))"
    }

    public var tokens: DysprosiumTokens {
        DysprosiumTokens(preset: palettePreset)
    }

    public static func sanitizedName(_ raw: String, fallback: String = "Profile") -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.count <= maxNameLength {
            return trimmed
        }
        return String(trimmed.prefix(maxNameLength))
    }

    /// Deterministic Default `Personal` profile seeded losslessly from existing shared defaults.
    public nonisolated static func makeDefaultProfile(
        seed: String? = nil,
        palettePreset: DysprosiumPalettePreset? = nil,
        userAgentProfile: BrowserUserAgentProfile? = nil,
        searchEngine: BrowserSearchEngine? = nil,
        customSearchTemplate: String? = nil
    ) -> BrowserProfile {
        let resolvedSeed: String = {
            if let seed, seed.count >= 32 { return seed }
            if let saved = LiveContainerEnvironment.sharedDefaults.string(forKey: "dysprosium.fingerprintShield.standardSeed"),
               saved.count >= 32 {
                return saved
            }
            if let legacy = UserDefaults.standard.string(forKey: "dysprosium.fingerprintShield.standardSeed"),
               legacy.count >= 32 {
                return legacy
            }
            let fresh = FingerprintShieldEngine.generateCryptographicSeed()
            LiveContainerEnvironment.sharedDefaults.set(fresh, forKey: "dysprosium.fingerprintShield.standardSeed")
            return fresh
        }()

        let resolvedPalette: DysprosiumPalettePreset = {
            if let palettePreset { return palettePreset }
            let raw = LiveContainerEnvironment.sharedDefaults.string(forKey: "dysprosium.design.palettePreset")
                ?? UserDefaults.standard.string(forKey: "dysprosium.design.palettePreset")
                ?? ""
            return DysprosiumPalettePreset(rawValue: raw) ?? .cerulean
        }()

        return BrowserProfile(
            id: defaultID,
            name: "Personal",
            symbolName: "person.crop.circle",
            palettePreset: resolvedPalette,
            isDefault: true,
            webkitStoreID: nil,
            fingerprintSeed: resolvedSeed,
            userAgentProfile: userAgentProfile ?? BrowserUserAgentProfile.persistedCurrent,
            searchEngine: searchEngine ?? BrowserSearchEngine.persistedCurrent,
            customSearchTemplate: customSearchTemplate ?? BrowserSearchEngine.persistedCustomTemplate,
            sortOrder: 0.0,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}

/// Manages per-profile `WKWebsiteDataStore` instances safely across iOS 17–27.2 and LiveContainer:
///
/// 1. **Weak object-identity cache (`[UUID: WeakBox]`)**: `WKWebsiteDataStore(forIdentifier:)` returns a
///    fresh instance per call, which splits WebKit `WebContent`/`Networking` process sharing unless cached.
///    Holding a weak reference lets all live tabs in a profile share one store while allowing WebKit to
///    reclaim idle `NetworkSession` resources once all tabs in that profile close or hibernate—and prevents
///    stray retains from blocking `WKWebsiteDataStore.remove(forIdentifier:)`.
/// 2. **Cold-start WebKit guard**: Touches `WKWebsiteDataStore.default()` before calling
///    `allDataStoreIdentifiers` or `remove(forIdentifier:)` to avoid WebKit's `WTF::RunLoop::dispatch` SEGV.
/// 3. **Teardown retry & deferred GC**: Retries `remove(forIdentifier:)` (`50ms`, `150ms`, `400ms`) across
///    WebKit's 20–60 ms `NetworkProcess` teardown window and records persistent deferred GC UUIDs in
///    container-local `UserDefaults.standard` when a store is still busy or deleted from a sibling LC host.
@MainActor
public final class ProfileWebsiteDataStoreRegistry {
    private final class WeakStoreBox {
        weak var store: WKWebsiteDataStore?

        init(_ store: WKWebsiteDataStore) {
            self.store = store
        }
    }

    private nonisolated static let pendingDeletedStoreUUIDsKey = "dysprosium.profiles.pendingDeletedStoreUUIDs.v1"

    private var cache: [UUID: WeakStoreBox] = [:]

    public init() {}

    /// Returns the authoritative `WKWebsiteDataStore` for `profile` (`.default()` for Default profile,
    /// weak-cached `forIdentifier:` for secondary profiles) and synchronizes OS manual proxy settings.
    public func websiteDataStore(for profile: BrowserProfile) -> WKWebsiteDataStore {
        guard let storeUUID = profile.webkitStoreID else {
            let store = WKWebsiteDataStore.default()
            SystemProxyBridge.sync(dataStore: store)
            return store
        }
        return websiteDataStore(forIdentifier: storeUUID)
    }

    /// Returns the weak-cached `WKWebsiteDataStore(forIdentifier:)` instance for `uuid`.
    public func websiteDataStore(forIdentifier uuid: UUID) -> WKWebsiteDataStore {
        pruneDeallocatedBoxes()
        if let existing = cache[uuid]?.store {
            SystemProxyBridge.sync(dataStore: existing)
            return existing
        }
        let created = WKWebsiteDataStore(forIdentifier: uuid)
        cache[uuid] = WeakStoreBox(created)
        SystemProxyBridge.sync(dataStore: created)
        return created
    }

    /// Returns an already-allocated `WKWebsiteDataStore` for `profile` without creating a fresh
    /// on-disk UUID directory for an untouched profile.
    ///
    /// Uses WebKit's authoritative `allDataStoreIdentifiers` (after touching `.default()` to guard
    /// cold-start RunLoop init) plus a bundle-scoped disk fallback so dormant/hibernated secondary
    /// profiles are accurately inspected and cleared on iOS 27.2 (`Library/WebKit/<BundleID>/WebsiteDataStore/<lower-uuid>/`).
    public func liveStoreIfAllocated(for profile: BrowserProfile) async -> WKWebsiteDataStore? {
        guard let storeUUID = profile.webkitStoreID else {
            return WKWebsiteDataStore.default()
        }
        if let existing = cache[storeUUID]?.store {
            return existing
        }
        _ = WKWebsiteDataStore.default()
        let existingIDs = await WKWebsiteDataStore.allDataStoreIdentifiers
        if existingIDs.contains(storeUUID) || !Self.existingDiskDirectories(forStoreIdentifier: storeUUID).isEmpty {
            return websiteDataStore(forIdentifier: storeUUID)
        }
        return nil
    }

    /// Returns all existing `WebsiteDataStore` parent directories under `Library/WebKit`
    /// (both `Library/WebKit/<BundleID>/WebsiteDataStore` on iOS 17–27.2 / LiveContainer and
    /// legacy `Library/WebKit/WebsiteDataStore`).
    public nonisolated static func allWebsiteDataStoreRoots() -> [URL] {
        let fm = FileManager.default
        guard let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return []
        }
        let webkitRoot = libraryURL.appendingPathComponent("WebKit", isDirectory: true)
        var roots: [URL] = []
        var seen: Set<String> = []

        func appendIfDirectory(_ url: URL) {
            var isDir: ObjCBool = false
            let standardized = url.standardizedFileURL.path
            guard !seen.contains(standardized),
                  fm.fileExists(atPath: standardized, isDirectory: &isDir),
                  isDir.boolValue else {
                return
            }
            seen.insert(standardized)
            roots.append(url)
        }

        appendIfDirectory(webkitRoot.appendingPathComponent("WebsiteDataStore", isDirectory: true))
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            appendIfDirectory(
                webkitRoot
                    .appendingPathComponent(bundleID, isDirectory: true)
                    .appendingPathComponent("WebsiteDataStore", isDirectory: true)
            )
        }
        if let children = try? fm.contentsOfDirectory(
            at: webkitRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children {
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                appendIfDirectory(child.appendingPathComponent("WebsiteDataStore", isDirectory: true))
            }
        }
        return roots
    }

    /// Resolves all existing on-disk directories for a secondary profile's `WKWebsiteDataStore(forIdentifier:)`.
    /// Matches lowercase UUIDs (iOS 27.2 WebKit on case-sensitive APFS) and uppercase UUIDs across
    /// `Library/WebKit/<BundleID>/WebsiteDataStore/` and legacy `Library/WebKit/WebsiteDataStore/`.
    public nonisolated static func existingDiskDirectories(forStoreIdentifier uuid: UUID) -> [URL] {
        let fm = FileManager.default
        let lower = uuid.uuidString.lowercased()
        let upper = uuid.uuidString.uppercased()
        var matches: [URL] = []
        var seen: Set<String> = []

        for root in allWebsiteDataStoreRoots() {
            for candidateName in (lower == upper ? [lower] : [lower, upper]) {
                let candidate = root.appendingPathComponent(candidateName, isDirectory: true)
                let path = candidate.standardizedFileURL.path
                var isDir: ObjCBool = false
                if !seen.contains(path),
                   fm.fileExists(atPath: path, isDirectory: &isDir),
                   isDir.boolValue {
                    seen.insert(path)
                    matches.append(candidate)
                }
            }
        }
        return matches
    }

    /// Primary expected disk path for a secondary profile's `WKWebsiteDataStore(forIdentifier:)`.
    public nonisolated static func diskDirectory(forStoreIdentifier uuid: UUID) -> URL? {
        if let existing = existingDiskDirectories(forStoreIdentifier: uuid).first {
            return existing
        }
        guard let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let webkitRoot = libraryURL.appendingPathComponent("WebKit", isDirectory: true)
        let scopedRoot: URL
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            scopedRoot = webkitRoot.appendingPathComponent(bundleID, isDirectory: true)
        } else {
            scopedRoot = webkitRoot
        }
        return scopedRoot
            .appendingPathComponent("WebsiteDataStore", isDirectory: true)
            .appendingPathComponent(uuid.uuidString.lowercased(), isDirectory: true)
    }

    /// Removes the on-disk `WKWebsiteDataStore` for `uuid` with bounded teardown retry and deferred GC fallback.
    public func removeStore(forIdentifier uuid: UUID) async {
        cache.removeValue(forKey: uuid)
        // Guard against WebKit's cold-start `WTF::RunLoop::dispatch` crash when `remove(forIdentifier:)`
        // is invoked before `WKWebsiteDataStore` initializes its Cocoa RunLoop bridge.
        _ = WKWebsiteDataStore.default()

        let retryDelaysMs: [UInt64] = [50, 150, 400]
        for attempt in 0...retryDelaysMs.count {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: uuid)
                removePendingDeletedUUID(uuid)
                return
            } catch {
                if attempt < retryDelaysMs.count {
                    try? await Task.sleep(for: .milliseconds(retryDelaysMs[attempt]))
                }
            }
        }
        recordPendingDeletedUUID(uuid)
    }

    /// Lazily cleans up orphaned `WKWebsiteDataStore` directories (e.g., from a profile deleted on a
    /// sibling LiveContainer instance or deferred after a busy teardown). Zero WebKit overhead when
    /// running single-profile with no pending deletions or secondary store directories on disk.
    public func collectOrphanedStores(keeping activeStoreUUIDs: Set<UUID>) async {
        let pending = loadPendingDeletedUUIDs()
        let hasDiskDirectory = !Self.allWebsiteDataStoreRoots().isEmpty

        guard !pending.isEmpty || hasDiskDirectory else { return }

        _ = WKWebsiteDataStore.default()
        let existingIDs = Set(await WKWebsiteDataStore.allDataStoreIdentifiers)
        let orphans = existingIDs.union(pending).subtracting(activeStoreUUIDs)
        guard !orphans.isEmpty else {
            savePendingDeletedUUIDs([])
            return
        }

        for uuid in orphans {
            if cache[uuid]?.store != nil {
                recordPendingDeletedUUID(uuid)
                continue
            }
            if existingIDs.contains(uuid) {
                await removeStore(forIdentifier: uuid)
            } else {
                removePendingDeletedUUID(uuid)
            }
        }
    }

    private func pruneDeallocatedBoxes() {
        cache = cache.filter { $0.value.store != nil }
    }

    private func loadPendingDeletedUUIDs() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: Self.pendingDeletedStoreUUIDsKey) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func savePendingDeletedUUIDs(_ uuids: Set<UUID>) {
        if uuids.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingDeletedStoreUUIDsKey)
        } else {
            UserDefaults.standard.set(uuids.map(\.uuidString).sorted(), forKey: Self.pendingDeletedStoreUUIDsKey)
        }
    }

    private func recordPendingDeletedUUID(_ uuid: UUID) {
        var current = loadPendingDeletedUUIDs()
        current.insert(uuid)
        savePendingDeletedUUIDs(current)
    }

    private func removePendingDeletedUUID(_ uuid: UUID) {
        var current = loadPendingDeletedUUIDs()
        guard current.remove(uuid) != nil else { return }
        savePendingDeletedUUIDs(current)
    }
}
