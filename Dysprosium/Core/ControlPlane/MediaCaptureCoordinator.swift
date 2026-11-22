import Foundation
import Observation
import WebKit

/// Represents an authenticated media stream intercepted live inside Cleanroom WebKit.
public struct SniffedStreamCandidate: Identifiable, Hashable, Sendable {
    public enum StreamFormat: String, Sendable {
        case hls = "HLS (.m3u8 → .mp4)"
        case mp4 = "Direct MP4"
        case dash = "DASH"
    }

    public let id: String
    public let streamURL: URL
    public let format: StreamFormat
    public let qualityScore: Int
    public let pageTitle: String
    public let sourceDomain: String
    public let headers: [String: String]
    public let discoveredAt: Date
    public let hintedDuration: Double?
    public let hintedWidth: Int?
    public let hintedHeight: Int?
    public let mimeType: String?

    public init(
        id: String,
        streamURL: URL,
        format: StreamFormat,
        qualityScore: Int,
        pageTitle: String,
        sourceDomain: String,
        headers: [String: String],
        discoveredAt: Date,
        hintedDuration: Double? = nil,
        hintedWidth: Int? = nil,
        hintedHeight: Int? = nil,
        mimeType: String? = nil
    ) {
        self.id = id
        self.streamURL = streamURL
        self.format = format
        self.qualityScore = qualityScore
        self.pageTitle = pageTitle
        self.sourceDomain = sourceDomain
        self.headers = headers
        self.discoveredAt = discoveredAt
        self.hintedDuration = hintedDuration
        self.hintedWidth = hintedWidth
        self.hintedHeight = hintedHeight
        self.mimeType = mimeType
    }

    /// Returns a copy overriding only the supplied fields (eliminates fragile 12-argument positional rebuilds).
    func upgrading(
        streamURL: URL? = nil,
        format: StreamFormat? = nil,
        qualityScore: Int? = nil,
        sourceDomain: String? = nil,
        headers: [String: String]? = nil,
        hintedDuration: Double? = nil,
        hintedWidth: Int? = nil,
        hintedHeight: Int? = nil,
        mimeType: String? = nil
    ) -> Self {
        SniffedStreamCandidate(
            id: id,
            streamURL: streamURL ?? self.streamURL,
            format: format ?? self.format,
            qualityScore: qualityScore ?? self.qualityScore,
            pageTitle: pageTitle,
            sourceDomain: sourceDomain ?? self.sourceDomain,
            headers: headers ?? self.headers,
            discoveredAt: discoveredAt,
            hintedDuration: hintedDuration ?? self.hintedDuration,
            hintedWidth: hintedWidth ?? self.hintedWidth,
            hintedHeight: hintedHeight ?? self.hintedHeight,
            mimeType: mimeType ?? self.mimeType
        )
    }

    public var suggestedFilename: String {
        let ext = MediaURLClassifier.preferredFileExtension(url: streamURL, format: format, mimeType: mimeType)
        let cleanedTitle = pageTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTitle.isEmpty, cleanedTitle.count <= 96 {
            return cleanedTitle.lowercased().hasSuffix(".\(ext)") ? cleanedTitle : "\(cleanedTitle).\(ext)"
        }
        let stem = streamURL.deletingPathExtension().lastPathComponent
        let base = stem.isEmpty || stem == "master" || stem == "index" ? sourceDomain : stem
        return "\(base).\(ext)"
    }
}

/// Deterministic top-level lifecycle phase for media discovery and metadata probing in a browser tab.
public enum MediaCapturePhase: Equatable, Sendable {
    case idle
    case discovered(candidateCount: Int)
    case probing(activeCount: Int, readyCount: Int)
    case ready(groupCount: Int)
    case allUnreachable(groupCount: Int)
}

/// Per-candidate capture/probe lifecycle state.
public enum SniffedStreamState: Equatable, Sendable {
    case discovered
    case probing
    case ready
    case unreachable(reason: String)
}

/// Explicit state-machine coordinator owning all media stream interception, deduplication,
/// preloaded `#EXTM3U` manifest caching, per-origin `WKFrameInfo` same-origin manifest fetching,
/// bounded-concurrency probing, cancellation on navigation reset, and deterministic variant grouping.
@Observable
@MainActor
public final class MediaCaptureCoordinator {
    public typealias CandidateProber = @Sendable (
        _ candidate: SniffedStreamCandidate,
        _ posterURL: URL?,
        _ capturedManifests: [String: String],
        _ inPageManifestFetcher: (@Sendable (URL) async -> String?)?
    ) async -> StreamMetadataProber.EnrichedProbeOutput

    public typealias YouTubeGroupResolver = @Sendable (
        _ videoID: String,
        _ defaultSelected: Bool
    ) async -> DiscoveredMediaGroup?

    public typealias CookieProvider = @MainActor () async -> [HTTPCookie]
    public typealias InPageManifestFetcher = @MainActor (URL, WKFrameInfo?) async -> String?

    public private(set) var capturePhase: MediaCapturePhase = .idle
    public private(set) var activeProbeCount: Int = 0
    public private(set) var candidates: [SniffedStreamCandidate] = []
    public private(set) var mediaGroups: [DiscoveredMediaGroup] = []
    public private(set) var pendingCandidateCount: Int = 0
    public private(set) var streamStates: [String: SniffedStreamState] = [:]

    /// Alias preserving explicit naming for callers inspecting resolved media groups.
    public var discoveredMediaGroups: [DiscoveredMediaGroup] {
        mediaGroups
    }

    public var isProbing: Bool {
        if case .probing = capturePhase {
            return true
        }
        return false
    }

    public var discoveredMediaBadgeCount: Int {
        mediaGroups.count + pendingCandidateCount
    }

    public var selectedGroupsForDownload: [DiscoveredMediaGroup] {
        mediaGroups.filter(\.isSelectedForDownload)
    }

    public var inFlightProbeTaskCount: Int {
        inFlightProbeCancellers.count
    }

