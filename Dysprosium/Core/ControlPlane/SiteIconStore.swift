import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit

/// Bounded async semaphore limiting concurrent origin favicon network probes to `maxConcurrent` lanes
/// so scrolling past hundreds of domains never triggers a `URLSession` stampede.
private actor IconFetchGate {
    private let maxConcurrent: Int
    private var active: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int = 4) {
        self.maxConcurrent = maxConcurrent
    }

    func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            active = max(0, active - 1)
        }
    }
}

/// Memory (`NSCache`, 12 MB cap) + disk cached origin favicon & `apple-touch-icon` resolver.
/// - Downsamples oversized icons to `<= 128 px` via `ImageIO` (`16×–64×` lower bitmap RAM & ~4 KB disk footprint).
/// - Uses per-host deduplicated `Task`s instead of a global broadcast counter so resolving one domain's icon
///   never invalidates unrelated `SiteIconView` cells during scrolling.
@MainActor
public final class SiteIconStore {
    public static let shared = SiteIconStore()

    public final class ResolvedIcon: NSObject, @unchecked Sendable {
        public let image: UIImage
        public let isHighResolution: Bool

        public init(image: UIImage, isHighResolution: Bool) {
            self.image = image
            self.isHighResolution = isHighResolution
        }
    }

    private static let maxNegativeCacheHosts = 256
    private static let maxDiscoveredHostURLs = 256
    nonisolated private static let maxDiskIconCount = 250
    nonisolated private static let maxDiskIconBytes: UInt64 = 12 * 1024 * 1024

    private let memoryCache = NSCache<NSString, ResolvedIcon>()
    private var negativeCacheHosts: Set<String> = []
    private var negativeCacheOrder: [String] = []
    private var inFlightTasks: [String: Task<ResolvedIcon?, Never>] = [:]
    private var discoveredIconURLByHost: [String: URL] = [:]
    private var discoveredIconOrder: [String] = []
    private var cacheEpoch: UInt64 = 0
    private var perHostEpoch: [String: UInt64] = [:]

    private let cacheDirectory: URL
    private let session: URLSession
    private let fetchGate = IconFetchGate(maxConcurrent: 4)

