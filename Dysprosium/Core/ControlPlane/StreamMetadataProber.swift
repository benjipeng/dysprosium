import AVFoundation
import CoreGraphics
import Foundation
import os
import OSLog
import UIKit

/// A selectable quality/format rendition belonging to a discovered media item on a webpage.
public struct SniffedVariantOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public var directPlayURL: URL?
    public var pairedAudioURL: URL?
    public var pairedAudioBytes: Int64?
    public let format: SniffedStreamCandidate.StreamFormat
    public let resolutionLabel: String
    public let width: Int?
    public let height: Int?
    public let bandwidthBps: Int64?
    public var exactOrEstimatedBytes: Int64?
    public let headers: [String: String]
    public let qualityRank: Int
    public var probeError: String?
    /// Optional `#EXTM3U` playlist body captured directly from the live `WKWebView` response so
    /// downloads can bypass Cloudflare/WAF/one-time-token 403 rejections on manifest origins.
    public var preloadedManifestText: String?
    /// True output container extension (`mp4`, `webm`, `mkv`, `m4a`, `mp3`, `mpd`, etc.).
    public let fileExtension: String

    /// False for formats without a native download/muxing engine (e.g. MPEG-DASH `.mpd`).
    public var isDownloadSupported: Bool {
        format != .dash
    }

    /// True when `AVPlayer` can play this rendition natively (HLS/MP4/direct audio, or an explicit HLS `directPlayURL`).
    public var isPlayableInNativePlayer: Bool {
        isDownloadSupported || directPlayURL != nil
    }

    public init(
        id: String,
        url: URL,
        directPlayURL: URL? = nil,
        pairedAudioURL: URL? = nil,
        pairedAudioBytes: Int64? = nil,
        format: SniffedStreamCandidate.StreamFormat,
        resolutionLabel: String,
        width: Int?,
        height: Int?,
        bandwidthBps: Int64?,
        exactOrEstimatedBytes: Int64?,
        headers: [String: String],
        qualityRank: Int,
        probeError: String? = nil,
        preloadedManifestText: String? = nil,
        fileExtension: String = "mp4"
    ) {
        self.id = id
        self.url = url
        self.directPlayURL = directPlayURL
        self.pairedAudioURL = pairedAudioURL
        self.pairedAudioBytes = pairedAudioBytes
        self.format = format
        self.resolutionLabel = resolutionLabel
        self.width = width
        self.height = height
        self.bandwidthBps = bandwidthBps
        self.exactOrEstimatedBytes = exactOrEstimatedBytes
        self.headers = headers
        self.qualityRank = qualityRank
        self.probeError = probeError
        self.preloadedManifestText = preloadedManifestText
        self.fileExtension = fileExtension
    }

    /// Returns a copy with an updated post-redirect playlist URL, re-scoped headers, and cached manifest text.
    func withResolvedPlaylist(url: URL, headers: [String: String], text: String) -> Self {
        SniffedVariantOption(
            id: id,
            url: url,
            directPlayURL: directPlayURL,
            pairedAudioURL: pairedAudioURL,
            pairedAudioBytes: pairedAudioBytes,
            format: format,
            resolutionLabel: resolutionLabel,
            width: width,
            height: height,
            bandwidthBps: bandwidthBps,
            exactOrEstimatedBytes: exactOrEstimatedBytes,
            headers: headers,
            qualityRank: qualityRank,
            probeError: probeError,
            preloadedManifestText: text,
            fileExtension: fileExtension
        )
    }

    /// Returns a copy hydrated with late `<video>` dimensions and/or a refined container extension.
    func applyingLateMetadata(width newW: Int?, height newH: Int?, fileExtension newExt: String? = nil) -> Self {
        let resolvedW = width ?? newW
        let resolvedH = height ?? newH
        let fallbackLabel = format == .hls ? L("HLS Stream") : (format == .dash ? L("DASH Stream") : L("MP4 Video"))
        let label = (height == nil && resolvedH != nil)
            ? StreamMetadataProber.formatResolutionLabel(width: resolvedW, height: resolvedH, fallback: fallbackLabel)
            : resolutionLabel
        return SniffedVariantOption(
            id: id,
            url: url,
            directPlayURL: directPlayURL,
            pairedAudioURL: pairedAudioURL,
            pairedAudioBytes: pairedAudioBytes,
            format: format,
            resolutionLabel: label,
            width: resolvedW,
            height: resolvedH,
            bandwidthBps: bandwidthBps,
            exactOrEstimatedBytes: exactOrEstimatedBytes,
            headers: headers,
            qualityRank: probeError == nil ? max(qualityRank, resolvedH ?? 0) : qualityRank,
            probeError: probeError,
            preloadedManifestText: preloadedManifestText,
            fileExtension: newExt ?? fileExtension
        )
    }

    public var badgeSummary: String {
        if !isDownloadSupported {
            return resolutionLabel
        }
        if let probeError, !probeError.isEmpty {
            return "\(resolutionLabel) · \(probeError)"
        }
        if let bytes = exactOrEstimatedBytes, bytes > 0 {
            let prefix = format == .hls ? "~" : ""
            return "\(resolutionLabel) · \(prefix)\(DysprosiumFormatters.bytes(bytes))"
        }
        return resolutionLabel
    }
}

/// Represents a distinct logical video/audio asset discovered on a webpage, aggregating its
/// multiple quality variants (`4K`, `1080p`, `720p`, `HLS`) behind one visual card with thumbnail & duration.
public struct DiscoveredMediaGroup: Identifiable, Sendable {
    public let id: String
    public var title: String
    public let sourceDomain: String
    public var durationSeconds: Double?
    public var thumbnailJPEGData: Data?
    public var variants: [SniffedVariantOption]
    public var selectedVariantID: String
    public var isSelectedForDownload: Bool

    public var selectedVariant: SniffedVariantOption? {
        variants.first(where: { $0.id == selectedVariantID }) ?? variants.first
    }

    public var isDownloadSupported: Bool {
        selectedVariant?.isDownloadSupported ?? variants.contains(where: \.isDownloadSupported)
    }

    /// True when every discovered variant for this media group failed manifest/origin reachability probing.
    public var isUnreachable: Bool {
        !variants.isEmpty && variants.allSatisfy { $0.probeError != nil }
    }

    public var unreachableReason: String? {
        guard isUnreachable else { return nil }
        return selectedVariant?.probeError ?? variants.first?.probeError
    }

    public var isShortClipCandidate: Bool {
        if id.hasPrefix("yt:") { return false }
        if let d = durationSeconds, d > 0, d < 4.5 {
            return true
        }
        return false
    }

