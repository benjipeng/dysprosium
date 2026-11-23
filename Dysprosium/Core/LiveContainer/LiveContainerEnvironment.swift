import Foundation
import Darwin

/// Encapsulates LiveContainer runtime detection, guest Mach-O symbol resolution,
/// Foundation-virtualized sandbox paths, iOS Files.app storage hygiene, and `0xdead10cc` file-lock protection.
public enum LiveContainerEnvironment {
    /// Represents a physical media or archive file discovered in Dysprosium's `Downloads` directory.
    public struct DownloadedVaultItem: Identifiable, Sendable, Equatable {
        public enum MediaKind: String, Sendable, Equatable {
            case video = "Video"
            case audio = "Audio"
            case archive = "Archive"
            case document = "File"

            public var isPlayableVideo: Bool {
                self == .video
            }

            public var systemImage: String {
                switch self {
                case .video: return "film.stack.fill"
                case .audio: return "waveform"
                case .archive: return "doc.zipper"
                case .document: return "doc.fill"
                }
            }

            public static func infer(from filename: String) -> MediaKind {
                let ext = (filename as NSString).pathExtension.lowercased()
                if ["mp4", "m4v", "mov", "mkv", "webm", "ts", "avi"].contains(ext) {
                    return .video
                }
                if ["m4a", "mp3", "flac", "wav", "aac", "ogg", "opus"].contains(ext) {
                    return .audio
                }
                if ["zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "ipa", "dmg"].contains(ext) {
                    return .archive
                }
                return .document
            }
        }

        public let id: String
        public let fileURL: URL
        public let filename: String
        public let byteSize: Int64
        public let modifiedAt: Date
        public let mediaKind: MediaKind

        public init(
            id: String? = nil,
            fileURL: URL,
            filename: String,
            byteSize: Int64,
            modifiedAt: Date,
            mediaKind: MediaKind? = nil
        ) {
            self.id = id ?? fileURL.standardizedFileURL.path
            self.fileURL = fileURL
            self.filename = filename
            self.byteSize = byteSize
            self.modifiedAt = modifiedAt
            self.mediaKind = mediaKind ?? MediaKind.infer(from: filename)
        }

        /// True when iOS `AVPlayer` and `AVAssetImageGenerator` can natively decode the container.
        public var supportsNativeAVPlayback: Bool {
            let ext = (filename as NSString).pathExtension.lowercased()
            return ["mp4", "m4v", "mov", "ts", "m4a", "mp3", "wav", "aac"].contains(ext)
        }

        /// True when `AVAssetImageGenerator` can extract a poster frame from the video track.
        public var supportsVideoThumbnail: Bool {
            let ext = (filename as NSString).pathExtension.lowercased()
            return ["mp4", "m4v", "mov"].contains(ext)
        }
    }

    /// LiveContainer injects `LC_HOME_PATH` into every guest app environment.
    public static var isRunningInLiveContainer: Bool {
        ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil
    }

    public static var guestHomePath: String {
        ProcessInfo.processInfo.environment["LC_HOME_PATH"] ?? NSHomeDirectory()
    }

    /// Resolves LiveContainer's real host App Group container when `LCSharedUtils` is loaded,
    /// enabling unified persistence across LiveContainer 1 / 2 / 3+ (Private & Shared Apps)
    /// and zero-copy handoff with sibling guests.
    public static var hostSharedAppGroupID: String? {
        guard let cls = NSClassFromString("LCSharedUtils") else { return nil }
        let sel = NSSelectorFromString("appGroupID")
        guard (cls as AnyObject).responds(to: sel),
              let unmanaged = (cls as AnyObject).perform(sel),
              let groupID = unmanaged.takeUnretainedValue() as? String,
              !groupID.isEmpty else {
            return nil
        }
        return groupID
    }