    private struct PendingSniffItem {
        let candidate: SniffedStreamCandidate
        let frameReferer: String?
        let frameOrigin: String?
        let posterURL: URL?
        let ua: String
    }

    private static let maxPendingCandidates = 24
    private static let maxCapturedManifests = 24
    private static let maxConcurrentProbes = 3

    private weak var webView: WKWebView?
    private let candidateProberOverride: CandidateProber?
    private let youTubeResolver: YouTubeGroupResolver
    private let cookieProviderOverride: CookieProvider?
    private let inPageManifestFetcherOverride: InPageManifestFetcher?

    private var generation: UInt64 = 0
    private var enrichmentTask: Task<Void, Never>?
    private var inFlightProbeCancellers: [String: () -> Void] = [:]
    private var isEnrichingPending: Bool = false

    private var seenCanonicalURLs: Set<String> = []
    private var capturedManifests: [String: StreamMetadataProber.CapturedManifest] = [:]
    private var frameInfoByOrigin: [String: WKFrameInfo] = [:]
    private var seenYouTubeVideoIDs: Set<String> = []
    private var pendingYouTubeVideoIDs: [String] = []
    private var pendingSniffItems: [PendingSniffItem] = []
    private var userToggledGroupIDs: Set<String> = []
    private var candidateEvidenceVersions: [String: UInt64] = [:]

    public init(
        webView: WKWebView? = nil,
        candidateProber: CandidateProber? = nil,
        youTubeResolver: @escaping YouTubeGroupResolver = { videoID, defaultSelected in
            await StreamMetadataProber.resolveYouTubeVideoGroup(
                videoID: videoID,
                defaultSelected: defaultSelected
            )
        },
        cookieProvider: CookieProvider? = nil,
        inPageManifestFetcher: InPageManifestFetcher? = nil
    ) {
        self.webView = webView
        self.candidateProberOverride = candidateProber
        self.youTubeResolver = youTubeResolver
        self.cookieProviderOverride = cookieProvider
        self.inPageManifestFetcherOverride = inPageManifestFetcher
    }

    public func attach(webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - Reset & Cancellation

    /// Cancels every in-flight probe task, increments the state-machine generation so late probe
    /// completions cannot leak stale groups, and returns `capturePhase` deterministically to `.idle`.
    public func clear() {
        generation &+= 1
        enrichmentTask?.cancel()
        enrichmentTask = nil
        for (_, cancel) in inFlightProbeCancellers {
            cancel()
        }
        inFlightProbeCancellers.removeAll()
        isEnrichingPending = false
        activeProbeCount = 0
        candidates.removeAll()
        mediaGroups.removeAll()
        streamStates.removeAll()
        pendingSniffItems.removeAll()
        pendingYouTubeVideoIDs.removeAll()
        pendingCandidateCount = 0
        seenCanonicalURLs.removeAll()
        capturedManifests.removeAll()
        frameInfoByOrigin.removeAll()
        seenYouTubeVideoIDs.removeAll()
        userToggledGroupIDs.removeAll()
        candidateEvidenceVersions.removeAll()
        recomputeCapturePhase()
    }

    /// Resets capture state on main-frame document navigation and immediately stages YouTube
    /// metadata resolution if the destination URL is a YouTube watch/shorts URL.
    public func resetForMainFrameNavigation(to url: URL? = nil) {
        clear()
        if let url {
            stageYouTubeURLIfApplicable(url)
        }
    }

    // MARK: - Frame Registry & Preloaded Manifest Cache

    public func registerFrameInfo(_ frameInfo: WKFrameInfo, reportedOrigin: String? = nil) {
        if let frameURL = frameInfo.request.url,
           let key = Self.originKey(for: frameURL) {
            frameInfoByOrigin[key] = frameInfo
        }
        if let origStr = reportedOrigin?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased(),
           origStr.hasPrefix("http://") || origStr.hasPrefix("https://") {
            frameInfoByOrigin[origStr] = frameInfo
        }
    }

    public func cachedManifestText(for urlString: String) -> String? {
        capturedManifests[urlString]?.text
    }

    public static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Executes a same-origin `fetch(..., { credentials: 'include' })` inside the live `WKWebView`
    /// frame that originated the stream, preserving `Response.url` after redirects so relative HLS
    /// variants and segments resolve against the post-redirect base URL.
    public func fetchManifestInWebView(url: URL) async -> String? {
        await fetchManifestInWebViewWithFinalURL(url: url)?.text
    }

    public func fetchManifestInWebViewWithFinalURL(url: URL) async -> StreamMetadataProber.CapturedManifest? {
        let key = url.absoluteString
        if let cached = capturedManifests[key],
           cached.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
            return cached
        }

        let targetFrame = Self.originKey(for: url).flatMap { frameInfoByOrigin[$0] }
        let fetchedText: String?
        var resolvedFinalURL = url

        if let override = inPageManifestFetcherOverride {
            fetchedText = await override(url, targetFrame)
        } else if let webView {
            let js = """
            try {
                const res = await fetch(url, { credentials: 'include' });
                if (!res.ok) return null;
                const txt = await res.text();
                if (typeof txt !== 'string' || !txt.trimStart().startsWith('#EXTM3U')) return null;
                return { text: txt, finalUrl: (res.url && res.url.length > 0) ? res.url : url };
            } catch (_) {
                return null;
            }
            """
            let rawResult: Any?
            if let targetFrame {
                rawResult = try? await webView.callAsyncJavaScript(
                    js,
                    arguments: ["url": key],
                    in: targetFrame,
                    contentWorld: .page
                )
            } else {
                rawResult = try? await webView.callAsyncJavaScript(
                    js,
                    arguments: ["url": key],
                    in: nil,
                    contentWorld: .page
                )
            }
            if let dict = rawResult as? [String: Any], let txt = dict["text"] as? String {
                fetchedText = txt
                if let finalStr = dict["finalUrl"] as? String, let parsed = URL(string: finalStr) {
                    resolvedFinalURL = parsed
                }
            } else {
                fetchedText = rawResult as? String
            }
        } else {
            fetchedText = nil
        }

        guard let fetchedText else { return nil }
        let trimmed = fetchedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#EXTM3U") else { return nil }
        storeCapturedManifest(trimmed, forKey: key, finalURL: resolvedFinalURL)
        return StreamMetadataProber.CapturedManifest(text: trimmed, finalURL: resolvedFinalURL)
    }