    private init() {
        memoryCache.countLimit = 320
        memoryCache.totalCostLimit = 12 * 1024 * 1024

        let dir = LiveContainerEnvironment
            .persistentSubdirectory(named: "BrowserState", excludeFromiCloudBackup: true)
            .appendingPathComponent("SiteIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var mutableDir = dir
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? mutableDir.setResourceValues(rv)
        self.cacheDirectory = dir

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 10
        cfg.httpAdditionalHeaders = [
            "User-Agent": HLSStreamEngine.iosSafariUserAgent,
            "Accept": "image/avif,image/webp,image/apng,image/png,image/*,*/*;q=0.8"
        ]
        self.session = URLSession(configuration: cfg)
    }

    nonisolated public static func normalizedHost(for urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let rawHost = URL(string: candidate)?.host(), !rawHost.isEmpty else {
            return nil
        }
        let normalized = LiveContainerEnvironment.HostNormalizer.normalize(rawHost)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }

    /// Synchronous `0 ms` memory-cache lookup so already-seen hosts render immediately with zero placeholder flash.
    public func cachedIcon(for urlString: String) -> ResolvedIcon? {
        guard let host = Self.normalizedHost(for: urlString) else { return nil }
        return memoryCache.object(forKey: host as NSString)
    }

    public func clearAllIcons() {
        cancelAndResetInMemoryCaches()
        let dir = cacheDirectory
        Task.detached(priority: .utility) {
            Self.removeAllFiles(in: dir)
        }
    }

    /// Zero-ghost cache clear: cancels all in-flight icon fetches, purges memory/negative/discovered caches,
    /// and awaits physical deletion of every cached favicon in `SiteIcons/`.
    public func clearDiskCache() async {
        cancelAndResetInMemoryCaches()
        let dir = cacheDirectory
        await Task.detached(priority: .utility) {
            Self.removeAllFiles(in: dir)
        }.value
    }

    /// Deletes cached favicon file and memory/negative/discovered entries for `host` with zero ghost write-back.
    public func removeIcon(forHost host: String) async {
        let fallback = LiveContainerEnvironment.HostNormalizer.normalize(host)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let normalized = Self.normalizedHost(for: host) ?? (fallback.isEmpty ? nil : fallback) else {
            return
        }
        inFlightTasks[normalized]?.cancel()
        inFlightTasks.removeValue(forKey: normalized)
        perHostEpoch[normalized, default: 0] &+= 1
        memoryCache.removeObject(forKey: normalized as NSString)
        removeFromNegativeCache(normalized)
        removeFromDiscoveredCache(normalized)

        let diskFile = diskFileURL(for: normalized)
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: diskFile)
        }.value
    }

    /// Returns exact bytes currently occupied by `SiteIcons/` on disk.
    public func diskUsageBytes() async -> UInt64 {
        let dir = cacheDirectory
        return await Task.detached(priority: .utility) {
            LiveContainerEnvironment.directorySizeBytes(at: dir)
        }.value
    }

    private func cancelAndResetInMemoryCaches() {
        cacheEpoch &+= 1
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
        perHostEpoch.removeAll()
        memoryCache.removeAllObjects()
        negativeCacheHosts.removeAll()
        negativeCacheOrder.removeAll()
        discoveredIconURLByHost.removeAll()
        discoveredIconOrder.removeAll()
    }

    private func addToNegativeCache(_ host: String) {
        if negativeCacheHosts.insert(host).inserted {
            negativeCacheOrder.append(host)
            while negativeCacheOrder.count > Self.maxNegativeCacheHosts {
                let evicted = negativeCacheOrder.removeFirst()
                negativeCacheHosts.remove(evicted)
            }
        }
    }

    private func removeFromNegativeCache(_ host: String) {
        if negativeCacheHosts.remove(host) != nil {
            negativeCacheOrder.removeAll { $0 == host }
        }
    }

    private func setDiscoveredIconURL(_ iconURL: URL, forHost host: String) {
        if discoveredIconURLByHost[host] == nil {
            discoveredIconOrder.append(host)
            while discoveredIconOrder.count > Self.maxDiscoveredHostURLs {
                let evicted = discoveredIconOrder.removeFirst()
                discoveredIconURLByHost.removeValue(forKey: evicted)
            }
        }
        discoveredIconURLByHost[host] = iconURL
    }

    private func removeFromDiscoveredCache(_ host: String) {
        if discoveredIconURLByHost.removeValue(forKey: host) != nil {
            discoveredIconOrder.removeAll { $0 == host }
        }
    }

    /// Resolves icon from memory -> disk -> bounded 4-lane network fetch, deduplicating concurrent callers per host.
    public func resolveIcon(for urlString: String) async -> ResolvedIcon? {
        guard let host = Self.normalizedHost(for: urlString) else { return nil }
        if let mem = memoryCache.object(forKey: host as NSString) {
            return mem
        }
        if negativeCacheHosts.contains(host) {
            return nil
        }
        if let existingTask = inFlightTasks[host] {
            return await existingTask.value
        }

        let candidate = urlString.contains("://") ? urlString : "https://\(urlString)"
        guard let originURL = URL(string: candidate) else { return nil }
        let preferred = discoveredIconURLByHost[host]
        let diskFile = diskFileURL(for: host)
        let urlSession = self.session
        let gate = self.fetchGate
        let startEpoch = self.cacheEpoch
        let startHostEpoch = self.perHostEpoch[host] ?? 0

        let task = Task<ResolvedIcon?, Never> { [weak self] in
            // 1. Off-main-thread disk lookup first (+ LRU mtime touch if stale)
            let diskLoaded: ResolvedIcon? = await Task.detached(priority: .utility) {
                Self.loadCachedIconFromDisk(at: diskFile)
            }.value

            if let diskLoaded {
                if let self {
                    self.inFlightTasks.removeValue(forKey: host)
                    guard self.cacheEpoch == startEpoch,
                          (self.perHostEpoch[host] ?? 0) == startHostEpoch else {
                        return nil
                    }
                    let cost = Self.estimatedByteCost(diskLoaded.image)
                    self.memoryCache.setObject(diskLoaded, forKey: host as NSString, cost: cost)
                }
                return diskLoaded
            }

            if Task.isCancelled {
                self?.inFlightTasks.removeValue(forKey: host)
                return nil
            }

            // 2. Bounded 4-lane origin probe
            let fetched = await Self.fetchOriginIcon(
                host: host,
                originURL: originURL,
                preferredIconURL: preferred,
                diskFile: diskFile,
                urlSession: urlSession,
                gate: gate
            )

            if let self {
                self.inFlightTasks.removeValue(forKey: host)
                guard self.cacheEpoch == startEpoch,
                      (self.perHostEpoch[host] ?? 0) == startHostEpoch else {
                    Task.detached(priority: .utility) {
                        try? FileManager.default.removeItem(at: diskFile)
                    }
                    return nil
                }
                if let fetched {
                    let cost = Self.estimatedByteCost(fetched.image)
                    self.memoryCache.setObject(fetched, forKey: host as NSString, cost: cost)
                } else if !Task.isCancelled {
                    self.addToNegativeCache(host)
                }
            }
            return fetched
        }

        inFlightTasks[host] = task
        return await task.value
    }

    public func recordDiscoveredIconURL(_ iconURL: URL, forPageURL pageURL: URL) {
        guard let host = Self.normalizedHost(for: pageURL.absoluteString) else { return }
        setDiscoveredIconURL(iconURL, forHost: host)
        if let existing = memoryCache.object(forKey: host as NSString), existing.isHighResolution {
            return
        }
        if inFlightTasks[host] != nil {
            return
        }
        removeFromNegativeCache(host)

        let diskFile = diskFileURL(for: host)
        let urlSession = self.session
        let gate = self.fetchGate
        let startEpoch = self.cacheEpoch
        let startHostEpoch = self.perHostEpoch[host] ?? 0

        let task = Task<ResolvedIcon?, Never> { [weak self] in
            // 1. Disk-first check before touching the network on relaunches.
            let diskLoaded: ResolvedIcon? = await Task.detached(priority: .utility) {
                Self.loadCachedIconFromDisk(at: diskFile)
            }.value

            if let diskLoaded {
                if let self {
                    self.inFlightTasks.removeValue(forKey: host)
                    guard self.cacheEpoch == startEpoch,
                          (self.perHostEpoch[host] ?? 0) == startHostEpoch else {
                        return nil
                    }
                    let cost = Self.estimatedByteCost(diskLoaded.image)
                    self.memoryCache.setObject(diskLoaded, forKey: host as NSString, cost: cost)
                }
                return diskLoaded
            }

            if Task.isCancelled {
                self?.inFlightTasks.removeValue(forKey: host)
                return nil
            }

            // 2. Network fetch only when missing on disk.
            let upgraded = await Self.fetchOriginIcon(
                host: host,
                originURL: pageURL,
                preferredIconURL: iconURL,
                diskFile: diskFile,
                urlSession: urlSession,
                gate: gate
            )

            if let self {
                self.inFlightTasks.removeValue(forKey: host)
                guard self.cacheEpoch == startEpoch,
                      (self.perHostEpoch[host] ?? 0) == startHostEpoch else {
                    Task.detached(priority: .utility) {
                        try? FileManager.default.removeItem(at: diskFile)
                    }
                    return nil
                }
                if let upgraded {
                    let cost = Self.estimatedByteCost(upgraded.image)
                    self.memoryCache.setObject(upgraded, forKey: host as NSString, cost: cost)
                }
            }
            return upgraded
        }

        inFlightTasks[host] = task
    }

    nonisolated private static func loadCachedIconFromDisk(at diskFile: URL) -> ResolvedIcon? {
        guard let data = try? Data(contentsOf: diskFile),
              let decoded = decodeAndDownsample(data: data, maxPixelSize: 128) else {
            return nil
        }
        // Touch mtime lazily (> 1h old) to preserve LRU accuracy without flash write churn.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: diskFile.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) > 3600 {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: diskFile.path)
        }
        return decoded
    }

    nonisolated private static func removeAllFiles(in directory: URL) {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }

    nonisolated private static func enforceDiskLRULimit(
        in directory: URL,
        maxCount: Int,
        maxBytes: UInt64
    ) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        struct DiskEntry {
            let url: URL
            let size: UInt64
            let modifiedAt: Date
        }

        var entries: [DiskEntry] = []
        entries.reserveCapacity(urls.count)
        var totalBytes: UInt64 = 0

        for url in urls {
            guard let rv = try? url.resourceValues(forKeys: keys),
                  rv.isRegularFile == true else { continue }
            let size = UInt64(max(0, rv.fileSize ?? 0))
            let mod = rv.contentModificationDate ?? Date.distantPast
            entries.append(DiskEntry(url: url, size: size, modifiedAt: mod))
            totalBytes &+= size
        }

        guard entries.count > maxCount || totalBytes > maxBytes else { return }
        entries.sort { $0.modifiedAt < $1.modifiedAt }

        var remaining = entries.count
        for entry in entries {
            if remaining <= maxCount && totalBytes <= maxBytes { break }
            if (try? fm.removeItem(at: entry.url)) != nil {
                remaining -= 1
                totalBytes = totalBytes >= entry.size ? (totalBytes - entry.size) : 0
            }
        }
    }

    nonisolated private static func fetchOriginIcon(
        host: String,
        originURL: URL,
        preferredIconURL: URL?,
        diskFile: URL,
        urlSession: URLSession,
        gate: IconFetchGate
    ) async -> ResolvedIcon? {
        if Task.isCancelled { return nil }
        await gate.acquire()
        defer { Task { await gate.release() } }
        if Task.isCancelled { return nil }

        let scheme = originURL.scheme ?? "https"
        let rawHost = originURL.host() ?? host
        var candidates: [URL] = []
        if let preferredIconURL {
            candidates.append(preferredIconURL)
        }
        if let touchURL = URL(string: "\(scheme)://\(rawHost)/apple-touch-icon.png") {
            candidates.append(touchURL)
        }
        if let favURL = URL(string: "\(scheme)://\(rawHost)/favicon.ico") {
            candidates.append(favURL)
        }
        if rawHost != "www.\(host)", let wwwFav = URL(string: "https://www.\(host)/favicon.ico") {
            candidates.append(wwwFav)
        }

        var bestResolved: ResolvedIcon?
        var bestSpan: CGFloat = 0
        var seen = Set<String>()

        for candidate in candidates {
            if Task.isCancelled { return nil }
            guard seen.insert(candidate.absoluteString).inserted else { continue }
            do {
                let (data, response) = try await urlSession.data(from: candidate)
                guard !Task.isCancelled else { return nil }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      data.count >= 64,
                      data.count <= 2_097_152 else {
                    continue
                }
                if let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
                   mime.contains("text/html") {
                    continue
                }
                guard let (decoded, originalSpan) = decodeAndDownsampleWithOriginalSpan(data: data, maxPixelSize: 128) else {
                    continue
                }
                if originalSpan > bestSpan {
                    bestSpan = originalSpan
                    bestResolved = decoded
                }
                if originalSpan >= 96 { break }
            } catch {
                continue
            }
        }

        if !Task.isCancelled, let bestResolved, let png = bestResolved.image.pngData() {
            let dir = diskFile.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? png.write(to: diskFile, options: .atomic)
            enforceDiskLRULimit(in: dir, maxCount: maxDiskIconCount, maxBytes: maxDiskIconBytes)
        }
        return Task.isCancelled ? nil : bestResolved
    }

    nonisolated private static func decodeAndDownsample(data: Data, maxPixelSize: Int) -> ResolvedIcon? {
        decodeAndDownsampleWithOriginalSpan(data: data, maxPixelSize: maxPixelSize)?.0
    }

    nonisolated private static func decodeAndDownsampleWithOriginalSpan(
        data: Data,
        maxPixelSize: Int
    ) -> (ResolvedIcon, CGFloat)? {
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0 {
            var nativeSpan: CGFloat = 0
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                let w = (props[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
                let h = (props[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
                nativeSpan = max(w, h)
            }
            if nativeSpan > CGFloat(maxPixelSize) {
                let thumbOpts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ]
                if let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) {
                    let img = UIImage(cgImage: cgThumb)
                    return (ResolvedIcon(image: img, isHighResolution: nativeSpan >= 88), nativeSpan)
                }
            }
        }

        guard let fallback = UIImage(data: data) else { return nil }
        let px = max(fallback.size.width * fallback.scale, fallback.size.height * fallback.scale)
        guard px >= 12 else { return nil }
        return (ResolvedIcon(image: fallback, isHighResolution: px >= 88), px)
    }

    nonisolated private static func estimatedByteCost(_ image: UIImage) -> Int {
        let w = Int(max(1, image.size.width * image.scale))
        let h = Int(max(1, image.size.height * image.scale))
        return w * h * 4
    }

    private func diskFileURL(for host: String) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hex).png")
    }
}