    /// Resolves the genuine kernel App Group directory (`/private/var/mobile/Containers/Shared/AppGroup/<UUID>/`)
    /// shared identically across LiveContainer 1, LiveContainer 2, LiveContainer 3+, Private Apps, and Shared Apps.
    public static var hostSharedAppGroupURL: URL? {
        guard let groupID = hostSharedAppGroupID else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    private static let sharedDefaultsMigrationSentinelKey = "dysprosium.sharedDefaults.migrated.v1"

    nonisolated(unsafe) private static let cachedSharedDefaults: UserDefaults = {
        if isRunningInLiveContainer,
           let groupID = hostSharedAppGroupID,
           hostSharedAppGroupURL != nil,
           let suite = UserDefaults(suiteName: groupID) {
            migrateStandardDefaultsIfNeeded(into: suite)
            return suite
        }
        return .standard
    }()

    /// Shared `UserDefaults` backed by LiveContainer's kernel App Group when active so
    /// `LC 1`, `LC 2`, and `LC 3+` share global preferences seamlessly, falling back to
    /// `UserDefaults.standard` in Simulator or standalone builds.
    public static var sharedDefaults: UserDefaults {
        cachedSharedDefaults
    }

    /// Canonical hostname normalizer shared across Browser, Shield, Dark Reader, and Control Plane.
    /// Lowercases, trims whitespace and trailing dots, and strips leading `www.`/`m.`/`mobile.`
    /// prefixes safely via `hasPrefix` (never substring replacement).
    public enum HostNormalizer {
        private static let redundantPrefixes = ["www.", "m.", "mobile."]

        public static func normalize(_ raw: String) -> String {
            var host = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            while host.hasSuffix(".") {
                host.removeLast()
            }
            var stripped = true
            while stripped {
                stripped = false
                for prefix in redundantPrefixes where host.hasPrefix(prefix) {
                    let remainder = String(host.dropFirst(prefix.count))
                    if remainder.contains(".") {
                        host = remainder
                        stripped = true
                        break
                    }
                }
            }
            return host
        }
    }

    /// Recursively computes logical disk usage in bytes for a file or directory without following symlinks.
    public static func directorySizeBytes(at url: URL) -> UInt64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]

        if let rootValues = try? url.resourceValues(forKeys: keys) {
            if rootValues.isSymbolicLink == true {
                return 0
            }
            if rootValues.isRegularFile == true {
                if let size = rootValues.fileSize {
                    return UInt64(max(0, size))
                }
                if let attrSize = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber {
                    return UInt64(max(0, attrSize.int64Value))
                }
                return 0
            }
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return 0
        }

