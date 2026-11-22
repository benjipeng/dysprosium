import Foundation

/// Native YouTube & YouTube Shorts `VISIONOS` Innertube resolver (zero Python, full-range HTTP 206).
public extension StreamMetadataProber {
    static let visionOSYouTubeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private actor VisitorDataStore {
        static let shared = VisitorDataStore()
        private var cachedToken: String?
        private var fetchedAt: ContinuousClock.Instant?

        func resolveToken(session: URLSession, userAgent: String) async -> String? {
            if let cachedToken,
               let fetchedAt,
               ContinuousClock.now - fetchedAt < .seconds(1800) {
                return cachedToken
            }
            guard let swURL = URL(string: "https://www.youtube.com/sw.js_data") else {
                return cachedToken
            }
            var req = URLRequest(url: swURL)
            req.timeoutInterval = 8
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else {
                return cachedToken
            }
            if let range = text.range(of: #""(Cgt[A-Za-z0-9_%+=/.-]+)""#, options: .regularExpression) {
                let matched = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !matched.isEmpty {
                    cachedToken = matched
                    fetchedAt = .now
                    return matched
                }
            }
            return cachedToken
        }
    }

    /// Extracts an 11-character YouTube video ID from standard Watch, Shorts, Embed, Live, or `youtu.be` URLs.
    static func extractYouTubeVideoID(from url: URL) -> String? {
        guard let rawHost = url.host() else { return nil }
        let cleanHost = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)

        if cleanHost == "youtu.be" {
            let id = url.pathComponents.dropFirst().first ?? ""
            return isValidYouTubeID(id) ? id : nil
        }

        guard cleanHost == "youtube.com" || cleanHost == "youtube-nocookie.com" else {
            return nil
        }

