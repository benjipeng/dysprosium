import CommonCrypto
import Foundation

public struct HLSProgressUpdate: Sendable {
    public let completedSegments: Int
    public let totalSegments: Int
    public let downloadedBytes: Int64
    public let activeLanes: Int
}

/// 2026-grade native HLS (`.m3u8`) stream engine with:
/// - Master variant selection (`BANDWIDTH` + `RESOLUTION` tie-breaking)
/// - `#EXT-X-MAP` fMP4 initialization box & `#EXT-X-BYTERANGE` RFC 8216 support
/// - Hardware-accelerated `#EXT-X-KEY:METHOD=AES-128` decryption via `CommonCrypto`
/// - Anti-poisoning payload sanitizer (strips fake PNG/JPEG/BMP headers disguised on `.jpg`/`.png` segments)
/// - `#EXT-X-DISCONTINUITY` anomalous ad-pod filtering
/// - AIMD (Additive Increase / Multiplicative Decrease) adaptive concurrency & jittered per-segment retry
public struct HLSStreamEngine: Sendable {
    public struct ByteRangeSpec: Sendable, Equatable {
        public let offset: Int64
        public let length: Int64

        public var headerValue: String {
            "bytes=\(offset)-\(offset + length - 1)"
        }
    }

    public struct SegmentItem: Sendable {
        public let sequenceIndex: Int
        public let url: URL
        public let keyURL: URL?
        public let explicitIV: Data?
        public let mediaSequence: UInt64
        public let durationSeconds: Double
        public let byteRange: ByteRangeSpec?
        public let discontinuityGroup: Int
    }

    public struct ParsedMediaPlaylist: Sendable {
        public let resolvedPlaylistURL: URL
        public let initializationMapURL: URL?
        public let initializationByteRange: ByteRangeSpec?
        public let segments: [SegmentItem]
        public let strippedAdSegmentsCount: Int

        public var isFragmentedMP4: Bool {
            initializationMapURL != nil
        }
    }

    public static let iosSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 27_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"

    public static let macosSafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15"

    public static var safariUserAgent: String {
        LiveContainerEnvironment.sharedDefaults.string(forKey: "dysprosium.browser.userAgentProfile") == "macosSafari"
            ? macosSafariUserAgent
            : iosSafariUserAgent
    }

    private let customSession: URLSession?

    public init(session: URLSession? = nil) {
        self.customSession = session
    }

    private func resolveSessionLease(for url: URL) -> SystemProxyBridge.SessionLease {
        if let customSession {
            return SystemProxyBridge.SessionLease(session: customSession)
        }
        return SystemProxyBridge.acquireSessionLease(for: .hlsStream, targetURL: url)
    }

    public func downloadPlaylist(
        manifestURL: URL,
        headers: [String: String] = [:],
        destinationURL: URL,
        concurrency: Int = 8,
        preloadedManifestText: String? = nil,
        onProgress: @escaping @Sendable (HLSProgressUpdate) -> Void
    ) async throws -> HLSProgressUpdate {
        let lease = resolveSessionLease(for: manifestURL)
        defer { lease.release() }
        let activeSession = lease.session
        let effectiveHeaders = Self.normalizedBrowserHeaders(headers, manifestURL: manifestURL)
        let playlist = try await resolveMediaPlaylist(
            from: manifestURL,
            headers: effectiveHeaders,
            preloadedManifestText: preloadedManifestText,
            session: activeSession
        )
        guard !playlist.segments.isEmpty else {
            throw NSError(
                domain: "Dysprosium.HLS",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L("HLS playlist contained zero playable media segments")]
            )
        }

