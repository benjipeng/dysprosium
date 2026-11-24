import Darwin
import Foundation
import UIKit
import WebKit

/// Official Dark Reader `4.9.135` Dynamic Theme Engine host for `WKWebView`.
///
/// Replaces GPU-heavy whole-page CSS `filter: invert()` with Dark Reader's native
/// CSSOM / HSL color-remapping engine (`darkreader.min.js`) paired with:
/// 1. Official `dark-sites.config` O(1) skip list (0 KB injected on natively dark sites)
/// 2. Compact mmap-backed byte-offset index for `dynamic-theme-fixes.config` (~0.5 KB per host instead of 823 KB)
/// 3. Calibrated Web Theme presets (`OLED`, `Obsidian`, `Graphite`, `Paper`) + `Auto / On / Off` mode
/// 4. Same-origin cache-backed fetch + SSRF-hardened ephemeral, cookieless cross-origin CSS bridge
/// 5. Reversible computed-style refinement pass for Tailwind v4 CSS-var gradients, dark monochrome SVG logos, and CSS icon bars
public final class DarkReaderEngine: @unchecked Sendable {
    public static let shared = DarkReaderEngine()
    public static let fetchMessageHandlerName = "dysprosiumDarkFetch"

    public enum WebDarkModeBehavior: String, CaseIterable, Identifiable, Codable, Sendable {
        case auto
        case on
        case off

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .auto: return L("Auto")
            case .on: return L("On")
            case .off: return L("Off")
            }
        }

        public var isEnabled: Bool {
            self != .off
        }
    }

    public enum WebDarkThemePreset: String, CaseIterable, Identifiable, Codable, Sendable {
        case oled
        case obsidian
        case graphite
        case paper

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .oled: return L("OLED")
            case .obsidian: return L("Obsidian")
            case .graphite: return L("Graphite")
            case .paper: return L("Paper")
            }
        }

        public var isDarkScheme: Bool {
            self != .paper
        }

        public var backgroundHex: String {
            switch self {
            case .oled: return "#000000"
            case .obsidian: return "#181a1b"
            case .graphite: return "#242629"
            case .paper: return "#dfd3ba"
            }
        }

        public var textHex: String {
            switch self {
            case .oled: return "#f2f2f7"
            case .obsidian: return "#e8e6e3"
            case .graphite: return "#e6e4df"
            case .paper: return "#231f1a"
            }
        }

        public var backgroundRGB: (r: Int, g: Int, b: Int) {
            switch self {
            case .oled: return (0, 0, 0)
            case .obsidian: return (24, 26, 27)
            case .graphite: return (36, 38, 41)
            case .paper: return (223, 211, 186)
            }
        }

        public var elevatedSurfaceRGB: (r: Int, g: Int, b: Int) {
            switch self {
            case .oled: return (12, 13, 15)
            case .obsidian: return (32, 35, 37)
            case .graphite: return (45, 48, 52)
            case .paper: return (230, 219, 196)
            }
        }

        public var canvasUIColor: UIColor {
            let c = backgroundRGB
            return UIColor(
                red: CGFloat(c.r) / 255.0,
                green: CGFloat(c.g) / 255.0,
                blue: CGFloat(c.b) / 255.0,
                alpha: 1.0
            )
        }

        /// Calibrated Dark Reader theme literal (`contrast: 100` avoids muddy black-level compression).
        public var themeJSONLiteral: String {
            let bg = backgroundRGB
            let elev = elevatedSurfaceRGB
            switch self {
            case .oled, .obsidian, .graphite:
                return """
                {"mode":1,"brightness":100,"contrast":100,"sepia":0,"grayscale":0,"darkSchemeBackgroundColor":"\(backgroundHex)","darkSchemeTextColor":"\(textHex)","selectionColor":"auto","styleSystemControls":true,"_dyBaseRGB":[\(bg.r),\(bg.g),\(bg.b)],"_dyElevRGB":[\(elev.r),\(elev.g),\(elev.b)]}
                """
            case .paper:
                return """
                {"mode":0,"brightness":98,"contrast":100,"sepia":10,"grayscale":0,"lightSchemeBackgroundColor":"\(backgroundHex)","lightSchemeTextColor":"\(textHex)","selectionColor":"auto","styleSystemControls":true,"_dyBaseRGB":[\(bg.r),\(bg.g),\(bg.b)],"_dyElevRGB":[\(elev.r),\(elev.g),\(elev.b)]}
                """
            }
        }
    }

    private static let maxStylesheetBytes = 2 * 1024 * 1024 // 2 MiB
    private static let maxRedirectHops = 5
    private static let maxParsedFixCacheCount = 64

    public struct DynamicFix: Sendable {
        public var invert: [String] = []
        public var css: String = ""
        public var ignoreInlineStyle: [String] = []
        public var ignoreImageAnalysis: [String] = []
        public var ignoreCSSUrl: [String] = []
        public var noCommon: Bool = false

        func merged(with common: DynamicFix?) -> DynamicFix {
            guard !noCommon, let common else { return self }
            var out = DynamicFix()
            out.invert = common.invert + invert
            out.css = [common.css, css].filter { !$0.isEmpty }.joined(separator: "\n")
            out.ignoreInlineStyle = common.ignoreInlineStyle + ignoreInlineStyle
            out.ignoreImageAnalysis = common.ignoreImageAnalysis + ignoreImageAnalysis
            out.ignoreCSSUrl = common.ignoreCSSUrl + ignoreCSSUrl
            out.noCommon = false
            return out
        }

        func toJSONLiteral(preset: WebDarkThemePreset = .oled) -> String {
            // Enable Dark Reader's live CSSStyleSheet proxy so dynamic `insertRule()` / `adoptedStyleSheets`
            // transition cleanly, and preserve real per-site `ignoreImageAnalysis` from `dynamic-theme-fixes.config`
            // (never forcing blanket `["*"]`, which skips all CSS `linear-gradient()` / `radial-gradient()` darkening).
            var cssParts: [String] = []
            if preset.isDarkScheme {
                cssParts.append(":root { color-scheme: dark !important; }")
            }
            if !css.isEmpty {
                cssParts.append(css)
            }
            let editorialCSS = cssParts.joined(separator: "\n")

            var dict: [String: Any] = [
                "disableStyleSheetsProxy": false
            ]
            if !editorialCSS.isEmpty { dict["css"] = editorialCSS }
            if !invert.isEmpty { dict["invert"] = invert }
            if !ignoreInlineStyle.isEmpty { dict["ignoreInlineStyle"] = ignoreInlineStyle }
            if !ignoreImageAnalysis.isEmpty { dict["ignoreImageAnalysis"] = ignoreImageAnalysis }
            if !ignoreCSSUrl.isEmpty { dict["ignoreCSSUrl"] = ignoreCSSUrl }
            guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                  let str = String(data: data, encoding: .utf8) else {
                return "{\"disableStyleSheetsProxy\":false}"
            }
            return str
        }
    }

    private struct FetchReply: Sendable {
        let ok: Bool
        let status: Int
        let contentType: String?
        let text: String?
        let cacheable: Bool

        func toDictionary() -> [String: Any] {
            var dict: [String: Any] = ["ok": ok, "status": status]
            if let contentType { dict["contentType"] = contentType }
            if let text { dict["text"] = text }
            return dict
        }
    }

    private final class CachedStylesheet: NSObject, @unchecked Sendable {
        let contentType: String
        let text: String

        init(contentType: String, text: String) {
            self.contentType = contentType
            self.text = text
        }
    }

    private final class SendableStylesheetCache: @unchecked Sendable {
        private let cache = NSCache<NSString, CachedStylesheet>()

        init(countLimit: Int, totalCostLimit: Int) {
            cache.countLimit = countLimit
            cache.totalCostLimit = totalCostLimit
        }

        func object(forKey key: String) -> CachedStylesheet? {
            cache.object(forKey: key as NSString)
        }

        func setObject(_ obj: CachedStylesheet, forKey key: String, cost: Int) {
            cache.setObject(obj, forKey: key as NSString, cost: cost)
        }

        func removeAllObjects() {
            cache.removeAllObjects()
        }
    }

    private actor StylesheetFetchCoordinator {
        private var inFlight: [String: Task<FetchReply, Never>] = [:]
        private var activeCount: Int = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private let maxConcurrent = 6

        func fetch(urlString: String, operation: @escaping @Sendable () async -> FetchReply) async -> FetchReply {
            if let existing = inFlight[urlString] {
                return await existing.value
            }
            let task = Task<FetchReply, Never> {
                await self.acquireSlot()
                defer {
                    self.releaseSlot(for: urlString)
                }
                return await operation()
            }
            inFlight[urlString] = task
            return await task.value
        }

        private func acquireSlot() async {
            if activeCount < maxConcurrent {
                activeCount += 1
                return
            }
            await withCheckedContinuation { cont in
                waiters.append(cont)
            }
        }

        private func releaseSlot(for urlString: String) {
            inFlight.removeValue(forKey: urlString)
            if !waiters.isEmpty {
                let next = waiters.removeFirst()
                next.resume()
            } else {
                activeCount = max(0, activeCount - 1)
            }
        }
    }

    private final class BoundedCSSFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maxBytes: Int
        private let lock = NSLock()
        private var redirectCount = 0
        private var responseStatus = 200
        private var responseContentType: String?
        private var isCacheableResponse = false
        private var rejectedStatus: Int?
        private var buffer = Data()
        private var continuation: CheckedContinuation<FetchReply, Never>?
        private var didComplete = false

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        func awaitResult(for task: URLSessionDataTask) async -> FetchReply {
            await withTaskCancellationHandler {
                await withCheckedContinuation { cont in
                    lock.lock()
                    if didComplete {
                        let reply = buildReplyLocked()
                        lock.unlock()
                        cont.resume(returning: reply)
                    } else {
                        continuation = cont
                        lock.unlock()
                        task.resume()
                    }
                }
            } onCancel: {
                task.cancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            lock.lock()
            let currentRedirect = redirectCount
            redirectCount += 1
            lock.unlock()

            guard currentRedirect < DarkReaderEngine.maxRedirectHops,
                  let targetURL = request.url else {
                lock.lock()
                rejectedStatus = 403
                lock.unlock()
                completionHandler(nil)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                guard DarkReaderEngine.isAllowedPublicStylesheetURL(targetURL) else {
                    self.lock.lock()
                    self.rejectedStatus = 403
                    self.lock.unlock()
                    completionHandler(nil)
                    return
                }
                var sanitized = request
                sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
                sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
                completionHandler(sanitized)
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                lock.lock()
                rejectedStatus = 415
                lock.unlock()
                completionHandler(.cancel)
                return
            }

            if let finalURL = http.url, !DarkReaderEngine.isAllowedPublicStylesheetURL(finalURL) {
                lock.lock()
                rejectedStatus = 403
                lock.unlock()
                completionHandler(.cancel)
                return
            }

            let status = http.statusCode
            guard (200...299).contains(status) else {
                lock.lock()
                rejectedStatus = status
                lock.unlock()
                completionHandler(.cancel)
                return
            }

            let rawCT = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            let mediaType = rawCT
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            guard mediaType == "text/css" else {
                lock.lock()
                rejectedStatus = 415
                lock.unlock()
                completionHandler(.cancel)
                return
            }

            if http.expectedContentLength > Int64(maxBytes) {
                lock.lock()
                rejectedStatus = 413
                lock.unlock()
                completionHandler(.cancel)
                return
            }

            let cacheControl = (http.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased()
            let hasSetCookie = http.value(forHTTPHeaderField: "Set-Cookie") != nil
            let cacheable = !cacheControl.contains("no-store") && !hasSetCookie

            lock.lock()
            responseStatus = status
            responseContentType = rawCT
            isCacheableResponse = cacheable
            if http.expectedContentLength > 0 {
                buffer.reserveCapacity(min(maxBytes, Int(http.expectedContentLength)))
            }
            lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            if rejectedStatus != nil {
                lock.unlock()
                dataTask.cancel()
                return
            }
            if buffer.count + data.count > maxBytes {
                rejectedStatus = 413
                buffer.removeAll(keepingCapacity: false)
                lock.unlock()
                dataTask.cancel()
                return
            }
            buffer.append(data)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            didComplete = true
            let reply: FetchReply
            if let rejected = rejectedStatus {
                reply = FetchReply(ok: false, status: rejected, contentType: nil, text: nil, cacheable: false)
            } else if error != nil {
                reply = FetchReply(ok: false, status: 502, contentType: nil, text: nil, cacheable: false)
            } else {
                reply = buildReplyLocked()
            }
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: reply)
        }

        private func buildReplyLocked() -> FetchReply {
            if let rejected = rejectedStatus {
                return FetchReply(ok: false, status: rejected, contentType: nil, text: nil, cacheable: false)
            }
            let text = String(data: buffer, encoding: .utf8)
                ?? String(data: buffer, encoding: .isoLatin1)
                ?? ""
            return FetchReply(
                ok: (200...299).contains(responseStatus),
                status: responseStatus,
                contentType: responseContentType,
                text: text,
                cacheable: isCacheableResponse
            )
        }
    }

    private struct DarkSitesIndex: Sendable {
        let exactDarkHosts: Set<String>
        let suffixDarkHosts: Set<String>
    }

    private struct DynamicFixesIndex: Sendable {
        let data: Data
        let commonFix: DynamicFix?
        let rangesByHost: [String: Range<Int>]
    }

    private let bypassLock = NSLock()
    private var bypassedHostsSet: Set<String> = []

    private let settingsLock = NSLock()
    private var _modeBehavior: WebDarkModeBehavior = .auto
    private var _themePreset: WebDarkThemePreset = .oled

    private let darkSitesLock = NSLock()
    private var cachedDarkSites: DarkSitesIndex?
    private var isWarmingDarkSites = false

    private let fixesLock = NSLock()
    private var cachedFixesIndex: DynamicFixesIndex?
    private var parsedFixesCache: [String: DynamicFix] = [:]
    private var parsedFixesOrder: [String] = []
    private var cachedRuntimeJS: String?

    private let fetchCoordinator = StylesheetFetchCoordinator()
    private let stylesheetCache = SendableStylesheetCache(countLimit: 64, totalCostLimit: 4 * 1024 * 1024)
    private let validatedHostLock = NSLock()
    private var validatedPublicHosts: [String: ContinuousClock.Instant] = [:]
    private static let validatedHostTTL: Duration = .seconds(60)
    private static let bypassedHostsKey = "dysprosium.autoDark.bypassedHosts"
    public static let modeBehaviorDefaultsKey = "dysprosium.autoDark.modeBehavior.v1"
    public static let themePresetDefaultsKey = "dysprosium.autoDark.themePreset.v1"

    /// Current global Web Dark Mode behavior (`Auto` / `On` / `Off`), persisted across `LC 1` / `LC 2`.
    public var modeBehavior: WebDarkModeBehavior {
        get {
            settingsLock.lock()
            defer { settingsLock.unlock() }
            return _modeBehavior
        }
        set {
            settingsLock.lock()
            _modeBehavior = newValue
            settingsLock.unlock()
            LiveContainerEnvironment.sharedDefaults.set(newValue.rawValue, forKey: Self.modeBehaviorDefaultsKey)
            LiveContainerEnvironment.sharedDefaults.set(newValue.isEnabled, forKey: CleanroomBrowserStore.autoWebPageDarkModeDefaultsKey)
        }
    }

    /// Current calibrated Web Theme preset (`OLED` / `Obsidian` / `Graphite` / `Paper`), persisted across `LC 1` / `LC 2`.
    public var themePreset: WebDarkThemePreset {
        get {
            settingsLock.lock()
            defer { settingsLock.unlock() }
            return _themePreset
        }
        set {
            settingsLock.lock()
            _themePreset = newValue
            settingsLock.unlock()
            LiveContainerEnvironment.sharedDefaults.set(newValue.rawValue, forKey: Self.themePresetDefaultsKey)
        }
    }

    /// Reloads shared mode & preset preferences written by another LiveContainer instance (`LC 1` / `LC 2`).
    public func refreshPersistedPreferences() {
        let shared = LiveContainerEnvironment.sharedDefaults
        let loadedMode: WebDarkModeBehavior
        if let raw = shared.string(forKey: Self.modeBehaviorDefaultsKey),
           let parsed = WebDarkModeBehavior(rawValue: raw) {
            loadedMode = parsed
        } else {
            let legacyBool = CleanroomBrowserStore.persistedAutoWebPageDarkMode
            loadedMode = legacyBool ? .auto : .off
        }

        let loadedPreset: WebDarkThemePreset
        if let raw = shared.string(forKey: Self.themePresetDefaultsKey),
           let parsed = WebDarkThemePreset(rawValue: raw) {
            loadedPreset = parsed
        } else {
            loadedPreset = .oled
        }

        settingsLock.lock()
        _modeBehavior = loadedMode
        _themePreset = loadedPreset
        settingsLock.unlock()
    }

    /// Returns `true` when the user has paused Auto Dark Mode for `rawHost`.
    public func isHostBypassed(_ rawHost: String?) -> Bool {
        guard let host = Self.normalizeHost(rawHost), !host.isEmpty else { return false }
        bypassLock.lock()
        defer { bypassLock.unlock() }
        return bypassedHostsSet.contains(host)
    }

    /// Toggles per-site Auto Dark Mode pause and persists across `LC 1` / `LC 2` via `sharedDefaults`.
    public func setHostBypassed(_ bypassed: Bool, for rawHost: String?) {
        guard let host = Self.normalizeHost(rawHost), !host.isEmpty else { return }
        bypassLock.lock()
        if bypassed {
            bypassedHostsSet.insert(host)
        } else {
            bypassedHostsSet.remove(host)
        }
        let snapshot = Array(bypassedHostsSet).sorted()
        bypassLock.unlock()
        LiveContainerEnvironment.sharedDefaults.set(snapshot, forKey: Self.bypassedHostsKey)
    }

    /// Clears legacy global auto-dark bypassed hosts once migrated to Default Profile `site_rules`.
    public func clearLegacyBypassedHosts() {
        bypassLock.lock()
        bypassedHostsSet.removeAll(keepingCapacity: false)
        bypassLock.unlock()
    }

    private static let corsFetchSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg)
    }()

    /// Releases all in-memory stylesheet caches, parsed fix structures, mmap index references, and `darkreader.min.js`.
    public func purgeMemoryCache() {
        stylesheetCache.removeAllObjects()
        Self.corsFetchSession.configuration.urlCache?.removeAllCachedResponses()

        validatedHostLock.lock()
        validatedPublicHosts.removeAll(keepingCapacity: false)
        validatedHostLock.unlock()

        darkSitesLock.lock()
        cachedDarkSites = nil
        darkSitesLock.unlock()

        fixesLock.lock()
        cachedFixesIndex = nil
        parsedFixesCache.removeAll(keepingCapacity: false)
        parsedFixesOrder.removeAll(keepingCapacity: false)
        cachedRuntimeJS = nil
        fixesLock.unlock()
    }

    private init() {
        let shared = LiveContainerEnvironment.sharedDefaults
        let standard = UserDefaults.standard
        if shared.stringArray(forKey: Self.bypassedHostsKey) == nil,
           standard !== shared,
           let legacy = standard.stringArray(forKey: Self.bypassedHostsKey) {
            shared.set(legacy, forKey: Self.bypassedHostsKey)
        }
        if let saved = shared.stringArray(forKey: Self.bypassedHostsKey) {
            self.bypassedHostsSet = Set(saved.compactMap { Self.normalizeHost($0) })
        }
        if let rawMode = shared.string(forKey: Self.modeBehaviorDefaultsKey),
           let parsedMode = WebDarkModeBehavior(rawValue: rawMode) {
            self._modeBehavior = parsedMode
        } else {
            let legacyBool = CleanroomBrowserStore.persistedAutoWebPageDarkMode
            self._modeBehavior = legacyBool ? .auto : .off
        }
        if let rawPreset = shared.string(forKey: Self.themePresetDefaultsKey),
           let parsedPreset = WebDarkThemePreset(rawValue: rawPreset) {
            self._themePreset = parsedPreset
        } else {
            self._themePreset = .oled
        }
    }

    /// Returns `true` if `host` is listed in Dark Reader's official `dark-sites.config`
    /// (natively dark websites where Dark Reader should inject 0 KB).
    public func isKnownNativeDarkHost(_ rawHost: String?) -> Bool {
        let index = ensureDarkSitesLoaded()
        return Self.matchesDarkSites(rawHost: rawHost, index: index)
    }

    /// Non-blocking O(1) cache check used on `@MainActor` navigation signature paths.
    /// Triggers background warmup if `dark-sites.config` has not yet been parsed.
    public func isKnownNativeDarkHostIfCached(_ rawHost: String?) -> Bool {
        guard let index = cachedDarkSitesIfReady() else {
            warmDarkSitesInBackgroundIfNeeded()
            return false
        }
        return Self.matchesDarkSites(rawHost: rawHost, index: index)
    }

    /// Returns the merged Dark Reader `DynamicFix` for `host`, or `commonFix` when no site-specific override exists.
    public func dynamicFix(forHost rawHost: String?) -> DynamicFix {
        guard let index = ensureDynamicFixesIndexLoaded() else {
            return DynamicFix()
        }
        let candidates = Self.lookupHostCandidates(for: rawHost)
        guard !candidates.isEmpty else {
            return index.commonFix ?? DynamicFix()
        }

        for candidate in candidates {
            var probe = candidate
            while !probe.isEmpty {
                fixesLock.lock()
                let cachedSiteFix = parsedFixesCache[probe]
                fixesLock.unlock()
                if let cachedSiteFix {
                    return cachedSiteFix.merged(with: index.commonFix)
                }

                if let range = index.rangesByHost[probe] {
                    let parsed = Self.parseSingleDynamicFixBlock(from: index.data[range])
                    fixesLock.lock()
                    if parsedFixesCache[probe] == nil {
                        if parsedFixesOrder.count >= Self.maxParsedFixCacheCount {
                            let oldest = parsedFixesOrder.removeFirst()
                            parsedFixesCache.removeValue(forKey: oldest)
                        }
                        parsedFixesOrder.append(probe)
                        parsedFixesCache[probe] = parsed
                    }
                    fixesLock.unlock()
                    return parsed.merged(with: index.commonFix)
                }

                guard let dot = probe.firstIndex(of: ".") else { break }
                probe = String(probe[probe.index(after: dot)...])
            }
        }
        return index.commonFix ?? DynamicFix()
    }

    /// Builds a lightweight main-frame dark-mode detector + pre-paint guard script.
    /// Zero `darkreader.min.js` bytes are parsed in Light Mode (when behavior is `Auto`), when disabled,
    /// on natively dark sites, or on user-paused sites; never blocks `@MainActor` on asset loading locks.
    public func makeDetectorUserScriptSource(
        forHost rawHost: String?,
        enabled: Bool,
        behavior: WebDarkModeBehavior? = nil,
        preset: WebDarkThemePreset? = nil
    ) -> String? {
        guard enabled, let host = Self.normalizeHost(rawHost), !host.isEmpty else { return nil }
        guard !isHostBypassed(host) else { return nil }

        let activeBehavior = behavior ?? modeBehavior
        let resolvedBehavior: WebDarkModeBehavior = (activeBehavior == .off) ? .auto : activeBehavior
        let activePreset = preset ?? themePreset

        if activePreset.isDarkScheme {
            if let darkSites = cachedDarkSitesIfReady() {
                if Self.matchesDarkSites(rawHost: rawHost, index: darkSites) {
                    return nil
                }
            } else {
                warmDarkSitesInBackgroundIfNeeded()
            }
        }

        let behaviorLiteral = resolvedBehavior == .on ? "on" : "auto"
        let prePaintBG = activePreset.backgroundHex
        let prePaintCS = activePreset.isDarkScheme ? "color-scheme:dark!important;" : ""

        return """
        (function() {
            const isTop = (window === window.top);
            if (!isTop) return;
            if (window.location && (window.location.protocol === 'about:' || window.location.protocol === 'blob:' || window.location.protocol === 'data:')) return;

            const mq = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
            let userEnabled = true;
            let darkBehavior = '\(behaviorLiteral)';
            let lastPostedState = null;
            let activationRequested = false;

            const PRE_STYLE_ID = '__dy_pre_dark';
            function shouldStyleDocument() {
                if (!userEnabled || darkBehavior === 'off') return false;
                if (darkBehavior === 'on') return true;
                return Boolean(mq && mq.matches);
            }
            function installPrePaintGuard() {
                if (!shouldStyleDocument()) return;
                try {
                    if (document.getElementById(PRE_STYLE_ID)) return;
                    const st = document.createElement('style');
                    st.id = PRE_STYLE_ID;
                    st.textContent = 'html{background-color:\(prePaintBG)!important;\(prePaintCS)}';
                    (document.head || document.documentElement).appendChild(st);
                    setTimeout(removePrePaintGuard, 600);
                } catch (_) {}
            }
            function removePrePaintGuard() {
                try {
                    const st = document.getElementById(PRE_STYLE_ID);
                    if (st && st.parentNode) st.parentNode.removeChild(st);
                } catch (_) {}
            }
            installPrePaintGuard();

            function postMsg(payload) {
                try {
                    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(BrowserInjectedScripts.snifferMessageHandlerName);
                    if (h) h.postMessage(payload);
                } catch (_) {}
            }

            function notifyNative(active) {
                if (lastPostedState === active) return;
                lastPostedState = active;
                postMsg({ kind: 'dark-state', active: active });
            }

            \(Self.nativeDarkHeuristicJS)

            let evaluating = false;
            function evaluate(forceReapply) {
                if (evaluating) return;
                evaluating = true;
                try {
                    if (!shouldStyleDocument()) {
                        removePrePaintGuard();
                        if (typeof window.__dysprosiumCleanupDarkSurface === 'function') {
                            window.__dysprosiumCleanupDarkSurface();
                        }
                        if (window.DarkReader && window.DarkReader.isEnabled()) {
                            window.DarkReader.disable();
                        }
                        activationRequested = false;
                        notifyNative(false);
                        return;
                    }

                    const wasEnabled = Boolean(window.DarkReader && window.DarkReader.isEnabled());
                    removePrePaintGuard();
                    if (wasEnabled && !forceReapply) {
                        // Avoid destructive DarkReader disable->enable CSSOM teardown on routine SPA class mutations
                        // (e.g. Wikipedia/React adding 'loaded'/'js-enabled'). Only tear down if the page explicitly
                        // switched into a native dark theme marker or dark color-scheme meta tag.
                        const themeMode = (window.__dysprosiumDarkTheme && typeof window.__dysprosiumDarkTheme.mode === 'number')
                            ? window.__dysprosiumDarkTheme.mode : 1;
                        if (themeMode === 1) {
                            const docEl = document.documentElement;
                            const metaCS = document.querySelector('meta[name="color-scheme"]');
                            const metaContent = (metaCS && metaCS.content) ? metaCS.content.trim().toLowerCase() : '';
                            const switchedToNativeDark = hasDarkMarker(docEl)
                                || hasDarkMarker(document.body)
                                || metaContent === 'dark'
                                || metaContent === 'only dark';
                            if (!switchedToNativeDark) {
                                notifyNative(true);
                                return;
                            }
                            if (typeof window.__dysprosiumCleanupDarkSurface === 'function') {
                                window.__dysprosiumCleanupDarkSurface();
                            }
                            window.DarkReader.disable();
                        } else {
                            notifyNative(true);
                            return;
                        }
                    }

                    const desiredMode = (window.__dysprosiumDarkTheme && typeof window.__dysprosiumDarkTheme.mode === 'number')
                        ? window.__dysprosiumDarkTheme.mode : (\(activePreset.isDarkScheme ? 1 : 0));
                    if (!wasEnabled && desiredMode === 1 && isNativelyDarkDocument()) {
                        activationRequested = false;
                        notifyNative(false);
                        return;
                    }

                    if (window.DarkReader && window.__dysprosiumDarkTheme) {
                        if (typeof window.__dysprosiumCleanupDarkSurface === 'function') {
                            window.__dysprosiumCleanupDarkSurface();
                        }
                        window.DarkReader.enable(window.__dysprosiumDarkTheme, window.__dysprosiumDarkFixes || { disableStyleSheetsProxy: false });
                        if (typeof window.__dysprosiumScheduleDarkRefine === 'function') {
                            window.__dysprosiumScheduleDarkRefine(window.__dysprosiumDarkTheme);
                        }
                        lastPostedState = null;
                        notifyNative(true);
                    } else if (!activationRequested) {
                        activationRequested = true;
                        postMsg({ kind: 'dark-activate' });
                    }
                } catch (err) {
                    removePrePaintGuard();
                    window.__dysprosiumDarkErr = 'eval:' + String(err);
                } finally {
                    evaluating = false;
                }
            }

            window.__dysprosiumSetAutoDark = function(nextEnabled) {
                userEnabled = Boolean(nextEnabled);
                if (userEnabled) activationRequested = false;
                evaluate(false);
            };
            window.__dysprosiumApplyDarkConfig = function(nextEnabled, nextBehavior, nextTheme, nextFixes) {
                userEnabled = Boolean(nextEnabled);
                if (typeof nextBehavior === 'string') darkBehavior = nextBehavior;
                if (nextTheme) window.__dysprosiumDarkTheme = nextTheme;
                if (nextFixes) window.__dysprosiumDarkFixes = nextFixes;
                if (userEnabled) activationRequested = false;
                evaluate(true);
            };
            window.__dysprosiumNotifyDarkActive = function(active) {
                removePrePaintGuard();
                lastPostedState = null;
                notifyNative(Boolean(active));
            };

            if (mq && typeof mq.addEventListener === 'function') {
                mq.addEventListener('change', function() { evaluate(false); });
            }

            let hydrationTimer = null;
            function scheduleReevaluate() {
                if (hydrationTimer) clearTimeout(hydrationTimer);
                hydrationTimer = setTimeout(function() { evaluate(false); }, 180);
            }
            function attachHydrationObserver() {
                if (typeof MutationObserver === 'undefined') return;
                try {
                    const obs = new MutationObserver(function(muts) {
                        for (let i = 0; i < muts.length; i++) {
                            const attr = muts[i].attributeName;
                            if (attr === 'class' || attr === 'data-theme' || attr === 'data-color-scheme' || attr === 'data-color-mode') {
                                scheduleReevaluate();
                                break;
                            }
                        }
                    });
                    if (document.documentElement) {
                        obs.observe(document.documentElement, { attributes: true, attributeFilter: ['class', 'data-theme', 'data-color-scheme', 'data-color-mode'] });
                    }
                    if (document.body) {
                        obs.observe(document.body, { attributes: true, attributeFilter: ['class', 'data-theme', 'data-color-scheme', 'data-color-mode'] });
                    }
                    setTimeout(function() { try { obs.disconnect(); } catch (_) {} }, 5000);
                } catch (_) {}
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', function() {
                    evaluate(false);
                    attachHydrationObserver();
                }, { once: true });
            } else {
                evaluate(false);
                attachHydrationObserver();
            }
            window.addEventListener('load', function() {
                removePrePaintGuard();
                if (lastPostedState === null && !activationRequested) evaluate(false);
                if (window.DarkReader && window.DarkReader.isEnabled() && window.__dysprosiumDarkTheme && typeof window.__dysprosiumScheduleDarkRefine === 'function') {
                    window.__dysprosiumScheduleDarkRefine(window.__dysprosiumDarkTheme);
                }
            }, { once: true });
            window.addEventListener('popstate', scheduleReevaluate);
        })();
        """
    }

    /// Builds the CSP-immune on-demand Dark Reader `4.9.135` activation script evaluated via
    /// `WKWebView.evaluateJavaScript` ONLY after the lightweight detector confirms styling should activate.
    public func makeActivationScript(
        forHost rawHost: String?,
        preset: WebDarkThemePreset? = nil
    ) -> String? {
        let runtimeJS = ensureRuntimeJSLoaded()
        guard !runtimeJS.isEmpty else { return nil }
        let activePreset = preset ?? themePreset
        let fixJSON = dynamicFix(forHost: rawHost).toJSONLiteral(preset: activePreset)
        let themeJSON = activePreset.themeJSONLiteral
        return """
        (function() {
            try {
                const THEME = \(themeJSON);
                const FIXES = \(fixJSON);
                window.__dysprosiumDarkTheme = THEME;
                window.__dysprosiumDarkFixes = FIXES;
                \(Self.surfaceRefinementJS)
                if (!window.DarkReader) {
                    \(runtimeJS)
                }
                if (window.DarkReader && typeof window.DarkReader.setFetchMethod === 'function' && !window.__dysprosiumFetchHooked) {
                    window.__dysprosiumFetchHooked = true;
                    window.DarkReader.setFetchMethod(function(url) {
                        try {
                            const resolved = new URL(String(url), window.location.href);
                            if (resolved.origin === window.location.origin) {
                                return window.fetch(resolved.href, { cache: 'force-cache' });
                            }
                        } catch (_) {}
                        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.fetchMessageHandlerName);
                        if (!handler) return window.fetch(url);
                        return handler.postMessage({ url: String(url) }).then(function(resp) {
                            if (!resp || !resp.ok) {
                                return new Response('', { status: (resp && resp.status) || 502 });
                            }
                            const headers = new Headers();
                            if (resp.contentType) headers.set('content-type', resp.contentType);
                            return new Response(resp.text || '', { status: resp.status || 200, headers: headers });
                        }).catch(function() {
                            return window.fetch(url);
                        });
                    });
                }
                if (window.DarkReader) {
                    if (typeof window.__dysprosiumCleanupDarkSurface === 'function') {
                        window.__dysprosiumCleanupDarkSurface();
                    }
                    window.DarkReader.enable(THEME, FIXES);
                    if (typeof window.__dysprosiumScheduleDarkRefine === 'function') {
                        window.__dysprosiumScheduleDarkRefine(THEME);
                    }
                    if (typeof window.__dysprosiumNotifyDarkActive === 'function') {
                        window.__dysprosiumNotifyDarkActive(true);
                    }
                }
            } catch (err) {
                window.__dysprosiumDarkErr = 'activate:' + String(err);
            }
        })();
        """
    }

    /// Builds an in-place live configuration update snippet evaluated on an active `WKWebView`
    /// when toggling mode (`Auto / On / Off`), switching presets (`OLED / Obsidian / Graphite / Paper`),
    /// or flipping per-site dark mode. Returns `"ok"` if handled live or `"missing"` if detector is absent.
    public func makeLiveConfigUpdateScript(
        forHost rawHost: String?,
        enabled: Bool,
        behavior: WebDarkModeBehavior? = nil,
        preset: WebDarkThemePreset? = nil
    ) -> String {
        let activeBehavior = behavior ?? modeBehavior
        let resolvedBehavior: WebDarkModeBehavior = enabled ? (activeBehavior == .off ? .auto : activeBehavior) : .off
        let activePreset = preset ?? themePreset
        let fixJSON = dynamicFix(forHost: rawHost).toJSONLiteral(preset: activePreset)
        let themeJSON = activePreset.themeJSONLiteral
        let enabledLit = enabled ? "true" : "false"
        let behaviorLit = resolvedBehavior.rawValue
        return """
        (function() {
            if (typeof window.__dysprosiumApplyDarkConfig === 'function') {
                window.__dysprosiumApplyDarkConfig(\(enabledLit), '\(behaviorLit)', \(themeJSON), \(fixJSON));
                return 'ok';
            }
            if (typeof window.__dysprosiumSetAutoDark === 'function') {
                window.__dysprosiumSetAutoDark(\(enabledLit));
                return 'ok';
            }
            return 'missing';
        })()
        """
    }

    /// Thin compatibility wrapper for `RangeEngineTests` verifying self-contained Dark Reader Dynamic Mode in `WKWebView`.
    public func makeUserScriptSource(
        forHost rawHost: String?,
        enabled: Bool,
        preset: WebDarkThemePreset? = nil
    ) -> String? {
        guard enabled, let host = Self.normalizeHost(rawHost), !host.isEmpty else { return nil }
        let activePreset = preset ?? themePreset
        if activePreset.isDarkScheme, isKnownNativeDarkHost(rawHost) {
            return nil
        }
        let runtimeJS = ensureRuntimeJSLoaded()
        guard !runtimeJS.isEmpty else { return nil }
        let fixJSON = dynamicFix(forHost: rawHost).toJSONLiteral(preset: activePreset)
        let themeJSON = activePreset.themeJSONLiteral
        return """
        (function() {
            if (window !== window.top) return;
            if (window.location && (window.location.protocol === 'about:' || window.location.protocol === 'blob:')) return;

            const THEME = \(themeJSON);
            const FIXES = \(fixJSON);
            const mq = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
            let userEnabled = true;
            let drLoaded = false;
            let lastPostedState = null;

            \(Self.surfaceRefinementJS)

            function notifyNative(active) {
                if (lastPostedState === active) return;
                lastPostedState = active;
                try {
                    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(BrowserInjectedScripts.snifferMessageHandlerName);
                    if (h) h.postMessage({ kind: 'dark-state', active: active });
                } catch (_) {}
            }

            function ensureDarkReaderLoaded() {
                if (drLoaded && window.DarkReader) return true;
                try {
                    \(runtimeJS)
                    if (window.DarkReader && typeof window.DarkReader.setFetchMethod === 'function') {
                        window.DarkReader.setFetchMethod(function(url) {
                            try {
                                const resolved = new URL(String(url), window.location.href);
                                if (resolved.origin === window.location.origin) {
                                    return window.fetch(resolved.href, { cache: 'force-cache' });
                                }
                            } catch (_) {}
                            const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.fetchMessageHandlerName);
                            if (!handler) return window.fetch(url);
                            return handler.postMessage({ url: String(url) }).then(function(resp) {
                                if (!resp || !resp.ok) {
                                    return new Response('', { status: (resp && resp.status) || 502 });
                                }
                                const headers = new Headers();
                                if (resp.contentType) headers.set('content-type', resp.contentType);
                                return new Response(resp.text || '', { status: resp.status || 200, headers: headers });
                            }).catch(function() {
                                return window.fetch(url);
                            });
                        });
                    }
                    drLoaded = Boolean(window.DarkReader);
                } catch (err) {
                    window.__dysprosiumDarkErr = 'load:' + String(err);
                    drLoaded = false;
                }
                return drLoaded;
            }

            \(Self.nativeDarkHeuristicJS)

            let evaluating = false;
            function evaluate() {
                if (evaluating) return;
                evaluating = true;
                try {
                    const systemDark = mq ? mq.matches : false;
                    if (!userEnabled || !systemDark) {
                        if (typeof window.__dysprosiumCleanupDarkSurface === 'function') {
                            window.__dysprosiumCleanupDarkSurface();
                        }
                        if (drLoaded && window.DarkReader && window.DarkReader.isEnabled()) {
                            window.DarkReader.disable();
                        }
                        notifyNative(false);
                        return;
                    }
                    if (drLoaded && window.DarkReader && window.DarkReader.isEnabled()) {
                        if (typeof window.__dysprosiumCleanupDarkSurface === 'function') {
                            window.__dysprosiumCleanupDarkSurface();
                        }
                        window.DarkReader.disable();
                    }
                    if (THEME.mode === 1 && isNativelyDarkDocument()) {
                        notifyNative(false);
                        return;
                    }
                    if (ensureDarkReaderLoaded()) {
                        window.DarkReader.enable(THEME, FIXES);
                        if (typeof window.__dysprosiumScheduleDarkRefine === 'function') {
                            window.__dysprosiumScheduleDarkRefine(THEME);
                        }
                        notifyNative(true);
                    }
                } catch (err) {
                    window.__dysprosiumDarkErr = 'eval:' + String(err);
                } finally {
                    evaluating = false;
                }
            }

            window.__dysprosiumSetAutoDark = function(nextEnabled) {
                userEnabled = Boolean(nextEnabled);
                evaluate();
            };

            if (mq && typeof mq.addEventListener === 'function') {
                mq.addEventListener('change', evaluate);
            }
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', evaluate, { once: true });
            } else {
                evaluate();
            }
            window.addEventListener('load', function() {
                if (lastPostedState === null) evaluate();
            }, { once: true });
        })();
        """
    }

    /// Reversible, zero-canvas, computed-style refinement pass complementing Dark Reader 4.9.135:
    /// 1. Darkens leaked bright neutral stops inside CSS-var gradients (e.g. Tailwind v4 `linear-gradient(..., #fff, rgba(var(--accent-rgb), .08))`)
    ///    while preserving chromatic accent tints and gradient geometry.
    /// 2. Adapts dark monochrome same-origin `<img src="*.svg">` brand logos via `invert(1) hue-rotate(180deg)` (text turns crisp white,
    ///    brand accent colors retain their true hue) by inspecting SVG text fills with zero `<canvas>` readback.
    /// 3. Restores contrast on CSS-drawn dark hamburger/menu icon bars (`<= 4.5px` spans inside dark header buttons).
    private static let surfaceRefinementJS = """
            if (!window.__dysprosiumRefineInstalled) {
                window.__dysprosiumRefineInstalled = true;
                const REFINE_STYLE_ID = '__dy_dark_refine';
                const svgDecisionCache = new Map();
                let refineTimer = null;
                let refineSecondTimer = null;

                function dyParseRGBA(str) {
                    if (!str || str === 'transparent') return { r: 0, g: 0, b: 0, a: 0 };
                    const m = str.match(/rgba?\\(\\s*([\\d.]+)[,\\s]+([\\d.]+)[,\\s]+([\\d.]+)(?:[,/\\s]+([\\d.]+))?\\s*\\)/i);
                    if (!m) return null;
                    return { r: Number(m[1]), g: Number(m[2]), b: Number(m[3]), a: m[4] === undefined ? 1 : Number(m[4]) };
                }
                function dyRGBToSL(r, g, b) {
                    const rn = r / 255, gn = g / 255, bn = b / 255;
                    const max = Math.max(rn, gn, bn), min = Math.min(rn, gn, bn);
                    const l = (max + min) * 0.5;
                    const d = max - min;
                    const s = d === 0 ? 0 : d / (1 - Math.abs(2 * l - 1));
                    return { s: s, l: l };
                }
                function dyHexToRGB(token) {
                    if (!token) return null;
                    const t = token.trim().toLowerCase();
                    if (t === 'black') return { r: 0, g: 0, b: 0 };
                    if (t === 'white') return { r: 255, g: 255, b: 255 };
                    if (t.startsWith('#')) {
                        const h = t.slice(1);
                        if (h.length === 3 || h.length === 4) {
                            return { r: parseInt(h[0] + h[0], 16), g: parseInt(h[1] + h[1], 16), b: parseInt(h[2] + h[2], 16) };
                        }
                        if (h.length === 6 || h.length === 8) {
                            return { r: parseInt(h.slice(0, 2), 16), g: parseInt(h.slice(2, 4), 16), b: parseInt(h.slice(4, 6), 16) };
                        }
                    }
                    const rgba = dyParseRGBA(t);
                    return rgba ? { r: rgba.r, g: rgba.g, b: rgba.b } : null;
                }
                function dyEffectiveBgLightness(el) {
                    let cur = el;
                    while (cur && cur.nodeType === 1) {
                        const c = dyParseRGBA(getComputedStyle(cur).backgroundColor);
                        if (c && c.a >= 0.45) {
                            return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255;
                        }
                        cur = cur.parentElement;
                    }
                    return 0.05;
                }
                function dyAnalyzeSVGText(svgText) {
                    if (!svgText || svgText.length > 131072) return false;
                    const rootMatch = svgText.match(/<svg\\b[^>]*>/i);
                    const rootFillNone = rootMatch ? /\\bfill\\s*=\\s*['"]none['"]/i.test(rootMatch[0]) : false;
                    let darkNeutral = 0;
                    let lightNeutral = 0;

                    function classifyColor(raw) {
                        const val = raw.trim().toLowerCase();
                        if (!val || val === 'none' || val === 'transparent' || val === 'currentcolor' || val.startsWith('url(')) return;
                        const rgb = dyHexToRGB(val);
                        if (!rgb || Number.isNaN(rgb.r)) return;
                        const sl = dyRGBToSL(rgb.r, rgb.g, rgb.b);
                        if (sl.l < 0.28 && sl.s < 0.25) darkNeutral++;
                        else if (sl.l > 0.72 && sl.s < 0.25) lightNeutral++;
                    }

                    const attrRe = /\\b(?:fill|stroke)\\s*=\\s*['"]([^'"]+)['"]/gi;
                    let m;
                    while ((m = attrRe.exec(svgText)) !== null) classifyColor(m[1]);
                    const cssRe = /\\b(?:fill|stroke)\\s*:\\s*([^;'"\\}]+)/gi;
                    while ((m = cssRe.exec(svgText)) !== null) classifyColor(m[1]);

                    if (darkNeutral === 0 && lightNeutral === 0 && !rootFillNone) {
                        if (/<(?:path|text|rect|circle|polygon|polyline|ellipse)\\b/i.test(svgText)) {
                            darkNeutral = 1;
                        }
                    }
                    return darkNeutral > 0 && lightNeutral === 0;
                }
                function dyEnsureRefineStyle(textColor) {
                    const parent = document.head || document.documentElement;
                    let st = document.getElementById(REFINE_STYLE_ID);
                    if (!st) {
                        st = document.createElement('style');
                        st.id = REFINE_STYLE_ID;
                        st.className = 'darkreader';
                    }
                    const ink = textColor || '#f2f2f7';
                    st.textContent =
                        'html body [data-dy-grad="1"][data-dy-grad="1"]{background-image:var(--dy-grad-img)!important;}' +
                        'html body [data-dy-grad-bg="1"][data-dy-grad-bg="1"]{background-color:var(--dy-grad-bg)!important;}' +
                        'html body img[data-dy-dark-svg="1"][data-dy-dark-svg="1"]{filter:invert(1) hue-rotate(180deg)!important;}' +
                        'html body [data-dy-dark-bar="1"][data-dy-dark-bar="1"]{background-color:' + ink + '!important;}';
                    if (parent && parent.lastElementChild !== st) {
                        parent.appendChild(st);
                    }
                }

                window.__dysprosiumCleanupDarkSurface = function() {
                    if (refineTimer) { clearTimeout(refineTimer); refineTimer = null; }
                    if (refineSecondTimer) { clearTimeout(refineSecondTimer); refineSecondTimer = null; }
                    try {
                        const st = document.getElementById(REFINE_STYLE_ID);
                        if (st && st.parentNode) st.parentNode.removeChild(st);
                        const marked = document.querySelectorAll('[data-dy-grad],[data-dy-grad-bg],[data-dy-dark-svg],[data-dy-dark-bar]');
                        for (let i = 0; i < marked.length; i++) {
                            const el = marked[i];
                            el.removeAttribute('data-dy-grad');
                            el.removeAttribute('data-dy-grad-bg');
                            el.removeAttribute('data-dy-dark-svg');
                            el.removeAttribute('data-dy-dark-bar');
                            el.style.removeProperty('--dy-grad-img');
                            el.style.removeProperty('--dy-grad-bg');
                        }
                    } catch (_) {}
                };

                function dyRunRefinePass(theme) {
                    if (!theme || theme.mode !== 1) return;
                    if (!window.DarkReader || !window.DarkReader.isEnabled()) return;
                    if (!document.body) return;

                    const baseRGB = Array.isArray(theme._dyBaseRGB) ? theme._dyBaseRGB : [0, 0, 0];
                    const elevRGB = Array.isArray(theme._dyElevRGB) ? theme._dyElevRGB : [12, 13, 15];
                    const textInk = theme.darkSchemeTextColor || '#f2f2f7';
                    dyEnsureRefineStyle(textInk);

                    const baseCss = 'rgb(' + baseRGB[0] + ', ' + baseRGB[1] + ', ' + baseRGB[2] + ')';
                    const skipTags = { IMG:1, VIDEO:1, CANVAS:1, SVG:1, PATH:1, SCRIPT:1, STYLE:1, NOSCRIPT:1, LINK:1, META:1, IFRAME:1, CODE:1, PRE:1 };

                    // 1. Leaked bright CSS gradients (e.g. Tailwind v4 var() + linear-gradient(..., #fff))
                    try {
                        const all = document.body.getElementsByTagName('*');
                        const limit = Math.min(all.length, 1400);
                        for (let i = 0; i < limit; i++) {
                            const el = all[i];
                            if (skipTags[el.tagName] || el.hasAttribute('data-dy-grad')) continue;
                            const cs = getComputedStyle(el);
                            const bgImg = cs.backgroundImage;
                            if (!bgImg || bgImg === 'none' || bgImg.indexOf('gradient(') === -1) continue;
                            const rect = el.getBoundingClientRect();
                            if (rect.width < 48 || rect.height < 28) continue;
                            if ((el.tagName === 'BUTTON' || el.tagName === 'A') && rect.width < 260 && rect.height < 64) continue;

                            let mutated = false;
                            const remapped = bgImg.replace(/rgba?\\(\\s*([\\d.]+)\\s*,\\s*([\\d.]+)\\s*,\\s*([\\d.]+)(?:\\s*,\\s*([\\d.]+))?\\s*\\)/gi, function(full, rStr, gStr, bStr, aStr) {
                                const r = Number(rStr), g = Number(gStr), b = Number(bStr);
                                const a = aStr === undefined ? 1 : Number(aStr);
                                if (a <= 0.01) return full;
                                const sl = dyRGBToSL(r, g, b);
                                if (sl.l > 0.72 && sl.s < 0.25) {
                                    mutated = true;
                                    const target = a < 0.75 ? baseRGB : elevRGB;
                                    return a < 0.999
                                        ? ('rgba(' + target[0] + ', ' + target[1] + ', ' + target[2] + ', ' + a + ')')
                                        : ('rgb(' + target[0] + ', ' + target[1] + ', ' + target[2] + ')');
                                }
                                return full;
                            });
                            if (mutated) {
                                el.style.setProperty('--dy-grad-img', remapped);
                                el.setAttribute('data-dy-grad', '1');
                                const bgC = dyParseRGBA(cs.backgroundColor);
                                if (bgC && bgC.a > 0.2) {
                                    const slBG = dyRGBToSL(bgC.r, bgC.g, bgC.b);
                                    if (slBG.l > 0.72 && slBG.s < 0.25) {
                                        el.style.setProperty('--dy-grad-bg', baseCss);
                                        el.setAttribute('data-dy-grad-bg', '1');
                                    }
                                }
                            }
                        }
                    } catch (_) {}

                    // 2. Dark monochrome same-origin SVG <img> brand logos
                    try {
                        const imgs = document.querySelectorAll('img[src]');
                        let checked = 0;
                        for (let i = 0; i < imgs.length && checked < 32; i++) {
                            const img = imgs[i];
                            if (img.hasAttribute('data-dy-dark-svg')) continue;
                            const src = img.currentSrc || img.src || '';
                            if (!src) continue;
                            const isDataSVG = src.startsWith('data:image/svg+xml');
                            let isSameOriginSVG = false;
                            if (!isDataSVG) {
                                try {
                                    const u = new URL(src, window.location.href);
                                    if (u.origin === window.location.origin && u.pathname.toLowerCase().endsWith('.svg')) {
                                        isSameOriginSVG = true;
                                    }
                                } catch (_) {}
                            }
                            if (!isDataSVG && !isSameOriginSVG) continue;
                            checked++;

                            const rect = img.getBoundingClientRect();
                            if (rect.width < 12 || rect.height < 10 || rect.width > 380 || rect.height > 96) continue;
                            const cs = getComputedStyle(img);
                            if (cs.filter && cs.filter.indexOf('invert(') !== -1) continue;
                            if (dyEffectiveBgLightness(img.parentElement) >= 0.35) continue;

                            if (svgDecisionCache.has(src)) {
                                if (svgDecisionCache.get(src)) img.setAttribute('data-dy-dark-svg', '1');
                                continue;
                            }
                            if (isDataSVG) {
                                let rawSVG = '';
                                const comma = src.indexOf(',');
                                if (comma > 0) {
                                    const body = src.slice(comma + 1);
                                    rawSVG = src.slice(0, comma).includes('base64') ? atob(body) : decodeURIComponent(body);
                                }
                                const shouldInvert = dyAnalyzeSVGText(rawSVG);
                                svgDecisionCache.set(src, shouldInvert);
                                if (shouldInvert) img.setAttribute('data-dy-dark-svg', '1');
                            } else {
                                (function(targetImg, targetSrc) {
                                    window.fetch(targetSrc, { cache: 'force-cache' }).then(function(r) {
                                        return r && r.ok ? r.text() : '';
                                    }).then(function(txt) {
                                        const shouldInvert = dyAnalyzeSVGText(txt);
                                        svgDecisionCache.set(targetSrc, shouldInvert);
                                        if (shouldInvert && window.DarkReader && window.DarkReader.isEnabled() && window.__dysprosiumDarkTheme && window.__dysprosiumDarkTheme.mode === 1) {
                                            targetImg.setAttribute('data-dy-dark-svg', '1');
                                        }
                                    }).catch(function() {});
                                })(img, src);
                            }
                        }
                    } catch (_) {}

                    // 3. CSS-drawn dark hamburger / menu icon bars inside dark header/nav buttons
                    try {
                        const btns = document.querySelectorAll('header button, nav button, header [role="button"], nav [role="button"]');
                        const maxBtns = Math.min(btns.length, 30);
                        for (let i = 0; i < maxBtns; i++) {
                            const btn = btns[i];
                            if ((btn.textContent || '').trim().length > 0) continue;
                            const br = btn.getBoundingClientRect();
                            if (br.width < 12 || br.width > 60 || br.height < 12 || br.height > 60) continue;
                            if (dyEffectiveBgLightness(btn) >= 0.30) continue;
                            const spans = btn.querySelectorAll('span, div');
                            for (let j = 0; j < spans.length; j++) {
                                const bar = spans[j];
                                if ((bar.textContent || '').trim().length > 0) continue;
                                const r = bar.getBoundingClientRect();
                                const isHorizBar = r.height >= 1 && r.height <= 4.5 && r.width >= 10;
                                const isVertBar = r.width >= 1 && r.width <= 4.5 && r.height >= 10;
                                if (!isHorizBar && !isVertBar) continue;
                                const c = dyParseRGBA(getComputedStyle(bar).backgroundColor);
                                if (!c || c.a < 0.5) continue;
                                const lum = (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255;
                                if (lum < 0.30) {
                                    bar.setAttribute('data-dy-dark-bar', '1');
                                }
                            }
                        }
                    } catch (_) {}
                }

                window.__dysprosiumScheduleDarkRefine = function(theme) {
                    if (refineTimer) clearTimeout(refineTimer);
                    if (refineSecondTimer) clearTimeout(refineSecondTimer);
                    if (!theme || theme.mode !== 1) return;
                    refineTimer = setTimeout(function() {
                        dyRunRefinePass(theme);
                    }, 30);
                    refineSecondTimer = setTimeout(function() {
                        dyRunRefinePass(theme);
                    }, 420);
                };
            }
    """

    private static let nativeDarkHeuristicJS = """
            function parseRGBA(str) {
                if (!str || str === 'transparent') return { r: 0, g: 0, b: 0, a: 0 };
                const m = str.match(/rgba?\\(\\s*([\\d.]+)[,\\s]+([\\d.]+)[,\\s]+([\\d.]+)(?:[,/\\s]+([\\d.]+))?\\s*\\)/i);
                if (!m) return null;
                return { r: Number(m[1]), g: Number(m[2]), b: Number(m[3]), a: m[4] === undefined ? 1 : Number(m[4]) };
            }

            function lightness(r, g, b) {
                return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
            }

            function hasDarkMarker(el) {
                if (!el) return false;
                if (el.hasAttribute && (el.hasAttribute('dark') || el.getAttribute('data-dark-mode') === 'true')) return true;
                const ds = el.dataset || {};
                const v = String(ds.theme || ds.colorMode || ds.bsTheme || ds.scheme || ds.colorScheme || '').toLowerCase();
                if (v.includes('dark') || v.includes('night') || v.includes('black')) return true;
                const cls = typeof el.className === 'string' ? el.className.toLowerCase() : '';
                return /(?:^|\\s)(?:dark|dark-mode|dark_mode|theme-dark|night|night-mode|skin-theme-clientpref-night)(?:\\s|$)/.test(cls);
            }

            function sampleEffectiveBgLightness(el) {
                let cur = el;
                while (cur && cur.nodeType === 1) {
                    const c = parseRGBA(getComputedStyle(cur).backgroundColor);
                    if (c && c.a >= 0.45) return lightness(c.r, c.g, c.b);
                    cur = cur.parentElement;
                }
                return null;
            }

            function isNativelyDarkDocument() {
                const docEl = document.documentElement;
                if (!docEl) return false;
                if (hasDarkMarker(docEl) || hasDarkMarker(document.body)) return true;

                const meta = document.querySelector('meta[name="color-scheme"]');
                if (meta && meta.content) {
                    const c = meta.content.trim().toLowerCase();
                    if (c === 'dark' || c === 'only dark') return true;
                }

                const rootCS = getComputedStyle(docEl);
                if (rootCS.colorScheme === 'dark') return true;
                if (!document.body) return false;

                const rootBg = parseRGBA(rootCS.backgroundColor) || { r: 0, g: 0, b: 0, a: 0 };
                const bodyCS = getComputedStyle(document.body);
                const bodyBg = parseRGBA(bodyCS.backgroundColor) || { r: 0, g: 0, b: 0, a: 0 };

                if (rootBg.a >= 0.5 || bodyBg.a >= 0.5) {
                    const rl = (1 - rootBg.a) + rootBg.a * lightness(rootBg.r, rootBg.g, rootBg.b);
                    const fl = (1 - bodyBg.a) * rl + bodyBg.a * lightness(bodyBg.r, bodyBg.g, bodyBg.b);
                    return fl < 0.46;
                }

                if (innerWidth > 40 && innerHeight > 80) {
                    const pts = [
                        [Math.floor(innerWidth * 0.5), Math.min(180, Math.floor(innerHeight * 0.25))],
                        [Math.floor(innerWidth * 0.5), Math.floor(innerHeight * 0.6)]
                    ];
                    let darkHits = 0;
                    let validHits = 0;
                    for (let i = 0; i < pts.length; i++) {
                        const hit = document.elementFromPoint(pts[i][0], pts[i][1]);
                        if (hit && hit !== docEl && hit !== document.body) {
                            const lum = sampleEffectiveBgLightness(hit);
                            if (lum !== null) {
                                validHits++;
                                if (lum < 0.42) darkHits++;
                            }
                        }
                    }
                    if (validHits > 0 && darkHits === validHits) return true;
                }

                if (rootBg.a < 0.1 && bodyBg.a < 0.1) {
                    const txt = parseRGBA(bodyCS.color) || parseRGBA(rootCS.color);
                    if (txt && lightness(txt.r, txt.g, txt.b) > 0.68) return true;
                }
                return false;
            }
    """

    /// Fulfills cross-origin CSS stylesheet fetches requested by Dark Reader Dynamic Mode
    /// via `WKScriptMessageHandlerWithReply` using an ephemeral, cookieless session,
    /// strict `text/css` MIME verification, and SSRF validation on initial URL + redirects.
    public func handleCrossOriginStylesheetFetch(urlString: String) async -> [String: Any] {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return ["ok": false, "status": 400]
        }

        // Fast-path reject binary image/font URLs before touching DNS or the network.
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "webp", "gif", "avif", "ico", "bmp", "woff", "woff2", "ttf", "otf", "mp4", "webm", "svg", "html", "json", "xml"].contains(ext) {
            return ["ok": false, "status": 415]
        }

        // Fast-path in-memory cache hit BEFORE running DNS `getaddrinfo()` (only validated public URLs are cached).
        if let cached = stylesheetCache.object(forKey: urlString) {
            return FetchReply(
                ok: true,
                status: 200,
                contentType: cached.contentType,
                text: cached.text,
                cacheable: true
            ).toDictionary()
        }

        // Short-TTL host validation cache avoids running 10+ synchronous `getaddrinfo()` DNS lookups
        // when a page loads multiple stylesheets from the same CDN host (redirects still re-validate live).
        let normalizedHost = url.host(percentEncoded: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let hostAlreadyValidated = !normalizedHost.isEmpty
            && url.user == nil
            && url.password == nil
            && isValidatedPublicHostCached(normalizedHost)

        if !hostAlreadyValidated {
            let isAllowed = await Task.detached(priority: .userInitiated) {
                Self.isAllowedPublicStylesheetURL(url)
            }.value
            guard isAllowed else {
                return ["ok": false, "status": 403]
            }
            if !normalizedHost.isEmpty {
                recordValidatedPublicHost(normalizedHost)
            }
        }

        let cache = stylesheetCache
        let reply = await fetchCoordinator.fetch(urlString: urlString) {
            if let cached = cache.object(forKey: urlString) {
                return FetchReply(
                    ok: true,
                    status: 200,
                    contentType: cached.contentType,
                    text: cached.text,
                    cacheable: true
                )
            }

            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
            request.setValue("text/css,*/*;q=0.1", forHTTPHeaderField: "Accept")
            request.setValue(HLSStreamEngine.iosSafariUserAgent, forHTTPHeaderField: "User-Agent")

            let task = Self.corsFetchSession.dataTask(with: request)
            let delegate = BoundedCSSFetchDelegate(maxBytes: Self.maxStylesheetBytes)
            task.delegate = delegate
            let fetched = await delegate.awaitResult(for: task)
            _ = delegate
            if fetched.ok, fetched.cacheable, let text = fetched.text {
                let entry = CachedStylesheet(contentType: fetched.contentType ?? "text/css; charset=utf-8", text: text)
                cache.setObject(entry, forKey: urlString, cost: text.utf8.count)
            }
            return fetched
        }
        return reply.toDictionary()
    }

    // MARK: - SSRF Protection (Public IP / Redirect / Host Validation)

    private func isValidatedPublicHostCached(_ normalizedHost: String) -> Bool {
        let now = ContinuousClock.now
        validatedHostLock.lock()
        defer { validatedHostLock.unlock() }
        guard let expiry = validatedPublicHosts[normalizedHost] else { return false }
        if now < expiry { return true }
        validatedPublicHosts.removeValue(forKey: normalizedHost)
        return false
    }

    private func recordValidatedPublicHost(_ normalizedHost: String) {
        let expiry = ContinuousClock.now + Self.validatedHostTTL
        validatedHostLock.lock()
        if validatedPublicHosts.count >= 64 {
            validatedPublicHosts.removeAll(keepingCapacity: true)
        }
        validatedPublicHosts[normalizedHost] = expiry
        validatedHostLock.unlock()
    }

    public nonisolated static func isAllowedPublicStylesheetURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil,
              url.password == nil,
              var rawHost = url.host(percentEncoded: false)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              !rawHost.isEmpty else {
            return false
        }

        if rawHost.hasPrefix("[") && rawHost.hasSuffix("]") {
            rawHost = String(rawHost.dropFirst().dropLast())
        }
        rawHost = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !rawHost.isEmpty, !rawHost.contains("%") else {
            return false
        }

        if rawHost == "localhost"
            || rawHost == "ip6-localhost"
            || rawHost == "ip6-loopback"
            || rawHost.hasSuffix(".localhost")
            || rawHost.hasSuffix(".local")
            || rawHost.hasSuffix(".localdomain")
            || rawHost.hasSuffix(".internal")
            || rawHost.hasSuffix(".home.arpa") {
            return false
        }

        // Reject bare single-label intranet hostnames (unless IPv6 literal with ':')
        guard rawHost.contains(".") || rawHost.contains(":") else {
            return false
        }

        var addr4 = in_addr()
        if rawHost.withCString({ inet_pton(AF_INET, $0, &addr4) }) == 1 {
            return isPublicIPv4(addr4)
        }
        var addr6 = in6_addr()
        if rawHost.withCString({ inet_pton(AF_INET6, $0, &addr6) }) == 1 {
            return isPublicIPv6(addr6)
        }
        // Reject alternate numeric IPv4 encodings (decimal integer, hex 0x7f000001, octal 0177.0.0.1, shorthand 127.1)
        if rawHost.withCString({ inet_aton($0, &addr4) }) != 0 {
            return isPublicIPv4(addr4)
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard rawHost.withCString({ getaddrinfo($0, nil, &hints, &result) }) == 0,
              let first = result else {
            return false
        }
        defer { freeaddrinfo(first) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var sawAddress = false
        while let info = cursor {
            if info.pointee.ai_family == AF_INET, let sa = info.pointee.ai_addr {
                let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                guard isPublicIPv4(addr) else { return false }
                sawAddress = true
            } else if info.pointee.ai_family == AF_INET6, let sa = info.pointee.ai_addr {
                let addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                guard isPublicIPv6(addr) else { return false }
                sawAddress = true
            }
            cursor = info.pointee.ai_next
        }
        return sawAddress
    }

    private nonisolated static func isPublicIPv4(_ addr: in_addr) -> Bool {
        let ip = UInt32(bigEndian: addr.s_addr)
        if (ip & 0xFF00_0000) == 0x0000_0000 { return false } // 0.0.0.0/8 (This network)
        if (ip & 0xFF00_0000) == 0x0A00_0000 { return false } // 10.0.0.0/8 (RFC 1918)
        if (ip & 0xFFC0_0000) == 0x6440_0000 { return false } // 100.64.0.0/10 (CGNAT RFC 6598)
        if (ip & 0xFF00_0000) == 0x7F00_0000 { return false } // 127.0.0.0/8 (Loopback)
        if (ip & 0xFFFF_0000) == 0xA9FE_0000 { return false } // 169.254.0.0/16 (Link-local / Cloud metadata)
        if (ip & 0xFFF0_0000) == 0xAC10_0000 { return false } // 172.16.0.0/12 (RFC 1918)
        if (ip & 0xFFFF_FF00) == 0xC000_0000 { return false } // 192.0.0.0/24 (IETF protocol)
        if (ip & 0xFFFF_FF00) == 0xC000_0200 { return false } // 192.0.2.0/24 (TEST-NET-1)
        if (ip & 0xFFFF_0000) == 0xC0A8_0000 { return false } // 192.168.0.0/16 (RFC 1918)
        if (ip & 0xFFFE_0000) == 0xC612_0000 { return false } // 198.18.0.0/15 (Benchmarking)
        if (ip & 0xFFFF_FF00) == 0xC633_6400 { return false } // 198.51.100.0/24 (TEST-NET-2)
        if (ip & 0xFFFF_FF00) == 0xCB00_7100 { return false } // 203.0.113.0/24 (TEST-NET-3)
        if (ip & 0xE000_0000) == 0xE000_0000 { return false } // 224.0.0.0/3 (Multicast / Reserved / Broadcast)
        return true
    }

    private nonisolated static func isPublicIPv6(_ addr: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        guard bytes.count == 16 else { return false }

        // Unspecified (::) and Loopback (::1)
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && (bytes[15] == 0 || bytes[15] == 1) {
            return false
        }
        // IPv4-mapped (::ffff:0:0/96) and IPv4-compatible (::/96)
        if bytes[0..<10].allSatisfy({ $0 == 0 }) &&
           ((bytes[10] == 0xFF && bytes[11] == 0xFF) || (bytes[10] == 0x00 && bytes[11] == 0x00)) {
            let v4 = in_addr(s_addr: UInt32(bigEndian:
                (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
            ))
            return isPublicIPv4(v4)
        }
        // NAT64 (64:ff9b::/96 and 64:ff9b:1::/48)
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xFF && bytes[3] == 0x9B {
            if bytes[4] == 0x00 && bytes[5] == 0x01 { return false } // local-use NAT64
            let v4 = in_addr(s_addr: UInt32(bigEndian:
                (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
            ))
            return isPublicIPv4(v4)
        }
        // ULA (fc00::/7)
        if (bytes[0] & 0xFE) == 0xFC { return false }
        // Link-local (fe80::/10)
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return false }
        // Deprecated site-local (fec0::/10)
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0xC0 { return false }
        // Multicast (ff00::/8)
        if bytes[0] == 0xFF { return false }
        // Documentation (2001:db8::/32)
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8 { return false }
        return true
    }

    // MARK: - Bundle Loading & Lock-Free Lazy Compact Indexing

    private func cachedDarkSitesIfReady() -> DarkSitesIndex? {
        darkSitesLock.lock()
        defer { darkSitesLock.unlock() }
        return cachedDarkSites
    }

    public func warmDarkSitesInBackgroundIfNeeded() {
        darkSitesLock.lock()
        let shouldStart = (cachedDarkSites == nil && !isWarmingDarkSites)
        if shouldStart { isWarmingDarkSites = true }
        darkSitesLock.unlock()

        guard shouldStart else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = self?.ensureDarkSitesLoaded()
        }
    }

    private func ensureDarkSitesLoaded() -> DarkSitesIndex {
        darkSitesLock.lock()
        if let existing = cachedDarkSites {
            darkSitesLock.unlock()
            return existing
        }
        darkSitesLock.unlock()

        // Parse off-lock to prevent priority inversion on @MainActor.
        let text = Self.loadBundledText(named: "dark-sites", ext: "config") ?? ""
        let (exact, suffix) = Self.parseDarkSitesConfig(text)
        let built = DarkSitesIndex(exactDarkHosts: exact, suffixDarkHosts: suffix)

        darkSitesLock.lock()
        if let existing = cachedDarkSites {
            isWarmingDarkSites = false
            darkSitesLock.unlock()
            return existing
        }
        cachedDarkSites = built
        isWarmingDarkSites = false
        darkSitesLock.unlock()
        return built
    }

    private func ensureDynamicFixesIndexLoaded() -> DynamicFixesIndex? {
        fixesLock.lock()
        if let existing = cachedFixesIndex {
            fixesLock.unlock()
            return existing
        }
        fixesLock.unlock()

        guard let data = Self.loadBundledData(named: "dynamic-theme-fixes", ext: "config"),
              let built = Self.buildDynamicFixesIndex(from: data) else {
            return nil
        }

        fixesLock.lock()
        if let existing = cachedFixesIndex {
            fixesLock.unlock()
            return existing
        }
        cachedFixesIndex = built
        fixesLock.unlock()
        return built
    }

    private func ensureRuntimeJSLoaded() -> String {
        fixesLock.lock()
        if let existing = cachedRuntimeJS {
            fixesLock.unlock()
            return existing
        }
        fixesLock.unlock()

        let loaded = Self.loadBundledText(named: "darkreader.min", ext: "js") ?? ""
        fixesLock.lock()
        if let existing = cachedRuntimeJS {
            fixesLock.unlock()
            return existing
        }
        cachedRuntimeJS = loaded
        fixesLock.unlock()
        return loaded
    }

    private static func bundledResourceURL(named name: String, ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "DarkReader")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    private static func loadBundledText(named name: String, ext: String) -> String? {
        guard let url = bundledResourceURL(named: name, ext: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func loadBundledData(named name: String, ext: String) -> Data? {
        guard let url = bundledResourceURL(named: name, ext: ext) else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func normalizeHost(_ rawHost: String?) -> String? {
        guard let rawHost else { return nil }
        let normalized = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }

    /// Returns ordered host lookup candidates: preserves mobile-specific config keys (`mobile.bg`, `m.dianping.com`)
    /// first while also matching canonical `HostNormalizer` keys.
    private static func lookupHostCandidates(for rawHost: String?) -> [String] {
        guard let rawHost else { return [] }
        var candidates: [String] = []
        let trimmed = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !trimmed.isEmpty {
            let wwwStripped = trimmed.hasPrefix("www.") ? String(trimmed.dropFirst(4)) : trimmed
            if !wwwStripped.isEmpty {
                candidates.append(wwwStripped)
            }
        }
        if let normalized = normalizeHost(rawHost), !candidates.contains(normalized) {
            candidates.append(normalized)
        }
        return candidates
    }

    private static func matchesDarkSites(rawHost: String?, index: DarkSitesIndex) -> Bool {
        for candidate in lookupHostCandidates(for: rawHost) {
            if index.exactDarkHosts.contains(candidate) { return true }
            var probe = candidate
            while true {
                if index.suffixDarkHosts.contains(probe) { return true }
                guard let dot = probe.firstIndex(of: ".") else { break }
                probe = String(probe[probe.index(after: dot)...])
            }
        }
        return false
    }

    private static func parseDarkSitesConfig(_ text: String) -> (exact: Set<String>, suffix: Set<String>) {
        var exact: Set<String> = []
        var suffix: Set<String> = []
        text.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !line.isEmpty, !line.hasPrefix("#"), !line.contains("/") else { return }
            if line.hasPrefix("*.") {
                let dom = String(line.dropFirst(2))
                if !dom.isEmpty { suffix.insert(dom) }
            } else {
                let clean = line.hasPrefix("www.") ? String(line.dropFirst(4)) : line
                exact.insert(clean)
            }
        }
        return (exact, suffix)
    }

    private static func buildDynamicFixesIndex(from data: Data) -> DynamicFixesIndex? {
        guard !data.isEmpty else { return nil }
        var commonRange: Range<Int>?
        var rangesByHost: [String: Range<Int>] = [:]
        rangesByHost.reserveCapacity(3_000)

        var blockStart = 0
        var inHostsSection = true
        var currentHosts: [String] = []
        var cursor = 0
        let count = data.count

        data.withUnsafeBytes { rawBuf in
            guard let bytes = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }

            func commitBlock(endOffset: Int) {
                if !currentHosts.isEmpty && blockStart < endOffset {
                    let range = blockStart..<endOffset
                    for host in currentHosts {
                        if host == "*" {
                            commonRange = range
                        } else {
                            rangesByHost[host] = range
                        }
                    }
                }
                currentHosts.removeAll(keepingCapacity: true)
                inHostsSection = true
            }

            while cursor < count {
                let lineStart = cursor
                var lineEnd = cursor
                while lineEnd < count && bytes[lineEnd] != 0x0A {
                    lineEnd += 1
                }
                cursor = (lineEnd < count) ? (lineEnd + 1) : count

                var trimmedEnd = lineEnd
                if trimmedEnd > lineStart && bytes[trimmedEnd - 1] == 0x0D {
                    trimmedEnd -= 1
                }
                var s = lineStart
                while s < trimmedEnd && (bytes[s] == 0x20 || bytes[s] == 0x09) { s += 1 }
                while trimmedEnd > s && (bytes[trimmedEnd - 1] == 0x20 || bytes[trimmedEnd - 1] == 0x09) { trimmedEnd -= 1 }

                let len = trimmedEnd - s
                if len == 0 { continue }

                if len >= 2 {
                    var allEquals = true
                    for p in s..<trimmedEnd where bytes[p] != 0x3D {
                        allEquals = false
                        break
                    }
                    if allEquals {
                        commitBlock(endOffset: lineStart)
                        blockStart = cursor
                        continue
                    }
                }

                if inHostsSection {
                    let lineStr = String(decoding: UnsafeBufferPointer(start: bytes + s, count: len), as: UTF8.self)
                    switch lineStr {
                    case "INVERT", "CSS", "IGNORE INLINE STYLE", "IGNORE IMAGE ANALYSIS",
                         "IGNORE CSS URL", "NO COMMON", "DISABLE STYLE SHEETS PROXY", "COMMON":
                        inHostsSection = false
                    default:
                        if !lineStr.hasPrefix("#") && !lineStr.contains("/") {
                            let cleaned = lineStr.lowercased().replacingOccurrences(of: "*.", with: "")
                            let finalHost = cleaned.hasPrefix("www.") ? String(cleaned.dropFirst(4)) : cleaned
                            if !finalHost.isEmpty {
                                currentHosts.append(finalHost)
                            }
                        }
                    }
                }
            }
            commitBlock(endOffset: count)
        }

        let commonFix = commonRange.map { parseSingleDynamicFixBlock(from: data[$0]) }
        return DynamicFixesIndex(data: data, commonFix: commonFix, rangesByHost: rangesByHost)
    }

    private static func parseSingleDynamicFixBlock(from slice: Data.SubSequence) -> DynamicFix {
        let blockText = String(decoding: slice, as: UTF8.self)
        enum Section {
            case hosts
            case invert
            case css
            case ignoreInlineStyle
            case ignoreImageAnalysis
            case ignoreCSSUrl
            case ignoreOther
        }

        var fix = DynamicFix()
        var cssLines: [String] = []
        var section: Section = .hosts

        blockText.enumerateLines { rawLine, _ in
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if section == .css { cssLines.append("") }
                return
            }
            switch trimmed {
            case "INVERT":
                section = .invert
                return
            case "CSS":
                section = .css
                return
            case "IGNORE INLINE STYLE":
                section = .ignoreInlineStyle
                return
            case "IGNORE IMAGE ANALYSIS":
                section = .ignoreImageAnalysis
                return
            case "IGNORE CSS URL":
                section = .ignoreCSSUrl
                return
            case "NO COMMON":
                fix.noCommon = true
                section = .ignoreOther
                return
            case "DISABLE STYLE SHEETS PROXY", "COMMON":
                section = .ignoreOther
                return
            default:
                break
            }

            switch section {
            case .hosts:
                break
            case .invert:
                fix.invert.append(trimmed)
            case .css:
                cssLines.append(rawLine)
            case .ignoreInlineStyle:
                fix.ignoreInlineStyle.append(trimmed)
            case .ignoreImageAnalysis:
                fix.ignoreImageAnalysis.append(trimmed)
            case .ignoreCSSUrl:
                fix.ignoreCSSUrl.append(trimmed)
            case .ignoreOther:
                break
            }
        }
        fix.css = cssLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return fix
    }
}