        let comps = url.pathComponents.filter { $0 != "/" }
        if comps.first == "watch" {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            if let v = q?.first(where: { $0.name == "v" })?.value, isValidYouTubeID(v) {
                return v
            }
        } else if let first = comps.first, ["shorts", "embed", "live", "v"].contains(first), comps.count >= 2 {
            let candidate = comps[1]
            if isValidYouTubeID(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func isValidYouTubeID(_ s: String) -> Bool {
        guard s.count == 11 else { return false }
        return s.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }

    /// Queries YouTube's `VISIONOS` Innertube `/youtubei/v1/player` endpoint paired with `/sw.js_data` `visitorData`
    /// to obtain unthrottled full-range `HTTP 206` H.264 (`avc1`) + AAC (`mp4a`) stream pairs (free of the 60-second
    /// GVS PO-Token 403 cutoff enforced on `IOS`/`ANDROID`/`ANDROID_VR`), plus muxed `hlsManifestUrl` for instant `Play`.
    static func resolveYouTubeVideoGroup(
        videoID: String,
        defaultSelected: Bool = true
    ) async -> DiscoveredMediaGroup? {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            return nil
        }

        let lease = SystemProxyBridge.acquireSessionLease(for: .streamProber, targetURL: endpoint)
        defer { lease.release() }
        let session = lease.session

        let visitorData = await VisitorDataStore.shared.resolveToken(
            session: session,
            userAgent: visionOSYouTubeUserAgent
        )

        var clientContext: [String: Any] = [
            "clientName": "VISIONOS",
            "clientVersion": "0.1",
            "deviceMake": "Apple",
            "deviceModel": "RealityDevice14,1",
            "osName": "visionOS",
            "osVersion": "1.3.21O771",
            "hl": "en",
            "gl": "US"
        ]
        if let visitorData, !visitorData.isEmpty {
            clientContext["visitorData"] = visitorData
        }

        let payload: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": clientContext
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(visionOSYouTubeUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("101", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue("0.1", forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")

        guard let (respData, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            return nil
        }

        let videoDetails = root["videoDetails"] as? [String: Any]
        let rawTitle = (videoDetails?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "YouTube \(videoID)"
        let durationSec = (videoDetails?["lengthSeconds"] as? String).flatMap(Double.init)

        // Fetch highest-resolution cover thumbnail concurrently
        let thumbURL: URL? = {
            if let thumbContainer = videoDetails?["thumbnail"] as? [String: Any],
               let thumbs = thumbContainer["thumbnails"] as? [[String: Any]],
               let best = thumbs.last?["url"] as? String {
                return URL(string: best)
            }
            return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
        }()
        async let coverTask: Data? = {
            guard let thumbURL else { return nil }
            return await fetchBinaryData(url: thumbURL, headers: ["User-Agent": visionOSYouTubeUserAgent], session: session)
        }()

        guard let streamingData = root["streamingData"] as? [String: Any] else {
            return nil
        }

        let streamHeaders: [String: String] = [
            "User-Agent": visionOSYouTubeUserAgent,
            "Accept": "*/*"
        ]

        let muxedHLSPlaybackURL = (streamingData["hlsManifestUrl"] as? String).flatMap(URL.init(string:))
        let adaptiveFormats = (streamingData["adaptiveFormats"] as? [[String: Any]]) ?? []
        let muxedFormats = (streamingData["formats"] as? [[String: Any]]) ?? []

        // 1. Pick highest-bitrate Apple-native `audio/mp4` (`mp4a`, typically `itag=140`) audio track
        var bestAudioURL: URL?
        var bestAudioBytes: Int64 = 0
        var bestAudioBitrate: Int = -1

        for fmt in adaptiveFormats {
            guard let mime = fmt["mimeType"] as? String,
                  mime.lowercased().hasPrefix("audio/mp4"),
                  let urlStr = fmt["url"] as? String,
                  let audioURL = URL(string: urlStr) else {
                continue
            }
            let br = (fmt["bitrate"] as? Int) ?? 0
            if br > bestAudioBitrate {
                bestAudioBitrate = br
                bestAudioURL = audioURL
                bestAudioBytes = (fmt["contentLength"] as? String).flatMap(Int64.init) ?? 0
            }
        }

        // 2. Collect Apple-muxable H.264/HEVC `video/mp4` renditions (`avc1` / `hvc1` / `hev1`), best bitrate per resolution label
        var bestByLabel: [String: SniffedVariantOption] = [:]

        for fmt in adaptiveFormats {
            guard let mime = fmt["mimeType"] as? String,
                  mime.lowercased().hasPrefix("video/mp4"),
                  (mime.contains("avc1") || mime.contains("hvc1") || mime.contains("hev1")),
                  let urlStr = fmt["url"] as? String,
                  let videoURL = URL(string: urlStr),
                  let audioURL = bestAudioURL else {
                continue
            }

            let width = fmt["width"] as? Int
            let height = fmt["height"] as? Int
            let shortEdge = min(width ?? (height ?? 0), height ?? 0)
            let rawLabel = (fmt["qualityLabel"] as? String) ?? formatResolutionLabel(width: width, height: height, fallback: "MP4")
            let vBytes = (fmt["contentLength"] as? String).flatMap(Int64.init) ?? 0
            let totalBytes = (vBytes > 0 && bestAudioBytes > 0) ? (vBytes + bestAudioBytes) : nil
            let bitrate = Int64((fmt["bitrate"] as? Int) ?? 0)
            let rank = shortEdge * 10_000 + Int(bitrate / 1_000)

            let candidateOption = SniffedVariantOption(
                id: "yt-\(videoID)-\(rawLabel)",
                url: videoURL,
                directPlayURL: muxedHLSPlaybackURL,
                pairedAudioURL: audioURL,
                pairedAudioBytes: bestAudioBytes > 0 ? bestAudioBytes : nil,
                format: .mp4,
                resolutionLabel: rawLabel,
                width: width,
                height: height,
                bandwidthBps: bitrate,
                exactOrEstimatedBytes: totalBytes,
                headers: streamHeaders,
                qualityRank: rank
            )

            if let existing = bestByLabel[rawLabel] {
                if candidateOption.qualityRank > existing.qualityRank {
                    bestByLabel[rawLabel] = candidateOption
                }
            } else {
                bestByLabel[rawLabel] = candidateOption
            }
        }

        // 3. Fallback to progressive muxed `formats` (`itag=18`/`22`) or `hlsManifestUrl` if adaptive tracks were absent
        if bestByLabel.isEmpty {
            for fmt in muxedFormats {
                guard let urlStr = fmt["url"] as? String, let u = URL(string: urlStr) else { continue }
                let w = fmt["width"] as? Int
                let h = fmt["height"] as? Int
                let label = (fmt["qualityLabel"] as? String) ?? formatResolutionLabel(width: w, height: h, fallback: "MP4")
                let bytes = (fmt["contentLength"] as? String).flatMap(Int64.init)
                bestByLabel[label] = SniffedVariantOption(
                    id: u.absoluteString,
                    url: u,
                    format: .mp4,
                    resolutionLabel: label,
                    width: w,
                    height: h,
                    bandwidthBps: nil,
                    exactOrEstimatedBytes: bytes,
                    headers: streamHeaders,
                    qualityRank: (min(w ?? (h ?? 360), h ?? 360)) * 10_000
                )
            }
        }

        if bestByLabel.isEmpty,
           let hlsStr = streamingData["hlsManifestUrl"] as? String,
           let hlsURL = URL(string: hlsStr) {
            if case .success(let manifestText, let finalHLSURL) = await fetchUTF8TextWithReason(
                url: hlsURL,
                headers: streamHeaders,
                session: session
            ) {
                for v in parseMasterVariants(manifestText: manifestText, baseURL: finalHLSURL, headers: streamHeaders) {
                    bestByLabel[v.resolutionLabel] = v
                }
            }
        }

        let variants = bestByLabel.values.sorted { $0.qualityRank > $1.qualityRank }
        guard let top = variants.first else { return nil }
        let coverData = await coverTask

        return DiscoveredMediaGroup(
            id: "yt:\(videoID)",
            title: rawTitle,
            sourceDomain: "youtube.com",
            durationSeconds: durationSec,
            thumbnailJPEGData: coverData,
            variants: variants,
            selectedVariantID: top.id,
            isSelectedForDownload: defaultSelected
        )
    }
}