    private func storeCapturedManifest(_ manifest: String, forKey key: String, finalURL: URL) {
        let entry = StreamMetadataProber.CapturedManifest(text: manifest, finalURL: finalURL)
        if capturedManifests.count < Self.maxCapturedManifests || capturedManifests[key] != nil {
            capturedManifests[key] = entry
        }
        let finalKey = finalURL.absoluteString
        if finalKey != key, capturedManifests.count < Self.maxCapturedManifests || capturedManifests[finalKey] != nil {
            capturedManifests[finalKey] = entry
        }
    }

    private func replacePendingCandidate(canonicalKey: String, with updated: SniffedStreamCandidate) -> Bool {
        guard let pIdx = pendingSniffItems.firstIndex(where: { $0.candidate.id == canonicalKey }) else {
            return false
        }
        let oldItem = pendingSniffItems[pIdx]
        pendingSniffItems[pIdx] = PendingSniffItem(
            candidate: updated,
            frameReferer: oldItem.frameReferer,
            frameOrigin: oldItem.frameOrigin,
            posterURL: oldItem.posterURL,
            ua: oldItem.ua
        )
        return true
    }

    private func upgradeSeenCandidateWithManifest(canonicalKey: String, body: [String: Any]) -> Bool {
        var didUpgrade = false
        var upgradedCandidate: SniffedStreamCandidate?
        if let idx = candidates.firstIndex(where: { $0.id == canonicalKey }) {
            let old = candidates[idx]
            if old.format != .hls {
                let upgraded = old.upgrading(
                    format: .hls,
                    qualityScore: max(old.qualityScore, MediaURLClassifier.inferQualityScore(url: old.streamURL, explicitQuality: 0, format: .hls)),
                    mimeType: "application/vnd.apple.mpegurl"
                )
                candidates[idx] = upgraded
                upgradedCandidate = upgraded
                didUpgrade = true
            } else {
                upgradedCandidate = old
            }
        }
        if let latest = upgradedCandidate, replacePendingCandidate(canonicalKey: canonicalKey, with: latest) {
            didUpgrade = true
        }

        let isProbingInFlight = (inFlightProbeCancellers[canonicalKey] != nil)
            || (streamStates[canonicalKey] == .probing)
        let hasStaleGroup = mediaGroups.contains { group in
            group.variants.contains {
                ($0.id == canonicalKey || $0.url.absoluteString == canonicalKey)
                    && ($0.format != .hls || $0.probeError != nil || $0.preloadedManifestText == nil)
            }
        }
        let alreadyFinishedWithoutGroup = !pendingSniffItems.contains(where: { $0.candidate.id == canonicalKey })
            && !isProbingInFlight
            && !mediaGroups.contains { group in
                group.variants.contains { $0.id == canonicalKey || $0.url.absoluteString == canonicalKey }
            }

        if isProbingInFlight || hasStaleGroup || (didUpgrade && alreadyFinishedWithoutGroup),
           let latest = upgradedCandidate {
            requeueUpgradedCandidate(canonicalKey: canonicalKey, latest: latest, body: body)
            return true
        }
        return didUpgrade
    }

    private func upgradeSeenCandidateWithLateMetadata(
        canonicalKey: String,
        effectiveHint: String?,
        incomingMIME: String?,
        hintedDuration: Double?,
        hintedWidth: Int?,
        hintedHeight: Int?,
        body: [String: Any]
    ) -> Bool {
        let hasAuthoritativeMIME = (incomingMIME?.isEmpty == false)
        guard hintedDuration != nil || hintedHeight != nil || hintedWidth != nil || hasAuthoritativeMIME else {
            return false
        }

        var didUpgrade = false
        var formatChanged = false
        var upgradedCandidate: SniffedStreamCandidate?
        if let idx = candidates.firstIndex(where: { $0.id == canonicalKey }) {
            let old = candidates[idx]
            let newDuration = old.hintedDuration ?? hintedDuration
            let newWidth = old.hintedWidth ?? hintedWidth
            let newHeight = old.hintedHeight ?? hintedHeight
            let newMIME = hasAuthoritativeMIME ? incomingMIME : old.mimeType
            let recomputedFormat: SniffedStreamCandidate.StreamFormat = {
                if capturedManifests[canonicalKey] != nil { return .hls }
                guard hasAuthoritativeMIME else { return old.format }
                return MediaURLClassifier.classifyStreamFormat(
                    url: old.streamURL,
                    hint: effectiveHint,
                    mimeType: newMIME
                ) ?? old.format
            }()
            formatChanged = (recomputedFormat != old.format)
            if newDuration != old.hintedDuration
                || newWidth != old.hintedWidth
                || newHeight != old.hintedHeight
                || newMIME != old.mimeType
                || formatChanged {
                let upgraded = old.upgrading(
                    format: recomputedFormat,
                    qualityScore: max(old.qualityScore, newHeight ?? 0),
                    hintedDuration: newDuration,
                    hintedWidth: newWidth,
                    hintedHeight: newHeight,
                    mimeType: newMIME
                )
                candidates[idx] = upgraded
                upgradedCandidate = upgraded
                _ = replacePendingCandidate(canonicalKey: canonicalKey, with: upgraded)
                didUpgrade = true
            } else {
                upgradedCandidate = old
            }
        }

        if formatChanged, let latest = upgradedCandidate {
            requeueUpgradedCandidate(canonicalKey: canonicalKey, latest: latest, body: body)
        }

        var updatedAnyGroup = false
        for gIdx in mediaGroups.indices {
            if let vIdx = mediaGroups[gIdx].variants.firstIndex(where: { $0.id == canonicalKey || $0.url.absoluteString == canonicalKey }) {
                if mediaGroups[gIdx].durationSeconds == nil, let dur = hintedDuration {
                    mediaGroups[gIdx].durationSeconds = dur
                    updatedAnyGroup = true
                    didUpgrade = true
                }
                let v = mediaGroups[gIdx].variants[vIdx]
                let updatedExt: String = {
                    guard hasAuthoritativeMIME, !formatChanged else { return v.fileExtension }
                    return MediaURLClassifier.preferredFileExtension(url: v.url, format: v.format, mimeType: incomingMIME)
                }()
                if (v.height == nil && hintedHeight != nil) || updatedExt != v.fileExtension {
                    mediaGroups[gIdx].variants[vIdx] = v.applyingLateMetadata(
                        width: hintedWidth,
                        height: hintedHeight,
                        fileExtension: updatedExt
                    )
                    mediaGroups[gIdx].variants.sort { $0.qualityRank > $1.qualityRank }
                    updatedAnyGroup = true
                    didUpgrade = true
                }
            }
        }
        if updatedAnyGroup {
            reconcileAutomaticGroupSelections()
            sortMediaGroups()
        }
        return didUpgrade
    }