        // Preserve final post-redirect playlist origin & re-scope headers before fetching init map, keys, and segments.
        let playlistOriginURL = playlist.resolvedPlaylistURL
        let playlistHeaders = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
            from: effectiveHeaders,
            sourceURL: manifestURL,
            destinationURL: playlistOriginURL
        )

        let writer = try PreallocatedFileWriter(fileURL: destinationURL, preallocateBytes: nil, truncateExisting: true)
        defer { try? writer.close() }

        var writeCursor: Int64 = 0
        if let initMapURL = playlist.initializationMapURL {
            let initHeaders = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
                from: playlistHeaders,
                sourceURL: playlistOriginURL,
                destinationURL: initMapURL
            )
            let initBytes = try await fetchWithRetry(
                url: initMapURL,
                headers: initHeaders,
                session: activeSession,
                byteRange: playlist.initializationByteRange,
                aimd: nil,
                maxAttempts: 3,
                requestTimeout: 15
            )
            try writer.write(initBytes, at: writeCursor)
            writeCursor += Int64(initBytes.count)
        }

        let keyCache = AESKeyCache(session: activeSession, manifestOriginURL: playlistOriginURL, headers: playlistHeaders)
        let totalCount = playlist.segments.count
        let ceiling = max(1, min(concurrency, 20))
        let initialWindow = ceiling <= 4 ? ceiling : min(6, ceiling)
        let aimd = AIMDConcurrencyGate(initialLimit: initialWindow, maxLimit: ceiling)
        let isFMP4 = playlist.isFragmentedMP4

        var nextToSchedule = 0
        var nextToWrite = 0
        var inFlight = 0
        var completedCount = 0
        var pendingBuffer: [Int: Data] = [:]
        var pendingBufferBytes = 0
        let maxPendingBufferBytes = 32 * 1024 * 1024
        var lastProgressEmit = ContinuousClock.now - .seconds(1)

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            let startBudget = await aimd.currentLimit
            while nextToSchedule < min(startBudget, totalCount) {
                let seg = playlist.segments[nextToSchedule]
                nextToSchedule += 1
                inFlight += 1
                group.addTask {
                    let payload = try await fetchDecryptAndSanitizeSegment(
                        seg,
                        manifestOriginURL: playlistOriginURL,
                        headers: playlistHeaders,
                        session: activeSession,
                        isFragmentedMP4: isFMP4,
                        keyCache: keyCache,
                        aimd: aimd
                    )
                    return (seg.sequenceIndex, payload)
                }
            }

            // Signal manifest resolution immediately so TransferScheduler transitions `.resolving -> .downloading`
            // with accurate segment totals and live worker count before the first segment finishes.
            onProgress(HLSProgressUpdate(
                completedSegments: 0,
                totalSegments: totalCount,
                downloadedBytes: writeCursor,
                activeLanes: inFlight
            ))

            while let (seqIdx, segmentBytes) = try await group.next() {
                inFlight -= 1
                completedCount += 1
                pendingBuffer[seqIdx] = segmentBytes
                pendingBufferBytes += segmentBytes.count

                while let readyData = pendingBuffer.removeValue(forKey: nextToWrite) {
                    pendingBufferBytes = max(0, pendingBufferBytes - readyData.count)
                    try writer.write(readyData, at: writeCursor)
                    writeCursor += Int64(readyData.count)
                    nextToWrite += 1
                }

                let targetWindow = await aimd.currentLimit
                while nextToSchedule < totalCount,
                      inFlight < targetWindow,
                      pendingBuffer.count < max(8, targetWindow * 2),
                      (pendingBufferBytes < maxPendingBufferBytes || inFlight == 0) {
                    let seg = playlist.segments[nextToSchedule]
                    nextToSchedule += 1
                    inFlight += 1
                    group.addTask {
                        let payload = try await fetchDecryptAndSanitizeSegment(
                            seg,
                            manifestOriginURL: playlistOriginURL,
                            headers: playlistHeaders,
                            session: activeSession,
                            isFragmentedMP4: isFMP4,
                            keyCache: keyCache,
                            aimd: aimd
                        )
                        return (seg.sequenceIndex, payload)
                    }
                }

                let now = ContinuousClock.now
                if now - lastProgressEmit >= .milliseconds(200) || completedCount == totalCount {
                    lastProgressEmit = now
                    onProgress(HLSProgressUpdate(
                        completedSegments: completedCount,
                        totalSegments: totalCount,
                        downloadedBytes: writeCursor,
                        activeLanes: inFlight
                    ))
                }
            }
        }

        try writer.synchronize()
        let finalUpdate = HLSProgressUpdate(
            completedSegments: totalCount,
            totalSegments: totalCount,
            downloadedBytes: writeCursor,
            activeLanes: 0
        )
        onProgress(finalUpdate)
        return finalUpdate
    }

    // MARK: - Playlist Resolution, Discontinuity Ad Filtering & Parsing

    public func resolveMediaPlaylist(
        from url: URL,
        headers: [String: String],
        preloadedManifestText: String? = nil
    ) async throws -> ParsedMediaPlaylist {
        let lease = resolveSessionLease(for: url)
        defer { lease.release() }
        return try await resolveMediaPlaylist(
            from: url,
            headers: headers,
            preloadedManifestText: preloadedManifestText,
            session: lease.session
        )
    }

    private func resolveMediaPlaylist(
        from url: URL,
        headers: [String: String],
        preloadedManifestText: String? = nil,
        session: URLSession
    ) async throws -> ParsedMediaPlaylist {
        let initialHeaders = Self.normalizedBrowserHeaders(headers, manifestURL: url)
        let text: String
        let resolvedURL: URL
        if let preloaded = preloadedManifestText?.trimmingCharacters(in: .whitespacesAndNewlines),
           preloaded.hasPrefix("#EXTM3U") {
            text = preloaded
            resolvedURL = url
        } else {
            // Manifests are tiny text files: fail fast (2 attempts × 12 s) instead of hanging 150 s on a dead CDN.
            let fetched = try await fetchWithRetryWithFinalURL(
                url: url,
                headers: initialHeaders,
                session: session,
                byteRange: nil,
                aimd: nil,
                maxAttempts: 2,
                requestTimeout: 12
            )
            guard let decoded = String(data: fetched.data, encoding: .utf8) ?? String(data: fetched.data, encoding: .isoLatin1) else {
                throw URLError(.cannotDecodeContentData)
            }
            text = decoded
            resolvedURL = fetched.finalURL
        }

        let effectiveHeaders = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
            from: initialHeaders,
            sourceURL: url,
            destinationURL: resolvedURL
        )

        if let bestVariantURL = Self.selectHighestBandwidthVariant(manifestText: text, baseURL: resolvedURL) {
            let subHeaders = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
                from: effectiveHeaders,
                sourceURL: resolvedURL,
                destinationURL: bestVariantURL
            )
            let subFetched = try await fetchWithRetryWithFinalURL(
                url: bestVariantURL,
                headers: subHeaders,
                session: session,
                byteRange: nil,
                aimd: nil,
                maxAttempts: 2,
                requestTimeout: 12
            )
            guard let subText = String(data: subFetched.data, encoding: .utf8) ?? String(data: subFetched.data, encoding: .isoLatin1) else {
                throw URLError(.cannotDecodeContentData)
            }
            return Self.parseMediaPlaylist(manifestText: subText, baseURL: subFetched.finalURL)
        }

        return Self.parseMediaPlaylist(manifestText: text, baseURL: resolvedURL)
    }

    static func selectHighestBandwidthVariant(manifestText: String, baseURL: URL) -> URL? {
        guard manifestText.contains("#EXT-X-STREAM-INF:") else { return nil }
        let lines = manifestText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var bestScore: Int64 = -1
        var bestURL: URL?

        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                let bw = Int64(attrs["BANDWIDTH"] ?? attrs["AVERAGE-BANDWIDTH"] ?? "0") ?? 0
                let resBonus: Int64 = {
                    guard let res = attrs["RESOLUTION"] else { return 0 }
                    let parts = res.lowercased().split(separator: "x")
                    if parts.count == 2, let w = Int64(parts[0]), let h = Int64(parts[1]) {
                        return w * h
                    }
                    return 0
                }()
                let score = bw > 0 ? bw : resBonus

                var nextIdx = idx + 1
                while nextIdx < lines.count, (lines[nextIdx].isEmpty || lines[nextIdx].hasPrefix("#")) {
                    nextIdx += 1
                }
                if nextIdx < lines.count, let candidate = resolveURL(lines[nextIdx], relativeTo: baseURL) {
                    if score >= bestScore {
                        bestScore = score
                        bestURL = candidate
                    }
                }
                idx = nextIdx + 1
            } else {
                idx += 1
            }
        }
        return bestURL
    }

    static func parseMediaPlaylist(manifestText: String, baseURL: URL) -> ParsedMediaPlaylist {
        let lines = manifestText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var initMapURL: URL?
        var initByteRange: ByteRangeSpec?
        var currentKeyURL: URL?
        var currentExplicitIV: Data?
        var mediaSequenceBase: UInt64 = 0
        var discontinuityGroup = 0
        var pendingDuration: Double = 4.0
        var pendingByteRange: ByteRangeSpec?
        var lastByteRangeEndByURL: [URL: Int64] = [:]
        var rawSegments: [SegmentItem] = []

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let val = line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)
                mediaSequenceBase = UInt64(val) ?? 0
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") {
                discontinuityGroup += 1
            } else if line.hasPrefix("#EXTINF:") {
                let body = line.dropFirst("#EXTINF:".count)
                let durToken = body.split(separator: ",").first.map(String.init) ?? ""
                pendingDuration = Double(durToken.trimmingCharacters(in: .whitespaces)) ?? 4.0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let specStr = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                pendingByteRange = parseByteRange(specStr, fallbackOffset: 0)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = attrs["URI"], let resolved = resolveURL(uri, relativeTo: baseURL) {
                    initMapURL = resolved
                    if let br = attrs["BYTERANGE"] {
                        initByteRange = parseByteRange(br, fallbackOffset: 0)
                    }
                }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = (attrs["METHOD"] ?? "NONE").uppercased()
                if method == "AES-128", let uri = attrs["URI"], let resolved = resolveURL(uri, relativeTo: baseURL) {
                    currentKeyURL = resolved
                    currentExplicitIV = attrs["IV"].flatMap(parseHexIV)
                } else {
                    currentKeyURL = nil
                    currentExplicitIV = nil
                }
            } else if !line.hasPrefix("#") {
                if let segURL = resolveURL(line, relativeTo: baseURL) {
                    var finalRange = pendingByteRange
                    if let pr = pendingByteRange {
                        if pr.offset < 0 {
                            let inferredOffset = lastByteRangeEndByURL[segURL] ?? 0
                            finalRange = ByteRangeSpec(offset: inferredOffset, length: pr.length)
                            lastByteRangeEndByURL[segURL] = inferredOffset + pr.length
                        } else {
                            lastByteRangeEndByURL[segURL] = pr.offset + pr.length
                        }
                    }
                    let rawIdx = rawSegments.count
                    rawSegments.append(SegmentItem(
                        sequenceIndex: rawIdx,
                        url: segURL,
                        keyURL: currentKeyURL,
                        explicitIV: currentExplicitIV,
                        mediaSequence: mediaSequenceBase + UInt64(rawIdx),
                        durationSeconds: pendingDuration,
                        byteRange: finalRange,
                        discontinuityGroup: discontinuityGroup
                    ))
                    pendingByteRange = nil
                    pendingDuration = 4.0
                }
            }
        }

        let (cleanSegments, strippedCount) = filterInjectedAdDiscontinuities(rawSegments)
        return ParsedMediaPlaylist(
            resolvedPlaylistURL: baseURL,
            initializationMapURL: initMapURL,
            initializationByteRange: initByteRange,
            segments: cleanSegments,
            strippedAdSegmentsCount: strippedCount
        )
    }

    /// Detects and removes anomalous injected `#EXT-X-DISCONTINUITY` ad pods whose CDN origin/directory
    /// diverges from the dominant program stream while preserving legitimate multi-part program segments.
    static func filterInjectedAdDiscontinuities(_ segments: [SegmentItem]) -> ([SegmentItem], Int) {
        guard segments.count >= 6 else { return (segments, 0) }
        let groups = Dictionary(grouping: segments, by: \.discontinuityGroup)
        guard groups.count > 1 else { return (segments, 0) }

        func originSignature(for url: URL) -> String {
            let host = (url.host() ?? "").lowercased()
            let dir = url.deletingLastPathComponent().path.lowercased()
            return "\(host)\(dir)"
        }

        // Accumulate total duration per origin+directory signature
        var durationBySignature: [String: Double] = [:]
        for seg in segments {
            durationBySignature[originSignature(for: seg.url), default: 0] += max(0.5, seg.durationSeconds)
        }
        guard let dominantSignature = durationBySignature.max(by: { $0.value < $1.value })?.key else {
            return (segments, 0)
        }

        var kept: [SegmentItem] = []
        kept.reserveCapacity(segments.count)
        var stripped = 0

        for groupID in groups.keys.sorted() {
            guard let cluster = groups[groupID], let first = cluster.first else { continue }
            let sig = originSignature(for: first.url)
            let clusterDuration = cluster.reduce(0.0) { $0 + $1.durationSeconds }
            let isMinority = cluster.count <= 18 && clusterDuration < 65.0 && Double(cluster.count) < Double(segments.count) * 0.30

            if sig != dominantSignature && isMinority {
                stripped += cluster.count
                continue
            }
            for item in cluster {
                kept.append(SegmentItem(
                    sequenceIndex: kept.count,
                    url: item.url,
                    keyURL: item.keyURL,
                    explicitIV: item.explicitIV,
                    mediaSequence: item.mediaSequence,
                    durationSeconds: item.durationSeconds,
                    byteRange: item.byteRange,
                    discontinuityGroup: item.discontinuityGroup
                ))
            }
        }

        return kept.isEmpty ? (segments, 0) : (kept, stripped)
    }

    // MARK: - Anti-Poisoning Payload Sanitizer (Fake PNG/JPEG/BMP Header Stripping)

    /// Some HLS origins and image-CDN relays disguise MPEG-TS segments
    /// with `.jpg`/`.png`/`.ico` extensions and prepend fake image headers before the real `0x47` TS packets.
    /// Scans for three consecutive `188-byte` `0x47` sync markers (`p < 6e-8` false-positive rate) and strips garbage.
    public static func sanitizeMPEGTSPayload(_ data: Data) -> Data {
        let count = data.count
        guard count >= 188 else { return data }

        return data.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return data }

            // Fast O(1) path for clean MPEG-TS segments
            if base[0] == 0x47, (count < 376 || (base[188] == 0x47 && base[376] == 0x47)) {
                return data
            }

            let maxScan = min(count - 376, 32_768)
            if maxScan >= 0 {
                var offset = 1
                while offset <= maxScan {
                    if base[offset] == 0x47,
                       base[offset + 188] == 0x47,
                       base[offset + 376] == 0x47 {
                        return data.subdata(in: offset..<count)
                    }
                    offset += 1
                }
            }
            return data
        }
    }

    // MARK: - Segment Fetch, AIMD Retry & AES-128-CBC Decryption

    private func fetchDecryptAndSanitizeSegment(
        _ segment: SegmentItem,
        manifestOriginURL: URL,
        headers: [String: String],
        session: URLSession,
        isFragmentedMP4: Bool,
        keyCache: AESKeyCache,
        aimd: AIMDConcurrencyGate
    ) async throws -> Data {
        let segHeaders = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
            from: headers,
            sourceURL: manifestOriginURL,
            destinationURL: segment.url
        )
        let rawBytes = try await fetchWithRetry(
            url: segment.url,
            headers: segHeaders,
            session: session,
            byteRange: segment.byteRange,
            aimd: aimd
        )

        let decrypted: Data
        if let keyURL = segment.keyURL {
            let keyData = try await keyCache.key(for: keyURL)
            let ivData: Data
            if let explicit = segment.explicitIV, explicit.count == kCCBlockSizeAES128 {
                ivData = explicit
            } else {
                var bigEndianSeq = segment.mediaSequence.bigEndian
                var synthesized = Data(repeating: 0, count: 8)
                withUnsafeBytes(of: &bigEndianSeq) { synthesized.append(contentsOf: $0) }
                ivData = synthesized
            }
            decrypted = try Self.decryptAES128CBC(ciphertext: rawBytes, key: keyData, iv: ivData)
        } else {
            decrypted = rawBytes
        }

        return isFragmentedMP4 ? decrypted : Self.sanitizeMPEGTSPayload(decrypted)
    }

    private struct NonRetryableHLSError: Error {
        let underlying: Error
    }

    private static func isFatalTransportError(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed, .unsupportedURL, .badURL,
             .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected:
            return true
        default:
            return false
        }
    }

    private struct FetchedPayload {
        let data: Data
        let finalURL: URL
    }

    private func fetchWithRetry(
        url: URL,
        headers: [String: String],
        session: URLSession,
        byteRange: ByteRangeSpec?,
        aimd: AIMDConcurrencyGate?,
        maxAttempts: Int = 5,
        requestTimeout: TimeInterval = 30
    ) async throws -> Data {
        try await fetchWithRetryWithFinalURL(
            url: url,
            headers: headers,
            session: session,
            byteRange: byteRange,
            aimd: aimd,
            maxAttempts: maxAttempts,
            requestTimeout: requestTimeout
        ).data
    }

    private func fetchWithRetryWithFinalURL(
        url: URL,
        headers: [String: String],
        session: URLSession,
        byteRange: ByteRangeSpec?,
        aimd: AIMDConcurrencyGate?,
        maxAttempts: Int = 5,
        requestTimeout: TimeInterval = 30
    ) async throws -> FetchedPayload {
        let attempts = max(1, maxAttempts)
        var lastError: Error = URLError(.badServerResponse)

        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = requestTimeout
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                if let byteRange {
                    req.setValue(byteRange.headerValue, forHTTPHeaderField: "Range")
                }

                let (data, response) = try await session.data(for: req, delegate: CrossOriginRedirectAuthStripper.shared)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                if (200...299).contains(http.statusCode) {
                    if let aimd { await aimd.recordSuccess() }
                    return FetchedPayload(data: data, finalURL: http.url ?? url)
                }

                if http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode) {
                    if let aimd { await aimd.recordCongestion() }
                    let retryAfterSec = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    let backoffMs = Int((retryAfterSec ?? (0.35 * pow(2.0, Double(attempt)))) * 1000.0) + Int.random(in: 40...260)
                    if attempt + 1 < attempts {
                        try await Task.sleep(for: .milliseconds(min(backoffMs, 8_000)))
                    }
                    lastError = NSError(
                        domain: "Dysprosium.HLS",
                        code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: L("HTTP \(http.statusCode) while fetching \(url.lastPathComponent)")]
                    )
                    continue
                }

                // Permanent HTTP 4xx (403 Forbidden, 404 Not Found, 410 Gone, etc.) must fail immediately.
                throw NonRetryableHLSError(underlying: NSError(
                    domain: "Dysprosium.HLS",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) while fetching \(url.lastPathComponent)"]
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                throw urlErr
            } catch let urlErr as URLError where Self.isFatalTransportError(urlErr) {
                throw urlErr
            } catch let fatal as NonRetryableHLSError {
                throw fatal.underlying
            } catch {
                lastError = error
                if attempt + 1 < attempts {
                    if let aimd { await aimd.recordCongestion() }
                    let backoffMs = Int(300.0 * pow(2.0, Double(attempt))) + Int.random(in: 50...250)
                    try await Task.sleep(for: .milliseconds(min(backoffMs, 6_000)))
                }
            }
        }
        throw lastError
    }

    // MARK: - Helpers & Crypto

    static func normalizedBrowserHeaders(_ incoming: [String: String], manifestURL: URL) -> [String: String] {
        var merged = incoming
        let keysLower = Set(incoming.keys.map { $0.lowercased() })

        if !keysLower.contains("user-agent") {
            merged["User-Agent"] = safariUserAgent
        }
        if !keysLower.contains("accept") {
            merged["Accept"] = "*/*"
        }
        if !keysLower.contains("accept-language") {
            merged["Accept-Language"] = "en-US,en;q=0.9"
        }
        if !keysLower.contains("referer"), let scheme = manifestURL.scheme, let host = manifestURL.host() {
            merged["Referer"] = "\(scheme)://\(host)/"
        }
        // Real browsers omit `Origin` on same-origin GET requests; strip it if it matches the target origin.
        if let targetScheme = manifestURL.scheme?.lowercased(),
           let targetHost = manifestURL.host()?.lowercased() {
            let targetOrigin = manifestURL.port.map { "\(targetScheme)://\(targetHost):\($0)" } ?? "\(targetScheme)://\(targetHost)"
            for key in Array(merged.keys) where key.lowercased() == "origin" {
                if merged[key]?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased() == targetOrigin {
                    merged.removeValue(forKey: key)
                }
            }
        }
        return merged
    }

    private static func resolveURL(_ rawURI: String, relativeTo baseURL: URL) -> URL? {
        let trimmed = rawURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
            return direct
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: encoded, relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    private static func parseByteRange(_ raw: String, fallbackOffset: Int64) -> ByteRangeSpec? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let parts = cleaned.split(separator: "@")
        guard let len = parts.first.flatMap({ Int64($0) }), len > 0 else { return nil }
        if parts.count == 2, let explicitOff = Int64(parts[1]) {
            return ByteRangeSpec(offset: explicitOff, length: len)
        }
        return ByteRangeSpec(offset: -1, length: len)
    }

    private static func parseAttributeList(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inQuotes = false
        var readingValue = false

        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "=", !inQuotes, !readingValue {
                readingValue = true
            } else if ch == ",", !inQuotes {
                let k = key.trimmingCharacters(in: .whitespaces)
                if !k.isEmpty { result[k] = value.trimmingCharacters(in: .whitespaces) }
                key = ""
                value = ""
                readingValue = false
            } else if readingValue {
                value.append(ch)
            } else {
                key.append(ch)
            }
        }
        let k = key.trimmingCharacters(in: .whitespaces)
        if !k.isEmpty { result[k] = value.trimmingCharacters(in: .whitespaces) }
        return result
    }

    private static func parseHexIV(_ raw: String) -> Data? {
        var hex = raw.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        if hex.count < 32 {
            hex = String(repeating: "0", count: 32 - hex.count) + hex
        }
        var bytes = Data()
        bytes.reserveCapacity(16)
        var index = hex.startIndex
        for _ in 0..<16 {
            guard index < hex.endIndex else { return nil }
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    static func decryptAES128CBC(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw NSError(domain: "Dysprosium.Crypto", code: kCCParamError, userInfo: nil)
        }
        let capacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var movedBytes: size_t = 0

        let status = output.withUnsafeMutableBytes { outBuf in
            ciphertext.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, ciphertext.count,
                            outBuf.baseAddress, capacity,
                            &movedBytes
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw NSError(domain: "Dysprosium.Crypto", code: Int(status), userInfo: nil)
        }
        output.count = movedBytes
        return output
    }
}

