import Foundation

/// Identifies how a URL is resolved and transported across Dysprosium's planes.
public enum TransferKind: String, Codable, Sendable, CaseIterable {
    case directRange = "HTTP Range"
    case hlsStream = "HLS Stream"
    case extractedMedia = "yt-dlp Media"
}

/// Lifecycle state of a transfer job across Control, Data, and Post-Processing planes.
public enum TransferLifecycle: String, Codable, Sendable, Equatable {
    case queued
    case resolving
    case downloading
    case muxing
    case paused
    case completed
    case failed

    public var isActive: Bool {
        switch self {
        case .resolving, .downloading, .muxing:
            return true
        case .queued, .paused, .completed, .failed:
            return false
        }
    }
}

/// Represents a contiguous byte interval assigned to a single HTTP Range worker lane.
/// Enables real-time visual heatmap rendering and crash-safe resume from exact cursors.
public struct ByteRangeSlice: Identifiable, Codable, Sendable, Equatable {
    public var id: Int
    /// Inclusive starting byte offset within the preallocated file.
    public var startOffset: Int64
    /// Next unwritten byte offset (`startOffset ... endOffset + 1`).
    public var currentOffset: Int64
    /// Inclusive ending byte offset assigned to this slice.
    public var endOffset: Int64
    /// Whether an active socket worker currently owns this slice.
    public var isActiveLane: Bool

    public init(
        id: Int,
        startOffset: Int64,
        currentOffset: Int64,
        endOffset: Int64,
        isActiveLane: Bool = false
    ) {
        self.id = id
        self.startOffset = startOffset
        self.currentOffset = currentOffset
        self.endOffset = endOffset
        self.isActiveLane = isActiveLane
    }

    public var totalBytes: Int64 {
        max(0, endOffset - startOffset + 1)
    }

    public var completedBytes: Int64 {
        min(totalBytes, max(0, currentOffset - startOffset))
    }

    public var remainingBytes: Int64 {
        max(0, endOffset - currentOffset + 1)
    }

    public var isComplete: Bool {
        currentOffset > endOffset
    }
}

/// Describes one physical track to fetch (e.g., direct file, video-only DASH track, audio-only M4A track, or HLS playlist).
public struct ResolvedTrackDescriptor: Codable, Sendable, Equatable, Identifiable {
    public enum TrackRole: String, Codable, Sendable {
        case primary
        case videoOnly
        case audioOnly
    }

    public var id: String
    public var role: TrackRole
    public var remoteURL: URL
    public var headers: [String: String]
    public var expectedBytes: Int64?
    public var supportsByteRanges: Bool
    public var isHLSManifest: Bool
    public var fileExtension: String
    /// Optional `#EXTM3U` playlist body captured directly from the live `WKWebView` response,
    /// allowing `HLSStreamEngine` to bypass Cloudflare/WAF/one-time-token 403s on manifest origins.
    public var preloadedManifestText: String?

    public init(
        id: String = UUID().uuidString,
        role: TrackRole = .primary,
        remoteURL: URL,
        headers: [String: String] = [:],
        expectedBytes: Int64? = nil,
        supportsByteRanges: Bool = true,
        isHLSManifest: Bool = false,
        fileExtension: String = "bin",
        preloadedManifestText: String? = nil
    ) {
        self.id = id
        self.role = role
        self.remoteURL = remoteURL
        self.headers = headers
        self.expectedBytes = expectedBytes
        self.supportsByteRanges = supportsByteRanges
        self.isHLSManifest = isHLSManifest
        self.fileExtension = fileExtension
        self.preloadedManifestText = preloadedManifestText
    }
}

/// Immutable contract emitted by Plane 1 (Control Plane) and consumed by Plane 2 (Data Plane).
public struct ResolvedTransferPlan: Codable, Sendable, Equatable {
    public var sourceURL: URL
    public var title: String
    public var siteDomain: String
    public var kind: TransferKind
    public var tracks: [ResolvedTrackDescriptor]
    public var outputFilename: String
    public var requiresMuxing: Bool
    public var etag: String?
    public var lastModified: String?

    public init(
        sourceURL: URL,
        title: String,
        siteDomain: String,
        kind: TransferKind,
        tracks: [ResolvedTrackDescriptor],
        outputFilename: String,
        requiresMuxing: Bool = false,
        etag: String? = nil,
        lastModified: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.title = title
        self.siteDomain = siteDomain
        self.kind = kind
        self.tracks = tracks
        self.outputFilename = outputFilename
        self.requiresMuxing = requiresMuxing
        self.etag = etag
        self.lastModified = lastModified
    }
}

/// External handoff payload accepted via `dysprosium://enqueue?...` or LiveContainer shared dropbox
/// (e.g., from external browsers, extensions, or `dysprosium://` URL-scheme handoffs).
public struct ExternalIntakeRequest: Codable, Sendable, Equatable {
    public var url: URL
    public var suggestedFilename: String?
    public var referer: String?
    public var userAgent: String?
    public var cookieHeader: String?
    public var preferredLanes: Int?

