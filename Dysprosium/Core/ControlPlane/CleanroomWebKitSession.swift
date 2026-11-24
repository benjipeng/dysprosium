import CryptoKit
import Foundation
import Network
import Observation
import OSLog
import PDFKit
import Security
import UIKit
import WebKit

@MainActor
private enum SystemProxyWebKitRegistry {
    final class TrackedDataStore {
        weak var store: WKWebsiteDataStore?
        var applied: SystemProxyBridge.ProxyDescriptor?

        init(store: WKWebsiteDataStore, applied: SystemProxyBridge.ProxyDescriptor?) {
            self.store = store
            self.applied = applied
        }
    }

    static var trackedDataStores: [ObjectIdentifier: TrackedDataStore] = [:]
    static var pathMonitor: NWPathMonitor?
}

/// WebKit `WKWebsiteDataStore` synchronization adapter for `SystemProxyBridge` (core lives in `Core/Transport/SystemProxyBridge.swift`).
public extension SystemProxyBridge {
    @MainActor
    private static func ensurePathMonitorStarted() {
        guard SystemProxyWebKitRegistry.pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in
            Task { @MainActor in
                Self.syncAllTrackedDataStores()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.dysprosium.system-proxy-monitor", qos: .utility))
        SystemProxyWebKitRegistry.pathMonitor = monitor
    }

    /// Re-evaluates all live `WKWebsiteDataStore` instances whenever network interfaces, VPN/TUN
    /// state, or Wi-Fi proxy settings change in foreground (e.g., Wi-Fi -> 5G handoff or Control Center VPN toggle).
    @MainActor
    static func syncAllTrackedDataStores() {
        let current = currentDescriptor()
        var staleKeys: [ObjectIdentifier] = []
        for (key, tracked) in SystemProxyWebKitRegistry.trackedDataStores {
            guard let store = tracked.store else {
                staleKeys.append(key)
                continue
            }
            apply(descriptor: current, to: store, tracked: tracked)
        }
        for key in staleKeys {
            SystemProxyWebKitRegistry.trackedDataStores.removeValue(forKey: key)
        }
    }

    @MainActor
    private static func apply(
        descriptor current: ProxyDescriptor?,
        to dataStore: WKWebsiteDataStore,
        tracked: SystemProxyWebKitRegistry.TrackedDataStore
    ) {
        guard tracked.applied != current else { return }
        if let current {
            dataStore.proxyConfigurations = makeProxyConfigurations(for: current)
            logger.notice("Synced WKWebsiteDataStore proxy=\(current.kind.rawValue, privacy: .public) \(current.host, privacy: .public):\(current.port) (allowFailover=false, excluded=\(current.excludedDomains.count))")
        } else {
            dataStore.proxyConfigurations = []
            logger.notice("Cleared WKWebsiteDataStore explicit proxy (no active manual OS proxy)")
        }
        tracked.applied = current
    }

    /// Idempotently synchronizes `WKWebsiteDataStore.proxyConfigurations` with the OS manual proxy
    /// and registers the data store for live `NWPathMonitor` updates.
    @MainActor
    static func sync(dataStore: WKWebsiteDataStore) {
        ensurePathMonitorStarted()
        let current = currentDescriptor()
        let key = ObjectIdentifier(dataStore)
        if let existing = SystemProxyWebKitRegistry.trackedDataStores[key], existing.store != nil {
            apply(descriptor: current, to: dataStore, tracked: existing)
            return
        }
        let tracked = SystemProxyWebKitRegistry.TrackedDataStore(store: dataStore, applied: nil)
        SystemProxyWebKitRegistry.trackedDataStores[key] = tracked
        apply(descriptor: current, to: dataStore, tracked: tracked)
    }
}

/// Authenticated browser download handoff payload produced by `WKNavigationDelegate` or context menus.
public struct BrowserDownloadRequest: Sendable {
    public let url: URL
    public let suggestedFilename: String?
    public let expectedBytes: Int64?
    public let headers: [String: String]
    public let sourceDomain: String?
    public let sourceProfileID: String?

    public init(
        url: URL,
        suggestedFilename: String? = nil,
        expectedBytes: Int64? = nil,
        headers: [String: String] = [:],
        sourceDomain: String? = nil,
        sourceProfileID: String? = nil
    ) {
        self.url = url
        self.suggestedFilename = suggestedFilename
        self.expectedBytes = expectedBytes
        self.headers = headers
        self.sourceDomain = sourceDomain
        self.sourceProfileID = sourceProfileID
    }
}

/// Structured page navigation failure surfaced to the browser workspace overlay.
public struct WebLoadError: Equatable, Sendable {
    public let urlString: String
    public let domain: String
    public let code: Int
    public let localizedDescription: String
    public let isTLSFailure: Bool

    public init(
        urlString: String,
        domain: String,
        code: Int,
        localizedDescription: String,
        isTLSFailure: Bool
    ) {
        self.urlString = urlString
        self.domain = domain
        self.code = code
        self.localizedDescription = localizedDescription
        self.isTLSFailure = isTLSFailure
    }
}

@MainActor
private final class JSDialogCompletionBox {
    enum Handler {
        case alert(@MainActor () -> Void)
        case confirm(@MainActor (Bool) -> Void)
        case prompt(@MainActor (String?) -> Void)
    }

    private var handler: Handler?
    private var onResolved: (@MainActor () -> Void)?

    init(handler: Handler, onResolved: (@MainActor () -> Void)? = nil) {
        self.handler = handler
        self.onResolved = onResolved
    }

    func resolveAlert() {
        guard let current = takeHandler() else { return }
        switch current {
        case .alert(let fn): fn()
        case .confirm(let fn): fn(false)
        case .prompt(let fn): fn(nil)
        }
    }

    func resolveConfirm(_ accepted: Bool) {
        guard let current = takeHandler() else { return }
        switch current {
        case .alert(let fn): fn()
        case .confirm(let fn): fn(accepted)
        case .prompt(let fn): fn(nil)
        }
    }

    func resolvePrompt(_ text: String?) {
        guard let current = takeHandler() else { return }
        switch current {
        case .alert(let fn): fn()
        case .confirm(let fn): fn(text != nil)
        case .prompt(let fn): fn(text)
        }
    }

    func cancel() {
        guard let current = takeHandler() else { return }
        switch current {
        case .alert(let fn): fn()
        case .confirm(let fn): fn(false)
        case .prompt(let fn): fn(nil)
        }
    }

    private func takeHandler() -> Handler? {
        guard let current = handler else { return nil }
        handler = nil
        let cleanup = onResolved
        onResolved = nil
        // Clear session state BEFORE invoking WebKit's completion handler so consecutive
        // synchronous JS dialogs (`alert('1'); alert('2');`) never get clobbered.
        cleanup?()
        return current
    }

    isolated deinit {
        guard let current = handler else { return }
        handler = nil
        onResolved = nil
        switch current {
        case .alert(let fn): fn()
        case .confirm(let fn): fn(false)
        case .prompt(let fn): fn(nil)
        }
    }
}

/// One-shot JavaScript dialog bridge (`alert`, `confirm`, `prompt`) guaranteeing WebKit's
/// completion handler is invoked at most once and always resolved on cancel/deinit/tab close.
public struct WebJSDialogRequest: Identifiable {
    public enum Kind: Equatable, Sendable {
        case alert
        case confirm
        case prompt(defaultText: String?)
    }

    public let id: UUID
    public let kind: Kind
    public let message: String
    private let box: JSDialogCompletionBox

    @MainActor
    fileprivate init(
        id: UUID = UUID(),
        kind: Kind,
        message: String,
        handler: JSDialogCompletionBox.Handler,
        onResolved: (@MainActor () -> Void)? = nil
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.box = JSDialogCompletionBox(handler: handler, onResolved: onResolved)
    }

    @MainActor
    public func resolveAlert() {
        box.resolveAlert()
    }

    @MainActor
    public func resolveConfirm(_ accepted: Bool) {
        box.resolveConfirm(accepted)
    }

    @MainActor
    public func resolvePrompt(_ text: String?) {
        box.resolvePrompt(text)
    }

    @MainActor
    public func cancel() {
        box.cancel()
    }
}

@MainActor
private final class AuthChallengeCompletionBox {
    enum Handler {
        case httpCredentials(@MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
        case lanSelfSignedTrust(
            trust: SecTrust,
            onTrustApproved: (@MainActor () -> Void)?,
            completion: @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        )
    }

    private var handler: Handler?
    private var onResolved: (@MainActor () -> Void)?

    init(handler: Handler, onResolved: (@MainActor () -> Void)? = nil) {
        self.handler = handler
        self.onResolved = onResolved
    }

    func resolveCredentials(username: String, password: String) {
        guard let current = takeHandler() else { return }
        switch current {
        case .httpCredentials(let fn):
            let credential = URLCredential(user: username, password: password, persistence: .forSession)
            fn(.useCredential, credential)
        case .lanSelfSignedTrust(_, _, let fn):
            fn(.cancelAuthenticationChallenge, nil)
        }
    }