/// BBR/TCP-inspired Additive-Increase / Multiplicative-Decrease concurrency window controller.
private actor AIMDConcurrencyGate {
    private(set) var currentLimit: Int
    private let maxLimit: Int
    private var consecutiveCleanCount: Int = 0

    init(initialLimit: Int, maxLimit: Int) {
        self.currentLimit = max(1, min(initialLimit, maxLimit))
        self.maxLimit = max(1, maxLimit)
    }

    func recordSuccess() {
        consecutiveCleanCount += 1
        if consecutiveCleanCount >= 6, currentLimit < maxLimit {
            currentLimit += 1
            consecutiveCleanCount = 0
        }
    }

    func recordCongestion() {
        consecutiveCleanCount = 0
        currentLimit = max(2, currentLimit / 2)
    }
}

private actor AESKeyCache {
    private let session: URLSession
    private let manifestOriginURL: URL
    private let headers: [String: String]
    private var cache: [URL: Data] = [:]
    private var inFlight: [URL: Task<Data, Error>] = [:]

    init(session: URLSession, manifestOriginURL: URL, headers: [String: String]) {
        self.session = session
        self.manifestOriginURL = manifestOriginURL
        self.headers = headers
    }

    func key(for url: URL) async throws -> Data {
        if let existing = cache[url] { return existing }
        if let task = inFlight[url] { return try await task.value }
        let s = session
        let h = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
            from: headers,
            sourceURL: manifestOriginURL,
            destinationURL: url
        )
        let task = Task<Data, Error> {
            var req = URLRequest(url: url)
            for (k, v) in h { req.setValue(v, forHTTPHeaderField: k) }
            let (data, resp) = try await s.data(for: req, delegate: CrossOriginRedirectAuthStripper.shared)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        }
        inFlight[url] = task
        do {
            let data = try await task.value
            inFlight.removeValue(forKey: url)
            cache[url] = data
            return data
        } catch {
            inFlight.removeValue(forKey: url)
            throw error
        }
    }
}
