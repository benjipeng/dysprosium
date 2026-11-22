import Foundation

/// Single source of truth for URL & stream format classification across the Omnibox,
/// Intake Composer, Control-Plane `MediaResolver`, and WebKit runtime sniffer.
/// Strictly format- and MIME-driven with zero hardcoded website domains.
public enum MediaURLClassifier {
    private static let directAssetExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m3u8", "mpd",
        "mp3", "m4a", "aac", "flac", "wav", "ogg",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar",
        "ipa", "dmg", "pkg", "iso", "epub", "bin", "safetensors", "gguf"
    ]

    private static let ignoredSubresourceSuffixes: [String] = [
        ".ts", ".m4s", ".aac", ".vtt", ".srt", ".jpg", ".jpeg", ".png",
        ".gif", ".webp", ".svg", ".js", ".css", ".woff", ".woff2", ".ico"
    ]

    /// True when `url` points directly to a downloadable binary file or manifest rather than an HTML webpage.
    public static func isDirectSingleAssetURL(_ url: URL) -> Bool {
        if isExplicitHLSURL(url) {
            return true
        }
        let ext = url.pathExtension.lowercased()
        if directAssetExtensions.contains(ext) {
            return true
        }
        return false
    }

    /// True when `url` is an HLS `.m3u8` playlist (including container-wrapped `?r_file=chunklist.m3u8`).
    public static func isExplicitHLSURL(_ url: URL) -> Bool {
        let pathExt = url.pathExtension.lowercased()
        let lowerFull = url.absoluteString.lowercased()
        return pathExt == "m3u8"
            || lowerFull.contains(".m3u8?")
            || lowerFull.contains(".m3u8&")
            || lowerFull.contains("r_file=chunklist.m3u8")
            || lowerFull.contains("application%2fvnd.apple.mpegurl")
            || lowerFull.contains("application/vnd.apple.mpegurl")
    }

    private static let hardNonMediaSuffixes: [String] = [
        ".vtt", ".srt", ".js", ".mjs", ".css", ".woff", ".woff2", ".svg", ".ico"
    ]

    /// Classifies a candidate subresource URL intercepted inside WebKit, filtering out scrub-bar
    /// storyboards, spritesheets, individual `.ts`/`.m4s` chunks, and incomplete range templates.
    /// Content & MIME truth (`m3u8-manifest`, `video-mime`, `dash-mime`, explicit `mimeType`)
    /// always takes precedence over URL path heuristics (so a genuine `video/mp4` whose path happens
    /// to contain `/hls/` is never misclassified as an HLS playlist).
    public static func classifyStreamFormat(
        url: URL,
        hint: String?,
        mimeType: String? = nil
    ) -> SniffedStreamCandidate.StreamFormat? {
        let lowerPath = url.path.lowercased()
        let lowerFull = url.absoluteString.lowercased()
        let lowerHint = hint?.lowercased() ?? ""
        let lowerMIME = (mimeType?.split(separator: ";").first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if lowerPath.hasSuffix(".faa.mp4")
            || lowerFull.contains("storyboard")
            || lowerFull.contains("spritesheet")
            || lowerFull.contains("trickplay")
            || lowerFull.contains("r_type=video%2fmp2t")
            || lowerFull.contains("r_type=video/mp2t")
            || lowerMIME.contains("mp2t")
            || lowerFull.hasSuffix("r_range=")
            || lowerFull.contains("r_range=&") {
            return nil
        }

        if lowerHint == "m3u8-manifest" || lowerHint == "fetch-manifest" || lowerHint == "xhr-manifest" || lowerMIME.contains("mpegurl") {
            return .hls
        }
        if lowerHint == "dash-mime" || lowerMIME.contains("dash+xml") {
            return .dash
        }

        // Direct binary media MIME truth overrides URL path heuristics (e.g. `video/mp4` on `/hls/video`).
        if lowerHint == "video-mime"
            || lowerMIME.hasPrefix("video/")
            || lowerMIME.hasPrefix("audio/") {
            if lowerFull.hasPrefix("blob:") || lowerFull.hasPrefix("data:") {
                return nil
            }
            for suffix in hardNonMediaSuffixes where lowerPath.hasSuffix(suffix) {
                return nil
            }
            return .mp4
        }

        if lowerHint == "video-src" {
            if lowerFull.hasPrefix("blob:") || lowerFull.hasPrefix("data:") {
                return nil
            }
            for suffix in hardNonMediaSuffixes where lowerPath.hasSuffix(suffix) {
                return nil
            }
            if isExplicitHLSURL(url) || lowerFull.contains("mpegurl") {
                return .hls
            }
            if lowerPath.hasSuffix(".mpd") || lowerFull.contains(".mpd?") {
                return .dash
            }
            return .mp4
        }

        for suffix in ignoredSubresourceSuffixes where lowerPath.hasSuffix(suffix) {
            return nil
        }

        if isExplicitHLSURL(url)
            || lowerFull.contains("mpegurl")
            || lowerFull.contains("/hls/")
            || lowerFull.contains("master.txt")
            || lowerFull.contains("index-v1-a1") {
            return .hls
        }

        if lowerPath.hasSuffix(".mpd") || lowerFull.contains(".mpd?") {
            return .dash
        }

        if lowerFull.contains("/videoplayback") {
            let isVideoMP4 = lowerFull.contains("mime=video/mp4") || lowerFull.contains("mime=video%2fmp4")
            let isMuxed = !lowerFull.contains("ump=1")
                && (lowerHint == "yt-muxed" || lowerHint == "video-src" || lowerFull.contains("itag=18") || lowerFull.contains("itag=22"))
            return (isVideoMP4 && isMuxed) ? .mp4 : nil
        }

        if lowerPath.hasSuffix(".mp4")
            || lowerPath.hasSuffix(".m4v")
            || lowerPath.hasSuffix(".webm")
            || lowerPath.hasSuffix(".mov")
            || lowerPath.hasSuffix(".mkv")
            || lowerPath.hasSuffix(".m4a")
            || lowerPath.hasSuffix(".mp3")
            || lowerFull.contains("mime=video/mp4")
            || lowerFull.contains("mime=video%2fmp4") {
            return .mp4
        }

        return nil
    }

    /// Resolves the true output container extension from MIME/format/URL evidence so WebM or
    /// audio streams keep their real extension instead of being mislabeled `.mp4`.
    public static func preferredFileExtension(
        url: URL,
        format: SniffedStreamCandidate.StreamFormat,
        mimeType: String? = nil
    ) -> String {
        switch format {
        case .hls:
            return "mp4"
        case .dash:
            return "mpd"
        case .mp4:
            let mime = (mimeType?.split(separator: ";").first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if mime == "video/webm" || mime == "audio/webm" { return "webm" }
            if mime == "video/x-matroska" || mime == "audio/x-matroska" { return "mkv" }
            if mime == "video/quicktime" { return "mov" }
            if mime == "video/ogg" || mime == "audio/ogg" { return "ogg" }
            if mime == "audio/mpeg" { return "mp3" }
            if mime == "audio/mp4" || mime == "audio/x-m4a" || mime == "audio/aac" { return "m4a" }
            if mime == "audio/flac" { return "flac" }
            if mime == "audio/wav" || mime == "audio/x-wav" { return "wav" }
            if mime == "video/mp4" || mime == "video/x-m4v" { return "mp4" }

            let ext = url.pathExtension.lowercased()
            let knownDirect: Set<String> = ["mp4", "m4v", "webm", "mkv", "mov", "ogg", "mp3", "m4a", "aac", "flac", "wav"]
            if knownDirect.contains(ext) {
                return ext == "m4v" ? "mp4" : ext
            }
            return "mp4"
        }
    }

    public static func inferQualityScore(
        url: URL,
        explicitQuality: Int,
        format: SniffedStreamCandidate.StreamFormat
    ) -> Int {
        if explicitQuality > 0 { return explicitQuality }
        let s = url.absoluteString.lowercased()
        for res in [2160, 1440, 1080, 720, 480, 360, 240] {
            if s.contains("\(res)p") || s.contains("_\(res)") || s.contains(".\(res).") || s.contains("/\(res)/") {
                return res
            }
        }
        if format == .hls {
            return url.path.lowercased().hasSuffix(".m3u8") ? 960 : 860
        }
        return 500
    }

    /// Extracts an explicit video pixel height from `qualityScore`, excluding synthetic
    /// format-ranking defaults (`500` MP4, `860`/`960` HLS) so unprobed streams never display
    /// fabricated resolutions like `[500p]` / `480p`.
    public static func inferredPixelHeight(fromQualityScore score: Int) -> Int? {
        guard score >= 144, score <= 4320, score != 500, score != 860, score != 960 else {
            return nil
        }
        return score
    }
}
