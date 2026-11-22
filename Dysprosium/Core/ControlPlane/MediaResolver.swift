import Foundation

/// Control Plane router that classifies incoming URLs into direct HTTP Range files,
/// native HLS `.m3u8` (including disguised `#EXTM3U` endpoints) -> `.mp4` streams,
/// or webpage media resolved via Cleanroom WebKit runtime interception.
/// Strictly MIME- and format-driven (`MediaURLClassifier`) with zero hardcoded website domain lists.
public struct MediaResolver: Sendable {
    private let rangeEngine: RangeTransferEngine

    public init(rangeEngine: RangeTransferEngine = RangeTransferEngine()) {
        self.rangeEngine = rangeEngine
    }

    public func resolve(
        url: URL,
        headers: [String: String] = [:],
        preferredFilename: String? = nil,
        isPrivate: Bool = false
    ) async throws -> ResolvedTransferPlan {
        let normalizedHost = url.host().map(LiveContainerEnvironment.HostNormalizer.normalize)
        let host = (normalizedHost?.isEmpty == false ? normalizedHost : nil) ?? "remote"
        let pathExt = url.pathExtension.lowercased()

        // 1. Explicit HLS manifest fast path -> outputs native fast-start .mp4
        if MediaURLClassifier.isExplicitHLSURL(url) {
            return Self.makeHLSPlan(sourceURL: url, manifestURL: url, host: host, headers: headers, preferredFilename: preferredFilename)
        }

        // Private tabs resolve through a dedicated one-shot ephemeral, cookieless URLSession
        // honoring the exact same CIDR/domain bypass policy as pooled Standard leases.
        let sessionLease: SystemProxyBridge.SessionLease
        let effectiveRangeEngine: RangeTransferEngine
        if isPrivate {
            let privateSession = SystemProxyBridge.makeOneShotEphemeralSession(for: .mediaResolver, targetURL: url)
            sessionLease = SystemProxyBridge.SessionLease(session: privateSession) {
                privateSession.invalidateAndCancel()
            }
            effectiveRangeEngine = RangeTransferEngine(session: privateSession)
        } else {
            sessionLease = SystemProxyBridge.acquireSessionLease(for: .mediaResolver, targetURL: url)
            effectiveRangeEngine = rangeEngine
        }
        defer { sessionLease.release() }
        let probeSession = sessionLease.session

        // Reject explicit MPEG-DASH `.mpd` manifests cleanly instead of saving XML as `.mp4`.
        if pathExt == "mpd" {
            throw Self.unsupportedDASHError(host: host)
        }

        // 2. Probe URL via Range 0-0 to inspect HTTP MIME type & byte-range capability
        let probe = try await effectiveRangeEngine.probe(url: url, headers: headers)
        let mime = (probe.mimeType ?? "").lowercased()

        // HTML webpages -> Cleanroom WebKit runtime interception (or embedded yt-dlp if linked).
        // Tiny `text/html` payloads (<= 256 B) on already-authenticated stream requests (with Referer)
        // are origin token/IP rejections rather than browsable webpages.
        if mime.contains("text/html") && !MediaURLClassifier.isDirectSingleAssetURL(probe.finalURL) {
            let effectiveHeaders = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
                from: headers,
                sourceURL: url,
                destinationURL: probe.finalURL
            )
            let hasReferer = effectiveHeaders.keys.contains { $0.lowercased() == "referer" }
            if hasReferer, let total = probe.totalBytes, total > 0, total <= 256 {
                throw NSError(
                    domain: "Dysprosium.ControlPlane",
                    code: -403,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Stream rejected by \(host) (returned \(total)-byte HTML error — token expired or IP mismatch). Refresh the page and recapture the stream."
                    ]
                )
            }
            return try await resolveWebpage(
                url: url,
                host: host,
                preferredFilename: preferredFilename,
                isPrivate: isPrivate,
                rangeEngine: effectiveRangeEngine,
                probeSession: probeSession
            )
        }

        return try await Self.buildPlanFromCandidateStream(
            sourceURL: url,
            initialStreamURL: url,
            initialHeaders: headers,
            hintedFormat: nil,
            hintedMIME: nil,
            probe: probe,
            host: host,
            preferredFilename: preferredFilename,
            session: probeSession
        )
    }

    // MARK: - Webpage Resolution (Cleanroom WebKit First, Optional Python Plugin)

    private func resolveWebpage(
        url: URL,
        host: String,
        preferredFilename: String?,
        isPrivate: Bool,
        rangeEngine effectiveRangeEngine: RangeTransferEngine,
        probeSession: URLSession
    ) async throws -> ResolvedTransferPlan {
        if !isPrivate {
            if EmbeddedPythonBridge.shared.isAvailable {
                if let plan = try? await EmbeddedPythonBridge.shared.extractTransferPlan(url: url) {
                    return plan
                }
            }

            if let sniffed = await CleanroomWebKitSession.autoSniffFirstStream(webpageURL: url) {
                if sniffed.format == .dash || sniffed.streamURL.pathExtension.lowercased() == "mpd" {
                    throw Self.unsupportedDASHError(host: host)
                }
                let fallbackStem = Self.cleanTentativeStem(from: sniffed.pageTitle)
                if sniffed.format == .hls {
                    return Self.makeHLSPlan(
                        sourceURL: url,
                        manifestURL: sniffed.streamURL,
                        host: host,
                        headers: sniffed.headers,
                        preferredFilename: preferredFilename ?? fallbackStem
                    )
                }
                let probe = try? await effectiveRangeEngine.probe(url: sniffed.streamURL, headers: sniffed.headers)
                return try await Self.buildPlanFromCandidateStream(
                    sourceURL: url,
                    initialStreamURL: sniffed.streamURL,
                    initialHeaders: sniffed.headers,
                    hintedFormat: sniffed.format,
                    hintedMIME: sniffed.mimeType,
                    probe: probe,
                    host: host,
                    preferredFilename: preferredFilename,
                    fallbackStem: fallbackStem,
                    session: probeSession
                )
            }
        }

        throw NSError(
            domain: "Dysprosium.ControlPlane",
            code: -404,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Interactive challenge or click-to-play required on \(host). Open the page in the Browser tab to capture the stream."
            ]
        )
    }

    /// Unified post-probe plan builder shared by direct URL resolution and webpage auto-sniff so
    /// DASH rejection, cross-origin credential stripping, disguised `#EXTM3U` promotion, and true
    /// container extensions apply identically across every Control Plane entry point.
    static func buildPlanFromCandidateStream(
        sourceURL: URL,
        initialStreamURL: URL,
        initialHeaders: [String: String],
        hintedFormat: SniffedStreamCandidate.StreamFormat?,
        hintedMIME: String?,
        probe: RangeProbeResult?,
        host: String,
        preferredFilename: String?,
        fallbackStem: String? = nil,
        session: URLSession
    ) async throws -> ResolvedTransferPlan {
        let finalURL = probe?.finalURL ?? initialStreamURL
        let effectiveHeaders = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
            from: initialHeaders,
            sourceURL: initialStreamURL,
            destinationURL: finalURL
        )
        let mime = (probe?.mimeType ?? hintedMIME ?? "").lowercased()
        let initialExt = initialStreamURL.pathExtension.lowercased()
        let finalExt = finalURL.pathExtension.lowercased()

        if hintedFormat == .dash || mime.contains("dash+xml") || initialExt == "mpd" || finalExt == "mpd" {
            throw unsupportedDASHError(host: host)
        }

        if hintedFormat == .hls || mime.contains("mpegurl") || MediaURLClassifier.isExplicitHLSURL(finalURL) {
            return makeHLSPlan(
                sourceURL: sourceURL,
                manifestURL: finalURL,
                host: host,
                headers: effectiveHeaders,
                preferredFilename: preferredFilename ?? fallbackStem
            )
        }

        // Detect disguised HLS manifests (`master.txt`, `text/plain` starting with `#EXTM3U`)
        if mime.contains("text/plain") || initialExt == "txt" || finalExt == "txt" || finalURL.absoluteString.lowercased().contains("master.txt") {
            if await startsWithEXTM3U(url: finalURL, headers: effectiveHeaders, session: session) {
                return makeHLSPlan(
                    sourceURL: sourceURL,
                    manifestURL: finalURL,
                    host: host,
                    headers: effectiveHeaders,
                    preferredFilename: preferredFilename ?? fallbackStem
                )
            }
        }

        let hasConfirmedMediaMIME = mime.hasPrefix("video/") || mime.hasPrefix("audio/")
        let resolvedUserPreferred = preferredFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitUserPreferred = (resolvedUserPreferred?.isEmpty == false) ? resolvedUserPreferred : nil
        let mediaExt: String? = (hasConfirmedMediaMIME || hintedFormat != nil)
            ? MediaURLClassifier.preferredFileExtension(
                url: finalURL,
                format: hintedFormat ?? .mp4,
                mimeType: probe?.mimeType ?? hintedMIME
            )
            : nil

        let outputFilename: String
        let finalExtToken: String

        if let userName = explicitUserPreferred {
            let safeUser = userName.replacingOccurrences(of: "/", with: "_")
            let userExt = (safeUser as NSString).pathExtension.lowercased()
            if !userExt.isEmpty {
                outputFilename = safeUser
                finalExtToken = userExt
            } else {
                finalExtToken = mediaExt ?? "bin"
                outputFilename = "\(safeUser).\(finalExtToken)"
            }
        } else {
            let serverName = resolveFilename(preferred: nil, suggested: probe?.suggestedFilename, finalURL: finalURL)
            let serverExt = (serverName as NSString).pathExtension.lowercased()
            let knownMediaExtensions: Set<String> = ["mp4", "m4v", "webm", "mkv", "mov", "ogg", "mp3", "m4a", "aac", "flac", "wav"]
            if !hasConfirmedMediaMIME && hintedFormat == nil {
                // Ordinary non-media file (e.g. `firmware.bin`, `archive.zip`): preserve server filename & extension verbatim.
                if !serverExt.isEmpty {
                    outputFilename = serverName
                    finalExtToken = serverExt
                } else {
                    finalExtToken = "bin"
                    outputFilename = "\(serverName).bin"
                }
            } else if hasConfirmedMediaMIME, let confirmedExt = mediaExt {
                // Confirmed media MIME (`video/webm`, `audio/mpeg`, etc.): replace missing or generic placeholder extension,
                // preferring webpage stem when the CDN URL itself is an extensionless/opaque token.
                let stem: String = {
                    if let fallbackStem, !fallbackStem.isEmpty, (serverExt.isEmpty || !knownMediaExtensions.contains(serverExt)) {
                        return fallbackStem
                    }
                    let stripped = (serverName as NSString).deletingPathExtension
                    return stripped.isEmpty ? (fallbackStem ?? "media") : stripped
                }()
                finalExtToken = confirmedExt
                outputFilename = "\(stem).\(confirmedExt)"
            } else {
                // Hinted media stream without a confirmed video/audio Content-Type response.
                let ext = !serverExt.isEmpty ? serverExt : (mediaExt ?? "mp4")
                let stem: String = {
                    if let fallbackStem, !fallbackStem.isEmpty, serverExt.isEmpty {
                        return fallbackStem
                    }
                    let stripped = (serverName as NSString).deletingPathExtension
                    return stripped.isEmpty ? (fallbackStem ?? "media") : stripped
                }()
                finalExtToken = ext
                outputFilename = "\(stem).\(ext)"
            }
        }

        let track = ResolvedTrackDescriptor(
            role: .primary,
            remoteURL: finalURL,
            headers: effectiveHeaders,
            expectedBytes: probe?.totalBytes,
            supportsByteRanges: probe?.supportsByteRanges ?? true,
            isHLSManifest: false,
            fileExtension: finalExtToken
        )

        return ResolvedTransferPlan(
            sourceURL: sourceURL,
            title: outputFilename,
            siteDomain: host,
            kind: .directRange,
            tracks: [track],
            outputFilename: outputFilename,
            requiresMuxing: false,
            etag: probe?.etag,
            lastModified: probe?.lastModified
        )
    }

    private static func cleanTentativeStem(from rawTitle: String?) -> String? {
        guard let rawTitle else { return nil }
        let sanitized = rawTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        guard !sanitized.isEmpty else { return nil }
        return sanitized
    }

    private static func unsupportedDASHError(host: String) -> NSError {
        NSError(
            domain: "Dysprosium.ControlPlane",
            code: -415,
            userInfo: [
                NSLocalizedDescriptionKey: "MPEG-DASH (.mpd) downloads are not yet supported on \(host)."
            ]
        )
    }

    private static func makeHLSPlan(
        sourceURL: URL,
        manifestURL: URL,
        host: String,
        headers: [String: String],
        preferredFilename: String?
    ) -> ResolvedTransferPlan {
        let rawBase = preferredFilename ?? cleanStem(from: manifestURL, fallback: "stream")
        let mp4Name: String = {
            let ns = rawBase as NSString
            let ext = ns.pathExtension.lowercased()
            if ext == "mp4" { return rawBase }
            if ext == "ts" || ext == "m3u8" || ext == "txt" || ext == "tar" {
                return "\(ns.deletingPathExtension).mp4"
            }
            return "\(rawBase).mp4"
        }()

        let track = ResolvedTrackDescriptor(
            role: .primary,
            remoteURL: manifestURL,
            headers: headers,
            expectedBytes: nil,
            supportsByteRanges: false,
            isHLSManifest: true,
            fileExtension: "ts"
        )
        return ResolvedTransferPlan(
            sourceURL: sourceURL,
            title: mp4Name,
            siteDomain: host,
            kind: .hlsStream,
            tracks: [track],
            outputFilename: mp4Name
        )
    }

    private static func startsWithEXTM3U(
        url: URL,
        headers: [String: String],
        session: URLSession
    ) async -> Bool {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=0-63", forHTTPHeaderField: "Range")
        req.timeoutInterval = 8
        guard let (asyncBytes, _) = try? await session.bytes(
            for: req,
            delegate: CrossOriginRedirectAuthStripper.shared
        ) else {
            return false
        }
        defer { asyncBytes.task.cancel() }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        do {
            for try await b in asyncBytes {
                bytes.append(b)
                if bytes.count >= 32 { break }
            }
        } catch {
            if bytes.isEmpty { return false }
        }
        guard let prefix = String(bytes: bytes, encoding: .utf8) else { return false }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }

    private static func cleanStem(from url: URL, fallback: String) -> String {
        let last = url.deletingPathExtension().lastPathComponent
        return last.isEmpty ? fallback : last
    }

    private static func resolveFilename(preferred: String?, suggested: String?, finalURL: URL) -> String {
        for candidate in [preferred, suggested, finalURL.lastPathComponent] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text != "/" {
                return text.replacingOccurrences(of: "/", with: "_")
            }
        }
        return "download-\(Int(Date().timeIntervalSince1970)).bin"
    }
}