    public func outputFilename(indexSuffix: Int? = nil) -> String {
        let targetExt = selectedVariant?.fileExtension ?? "mp4"
        var clean = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { clean = sourceDomain }
        let suffixToStrip = ".\(targetExt)"
        if clean.lowercased().hasSuffix(suffixToStrip) {
            clean = String(clean.dropLast(suffixToStrip.count))
        } else if clean.lowercased().hasSuffix(".mp4") {
            clean = String(clean.dropLast(4))
        }
        if clean.count > 84 {
            clean = String(clean.prefix(84)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let resTag: String = {
            guard let v = selectedVariant else { return "" }
            if let w = v.width, let h = v.height, w > 0, h > 0 {
                let shortEdge = min(w, h)
                return " [\(shortEdge)p]"
            }
            if let h = v.height, h > 0 {
                return " [\(h)p]"
            }
            return ""
        }()
        let idxTag = indexSuffix.map { " #\($0)" } ?? ""
        return "\(clean)\(idxTag)\(resTag).\(targetExt)"
    }
}

/// Asynchronous media metadata & frame-poster inspector that enriches intercepted stream URLs with:
/// 1. Master `.m3u8` multi-resolution variant expansion (`4K 2160p`, `1080p`, `720p`, `480p`)
/// 2. Exact HTTP `Content-Range` byte sizes for direct `.mp4` streams & bandwidth-derived estimates for HLS
/// 3. Authenticated `AVURLAsset` (`AVURLAssetHTTPHeaderFieldsKey`) duration, dimensions, and `AVAssetImageGenerator` live frame thumbnails
public enum StreamMetadataProber {
    public struct EnrichedProbeOutput: Sendable {
        public let groupStemHint: String
        public let durationSeconds: Double?
        public let thumbnailJPEGData: Data?
        public let expandedVariants: [SniffedVariantOption]
    }

    public struct CapturedManifest: Sendable, Equatable {
        public let text: String
        public let finalURL: URL

        public init(text: String, finalURL: URL) {
            self.text = text
            self.finalURL = finalURL
        }
    }

    public typealias CookieHeaderBuilder = @Sendable (_ destinationURL: URL) -> String?
    public typealias InPageManifestFetcher = @Sendable (URL) async -> CapturedManifest?

    public static func probeCandidate(
        _ candidate: SniffedStreamCandidate,
        posterURL: URL?,
        capturedManifests: [String: CapturedManifest] = [:],
        inPageManifestFetcher: InPageManifestFetcher? = nil,
        cookieHeaderBuilder: CookieHeaderBuilder? = nil
    ) async -> EnrichedProbeOutput {
        let lease = SystemProxyBridge.acquireSessionLease(for: .streamProber, targetURL: candidate.streamURL)
        defer { lease.release() }
        let session = lease.session
        let stemHint = extractNormalizedAssetStem(from: candidate.streamURL)

        // Always prioritize an already-captured `#EXTM3U` manifest in memory regardless of the
        // initial format guess so single-use-token HLS URLs never trigger a destructive Range probe.
        let hasCachedEXTM3U = capturedManifests[candidate.streamURL.absoluteString]?
            .text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") == true

        if hasCachedEXTM3U || candidate.format == .hls {
            return await probeHLSCandidate(
                candidate,
                stemHint: stemHint,
                posterURL: posterURL,
                capturedManifests: capturedManifests,
                inPageManifestFetcher: inPageManifestFetcher,
                cookieHeaderBuilder: cookieHeaderBuilder,
                session: session
            )
        }

        switch candidate.format {
        case .hls:
            // Handled above.
            return EnrichedProbeOutput(groupStemHint: stemHint, durationSeconds: nil, thumbnailJPEGData: nil, expandedVariants: [])
        case .dash:
            let headers = HLSStreamEngine.normalizedBrowserHeaders(candidate.headers, manifestURL: candidate.streamURL)
            return await makeUnsupportedDASHOutput(
                candidate: candidate,
                effectiveURL: candidate.streamURL,
                headers: headers,
                stemHint: stemHint,
                posterURL: posterURL,
                cookieHeaderBuilder: cookieHeaderBuilder,
                session: session
            )
        case .mp4:
            return await probeDirectCandidate(
                candidate,
                stemHint: stemHint,
                posterURL: posterURL,
                capturedManifests: capturedManifests,
                inPageManifestFetcher: inPageManifestFetcher,
                cookieHeaderBuilder: cookieHeaderBuilder,
                session: session
            )
        }
    }

    private static func makeUnsupportedDASHOutput(
        candidate: SniffedStreamCandidate,
        effectiveURL: URL,
        headers: [String: String],
        stemHint: String,
        posterURL: URL?,
        cookieHeaderBuilder: CookieHeaderBuilder?,
        session: URLSession
    ) async -> EnrichedProbeOutput {
        // MPEG-DASH (.mpd) is surfaced cleanly as unsupported until a native DASH muxer lands
        // (see `.agents/TODO.md`), preventing raw `.mpd` XML from being downloaded as `.mp4`.
        let posterData: Data? = if let posterURL {
            await fetchBinaryData(
                url: posterURL,
                headers: reScopedHeaders(
                    from: effectiveURL,
                    to: posterURL,
                    headers: headers,
                    cookieHeaderBuilder: cookieHeaderBuilder
                ),
                session: session
            )
        } else {
            nil
        }
        let h = candidate.hintedHeight ?? MediaURLClassifier.inferredPixelHeight(fromQualityScore: candidate.qualityScore)
        let w = candidate.hintedWidth
        let option = SniffedVariantOption(
            id: candidate.streamURL.absoluteString,
            url: effectiveURL,
            format: .dash,
            resolutionLabel: formatResolutionLabel(width: w, height: h, fallback: L("DASH Stream")),
            width: w,
            height: h,
            bandwidthBps: nil,
            exactOrEstimatedBytes: nil,
            headers: headers,
            qualityRank: h ?? 0,
            fileExtension: "mpd"
        )
        return EnrichedProbeOutput(
            groupStemHint: stemHint,
            durationSeconds: candidate.hintedDuration,
            thumbnailJPEGData: posterData,
            expandedVariants: [option]
        )
    }

    /// Re-scopes origin-bound credentials (`Cookie`, `Authorization`, `Proxy-Authorization`, and
    /// HTTPS -> HTTP `Referer`/`Origin`) whenever a probe target crosses origins (e.g. 302 redirect,
    /// cross-origin HLS sub-playlist/segment, or poster image).
    static func reScopedHeaders(
        from sourceURL: URL,
        to destinationURL: URL,
        headers: [String: String],
        cookieHeaderBuilder: CookieHeaderBuilder?
    ) -> [String: String] {
        guard !CrossOriginRedirectAuthStripper.isSameOrigin(sourceURL, destinationURL) else {
            return headers
        }
        var scoped = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
            from: headers,
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )
        if let rebuiltCookie = cookieHeaderBuilder?(destinationURL), !rebuiltCookie.isEmpty {
            scoped["Cookie"] = rebuiltCookie
        }
        return scoped
    }

    // MARK: - HLS Master & Media Playlist Inspection

    private static func probeHLSCandidate(
        _ candidate: SniffedStreamCandidate,
        stemHint: String,
        posterURL: URL?,
        capturedManifests: [String: CapturedManifest],
        inPageManifestFetcher: InPageManifestFetcher?,
        cookieHeaderBuilder: CookieHeaderBuilder?,
        session: URLSession
    ) async -> EnrichedProbeOutput {
        let headers = HLSStreamEngine.normalizedBrowserHeaders(candidate.headers, manifestURL: candidate.streamURL)
        var variants: [SniffedVariantOption] = []
        var parsedDuration: Double?

        var sampledMediaPlaylistText: String?
        var manifestFetchError: String?
        var usedInPageFallback = false
        var effectiveManifestURL = candidate.streamURL
        var effectiveManifestHeaders = headers
        var manifestResult: ManifestFetchResult
        if let captured = capturedManifests[candidate.streamURL.absoluteString],
           captured.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
            manifestResult = .success(text: captured.text, finalURL: captured.finalURL)
        } else {
            manifestResult = await fetchUTF8TextWithReason(url: candidate.streamURL, headers: headers, session: session)
            // When Cloudflare/WAF/cookie-partitioned origins reject out-of-band URLSession with 401/403,
            // fetch the manifest directly inside the live WKWebView iframe (genuine WebKit TLS + cookies),
            // preserving `Response.url` after redirects so relative HLS URIs resolve accurately.
            if case .failure(let reason, let statusCode) = manifestResult,
               (statusCode == 403 || statusCode == 401 || reason == "HTTP 403" || reason == "HTTP 401"),
               let inPageFetcher = inPageManifestFetcher,
               let live = await inPageFetcher(candidate.streamURL) {
                manifestResult = .success(text: live.text, finalURL: live.finalURL)
                usedInPageFallback = true
            }
        }

        switch manifestResult {
        case .success(let manifestText, let resolvedManifestURL):
            effectiveManifestURL = resolvedManifestURL
            effectiveManifestHeaders = reScopedHeaders(
                from: candidate.streamURL,
                to: resolvedManifestURL,
                headers: headers,
                cookieHeaderBuilder: cookieHeaderBuilder
            )
            if manifestText.contains("#EXT-X-STREAM-INF:") {
                variants = parseMasterVariants(
                    manifestText: manifestText,
                    baseURL: effectiveManifestURL,
                    headers: effectiveManifestHeaders,
                    cookieHeaderBuilder: cookieHeaderBuilder
                )
                // Attach any already-captured sub-playlists from WKWebView (bypasses Cloudflare 403 on manifest origins).
                for idx in variants.indices {
                    let subKey = variants[idx].url.absoluteString
                    if let subCaptured = capturedManifests[subKey],
                       subCaptured.text.contains("#EXTINF:") {
                        let existing = variants[idx]
                        variants[idx] = existing.withResolvedPlaylist(
                            url: subCaptured.finalURL,
                            headers: reScopedHeaders(
                                from: existing.url,
                                to: subCaptured.finalURL,
                                headers: existing.headers,
                                cookieHeaderBuilder: cookieHeaderBuilder
                            ),
                            text: subCaptured.text
                        )
                        if parsedDuration == nil { parsedDuration = sumEXTINFDuration(subCaptured.text) }
                        if sampledMediaPlaylistText == nil { sampledMediaPlaylistText = subCaptured.text }
                    }
                }
                // Fetch sub-playlists for duration & preloaded media manifest (especially when origin blocks URLSession).
                if usedInPageFallback, let inPageFetcher = inPageManifestFetcher {
                    for idx in variants.indices where variants[idx].preloadedManifestText == nil {
                        let reqSubURL = variants[idx].url
                        if let liveSub = await inPageFetcher(reqSubURL), liveSub.text.contains("#EXTINF:") {
                            let existing = variants[idx]
                            variants[idx] = existing.withResolvedPlaylist(
                                url: liveSub.finalURL,
                                headers: reScopedHeaders(
                                    from: reqSubURL,
                                    to: liveSub.finalURL,
                                    headers: existing.headers,
                                    cookieHeaderBuilder: cookieHeaderBuilder
                                ),
                                text: liveSub.text
                            )
                            if parsedDuration == nil { parsedDuration = sumEXTINFDuration(liveSub.text) }
                            if sampledMediaPlaylistText == nil { sampledMediaPlaylistText = liveSub.text }
                        }
                    }
                } else if parsedDuration == nil,
                          let fastestIdx = variants.indices.last ?? variants.indices.first {
                    let fastestSubURL = variants[fastestIdx].url
                    let subHeaders = variants[fastestIdx].headers
                    var resolvedSub: CapturedManifest?
                    if case .success(let fetchedText, let finalSubURL) = await fetchUTF8TextWithReason(
                        url: fastestSubURL,
                        headers: subHeaders,
                        session: session
                    ) {
                        resolvedSub = CapturedManifest(text: fetchedText, finalURL: finalSubURL)
                    } else if let inPageFetcher = inPageManifestFetcher {
                        resolvedSub = await inPageFetcher(fastestSubURL)
                    }
                    if let resolvedSub {
                        parsedDuration = sumEXTINFDuration(resolvedSub.text)
                        if resolvedSub.text.contains("#EXTINF:") {
                            let existing = variants[fastestIdx]
                            variants[fastestIdx] = existing.withResolvedPlaylist(
                                url: resolvedSub.finalURL,
                                headers: reScopedHeaders(
                                    from: fastestSubURL,
                                    to: resolvedSub.finalURL,
                                    headers: subHeaders,
                                    cookieHeaderBuilder: cookieHeaderBuilder
                                ),
                                text: resolvedSub.text
                            )
                            if sampledMediaPlaylistText == nil {
                                sampledMediaPlaylistText = resolvedSub.text
                            }
                        }
                    }
                }
            } else if manifestText.contains("#EXTINF:") {
                parsedDuration = sumEXTINFDuration(manifestText)
                sampledMediaPlaylistText = manifestText
            }
        case .failure(let reason, _):
            manifestFetchError = reason
        }

        // Avoid passing remote `.m3u8` URLs to out-of-process `mediaserverd` (`AVURLAsset`), which strips
        // custom `Referer` / `Cookie` headers on signed CDNs and hangs retrying `403`.
        // Also skip redundant `AVURLAsset` probing when the manifest host itself already timed out or failed TLS.
        let avProbe: AVAssetProbeSummary
        if let mediaText = sampledMediaPlaylistText {
            let sampledVariant = variants.first(where: { $0.preloadedManifestText != nil })
            let mediaBaseURL = sampledVariant?.url ?? effectiveManifestURL
            let mediaHeaders = sampledVariant?.headers ?? effectiveManifestHeaders
            avProbe = await probeFirstHLSSegmentLocally(
                manifestText: mediaText,
                baseURL: mediaBaseURL,
                headers: mediaHeaders,
                fallbackPosterURL: posterURL,
                cookieHeaderBuilder: cookieHeaderBuilder,
                session: session
            )
        } else if let posterURL,
                  let posterBytes = await fetchBinaryData(
                      url: posterURL,
                      headers: reScopedHeaders(
                          from: effectiveManifestURL,
                          to: posterURL,
                          headers: effectiveManifestHeaders,
                          cookieHeaderBuilder: cookieHeaderBuilder
                      ),
                      session: session
                  ) {
            avProbe = AVAssetProbeSummary(
                durationSeconds: nil,
                width: nil,
                height: nil,
                hasAudio: true,
                isStoryboardSpritesheet: false,
                thumbnailJPEGData: posterBytes
            )
        } else if manifestFetchError == nil,
                  effectiveManifestURL.pathExtension.lowercased() == "m3u8",
                  !variants.contains(where: { $0.url.pathExtension.lowercased() == "tar" }) {
            let probeVariant = variants.first(where: { ($0.height ?? 0) <= 720 })
            let targetProbeURL = probeVariant?.url ?? effectiveManifestURL
            let targetProbeHeaders = probeVariant?.headers ?? effectiveManifestHeaders
            avProbe = await probeAVAssetWithTimeout(
                url: targetProbeURL,
                headers: targetProbeHeaders,
                fallbackPosterURL: posterURL,
                cookieHeaderBuilder: cookieHeaderBuilder,
                session: session,
                timeoutSeconds: 3.5
            )
        } else {
            avProbe = AVAssetProbeSummary(
                durationSeconds: nil,
                width: nil,
                height: nil,
                hasAudio: true,
                isStoryboardSpritesheet: false,
                thumbnailJPEGData: nil
            )
        }
        let finalDuration = parsedDuration ?? avProbe.durationSeconds ?? candidate.hintedDuration

        if variants.isEmpty {
            let h = avProbe.height ?? candidate.hintedHeight ?? MediaURLClassifier.inferredPixelHeight(fromQualityScore: candidate.qualityScore)
            let w = avProbe.width ?? candidate.hintedWidth
            let label = formatResolutionLabel(width: w, height: h, fallback: L("HLS Stream"))
            var inferredBytes = extractTarRangeStartOffset(from: effectiveManifestURL)
            if inferredBytes == nil,
               let mediaText = sampledMediaPlaylistText,
               let totalDur = finalDuration, totalDur > 0 {
                inferredBytes = await estimateMediaPlaylistBytes(
                    manifestText: mediaText,
                    baseURL: effectiveManifestURL,
                    totalDuration: totalDur,
                    headers: effectiveManifestHeaders,
                    cookieHeaderBuilder: cookieHeaderBuilder,
                    session: session
                )
            }
            variants = [
                SniffedVariantOption(
                    id: candidate.streamURL.absoluteString,
                    url: effectiveManifestURL,
                    format: .hls,
                    resolutionLabel: label,
                    width: w,
                    height: h,
                    bandwidthBps: nil,
                    exactOrEstimatedBytes: inferredBytes,
                    headers: effectiveManifestHeaders,
                    qualityRank: manifestFetchError == nil ? (h ?? candidate.qualityScore) : -1,
                    probeError: manifestFetchError,
                    preloadedManifestText: sampledMediaPlaylistText,
                    fileExtension: "mp4"
                )
            ]
        } else if let dur = finalDuration, dur > 0 {
            // Compute accurate byte-size estimates from Master BANDWIDTH × duration
            for idx in variants.indices {
                if let bw = variants[idx].bandwidthBps, bw > 0 {
                    variants[idx].exactOrEstimatedBytes = Int64((Double(bw) / 8.0) * dur)
                } else if let archiveBytes = extractTarRangeStartOffset(from: variants[idx].url) {
                    variants[idx].exactOrEstimatedBytes = archiveBytes
                }
            }
        }

        return EnrichedProbeOutput(
            groupStemHint: stemHint,
            durationSeconds: finalDuration,
            thumbnailJPEGData: avProbe.thumbnailJPEGData,
            expandedVariants: variants.sorted { $0.qualityRank > $1.qualityRank }
        )
    }