    private func requeueUpgradedCandidate(
        canonicalKey: String,
        latest: SniffedStreamCandidate,
        body: [String: Any]
    ) {
        candidateEvidenceVersions[canonicalKey, default: 0] &+= 1
        let isProbingInFlight = (inFlightProbeCancellers[canonicalKey] != nil)
            || (streamStates[canonicalKey] == .probing)
        if isProbingInFlight {
            inFlightProbeCancellers.removeValue(forKey: canonicalKey)?()
        }
        guard !pendingSniffItems.contains(where: { $0.candidate.id == canonicalKey }) else { return }
        let frameReferer = (body["referer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let frameOrigin = (body["origin"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let posterURL = (body["poster"] as? String).flatMap(URL.init(string:))
        let ua = (body["ua"] as? String) ?? HLSStreamEngine.safariUserAgent
        pendingSniffItems.append(
            PendingSniffItem(
                candidate: latest,
                frameReferer: frameReferer,
                frameOrigin: frameOrigin,
                posterURL: posterURL,
                ua: ua
            )
        )
        streamStates[canonicalKey] = .discovered
        syncPendingCountAndPhase()
    }

    // MARK: - Candidate Ingestion

    public func stageYouTubeURLIfApplicable(_ url: URL) {
        guard let videoID = StreamMetadataProber.extractYouTubeVideoID(from: url),
              !seenYouTubeVideoIDs.contains(videoID) else {
            return
        }
        seenYouTubeVideoIDs.insert(videoID)
        pendingYouTubeVideoIDs.append(videoID)
        streamStates["yt:\(videoID)"] = .discovered
        syncPendingCountAndPhase()
    }

    /// Ingests an intercepted JS media payload, handling `#EXTM3U` manifest caching, deduplication,
    /// late-manifest re-queuing for previously 403-probed streams, and deterministic phase transitions.
    @discardableResult
    public func ingestSniffedCandidate(
        payload body: [String: Any],
        pageTitle: String,
        currentURLString: String,
        frameInfo: WKFrameInfo? = nil
    ) -> Bool {
        if let frameInfo {
            registerFrameInfo(frameInfo, reportedOrigin: body["origin"] as? String)
        }

        guard let rawURL = body["url"] as? String,
              let resolvedURL = URL(string: rawURL),
              let scheme = resolvedURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let streamHost = resolvedURL.host()?.lowercased() else {
            return false
        }

        if streamHost.hasSuffix("googlevideo.com"), !seenYouTubeVideoIDs.isEmpty {
            return false
        }

        let incomingManifest: String? = {
            guard let raw = body["manifestText"] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("#EXTM3U") ? trimmed : nil
        }()

        let incomingMIME = (body["mimeType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveHint = (incomingManifest != nil) ? "m3u8-manifest" : (body["hint"] as? String)
        guard let format = MediaURLClassifier.classifyStreamFormat(
            url: resolvedURL,
            hint: effectiveHint,
            mimeType: incomingMIME
        ) else {
            return false
        }

        let canonicalKey = resolvedURL.absoluteString

        if let incomingManifest {
            storeCapturedManifest(incomingManifest, forKey: canonicalKey, finalURL: resolvedURL)
            if seenCanonicalURLs.contains(canonicalKey) {
                return upgradeSeenCandidateWithManifest(canonicalKey: canonicalKey, body: body)
            }
        }

        let hintedDuration: Double? = {
            if let d = body["duration"] as? Double, d.isFinite, d > 0 { return d }
            if let n = body["duration"] as? NSNumber {
                let d = n.doubleValue
                return (d.isFinite && d > 0) ? d : nil
            }
            return nil
        }()
        let hintedWidth: Int? = {
            let w = (body["videoWidth"] as? Int) ?? (body["videoWidth"] as? NSNumber)?.intValue ?? 0
            return w > 0 ? w : nil
        }()
        let hintedHeight: Int? = {
            let h = (body["videoHeight"] as? Int) ?? (body["videoHeight"] as? NSNumber)?.intValue ?? 0
            return h > 0 ? h : nil
        }()

        if seenCanonicalURLs.contains(canonicalKey) {
            return upgradeSeenCandidateWithLateMetadata(
                canonicalKey: canonicalKey,
                effectiveHint: effectiveHint,
                incomingMIME: incomingMIME,
                hintedDuration: hintedDuration,
                hintedWidth: hintedWidth,
                hintedHeight: hintedHeight,
                body: body
            )
        }
        seenCanonicalURLs.insert(canonicalKey)

        let explicitQuality = (body["quality"] as? Int) ?? 0
        let qualityScore = MediaURLClassifier.inferQualityScore(
            url: resolvedURL,
            explicitQuality: explicitQuality,
            format: format
        )

        let frameReferer = (body["referer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let frameOrigin = (body["origin"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let frameTitle = (body["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let posterURL = (body["poster"] as? String).flatMap(URL.init(string:))
        let ua = (body["ua"] as? String) ?? HLSStreamEngine.safariUserAgent

        let effectiveTitle: String = {
            if !pageTitle.isEmpty { return pageTitle }
            if let frameTitle, !frameTitle.isEmpty { return frameTitle }
            return streamHost
        }()

        var headers: [String: String] = [
            "User-Agent": ua,
            "Accept": "*/*"
        ]
        if let ref = frameReferer, !ref.isEmpty {
            headers["Referer"] = ref
        } else if !currentURLString.isEmpty {
            headers["Referer"] = currentURLString
        }
        let omitOrigin = (body["omitOrigin"] as? Bool) ?? false
        if !omitOrigin, let orig = frameOrigin, !orig.isEmpty, orig != "null" {
            headers["Origin"] = orig
        }

        let candidate = SniffedStreamCandidate(
            id: canonicalKey,
            streamURL: resolvedURL,
            format: format,
            qualityScore: qualityScore,
            pageTitle: effectiveTitle,
            sourceDomain: streamHost,
            headers: headers,
            discoveredAt: Date(),
            hintedDuration: hintedDuration,
            hintedWidth: hintedWidth,
            hintedHeight: hintedHeight,
            mimeType: (incomingMIME?.isEmpty == false) ? incomingMIME : nil
        )
        candidates.append(candidate)
        candidates.sort { lhs, rhs in
            if lhs.qualityScore != rhs.qualityScore {
                return lhs.qualityScore > rhs.qualityScore
            }
            return lhs.discoveredAt > rhs.discoveredAt
        }

        if pendingSniffItems.count < Self.maxPendingCandidates {
            pendingSniffItems.append(
                PendingSniffItem(
                    candidate: candidate,
                    frameReferer: frameReferer,
                    frameOrigin: frameOrigin,
                    posterURL: posterURL,
                    ua: ua
                )
            )
            streamStates[canonicalKey] = .discovered
            syncPendingCountAndPhase()
        }
        return true
    }

    // MARK: - On-Demand Bounded-Concurrency Probing

    /// On-demand enrichment triggered when the user opens Media Radar:
    /// harvests HTTP cookies once and probes pending streams with bounded concurrency (max 3)
    /// while tracking every in-flight probe `Task` for instant cancellation on navigation or `clear()`.
    public func enrichPendingCandidatesIfNeeded(
        fallbackReferer: String,
        pageTitle: String
    ) async {
        guard !isEnrichingPending else { return }
        if let webView {
            // Live sweep of active `<video>` / `<audio>` elements across main frame and known iframes
            // catches any extensionless stream whose `src` was assigned before listeners attached.
            _ = try? await webView.evaluateJavaScript("window.__dysprosiumScanMediaElements && window.__dysprosiumScanMediaElements()")
            for frame in frameInfoByOrigin.values {
                _ = try? await webView.evaluateJavaScript(
                    "window.__dysprosiumScanMediaElements && window.__dysprosiumScanMediaElements()",
                    in: frame,
                    contentWorld: .page
                )
            }
        }
        guard !pendingSniffItems.isEmpty || !pendingYouTubeVideoIDs.isEmpty else {
            recomputeCapturePhase()
            return
        }

        let runGeneration = generation
        isEnrichingPending = true
        defer {
            if self.generation == runGeneration {
                self.isEnrichingPending = false
                self.enrichmentTask = nil
                self.recomputeCapturePhase()
            }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var passCount = 0
            while self.generation == runGeneration,
                  !Task.isCancelled,
                  passCount < 4,
                  (!self.pendingYouTubeVideoIDs.isEmpty || !self.pendingSniffItems.isEmpty) {
                passCount += 1
                await self.runSingleEnrichmentPass(
                    runGeneration: runGeneration,
                    fallbackReferer: fallbackReferer,
                    pageTitle: pageTitle
                )
            }
        }
        enrichmentTask = task
        await task.value
    }

    private func runSingleEnrichmentPass(
        runGeneration: UInt64,
        fallbackReferer: String,
        pageTitle: String
    ) async {
        let ytBatch = pendingYouTubeVideoIDs
        pendingYouTubeVideoIDs.removeAll()
        let streamBatch = pendingSniffItems
        pendingSniffItems.removeAll()
        pendingCandidateCount = 0

        let totalCount = ytBatch.count + streamBatch.count
        guard totalCount > 0 else {
            recomputeCapturePhase()
            return
        }

        for videoID in ytBatch {
            streamStates["yt:\(videoID)"] = .probing
        }
        var batchStartVersions: [String: UInt64] = [:]
        for item in streamBatch {
            streamStates[item.candidate.id] = .probing
            batchStartVersions[item.candidate.id] = candidateEvidenceVersions[item.candidate.id] ?? 0
        }
        activeProbeCount += totalCount
        recomputeCapturePhase()

        // 1. Resolve staged YouTube videos sequentially.
        if !ytBatch.isEmpty {
            let resolver = youTubeResolver
            for videoID in ytBatch {
                guard generation == runGeneration, !Task.isCancelled else { return }
                let taskKey = "yt:\(videoID)"
                let isFirst = mediaGroups.isEmpty
                let probeTask = Task {
                    await resolver(videoID, isFirst)
                }
                inFlightProbeCancellers[taskKey] = { probeTask.cancel() }
                let resolvedGroup = await withTaskCancellationHandler {
                    await probeTask.value
                } onCancel: {
                    probeTask.cancel()
                }
                inFlightProbeCancellers.removeValue(forKey: taskKey)

                guard generation == runGeneration, !Task.isCancelled else { return }
                activeProbeCount = max(0, activeProbeCount - 1)
                if let group = resolvedGroup {
                    if !mediaGroups.contains(where: { $0.id == group.id }) {
                        mediaGroups.insert(group, at: 0)
                        sortMediaGroups()
                    }
                    streamStates[taskKey] = group.isUnreachable
                        ? .unreachable(reason: group.unreachableReason ?? "Unavailable")
                        : .ready
                } else {
                    streamStates[taskKey] = .unreachable(reason: "Unavailable")
                }
                recomputeCapturePhase()
            }
        }

        guard !streamBatch.isEmpty, generation == runGeneration, !Task.isCancelled else { return }

        // 2. Harvest cookies once for the stream batch.
        let cookies = await fetchCookies()
        guard generation == runGeneration, !Task.isCancelled else { return }

        let preparedBatch: [(candidate: SniffedStreamCandidate, posterURL: URL?, evidenceVersion: UInt64)] = streamBatch.map { item in
            let cookieHeader = Self.buildCookieHeader(
                cookies: cookies,
                for: item.candidate.streamURL
            )
            var headers = item.candidate.headers
            if !cookieHeader.isEmpty {
                headers["Cookie"] = cookieHeader
            }
            return (item.candidate.upgrading(headers: headers), item.posterURL, batchStartVersions[item.candidate.id] ?? 0)
        }

        let manifestsSnapshot = capturedManifests
        let proberOverride = candidateProberOverride
        let cookieHeaderBuilder: StreamMetadataProber.CookieHeaderBuilder = { destinationURL in
            let header = Self.buildCookieHeader(cookies: cookies, for: destinationURL)
            return header.isEmpty ? nil : header
        }
        let inPageFetcher: StreamMetadataProber.InPageManifestFetcher = { [weak self] url in
            await MainActor.run { [weak self] in
                self
            }?.fetchManifestInWebViewWithFinalURL(url: url)
        }

        // 3. Probe streams with bounded concurrency (`maxConcurrentProbes = 3`).
        let maxConcurrency = Self.maxConcurrentProbes
        var nextIndex = 0

        await withTaskGroup(of: (String, UInt64, (SniffedStreamCandidate, StreamMetadataProber.EnrichedProbeOutput)?).self) { group in
            @MainActor func enqueueNext(into group: inout TaskGroup<(String, UInt64, (SniffedStreamCandidate, StreamMetadataProber.EnrichedProbeOutput)?)>) {
                while nextIndex < preparedBatch.count {
                    let item = preparedBatch[nextIndex]
                    nextIndex += 1
                    let candidateID = item.candidate.id
                    let startedVersion = item.evidenceVersion
                    // If stronger evidence (e.g. `#EXTM3U` or authoritative MIME) arrived during cookie fetch,
                    // skip this obsolete probe and let the next pass process the upgraded queued item.
                    if (self.candidateEvidenceVersions[candidateID] ?? 0) != startedVersion {
                        self.activeProbeCount = max(0, self.activeProbeCount - 1)
                        continue
                    }
                    let innerTask = Task<(SniffedStreamCandidate, StreamMetadataProber.EnrichedProbeOutput)?, Never> {
                        guard !Task.isCancelled else { return nil }
                        let enriched: StreamMetadataProber.EnrichedProbeOutput
                        if let proberOverride {
                            let legacyManifests = manifestsSnapshot.mapValues(\.text)
                            let legacyFetcher: @Sendable (URL) async -> String? = { url in
                                await inPageFetcher(url)?.text
                            }
                            enriched = await proberOverride(
                                item.candidate,
                                item.posterURL,
                                legacyManifests,
                                legacyFetcher
                            )
                        } else {
                            enriched = await StreamMetadataProber.probeCandidate(
                                item.candidate,
                                posterURL: item.posterURL,
                                capturedManifests: manifestsSnapshot,
                                inPageManifestFetcher: inPageFetcher,
                                cookieHeaderBuilder: cookieHeaderBuilder
                            )
                        }
                        guard !Task.isCancelled else { return nil }
                        return (item.candidate, enriched)
                    }
                    self.inFlightProbeCancellers[candidateID] = { innerTask.cancel() }
                    group.addTask {
                        let output = await withTaskCancellationHandler {
                            await innerTask.value
                        } onCancel: {
                            innerTask.cancel()
                        }
                        return (candidateID, startedVersion, output)
                    }
                    return
                }
            }

            let initialCount = min(maxConcurrency, preparedBatch.count)
            for _ in 0..<initialCount {
                enqueueNext(into: &group)
            }

            for await (candidateID, startedVersion, result) in group {
                guard self.generation == runGeneration, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                self.inFlightProbeCancellers.removeValue(forKey: candidateID)
                self.activeProbeCount = max(0, self.activeProbeCount - 1)
                let currentVersion = self.candidateEvidenceVersions[candidateID] ?? 0
                if startedVersion == currentVersion, let (candidate, enriched) = result {
                    self.mergeEnrichedCandidate(candidate, enriched: enriched, pageTitle: pageTitle)
                }
                self.recomputeCapturePhase()
                if nextIndex < preparedBatch.count {
                    enqueueNext(into: &group)
                }
            }
        }
    }

    private func fetchCookies() async -> [HTTPCookie] {
        if let cookieProviderOverride {
            return await cookieProviderOverride()
        }
        guard let webView else { return [] }
        return await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
    }

    // MARK: - Selection Controls

    public func selectVariant(groupID: String, variantID: String) {
        guard let idx = mediaGroups.firstIndex(where: { $0.id == groupID }) else { return }
        mediaGroups[idx].selectedVariantID = variantID
    }

    public func toggleGroupSelection(groupID: String) {
        guard let idx = mediaGroups.firstIndex(where: { $0.id == groupID }) else { return }
        guard mediaGroups[idx].isDownloadSupported else { return }
        userToggledGroupIDs.insert(groupID)
        mediaGroups[idx].isSelectedForDownload.toggle()
    }

    // MARK: - Merging, Sorting & Phase State Machine

    private func syncPendingCountAndPhase() {
        pendingCandidateCount = pendingSniffItems.count + pendingYouTubeVideoIDs.count
        recomputeCapturePhase()
    }

    private func recomputeCapturePhase() {
        if activeProbeCount > 0 {
            let readyCount = mediaGroups.filter { !$0.isUnreachable }.count
            capturePhase = .probing(activeCount: activeProbeCount, readyCount: readyCount)
            return
        }

        if !mediaGroups.isEmpty {
            let hasReachable = mediaGroups.contains { !$0.isUnreachable }
            capturePhase = hasReachable
                ? .ready(groupCount: mediaGroups.count)
                : .allUnreachable(groupCount: mediaGroups.count)
            return
        }

        if pendingCandidateCount > 0 {
            capturePhase = .discovered(candidateCount: pendingCandidateCount)
            return
        }

        capturePhase = .idle
    }

    private func mergeEnrichedCandidate(
        _ candidate: SniffedStreamCandidate,
        enriched: StreamMetadataProber.EnrichedProbeOutput,
        pageTitle: String
    ) {
        guard !enriched.expandedVariants.isEmpty else {
            streamStates[candidate.id] = .unreachable(reason: "Filtered")
            return
        }

        // Read the latest stored candidate metadata so `loadedmetadata` duration/dimensions that
        // arrived while this probe was in flight are never lost during merge.
        let latestCandidate = candidates.first(where: { $0.id == candidate.id }) ?? candidate
        let mergedDuration = enriched.durationSeconds ?? latestCandidate.hintedDuration

        // Guarantee cached `#EXTM3U` manifests and latest DOM dimensions pass through to matching variants.
        let hydratedVariants: [SniffedVariantOption] = enriched.expandedVariants.map { variant in
            var copy = variant
            if copy.preloadedManifestText == nil,
               let cached = capturedManifests[copy.url.absoluteString] {
                copy.preloadedManifestText = cached.text
            }
            if copy.height == nil, let lateH = latestCandidate.hintedHeight {
                copy = copy.applyingLateMetadata(width: latestCandidate.hintedWidth, height: lateH)
            }
            return copy
        }

        let hasReachableVariant = hydratedVariants.contains { $0.probeError == nil }
        if hasReachableVariant {
            streamStates[candidate.id] = .ready
        } else {
            let reason = hydratedVariants.first?.probeError ?? "Unreachable"
            streamStates[candidate.id] = .unreachable(reason: reason)
        }

        let matchIdx = mediaGroups.firstIndex { existing in
            if existing.id == enriched.groupStemHint { return true }
            if let d1 = existing.durationSeconds,
               let d2 = mergedDuration,
               d1 >= 8.0, d2 >= 8.0,
               abs(d1 - d2) <= 1.6 {
                return true
            }
            return false
        }

        if let idx = matchIdx {
            var group = mediaGroups[idx]
            if !pageTitle.isEmpty && (group.title == group.sourceDomain || group.title.isEmpty) {
                group.title = pageTitle
            }
            if group.durationSeconds == nil, let dur = mergedDuration {
                group.durationSeconds = dur
            }
            if group.thumbnailJPEGData == nil, let thumb = enriched.thumbnailJPEGData {
                group.thumbnailJPEGData = thumb
            }

            let incomingHasTypedResolution = hydratedVariants.contains {
                $0.height != nil || $0.bandwidthBps != nil
            }
            if incomingHasTypedResolution {
                group.variants.removeAll {
                    $0.format == .hls && $0.height == nil && $0.bandwidthBps == nil
                }
            }
            let existingHasTypedResolution = group.variants.contains {
                $0.height != nil || $0.bandwidthBps != nil
            }

            for incoming in hydratedVariants {
                if existingHasTypedResolution && incoming.format == .hls && incoming.height == nil && incoming.bandwidthBps == nil && incoming.preloadedManifestText == nil {
                    continue
                }
                if let dupIdx = group.variants.firstIndex(where: {
                    $0.id == incoming.id || ($0.height != nil && $0.height == incoming.height && $0.format == incoming.format)
                }) {
                    let current = group.variants[dupIdx]
                    let formatReclassifiedForSameID = (current.id == incoming.id && current.format != incoming.format)
                    let upgradesReachability = (current.probeError != nil && incoming.probeError == nil)
                    let upgradesFormatToHLS = (current.format != .hls && incoming.format == .hls)
                    if formatReclassifiedForSameID {
                        group.variants[dupIdx] = incoming
                    } else if upgradesReachability || upgradesFormatToHLS || incoming.qualityRank > current.qualityRank || (current.height == nil && incoming.height != nil) {
                        var upgraded = incoming
                        if upgraded.exactOrEstimatedBytes == nil {
                            upgraded.exactOrEstimatedBytes = current.exactOrEstimatedBytes
                        }
                        if upgraded.preloadedManifestText == nil {
                            upgraded.preloadedManifestText = current.preloadedManifestText
                        }
                        group.variants[dupIdx] = upgraded
                    } else {
                        if current.exactOrEstimatedBytes == nil, incoming.exactOrEstimatedBytes != nil {
                            group.variants[dupIdx].exactOrEstimatedBytes = incoming.exactOrEstimatedBytes
                        }
                        if current.preloadedManifestText == nil, incoming.preloadedManifestText != nil {
                            group.variants[dupIdx].preloadedManifestText = incoming.preloadedManifestText
                        }
                    }
                } else {
                    group.variants.append(incoming)
                }
            }

            // Drop stale unreachable placeholders once a verified variant exists in the same media group.
            if group.variants.contains(where: { $0.probeError == nil }) {
                group.variants.removeAll { $0.probeError != nil }
            }
            group.variants.sort { $0.qualityRank > $1.qualityRank }
            if let topVariant = group.variants.first,
               let currVariant = group.selectedVariant,
               (currVariant.probeError != nil || topVariant.qualityRank > currVariant.qualityRank) {
                group.selectedVariantID = topVariant.id
            }
            mediaGroups[idx] = group
            reconcileAutomaticGroupSelections()
            sortMediaGroups()
        } else {
            let sorted = hydratedVariants.sorted { $0.qualityRank > $1.qualityRank }
            let bestID = sorted.first?.id ?? candidate.id
            let isShort = (mergedDuration ?? 99.0) < 8.0
            let isUnreachable = !sorted.isEmpty && sorted.allSatisfy { $0.probeError != nil }
            let isSupported = sorted.contains(where: \.isDownloadSupported)
            let shouldDefaultSelect = isSupported && !isShort && !isUnreachable
                && mediaGroups.filter({ $0.isDownloadSupported && !$0.isShortClipCandidate && !$0.isUnreachable }).isEmpty

            let newGroup = DiscoveredMediaGroup(
                id: enriched.groupStemHint.isEmpty ? UUID().uuidString : enriched.groupStemHint,
                title: !pageTitle.isEmpty ? pageTitle : candidate.pageTitle,
                sourceDomain: candidate.sourceDomain,
                durationSeconds: mergedDuration,
                thumbnailJPEGData: enriched.thumbnailJPEGData,
                variants: sorted,
                selectedVariantID: bestID,
                isSelectedForDownload: shouldDefaultSelect
            )
            mediaGroups.append(newGroup)
            reconcileAutomaticGroupSelections()
            sortMediaGroups()
        }
    }

    /// Recomputes default automatic download selection when late metadata (e.g. a 3-second clip
    /// duration or recovered reachability) changes eligibility, while strictly preserving any
    /// explicit manual user toggles.
    private func reconcileAutomaticGroupSelections() {
        for idx in mediaGroups.indices {
            let id = mediaGroups[idx].id
            if !mediaGroups[idx].isDownloadSupported {
                mediaGroups[idx].isSelectedForDownload = false
                continue
            }
            guard !userToggledGroupIDs.contains(id) else { continue }
            if mediaGroups[idx].isShortClipCandidate || mediaGroups[idx].isUnreachable {
                mediaGroups[idx].isSelectedForDownload = false
            }
        }
        let hasAnySelected = mediaGroups.contains { $0.isSelectedForDownload && $0.isDownloadSupported }
        if !hasAnySelected {
            if let bestIdx = mediaGroups.indices.first(where: {
                let g = mediaGroups[$0]
                return g.isDownloadSupported && !g.isUnreachable && !g.isShortClipCandidate && !userToggledGroupIDs.contains(g.id)
            }) {
                mediaGroups[bestIdx].isSelectedForDownload = true
            }
        }
    }

    private func sortMediaGroups() {
        mediaGroups.sort { lhs, rhs in
            if lhs.isDownloadSupported != rhs.isDownloadSupported {
                return lhs.isDownloadSupported
            }
            if lhs.isUnreachable != rhs.isUnreachable {
                return !lhs.isUnreachable
            }
            if lhs.isShortClipCandidate != rhs.isShortClipCandidate {
                return !lhs.isShortClipCandidate
            }
            let d1 = lhs.durationSeconds ?? 0
            let d2 = rhs.durationSeconds ?? 0
            if d1 != d2 {
                return d1 > d2
            }
            return lhs.id < rhs.id
        }
    }

    /// Builds an RFC 6265 `Cookie` header strictly scoped to `targetURL`, preserving host-only vs
    /// leading-dot domain scope, `Path` prefix semantics (§5.1.4), `Secure`, and expiration.
    public nonisolated static func buildCookieHeader(
        cookies: [HTTPCookie],
        for targetURL: URL
    ) -> String {
        guard let host = targetURL.host()?.lowercased(), !host.isEmpty else { return "" }
        let requestPath = targetURL.path.isEmpty ? "/" : targetURL.path
        let isSecureScheme = targetURL.scheme?.lowercased() == "https"
        return buildCookieHeader(
            cookies: cookies,
            streamHost: host,
            targetPath: requestPath,
            isSecureScheme: isSecureScheme
        )
    }

    /// Builds an RFC 6265 `Cookie` header strictly scoped to `streamHost` and `targetPath`.
    /// Preserves host-only semantics (`cookie.domain` without leading `.` matches only exact host).
    public nonisolated static func buildCookieHeader(
        cookies: [HTTPCookie],
        streamHost: String,
        targetPath: String = "/",
        isSecureScheme: Bool = true
    ) -> String {
        let targetHost = streamHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !targetHost.isEmpty else { return "" }
        let normalizedReqPath = targetPath.isEmpty ? "/" : targetPath

        let now = Date()
        var matched: [HTTPCookie] = []
        matched.reserveCapacity(cookies.count)

        for cookie in cookies {
            if let expires = cookie.expiresDate, expires < now {
                continue
            }
            if cookie.isSecure && !isSecureScheme {
                continue
            }

            let rawDomain = cookie.domain
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !rawDomain.isEmpty else { continue }

            // Foundation encodes RFC 6265 `host-only-flag`: a leading `.` indicates a domain-wide
            // cookie (`Domain=...`); absence of leading `.` indicates a host-only cookie that MUST
            // NOT be forwarded to subdomains.
            let isDomainCookie = rawDomain.hasPrefix(".")
            let cleanDomain = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !cleanDomain.isEmpty else { continue }

            let domainMatches: Bool = isDomainCookie
                ? (targetHost == cleanDomain || targetHost.hasSuffix(".\(cleanDomain)"))
                : (targetHost == cleanDomain)
            guard domainMatches else { continue }

            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches: Bool = {
                if cookiePath == "/" || normalizedReqPath == cookiePath {
                    return true
                }
                if cookiePath.hasSuffix("/") {
                    return normalizedReqPath.hasPrefix(cookiePath)
                }
                return normalizedReqPath.hasPrefix(cookiePath + "/")
            }()
            guard pathMatches else { continue }

            matched.append(cookie)
        }

        // RFC 6265 §5.4: more specific (longer) cookie paths come first.
        matched.sort { $0.path.count > $1.path.count }
        var pairs: [String] = []
        var seenNames: Set<String> = []
        for cookie in matched {
            if seenNames.insert(cookie.name).inserted {
                pairs.append("\(cookie.name)=\(cookie.value)")
            }
        }
        return pairs.joined(separator: "; ")
    }
}