    public init(
        url: URL,
        suggestedFilename: String? = nil,
        referer: String? = nil,
        userAgent: String? = nil,
        cookieHeader: String? = nil,
        preferredLanes: Int? = nil
    ) {
        self.url = url
        self.suggestedFilename = suggestedFilename
        self.referer = referer
        self.userAgent = userAgent
        self.cookieHeader = cookieHeader
        self.preferredLanes = preferredLanes
    }

    public var synthesizedHeaders: [String: String] {
        var result: [String: String] = [:]
        if let referer, !referer.isEmpty { result["Referer"] = referer }
        if let userAgent, !userAgent.isEmpty { result["User-Agent"] = userAgent }
        if let cookieHeader, !cookieHeader.isEmpty { result["Cookie"] = cookieHeader }
        return result
    }
}

/// Observable snapshot of a transfer job persisted in SQLite WAL and rendered in UI.
public struct TransferJob: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var sourceURL: URL
    /// Optional originating webpage URL used to re-resolve expired signed CDN URLs on HTTP 403.
    public var sourcePageURL: URL?
    public var title: String
    public var siteDomain: String
    public var kind: TransferKind
    public var lifecycle: TransferLifecycle
    public var configuredLanes: Int
    public var activeLanes: Int
    public var downloadedBytes: Int64
    public var totalBytes: Int64?
    public var speedBytesPerSec: Double
    public var throughputSamples: [Double]
    public var slices: [ByteRangeSlice]
    public var completedSegments: Int
    public var totalSegments: Int?
    public var initialHeaders: [String: String]
    public var plan: ResolvedTransferPlan?
    public var destinationRelativePath: String?
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Timestamp recorded when the transfer transitioned to `.completed`.
    public var completedAt: Date?
    /// Exact accumulated seconds spent actively transferring bytes (excludes pause intervals).
    public var activeDurationSeconds: Double?
    /// Peak observed EMA throughput across the full lifetime of the transfer.
    public var peakSpeedBytesPerSec: Double?
    /// Final average throughput (`downloadedBytes / activeDurationSeconds`) computed on completion.
    public var averageSpeedBytesPerSec: Double?
    /// Originating browser profile ID (`nil` for legacy/direct/private downloads).
    public var sourceProfileID: String?

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        sourcePageURL: URL? = nil,
        title: String? = nil,
        siteDomain: String? = nil,
        kind: TransferKind = .directRange,
        lifecycle: TransferLifecycle = .queued,
        configuredLanes: Int = 8,
        activeLanes: Int = 0,
        downloadedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        speedBytesPerSec: Double = 0,
        throughputSamples: [Double] = [],
        slices: [ByteRangeSlice] = [],
        completedSegments: Int = 0,
        totalSegments: Int? = nil,
        initialHeaders: [String: String] = [:],
        plan: ResolvedTransferPlan? = nil,
        destinationRelativePath: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        activeDurationSeconds: Double? = nil,
        peakSpeedBytesPerSec: Double? = nil,
        averageSpeedBytesPerSec: Double? = nil,
        sourceProfileID: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourcePageURL = sourcePageURL
        let normalizedHost = sourceURL.host().map(LiveContainerEnvironment.HostNormalizer.normalize)
        let fallbackHost = (normalizedHost?.isEmpty == false ? normalizedHost : nil) ?? "remote"
        let rawName = sourceURL.lastPathComponent.isEmpty ? fallbackHost : sourceURL.lastPathComponent
        self.title = title ?? rawName
        self.siteDomain = siteDomain ?? fallbackHost
        self.kind = kind
        self.lifecycle = lifecycle
        self.configuredLanes = max(1, min(configuredLanes, 32))
        self.activeLanes = activeLanes
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSec = speedBytesPerSec
        self.throughputSamples = throughputSamples
        self.slices = slices
        self.completedSegments = completedSegments
        self.totalSegments = totalSegments
        self.initialHeaders = initialHeaders
        self.plan = plan
        self.destinationRelativePath = destinationRelativePath
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.activeDurationSeconds = activeDurationSeconds
        self.peakSpeedBytesPerSec = peakSpeedBytesPerSec
        self.averageSpeedBytesPerSec = averageSpeedBytesPerSec
        self.sourceProfileID = sourceProfileID
    }

    private static let sensitiveAuthHeaderNames: Set<String> = [
        "cookie",
        "authorization",
        "proxy-authorization",
        "set-cookie"
    ]

    /// Returns `headers` with sensitive authentication headers (`Cookie`, `Authorization`, `Proxy-Authorization`) removed.
    public static func strippingAuthHeaders(from headers: [String: String]) -> [String: String] {
        guard !headers.isEmpty else { return headers }
        return headers.filter { !sensitiveAuthHeaderNames.contains($0.key.lowercased()) }
    }

    /// Returns a copy of this job with `Cookie`/`Authorization` headers scrubbed from both
    /// `initialHeaders` and every resolved track descriptor.
    public func strippingAuthHeaders() -> TransferJob {
        var copy = self
        copy.initialHeaders = Self.strippingAuthHeaders(from: copy.initialHeaders)
        if var planCopy = copy.plan {
            for idx in planCopy.tracks.indices {
                planCopy.tracks[idx].headers = Self.strippingAuthHeaders(from: planCopy.tracks[idx].headers)
            }
            copy.plan = planCopy
        }
        return copy
    }

    public var progressFraction: Double {
        if let totalSegments, totalSegments > 0 {
            return min(1.0, max(0.0, Double(completedSegments) / Double(totalSegments)))
        }
        guard let totalBytes, totalBytes > 0 else { return lifecycle == .completed ? 1.0 : 0.0 }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(totalBytes)))
    }

    public var etaSeconds: TimeInterval? {
        guard lifecycle == .downloading, speedBytesPerSec > 1024 else { return nil }
        if let totalBytes, totalBytes > downloadedBytes {
            return Double(totalBytes - downloadedBytes) / speedBytesPerSec
        }
        return nil
    }

    // MARK: - Post-Completion Transfer Insights (Backward-Compatible with Legacy SQLite Rows)

    /// Effective elapsed transfer duration, preferring exact active transfer seconds over wall-clock fallback.
    public var effectiveDurationSeconds: Double? {
        if let active = activeDurationSeconds, active.isFinite, active > 0 {
            return active
        }
        guard lifecycle == .completed else { return nil }
        let end = completedAt ?? updatedAt
        let span = end.timeIntervalSince(createdAt)
        return span > 0 ? span : nil
    }

    /// Effective average throughput in bytes/sec, gracefully falling back for pre-insight records.
    public var effectiveAverageSpeedBytesPerSec: Double? {
        if let avg = averageSpeedBytesPerSec, avg.isFinite, avg > 0 {
            return avg
        }
        if let duration = effectiveDurationSeconds, duration > 0, downloadedBytes > 0 {
            return Double(downloadedBytes) / duration
        }
        let positiveSamples = throughputSamples.filter { $0 > 0 }
        guard !positiveSamples.isEmpty else { return nil }
        return positiveSamples.reduce(0, +) / Double(positiveSamples.count)
    }

    /// Peak measured throughput in bytes/sec across the entire transfer.
    public var effectivePeakSpeedBytesPerSec: Double? {
        let best = max(
            peakSpeedBytesPerSec ?? 0,
            throughputSamples.max() ?? 0,
            averageSpeedBytesPerSec ?? 0
        )
        return best > 0 ? best : nil
    }

    /// Completion timestamp, falling back to `updatedAt` for completed legacy rows.
    public var effectiveCompletedAt: Date? {
        guard lifecycle == .completed else { return completedAt }
        return completedAt ?? updatedAt
    }

    /// Concise parallelism & segment topology description (e.g. `16× Lanes · 16 Slices`, `8× Lanes · 142 Segments`).
    public var segmentTopologySummary: String {
        if kind == .hlsStream, let total = totalSegments ?? (completedSegments > 0 ? completedSegments : nil), total > 0 {
            return "\(configuredLanes)× Lanes · \(total) HLS Segments"
        }
        if !slices.isEmpty {
            return "\(configuredLanes)× Lanes · \(slices.count) Byte-Range Slices"
        }
        return "\(configuredLanes)× Lanes · \(kind.rawValue)"
    }

    /// Compact single-line insight summary for history rows (e.g. `612.5 MB · 14.8 MB/s · 16× · 42s`).
    public var compactInsightSummary: String {
        var parts: [String] = []
        let size = totalBytes ?? downloadedBytes
        if size > 0 {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        if let avg = effectiveAverageSpeedBytesPerSec, avg > 1 {
            parts.append("\(Int64(avg).formatted(.byteCount(style: .file)))/s")
        }
        if kind == .hlsStream, let segs = totalSegments ?? (completedSegments > 0 ? completedSegments : nil), segs > 0 {
            parts.append("\(segs) segs")
        } else if !slices.isEmpty {
            parts.append("\(slices.count)× slices")
        } else {
            parts.append("\(configuredLanes)×")
        }
        if let dur = effectiveDurationSeconds {
            let formatted: String
            if dur < 60 {
                formatted = dur < 10 ? String(format: "%.1fs", dur) : String(format: "%.0fs", dur)
            } else {
                let total = Int(dur.rounded())
                formatted = total < 3600
                    ? String(format: "%dm %02ds", total / 60, total % 60)
                    : String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
            }
            parts.append(formatted)
        }
        return parts.joined(separator: " · ")
    }
}