    // MARK: - Direct MP4 Inspection

    private static let probeLogger = Logger(subsystem: "com.appautomaton.dysprosium", category: "StreamProber")

    private struct DirectHeaderProbe {
        let byteSize: Int64?
        let isHLSPlaylist: Bool
        let isDASHManifest: Bool
        let finalURL: URL
        let httpStatus: Int?
        let contentType: String?
        let effectiveHeaders: [String: String]
        let rejectionReason: String?
    }

    private static func originOnlyRefererHeaders(from headers: [String: String]) -> [String: String]? {
        guard let refKey = headers.keys.first(where: { $0.lowercased() == "referer" }),
              let rawRef = headers[refKey],
              let refURL = URL(string: rawRef),
              let scheme = refURL.scheme,
              let host = refURL.host() else {
            return nil
        }
        let originRef = refURL.port.map { "\(scheme)://\(host):\($0)/" } ?? "\(scheme)://\(host)/"
        guard originRef != rawRef else { return nil }
        var copy = headers
        copy[refKey] = originRef
        return copy
    }

    private static func withoutRefererHeaders(from headers: [String: String]) -> [String: String]? {
        let stripped = headers.filter {
            let lower = $0.key.lowercased()
            return lower != "referer" && lower != "origin"
        }
        return stripped.count == headers.count ? nil : stripped
    }