/// Renders a crisp site favicon / `apple-touch-icon` inside an Apple-ratio continuous squircle (`0.245 * size`),
/// using per-host `.task(id:)` resolution with synchronous `NSCache` fast-path so scrolling never re-renders siblings.
public struct SiteIconView: View {
    public let urlString: String
    public let title: String
    public let size: CGFloat

    @State private var loadedIcon: SiteIconStore.ResolvedIcon?

    public init(urlString: String, title: String, size: CGFloat = 54) {
        self.urlString = urlString
        self.title = title
        self.size = size
    }

    private var cornerRadius: CGFloat {
        round(size * 0.245 * 2) / 2
    }

    private var hostKey: String {
        SiteIconStore.normalizedHost(for: urlString) ?? title.lowercased()
    }

    public var body: some View {
        let resolved = loadedIcon ?? SiteIconStore.shared.cachedIcon(for: urlString)
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(monogramBackground(hasIcon: resolved != nil))

            if let resolved {
                if resolved.isHighResolution {
                    Image(uiImage: resolved.image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else {
                    let inner = max(14, round(size * 0.54))
                    Image(uiImage: resolved.image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: inner, height: inner)
                }
            } else {
                Text(monogramGlyph)
                    .font(.system(size: round(size * 0.44), weight: .semibold, design: .rounded))
                    .foregroundStyle(monogramForeground)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .task(id: hostKey) {
            if let cached = SiteIconStore.shared.cachedIcon(for: urlString) {
                loadedIcon = cached
            } else {
                loadedIcon = nil
                loadedIcon = await SiteIconStore.shared.resolveIcon(for: urlString)
            }
        }
        .accessibilityHidden(true)
    }

    private var monogramGlyph: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmedTitle.isEmpty ? hostKey : trimmedTitle
        for scalar in source {
            if scalar.isLetter || scalar.isNumber {
                return String(scalar).uppercased()
            }
        }
        return String(source.prefix(1)).uppercased()
    }

    private var hueBucket: Double {
        var hash: UInt64 = 1469598103934665603
        for byte in hostKey.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        let paletteHues: [Double] = [0.58, 0.46, 0.63, 0.08, 0.96, 0.76, 0.36, 0.53]
        return paletteHues[Int(hash % UInt64(paletteHues.count))]
    }

    private func monogramBackground(hasIcon: Bool) -> Color {
        if hasIcon {
            return Color(.secondarySystemGroupedBackground)
        }
        return Color(hue: hueBucket, saturation: 0.20, brightness: 0.52).opacity(0.16)
    }

    private var monogramForeground: Color {
        Color(hue: hueBucket, saturation: 0.52, brightness: 0.46)
    }
}

/// Renders an iOS / Safari-style `2 × 2` miniature mosaic of up to 4 bookmarks inside a `54 × 54 pt` folder squircle.
public struct FavoriteFolderMosaicView: View {
    public let previewBookmarks: [BrowserBookmark]
    public let size: CGFloat

    public init(previewBookmarks: [BrowserBookmark], size: CGFloat = 54) {
        self.previewBookmarks = previewBookmarks
        self.size = size
    }

    private var cornerRadius: CGFloat {
        round(size * 0.245 * 2) / 2
    }

    public var body: some View {
        let pad = round(size * 0.13)
        let spacing = round(size * 0.075)
        let miniSize = floor((size - pad * 2 - spacing) / 2)

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))

            if previewBookmarks.isEmpty {
                Image(systemName: "folder.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: round(size * 0.40), weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        slotView(at: 0, cellSize: miniSize)
                        slotView(at: 1, cellSize: miniSize)
                    }
                    HStack(spacing: spacing) {
                        slotView(at: 2, cellSize: miniSize)
                        slotView(at: 3, cellSize: miniSize)
                    }
                }
                .padding(pad)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.10), lineWidth: 0.6)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func slotView(at index: Int, cellSize: CGFloat) -> some View {
        if index < previewBookmarks.count {
            let bm = previewBookmarks[index]
            SiteIconView(urlString: bm.urlString, title: bm.title, size: cellSize)
        } else {
            RoundedRectangle(cornerRadius: round(cellSize * 0.25), style: .continuous)
                .fill(Color(.tertiarySystemFill).opacity(0.65))
                .frame(width: cellSize, height: cellSize)
        }
    }
}