    func resolveTrust(proceed: Bool) {
        guard let current = takeHandler() else { return }
        switch current {
        case .httpCredentials(let fn):
            fn(.cancelAuthenticationChallenge, nil)
        case .lanSelfSignedTrust(let trust, let onTrustApproved, let fn):
            if proceed {
                onTrustApproved?()
                fn(.useCredential, URLCredential(trust: trust))
            } else {
                fn(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    func cancel() {
        guard let current = takeHandler() else { return }
        switch current {
        case .httpCredentials(let fn):
            fn(.cancelAuthenticationChallenge, nil)
        case .lanSelfSignedTrust(_, _, let fn):
            fn(.cancelAuthenticationChallenge, nil)
        }
    }

    private func takeHandler() -> Handler? {
        guard let current = handler else { return nil }
        handler = nil
        let cleanup = onResolved
        onResolved = nil
        cleanup?()
        return current
    }

    isolated deinit {
        guard let current = handler else { return }
        handler = nil
        onResolved = nil
        switch current {
        case .httpCredentials(let fn):
            fn(.cancelAuthenticationChallenge, nil)
        case .lanSelfSignedTrust(_, _, let fn):
            fn(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// One-shot authentication / LAN self-signed TLS challenge bridge guaranteeing WebKit's
/// challenge completion handler is invoked once and always cancelled on dismiss/deinit/tab close.
public struct WebAuthChallengeRequest: Identifiable {
    public enum Kind: Equatable, Sendable {
        case httpCredentials(realm: String?)
        case lanSelfSignedTrust(reason: String)
    }

    public let id: UUID
    public let host: String
    public let kind: Kind
    private let box: AuthChallengeCompletionBox

    @MainActor
    fileprivate init(
        id: UUID = UUID(),
        host: String,
        kind: Kind,
        handler: AuthChallengeCompletionBox.Handler,
        onResolved: (@MainActor () -> Void)? = nil
    ) {
        self.id = id
        self.host = host
        self.kind = kind
        self.box = AuthChallengeCompletionBox(handler: handler, onResolved: onResolved)
    }

    @MainActor
    public func resolveCredentials(username: String, password: String) {
        box.resolveCredentials(username: username, password: password)
    }

    @MainActor
    public func resolveTrust(proceed: Bool) {
        box.resolveTrust(proceed: proceed)
    }

    @MainActor
    public func cancel() {
        box.cancel()
    }
}

/// Lightweight summary of a `WKBackForwardListItem` keyed by relative offset (`-1, -2...` or `+1, +2...`).
public struct WebBackForwardItemSummary: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let url: URL

    public init(id: Int, title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// Per-tab Cleanroom WebKit session managing `WKWebView` lifecycle, navigation/UI delegates,
/// per-host Content Shield bypass & subframe scriptlet wiring, and delegating all media discovery,
/// probing, and manifest capture to `MediaCaptureCoordinator`.
@Observable
@MainActor
public final class CleanroomWebKitSession: NSObject, Identifiable {
    public let id: UUID
    public let isPrivate: Bool
    /// Owning persistent profile identifier (`nil` iff `isPrivate == true`).
    public let profileID: String?
    public let mediaCapture: MediaCaptureCoordinator

    public private(set) var currentURLString: String = ""
    public private(set) var pageTitle: String = ""
    public private(set) var isLoading: Bool = false
    public private(set) var estimatedProgress: Double = 0
    public private(set) var canGoBack: Bool = false
    public private(set) var canGoForward: Bool = false
    public private(set) var blockedPopupCount: Int = 0
    public private(set) var isShieldEnabled: Bool = true
    public private(set) var previewSnapshot: UIImage?
    /// Active native `PDFKit` document hosted directly inside this tab (zero forced download).
    public private(set) var activePDF: PDFTabDocument?
    /// True while a main-frame inline `application/pdf` response is streaming via `WKDownload` into temporary preview storage.
    public private(set) var isLoadingInlinePDF: Bool = false

    public var isViewingPDF: Bool {
        activePDF != nil
    }

    // MARK: - Media Capture Forwarding (100% Reactive via `@Observable` `MediaCaptureCoordinator`)

    public var capturePhase: MediaCapturePhase {
        mediaCapture.capturePhase
    }

    public var isProbingMedia: Bool {
        mediaCapture.isProbing
    }

    public var activeProbeCount: Int {
        mediaCapture.activeProbeCount
    }

    public var candidates: [SniffedStreamCandidate] {
        mediaCapture.candidates
    }

    public var sniffedMedia: [SniffedStreamCandidate] {
        mediaCapture.candidates
    }

    public var mediaGroups: [DiscoveredMediaGroup] {
        mediaCapture.mediaGroups
    }

    public var discoveredMediaGroups: [DiscoveredMediaGroup] {
        mediaCapture.mediaGroups
    }

    public var pendingCandidateCount: Int {
        mediaCapture.pendingCandidateCount
    }

    public var discoveredMediaBadgeCount: Int {
        mediaCapture.discoveredMediaBadgeCount
    }

    public var selectedGroupsForDownload: [DiscoveredMediaGroup] {
        mediaCapture.selectedGroupsForDownload
    }

    // MARK: - Per-Host Content Shield Bypass

    public var currentURL: URL? {
        if !currentURLString.isEmpty, let parsed = URL(string: currentURLString) {
            return parsed
        }
        return backingWebView?.url
    }

    /// Normalized lowercase host (leading `www.` stripped) of the current HTTP(S) page,
    /// or `nil` on the Start Page, `about:` documents, or non-web schemes.
    public var currentBypassableHost: String? {
        let candidateURL = currentURLString.isEmpty
            ? backingWebView?.url
            : (URL(string: currentURLString) ?? backingWebView?.url)
        guard let candidateURL,
              let scheme = candidateURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return CleanroomContentBlocker.shared.normalizeBypassHost(candidateURL.host())
    }

    public var isShieldBypassedForCurrentHost: Bool {
        guard let host = currentBypassableHost else { return false }
        if let rule = siteRuleProvider?(host) {
            if rule.shieldMode == -1 { return true }
            if rule.shieldMode == 1 { return false }
        }
        if profileID == nil || profileID == BrowserProfile.defaultID {
            return CleanroomContentBlocker.shared.isHostBypassed(host)
        }
        return false
    }

    public var isEffectiveShieldEnabled: Bool {
        resolvedEffectiveShield(forHost: currentBypassableHost, globalEnabled: isShieldEnabled)
    }

    public func toggleShieldBypassForCurrentHost() {
        setShieldBypassedForCurrentHost(!isShieldBypassedForCurrentHost)
    }

    public var isAutoDarkBypassedForCurrentHost: Bool {
        guard let host = currentBypassableHost else { return false }
        if let rule = siteRuleProvider?(host) {
            if rule.darkMode == -1 { return true }
            if rule.darkMode == 1 { return false }
        }
        if profileID == nil || profileID == BrowserProfile.defaultID {
            return DarkReaderEngine.shared.isHostBypassed(host)
        }
        return false
    }

    /// Toggles per-site Auto Dark Mode pause for the current website and updates live immediately.
    public func toggleAutoDarkBypassForCurrentHost() {
        guard let host = currentBypassableHost else { return }
        let nextBypassed = !isAutoDarkBypassedForCurrentHost
        if let onUpdateSiteRule {
            onUpdateSiteRule(host, nil, nextBypassed ? -1 : 0)
        } else {
            DarkReaderEngine.shared.setHostBypassed(nextBypassed, for: host)
        }

        guard let wv = backingWebView else { return }
        let controller = wv.configuration.userContentController
        let effectiveShield = resolvedEffectiveShield(forHost: host, globalEnabled: isShieldEnabled)
        Task { @MainActor [weak self] in
            guard let self, let liveWV = self.backingWebView else { return }
            await CleanroomContentBlocker.shared.apply(
                enabled: effectiveShield,
                to: controller,
                forHost: host,
                autoWebPageDarkModeOverride: !nextBypassed && CleanroomBrowserStore.persistedAutoWebPageDarkMode
            )
            self.recordAppliedBlockerState(forHost: host, shieldEnabled: self.isShieldEnabled)
            let enableJS = nextBypassed ? "false" : "true"
            let script = "if (typeof window.__dysprosiumSetAutoDark === 'function') { window.__dysprosiumSetAutoDark(\(enableJS)); }"
            _ = try? await liveWV.evaluateJavaScript(script)
            if nextBypassed {
                self.isSyntheticDarkActive = false
                liveWV.underPageBackgroundColor = nil
                liveWV.scrollView.backgroundColor = .systemBackground
                self.syncPageCanvasColor(from: liveWV)
            } else if !self.currentURLString.isEmpty, self.deferredRestoreURLString == nil {
                liveWV.reload()
            }
        }
    }

    /// Rotates the active 256-bit anti-fingerprinting seed without restarting the app,
    /// purges tracking cookies/storage/IndexedDB/HTTP caches for the active site (or entire
    /// ephemeral store in Private mode), re-installs 0-frame scripts, and reloads ignoring ETag cache.
    public func rotateFingerprintAndReload() {
        let wv = ensureWebView()
        let activeProfile = resolvedUserAgentProfile(global: effectiveProfileUserAgent)
        let newSeed: String
        if isPrivate {
            newSeed = FingerprintShieldEngine.generateDistinctCryptographicSeed(
                avoiding: privateFingerprintSeed,
                profile: activeProfile
            )
            privateFingerprintSeed = newSeed
        } else {
            if !FingerprintShieldEngine.shared.isEnabled {
                FingerprintShieldEngine.shared.isEnabled = true
            }
            if let onRotateProfileFingerprintSeed {
                newSeed = onRotateProfileFingerprintSeed()
            } else {
                FingerprintShieldEngine.shared.rotateStandardSeed()
                newSeed = FingerprintShieldEngine.shared.standardSeed
            }
        }

        let controller = wv.configuration.userContentController
        let dataStore = wv.configuration.websiteDataStore
        let host = activeNavigationHost
        let effectiveShield = resolvedEffectiveShield(forHost: host, globalEnabled: isShieldEnabled)
        let targetURL = wv.url ?? URL(string: currentURLString)
        let isPrivateTab = isPrivate

        Task { @MainActor [weak self] in
            // 1. Clear in-page sessionStorage / localStorage immediately before wiping WKWebsiteDataStore.
            if let self, let liveWV = self.backingWebView {
                _ = try? await liveWV.evaluateJavaScript(
                    "try { sessionStorage.clear(); localStorage.clear(); } catch (_) {}"
                )
            }

            // 2. Purge persistent/ephemeral cookies, IndexedDB, CacheStorage, ServiceWorkers, and HTTP caches.
            let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            if isPrivateTab {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    dataStore.removeData(ofTypes: allTypes, modifiedSince: .distantPast) {
                        cont.resume()
                    }
                }
            } else {
                let targetDomains = Self.siteAndTrackerPurgeDomains(forHost: host)
                let records = await withCheckedContinuation { (cont: CheckedContinuation<[WKWebsiteDataRecord], Never>) in
                    dataStore.fetchDataRecords(ofTypes: allTypes) { fetched in
                        cont.resume(returning: fetched)
                    }
                }
                let matching = records.filter { rec in
                    let name = rec.displayName.lowercased()
                    return targetDomains.contains { domain in
                        name == domain || name.hasSuffix(".\(domain)") || domain.hasSuffix(".\(name)")
                    }
                }
                if !matching.isEmpty {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        dataStore.removeData(ofTypes: allTypes, for: matching) {
                            cont.resume()
                        }
                    }
                }
                // Also explicitly purge live HttpOnly identification cookies (such as Fingerprint Pro's
                // `_iidt` / `_vid_t` tokens) regardless of first-party proxy subdomain naming.
                let liveCookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
                    dataStore.httpCookieStore.getAllCookies { cookies in
                        cont.resume(returning: cookies)
                    }
                }
                for cookie in liveCookies {
                    let dom = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    let cname = cookie.name.lowercased()
                    let isTrackerToken = cname == "_iidt" || cname == "_vid_t" || cname.hasPrefix("_fpjs")
                    let matchesDomain = targetDomains.contains { d in
                        dom == d || dom.hasSuffix(".\(d)") || d.hasSuffix(".\(dom)")
                    }
                    if isTrackerToken || matchesDomain {
                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                            dataStore.httpCookieStore.delete(cookie) {
                                cont.resume()
                            }
                        }
                    }
                }
            }

            // 3. Apply the brand-new OS-coherent Apple persona UA (HTTP + Main + Iframe + Worker parity),
            // re-install 0-frame scripts with the fresh 256-bit seed, and reload ignoring HTTP ETag cache.
            guard let self, let liveWV = self.backingWebView else { return }
            let profile = self.resolvedUserAgentProfile(global: self.effectiveProfileUserAgent)
            liveWV.customUserAgent = FingerprintShieldEngine.persona(forSeed: newSeed, profile: profile).userAgent
            self.lastAppliedUserAgentProfile = profile
            await CleanroomContentBlocker.shared.apply(
                enabled: effectiveShield,
                to: controller,
                forHost: host,
                includeFingerprintShield: true,
                fingerprintSeedOverride: newSeed,
                userAgentProfileOverride: profile
            )
            self.recordAppliedBlockerState(forHost: host, shieldEnabled: self.isShieldEnabled)
            if let targetURL, self.deferredRestoreURLString == nil {
                var req = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
                req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                req.setValue("no-cache", forHTTPHeaderField: "Pragma")
                liveWV.load(req)
            } else if !self.currentURLString.isEmpty, self.deferredRestoreURLString == nil {
                liveWV.reloadFromOrigin()
            }
        }
    }

    private static func siteAndTrackerPurgeDomains(forHost rawHost: String?) -> Set<String> {
        var domains: Set<String> = [
            "fpjs.io",
            "fpcdn.io",
            "openfpcdn.io",
            "fpnpmcdn.net",
            "fingerprint.com",
            "fingerprintjs.com"
        ]
        if let rawHost = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !rawHost.isEmpty {
            let clean = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
            if !clean.isEmpty {
                domains.insert(clean)
                let parts = clean.split(separator: ".")
                if parts.count >= 2 {
                    domains.insert(parts.suffix(2).joined(separator: "."))
                }
            }
        }
        return domains
    }

    public func setShieldBypassedForCurrentHost(_ bypassed: Bool) {
        guard let host = currentBypassableHost else { return }
        mediaCapture.clear()
        if let onUpdateSiteRule {
            onUpdateSiteRule(host, bypassed ? -1 : 1, nil)
            guard let liveWV = backingWebView else { return }
            let controller = liveWV.configuration.userContentController
            let effectiveShield = resolvedEffectiveShield(forHost: host, globalEnabled: isShieldEnabled)
            Task { @MainActor [weak self] in
                guard let self, let liveWV = self.backingWebView else { return }
                await CleanroomContentBlocker.shared.apply(enabled: effectiveShield, to: controller, forHost: host)
                self.recordAppliedBlockerState(forHost: host, shieldEnabled: self.isShieldEnabled)
                if !self.currentURLString.isEmpty, self.deferredRestoreURLString == nil {
                    liveWV.reload()
                }
            }
            return
        }
        let enabled = isShieldEnabled
        Task { @MainActor [weak self] in
            await CleanroomContentBlocker.shared.setHostBypassed(bypassed, for: host)
            guard let self, let liveWV = self.backingWebView else { return }
            let controller = liveWV.configuration.userContentController
            await CleanroomContentBlocker.shared.apply(enabled: enabled, to: controller, forHost: host)
            self.recordAppliedBlockerState(forHost: host, shieldEnabled: enabled)
            if !self.currentURLString.isEmpty, self.deferredRestoreURLString == nil {
                liveWV.reload()
            }
        }
    }

    public var onOpenLinkInTab: (@MainActor (URL, _ isPrivate: Bool, _ activate: Bool) -> Void)?
    public var onNavigationCommitted: (@MainActor (URL, String) -> Void)?
    public var onEnqueueBrowserDownload: (@MainActor (BrowserDownloadRequest) -> Void)?
    public var onWKDownloadFinished: (@MainActor (URL) -> Void)?
    public var onWKDownloadFailed: (@MainActor (String) -> Void)?
    public var onPDFSavedToVault: (@MainActor (URL) -> Void)?
    public var onShareURL: (@MainActor (URL) -> Void)?
    public var onCreateChildWebViewTab: (@MainActor (WKWebViewConfiguration, URL?) -> WKWebView?)?
    public var onRequestCloseSelf: (@MainActor () -> Void)?

    public var isSecureConnection: Bool = false
    public var lastLoadError: WebLoadError?
    public var activeJSDialog: WebJSDialogRequest? {
        didSet {
            if let old = oldValue, old.id != activeJSDialog?.id {
                old.cancel()
            }
        }
    }
    public var activeAuthChallenge: WebAuthChallengeRequest? {
        didSet {
            if let old = oldValue, old.id != activeAuthChallenge?.id {
                old.cancel()
            }
        }
    }
    public var lastBlockedPopupURL: URL?
    public var hasActiveWKDownload: Bool = false

    public var activeShieldRuleCount: Int {
        CleanroomContentBlocker.shared.activeRuleCount
    }

    public var displayTabTitle: String {
        if let pdf = activePDF { return pdf.displayTitle }
        if !pageTitle.isEmpty { return pageTitle }
        if let host = URL(string: currentURLString)?.host() { return host }
        return isPrivate ? L("Private Tab") : L("New Tab")
    }

    /// Clean text displayed in the Omnibox when not editing: shows the document title for local `file://` PDFs
    /// instead of raw sandbox container paths, while keeping full `https://` URLs for remote pages and PDFs.
    public var omniboxDisplayText: String {
        if let pdf = activePDF, pdf.isLocalFileSource {
            return pdf.displayTitle
        }
        if currentURLString.lowercased().hasPrefix("file://"),
           let parsed = URL(string: currentURLString), parsed.isFileURL {
            let stem = (parsed.lastPathComponent as NSString).deletingPathExtension
            return stem.isEmpty ? parsed.lastPathComponent : stem
        }
        return currentURLString
    }

    public var displayHost: String {
        if let pdf = activePDF {
            if pdf.isLocalFileSource {
                return pdf.displayTitle
            }
            if let host = pdf.sourceURL.host() {
                let normalized = LiveContainerEnvironment.HostNormalizer.normalize(host)
                return normalized.isEmpty ? host : normalized
            }
            return pdf.displayTitle
        }
        if let parsed = URL(string: currentURLString) {
            if parsed.isFileURL {
                let name = (parsed.lastPathComponent as NSString).deletingPathExtension
                return name.isEmpty ? L("Local PDF") : name
            }
            if let host = parsed.host() {
                let normalized = LiveContainerEnvironment.HostNormalizer.normalize(host)
                return normalized.isEmpty ? host : normalized
            }
        }
        return isPrivate ? L("Ephemeral Session") : L("Start Page")
    }

    /// True while a live `WKWebView` (and backing `WebContent` process) is currently allocated for this tab.
    public private(set) var hasLiveWebView: Bool = false
    /// True when this tab previously had a live page and was hibernated to reclaim RAM, holding `interactionState`.
    public private(set) var isHibernated: Bool = false
    /// Current effective page zoom (`0.5...2.0`, default `1.0`).
    public private(set) var pageZoom: Double = 1.0
    /// Marks this tab as running an active fingerprint/diagnostic audit (exempts it from LRU hibernation).
    public var isAuditInProgress: Bool = false
    /// Marks this tab as owning an active download (exempts it from LRU hibernation).
    public var hasActiveDownload: Bool = false
    /// Last sampled `WKWebView` media playback state (used to exempt active media/PiP tabs from hibernation).
    public private(set) var lastKnownMediaPlaybackState: WKMediaPlaybackState = .none

    /// Live `WKWebView` allocated lazily on demand via `ensureWebView()`.
    /// Dormant/background/hibernated tabs never allocate a `WKWebView` until activated or explicitly accessed.
    public var webView: WKWebView {
        ensureWebView()
    }

    /// Read-only access to the live `WKWebView` without triggering lazy allocation.
    public var liveWebViewIfLoaded: WKWebView? {
        backingWebView
    }

    /// True if this tab must never be hibernated due to active media/PiP, capture, downloads, probing, or auditing.
    public var isExemptFromHibernation: Bool {
        if isProbingMedia || activeProbeCount > 0 || isAuditInProgress || hasActiveDownload || hasActiveWKDownload || isLoadingInlinePDF {
            return true
        }
        if lastKnownMediaPlaybackState == .playing {
            return true
        }
        if let wv = backingWebView {
            if wv.fullscreenState != .notInFullscreen
                || wv.cameraCaptureState != .none
                || wv.microphoneCaptureState != .none {
                return true
            }
        }
        return false
    }

    @discardableResult
    public func refreshMediaPlaybackState() async -> WKMediaPlaybackState {
        guard let wv = backingWebView else {
            lastKnownMediaPlaybackState = .none
            return .none
        }
        let state = await wv.requestMediaPlaybackState()
        lastKnownMediaPlaybackState = state
        return state
    }

    private var backingWebView: WKWebView?
    private var savedInteractionState: Any?
    private let websiteDataStoreProvider: (@MainActor () -> WKWebsiteDataStore)?
    private let siteRuleProvider: (@MainActor (String) -> SiteRuleRecord?)?
    private let profileFingerprintSeedProvider: (@MainActor () -> String?)?
    private let profileUserAgentProvider: (@MainActor () -> BrowserUserAgentProfile?)?
    private let profileSearchProvider: (@MainActor () -> (BrowserSearchEngine, String))?
    public var onRotateProfileFingerprintSeed: (@MainActor () -> String)?
    public var onUpdateSiteRule: (@MainActor (_ host: String, _ shieldMode: Int?, _ darkMode: Int?) -> Void)?

    /// Profile scope attributed to downloads initiated from this tab (`BrowserProfile.privateTransferProfileID`
    /// for Private tabs so ephemeral cookies never mix with Default profile auth headers).
    public var transferSourceProfileID: String? {
        isPrivate ? BrowserProfile.privateTransferProfileID : profileID
    }
    private var privateFingerprintSeed: String?
    public private(set) var pageCanvasColor: UIColor?
    private var isSyntheticDarkActive: Bool = false
    private var lastInstalledScriptSignature: String?
    private var lastAppliedEffectiveShield: Bool?
    private var lastAttachedRuleListGeneration: UInt64?
    private var lastAppliedUserAgentProfile: BrowserUserAgentProfile?
    private var lastAppliedAutoDarkMode: Bool?
    private var lastAppliedDarkConfigKey: String?
    private var lastCommittedDocumentKey: String?
    private var deferredRestoreURLString: String?
    private var isCapturingSnapshot: Bool = false
    private var needsSettingsSyncOnActivate: Bool = false
    private var lastOpenTabTimestamp: ContinuousClock.Instant?
    private struct PendingInlinePDFCapture {
        let generation: UInt64
        let sourceURL: URL
        let suggestedFilename: String
        var resolvedFilename: String
        var destinationURL: URL?
    }

    private struct PDFHistoryEntry {
        let sourceURL: URL
        let title: String
        let localFileURL: URL?
        let isTemporaryPreviewFile: Bool
        let pageIndex: Int
    }

    private var activeWKDownloads: [ObjectIdentifier: WKDownload] = [:]
    private var wkDownloadDestinations: [ObjectIdentifier: URL] = [:]
    private var pendingInlinePDFCapture: PendingInlinePDFCapture?
    private var inlinePDFDownloads: [ObjectIdentifier: PendingInlinePDFCapture] = [:]
    private var activeInlinePDFDownloadKey: ObjectIdentifier?
    private var inlinePDFProgressObservation: NSKeyValueObservation?
    private var inlinePDFGeneration: UInt64 = 0
    private var pdfBackStack: [PDFHistoryEntry] = []
    private var pdfForwardStack: [PDFHistoryEntry] = []
    private var pdfReturnAfterWebBackEntry: (entry: PDFHistoryEntry, webBackCountAtPush: Int)?
    private var approvedLANTrustCertHashes: Set<String> = []
    private var progressObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var backObservation: NSKeyValueObservation?
    private var forwardObservation: NSKeyValueObservation?
    private var underPageColorObservation: NSKeyValueObservation?
    private var themeColorObservation: NSKeyValueObservation?
    private var secureContentObservation: NSKeyValueObservation?

    public convenience override init() {
        self.init(isPrivate: false)
    }

    public convenience init(isPrivate: Bool) {
        self.init(id: UUID(), isPrivate: isPrivate)
    }

    public init(
        id: UUID,
        isPrivate: Bool,
        profileID: String? = nil,
        websiteDataStoreProvider: (@MainActor () -> WKWebsiteDataStore)? = nil,
        privateWebsiteDataStoreProvider: (@MainActor () -> WKWebsiteDataStore)? = nil,
        siteRuleProvider: (@MainActor (String) -> SiteRuleRecord?)? = nil,
        profileFingerprintSeedProvider: (@MainActor () -> String?)? = nil,
        profileUserAgentProvider: (@MainActor () -> BrowserUserAgentProfile?)? = nil,
        profileSearchProvider: (@MainActor () -> (BrowserSearchEngine, String))? = nil
    ) {
        self.id = id
        self.isPrivate = isPrivate
        self.profileID = isPrivate ? nil : (profileID ?? BrowserProfile.defaultID)
        self.websiteDataStoreProvider = websiteDataStoreProvider ?? privateWebsiteDataStoreProvider
        self.siteRuleProvider = siteRuleProvider
        self.profileFingerprintSeedProvider = profileFingerprintSeedProvider
        self.profileUserAgentProvider = profileUserAgentProvider
        self.profileSearchProvider = profileSearchProvider
        self.isShieldEnabled = CleanroomBrowserStore.persistedGlobalShieldEnabled
        self.privateFingerprintSeed = isPrivate ? FingerprintShieldEngine.generateCryptographicSeed() : nil
        // Lightweight init: defer `WKWebView` allocation until `ensureWebView()` on activation or navigation.
        self.mediaCapture = MediaCaptureCoordinator(webView: nil)
        super.init()
    }

    private var effectiveProfileUserAgent: BrowserUserAgentProfile {
        profileUserAgentProvider?() ?? BrowserUserAgentProfile.persistedCurrent
    }

    private var effectiveFingerprintSeed: String? {
        if isPrivate {
            return privateFingerprintSeed
        }
        guard FingerprintShieldEngine.shared.isEnabled else { return nil }
        return profileFingerprintSeedProvider?() ?? FingerprintShieldEngine.shared.standardSeed
    }

    /// Lazily instantiates the backing `WKWebView`, wires delegates/KVO/scripts, attaches `MediaCaptureCoordinator`,
    /// and seamlessly restores saved `interactionState` if this tab was previously hibernated.
    @discardableResult
    public func ensureWebView() -> WKWebView {
        if let existing = backingWebView {
            return existing
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = websiteDataStoreProvider?()
            ?? (isPrivate ? .nonPersistent() : .default())

        let initialHost = URL(string: currentURLString)?.host()
        let wv = configureAndInstallWebView(configuration: config, initialHost: initialHost)

        if let savedState = savedInteractionState {
            savedInteractionState = nil
            deferredRestoreURLString = nil
            syncContentBlockerForHostNavigation(initialHost)
            wv.interactionState = savedState
        }

        return wv
    }

    /// Instantiates the backing `WKWebView` directly from WebKit's `createWebViewWith` configuration
    /// so OAuth `window.opener.postMessage` and `window.close()` remain natively linked to the opener tab.
    @discardableResult
    internal func attachChildWebView(
        using configuration: WKWebViewConfiguration,
        initialURL: URL?
    ) -> WKWebView {
        if let existing = backingWebView {
            return existing
        }

        if let initialURL,
           let scheme = initialURL.scheme?.lowercased(),
           (scheme == "http" || scheme == "https") {
            currentURLString = initialURL.absoluteString
        }

        return configureAndInstallWebView(
            configuration: configuration,
            initialHost: initialURL?.host()
        )
    }

    private func configureAndInstallWebView(
        configuration config: WKWebViewConfiguration,
        initialHost: String?
    ) -> WKWebView {
        if websiteDataStoreProvider == nil || isPrivate {
            SystemProxyBridge.sync(dataStore: config.websiteDataStore)
        }
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let activeUAProfile = resolvedUserAgentProfile(
            global: effectiveProfileUserAgent,
            forHost: initialHost
        )
        let activeAutoDark = resolvedAutoDarkMode(
            global: CleanroomBrowserStore.persistedAutoWebPageDarkMode,
            forHost: initialHost
        )
        let activeZoom = resolvedPageZoom(forHost: initialHost)
        config.defaultWebpagePreferences.preferredContentMode = activeUAProfile.preferredContentMode

        // Always allocate an isolated `WKUserContentController` per tab (even for WebKit-provided
        // child configurations) so script handlers and teardown never collide with the opener tab.
        let contentController = WKUserContentController()
        if isPrivate, privateFingerprintSeed == nil {
            privateFingerprintSeed = FingerprintShieldEngine.generateCryptographicSeed()
        }
        let activeBootSeed = effectiveFingerprintSeed
        let blocker = CleanroomContentBlocker.shared
        let normalizedInitialHost = blocker.normalizeBypassHost(initialHost)
        let effectiveInitialShield = resolvedEffectiveShield(
            forHost: normalizedInitialHost,
            globalEnabled: isShieldEnabled
        )
        // Synchronous 0-frame pre-execution install of the complete script set + already-warm rule lists
        // so the very first navigation never triggers a redundant `removeAllUserScripts()` / `add(list)` cycle.
        blocker.installUserScripts(
            on: contentController,
            shieldEnabled: effectiveInitialShield,
            forHost: normalizedInitialHost,
            includeFingerprintShield: activeBootSeed != nil,
            fingerprintSeedOverride: activeBootSeed,
            userAgentProfileOverride: activeUAProfile,
            autoWebPageDarkModeOverride: activeAutoDark
        )
        if effectiveInitialShield && !blocker.compiledLists.isEmpty {
            for list in blocker.compiledLists {
                contentController.add(list)
            }
        }
        config.userContentController = contentController

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.isOpaque = true
        wv.backgroundColor = .systemBackground
        wv.scrollView.backgroundColor = .systemBackground
        if let activeBootSeed {
            wv.customUserAgent = FingerprintShieldEngine.persona(forSeed: activeBootSeed, profile: activeUAProfile).userAgent
        } else {
            wv.customUserAgent = activeUAProfile.userAgentString
        }
        wv.pageZoom = CGFloat(activeZoom)
        wv.allowsBackForwardNavigationGestures = true
        wv.isFindInteractionEnabled = true

        self.backingWebView = wv
        self.hasLiveWebView = true
        self.isHibernated = false
        self.pageZoom = activeZoom
        self.lastAppliedUserAgentProfile = activeUAProfile
        self.lastAppliedAutoDarkMode = activeAutoDark
        self.lastAppliedDarkConfigKey = Self.darkConfigKey(effectiveEnabled: activeAutoDark)
        self.lastInstalledScriptSignature = computeScriptSignature(forHost: normalizedInitialHost, shieldEnabled: isShieldEnabled)
        self.lastAppliedEffectiveShield = effectiveInitialShield
        self.lastAttachedRuleListGeneration = (effectiveInitialShield && !blocker.compiledLists.isEmpty) ? blocker.compiledListsGeneration : nil
        self.mediaCapture.attach(webView: wv)

        contentController.add(
            WeakScriptMessageProxy(target: self),
            name: BrowserInjectedScripts.snifferMessageHandlerName
        )
        contentController.addScriptMessageHandler(
            WeakDarkFetchMessageProxy(),
            contentWorld: .page,
            name: DarkReaderEngine.fetchMessageHandlerName
        )
        wv.navigationDelegate = self
        wv.uiDelegate = self

        installObservations(on: wv)

        blocker.registerController(
            contentController,
            profileID: profileID,
            currentHostProvider: { [weak self] in self?.activeNavigationHost },
            isEnabledProvider: { [weak self] in
                guard let self else { return false }
                return self.resolvedEffectiveShield(forHost: self.activeNavigationHost, globalEnabled: self.isShieldEnabled)
            },
            fingerprintSeedProvider: { [weak self] in
                self?.effectiveFingerprintSeed
            },
            userAgentProfileProvider: { [weak self] in
                guard let self else { return nil }
                return self.resolvedUserAgentProfile(global: self.effectiveProfileUserAgent)
            },
            autoWebPageDarkModeProvider: { [weak self] in
                guard let self else { return nil }
                return self.resolvedAutoDarkMode(global: CleanroomBrowserStore.persistedAutoWebPageDarkMode)
            }
        )

        if effectiveInitialShield && blocker.compiledLists.isEmpty {
            Task { @MainActor [weak self] in
                guard let self, self.backingWebView === wv else { return }
                let restored = await CleanroomContentBlocker.shared.fastRestoreCachedListsIfAvailable()
                guard self.backingWebView === wv, !restored.isEmpty else { return }
                self.syncContentBlockerForHostNavigation(self.activeNavigationHost)
            }
        }

        return wv
    }

    private func installObservations(on wv: WKWebView) {
        progressObservation = wv.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.backingWebView === view,
                      !self.isLoadingInlinePDF, self.activePDF == nil else { return }
                let next = view.estimatedProgress
                if next != self.estimatedProgress,
                   (next <= 0.01 || next >= 0.99 || abs(next - self.estimatedProgress) >= 0.03) {
                    self.estimatedProgress = next
                }
            }
        }
        titleObservation = wv.observe(\.title, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.backingWebView === view,
                      self.activePDF == nil, !self.isLoadingInlinePDF,
                      let title = view.title, !title.isEmpty, self.pageTitle != title else { return }
                self.pageTitle = title
            }
        }
        urlObservation = wv.observe(\.url, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.backingWebView === view,
                      self.activePDF == nil, !self.isLoadingInlinePDF,
                      let liveURL = view.url else { return }
                let str = liveURL.absoluteString
                if !str.isEmpty, self.currentURLString != str {
                    self.currentURLString = str
                }
                self.updateSecureConnectionState(for: view)
                self.mediaCapture.stageYouTubeURLIfApplicable(liveURL)
            }
        }
        backObservation = wv.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.backingWebView === view else { return }
                self.syncEffectiveNavigationState()
            }
        }
        forwardObservation = wv.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.backingWebView === view else { return }
                self.syncEffectiveNavigationState()
            }
        }
        underPageColorObservation = wv.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.backingWebView === view, !self.isSyntheticDarkActive else { return }
                if let color = view.themeColor ?? view.underPageBackgroundColor, self.pageCanvasColor != color {
                    self.pageCanvasColor = color
                    view.scrollView.backgroundColor = color
                }
            }
        }
        themeColorObservation = wv.observe(\.themeColor, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.backingWebView === view, !self.isSyntheticDarkActive else { return }
                if let color = view.themeColor ?? view.underPageBackgroundColor, self.pageCanvasColor != color {
                    self.pageCanvasColor = color
                    view.scrollView.backgroundColor = color
                }
            }
        }
        secureContentObservation = wv.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.backingWebView === view else { return }
                self.updateSecureConnectionState(for: view)
            }
        }
    }

    private func updateSecureConnectionState(for webView: WKWebView) {
        let isHTTPS = webView.url?.scheme?.lowercased() == "https"
        let next = isHTTPS && webView.hasOnlySecureContent
        if isSecureConnection != next {
            isSecureConnection = next
        }
    }

    // MARK: - Find in Page, PDF Export, History Navigation, Popups & Authenticated Headers

    public func presentFindInPage() {
        let wv = ensureWebView()
        wv.isFindInteractionEnabled = true
        wv.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    public func createCurrentPagePDF() async -> URL? {
        guard let wv = backingWebView else { return nil }
        let config = WKPDFConfiguration()
        guard let pdfData = try? await wv.pdf(configuration: config), !pdfData.isEmpty else {
            return nil
        }

        let rawBase: String = {
            let trimmedTitle = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty { return trimmedTitle }
            if let host = (wv.url ?? URL(string: currentURLString))?.host(), !host.isEmpty {
                return host
            }
            return "Page"
        }()
        let sanitizedStem = Self.sanitizeFilenameComponent(rawBase, fallback: "Page", maxLength: 80)
        let filename = sanitizedStem.lowercased().hasSuffix(".pdf") ? sanitizedStem : "\(sanitizedStem).pdf"

        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let folder = fm.temporaryDirectory.appendingPathComponent(
                "dys-tmp-pdf-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let fileURL = folder.appendingPathComponent(filename, isDirectory: false)
                try pdfData.write(to: fileURL, options: .atomic)
                return fileURL
            } catch {
                return nil
            }
        }.value
    }

    // MARK: - Native In-Tab PDF Lifecycle & Unified Navigation

    private var hasUnderlyingWebPage: Bool {
        guard let url = backingWebView?.url else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    private func syncEffectiveNavigationState() {
        let nextCanGoBack: Bool
        let nextCanGoForward: Bool
        if activePDF != nil {
            nextCanGoBack = !pdfBackStack.isEmpty || hasUnderlyingWebPage
            nextCanGoForward = !pdfForwardStack.isEmpty
        } else {
            let webBack = backingWebView?.canGoBack ?? false
            let hasPDFReturn = pdfReturnAfterWebBackEntry != nil
            nextCanGoBack = webBack || hasPDFReturn
            nextCanGoForward = (backingWebView?.canGoForward ?? false) || !pdfForwardStack.isEmpty
        }
        if canGoBack != nextCanGoBack {
            canGoBack = nextCanGoBack
        }
        if canGoForward != nextCanGoForward {
            canGoForward = nextCanGoForward
        }
    }

    /// Unified Back navigation handling Web ↔ Native PDF transitions smoothly (0 ms return to live webpage).
    public func navigateBack() {
        if let pdf = activePDF {
            let forwardEntry = PDFHistoryEntry(
                sourceURL: pdf.sourceURL,
                title: pdf.displayTitle,
                localFileURL: pdf.isTemporaryPreviewFile ? nil : pdf.localFileURL,
                isTemporaryPreviewFile: pdf.isTemporaryPreviewFile,
                pageIndex: pdf.currentPageIndex
            )
            pdfForwardStack.append(forwardEntry)

            if let previousPDF = pdfBackStack.popLast() {
                dismissActivePDF(restoreUnderlyingWebMetadata: false)
                restorePDFHistoryEntry(previousPDF)
                return
            }

            if hasUnderlyingWebPage {
                dismissActivePDF(restoreUnderlyingWebMetadata: true)
                return
            }

            // No underlying page or prior PDF; drop pushed forward entry and sync.
            _ = pdfForwardStack.popLast()
            syncEffectiveNavigationState()
            return
        }

        if let pendingReturn = pdfReturnAfterWebBackEntry {
            let currentWebBackCount = backingWebView?.backForwardList.backList.count ?? 0
            if currentWebBackCount <= pendingReturn.webBackCountAtPush {
                pdfReturnAfterWebBackEntry = nil
                restorePDFHistoryEntry(pendingReturn.entry)
                return
            }
        }

        backingWebView?.goBack()
        syncEffectiveNavigationState()
    }

    /// Unified Forward navigation handling Web ↔ Native PDF transitions.
    public func navigateForward() {
        if activePDF != nil {
            guard let nextPDF = pdfForwardStack.popLast() else { return }
            if let current = activePDF {
                pdfBackStack.append(
                    PDFHistoryEntry(
                        sourceURL: current.sourceURL,
                        title: current.displayTitle,
                        localFileURL: current.isTemporaryPreviewFile ? nil : current.localFileURL,
                        isTemporaryPreviewFile: current.isTemporaryPreviewFile,
                        pageIndex: current.currentPageIndex
                    )
                )
            }
            dismissActivePDF(restoreUnderlyingWebMetadata: false)
            restorePDFHistoryEntry(nextPDF)
            return
        }

        if let wv = backingWebView, wv.canGoForward {
            wv.goForward()
            syncEffectiveNavigationState()
            return
        }

        if let nextPDF = pdfForwardStack.popLast() {
            restorePDFHistoryEntry(nextPDF)
        }
    }

    /// Reloads either the active native PDF or the active `WKWebView` page.
    public func reloadCurrentContent() {
        if let pdf = activePDF {
            if pdf.isLocalFileSource {
                openLocalPDF(
                    fileURL: pdf.localFileURL,
                    displayTitle: pdf.displayTitle,
                    isTemporaryPreviewFile: pdf.isTemporaryPreviewFile,
                    initialPageIndex: pdf.currentPageIndex
                )
            } else {
                let targetURL = pdf.sourceURL
                dismissActivePDF(restoreUnderlyingWebMetadata: false)
                load(urlString: targetURL.absoluteString, clearPreviousStreams: true)
            }
            return
        }
        backingWebView?.reload()
    }

    /// Stops either an in-flight inline PDF stream or `WKWebView` load.
    public func stopCurrentLoad() {
        if isLoadingInlinePDF {
            cancelActiveInlinePDFDownload()
            isLoading = false
            estimatedProgress = 0
            if activePDF == nil, let wv = backingWebView, let liveURL = wv.url {
                currentURLString = liveURL.absoluteString
                if let title = wv.title, !title.isEmpty {
                    pageTitle = title
                }
                updateSecureConnectionState(for: wv)
            }
            syncEffectiveNavigationState()
            return
        }
        backingWebView?.stopLoading()
    }

    /// Opens an external HTTP(S) hyperlink tapped inside an active PDF while remembering the PDF for Back.
    public func openURLFromPDF(_ url: URL) {
        if let current = activePDF {
            let entry = PDFHistoryEntry(
                sourceURL: current.sourceURL,
                title: current.displayTitle,
                localFileURL: current.isTemporaryPreviewFile ? nil : current.localFileURL,
                isTemporaryPreviewFile: current.isTemporaryPreviewFile,
                pageIndex: current.currentPageIndex
            )
            let backDepth = backingWebView?.backForwardList.backList.count ?? 0
            pdfReturnAfterWebBackEntry = (entry: entry, webBackCountAtPush: backDepth)
        }
        load(urlString: url.absoluteString, clearPreviousStreams: true, preservePDFReturnEntry: true)
    }

    /// Opens a local on-disk `.pdf` file (e.g. from Downloads Vault or iOS Files) directly inside this tab.
    public func openLocalPDF(
        fileURL: URL,
        displayTitle: String? = nil,
        isTemporaryPreviewFile: Bool = false,
        sourceURLOverride: URL? = nil,
        initialPageIndex: Int = 0,
        preserveNavigationHistory: Bool = false
    ) {
        cancelActiveInlinePDFDownload()
        dismissActivePDF(restoreUnderlyingWebMetadata: false)
        deferredRestoreURLString = nil
        savedInteractionState = nil
        lastLoadError = nil
        lastBlockedPopupURL = nil
        if !preserveNavigationHistory {
            pdfForwardStack.removeAll()
            pdfReturnAfterWebBackEntry = nil
        }

        let sourceURL = sourceURLOverride ?? fileURL
        let fallbackName = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFilename = PDFTabDocument.sanitizePDFFilename(
            (fallbackName?.isEmpty == false ? fallbackName! : fileURL.lastPathComponent)
        )

        isLoading = true
        isLoadingInlinePDF = true
        estimatedProgress = 0.25
        currentURLString = sourceURL.absoluteString
        pageTitle = (resolvedFilename as NSString).deletingPathExtension

        inlinePDFGeneration &+= 1
        let gen = inlinePDFGeneration
        let appearance = PDFAppearanceMode.persistedCurrent

        Task { @MainActor [weak self] in
            let parsed = await Task.detached(priority: .userInitiated) { () -> (PDFTransferBox<ThemedPDFDocument>, Int64, [PDFOutlineNode], UIImage?)? in
                guard let doc = ThemedPDFDocument(url: fileURL) else { return nil }
                doc.appearanceMode = appearance
                let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                let outline = doc.isLocked ? [] : doc.extractOutlineNodes()
                let thumb: UIImage? = doc.renderThemedThumbnail(pageIndex: 0, maxDimension: 300)
                return (PDFTransferBox(doc), size, outline, thumb)
            }.value

            guard let self, self.inlinePDFGeneration == gen else {
                if isTemporaryPreviewFile {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                return
            }

            self.isLoading = false
            self.isLoadingInlinePDF = false
            self.estimatedProgress = 1.0

            guard let (docBox, byteCount, outline, thumb) = parsed else {
                if isTemporaryPreviewFile {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                self.lastLoadError = WebLoadError(
                    urlString: sourceURL.absoluteString,
                    domain: "DysprosiumPDFErrorDomain",
                    code: -1,
                    localizedDescription: L("Unable to open PDF document (\(resolvedFilename))."),
                    isTLSFailure: false
                )
                self.syncEffectiveNavigationState()
                return
            }

            let pdfTabDoc = PDFTabDocument(
                sourceURL: sourceURL,
                localFileURL: fileURL,
                isTemporaryPreviewFile: isTemporaryPreviewFile,
                suggestedFilename: resolvedFilename,
                fileByteCount: byteCount,
                document: docBox.value,
                initialAppearance: appearance,
                initialOutline: outline
            )
            if initialPageIndex > 0, initialPageIndex < pdfTabDoc.pageCount {
                pdfTabDoc.currentPageIndex = initialPageIndex
            }
            self.activePDF = pdfTabDoc
            self.currentURLString = sourceURL.absoluteString
            self.pageTitle = pdfTabDoc.displayTitle
            self.isSecureConnection = (sourceURL.scheme?.lowercased() == "https")
            if let thumb {
                self.previewSnapshot = thumb
            }
            self.syncEffectiveNavigationState()

            if !self.isPrivate,
               let scheme = sourceURL.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                self.onNavigationCommitted?(sourceURL, pdfTabDoc.displayTitle)
            }
        }
    }

    /// Atomically saves the active untouched original PDF into Dysprosium's Downloads Vault
    /// without re-downloading a single byte over the network.
    public func saveActivePDFToVault() async -> URL? {
        guard let pdf = activePDF else { return nil }
        if let alreadySaved = pdf.savedVaultURL, FileManager.default.fileExists(atPath: alreadySaved.path) {
            return alreadySaved
        }
        if pdf.isSavedInVault {
            pdf.savedVaultURL = pdf.localFileURL
            return pdf.localFileURL
        }

        let sourceFile = pdf.localFileURL
        let desiredFilename = pdf.suggestedFilename
        let targetDir = LiveContainerEnvironment.downloadsDirectory
        let saved: URL? = await Task.detached(priority: .userInitiated) {
            try? LiveContainerEnvironment.commitStagedFile(
                from: sourceFile,
                toDirectory: targetDir,
                preferredFilename: desiredFilename,
                removeSource: false
            )
        }.value

        if let saved {
            if activePDF?.id == pdf.id {
                pdf.savedVaultURL = saved
            }
            onPDFSavedToVault?(saved)
        }
        return saved
    }

    private func restorePDFHistoryEntry(_ entry: PDFHistoryEntry) {
        if let local = entry.localFileURL, !entry.isTemporaryPreviewFile,
           FileManager.default.fileExists(atPath: local.path) {
            openLocalPDF(
                fileURL: local,
                displayTitle: entry.title,
                isTemporaryPreviewFile: false,
                sourceURLOverride: entry.sourceURL,
                initialPageIndex: entry.pageIndex,
                preserveNavigationHistory: true
            )
        } else {
            load(urlString: entry.sourceURL.absoluteString, clearPreviousStreams: true, preservePDFReturnEntry: true)
        }
    }

    private func dismissActivePDF(restoreUnderlyingWebMetadata: Bool) {
        guard let existing = activePDF else { return }
        activePDF = nil
        existing.dismissSearch()
        existing.cleanupTemporaryFileIfNeeded()

        if restoreUnderlyingWebMetadata, let wv = backingWebView {
            if let liveURL = wv.url {
                currentURLString = liveURL.absoluteString
            }
            if let liveTitle = wv.title, !liveTitle.isEmpty {
                pageTitle = liveTitle
            }
            updateSecureConnectionState(for: wv)
            syncPageCanvasColor(from: wv)
        }
        syncEffectiveNavigationState()
    }

    private func cancelActiveInlinePDFDownload() {
        inlinePDFGeneration &+= 1
        pendingInlinePDFCapture = nil
        inlinePDFProgressObservation?.invalidate()
        inlinePDFProgressObservation = nil
        isLoadingInlinePDF = false

        let keys = Array(inlinePDFDownloads.keys)
        for key in keys {
            if let capture = inlinePDFDownloads.removeValue(forKey: key),
               let tempDest = capture.destinationURL {
                try? FileManager.default.removeItem(at: tempDest)
            }
            if let download = activeWKDownloads.removeValue(forKey: key) {
                download.cancel(nil)
            }
            wkDownloadDestinations.removeValue(forKey: key)
        }
        activeInlinePDFDownloadKey = nil
        hasActiveWKDownload = !activeWKDownloads.isEmpty
    }

    public func buildHostScopedDownloadHeaders(for targetURL: URL) async -> [String: String] {
        let dataStore: WKWebsiteDataStore
        if let wv = backingWebView {
            dataStore = wv.configuration.websiteDataStore
        } else if let provided = websiteDataStoreProvider?() {
            dataStore = provided
        } else if isPrivate {
            dataStore = .nonPersistent()
        } else {
            dataStore = .default()
        }

        let targetHost = targetURL.host() ?? ""
        let isSecure = targetURL.scheme?.lowercased() == "https"
        let allCookies = await dataStore.httpCookieStore.allCookies()
        let cookieHeader = MediaCaptureCoordinator.buildCookieHeader(
            cookies: allCookies,
            for: targetURL
        )

        var headers: [String: String] = [:]
        if !cookieHeader.isEmpty {
            headers["Cookie"] = cookieHeader
        }

        if let liveUA = backingWebView?.customUserAgent, !liveUA.isEmpty {
            headers["User-Agent"] = liveUA
        } else {
            let profile = resolvedUserAgentProfile(
                global: effectiveProfileUserAgent,
                forHost: targetHost
            )
            if let activeSeed = effectiveFingerprintSeed {
                headers["User-Agent"] = FingerprintShieldEngine.persona(forSeed: activeSeed, profile: profile).userAgent
            } else {
                headers["User-Agent"] = profile.userAgentString
            }
        }

        if let refererURL = backingWebView?.url ?? URL(string: currentURLString),
           let refScheme = refererURL.scheme?.lowercased(),
           (refScheme == "http" || refScheme == "https") {
            // Respect no-referrer-when-downgrade (never leak HTTPS referer to plaintext HTTP download).
            if !(refScheme == "https" && !isSecure) {
                headers["Referer"] = refererURL.absoluteString
            }
        }

        return headers
    }

    public var backHistoryItems: [WebBackForwardItemSummary] {
        guard let list = backingWebView?.backForwardList else { return [] }
        return list.backList.reversed().prefix(15).enumerated().map { index, item in
            let rawTitle = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = rawTitle.isEmpty ? (item.url.host() ?? item.url.absoluteString) : rawTitle
            return WebBackForwardItemSummary(
                id: -(index + 1),
                title: displayTitle,
                url: item.url
            )
        }
    }

    public var forwardHistoryItems: [WebBackForwardItemSummary] {
        guard let list = backingWebView?.backForwardList else { return [] }
        return list.forwardList.prefix(15).enumerated().map { index, item in
            let rawTitle = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = rawTitle.isEmpty ? (item.url.host() ?? item.url.absoluteString) : rawTitle
            return WebBackForwardItemSummary(
                id: index + 1,
                title: displayTitle,
                url: item.url
            )
        }
    }

    public func navigateBackForward(offset: Int) {
        guard offset != 0, let wv = backingWebView else { return }
        guard let item = wv.backForwardList.item(at: offset) else { return }
        lastLoadError = nil
        wv.go(to: item)
    }

    public func retryLastFailedLoad() {
        let failedURL = lastLoadError?.urlString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lastLoadError = nil
        if !failedURL.isEmpty {
            if let ds = backingWebView?.configuration.websiteDataStore {
                SystemProxyBridge.sync(dataStore: ds)
            }
            load(urlString: failedURL, clearPreviousStreams: false)
        } else if let wv = backingWebView {
            SystemProxyBridge.sync(dataStore: wv.configuration.websiteDataStore)
            wv.reload()
        } else if !currentURLString.isEmpty {
            load(urlString: currentURLString, clearPreviousStreams: false)
        }
    }

    public func allowLastBlockedPopup() {
        guard let url = lastBlockedPopupURL else { return }
        lastBlockedPopupURL = nil
        if let onOpenLinkInTab {
            onOpenLinkInTab(url, isPrivate, true)
        } else {
            load(urlString: url.absoluteString)
        }
    }

    public func dismissBlockedPopupBanner() {
        lastBlockedPopupURL = nil
    }

    // MARK: - Host Normalization & Content Blocker Synchronization

    private var activeNavigationHost: String? {
        CleanroomContentBlocker.shared.normalizeBypassHost(
            (backingWebView?.url ?? URL(string: currentURLString))?.host()
        )
    }

    private func resolvedUserAgentProfile(
        global: BrowserUserAgentProfile,
        forHost hostOverride: String? = nil
    ) -> BrowserUserAgentProfile {
        let candidateHost = hostOverride ?? activeNavigationHost
        if let candidateHost,
           let rule = siteRuleProvider?(candidateHost) {
            if rule.uaMode == 1 { return .iosSafari }
            if rule.uaMode == 2 { return .macosSafari }
        }
        return global
    }

    private func resolvedAutoDarkMode(
        global: Bool,
        forHost hostOverride: String? = nil
    ) -> Bool {
        let candidateHost = hostOverride ?? activeNavigationHost
        if let candidateHost,
           let rule = siteRuleProvider?(candidateHost) {
            if rule.darkMode == 1 { return true }
            if rule.darkMode == -1 { return false }
        }
        return global
    }

    private func resolvedEffectiveShield(
        forHost hostOverride: String? = nil,
        globalEnabled: Bool? = nil
    ) -> Bool {
        let effectiveGlobal = globalEnabled ?? isShieldEnabled
        let candidateHost = hostOverride ?? activeNavigationHost
        if let candidateHost,
           let rule = siteRuleProvider?(candidateHost) {
            if rule.shieldMode == 1 { return true }
            if rule.shieldMode == -1 { return false }
        }
        if profileID == nil || profileID == BrowserProfile.defaultID {
            return CleanroomContentBlocker.shared.effectiveShieldEnabled(
                globalEnabled: effectiveGlobal,
                forHost: candidateHost
            )
        }
        return effectiveGlobal
    }

    private func resolvedPageZoom(forHost hostOverride: String? = nil) -> Double {
        let candidateHost = hostOverride ?? activeNavigationHost
        if let candidateHost,
           let zoom = siteRuleProvider?(candidateHost)?.pageZoom {
            return SiteRuleRecord.clampedZoom(zoom)
        }
        return 1.0
    }

    /// Keyed strictly on effective injected script inputs (NOT raw hostname) so routine cross-site
    /// navigations across the ~95% of websites with zero per-host scriptlets skip `removeAllUserScripts()`
    /// and retain JavaScriptCore's compiled bytecode cache across navigations.
    private func computeScriptSignature(forHost host: String?, shieldEnabled: Bool) -> String {
        let blocker = CleanroomContentBlocker.shared
        let h = blocker.normalizeBypassHost(host)
        let effective = resolvedEffectiveShield(forHost: h, globalEnabled: shieldEnabled)
        let ua = resolvedUserAgentProfile(global: effectiveProfileUserAgent, forHost: h).rawValue
        let autoDark = resolvedAutoDarkMode(global: CleanroomBrowserStore.persistedAutoWebPageDarkMode, forHost: h)
        let dark = DarkReaderEngine.shared
        let darkBehavior = dark.modeBehavior
        let darkPreset = dark.themePreset
        let needsDarkDetector: Bool = {
            guard autoDark, let h, !h.isEmpty else { return false }
            if (profileID == nil || profileID == BrowserProfile.defaultID) && dark.isHostBypassed(h) { return false }
            return !darkPreset.isDarkScheme || !dark.isKnownNativeDarkHostIfCached(h)
        }()
        let darkKey = needsDarkDetector ? "1:\(darkBehavior.rawValue):\(darkPreset.rawValue)" : "0"
        let activeSeed = effectiveFingerprintSeed ?? ""
        let maskScreen = FingerprintShieldEngine.shared.maskFoldableScreen ? "1" : "0"
        let hasDefuser = (effective && blocker.hasEnabledAntiAdblockSubscription) ? "1" : "0"
        let scriptletKey = effective ? blocker.scriptletCacheKey(forHost: h) : ""
        return "\(effective ? "1" : "0")|\(ua)|\(darkKey)|\(activeSeed)|\(maskScreen)|\(hasDefuser)|\(scriptletKey)"
    }

    private func recordAppliedBlockerState(forHost host: String?, shieldEnabled: Bool) {
        let blocker = CleanroomContentBlocker.shared
        let normalized = blocker.normalizeBypassHost(host)
        let effective = resolvedEffectiveShield(forHost: normalized, globalEnabled: shieldEnabled)
        lastInstalledScriptSignature = computeScriptSignature(forHost: normalized, shieldEnabled: shieldEnabled)
        lastAppliedEffectiveShield = effective
        lastAttachedRuleListGeneration = (effective && !blocker.compiledLists.isEmpty) ? blocker.compiledListsGeneration : nil
    }

    /// Synchronizes user scripts and `WKContentRuleList` attachment independently before a main-frame
    /// navigation begins. Never re-IPCs the 112k-rule `WKContentRuleList` or tears down `WKUserScript`s
    /// unless the effective rule generation or effective script inputs actually changed.
    private func syncContentBlockerForHostNavigation(_ targetHost: String?) {
        guard let wv = backingWebView else { return }
        let blocker = CleanroomContentBlocker.shared
        let normalized = blocker.normalizeBypassHost(targetHost)
        let effective = resolvedEffectiveShield(forHost: normalized, globalEnabled: isShieldEnabled)
        let sig = computeScriptSignature(forHost: normalized, shieldEnabled: isShieldEnabled)

        let controller = wv.configuration.userContentController
        let scriptsNeedUpdate = (sig != lastInstalledScriptSignature)
        let ruleListsNeedUpdate: Bool = {
            if effective != lastAppliedEffectiveShield {
                return true
            }
            if effective, !blocker.compiledLists.isEmpty, lastAttachedRuleListGeneration != blocker.compiledListsGeneration {
                return true
            }
            return false
        }()

        if scriptsNeedUpdate {
            lastInstalledScriptSignature = sig
            let activeSeed = effectiveFingerprintSeed
            let effectiveUA = resolvedUserAgentProfile(
                global: effectiveProfileUserAgent,
                forHost: normalized
            )
            let effectiveDark = resolvedAutoDarkMode(
                global: CleanroomBrowserStore.persistedAutoWebPageDarkMode,
                forHost: normalized
            )

            blocker.installUserScripts(
                on: controller,
                shieldEnabled: effective,
                forHost: normalized,
                includeFingerprintShield: activeSeed != nil,
                fingerprintSeedOverride: activeSeed,
                userAgentProfileOverride: effectiveUA,
                autoWebPageDarkModeOverride: effectiveDark
            )
        } else {
            blocker.pruneSubframeScriptletsIfMainHostChanged(to: normalized, on: controller)
        }

        if ruleListsNeedUpdate {
            lastAppliedEffectiveShield = effective
            controller.removeAllContentRuleLists()
            if effective {
                if !blocker.compiledLists.isEmpty {
                    for list in blocker.compiledLists {
                        controller.add(list)
                    }
                    lastAttachedRuleListGeneration = blocker.compiledListsGeneration
                } else {
                    lastAttachedRuleListGeneration = nil
                    Task { @MainActor [weak self] in
                        guard let self, self.backingWebView === wv else { return }
                        let restored = await CleanroomContentBlocker.shared.fastRestoreCachedListsIfAvailable()
                        guard self.backingWebView === wv, !restored.isEmpty else { return }
                        self.syncContentBlockerForHostNavigation(self.activeNavigationHost)
                    }
                }
            } else {
                lastAttachedRuleListGeneration = nil
            }
        }
    }

    private static func documentKey(for url: URL?) -> String? {
        guard let url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        comps.fragment = nil
        return comps.string ?? url.absoluteString
    }

    // MARK: - Shield, User-Agent & Appearance Controls

    public func setShieldEnabled(_ enabled: Bool) {
        guard isShieldEnabled != enabled else { return }
        isShieldEnabled = enabled
        guard let wv = backingWebView else { return }
        let host = activeNavigationHost
        let effectiveShield = resolvedEffectiveShield(forHost: host, globalEnabled: enabled)
        let controller = wv.configuration.userContentController
        recordAppliedBlockerState(forHost: host, shieldEnabled: enabled)
        Task { @MainActor [weak self] in
            await CleanroomContentBlocker.shared.apply(enabled: effectiveShield, to: controller, forHost: host)
            self?.backingWebView?.reload()
        }
    }

    /// Re-evaluates per-site shield rules (`WKContentRuleList` + host scriptlets) for the current host
    /// and reloads when the effective shield decision changed.
    public func syncShieldRulesForCurrentHost(reloadIfChanged: Bool = true) {
        guard let wv = backingWebView else { return }
        let host = activeNavigationHost
        let effectiveShield = resolvedEffectiveShield(forHost: host, globalEnabled: isShieldEnabled)
        let changed = (lastAppliedEffectiveShield != effectiveShield)
        guard changed else { return }
        let controller = wv.configuration.userContentController
        recordAppliedBlockerState(forHost: host, shieldEnabled: isShieldEnabled)
        Task { @MainActor [weak self] in
            await CleanroomContentBlocker.shared.apply(enabled: effectiveShield, to: controller, forHost: host)
            if reloadIfChanged, let self, !self.currentURLString.isEmpty, self.deferredRestoreURLString == nil {
                self.backingWebView?.reload()
            }
        }
    }

    /// Synchronizes `WKWebView.customUserAgent` after a fingerprint seed rotation or shield toggle
    /// so HTTP/Worker `User-Agent` headers stay paired with the injected JS persona.
    public func refreshCustomUserAgentForActivePersona() {
        guard let wv = backingWebView else { return }
        let effectiveProfile = resolvedUserAgentProfile(global: effectiveProfileUserAgent)
        if let activeSeed = effectiveFingerprintSeed {
            wv.customUserAgent = FingerprintShieldEngine.persona(forSeed: activeSeed, profile: effectiveProfile).userAgent
        } else {
            wv.customUserAgent = effectiveProfile.userAgentString
        }
    }

    public func toggleShield() {
        setShieldEnabled(!isShieldEnabled)
    }

    public func applyPageZoom(_ zoom: Double) {
        let clamped = SiteRuleRecord.clampedZoom(zoom)
        pageZoom = clamped
        backingWebView?.pageZoom = CGFloat(clamped)
    }

    public func markNeedsSettingsSyncOnActivate() {
        needsSettingsSyncOnActivate = true
    }

    public func syncDeferredSettingsIfNeeded(
        userAgentProfile: BrowserUserAgentProfile,
        autoWebPageDarkMode: Bool
    ) {
        guard needsSettingsSyncOnActivate else { return }
        needsSettingsSyncOnActivate = false
        // Dormant or hibernated tabs will pick up the latest settings automatically in `ensureWebView()`.
        guard backingWebView != nil else { return }

        let effectiveUA = resolvedUserAgentProfile(global: userAgentProfile)
        let effectiveDark = resolvedAutoDarkMode(global: autoWebPageDarkMode)
        let effectiveZoom = resolvedPageZoom()
        if abs(pageZoom - effectiveZoom) > 0.001 {
            applyPageZoom(effectiveZoom)
        }

        let effectiveShield = resolvedEffectiveShield(forHost: activeNavigationHost, globalEnabled: isShieldEnabled)
        let shieldChanged = (lastAppliedEffectiveShield != effectiveShield)

        // Compare against `lastAppliedUserAgentProfile` instead of raw `webView.customUserAgent`
        // so Fingerprint Shield persona UAs never trigger spurious `reloadFromOrigin()` on tab switches.
        let uaChanged = (lastAppliedUserAgentProfile != effectiveUA)
        let desiredDarkKey = Self.darkConfigKey(effectiveEnabled: effectiveDark)
        if shieldChanged {
            if uaChanged {
                applyUserAgentProfile(effectiveUA, reloadIfLoaded: false)
                lastAppliedAutoDarkMode = effectiveDark
                lastAppliedDarkConfigKey = desiredDarkKey
            } else if lastAppliedAutoDarkMode != effectiveDark || lastAppliedDarkConfigKey != desiredDarkKey {
                applyAutoWebPageDarkMode(effectiveDark)
            }
            syncShieldRulesForCurrentHost(reloadIfChanged: true)
        } else if uaChanged {
            applyUserAgentProfile(effectiveUA, reloadIfLoaded: true)
            lastAppliedAutoDarkMode = effectiveDark
            lastAppliedDarkConfigKey = desiredDarkKey
        } else if lastAppliedAutoDarkMode != effectiveDark || lastAppliedDarkConfigKey != desiredDarkKey {
            applyAutoWebPageDarkMode(effectiveDark)
        }
    }

    private static func darkConfigKey(effectiveEnabled: Bool) -> String {
        let dark = DarkReaderEngine.shared
        return "\(effectiveEnabled ? "1" : "0")|\(dark.modeBehavior.rawValue)|\(dark.themePreset.rawValue)"
    }

    public func applyUserAgentProfile(_ profile: BrowserUserAgentProfile, reloadIfLoaded: Bool = true) {
        let effectiveProfile = resolvedUserAgentProfile(global: profile)
        lastAppliedUserAgentProfile = effectiveProfile
        guard let wv = backingWebView else { return }

        wv.configuration.defaultWebpagePreferences.preferredContentMode = effectiveProfile.preferredContentMode
        let activeSeed = effectiveFingerprintSeed
        if let activeSeed {
            wv.customUserAgent = FingerprintShieldEngine.persona(forSeed: activeSeed, profile: effectiveProfile).userAgent
        } else {
            wv.customUserAgent = effectiveProfile.userAgentString
        }
        let host = activeNavigationHost
        let effectiveShield = resolvedEffectiveShield(forHost: host, globalEnabled: isShieldEnabled)
        recordAppliedBlockerState(forHost: host, shieldEnabled: isShieldEnabled)
        CleanroomContentBlocker.shared.installUserScripts(
            on: wv.configuration.userContentController,
            shieldEnabled: effectiveShield,
            forHost: host,
            includeFingerprintShield: activeSeed != nil,
            fingerprintSeedOverride: activeSeed,
            userAgentProfileOverride: effectiveProfile
        )
        if reloadIfLoaded, !currentURLString.isEmpty, deferredRestoreURLString == nil {
            wv.reloadFromOrigin()
        }
    }

    public func applyAutoWebPageDarkMode(_ enabled: Bool) {
        let effectiveEnabled = resolvedAutoDarkMode(global: enabled)
        lastAppliedAutoDarkMode = effectiveEnabled
        lastAppliedDarkConfigKey = Self.darkConfigKey(effectiveEnabled: effectiveEnabled)
        guard let wv = backingWebView else { return }

        let host = activeNavigationHost
        let effectiveShield = resolvedEffectiveShield(forHost: host, globalEnabled: isShieldEnabled)
        recordAppliedBlockerState(forHost: host, shieldEnabled: isShieldEnabled)
        let activeSeed = effectiveFingerprintSeed
        CleanroomContentBlocker.shared.installUserScripts(
            on: wv.configuration.userContentController,
            shieldEnabled: effectiveShield,
            forHost: host,
            includeFingerprintShield: activeSeed != nil,
            fingerprintSeedOverride: activeSeed,
            autoWebPageDarkModeOverride: effectiveEnabled
        )
        guard deferredRestoreURLString == nil, !currentURLString.isEmpty else { return }

        let dark = DarkReaderEngine.shared
        let behavior = dark.modeBehavior
        let preset = dark.themePreset
        let updateScript = dark.makeLiveConfigUpdateScript(
            forHost: host,
            enabled: effectiveEnabled,
            behavior: behavior,
            preset: preset
        )
        wv.evaluateJavaScript(updateScript) { [weak self] result, _ in
            Task { @MainActor [weak self] in
                guard let self, let liveWV = self.backingWebView, liveWV === wv else { return }
                if effectiveEnabled,
                   (result as? String) == "missing",
                   (!preset.isDarkScheme || !DarkReaderEngine.shared.isKnownNativeDarkHost(host)) {
                    // Inject the lightweight detector directly onto the already-loaded DOM (zero page reload).
                    if let detectorJS = DarkReaderEngine.shared.makeDetectorUserScriptSource(
                        forHost: host,
                        enabled: true,
                        behavior: behavior,
                        preset: preset
                    ) {
                        _ = try? await liveWV.evaluateJavaScript(detectorJS)
                    } else {
                        liveWV.reload()
                    }
                } else {
                    self.syncPageCanvasColor(from: liveWV)
                }
            }
        }
    }

    public func setMediaPlaybackSuspended(_ suspended: Bool) {
        backingWebView?.setAllMediaPlaybackSuspended(suspended)
        if suspended, lastKnownMediaPlaybackState == .playing {
            lastKnownMediaPlaybackState = .suspended
        }
    }

    /// Clears in-memory `sessionStorage` and `localStorage` on this tab if its `WKWebView` is currently live.
    public func clearLiveWebStorageIfLoaded() async {
        guard let wv = backingWebView else { return }
        _ = try? await wv.evaluateJavaScript(
            "try { sessionStorage.clear(); localStorage.clear(); } catch (_) {}"
        )
    }

    /// Returns true if this tab's current host matches any normalized domain in `normalizedDomains`.
    public func matchesDomainSet(_ normalizedDomains: Set<String>) -> Bool {
        guard let host = activeNavigationHost, !host.isEmpty else { return false }
        let cleanHost = LiveContainerEnvironment.HostNormalizer.normalize(host)
        return normalizedDomains.contains { target in
            cleanHost == target || cleanHost.hasSuffix(".\(target)") || target.hasSuffix(".\(cleanHost)")
        }
    }

    // MARK: - Tab Lifecycle, Hibernation & Navigation

    /// Stages a persisted background tab URL without allocating a `WKWebView` or spawning network/JS work
    /// until the user actually switches to this tab (`hydrateDeferredURLIfNeeded`).
    public func stageDeferredRestore(urlString: String, title: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentURLString = trimmed
        if !title.isEmpty {
            pageTitle = title
        }
        deferredRestoreURLString = trimmed
    }

    /// Loads the deferred URL on first tab activation (true Lazy Tab Hydration) or restores a hibernated tab.
    public func hydrateDeferredURLIfNeeded() {
        if let pending = deferredRestoreURLString {
            deferredRestoreURLString = nil
            load(urlString: pending, clearPreviousStreams: true)
            return
        }
        if isHibernated || savedInteractionState != nil {
            _ = ensureWebView()
        }
    }

    /// Captures `WKWebView.interactionState`, detaches all delegates/KVO/script handlers cleanly,
    /// and releases the `WKWebView` to reclaim its `WebContent` process RAM.
    /// Restores seamlessly when `ensureWebView()` / `hydrateDeferredURLIfNeeded()` is called on re-activation.
    public func hibernateWebView() {
        cancelPendingDialogsAndChallenges()
        lastBlockedPopupURL = nil
        guard let wv = backingWebView else { return }
        if activePDF == nil {
            if let liveURL = wv.url?.absoluteString, !liveURL.isEmpty {
                currentURLString = liveURL
            }
            if let liveTitle = wv.title, !liveTitle.isEmpty {
                pageTitle = liveTitle
            }
            canGoBack = wv.canGoBack
            canGoForward = wv.canGoForward
        }
        if !currentURLString.isEmpty {
            savedInteractionState = wv.interactionState
        }
        detachWebViewResources(wv)
        isHibernated = !currentURLString.isEmpty
    }

    /// Releases cached preview bitmap under iOS memory pressure for inactive tabs.
    public func purgePreviewSnapshotForMemoryRelief() {
        previewSnapshot = nil
    }

    public func teardown() {
        cancelPendingDialogsAndChallenges()
        cancelActiveInlinePDFDownload()
        dismissActivePDF(restoreUnderlyingWebMetadata: false)
        cancelActiveWKDownloads()
        pdfBackStack.removeAll()
        pdfForwardStack.removeAll()
        pdfReturnAfterWebBackEntry = nil
        mediaCapture.clear()
        savedInteractionState = nil
        deferredRestoreURLString = nil
        previewSnapshot = nil
        lastLoadError = nil
        lastBlockedPopupURL = nil
        approvedLANTrustCertHashes.removeAll()
        isHibernated = false
        isSecureConnection = false
        if let wv = backingWebView {
            detachWebViewResources(wv)
        }
        onOpenLinkInTab = nil
        onNavigationCommitted = nil
        onEnqueueBrowserDownload = nil
        onWKDownloadFinished = nil
        onWKDownloadFailed = nil
        onPDFSavedToVault = nil
        onShareURL = nil
        onCreateChildWebViewTab = nil
        onRequestCloseSelf = nil
        onRotateProfileFingerprintSeed = nil
        onUpdateSiteRule = nil
    }

    private func cancelPendingDialogsAndChallenges() {
        if let dialog = activeJSDialog {
            activeJSDialog = nil
            dialog.cancel()
        }
        if let challenge = activeAuthChallenge {
            activeAuthChallenge = nil
            challenge.cancel()
        }
    }

    private func cancelActiveWKDownloads() {
        inlinePDFProgressObservation?.invalidate()
        inlinePDFProgressObservation = nil
        pendingInlinePDFCapture = nil
        for (_, capture) in inlinePDFDownloads {
            if let dest = capture.destinationURL {
                try? FileManager.default.removeItem(at: dest)
            }
        }
        inlinePDFDownloads.removeAll()
        activeInlinePDFDownloadKey = nil
        isLoadingInlinePDF = false

        let downloads = Array(activeWKDownloads.values)
        activeWKDownloads.removeAll()
        wkDownloadDestinations.removeAll()
        hasActiveWKDownload = false
        for download in downloads {
            download.cancel(nil)
        }
    }

    private func detachWebViewResources(_ wv: WKWebView) {
        cancelPendingDialogsAndChallenges()
        wv.setAllMediaPlaybackSuspended(true)
        wv.stopLoading()
        wv.removeFromSuperview()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        progressObservation = nil
        titleObservation = nil
        urlObservation = nil
        backObservation = nil
        forwardObservation = nil
        underPageColorObservation = nil
        themeColorObservation = nil
        secureContentObservation = nil
        let controller = wv.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        controller.removeScriptMessageHandler(forName: BrowserInjectedScripts.snifferMessageHandlerName)
        controller.removeScriptMessageHandler(forName: DarkReaderEngine.fetchMessageHandlerName, contentWorld: .page)
        backingWebView = nil
        hasLiveWebView = false
        isLoading = false
        isSecureConnection = false
        estimatedProgress = 0
        isCapturingSnapshot = false
        lastInstalledScriptSignature = nil
        lastAppliedEffectiveShield = nil
        lastAttachedRuleListGeneration = nil
        lastAppliedUserAgentProfile = nil
        lastAppliedAutoDarkMode = nil
        lastAppliedDarkConfigKey = nil
        lastKnownMediaPlaybackState = .none
    }

    nonisolated private static let nonTLDFileExtensions: Set<String> = [
        "js", "ts", "jsx", "tsx", "mjs", "cjs",
        "py", "rb", "swift", "kt", "kts", "java", "scala",
        "c", "h", "cpp", "hpp", "cc", "cxx", "cs", "go", "php",
        "html", "htm", "css", "scss", "sass", "less",
        "json", "yaml", "yml", "toml", "xml", "plist", "ini", "env",
        "txt", "csv", "tsv", "log", "pdf", "doc", "docx", "rtf",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "ico",
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "mp3", "m4a", "wav", "flac", "aac", "ogg",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "ipa", "apk", "exe", "dll", "dylib", "so"
    ]

    /// Pure, deterministic omnibox URL vs search resolver:
    /// - Supports explicit `http://`, `https://`, `about:`, `blob:` URLs
    /// - Supports `localhost`, `localhost:8080`, IPv4 (`127.0.0.1:3000`), and bracketed IPv6 (`[::1]:8080`) over `http://`
    /// - Avoids false-positive navigations like `"Node.js"`, `"index.html"`, `"1.5"`, or `"v2.0"`
    /// - Encodes search queries cleanly via `URLComponents` with strict `+`, `&`, `=`, `#` percent-encoding.
    nonisolated public static func resolveNavigationURL(
        from rawInput: String,
        searchEngine: BrowserSearchEngine = BrowserSearchEngine.persistedCurrent,
        customSearchTemplate: String? = nil
    ) -> URL? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Explicit web scheme (`http://`, `https://`, `about:`, `blob:`)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("about:") || lower.hasPrefix("blob:") {
            if let direct = URL(string: trimmed) {
                return direct
            }
            if let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
               let fallback = URL(string: escaped) {
                return fallback
            }
        }

        // 2. Any whitespace is always a search query.
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return searchEngine.searchURL(for: trimmed, customTemplate: customSearchTemplate)
        }

        // Split host[:port] prefix from optional /path?query#fragment
        let authorityEnd = trimmed.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? trimmed.endIndex
        let authority = String(trimmed[..<authorityEnd])
        let hasPathOrQuery = authorityEnd != trimmed.endIndex

        // 3. Bracketed IPv6 literal (`[::1]` or `[::1]:8080`)
        if authority.hasPrefix("["), let closeBracket = authority.firstIndex(of: "]") {
            let afterBracket = authority.index(after: closeBracket)
            if afterBracket == authority.endIndex || authority[afterBracket] == ":" {
                if let url = URL(string: "http://\(trimmed)") {
                    return url
                }
            }
        }

        // Parse optional :port from authority
        let hostPart: String
        let hasValidPort: Bool
        if let colonIdx = authority.lastIndex(of: ":"),
           !authority[..<colonIdx].contains(":") {
            let portStr = String(authority[authority.index(after: colonIdx)...])
            if let port = Int(portStr), (1...65535).contains(port) {
                hostPart = String(authority[..<colonIdx])
                hasValidPort = true
            } else {
                // Invalid port -> treat as search
                return searchEngine.searchURL(for: trimmed, customTemplate: customSearchTemplate)
            }
        } else {
            hostPart = authority
            hasValidPort = false
        }

        let hostLower = hostPart.lowercased()

        // 4. `localhost` or `*.localhost`
        if hostLower == "localhost" || hostLower.hasSuffix(".localhost") {
            if let url = URL(string: "http://\(trimmed)") {
                return url
            }
        }

        // 5. IPv4 literal (`127.0.0.1`, `192.168.1.1:8080`)
        if isIPv4Address(hostLower) {
            if let url = URL(string: "http://\(trimmed)") {
                return url
            }
        }

        // 6. Domain name heuristic (must contain a dot, valid DNS labels, non-numeric TLD, not a code/file extension)
        if hostPart.contains("."),
           !hostPart.hasPrefix("."),
           !hostPart.hasSuffix("."),
           !hostPart.contains("..") {
            let labels = hostPart.split(separator: ".", omittingEmptySubsequences: false)
            if labels.count >= 2,
               labels.allSatisfy({ isValidHostnameLabel(String($0)) }),
               let tld = labels.last.map({ String($0).lowercased() }),
               tld.count >= 2,
               !tld.allSatisfy(\.isNumber) {
                // Guard against framework/filename false positives like "Node.js", "Next.js", "config.json", "index.html"
                let isLikelyFilename = !hasPathOrQuery
                    && !hasValidPort
                    && labels.count == 2
                    && nonTLDFileExtensions.contains(tld)
                // Also reject obvious uppercase filename.ext like "README.md" when no path/port is given
                let isUppercaseFilename = !hasPathOrQuery
                    && !hasValidPort
                    && labels.count == 2
                    && String(labels[0]) == String(labels[0]).uppercased()
                    && String(labels[0]).rangeOfCharacter(from: .letters) != nil
                    && tld == "md"
                if !isLikelyFilename && !isUppercaseFilename,
                   let url = URL(string: "https://\(trimmed)") {
                    return url
                }
            }
        }

        // 7. Default to configured search engine
        return searchEngine.searchURL(for: trimmed, customTemplate: customSearchTemplate)
    }

    nonisolated private static func isIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let octet = Int(part), (0...255).contains(octet) else {
                return false
            }
        }
        return true
    }

    nonisolated private static func isValidHostnameLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 63,
              !label.hasPrefix("-"), !label.hasSuffix("-") else {
            return false
        }
        for scalar in label.unicodeScalars {
            let isASCIIAlnum = (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
            let isHyphen = scalar.value == 45
            let isNonASCII = scalar.value > 127 && CharacterSet.alphanumerics.contains(scalar)
            if !isASCIIAlnum && !isHyphen && !isNonASCII {
                return false
            }
        }
        return true
    }

    public func load(
        urlString: String,
        clearPreviousStreams: Bool = true,
        preservePDFReturnEntry: Bool = false
    ) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Support restoring durable local Vault `file://` PDFs directly into the native PDFKit reader.
        if trimmed.lowercased().hasPrefix("file://"),
           let fileURL = URL(string: trimmed),
           fileURL.isFileURL,
           fileURL.pathExtension.lowercased() == "pdf",
           FileManager.default.fileExists(atPath: fileURL.path) {
            openLocalPDF(fileURL: fileURL)
            return
        }

        cancelActiveInlinePDFDownload()
        dismissActivePDF(restoreUnderlyingWebMetadata: false)
        if !preservePDFReturnEntry {
            pdfBackStack.removeAll()
            pdfForwardStack.removeAll()
            pdfReturnAfterWebBackEntry = nil
        }

        deferredRestoreURLString = nil
        savedInteractionState = nil
        lastLoadError = nil
        lastBlockedPopupURL = nil

        let searchConfig = profileSearchProvider?()
        guard let url = Self.resolveNavigationURL(
            from: trimmed,
            searchEngine: searchConfig?.0 ?? BrowserSearchEngine.persistedCurrent,
            customSearchTemplate: searchConfig?.1
        ) else { return }
        let wv = ensureWebView()

        if clearPreviousStreams, url.absoluteString != currentURLString {
            mediaCapture.resetForMainFrameNavigation(to: url)
        } else {
            mediaCapture.stageYouTubeURLIfApplicable(url)
        }
        lastCommittedDocumentKey = Self.documentKey(for: url)
        currentURLString = url.absoluteString

        // Apply per-site UA & zoom before initiating load
        let targetHost = url.host()
        let effectiveUA = resolvedUserAgentProfile(
            global: effectiveProfileUserAgent,
            forHost: targetHost
        )
        if lastAppliedUserAgentProfile != effectiveUA {
            applyUserAgentProfile(effectiveUA, reloadIfLoaded: false)
        }
        applyPageZoom(resolvedPageZoom(forHost: targetHost))
        syncContentBlockerForHostNavigation(targetHost)

        let blocker = CleanroomContentBlocker.shared
        let effectiveShield = resolvedEffectiveShield(
            forHost: targetHost,
            globalEnabled: isShieldEnabled
        )
        // Fast synchronous load path whenever content-blocker bytecode is already warm (or shield is off):
        // starts DNS/TLS immediately with zero Task hop. On cold start, await ONLY the ~5–15 ms cached
        // bytecode mmap (never a multi-second recompile or 12-file staleness probe).
        if !effectiveShield || !blocker.compiledLists.isEmpty {
            wv.load(URLRequest(url: url))
            return
        }

        Task { @MainActor [weak self] in
            guard let self, let liveWV = self.backingWebView, liveWV === wv else { return }
            _ = await CleanroomContentBlocker.shared.fastRestoreCachedListsIfAvailable()
            guard self.backingWebView === liveWV else { return }
            self.syncContentBlockerForHostNavigation(targetHost)
            liveWV.load(URLRequest(url: url))
        }
    }

    // MARK: - Media Capture Forwarding Methods

    public func clearCandidates() {
        mediaCapture.clear()
    }

    public func clearSniffedMedia() {
        mediaCapture.clear()
    }

    public func enrichPendingCandidatesIfNeeded() async {
        await mediaCapture.enrichPendingCandidatesIfNeeded(
            fallbackReferer: currentURLString,
            pageTitle: pageTitle
        )
    }

    public func selectVariant(groupID: String, variantID: String) {
        mediaCapture.selectVariant(groupID: groupID, variantID: variantID)
    }

    public func toggleGroupSelection(groupID: String) {
        mediaCapture.toggleGroupSelection(groupID: groupID)
    }

    nonisolated static func classifyStreamFormat(url: URL, hint: String?) -> SniffedStreamCandidate.StreamFormat? {
        MediaURLClassifier.classifyStreamFormat(url: url, hint: hint)
    }

    public static func autoSniffFirstStream(
        webpageURL: URL,
        timeoutSeconds: Double = 15.0
    ) async -> SniffedStreamCandidate? {
        let session = CleanroomWebKitSession()
        defer { session.teardown() }

        session.load(urlString: webpageURL.absoluteString)

        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutSeconds * 1000))
        var didNudgePlay = false
        var firstCandidateTime: ContinuousClock.Instant?

        while ContinuousClock.now < deadline, !Task.isCancelled {
            if !session.candidates.isEmpty {
                if firstCandidateTime == nil {
                    firstCandidateTime = ContinuousClock.now
                }
                if let firstHit = firstCandidateTime, ContinuousClock.now - firstHit >= .milliseconds(700) {
                    return session.candidates.first
                }
            }
            if !session.isLoading, !didNudgePlay {
                didNudgePlay = true
                _ = try? await session.liveWebViewIfLoaded?.evaluateJavaScript(BrowserInjectedScripts.headlessAutoPlayNudge)
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return nil
            }
        }
        return Task.isCancelled ? nil : session.candidates.first
    }

    // MARK: - Script Message Dispatch

    fileprivate func handleInterceptedPayload(_ body: [String: Any], frameInfo: WKFrameInfo? = nil) {
        if let frameInfo {
            mediaCapture.registerFrameInfo(frameInfo, reportedOrigin: body["origin"] as? String)
        }

        let hint = body["hint"] as? String
        if hint == "spa-nav",
           let navStr = body["url"] as? String,
           let navURL = URL(string: navStr) {
            currentURLString = navStr
            mediaCapture.stageYouTubeURLIfApplicable(navURL)
            return
        }

        if hint == "open-tab",
           let targetStr = body["url"] as? String,
           let targetURL = URL(string: targetStr),
           let scheme = targetURL.scheme?.lowercased(),
           (scheme == "http" || scheme == "https") {
            if let last = lastOpenTabTimestamp, ContinuousClock.now - last < .milliseconds(350) {
                return
            }
            let refURL = (body["referer"] as? String).flatMap(URL.init(string:)) ?? backingWebView?.url
            let effectiveShield = resolvedEffectiveShield(
                forHost: activeNavigationHost,
                globalEnabled: isShieldEnabled
            )
            if !effectiveShield || Self.sharesBaseDomain(targetURL, with: refURL) {
                lastOpenTabTimestamp = .now
                // Do not eagerly snapshot on link taps; previews are captured lazily on tab deactivation or tab switcher open.
                if let onOpenLinkInTab {
                    onOpenLinkInTab(targetURL, isPrivate, true)
                } else {
                    load(urlString: targetURL.absoluteString)
                }
            } else {
                blockedPopupCount += 1
                lastBlockedPopupURL = targetURL
            }
            return
        }

        if (body["kind"] as? String) == "dark-activate" {
            let targetHost = frameInfo?.request.url?.host ?? activeNavigationHost
            let expectedTopHost = activeNavigationHost
            let targetFrame = frameInfo
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let activationJS = DarkReaderEngine.shared.makeActivationScript(forHost: targetHost) else { return }
                await MainActor.run {
                    guard let self, let liveWV = self.backingWebView, self.activeNavigationHost == expectedTopHost else { return }
                    if let targetFrame {
                        liveWV.evaluateJavaScript(activationJS, in: targetFrame, in: .page, completionHandler: nil)
                    } else {
                        liveWV.evaluateJavaScript(activationJS, completionHandler: nil)
                    }
                }
            }
            return
        }

        if (body["kind"] as? String) == "dark-state" {
            guard let liveWV = backingWebView else { return }
            let active = (body["active"] as? Bool) ?? false
            if active {
                isSyntheticDarkActive = true
                let canvas = DarkReaderEngine.shared.themePreset.canvasUIColor
                liveWV.underPageBackgroundColor = canvas
                liveWV.scrollView.backgroundColor = canvas
                if pageCanvasColor != canvas {
                    pageCanvasColor = canvas
                }
            } else if isSyntheticDarkActive {
                isSyntheticDarkActive = false
                liveWV.underPageBackgroundColor = nil
                liveWV.scrollView.backgroundColor = .systemBackground
                syncPageCanvasColor(from: liveWV)
            }
            return
        }

        mediaCapture.ingestSniffedCandidate(
            payload: body,
            pageTitle: pageTitle,
            currentURLString: currentURLString,
            frameInfo: frameInfo
        )
    }
}