    private static func sanitizedBodySnippet(from data: Data) -> String? {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        let printableCount = collapsed.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 }.count
        guard printableCount * 10 >= collapsed.unicodeScalars.count * 8 else { return nil }
        let clipped = collapsed.count > 44 ? String(collapsed.prefix(44)) + "…" : collapsed
        return clipped
    }

    /// Checks common binary media container signatures in the first 64 bytes:
    /// MP4/MOV (`ftyp`/`moov`/`mdat`/`wide`/`free`), Matroska/WebM EBML (`1A 45 DF A3`),
    /// Ogg (`OggS`), FLV (`FLV`), FLAC (`fLaC`), WAV/AVI (`RIFF`), MP3 (`ID3`/sync),
    /// AAC ADTS (`0xFF 0xF0..0xF9`), and MPEG-TS (`0x47`).
    static func hasBinaryMediaMagic(_ prefix: Data) -> Bool {
        let b = [UInt8](prefix)
        if b.count >= 8 {
            let box = String(bytes: b[4..<8], encoding: .ascii)
            if box == "ftyp" || box == "moov" || box == "mdat" || box == "wide" || box == "free" {
                return true
            }
        }
        if b.count >= 12,
           b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 { // RIFF
            let fourcc = String(bytes: b[8..<12], encoding: .ascii)
            if fourcc == "WAVE" || fourcc == "AVI " { return true }
        }
        if b.count >= 4 {
            if b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3 { return true } // EBML (WebM/MKV)
            if b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53 { return true } // OggS
            if b[0] == 0x46 && b[1] == 0x4C && b[2] == 0x56 { return true } // FLV
            if b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43 { return true } // fLaC
        }
        if b.count >= 3 {
            if b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33 { return true } // MP3 ID3v2
        }
        if b.count >= 2 {
            // AAC ADTS (`11111111 1111x00x`) or MPEG Audio Layer I/II/III frame sync (`11111111 111xxxxx`, layer != 00)
            if b[0] == 0xFF && (b[1] & 0xF6) == 0xF0 { return true }
            if b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 && (b[1] & 0x06) != 0 { return true }
        }
        if b.count >= 189, b[0] == 0x47, b[188] == 0x47 {
            return true // MPEG-TS double sync
        }
        // Single MPEG-TS packet sync when only 64 bytes were peeked and payload is binary (not ASCII 'G' text)
        if b.count >= 4, b[0] == 0x47 {
            let nonPrintable = b.prefix(32).filter { $0 < 9 || ($0 > 13 && $0 < 32) || $0 >= 127 }.count
            if nonPrintable >= 4 { return true }
        }
        return false
    }

    private static func attemptDirectRangePeek(
        url: URL,
        headers: [String: String],
        cookieHeaderBuilder: CookieHeaderBuilder?,
        session: URLSession
    ) async -> DirectHeaderProbe? {
        var rangeReq = URLRequest(url: url)
        for (k, v) in headers { rangeReq.setValue(v, forHTTPHeaderField: k) }
        rangeReq.setValue("bytes=0-63", forHTTPHeaderField: "Range")
        rangeReq.timeoutInterval = 7

        guard let (asyncBytes, resp) = try? await session.bytes(
            for: rangeReq,
            delegate: CrossOriginRedirectAuthStripper.shared
        ) else {
            return nil
        }
        defer { asyncBytes.task.cancel() }
        guard let http = resp as? HTTPURLResponse else { return nil }

        let finalURL = http.url ?? url
        let scopedHeaders = reScopedHeaders(
            from: url,
            to: finalURL,
            headers: headers,
            cookieHeaderBuilder: cookieHeaderBuilder
        )
        let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        var totalBytes: Int64?
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.lastIndex(of: "/"),
           let parsed = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)),
           parsed > 0 {
            totalBytes = parsed
        } else if http.statusCode == 200, http.expectedContentLength > 0 {
            totalBytes = http.expectedContentLength
        }

        // Validate HTTP status FIRST before inspecting HLS/DASH content or peeking body bytes.
        if !(200...299).contains(http.statusCode) {
            probeLogger.notice("Direct probe HTTP \(http.statusCode) ct=\(ct, privacy: .public) host=\(finalURL.host() ?? "unknown", privacy: .private)")
            return DirectHeaderProbe(
                byteSize: nil,
                isHLSPlaylist: false,
                isDASHManifest: false,
                finalURL: finalURL,
                httpStatus: http.statusCode,
                contentType: ct.isEmpty ? nil : ct,
                effectiveHeaders: scopedHeaders,
                rejectionReason: "HTTP \(http.statusCode)"
            )
        }

        var prefix = Data()
        prefix.reserveCapacity(64)
        do {
            for try await byte in asyncBytes {
                prefix.append(byte)
                if prefix.count >= 64 { break }
            }
        } catch {}

        var isHLS = ct.contains("mpegurl")
        if !isHLS, !prefix.isEmpty,
           let headStr = String(data: prefix, encoding: .utf8),
           headStr.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
            isHLS = true
        }
        if isHLS {
            return DirectHeaderProbe(
                byteSize: totalBytes,
                isHLSPlaylist: true,
                isDASHManifest: false,
                finalURL: finalURL,
                httpStatus: http.statusCode,
                contentType: ct.isEmpty ? nil : ct,
                effectiveHeaders: scopedHeaders,
                rejectionReason: nil
            )
        }

        let isDASH = ct.contains("dash+xml") || finalURL.pathExtension.lowercased() == "mpd"
        if isDASH {
            return DirectHeaderProbe(
                byteSize: totalBytes,
                isHLSPlaylist: false,
                isDASHManifest: true,
                finalURL: finalURL,
                httpStatus: http.statusCode,
                contentType: ct.isEmpty ? nil : ct,
                effectiveHeaders: scopedHeaders,
                rejectionReason: nil
            )
        }

        // Validate that a 2xx response is genuine media rather than an anti-hotlink/expired-token
        // `200 OK` plain-text or HTML error payload (e.g. a 14-byte error string).
        let isExplicitNonMediaCT = ct.hasPrefix("text/html")
            || ct.hasPrefix("text/plain")
            || ct.hasPrefix("application/json")
            || ct.hasPrefix("application/xml")
            || ct.hasPrefix("text/xml")
        let effectiveKnownBytes = totalBytes ?? (http.statusCode == 200 && prefix.count < 64 ? Int64(prefix.count) : nil)
        let hasMagic = hasBinaryMediaMagic(prefix)
        let isTinyNonMedia = (effectiveKnownBytes ?? 4096) < 1024 && !hasMagic

        if isExplicitNonMediaCT || isTinyNonMedia {
            let snippet = sanitizedBodySnippet(from: prefix)
            let sizeDesc = effectiveKnownBytes.map { "\($0) B" } ?? "\(prefix.count) B"
            let reason = snippet.map { L("Rejected (\($0))") } ?? L("Not a video (\(sizeDesc))")
            probeLogger.notice("Direct probe rejected status=\(http.statusCode) ct=\(ct, privacy: .public) bytes=\(sizeDesc, privacy: .public) snippet=\(snippet ?? "<binary>", privacy: .private)")
            return DirectHeaderProbe(
                byteSize: nil,
                isHLSPlaylist: false,
                isDASHManifest: false,
                finalURL: finalURL,
                httpStatus: http.statusCode,
                contentType: ct.isEmpty ? nil : ct,
                effectiveHeaders: scopedHeaders,
                rejectionReason: reason
            )
        }

        return DirectHeaderProbe(
            byteSize: totalBytes,
            isHLSPlaylist: false,
            isDASHManifest: false,
            finalURL: finalURL,
            httpStatus: http.statusCode,
            contentType: ct.isEmpty ? nil : ct,
            effectiveHeaders: scopedHeaders,
            rejectionReason: nil
        )
    }

    private static func probeDirectStreamHeader(
        url: URL,
        headers: [String: String],
        cookieHeaderBuilder: CookieHeaderBuilder?,
        session: URLSession
    ) async -> DirectHeaderProbe {
        // Order header attempts to match real browser Referer semantics (`strict-origin-when-cross-origin`):
        // cross-origin requests prefer origin-only Referer first, then full Referer, then bare (no Referer/Origin).
        let refURL: URL? = headers.first(where: { $0.key.lowercased() == "referer" }).flatMap { URL(string: $0.value) }
        let isCrossOriginRef = (refURL != nil) && !CrossOriginRedirectAuthStripper.isSameOrigin(refURL, url)
        let originHeaders = originOnlyRefererHeaders(from: headers)
        let primaryHeaders = (isCrossOriginRef ? originHeaders : nil) ?? headers
        let secondaryHeaders: [String: String]? = isCrossOriginRef
            ? (originHeaders != nil ? headers : nil)
            : originHeaders

        var lastRejection: DirectHeaderProbe?
        if let firstAttempt = await attemptDirectRangePeek(url: url, headers: primaryHeaders, cookieHeaderBuilder: cookieHeaderBuilder, session: session) {
            if firstAttempt.rejectionReason == nil {
                return firstAttempt
            }
            lastRejection = firstAttempt

            // Retry with alternate Referer form (full <-> origin-only).
            var duplicateTextRejection = false
            if let secondaryHeaders,
               let retryAttempt = await attemptDirectRangePeek(url: url, headers: secondaryHeaders, cookieHeaderBuilder: cookieHeaderBuilder, session: session) {
                if retryAttempt.rejectionReason == nil {
                    return retryAttempt
                }
                // Only short-circuit the bare retry when BOTH attempts returned the exact same
                // `200 OK` non-media text rejection (e.g. `error_wrong_ip`), NOT on generic `403`.
                duplicateTextRejection = (firstAttempt.httpStatus == 200)
                    && (retryAttempt.httpStatus == 200)
                    && (retryAttempt.rejectionReason == firstAttempt.rejectionReason)
            }
            if !duplicateTextRejection,
               let bareHeaders = withoutRefererHeaders(from: headers),
               let bareAttempt = await attemptDirectRangePeek(url: url, headers: bareHeaders, cookieHeaderBuilder: cookieHeaderBuilder, session: session) {
                if bareAttempt.rejectionReason == nil {
                    return bareAttempt
                }
            }
        }

        // 2. Fallback to zero-body HTTP HEAD only when Range itself failed/returned 405/501 (not a confirmed 403/text rejection).
        if let rejected = lastRejection,
           rejected.httpStatus == 200 || rejected.httpStatus == 401 || rejected.httpStatus == 403 || rejected.httpStatus == 404 || rejected.httpStatus == 410 {
            return rejected
        }
        let fallbackBytes = await probeExactByteSize(url: url, headers: primaryHeaders, session: session)
        return DirectHeaderProbe(
            byteSize: (fallbackBytes ?? 0) >= 1024 ? fallbackBytes : nil,
            isHLSPlaylist: false,
            isDASHManifest: false,
            finalURL: url,
            httpStatus: fallbackBytes != nil ? 200 : lastRejection?.httpStatus,
            contentType: lastRejection?.contentType,
            effectiveHeaders: primaryHeaders,
            rejectionReason: (fallbackBytes ?? 0) >= 1024 ? nil : (lastRejection?.rejectionReason)
        )
    }

    private static func probeDirectCandidate(
        _ candidate: SniffedStreamCandidate,
        stemHint: String,
        posterURL: URL?,
        capturedManifests: [String: CapturedManifest] = [:],
        inPageManifestFetcher: InPageManifestFetcher? = nil,
        cookieHeaderBuilder: CookieHeaderBuilder? = nil,
        session: URLSession
    ) async -> EnrichedProbeOutput {
        let initialHeaders = HLSStreamEngine.normalizedBrowserHeaders(candidate.headers, manifestURL: candidate.streamURL)

        let headerProbe = await probeDirectStreamHeader(
            url: candidate.streamURL,
            headers: initialHeaders,
            cookieHeaderBuilder: cookieHeaderBuilder,
            session: session
        )
        let headers = headerProbe.effectiveHeaders
        let effectiveURL = headerProbe.finalURL

        // Extensionless `<video src="...">` URLs on Safari often serve HLS `.m3u8` natively:
        // automatically promote to HLS probing when Content-Type or first bytes prove `#EXTM3U`.
        if headerProbe.isHLSPlaylist {
            let promoted = candidate.upgrading(
                streamURL: effectiveURL,
                format: .hls,
                sourceDomain: effectiveURL.host()?.lowercased(),
                headers: headers,
                mimeType: headerProbe.contentType ?? candidate.mimeType
            )
            return await probeHLSCandidate(
                promoted,
                stemHint: stemHint,
                posterURL: posterURL,
                capturedManifests: capturedManifests,
                inPageManifestFetcher: inPageManifestFetcher,
                cookieHeaderBuilder: cookieHeaderBuilder,
                session: session
            )
        }

        // If an extensionless URL resolved to an MPEG-DASH `.mpd` manifest, mark cleanly as unsupported.
        if headerProbe.isDASHManifest {
            return await makeUnsupportedDASHOutput(
                candidate: candidate,
                effectiveURL: effectiveURL,
                headers: headers,
                stemHint: stemHint,
                posterURL: posterURL,
                cookieHeaderBuilder: cookieHeaderBuilder,
                session: session
            )
        }

        let exactBytes = headerProbe.byteSize
        let resolvedMIME = headerProbe.contentType ?? candidate.mimeType
        let containerExt = MediaURLClassifier.preferredFileExtension(
            url: effectiveURL,
            format: candidate.format,
            mimeType: resolvedMIME
        )

        // If the origin explicitly returned a non-video / rejected payload (e.g. HTTP 403 or a 14-byte
        // `200 OK` text error body), skip wasting time in `AVURLAsset` and surface the honest probeError.
        if let rejectionReason = headerProbe.rejectionReason {
            let thumbData: Data? = if let posterURL {
                await fetchBinaryData(
                    url: posterURL,
                    headers: reScopedHeaders(
                        from: effectiveURL,
                        to: posterURL,
                        headers: headers,
                        cookieHeaderBuilder: cookieHeaderBuilder
                    ),
                    session: session
                )
            } else {
                nil
            }
            let height = candidate.hintedHeight ?? MediaURLClassifier.inferredPixelHeight(fromQualityScore: candidate.qualityScore)
            let width = candidate.hintedWidth
            let label = formatResolutionLabel(
                width: width,
                height: height,
                fallback: containerExt == "mp4" ? L("MP4 Video") : L("\(containerExt.uppercased()) Media")
            )
            let option = SniffedVariantOption(
                id: candidate.streamURL.absoluteString,
                url: effectiveURL,
                format: candidate.format,
                resolutionLabel: label,
                width: width,
                height: height,
                bandwidthBps: nil,
                exactOrEstimatedBytes: nil,
                headers: headers,
                qualityRank: -1,
                probeError: rejectionReason,
                fileExtension: containerExt
            )
            return EnrichedProbeOutput(
                groupStemHint: stemHint,
                durationSeconds: candidate.hintedDuration,
                thumbnailJPEGData: thumbData,
                expandedVariants: [option]
            )
        }

        let avProbe = await probeAVAssetWithTimeout(
            url: effectiveURL,
            headers: headers,
            fallbackPosterURL: posterURL,
            cookieHeaderBuilder: cookieHeaderBuilder,
            session: session,
            timeoutSeconds: 6.5
        )

        // Discard timeline scrub-bar storyboards / spritesheet videos (e.g., 0.5 fps silent hover preview tracks)
        if avProbe.isStoryboardSpritesheet {
            return EnrichedProbeOutput(groupStemHint: stemHint, durationSeconds: nil, thumbnailJPEGData: nil, expandedVariants: [])
        }
        let resolvedDuration = avProbe.durationSeconds ?? candidate.hintedDuration
        if !avProbe.hasAudio,
           let dur = resolvedDuration, dur >= 25.0,
           let bytes = exactBytes, bytes > 0,
           (Double(bytes) * 8.0 / dur) < 28_000 {
            return EnrichedProbeOutput(groupStemHint: stemHint, durationSeconds: nil, thumbnailJPEGData: nil, expandedVariants: [])
        }

        let height = avProbe.height ?? candidate.hintedHeight ?? MediaURLClassifier.inferredPixelHeight(fromQualityScore: candidate.qualityScore)
        let width = avProbe.width ?? candidate.hintedWidth
        let label = formatResolutionLabel(
            width: width,
            height: height,
            fallback: containerExt == "mp4" ? L("MP4 Video") : L("\(containerExt.uppercased()) Media")
        )

        let option = SniffedVariantOption(
            id: candidate.streamURL.absoluteString,
            url: effectiveURL,
            format: candidate.format,
            resolutionLabel: label,
            width: width,
            height: height,
            bandwidthBps: nil,
            exactOrEstimatedBytes: exactBytes,
            headers: headers,
            qualityRank: height ?? candidate.qualityScore,
            fileExtension: containerExt
        )

        return EnrichedProbeOutput(
            groupStemHint: stemHint,
            durationSeconds: resolvedDuration,
            thumbnailJPEGData: avProbe.thumbnailJPEGData,
            expandedVariants: [option]
        )
    }

    // MARK: - Authenticated AVURLAsset + AVAssetImageGenerator Thumbnail Extractor

    private struct AVAssetProbeSummary: Sendable {
        let durationSeconds: Double?
        let width: Int?
        let height: Int?
        let hasAudio: Bool
        let isStoryboardSpritesheet: Bool
        let thumbnailJPEGData: Data?
    }

    private final class AssetCancelHandle: @unchecked Sendable {
        let asset: AVURLAsset
        let generator: AVAssetImageGenerator
        init(asset: AVURLAsset, generator: AVAssetImageGenerator) {
            self.asset = asset
            self.generator = generator
        }
        func cancel() {
            generator.cancelAllCGImageGeneration()
            asset.cancelLoading()
        }
    }

    private static func probeAVAsset(
        url: URL,
        headers: [String: String],
        fallbackPosterURL: URL?,
        cookieHeaderBuilder: CookieHeaderBuilder? = nil,
        session: URLSession
    ) async -> AVAssetProbeSummary {
        let options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": headers
        ]
        let asset = AVURLAsset(url: url, options: options)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2.5, preferredTimescale: 600)
        let cancelHandle = AssetCancelHandle(asset: asset, generator: generator)

        return await withTaskCancellationHandler {
            let asset = cancelHandle.asset
            let generator = cancelHandle.generator
            var durationSec: Double?
            var width: Int?
            var height: Int?
            var nominalFPS: Float = 0

            guard !Task.isCancelled else {
                return AVAssetProbeSummary(durationSeconds: nil, width: nil, height: nil, hasAudio: true, isStoryboardSpritesheet: false, thumbnailJPEGData: nil)
            }

            if let cmDur = try? await asset.load(.duration) {
                let s = cmDur.seconds
                if s.isFinite && s > 0.1 {
                    durationSec = s
                }
            }
            guard !Task.isCancelled else {
                return AVAssetProbeSummary(durationSeconds: durationSec, width: nil, height: nil, hasAudio: true, isStoryboardSpritesheet: false, thumbnailJPEGData: nil)
            }

            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let hasAudio = !audioTracks.isEmpty

            if let vTrack = (try? await asset.loadTracks(withMediaType: .video))?.first {
                if let fps = try? await vTrack.load(.nominalFrameRate) {
                    nominalFPS = fps
                }
                if let natSize = try? await vTrack.load(.naturalSize),
                   let transform = try? await vTrack.load(.preferredTransform) {
                    let transformed = natSize.applying(transform)
                    let w = Int(abs(transformed.width).rounded())
                    let h = Int(abs(transformed.height).rounded())
                    if w > 0 && h > 0 {
                        width = w
                        height = h
                    }
                }
            }

            let isStoryboard = !hasAudio && nominalFPS > 0 && nominalFPS < 4.0 && (durationSec ?? 0) >= 12.0
            if isStoryboard || Task.isCancelled {
                return AVAssetProbeSummary(
                    durationSeconds: durationSec,
                    width: width,
                    height: height,
                    hasAudio: hasAudio,
                    isStoryboardSpritesheet: isStoryboard,
                    thumbnailJPEGData: nil
                )
            }

            var jpegData: Data?
            // When video dimensions are already known and a page poster exists, fetch the lightweight poster
            // instead of spinning up hardware 4K video decoding.
            if width != nil, height != nil, let posterURL = fallbackPosterURL {
                let posterHeaders = reScopedHeaders(
                    from: url,
                    to: posterURL,
                    headers: headers,
                    cookieHeaderBuilder: cookieHeaderBuilder
                )
                jpegData = await fetchBinaryData(url: posterURL, headers: posterHeaders, session: session)
            }

            if jpegData == nil, !Task.isCancelled {
                // Only decode native size when `asset.tracks` had no video dimensions; otherwise cap at 480 px.
                generator.maximumSize = (width != nil && height != nil) ? CGSize(width: 480, height: 480) : .zero
                let sampleSecond: Double = {
                    guard let d = durationSec, d > 1.0 else { return 1.0 }
                    return min(3.0, max(0.5, d * 0.12))
                }()
                let targetTime = CMTime(seconds: sampleSecond, preferredTimescale: 600)

                if let (cgImage, _) = try? await generator.image(at: targetTime) {
                    if width == nil || height == nil, cgImage.width > 0, cgImage.height > 0 {
                        width = cgImage.width
                        height = cgImage.height
                    }
                    jpegData = downscaledJPEGData(from: cgImage, maxDimension: 480)
                } else if let posterURL = fallbackPosterURL {
                    let posterHeaders = reScopedHeaders(
                        from: url,
                        to: posterURL,
                        headers: headers,
                        cookieHeaderBuilder: cookieHeaderBuilder
                    )
                    jpegData = await fetchBinaryData(url: posterURL, headers: posterHeaders, session: session)
                }
            }

            return AVAssetProbeSummary(
                durationSeconds: durationSec,
                width: width,
                height: height,
                hasAudio: hasAudio,
                isStoryboardSpritesheet: false,
                thumbnailJPEGData: jpegData
            )
        } onCancel: {
            cancelHandle.cancel()
        }
    }

    // MARK: - Manifest & HTTP Helpers

    static func parseMasterVariants(
        manifestText: String,
        baseURL: URL,
        headers: [String: String],
        cookieHeaderBuilder: CookieHeaderBuilder? = nil
    ) -> [SniffedVariantOption] {
        let lines = manifestText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var options: [SniffedVariantOption] = []
        var seenHeightsAndBW: Set<String> = []

        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let rawAttrs = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                let bw = extractAttribute("AVERAGE-BANDWIDTH", in: rawAttrs).flatMap(Int64.init)
                    ?? extractAttribute("BANDWIDTH", in: rawAttrs).flatMap(Int64.init)
                var width: Int?
                var height: Int?
                if let res = extractAttribute("RESOLUTION", in: rawAttrs) {
                    let parts = res.lowercased().split(separator: "x")
                    if parts.count == 2 {
                        width = Int(parts[0])
                        height = Int(parts[1])
                    }
                }

                var nextIdx = idx + 1
                while nextIdx < lines.count, (lines[nextIdx].isEmpty || lines[nextIdx].hasPrefix("#")) {
                    nextIdx += 1
                }
                if nextIdx < lines.count,
                   let subURL = URL(string: lines[nextIdx], relativeTo: baseURL)?.absoluteURL {
                    let dedupKey = "\(height ?? 0)-\((bw ?? 0) / 100_000)"
                    if !seenHeightsAndBW.contains(dedupKey) {
                        seenHeightsAndBW.insert(dedupKey)
                        let label = formatResolutionLabel(
                            width: width,
                            height: height,
                            fallback: bw.map { L("\(Double($0) / 1_000_000.0, specifier: "%.1f") Mbps HLS") } ?? L("HLS Variant")
                        )
                        let rank = (height ?? 0) * 10_000 + Int((bw ?? 0) / 1_000)
                        let variantHeaders = reScopedHeaders(
                            from: baseURL,
                            to: subURL,
                            headers: headers,
                            cookieHeaderBuilder: cookieHeaderBuilder
                        )
                        options.append(SniffedVariantOption(
                            id: subURL.absoluteString,
                            url: subURL,
                            format: .hls,
                            resolutionLabel: label,
                            width: width,
                            height: height,
                            bandwidthBps: bw,
                            exactOrEstimatedBytes: nil,
                            headers: variantHeaders,
                            qualityRank: rank,
                            fileExtension: "mp4"
                        ))
                    }
                }
                idx = nextIdx + 1
            } else {
                idx += 1
            }
        }
        return options.sorted { $0.qualityRank > $1.qualityRank }
    }

    private static func sumEXTINFDuration(_ text: String) -> Double? {
        var total: Double = 0
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXTINF:") {
                let valToken = trimmed.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                if let d = Double(valToken.trimmingCharacters(in: .whitespaces)), d > 0 {
                    total += d
                    count += 1
                }
            }
        }
        return count > 0 ? total : nil
    }

    private static func estimateMediaPlaylistBytes(
        manifestText: String,
        baseURL: URL,
        totalDuration: Double,
        headers: [String: String],
        cookieHeaderBuilder: CookieHeaderBuilder? = nil,
        session: URLSession
    ) async -> Int64? {
        var entries: [(duration: Double, url: URL)] = []
        var pendingDur: Double = 0
        for rawLine in manifestText.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#EXTINF:") {
                let token = trimmed.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                pendingDur = Double(token.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if !trimmed.hasPrefix("#"), pendingDur > 0.5,
                      let segURL = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
                entries.append((pendingDur, segURL))
                pendingDur = 0
            }
        }
        guard !entries.isEmpty else { return nil }
        let sample = entries[entries.count / 2]
        let segHeaders = reScopedHeaders(
            from: baseURL,
            to: sample.url,
            headers: headers,
            cookieHeaderBuilder: cookieHeaderBuilder
        )
        guard let segBytes = await probeExactByteSize(url: sample.url, headers: segHeaders, session: session),
              segBytes > 1_024, sample.duration > 0.5 else {
            return nil
        }
        let bytesPerSec = Double(segBytes) / sample.duration
        return Int64(bytesPerSec * totalDuration)
    }

    private static func downscaledJPEGData(from cgImage: CGImage, maxDimension: CGFloat) -> Data? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, maxDimension / max(w, h))
        if scale >= 0.99 {
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.78)
        }
        let targetSize = CGSize(width: floor(w * scale), height: floor(h * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let img = renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return img.jpegData(compressionQuality: 0.78)
    }

    private static func probeFirstHLSSegmentLocally(
        manifestText: String,
        baseURL: URL,
        headers: [String: String],
        fallbackPosterURL: URL?,
        cookieHeaderBuilder: CookieHeaderBuilder? = nil,
        session: URLSession
    ) async -> AVAssetProbeSummary {
        if let fallbackPosterURL,
           let posterBytes = await fetchBinaryData(
               url: fallbackPosterURL,
               headers: reScopedHeaders(
                   from: baseURL,
                   to: fallbackPosterURL,
                   headers: headers,
                   cookieHeaderBuilder: cookieHeaderBuilder
               ),
               session: session
           ),
           !posterBytes.isEmpty {
            return AVAssetProbeSummary(
                durationSeconds: nil,
                width: nil,
                height: nil,
                hasAudio: true,
                isStoryboardSpritesheet: false,
                thumbnailJPEGData: posterBytes
            )
        }
        let parsed = HLSStreamEngine.parseMediaPlaylist(manifestText: manifestText, baseURL: baseURL)
        guard !parsed.isFragmentedMP4,
              parsed.segments.first?.keyURL == nil,
              let firstSeg = parsed.segments.first,
              let rawSeg = await fetchBinaryData(
                  url: firstSeg.url,
                  headers: reScopedHeaders(
                      from: baseURL,
                      to: firstSeg.url,
                      headers: headers,
                      cookieHeaderBuilder: cookieHeaderBuilder
                  ),
                  session: session
              ) else {
            return AVAssetProbeSummary(
                durationSeconds: nil,
                width: nil,
                height: nil,
                hasAudio: true,
                isStoryboardSpritesheet: false,
                thumbnailJPEGData: nil
            )
        }

        let cleanTS = HLSStreamEngine.sanitizeMPEGTSPayload(rawSeg)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dys-probe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tsFile = tempDir.appendingPathComponent("seg0.ts")
        let mp4File = tempDir.appendingPathComponent("seg0.mp4")

        do {
            try cleanTS.write(to: tsFile)
            try await NativeMP4Remuxer.remuxMPEGTS(from: tsFile, to: mp4File)
            let localProbe = await probeAVAsset(url: mp4File, headers: [:], fallbackPosterURL: nil, session: session)
            return AVAssetProbeSummary(
                durationSeconds: nil,
                width: localProbe.width,
                height: localProbe.height,
                hasAudio: localProbe.hasAudio,
                isStoryboardSpritesheet: false,
                thumbnailJPEGData: localProbe.thumbnailJPEGData
            )
        } catch {
            return AVAssetProbeSummary(
                durationSeconds: nil,
                width: nil,
                height: nil,
                hasAudio: true,
                isStoryboardSpritesheet: false,
                thumbnailJPEGData: nil
            )
        }
    }

    private static func probeAVAssetWithTimeout(
        url: URL,
        headers: [String: String],
        fallbackPosterURL: URL?,
        cookieHeaderBuilder: CookieHeaderBuilder? = nil,
        session: URLSession,
        timeoutSeconds: Double
    ) async -> AVAssetProbeSummary {
        await withTaskGroup(of: AVAssetProbeSummary?.self) { group in
            group.addTask {
                await probeAVAsset(
                    url: url,
                    headers: headers,
                    fallbackPosterURL: fallbackPosterURL,
                    cookieHeaderBuilder: cookieHeaderBuilder,
                    session: session
                )
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(Int(timeoutSeconds * 1000)))
                return nil
            }
            if let first = await group.next(), let valid = first {
                group.cancelAll()
                return valid
            }
            group.cancelAll()
            let posterBytes: Data? = if let fallbackPosterURL {
                await fetchBinaryData(
                    url: fallbackPosterURL,
                    headers: reScopedHeaders(
                        from: url,
                        to: fallbackPosterURL,
                        headers: headers,
                        cookieHeaderBuilder: cookieHeaderBuilder
                    ),
                    session: session
                )
            } else {
                nil
            }
            return AVAssetProbeSummary(
                durationSeconds: nil,
                width: nil,
                height: nil,
                hasAudio: true,
                isStoryboardSpritesheet: false,
                thumbnailJPEGData: posterBytes
            )
        }
    }

    private static func probeExactByteSize(url: URL, headers: [String: String], session: URLSession) async -> Int64? {
        // 1. Zero-body HTTP HEAD check first (avoids downloading full segments on servers that ignore Range)
        var headReq = URLRequest(url: url)
        headReq.httpMethod = "HEAD"
        for (k, v) in headers { headReq.setValue(v, forHTTPHeaderField: k) }
        headReq.timeoutInterval = 6
        if let (_, headResp) = try? await session.data(
            for: headReq,
            delegate: CrossOriginRedirectAuthStripper.shared
        ),
           let httpHead = headResp as? HTTPURLResponse,
           (200...299).contains(httpHead.statusCode),
           httpHead.expectedContentLength > 0 {
            return httpHead.expectedContentLength
        }

        // 2. Fallback to 2-byte Range probe (`Content-Range: bytes 0-1/TOTAL`) using streaming `bytes(for:)`
        // and immediate cancellation so non-Range `200 OK` servers never buffer a full video body into RAM.
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        req.timeoutInterval = 6

        guard let (asyncBytes, resp) = try? await session.bytes(
            for: req,
            delegate: CrossOriginRedirectAuthStripper.shared
        ) else {
            return nil
        }
        defer { asyncBytes.task.cancel() }
        guard let http = resp as? HTTPURLResponse else {
            return nil
        }
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.lastIndex(of: "/"),
           let total = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)),
           total > 0 {
            return total
        }
        if http.statusCode == 200, http.expectedContentLength > 0 {
            return http.expectedContentLength
        }
        return nil
    }

    enum ManifestFetchResult {
        case success(text: String, finalURL: URL)
        case failure(String, statusCode: Int? = nil)
    }

    private static let maxManifestBytes = 512 * 1024

    /// Bounded streaming HLS playlist reader (`<= 512 KiB`) that rejects binary video/audio MIME
    /// types and cancels immediately if the leading bytes are not `#EXTM3U`, eliminating OOM risk
    /// when a binary MP4 URL was speculatively routed into HLS probing.
    static func fetchUTF8TextWithReason(url: URL, headers: [String: String], session: URLSession) async -> ManifestFetchResult {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 8
        do {
            let (asyncBytes, resp) = try await session.bytes(
                for: req,
                delegate: CrossOriginRedirectAuthStripper.shared
            )
            defer { asyncBytes.task.cancel() }
            guard let http = resp as? HTTPURLResponse else {
                return .failure(L("Invalid response"))
            }
            guard (200...299).contains(http.statusCode) else {
                return .failure(L("HTTP \(http.statusCode)"), statusCode: http.statusCode)
            }
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if (ct.hasPrefix("video/") || ct.hasPrefix("audio/")) && !ct.contains("mpegurl") {
                return .failure(L("Binary media response"))
            }
            if http.expectedContentLength > Int64(maxManifestBytes) {
                return .failure(L("Playlist too large"))
            }

            var buffer = Data()
            buffer.reserveCapacity(min(65_536, max(4_096, Int(max(0, http.expectedContentLength)))))
            var validatedPrefix = false
            for try await byte in asyncBytes {
                buffer.append(byte)
                if !validatedPrefix && buffer.count >= 16 {
                    let head = String(data: buffer, encoding: .utf8) ?? String(data: buffer, encoding: .isoLatin1) ?? ""
                    let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count >= 7 {
                        guard trimmed.hasPrefix("#EXTM3U") else {
                            return .failure(L("Not an HLS playlist"))
                        }
                        validatedPrefix = true
                    }
                }
                if buffer.count > maxManifestBytes {
                    return .failure(L("Playlist too large"))
                }
            }
            guard let text = String(data: buffer, encoding: .utf8) ?? String(data: buffer, encoding: .isoLatin1) else {
                return .failure(L("Unreadable playlist"))
            }
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
                return .failure(L("Not an HLS playlist"))
            }
            return .success(text: text, finalURL: http.url ?? url)
        } catch let err as URLError {
            switch err.code {
            case .timedOut:
                return .failure(L("Timed out"))
            case .cannotFindHost, .dnsLookupFailed:
                return .failure(L("Host not found"))
            case .cannotConnectToHost, .networkConnectionLost:
                return .failure(L("Connection failed"))
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return .failure(L("TLS error"))
            default:
                return .failure(L("Unreachable"))
            }
        } catch {
            return .failure(L("Unreachable"))
        }
    }

    static func fetchBinaryData(url: URL, headers: [String: String], session: URLSession, maxBytes: Int = 8 * 1024 * 1024) async -> Data? {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 10
        guard let (asyncBytes, resp) = try? await session.bytes(
            for: req,
            delegate: CrossOriginRedirectAuthStripper.shared
        ) else {
            return nil
        }
        defer { asyncBytes.task.cancel() }
        guard let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              http.expectedContentLength <= Int64(maxBytes) else {
            return nil
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(min(maxBytes, Int(http.expectedContentLength)))
        }
        do {
            for try await byte in asyncBytes {
                data.append(byte)
                if data.count > maxBytes {
                    return nil
                }
            }
        } catch {
            return nil
        }
        return data
    }

    private static func extractTarRangeStartOffset(from url: URL) -> Int64? {
        guard url.pathExtension.lowercased() == "tar",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rangeVal = comps.queryItems?.first(where: { $0.name == "r_range" })?.value,
              let firstNum = rangeVal.split(separator: "-").first,
              let bytes = Int64(firstNum),
              bytes >= 65_536 else {
            return nil
        }
        return bytes
    }

    private static func extractAttribute(_ name: String, in raw: String) -> String? {
        let pattern = "\(name)="
        guard let range = raw.range(of: pattern) else { return nil }
        let rest = raw[range.upperBound...]
        if rest.first == "\"" {
            let afterQuote = rest.dropFirst()
            if let endQuote = afterQuote.firstIndex(of: "\"") {
                return String(afterQuote[..<endQuote])
            }
        } else {
            let end = rest.firstIndex(of: ",") ?? rest.endIndex
            return String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func formatResolutionLabel(width: Int?, height: Int?, fallback: String) -> String {
        guard let h = height, h > 0 else { return fallback }
        let shortEdge = min(width ?? h * 16 / 9, h)
        let tier: String = switch shortEdge {
        case 2000...: "4K \(h)p"
        case 1350..<2000: "2K \(h)p"
        case 1000..<1350: "1080p"
        case 680..<1000: "720p"
        case 450..<680: "480p"
        case 320..<450: "360p"
        default: "\(h)p"
        }
        return tier
    }

    /// Normalizes CDN asset filenames so multi-bitrate siblings of the same video
    /// (e.g., `O8xOz.baa.mp4`, `O8xOz.caa.mp4`, `.../hls/O8xOz/playlist.m3u8`) share a deterministic stem.
    static func extractNormalizedAssetStem(from url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        let genericNames: Set<String> = ["playlist", "master", "index", "prog_index", "manifest", "video", "hls", "hls-vod", "embed"]
        for comp in parts.reversed() {
            let base = (comp as NSString).deletingPathExtension
            let firstToken = base.split(separator: ".").first.map(String.init) ?? base
            let stripped = firstToken
                .replacingOccurrences(of: #"[-_](2160|1440|1080|720|480|360|240)p?$"#, with: "", options: .regularExpression)
            if stripped.count >= 4, !genericNames.contains(stripped.lowercased()) {
                return stripped.lowercased()
            }
        }
        return url.deletingPathExtension().lastPathComponent.lowercased()
    }
}