        var totalBytes: UInt64 = 0
        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                if let size = values.fileSize {
                    totalBytes &+= UInt64(max(0, size))
                } else if let attrSize = (try? fm.attributesOfItem(atPath: itemURL.path)[.size]) as? NSNumber {
                    totalBytes &+= UInt64(max(0, attrSize.int64Value))
                }
            }
        }
        return totalBytes
    }

    /// Removes orphaned `Staging/<uuid>` directories not belonging to `activeTransferIDs` and
    /// stale Dysprosium probe/remux scratch folders from the temporary directory. Returns freed bytes.
    /// Pass a positive `minimumStagingOrphanAge` for background sweeps so concurrently enqueued
    /// transfers created after `activeTransferIDs` was snapshotted can never be unlinked mid-flight.
    @discardableResult
    public static func reclaimOrphanedTemporaryFiles(
        activeTransferIDs: Set<UUID>,
        minimumStagingOrphanAge: TimeInterval = 0
    ) -> UInt64 {
        let fm = FileManager.default
        var freedBytes: UInt64 = 0

        let stagingRoot = stagingDirectory
        let stagingCutoff = minimumStagingOrphanAge > 0
            ? Date().addingTimeInterval(-minimumStagingOrphanAge)
            : nil
        if let stagingEntries = try? fm.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: []
        ) {
            for entry in stagingEntries {
                let name = entry.lastPathComponent
                guard !name.hasPrefix(".") else { continue }
                if let uuid = UUID(uuidString: name), activeTransferIDs.contains(uuid) {
                    continue
                }
                if let stagingCutoff {
                    let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                    let stamp = max(
                        values?.contentModificationDate ?? .distantPast,
                        values?.creationDate ?? .distantPast
                    )
                    if stamp >= stagingCutoff {
                        continue
                    }
                }
                let size = directorySizeBytes(at: entry)
                if (try? fm.removeItem(at: entry)) != nil {
                    freedBytes &+= size
                }
            }
        }

        let tempRoot = fm.temporaryDirectory
        let staleCutoff = Date().addingTimeInterval(-60)
        let ownedTempPrefixes = ["dys-probe-", "dys-remux-", "dys-tmp-", "dys-wkdl-"]
        if let tempEntries = try? fm.contentsOfDirectory(
            at: tempRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: []
        ) {
            for entry in tempEntries {
                let name = entry.lastPathComponent
                guard ownedTempPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
                let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                let stamp = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
                guard stamp < staleCutoff else { continue }
                let size = directorySizeBytes(at: entry)
                if (try? fm.removeItem(at: entry)) != nil {
                    freedBytes &+= size
                }
            }
        }

        return freedBytes
    }

    /// Opens the guest executable image explicitly. Inside LiveContainer, `dlopen(nil, ...)`
    /// inspects the host executable first; passing `Bundle.main.executablePath` guarantees
    /// C-ABI bridges (`@_cdecl` exports) resolve against Dysprosium's own Mach-O image.
    public static func openGuestExecutableImage() -> UnsafeMutableRawPointer? {
        if let execPath = Bundle.main.executablePath,
           let handle = dlopen(execPath, RTLD_NOW | RTLD_LOCAL) {
            return handle
        }
        return dlopen(nil, RTLD_NOW)
    }

    // MARK: - Virtualized Directory Layout, Custom Save Folder & iOS Files.app Promotion

    private final class CustomFolderStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?
        private var breadcrumb: String?

        func set(url: URL?, breadcrumb: String?) {
            lock.lock()
            self.url = url
            self.breadcrumb = breadcrumb
            lock.unlock()
        }

        func snapshot() -> (url: URL?, breadcrumb: String?) {
            lock.lock()
            defer { lock.unlock() }
            return (url, breadcrumb)
        }
    }

    private static let customFolderState = CustomFolderStateBox()

    public static func setActiveCustomDownloadsFolder(url: URL?, displayBreadcrumb: String?) {
        customFolderState.set(url: url, breadcrumb: displayBreadcrumb)
    }

    public static var activeCustomDownloadsURL: URL? {
        customFolderState.snapshot().url
    }

    public static var isUsingCustomDownloadsFolder: Bool {
        customFolderState.snapshot().url != nil
    }

    public static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Whether the active downloads directory can be browsed directly in iOS Files.app.
    public static var isDownloadsDirectoryVisibleInFiles: Bool {
        if isUsingCustomDownloadsFolder {
            return true
        }
        if isRunningInLiveContainer {
            return isPrivateHostDocumentsLayout() || hostSharedAppGroupURL == nil
        }
        return true
    }

    /// User-facing bread-crumb path displayed in the Downloads & Engine tabs.
    public static var displayDownloadsPath: String {
        let custom = customFolderState.snapshot()
        if let breadcrumb = custom.breadcrumb, custom.url != nil, !breadcrumb.isEmpty {
            return breadcrumb
        }
        if isRunningInLiveContainer {
            if !isPrivateHostDocumentsLayout(), hostSharedAppGroupURL != nil {
                return "App Storage"
            }
            return "On My iPhone › LiveContainer › Dysprosium › Downloads"
        }
        return "On My iPhone › Dysprosium › Downloads"
    }

    /// Queries free storage capacity on the active downloads volume in bytes.
    public static var availableDiskSpaceBytes: Int64? {
        let probeURL = downloadsDirectory
        if let values = try? probeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) {
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                return important
            }
            if let standard = values.volumeAvailableCapacity, standard > 0 {
                return Int64(standard)
            }
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSize = attrs[.systemFreeSize] as? NSNumber {
            return freeSize.int64Value
        }
        return nil
    }

    /// Primary user-visible `Downloads` directory exposed to the iOS Files app:
    /// - Standalone / Simulator: `On My iPhone › Dysprosium › Downloads` (`Documents/Downloads/`)
    /// - LiveContainer Guest: `On My iPhone › LiveContainer › Dysprosium › Downloads` (promoted out of the
    ///   deep `Data/Application/<UUID>/` path so users find downloads immediately in Files.app, with a
    ///   symlink at `<documentsDirectory>/Downloads` so guest-local and host-level paths resolve identically).
    /// Resolves the LiveContainer host or shared container root from `LC_HOME_PATH` or `NSHomeDirectory()`.
    /// Supports both Private App paths (`<HostContainer>/Documents/Data/Application/<GuestUUID>`)
    /// and Shared App paths (`<SharedRoot>/LiveContainer/Data/Application/<GuestUUID>`).
    public static func resolveLiveContainerHostRoot(
        fromCandidatePaths candidatePaths: [String]? = nil
    ) -> URL? {
        let candidates = candidatePaths ?? [
            ProcessInfo.processInfo.environment["LC_HOME_PATH"],
            NSHomeDirectory()
        ].compactMap { $0 }

        for rawPath in candidates where !rawPath.isEmpty {
            let guestHome = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            let appDir = guestHome.deletingLastPathComponent()
            let dataDir = appDir.deletingLastPathComponent()
            let parentDir = dataDir.deletingLastPathComponent()
            if appDir.lastPathComponent == "Application",
               dataDir.lastPathComponent == "Data",
               (parentDir.lastPathComponent == "Documents" || parentDir.lastPathComponent == "LiveContainer") {
                return parentDir.deletingLastPathComponent()
            }
        }
        return nil
    }

    /// True when the guest home path resides inside a host `Documents/Data/Application/<UUID>` tree
    /// (Private App mode where `<HostContainer>/Documents/` is surfaced in iOS Files.app).
    private static func isPrivateHostDocumentsLayout() -> Bool {
        let candidates = [
            ProcessInfo.processInfo.environment["LC_HOME_PATH"],
            NSHomeDirectory()
        ].compactMap { $0 }
        for rawPath in candidates where !rawPath.isEmpty {
            let guestHome = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            let appDir = guestHome.deletingLastPathComponent()
            let dataDir = appDir.deletingLastPathComponent()
            let parentDir = dataDir.deletingLastPathComponent()
            if appDir.lastPathComponent == "Application",
               dataDir.lastPathComponent == "Data",
               parentDir.lastPathComponent == "Documents" {
                return true
            }
        }
        return false
    }

    /// Pure, testable resolver selecting the canonical durable `Application Support/Dysprosium` directory:
    /// 1. LiveContainer Shared App Group (`<SharedAppGroup>/Library/Application Support/Dysprosium/`) —
    ///    uniform across LiveContainer 1, LiveContainer 2, LiveContainer 3+, Private Apps, and Shared Apps.
    /// 2. LiveContainer Host Root (`<HostContainer>/Library/Application Support/Dysprosium/`) — fallback if no App Group.
    /// 3. Standard `Library/Application Support/` on Simulator / Standalone.
    public static func resolvePersistentAppSupportDirectory(
        isLiveContainer: Bool,
        sharedAppGroupURL: URL?,
        hostRootURL: URL?,
        guestAppSupportURL: URL
    ) -> URL {
        let fm = FileManager.default
        if isLiveContainer, let sharedRoot = sharedAppGroupURL {
            let sharedAppSupport = sharedRoot
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Dysprosium", isDirectory: true)
            if (try? fm.createDirectory(at: sharedAppSupport, withIntermediateDirectories: true)) != nil {
                return sharedAppSupport
            }
        }
        if isLiveContainer, let hostRoot = hostRootURL {
            let hostAppSupport = hostRoot
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Dysprosium", isDirectory: true)
            if (try? fm.createDirectory(at: hostAppSupport, withIntermediateDirectories: true)) != nil {
                return hostAppSupport
            }
        }
        ensureDirectory(guestAppSupportURL, excludeFromiCloudBackup: false)
        return guestAppSupportURL
    }

    /// Host/AppGroup-level persistent Application Support directory immune to guest resets and
    /// shared identically across LiveContainer 1 / 2 / 3+:
    /// - LiveContainer Guest (with App Group): `<SharedAppGroup>/Library/Application Support/Dysprosium/`
    /// - LiveContainer Guest (fallback): `<HostContainer>/Library/Application Support/Dysprosium/`
    /// - Standalone / Simulator: standard `Library/Application Support/`
    private static let cachedPersistentAppSupportDirectory: URL = {
        let guestAppSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return resolvePersistentAppSupportDirectory(
            isLiveContainer: isRunningInLiveContainer,
            sharedAppGroupURL: hostSharedAppGroupURL,
            hostRootURL: resolveLiveContainerHostRoot(),
            guestAppSupportURL: guestAppSupport
        )
    }()

    public static var persistentAppSupportDirectory: URL {
        cachedPersistentAppSupportDirectory
    }

    /// Migrates files non-destructively from ordered legacy candidate directories into `target`
    /// whenever `target` is still empty. Preserves originals as backup.
    @discardableResult
    public static func migrateLegacySubdirectoryIfNeeded(
        into target: URL,
        legacyCandidates: [URL]
    ) -> Bool {
        let fm = FileManager.default
        let targetAlreadyPopulated: Bool = {
            guard let items = try? fm.contentsOfDirectory(atPath: target.path) else { return false }
            return !items.filter { !$0.hasPrefix(".") }.isEmpty
        }()
        guard !targetAlreadyPopulated else { return false }

        let canonicalTarget = target.standardizedFileURL.path
        for legacyDir in legacyCandidates {
            guard legacyDir.standardizedFileURL.path != canonicalTarget,
                  let legacyItems = try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil),
                  !legacyItems.filter({ !$0.lastPathComponent.hasPrefix(".") }).isEmpty else {
                continue
            }
            var copiedAny = false
            for src in legacyItems where !src.lastPathComponent.hasPrefix(".") {
                let dst = target.appendingPathComponent(src.lastPathComponent)
                if !fm.fileExists(atPath: dst.path) {
                    if (try? fm.copyItem(at: src, to: dst)) != nil {
                        copiedAny = true
                    }
                }
            }
            if copiedAny {
                return true
            }
        }
        return false
    }

    /// Returns a durable subdirectory (`BrowserState`, `Database`, `FilterLists`) under `persistentAppSupportDirectory`,
    /// automatically migrating any legacy files from single-host `<HostContainer>/Library/Application Support/Dysprosium/<name>`
    /// or guest-local `Library/Application Support/<name>` if needed.
    public static func persistentSubdirectory(named name: String, excludeFromiCloudBackup: Bool) -> URL {
        let target = cachedPersistentAppSupportDirectory.appendingPathComponent(name, isDirectory: true)
        ensureDirectory(target, excludeFromiCloudBackup: excludeFromiCloudBackup)

        var legacyCandidates: [URL] = []
        if let hostRoot = resolveLiveContainerHostRoot() {
            legacyCandidates.append(
                hostRoot
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("Dysprosium", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true)
            )
        }
        if let guestAppSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            legacyCandidates.append(guestAppSupport.appendingPathComponent(name, isDirectory: true))
        }
        migrateLegacySubdirectoryIfNeeded(into: target, legacyCandidates: legacyCandidates)
        return target
    }

    private static let cachedDefaultDownloadsDirectory: URL = {
        ensureFilesAppVisibilityMarker()
        let guestLocalDownloads = documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)

        // Private App in LC: promote to `<HostContainer>/Documents/Dysprosium/Downloads` so files appear in iOS Files.app.
        if isPrivateHostDocumentsLayout(), let hostRoot = resolveLiveContainerHostRoot() {
            let hostDocuments = hostRoot.appendingPathComponent("Documents", isDirectory: true)
            let hostAppFolder = hostDocuments.appendingPathComponent("Dysprosium", isDirectory: true)
            let promoted = hostAppFolder.appendingPathComponent("Downloads", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: promoted, withIntermediateDirectories: true)) != nil {
                excludeFromBackup(hostAppFolder)
                excludeFromBackup(promoted)
                ensureGuestDownloadsSymlink(at: guestLocalDownloads, pointingTo: promoted)
                return promoted
            }
        }

        // Shared App across LC 1 / LC 2 / LC 3+: store in Shared App Group `Documents/Dysprosium/Downloads`
        // so every LiveContainer instance accesses the exact same downloaded media library.
        if isRunningInLiveContainer, let sharedRoot = hostSharedAppGroupURL {
            let sharedAppFolder = sharedRoot
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Dysprosium", isDirectory: true)
            let sharedDownloads = sharedAppFolder.appendingPathComponent("Downloads", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: sharedDownloads, withIntermediateDirectories: true)) != nil {
                excludeFromBackup(sharedAppFolder)
                excludeFromBackup(sharedDownloads)
                ensureGuestDownloadsSymlink(at: guestLocalDownloads, pointingTo: sharedDownloads)
                return sharedDownloads
            }
        }

        ensureDirectory(guestLocalDownloads, excludeFromiCloudBackup: true)
        return guestLocalDownloads
    }()

    public static var defaultDownloadsDirectory: URL {
        cachedDefaultDownloadsDirectory
    }

    public static var downloadsDirectory: URL {
        activeCustomDownloadsURL ?? cachedDefaultDownloadsDirectory
    }

    /// Alias preserved for call-site compatibility; resolves dynamically to `downloadsDirectory`.
    public static var vaultDirectory: URL {
        downloadsDirectory
    }

    /// Generates a collision-free filename inside `directory`.
    public static func uniqueDestinationURL(
        in directory: URL,
        desiredFilename: String,
        reservedPaths: Set<String> = []
    ) -> URL {
        let fm = FileManager.default
        let sanitized = desiredFilename
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        let cleanName = (sanitized.isEmpty || sanitized == "." || sanitized == "..") ? "download" : sanitized
        let nsName = cleanName as NSString
        let rawExt = nsName.pathExtension
        let hasExt = !rawExt.isEmpty && rawExt.count <= 12 && !nsName.deletingPathExtension.isEmpty
        let stem = hasExt ? nsName.deletingPathExtension : cleanName
        let ext = hasExt ? rawExt : ""

        let first = directory.appendingPathComponent(cleanName, isDirectory: false)
        if !fm.fileExists(atPath: first.path),
           !reservedPaths.contains(first.standardizedFileURL.path) {
            return first
        }
        for idx in 2...9999 {
            let nextName = hasExt ? "\(stem) (\(idx)).\(ext)" : "\(stem) (\(idx))"
            let candidate = directory.appendingPathComponent(nextName, isDirectory: false)
            if !fm.fileExists(atPath: candidate.path),
               !reservedPaths.contains(candidate.standardizedFileURL.path) {
                return candidate
            }
        }
        let fallbackName = hasExt ? "\(stem)-\(UUID().uuidString.prefix(6)).\(ext)" : "\(stem)-\(UUID().uuidString.prefix(6))"
        return directory.appendingPathComponent(fallbackName, isDirectory: false)
    }

    /// Atomically commits a locally staged file (from multi-lane Range staging, FFmpeg mux, `WKDownload`,
    /// or native PDF preview) into `destinationDirectory` with full iCloud Drive / FileProvider safety:
    /// - Fast-path `moveItem` on same-volume local non-ubiquitous destinations when `removeSource == true`.
    /// - Cross-volume / FileProvider / iCloud Drive safe `NSFileCoordinator` `copyItem` + source cleanup.
    /// - Never writes `isExcludedFromBackup = true` inside Custom Save Folders so iCloud Drive sync works.
    @discardableResult
    public static func commitStagedFile(
        from stagedURL: URL,
        toDirectory destinationDirectory: URL = downloadsDirectory,
        preferredFilename: String,
        removeSource: Bool
    ) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationDirectory.path) {
            try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        }
        let finalURL = uniqueDestinationURL(in: destinationDirectory, desiredFilename: preferredFilename)
        let isUbiquitous = fm.isUbiquitousItem(at: destinationDirectory)
            || destinationDirectory.standardizedFileURL.path.contains("Mobile Documents")
        let useDirectMove = removeSource && !isUbiquitous && !isUsingCustomDownloadsFolder

        if useDirectMove {
            do {
                try fm.moveItem(at: stagedURL, to: finalURL)
                return finalURL
            } catch {
                // Fall through to coordinated cross-volume copy below.
            }
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var fileOpError: Error?
        coordinator.coordinate(writingItemAt: finalURL, options: .forReplacing, error: &coordinationError) { targetURL in
            do {
                if fm.fileExists(atPath: targetURL.path) {
                    try fm.removeItem(at: targetURL)
                }
                if removeSource && !isUbiquitous {
                    do {
                        try fm.moveItem(at: stagedURL, to: targetURL)
                        return
                    } catch {
                        // Cross-volume or FileProvider boundary -> copy + cleanup below.
                    }
                }
                try fm.copyItem(at: stagedURL, to: targetURL)
                if removeSource {
                    try? fm.removeItem(at: stagedURL)
                }
            } catch {
                fileOpError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let fileOpError { throw fileOpError }
        return finalURL
    }

    /// Removes a file using `NSFileCoordinator` when residing inside a Custom Save Folder / FileProvider.
    public static func coordinatedRemoveItem(at url: URL) {
        let fm = FileManager.default
        guard isUsingCustomDownloadsFolder || fm.isUbiquitousItem(at: url) else {
            try? fm.removeItem(at: url)
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { target in
            try? fm.removeItem(at: target)
        }
    }

    /// Renames/moves a file using `NSFileCoordinator` when residing inside a Custom Save Folder / FileProvider.
    public static func coordinatedRenameItem(from sourceURL: URL, to targetURL: URL) throws {
        let fm = FileManager.default
        guard isUsingCustomDownloadsFolder || fm.isUbiquitousItem(at: sourceURL) else {
            try fm.moveItem(at: sourceURL, to: targetURL)
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var moveError: Error?
        coordinator.coordinate(
            writingItemAt: sourceURL,
            options: .forMoving,
            writingItemAt: targetURL,
            options: .forReplacing,
            error: &coordError
        ) { src, dst in
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                moveError = error
            }
        }
        if let coordError { throw coordError }
        if let moveError { throw moveError }
    }

    /// Legacy `Documents/Vault` fallback directory for files downloaded prior to the `Downloads/` standardization.
    public static var legacyVaultDirectory: URL {
        documentsDirectory.appendingPathComponent("Vault", isDirectory: true)
    }

    private static let cachedStagingDirectory: URL = {
        persistentSubdirectory(named: "Staging", excludeFromiCloudBackup: true)
    }()

    public static var stagingDirectory: URL {
        cachedStagingDirectory
    }

    public static var stateDatabaseURL: URL {
        let dbDir = persistentSubdirectory(named: "Database", excludeFromiCloudBackup: false)
        return dbDir.appendingPathComponent("dysprosium_state.sqlite3")
    }

    public static var writablePythonPackagesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = appSupport.appendingPathComponent("python-packages", isDirectory: true)
        ensureDirectory(url, excludeFromiCloudBackup: true)
        return url
    }

    /// Returns whether `URLResourceValues.isExcludedFromBackup` is active on both `downloadsDirectory` and `stagingDirectory`.
    public static var isBackupExclusionActive: Bool {
        let downloadsURL = downloadsDirectory
        let stagingURL = stagingDirectory
        let downloadsExcluded = (try? downloadsURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
        let stagingExcluded = (try? stagingURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
        return downloadsExcluded && stagingExcluded
    }

    /// Scans the active downloads directory directly on disk, filtering out hidden metadata files (`.DS_Store`)
    /// so files added, renamed, or managed externally in iOS Files.app are always reflected in the in-app Downloads tab.
    /// When a user-chosen Custom Save Folder is active, scans ONLY that single source of truth (zero legacy duplicates).
    public static func scanDownloadedFiles() -> [DownloadedVaultItem] {
        let fm = FileManager.default
        var directoriesToScan: [URL] = [downloadsDirectory]
        if !isUsingCustomDownloadsFolder {
            if isRunningInLiveContainer {
                if let sharedRoot = hostSharedAppGroupURL {
                    let sharedDownloads = sharedRoot
                        .appendingPathComponent("Documents", isDirectory: true)
                        .appendingPathComponent("Dysprosium", isDirectory: true)
                        .appendingPathComponent("Downloads", isDirectory: true)
                    if fm.fileExists(atPath: sharedDownloads.path),
                       !directoriesToScan.contains(where: { $0.standardizedFileURL.path == sharedDownloads.standardizedFileURL.path }) {
                        directoriesToScan.append(sharedDownloads)
                    }
                }
                if let hostRoot = resolveLiveContainerHostRoot() {
                    let hostDownloads = hostRoot
                        .appendingPathComponent("Documents", isDirectory: true)
                        .appendingPathComponent("Dysprosium", isDirectory: true)
                        .appendingPathComponent("Downloads", isDirectory: true)
                    if fm.fileExists(atPath: hostDownloads.path),
                       !directoriesToScan.contains(where: { $0.standardizedFileURL.path == hostDownloads.standardizedFileURL.path }) {
                        directoriesToScan.append(hostDownloads)
                    }
                }
            }
            let legacy = legacyVaultDirectory
            if fm.fileExists(atPath: legacy.path),
               !directoriesToScan.contains(where: { $0.standardizedFileURL.path == legacy.standardizedFileURL.path }) {
                directoriesToScan.append(legacy)
            }
        }

        var seenCanonicalPaths = Set<String>()
        var seenFilenames = Set<String>()
        var results: [DownloadedVaultItem] = []

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey
        ]

        for folder in directoriesToScan {
            guard let urls = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for fileURL in urls {
                let filename = fileURL.lastPathComponent
                guard !filename.isEmpty,
                      filename != ".DS_Store",
                      !filename.hasPrefix(".") else {
                    continue
                }

                let canonicalPath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                guard !seenCanonicalPaths.contains(canonicalPath),
                      !seenFilenames.contains(filename) else {
                    continue
                }

                let values = try? fileURL.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    continue
                }

                let byteSize: Int64
                if let size = values?.fileSize {
                    byteSize = Int64(size)
                } else if let attrSize = (try? fm.attributesOfItem(atPath: fileURL.path)[.size]) as? Int64 {
                    byteSize = attrSize
                } else {
                    byteSize = 0
                }

                let modifiedAt = values?.contentModificationDate
                    ?? values?.creationDate
                    ?? ((try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date)
                    ?? Date.distantPast

                seenCanonicalPaths.insert(canonicalPath)
                seenFilenames.insert(filename)

                results.append(
                    DownloadedVaultItem(
                        id: canonicalPath,
                        fileURL: fileURL,
                        filename: filename,
                        byteSize: byteSize,
                        modifiedAt: modifiedAt
                    )
                )
            }
        }

        return results.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
    }

    /// Marks an open file and its SQLite WAL/SHM companions safe to hold locks across iOS suspension,
    /// matching LiveContainer's `Dead10ccFix.m` (`com.apple.runningboard.can-suspend-locked`).
    public static func applySuspendLockedProtection(at path: String) {
        let candidates = [path, path + "-wal", path + "-shm"]
        var flag: UInt8 = 1
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            _ = candidate.withCString { cPath in
                setxattr(cPath, "com.apple.runningboard.can-suspend-locked", &flag, MemoryLayout<UInt8>.size, 0, 0)
            }
        }
    }

    // MARK: - Internal Helpers

    private static func migrateStandardDefaultsIfNeeded(into suite: UserDefaults) {
        guard !suite.bool(forKey: sharedDefaultsMigrationSentinelKey) else { return }
        let standard = UserDefaults.standard
        // Preserve per-host WebKit WKContentRuleListStore compilation caches in `.standard`.
        let excludedSubstrings = [
            "compiledSignature",
            "compiledChunkCount",
            "compiledRuleTotal",
            "compiledList"
        ]
        for (key, value) in standard.dictionaryRepresentation() {
            guard key.hasPrefix("dysprosium."),
                  !excludedSubstrings.contains(where: { key.contains($0) }),
                  suite.object(forKey: key) == nil else {
                continue
            }
            suite.set(value, forKey: key)
        }
        suite.set(true, forKey: sharedDefaultsMigrationSentinelKey)
    }

    private static func ensureDirectory(_ url: URL, excludeFromiCloudBackup: Bool) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if excludeFromiCloudBackup {
            excludeFromBackup(url)
        }
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)
    }

    /// Ensures `<documentsDirectory>/Downloads` points to the promoted LiveContainer host `Downloads` directory
    /// so both guest-local and host-level Files.app paths resolve to the exact same directory.
    private static func ensureGuestDownloadsSymlink(at guestLocalURL: URL, pointingTo promotedURL: URL) {
        let fm = FileManager.default
        let guestPath = guestLocalURL.path
        let promotedPath = promotedURL.standardizedFileURL.path
        guard guestLocalURL.standardizedFileURL.path != promotedPath else { return }

        if let attrs = try? fm.attributesOfItem(atPath: guestPath),
           let fileType = attrs[.type] as? FileAttributeType {
            if fileType == .typeSymbolicLink {
                if let dest = try? fm.destinationOfSymbolicLink(atPath: guestPath),
                   URL(fileURLWithPath: dest).standardizedFileURL.path == promotedPath {
                    return
                }
                try? fm.removeItem(at: guestLocalURL)
            } else if fileType == .typeDirectory {
                let existingItems = (try? fm.contentsOfDirectory(atPath: guestPath))?.filter { $0 != ".DS_Store" } ?? []
                if existingItems.isEmpty {
                    try? fm.removeItem(at: guestLocalURL)
                } else {
                    return
                }
            }
        }

        try? fm.createSymbolicLink(at: guestLocalURL, withDestinationURL: promotedURL)
    }

    private static func ensureFilesAppVisibilityMarker() {
        let marker = documentsDirectory.appendingPathComponent("README.txt")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let note = """
        Dysprosium Storage

        Downloads/ — Completed multi-lane downloads and remuxed media streams.
         Excluded from iCloud Backup automatically so large video files never consume cloud quota.
        """
        try? note.write(to: marker, atomically: true, encoding: .utf8)
        excludeFromBackup(marker)
    }
}