extension CleanroomWebKitSession: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        lastLoadError = nil
        if activePDF == nil {
            updateSecureConnectionState(for: webView)
        }
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        lastLoadError = nil
        lastBlockedPopupURL = nil
        if activePDF != nil {
            dismissActivePDF(restoreUnderlyingWebMetadata: false)
        }
        updateSecureConnectionState(for: webView)

        guard let committedURL = webView.url else { return }
        let committedDocKey = Self.documentKey(for: committedURL)
        if let lastKey = lastCommittedDocumentKey, lastKey != committedDocKey {
            mediaCapture.resetForMainFrameNavigation(to: committedURL)
        }
        lastCommittedDocumentKey = committedDocKey

        let committedHost = CleanroomContentBlocker.shared.normalizeBypassHost(committedURL.host())
        let effectiveZoom = resolvedPageZoom(forHost: committedHost)
        if abs(Double(webView.pageZoom) - effectiveZoom) > 0.001 || abs(pageZoom - effectiveZoom) > 0.001 {
            pageZoom = effectiveZoom
            webView.pageZoom = CGFloat(effectiveZoom)
        }

        syncContentBlockerForHostNavigation(committedHost)
        syncEffectiveNavigationState()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isLoadingInlinePDF {
            isLoading = false
        }
        lastLoadError = nil
        guard activePDF == nil else {
            syncEffectiveNavigationState()
            return
        }
        updateSecureConnectionState(for: webView)
        syncPageCanvasColor(from: webView)
        syncEffectiveNavigationState()
        if !isPrivate,
           let url = webView.url,
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            let title = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            onNavigationCommitted?(url, title.isEmpty ? (url.host() ?? url.absoluteString) : title)
            if SiteIconStore.shared.cachedIcon(for: url.absoluteString) == nil {
                discoverSiteIcon(from: webView, pageURL: url)
            }
        }
    }

    public func capturePreviewSnapshot() {
        if let pdf = activePDF {
            let pageIdx = pdf.currentPageIndex
            let docBox = PDFTransferBox(pdf.document)
            let tabDocID = pdf.id
            Task { @MainActor [weak self] in
                let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    let doc = docBox.value
                    return doc.renderThemedThumbnail(pageIndex: pageIdx, maxDimension: 340)
                        ?? doc.renderThemedThumbnail(pageIndex: 0, maxDimension: 340)
                }.value
                guard let self, self.activePDF?.id == tabDocID, let img else { return }
                self.previewSnapshot = img
            }
            return
        }
        guard !currentURLString.isEmpty else {
            previewSnapshot = nil
            return
        }
        guard !isCapturingSnapshot, let liveWV = backingWebView else { return }
        let bounds = liveWV.bounds
        guard bounds.width > 40, bounds.height > 40 else { return }
        isCapturingSnapshot = true
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, bounds.width * 0.95))
        config.snapshotWidth = 220
        liveWV.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isCapturingSnapshot = false
                guard let image, !self.currentURLString.isEmpty else { return }
                self.previewSnapshot = image
            }
        }
    }

    private static func sharesBaseDomain(_ a: URL, with b: URL?) -> Bool {
        guard let hostA = a.host()?.lowercased(),
              let hostB = b?.host()?.lowercased() else {
            return false
        }
        if hostA == hostB { return true }
        let partsA = hostA.split(separator: ".")
        let partsB = hostB.split(separator: ".")
        guard partsA.count >= 2, partsB.count >= 2 else { return false }
        return partsA.suffix(2) == partsB.suffix(2)
    }

    nonisolated private static let trustedAuthPopupBaseDomains: Set<String> = [
        "accounts.google.com",
        "appleid.apple.com",
        "login.microsoftonline.com",
        "login.live.com",
        "github.com",
        "discord.com",
        "auth0.com",
        "okta.com",
        "checkout.stripe.com",
        "paypal.com",
        "oauth.reddit.com",
        "accounts.spotify.com",
        "id.twitch.tv",
        "facebook.com",
        "api.twitter.com",
        "x.com"
    ]

    nonisolated private static func isTrustedAuthPopupHost(_ rawHost: String?) -> Bool {
        guard let rawHost else { return false }
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return false }
        for allowed in trustedAuthPopupBaseDomains {
            if host == allowed || host.hasSuffix(".\(allowed)") {
                return true
            }
        }
        return false
    }

    private func discoverSiteIcon(from webView: WKWebView, pageURL: URL) {
        let js = """
        (() => {
            const links = Array.from(document.querySelectorAll('link[rel*="apple-touch-icon"], link[rel~="icon"]'));
            if (!links.length) return '';
            const score = (el) => {
                const rel = (el.getAttribute('rel') || '').toLowerCase();
                const sz = parseInt((el.getAttribute('sizes') || '').split('x')[0], 10) || 0;
                return (rel.includes('apple-touch-icon') ? 1000 : 0) + sz;
            };
            links.sort((a, b) => score(b) - score(a));
            return links[0].href || '';
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            guard let href = result as? String, !href.isEmpty, let iconURL = URL(string: href) else { return }
            Task { @MainActor in
                SiteIconStore.shared.recordDiscoveredIconURL(iconURL, forPageURL: pageURL)
            }
        }
    }

    private func syncPageCanvasColor(from webView: WKWebView) {
        if isSyntheticDarkActive {
            let canvas = DarkReaderEngine.shared.themePreset.canvasUIColor
            pageCanvasColor = canvas
            webView.underPageBackgroundColor = canvas
            webView.scrollView.backgroundColor = canvas
            return
        }
        if let metaTheme = webView.themeColor {
            pageCanvasColor = metaTheme
            webView.scrollView.backgroundColor = metaTheme
            return
        }
        webView.evaluateJavaScript(BrowserInjectedScripts.pageCanvasColorProbe) { [weak self] result, _ in
            guard let csv = result as? String else { return }
            let parts = csv.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 3 else { return }
            let sampled = UIColor(red: parts[0] / 255.0, green: parts[1] / 255.0, blue: parts[2] / 255.0, alpha: 1.0)
            Task { @MainActor [weak self] in
                guard let self, let liveWV = self.backingWebView, liveWV.themeColor == nil, !self.isSyntheticDarkActive else { return }
                self.pageCanvasColor = sampled
                liveWV.scrollView.backgroundColor = sampled
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !isLoadingInlinePDF {
            isLoading = false
        }
        recordLoadErrorIfApplicable(error, webView: webView)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        let isPolicyHandoff = (nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204))
        if !(isLoadingInlinePDF && isPolicyHandoff) {
            isLoading = false
        }
        recordLoadErrorIfApplicable(error, webView: webView)
    }

    private func recordLoadErrorIfApplicable(_ error: Error, webView: WKWebView) {
        let nsError = error as NSError
        // Ignore navigation cancellations (`-999`) and WebKit FrameLoadInterrupted (`102`, download handoff) / plug-in (`204`).
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204) {
            return
        }
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
            ?? (nsError.userInfo["NSErrorFailingURLStringKey"] as? String)
            ?? webView.url?.absoluteString
            ?? currentURLString
        lastLoadError = WebLoadError(
            urlString: failingURL,
            domain: nsError.domain,
            code: nsError.code,
            localizedDescription: nsError.localizedDescription,
            isTLSFailure: Self.isTLSError(nsError)
        )
    }

    nonisolated private static func isTLSError(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain, (-1206 ... -1200).contains(error.code) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSURLErrorDomain, (-1206 ... -1200).contains(underlying.code) {
                return true
            }
            if underlying.domain == NSOSStatusErrorDomain, (-9899 ... -9800).contains(underlying.code) {
                return true
            }
        }
        return false
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let effectiveShield = resolvedEffectiveShield(
            forHost: activeNavigationHost,
            globalEnabled: isShieldEnabled
        )
        let isExplicitGesture = navigationAction.navigationType == .linkActivated
            || navigationAction.navigationType == .formSubmitted

        if let targetURL = navigationAction.request.url,
           let scheme = targetURL.scheme?.lowercased(),
           (scheme == "http" || scheme == "https") {
            let isSameSite = Self.sharesBaseDomain(targetURL, with: webView.url)
            let isKnownAuth = Self.isTrustedAuthPopupHost(targetURL.host())

            if !effectiveShield || isExplicitGesture || isSameSite || isKnownAuth {
                if let childWebView = onCreateChildWebViewTab?(configuration, targetURL) {
                    return childWebView
                }
                if let onOpenLinkInTab {
                    onOpenLinkInTab(targetURL, isPrivate, true)
                } else {
                    load(urlString: targetURL.absoluteString)
                }
                return nil
            }

            blockedPopupCount += 1
            lastBlockedPopupURL = targetURL
            return nil
        }

        // `window.open('about:blank')` / deferred OAuth popup: permit when shield is disabled/bypassed or user-initiated.
        let isBlankPopup = navigationAction.request.url == nil
            || navigationAction.request.url?.absoluteString.lowercased() == "about:blank"
        if isBlankPopup && (!effectiveShield || isExplicitGesture) {
            if let childWebView = onCreateChildWebViewTab?(configuration, nil) {
                return childWebView
            }
        }

        blockedPopupCount += 1
        return nil
    }

    public func webViewDidClose(_ webView: WKWebView) {
        guard webView === backingWebView else { return }
        onRequestCloseSelf?()
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        let requestID = UUID()
        let request = WebJSDialogRequest(
            id: requestID,
            kind: .alert,
            message: message,
            handler: .alert(completionHandler),
            onResolved: { [weak self] in
                guard let self, self.activeJSDialog?.id == requestID else { return }
                self.activeJSDialog = nil
            }
        )
        activeJSDialog = request
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let requestID = UUID()
        let request = WebJSDialogRequest(
            id: requestID,
            kind: .confirm,
            message: message,
            handler: .confirm(completionHandler),
            onResolved: { [weak self] in
                guard let self, self.activeJSDialog?.id == requestID else { return }
                self.activeJSDialog = nil
            }
        )
        activeJSDialog = request
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let requestID = UUID()
        let request = WebJSDialogRequest(
            id: requestID,
            kind: .prompt(defaultText: defaultText),
            message: prompt,
            handler: .prompt(completionHandler),
            onResolved: { [weak self] in
                guard let self, self.activeJSDialog?.id == requestID else { return }
                self.activeJSDialog = nil
            }
        )
        activeJSDialog = request
    }

    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let method = space.authenticationMethod

        if method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest {
            let requestID = UUID()
            let request = WebAuthChallengeRequest(
                id: requestID,
                host: space.host,
                kind: .httpCredentials(realm: space.realm),
                handler: .httpCredentials(completionHandler),
                onResolved: { [weak self] in
                    guard let self, self.activeAuthChallenge?.id == requestID else { return }
                    self.activeAuthChallenge = nil
                }
            )
            activeAuthChallenge = request
            return
        }

        if method == NSURLAuthenticationMethodServerTrust {
            // Strictly enforce default TLS verification on all public internet hosts.
            guard Self.isPrivateOrLANHost(space.host),
                  let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            var cfError: CFError?
            if SecTrustEvaluateWithError(trust, &cfError) {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            let certFingerprint = Self.leafCertificateFingerprint(for: trust, host: space.host)
            if let certFingerprint, approvedLANTrustCertHashes.contains(certFingerprint) {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }

            let reason: String = {
                if let cfError {
                    return (cfError as Error).localizedDescription
                }
                return L("The certificate for \(space.host) is self-signed or not trusted.")
            }()

            let requestID = UUID()
            let request = WebAuthChallengeRequest(
                id: requestID,
                host: space.host,
                kind: .lanSelfSignedTrust(reason: reason),
                handler: .lanSelfSignedTrust(
                    trust: trust,
                    onTrustApproved: { [weak self] in
                        if let certFingerprint {
                            self?.approvedLANTrustCertHashes.insert(certFingerprint)
                        }
                    },
                    completion: completionHandler
                ),
                onResolved: { [weak self] in
                    guard let self, self.activeAuthChallenge?.id == requestID else { return }
                    self.activeAuthChallenge = nil
                }
            )
            activeAuthChallenge = request
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        let targetHostForUA = navigationAction.targetFrame?.isMainFrame == true
            ? navigationAction.request.url?.host()
            : activeNavigationHost
        let effectiveUA = resolvedUserAgentProfile(
            global: effectiveProfileUserAgent,
            forHost: targetHostForUA
        )
        preferences.preferredContentMode = effectiveUA.preferredContentMode

        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel, preferences)
            return
        }

        if navigationAction.shouldPerformDownload,
           ["http", "https", "blob", "data"].contains(scheme) {
            decisionHandler(.download, preferences)
            return
        }

        if ["mailto", "tel", "sms", "facetime", "facetime-audio"].contains(scheme) {
            if navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel, preferences)
            return
        }

        if !["http", "https", "about", "blob"].contains(scheme) {
            blockedPopupCount += 1
            decisionHandler(.cancel, preferences)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true,
           let targetHost = url.host(),
           !targetHost.isEmpty {
            if lastAppliedUserAgentProfile != effectiveUA {
                applyUserAgentProfile(effectiveUA, reloadIfLoaded: false)
            }
            syncContentBlockerForHostNavigation(targetHost)
        } else if navigationAction.targetFrame?.isMainFrame == false,
                  let subframeHost = url.host(),
                  !subframeHost.isEmpty {
            let mainHost = currentURL?.host()
            CleanroomContentBlocker.shared.ensureSubframeScriptlets(
                forHost: subframeHost,
                on: webView.configuration.userContentController,
                shieldEnabled: resolvedEffectiveShield(forHost: mainHost, globalEnabled: isShieldEnabled),
                mainHost: mainHost
            )
        }

        if (scheme == "http" || scheme == "https"),
           MediaURLClassifier.classifyStreamFormat(url: url, hint: "nav") != nil {
            handleInterceptedPayload([
                "url": url.absoluteString,
                "hint": "nav",
                "referer": webView.url?.absoluteString ?? "",
                "origin": "",
                "title": webView.title ?? "",
                "ua": webView.customUserAgent ?? HLSStreamEngine.safariUserAgent
            ])
        }

        decisionHandler(.allow, preferences)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        let response = navigationResponse.response
        let httpResponse = response as? HTTPURLResponse

        if let statusCode = httpResponse?.statusCode,
           (statusCode == 204 || statusCode == 304 || statusCode >= 400) {
            decisionHandler(.allow)
            return
        }

        let dispositionHeader = httpResponse?.value(forHTTPHeaderField: "Content-Disposition")
        let isAttachment = Self.isAttachmentContentDisposition(dispositionHeader)
        let mimeType = (response.mimeType ?? "").lowercased()
        let isPDF = (mimeType == "application/pdf" || mimeType == "application/x-pdf")

        // Main-frame inline PDFs (`!isAttachment`): stream the already-authenticated WebKit response
        // directly into a temporary preview file via `WKDownload` (zero second HTTP request, works for
        // GET, POST, cookies, proxy, Private tabs, `blob:`, and `data:`) and open in our native `PDFKit` reader.
        if isPDF && !isAttachment && navigationResponse.isForMainFrame {
            let parsedFilename = Self.parseContentDispositionFilename(dispositionHeader)
            let responseFilename = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceURL = response.url ?? URL(string: currentURLString) ?? URL(string: "about:blank")!
            let rawFilename: String = {
                if let parsedFilename, !parsedFilename.isEmpty { return parsedFilename }
                if let responseFilename, !responseFilename.isEmpty, responseFilename != "Unknown" {
                    return responseFilename
                }
                let last = sourceURL.lastPathComponent
                return (!last.isEmpty && last != "/") ? last : "Document.pdf"
            }()
            let sanitized = PDFTabDocument.sanitizePDFFilename(rawFilename)

            cancelActiveInlinePDFDownload()
            inlinePDFGeneration &+= 1
            pendingInlinePDFCapture = PendingInlinePDFCapture(
                generation: inlinePDFGeneration,
                sourceURL: sourceURL,
                suggestedFilename: sanitized,
                resolvedFilename: sanitized,
                destinationURL: nil
            )
            isLoadingInlinePDF = true
            isLoading = true
            estimatedProgress = max(estimatedProgress, 0.15)
            decisionHandler(.download)
            return
        }

        let shouldDownload: Bool
        if isAttachment {
            shouldDownload = true
        } else if isPDF {
            // Subframe embedded PDFs remain inline inside their parent page.
            shouldDownload = false
        } else if !navigationResponse.canShowMIMEType {
            shouldDownload = navigationResponse.isForMainFrame || response.expectedContentLength > 0
        } else {
            shouldDownload = false
        }

        guard shouldDownload else {
            decisionHandler(.allow)
            return
        }

        guard let url = response.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.download)
            return
        }

        if scheme == "blob" || scheme == "data" {
            decisionHandler(.download)
            return
        }

        if scheme == "http" || scheme == "https" {
            if onEnqueueBrowserDownload != nil {
                let parsedFilename = Self.parseContentDispositionFilename(dispositionHeader)
                let responseFilename = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
                let suggestedFilename: String? = {
                    if let parsedFilename, !parsedFilename.isEmpty { return parsedFilename }
                    if let responseFilename, !responseFilename.isEmpty, responseFilename != "Unknown" {
                        return responseFilename
                    }
                    let last = url.lastPathComponent
                    return (!last.isEmpty && last != "/") ? last : nil
                }()
                let expectedBytes: Int64? = response.expectedContentLength > 0 ? response.expectedContentLength : nil
                let normalizedDomain = url.host().map { LiveContainerEnvironment.HostNormalizer.normalize($0) }
                let sourceDomain = (normalizedDomain?.isEmpty == false) ? normalizedDomain : nil

                decisionHandler(.cancel)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let headers = await self.buildHostScopedDownloadHeaders(for: url)
                    let request = BrowserDownloadRequest(
                        url: url,
                        suggestedFilename: suggestedFilename,
                        expectedBytes: expectedBytes,
                        headers: headers,
                        sourceDomain: sourceDomain,
                        sourceProfileID: self.transferSourceProfileID
                    )
                    self.onEnqueueBrowserDownload?(request)
                }
                return
            }
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    public func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        attachWKDownload(download)
    }

    public func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        if let capture = pendingInlinePDFCapture {
            pendingInlinePDFCapture = nil
            let key = ObjectIdentifier(download)
            inlinePDFDownloads[key] = capture
            activeInlinePDFDownloadKey = key
            inlinePDFProgressObservation?.invalidate()
            inlinePDFProgressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                MainActor.assumeIsolated {
                    guard let self, self.activeInlinePDFDownloadKey == key else { return }
                    let mapped = min(0.95, max(0.15, 0.15 + progress.fractionCompleted * 0.80))
                    if abs(mapped - self.estimatedProgress) >= 0.02 || mapped >= 0.94 {
                        self.estimatedProgress = mapped
                    }
                }
            }
        }
        attachWKDownload(download)
    }

    private func attachWKDownload(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        activeWKDownloads[key] = download
        hasActiveWKDownload = !activeWKDownloads.isEmpty
        download.delegate = self
    }

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let key = ObjectIdentifier(download)
        if var capture = inlinePDFDownloads[key] {
            let trimmedSuggested = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            let chosenRaw: String = {
                if !capture.suggestedFilename.isEmpty, capture.suggestedFilename != "Document.pdf" {
                    return capture.suggestedFilename
                }
                if !trimmedSuggested.isEmpty, trimmedSuggested != "Unknown" {
                    return trimmedSuggested
                }
                if let respName = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !respName.isEmpty, respName != "Unknown" {
                    return respName
                }
                return "Document.pdf"
            }()
            let cleanName = PDFTabDocument.sanitizePDFFilename(chosenRaw)
            let destination = PDFTabDocument.makeTemporaryPreviewFileURL(tabID: id, suggestedFilename: cleanName)
            capture.resolvedFilename = cleanName
            capture.destinationURL = destination
            inlinePDFDownloads[key] = capture
            wkDownloadDestinations[key] = destination
            completionHandler(destination)
            return
        }

        let rawName: String = {
            let trimmed = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != "Unknown" { return trimmed }
            if let respName = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
               !respName.isEmpty, respName != "Unknown" {
                return respName
            }
            return "download"
        }()
        // Always stage regular `WKDownload` into a local temporary folder first because out-of-process
        // `com.apple.WebKit.Networking` lacks sandbox extensions for external FileProvider/iCloud folders.
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dys-wkdl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let cleanName = Self.sanitizeFilenameComponent(rawName, fallback: "download", maxLength: 160)
        let stagedDestination = stagingDir.appendingPathComponent(cleanName, isDirectory: false)
        wkDownloadDestinations[key] = stagedDestination
        completionHandler(stagedDestination)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        activeWKDownloads.removeValue(forKey: key)
        let savedURL = wkDownloadDestinations.removeValue(forKey: key)
        hasActiveWKDownload = !activeWKDownloads.isEmpty

        if let capture = inlinePDFDownloads.removeValue(forKey: key) {
            if activeInlinePDFDownloadKey == key {
                inlinePDFProgressObservation?.invalidate()
                inlinePDFProgressObservation = nil
                activeInlinePDFDownloadKey = nil
                isLoadingInlinePDF = false
            }
            guard let tempURL = savedURL ?? capture.destinationURL else {
                isLoading = false
                return
            }
            guard capture.generation == inlinePDFGeneration else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            // Remember previous active PDF on back stack if transitioning PDF -> PDF directly.
            if let previous = activePDF {
                pdfBackStack.append(
                    PDFHistoryEntry(
                        sourceURL: previous.sourceURL,
                        title: previous.displayTitle,
                        localFileURL: previous.isTemporaryPreviewFile ? nil : previous.localFileURL,
                        isTemporaryPreviewFile: previous.isTemporaryPreviewFile,
                        pageIndex: previous.currentPageIndex
                    )
                )
            }
            openLocalPDF(
                fileURL: tempURL,
                displayTitle: capture.resolvedFilename,
                isTemporaryPreviewFile: true,
                sourceURLOverride: capture.sourceURL,
                preserveNavigationHistory: !pdfForwardStack.isEmpty
            )
            return
        }

        if let stagedURL = savedURL {
            let desiredName = stagedURL.lastPathComponent
            let stagingFolder = stagedURL.deletingLastPathComponent()
            let targetDir = LiveContainerEnvironment.downloadsDirectory
            Task { @MainActor [weak self] in
                let committed = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                    defer { try? FileManager.default.removeItem(at: stagingFolder) }
                    return Result {
                        try LiveContainerEnvironment.commitStagedFile(
                            from: stagedURL,
                            toDirectory: targetDir,
                            preferredFilename: desiredName,
                            removeSource: true
                        )
                    }
                }.value
                guard let self else { return }
                switch committed {
                case .success(let finalURL):
                    self.onWKDownloadFinished?(finalURL)
                case .failure(let err):
                    self.onWKDownloadFailed?(err.localizedDescription)
                }
            }
        }
    }

    public func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        let key = ObjectIdentifier(download)
        activeWKDownloads.removeValue(forKey: key)
        let destURL = wkDownloadDestinations.removeValue(forKey: key)
        hasActiveWKDownload = !activeWKDownloads.isEmpty

        if let capture = inlinePDFDownloads.removeValue(forKey: key) {
            if activeInlinePDFDownloadKey == key {
                inlinePDFProgressObservation?.invalidate()
                inlinePDFProgressObservation = nil
                activeInlinePDFDownloadKey = nil
                isLoadingInlinePDF = false
                isLoading = false
                estimatedProgress = 0
            }
            if let tempFile = destURL ?? capture.destinationURL {
                try? FileManager.default.removeItem(at: tempFile)
            }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            lastLoadError = WebLoadError(
                urlString: capture.sourceURL.absoluteString,
                domain: nsError.domain,
                code: nsError.code,
                localizedDescription: error.localizedDescription,
                isTLSFailure: Self.isTLSError(nsError)
            )
            syncEffectiveNavigationState()
            return
        }

        if let staged = destURL {
            let folder = staged.deletingLastPathComponent()
            if folder.lastPathComponent.hasPrefix("dys-wkdl-") {
                try? FileManager.default.removeItem(at: folder)
            } else {
                try? FileManager.default.removeItem(at: staged)
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        onWKDownloadFailed?(error.localizedDescription)
    }

    public func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void
    ) {
        // When there is no HTTP(S) link, return `nil` so WebKit presents its native image/text menu intact.
        guard let linkURL = elementInfo.linkURL,
              let scheme = linkURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            completionHandler(nil)
            return
        }

        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggestedActions in
            let openBG = UIAction(
                title: L("Open in Background Tab"),
                image: UIImage(systemName: "plus.square.on.square")
            ) { _ in
                guard let self else { return }
                self.onOpenLinkInTab?(linkURL, self.isPrivate, false)
            }
            let openFG = UIAction(
                title: L("Open in New Tab"),
                image: UIImage(systemName: "arrow.up.right.square")
            ) { _ in
                guard let self else { return }
                self.onOpenLinkInTab?(linkURL, self.isPrivate, true)
            }
            let openPriv = UIAction(
                title: L("Open in Private Tab"),
                image: UIImage(systemName: "hand.raised")
            ) { _ in
                self?.onOpenLinkInTab?(linkURL, true, true)
            }
            let downloadAct = UIAction(
                title: L("Download Linked File"),
                image: UIImage(systemName: "arrow.down.circle")
            ) { _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let headers = await self.buildHostScopedDownloadHeaders(for: linkURL)
                    let last = linkURL.lastPathComponent
                    let suggestedName = (!last.isEmpty && last != "/") ? last : nil
                    let normalizedDomain = linkURL.host().map { LiveContainerEnvironment.HostNormalizer.normalize($0) }
                    let request = BrowserDownloadRequest(
                        url: linkURL,
                        suggestedFilename: suggestedName,
                        expectedBytes: nil,
                        headers: headers,
                        sourceDomain: (normalizedDomain?.isEmpty == false) ? normalizedDomain : nil,
                        sourceProfileID: self.transferSourceProfileID
                    )
                    self.onEnqueueBrowserDownload?(request)
                }
            }
            let copyAct = UIAction(
                title: L("Copy Link"),
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = linkURL.absoluteString
            }
            let shareAct = UIAction(
                title: L("Share Link"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in
                self?.onShareURL?(linkURL)
            }

            var children: [UIMenuElement] = [openBG, openFG, openPriv, downloadAct, copyAct, shareAct]
            let preserved = Self.filterNonDuplicateSuggestedActions(suggestedActions)
            if !preserved.isEmpty {
                children.append(UIMenu(title: "", options: .displayInline, children: preserved))
            }
            return UIMenu(title: linkURL.host() ?? linkURL.absoluteString, children: children)
        }
        completionHandler(config)
    }

    // MARK: - Private Security, Download & Context-Menu Helpers

    private static func filterNonDuplicateSuggestedActions(_ actions: [UIMenuElement]) -> [UIMenuElement] {
        let duplicateIdentifierSubstrings = [
            "WKElementActionTypeOpen",
            "WKElementActionTypeCopy",
            "WKElementActionTypeShare",
            "WKElementActionTypeDownload"
        ]
        let duplicateTitles: Set<String> = [
            "open",
            "open link",
            "open in new tab",
            "open in background",
            "copy",
            "copy link",
            "copy link url",
            "share",
            "share...",
            "share…",
            "share link",
            "download linked file"
        ]

        var kept: [UIMenuElement] = []
        for element in actions {
            if let action = element as? UIAction {
                let idRaw = action.identifier.rawValue
                let isDupIdentifier = duplicateIdentifierSubstrings.contains { idRaw.contains($0) }
                let lowerTitle = action.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if isDupIdentifier || duplicateTitles.contains(lowerTitle) {
                    continue
                }
                kept.append(action)
            } else if let submenu = element as? UIMenu {
                let filteredChildren = filterNonDuplicateSuggestedActions(submenu.children)
                if !filteredChildren.isEmpty {
                    kept.append(submenu.replacingChildren(filteredChildren))
                }
            } else {
                kept.append(element)
            }
        }
        return kept
    }

    nonisolated private static func isPrivateOrLANHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else { return false }

        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host == "::1" {
            return true
        }
        if host.contains(":"),
           (host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")) {
            return true
        }

        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let val = Int(part), (0...255).contains(val) else {
                return false
            }
            octets.append(val)
        }
        let a = octets[0], b = octets[1]
        if a == 127 || a == 10 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 169 && b == 254 { return true }
        return false
    }

    nonisolated private static func leafCertificateFingerprint(for trust: SecTrust, host: String) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }
        let data = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(host.lowercased()):\(hex)"
    }

    nonisolated private static func isAttachmentContentDisposition(_ header: String?) -> Bool {
        guard let header else { return false }
        return header.lowercased().contains("attachment")
    }

    nonisolated private static func parseContentDispositionFilename(_ header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }
        let segments = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Prefer RFC 5987 `filename*=UTF-8''...` over plain `filename=...`
        for segment in segments {
            let lower = segment.lowercased()
            if lower.hasPrefix("filename*=") {
                var value = String(segment.dropFirst("filename*=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if let quoteRange = value.range(of: "''") {
                    value = String(value[quoteRange.upperBound...])
                }
                let decoded = value.removingPercentEncoding ?? value
                let sanitized = sanitizeFilenameComponent(decoded, fallback: "", maxLength: 160)
                if !sanitized.isEmpty { return sanitized }
            }
        }
        for segment in segments {
            let lower = segment.lowercased()
            if lower.hasPrefix("filename=") {
                let raw = String(segment.dropFirst("filename=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                let decoded = raw.removingPercentEncoding ?? raw
                let sanitized = sanitizeFilenameComponent(decoded, fallback: "", maxLength: 160)
                if !sanitized.isEmpty { return sanitized }
            }
        }
        return nil
    }

    nonisolated private static func sanitizeFilenameComponent(
        _ raw: String,
        fallback: String,
        maxLength: Int
    ) -> String {
        let leaf = (raw as NSString).lastPathComponent
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(min(leaf.unicodeScalars.count, maxLength))
        for scalar in leaf.unicodeScalars {
            if scalar.value < 32 || scalar.value == 127 { continue }
            if scalar == "/" || scalar == "\\" || scalar == ":" {
                scalars.append("-")
            } else {
                scalars.append(scalar)
            }
        }
        var cleaned = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > maxLength {
            cleaned = String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func uniqueDownloadDestinationURL(suggestedFilename: String) -> URL {
        let dir = LiveContainerEnvironment.downloadsDirectory
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let cleanName = Self.sanitizeFilenameComponent(suggestedFilename, fallback: "download", maxLength: 160)
        let nsName = cleanName as NSString
        let rawExt = nsName.pathExtension
        let hasExt = !rawExt.isEmpty && rawExt.count <= 12 && nsName.deletingPathExtension != ""
        let stem = hasExt ? nsName.deletingPathExtension : cleanName
        let ext = hasExt ? rawExt : ""

        let reservedPaths = Set(wkDownloadDestinations.values.map { $0.standardizedFileURL.path })
        let baseCandidate = dir.appendingPathComponent(cleanName, isDirectory: false)
        if !fm.fileExists(atPath: baseCandidate.path),
           !reservedPaths.contains(baseCandidate.standardizedFileURL.path) {
            return baseCandidate
        }

        for index in 2...9999 {
            let nextName = hasExt ? "\(stem) (\(index)).\(ext)" : "\(stem) (\(index))"
            let candidate = dir.appendingPathComponent(nextName, isDirectory: false)
            if !fm.fileExists(atPath: candidate.path),
               !reservedPaths.contains(candidate.standardizedFileURL.path) {
                return candidate
            }
        }

        let uniqueSuffix = UUID().uuidString.prefix(8)
        let fallbackName = hasExt ? "\(stem)-\(uniqueSuffix).\(ext)" : "\(stem)-\(uniqueSuffix)"
        return dir.appendingPathComponent(fallbackName, isDirectory: false)
    }
}

private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: CleanroomWebKitSession?

    init(target: CleanroomWebKitSession) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        let frameInfo = message.frameInfo
        target?.handleInterceptedPayload(dict, frameInfo: frameInfo)
    }
}

private final class WeakDarkFetchMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let dict = message.body as? [String: Any],
              let urlString = dict["url"] as? String else {
            return (["ok": false, "status": 400], nil)
        }
        let reply = await DarkReaderEngine.shared.handleCrossOriginStylesheetFetch(urlString: urlString)
        return (reply, nil)
    }
}
