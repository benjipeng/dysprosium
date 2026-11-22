import Foundation
import Observation
import UIKit

/// Central orchestrator coordinating simultaneous transfers across Control, Data, and Post-Processing planes.
@Observable
@MainActor
public final class TransferScheduler {
    public static let defaultLanesDefaultsKey = "dysprosium.transport.defaultLanesPerTransfer"

    public private(set) var jobs: [TransferJob] = [] {
        didSet {
            let nextActive = jobs.reduce(0) { $0 + ($1.lifecycle.isActive ? 1 : 0) }
            if nextActive != activeTransferCount {
                activeTransferCount = nextActive
            }
            let nextCompleted = jobs.reduce(0) { $0 + ($1.lifecycle == .completed ? 1 : 0) }
            if nextCompleted != completedJobCount {
                completedJobCount = nextCompleted
            }
        }
    }
    public private(set) var activeTransferCount: Int = 0
    public private(set) var completedJobCount: Int = 0
    public var maxConcurrentTransfers: Int = 3 {
        didSet { pumpQueue() }
    }
    public var defaultLanesPerTransfer: Int = TransferScheduler.loadPersistedDefaultLanes() {
        didSet {
            let clamped = max(1, min(defaultLanesPerTransfer, 32))
            if clamped != defaultLanesPerTransfer {
                defaultLanesPerTransfer = clamped
                return
            }
            LiveContainerEnvironment.sharedDefaults.set(clamped, forKey: Self.defaultLanesDefaultsKey)
        }
    }

    private let store: TransferStore?
    private let resolver: MediaResolver
    private let rangeEngine: RangeTransferEngine
    private let hlsEngine: HLSStreamEngine
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var speedTrackers: [UUID: ThroughputMeter] = [:]
    private var activeRunStartedAt: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored
    nonisolated(unsafe) private var foregroundObserverToken: NSObjectProtocol?

    public init(
        store: TransferStore? = try? TransferStore(),
        resolver: MediaResolver? = nil,
        rangeEngine: RangeTransferEngine = RangeTransferEngine(),
        hlsEngine: HLSStreamEngine = HLSStreamEngine()
    ) {
        self.store = store
        self.rangeEngine = rangeEngine
        self.resolver = resolver ?? MediaResolver(rangeEngine: rangeEngine)
        self.hlsEngine = hlsEngine

        self.foregroundObserverToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let sharedLanes = Self.loadPersistedDefaultLanes()
                if self.defaultLanesPerTransfer != sharedLanes {
                    self.defaultLanesPerTransfer = sharedLanes
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            if let loaded = await self.store?.loadAllJobs(), !loaded.isEmpty {
                let currentIDs = Set(self.jobs.map(\.id))
                let additional = loaded.filter { !currentIDs.contains($0.id) }
                self.jobs.append(contentsOf: additional)
            }
            self.pumpQueue()
            let protectedIDs = self.resumableTransferIDs
            Task.detached(priority: .utility) {
                _ = LiveContainerEnvironment.reclaimOrphanedTemporaryFiles(activeTransferIDs: protectedIDs)
            }
        }
    }

    deinit {
        if let token = foregroundObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private static func loadPersistedDefaultLanes() -> Int {
        let saved = LiveContainerEnvironment.sharedDefaults.integer(forKey: defaultLanesDefaultsKey)
        return (1...32).contains(saved) ? saved : 8
    }

    /// Job IDs whose staging files must be retained across orphaned-staging sweeps.
    private var resumableTransferIDs: Set<UUID> {
        Set(
            jobs.compactMap { job in
                (job.lifecycle.isActive || job.lifecycle == .queued || job.lifecycle == .paused)
                    ? job.id
                    : nil
            }
        )
    }

    // MARK: - Computed Telemetry

    public var aggregateSpeedBytesPerSec: Double {
        jobs.reduce(0) { $0 + ($1.lifecycle == .downloading ? $1.speedBytesPerSec : 0) }
    }

    public var totalActiveLanes: Int {
        jobs.reduce(0) { $0 + ($1.lifecycle == .downloading ? $1.activeLanes : 0) }
    }

    public var completedJobs: [TransferJob] {
        jobs.filter { $0.lifecycle == .completed }
    }

    public func runtimeSummary() async -> RuntimeProbeSummary {
        let ffmpeg = await FFmpegMuxActor.shared.isFFmpegFrameworkPresent
        return RuntimeProbeSummary(
            isLiveContainerGuest: LiveContainerEnvironment.isRunningInLiveContainer,
            cpythonAvailable: EmbeddedPythonBridge.shared.isAvailable,
            cpythonVersion: EmbeddedPythonBridge.shared.versionString,
            ffmpegAvailable: ffmpeg,
            quickJSAvailable: FileManager.default.fileExists(
                atPath: Bundle.main.bundleURL.appendingPathComponent("Frameworks/QuickJS").path
            ),
            silentAudioActive: SilentAudioKeepAlive.shared.isActive
        )
    }

    /// Scrubs `Cookie`/`Authorization` headers from in-memory and persisted transfer records,
    /// compacts/truncates `dysprosium_state.sqlite3`, and reclaims orphaned staging files.
    public func scrubPersistedAuthDataAndOrphanedStaging() {
        for idx in jobs.indices {
            let scrubbed = jobs[idx].strippingAuthHeaders()
            if scrubbed != jobs[idx] {
                jobs[idx] = scrubbed
            }
        }
        let storeRef = self.store
        let protectedIDs = self.resumableTransferIDs
        Task.detached(priority: .utility) {
            await storeRef?.scrubStoredAuthHeaders()
            await storeRef?.reclaimStorage()
            _ = LiveContainerEnvironment.reclaimOrphanedTemporaryFiles(activeTransferIDs: protectedIDs)
        }
    }

    // MARK: - Intake & Queue Control

    @discardableResult
    public func enqueue(
        url: URL,
        sourcePageURL: URL? = nil,
        pairedAudioURL: URL? = nil,
        pairedAudioBytes: Int64? = nil,
        expectedTotalBytes: Int64? = nil,
        siteDomainOverride: String? = nil,
        lanes: Int? = nil,
        headers: [String: String] = [:],
        suggestedTitle: String? = nil,
        preloadedManifestText: String? = nil
    ) -> TransferJob {
        let configuredLanes = lanes ?? defaultLanesPerTransfer
        var prebuiltPlan: ResolvedTransferPlan?
        var resolvedKind: TransferKind = .directRange
        let normalizedFallbackDomain: String = {
            let norm = url.host().map(LiveContainerEnvironment.HostNormalizer.normalize)
            return (norm?.isEmpty == false ? norm : nil) ?? "remote"
        }()

        if let audioURL = pairedAudioURL {
            let cleanTitle: String = {
                guard let suggestedTitle, !suggestedTitle.isEmpty else { return "video.mp4" }
                return suggestedTitle.hasSuffix(".mp4") ? suggestedTitle : "\(suggestedTitle).mp4"
            }()
            let videoBytes: Int64? = {
                guard let total = expectedTotalBytes, let aBytes = pairedAudioBytes, total > aBytes else { return nil }
                return total - aBytes
            }()
            let domain = siteDomainOverride ?? normalizedFallbackDomain

            let audioHeaders = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
                from: headers,
                sourceURL: url,
                destinationURL: audioURL
            )
            let videoTrack = ResolvedTrackDescriptor(
                role: .videoOnly,
                remoteURL: url,
                headers: headers,
                expectedBytes: videoBytes,
                supportsByteRanges: true,
                isHLSManifest: false,
                fileExtension: "mp4"
            )
            let audioTrack = ResolvedTrackDescriptor(
                role: .audioOnly,
                remoteURL: audioURL,
                headers: audioHeaders,
                expectedBytes: pairedAudioBytes,
                supportsByteRanges: true,
                isHLSManifest: false,
                fileExtension: "m4a"
            )
            prebuiltPlan = ResolvedTransferPlan(
                sourceURL: url,
                title: cleanTitle,
                siteDomain: domain,
                kind: .directRange,
                tracks: [videoTrack, audioTrack],
                outputFilename: cleanTitle,
                requiresMuxing: true
            )
            resolvedKind = .directRange
        } else if let manifest = preloadedManifestText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  manifest.hasPrefix("#EXTM3U") {
            let cleanTitle: String = {
                guard let suggestedTitle, !suggestedTitle.isEmpty else { return "video.mp4" }
                return suggestedTitle.hasSuffix(".mp4") ? suggestedTitle : "\(suggestedTitle).mp4"
            }()
            let domain = siteDomainOverride ?? normalizedFallbackDomain
            let hlsTrack = ResolvedTrackDescriptor(
                role: .primary,
                remoteURL: url,
                headers: headers,
                expectedBytes: expectedTotalBytes,
                supportsByteRanges: false,
                isHLSManifest: true,
                fileExtension: "ts",
                preloadedManifestText: manifest
            )
            prebuiltPlan = ResolvedTransferPlan(
                sourceURL: url,
                title: cleanTitle,
                siteDomain: domain,
                kind: .hlsStream,
                tracks: [hlsTrack],
                outputFilename: cleanTitle,
                requiresMuxing: false
            )
            resolvedKind = .hlsStream
        }

        var job = TransferJob(
            sourceURL: url,
            sourcePageURL: sourcePageURL,
            title: prebuiltPlan?.title ?? suggestedTitle,
            siteDomain: prebuiltPlan?.siteDomain ?? siteDomainOverride,
            kind: resolvedKind,
            configuredLanes: configuredLanes,
            initialHeaders: headers
        )
        job.plan = prebuiltPlan
        job.totalBytes = expectedTotalBytes
        jobs.insert(job, at: 0)
        persist(job)
        pumpQueue()
        return job
    }

    private static func isAllowedEnqueueURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else {
            return false
        }
        return true
    }

    /// Handles external `dysprosium://enqueue?url=...&referer=...&lanes=...` or JSON base64 payloads
    /// from external browsers or automation clients via the `dysprosium://` URL scheme.
    @discardableResult
    public func handleIncomingURL(_ incoming: URL) -> Bool {
        guard incoming.scheme?.lowercased() == "dysprosium" else { return false }
        let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        #if DEBUG
        if incoming.host?.lowercased() == "benchmark" {
            let lanes = queryItems.first(where: { $0.name == "lanes" })?.value.flatMap(Int.init) ?? 16
            let bytes = (queryItems.first(where: { $0.name == "mb" })?.value.flatMap(Int.init) ?? 36) * 1024 * 1024
            Task {
                await LoopbackRangeServer.shared.configureThrottling(everyNth: 3, delayNanoseconds: 35_000_000)
                if let url = try? await LoopbackRangeServer.shared.ensureRunning(sizeBytes: bytes) {
                    _ = self.enqueue(url: url, lanes: lanes)
                }
            }
            return true
        }
        #endif

        if let host = incoming.host?.lowercased(), !host.isEmpty, host != "enqueue" {
            return false
        }

        if let payloadB64 = queryItems.first(where: { $0.name == "payload" })?.value,
           let data = Data(base64Encoded: payloadB64),
           let decoded = try? JSONDecoder().decode(ExternalIntakeRequest.self, from: data) {
            guard Self.isAllowedEnqueueURL(decoded.url) else { return false }
            _ = enqueue(
                url: decoded.url,
                lanes: decoded.preferredLanes,
                headers: decoded.synthesizedHeaders,
                suggestedTitle: decoded.suggestedFilename
            )
            return true
        }

        if let rawTarget = queryItems.first(where: { $0.name == "url" })?.value,
           let targetURL = URL(string: rawTarget) {
            guard Self.isAllowedEnqueueURL(targetURL) else { return false }
            var headers: [String: String] = [:]
            if let ref = queryItems.first(where: { $0.name == "referer" })?.value, !ref.isEmpty {
                headers["Referer"] = ref
            }
            if let ua = queryItems.first(where: { $0.name == "ua" })?.value, !ua.isEmpty {
                headers["User-Agent"] = ua
            }
            if let cookie = queryItems.first(where: { $0.name == "cookie" })?.value, !cookie.isEmpty {
                headers["Cookie"] = cookie
            }
            let lanes = queryItems.first(where: { $0.name == "lanes" })?.value.flatMap(Int.init)
            let name = queryItems.first(where: { $0.name == "filename" })?.value
            _ = enqueue(url: targetURL, lanes: lanes, headers: headers, suggestedTitle: name)
            return true
        }
        return false
    }

    public func pause(id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        speedTrackers[id] = nil
        let runElapsed = consumeActiveRunElapsed(for: id)
        mutateJob(id: id) { job in
            guard job.lifecycle.isActive || job.lifecycle == .queued else { return }
            if runElapsed > 0 {
                job.activeDurationSeconds = (job.activeDurationSeconds ?? 0) + runElapsed
            }
            job.lifecycle = .paused
            job.activeLanes = 0
            job.speedBytesPerSec = 0
            for idx in job.slices.indices {
                job.slices[idx].isActiveLane = false
            }
        }
        syncKeepAlive()
        pumpQueue()
    }

    public func resume(id: UUID) {
        mutateJob(id: id) { job in
            guard job.lifecycle == .paused || job.lifecycle == .failed else { return }
            job.lifecycle = .queued
            job.errorMessage = nil
        }
        pumpQueue()
    }

    public func remove(id: UUID, deleteVaultFile: Bool = false) {
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        speedTrackers[id] = nil
        activeRunStartedAt[id] = nil

        if let existing = jobs.first(where: { $0.id == id }) {
            let stagingDir = LiveContainerEnvironment.stagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: stagingDir)
            if deleteVaultFile, let rel = existing.destinationRelativePath {
                let vaultURL = LiveContainerEnvironment.vaultDirectory.appendingPathComponent(rel)
                LiveContainerEnvironment.coordinatedRemoveItem(at: vaultURL)
            }
        }

        jobs.removeAll { $0.id == id }
        Task { await store?.delete(id: id) }
        syncKeepAlive()
        pumpQueue()
    }

    /// Removes only the local file on disk to reclaim storage while preserving the completed
    /// `TransferJob` record and its transfer insights in SQLite history.
    public func removeLocalFileKeepingHistory(jobID: UUID?, fileURL: URL) {
        LiveContainerEnvironment.coordinatedRemoveItem(at: fileURL)
        if let jobID {
            mutateJob(id: jobID) { job in
                if job.completedAt == nil && job.lifecycle == .completed {
                    job.completedAt = job.updatedAt
                }
            }
        }
    }

    /// Clears completed download history records from SQLite without deleting any on-device files.
    /// - Parameter onlyOffDevice: When `true`, removes only records whose local file has already been
    ///   moved out or deleted; when `false`, clears all completed transfer history records.
    public func clearDownloadHistory(onlyOffDevice: Bool = false) {
        let targets: [TransferJob] = jobs.filter { job in
            guard job.lifecycle == .completed else { return false }
            if onlyOffDevice {
                return vaultFileURL(for: job) == nil
            }
            return true
        }
        guard !targets.isEmpty else { return }
        let removeIDs = Set(targets.map(\.id))
        jobs.removeAll { removeIDs.contains($0.id) }
        Task {
            for id in removeIDs {
                await store?.delete(id: id)
            }
        }
    }

    /// Re-enqueues a fresh transfer from a historical record's original URL, headers, and lane count.
    @discardableResult
    public func redownload(from job: TransferJob) -> TransferJob {
        enqueue(
            url: job.sourceURL,
            sourcePageURL: job.sourcePageURL,
            siteDomainOverride: job.siteDomain,
            lanes: job.configuredLanes,
            headers: job.initialHeaders,
            suggestedTitle: job.title
        )
    }

    /// Looks up a persisted job by identifier (including completed history entries).
    public func job(for id: UUID) -> TransferJob? {
        jobs.first { $0.id == id }
    }

    public func vaultFileURL(for job: TransferJob) -> URL? {
        guard let rel = job.destinationRelativePath else { return nil }
        let primary = LiveContainerEnvironment.downloadsDirectory.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: primary.path) {
            return primary
        }
        let legacy = LiveContainerEnvironment.legacyVaultDirectory.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    public func matchingJob(for sourceURL: URL) -> TransferJob? {
        jobs.first { $0.sourceURL == sourceURL }
    }

    @discardableResult
    public func renameVaultFile(jobID: UUID?, currentFileURL: URL, newBaseOrFullName: String) throws -> URL {
        let cleaned = newBaseOrFullName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return currentFileURL }

        let origExt = currentFileURL.pathExtension
        let finalFilename: String
        if !origExt.isEmpty && (cleaned as NSString).pathExtension.isEmpty {
            finalFilename = "\(cleaned).\(origExt)"
        } else {
            finalFilename = cleaned
        }

        let targetURL = currentFileURL.deletingLastPathComponent().appendingPathComponent(finalFilename, isDirectory: false)
        guard targetURL.standardizedFileURL != currentFileURL.standardizedFileURL else { return currentFileURL }

        try LiveContainerEnvironment.coordinatedRenameItem(from: currentFileURL, to: targetURL)
        if !LiveContainerEnvironment.isUsingCustomDownloadsFolder {
            var mutableTarget = targetURL
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try? mutableTarget.setResourceValues(rv)
        }

        if let jobID {
            mutateJob(id: jobID) { job in
                job.destinationRelativePath = finalFilename
                job.title = finalFilename
            }
        }
        return targetURL
    }

    // MARK: - Internal Pipeline Execution

    private func pumpQueue() {
        while activeTasks.count < maxConcurrentTransfers,
              let nextJob = jobs.last(where: { $0.lifecycle == .queued }) {
            startJob(nextJob.id)
        }
        syncKeepAlive()
    }

    private func startJob(_ id: UUID) {
        guard activeTasks[id] == nil,
              let snapshot = jobs.first(where: { $0.id == id }) else { return }

        mutateJob(id: id) { job in
            let needsManifestResolve = (job.plan == nil) || (job.plan?.kind == .hlsStream && (job.totalSegments ?? 0) == 0)
            job.lifecycle = needsManifestResolve ? .resolving : .downloading
            job.errorMessage = nil
        }
        speedTrackers[id] = ThroughputMeter(initialBytes: snapshot.downloadedBytes)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(for: id)
        }
        activeTasks[id] = task
        syncKeepAlive()
    }

    private static func isExpiredSignedURL403(_ error: Error) -> Bool {
        let nsErr = error as NSError
        guard nsErr.code == 403 else { return false }
        return nsErr.domain == "Dysprosium.HTTP"
            || nsErr.domain == "Dysprosium.Range"
            || nsErr.domain == "Dysprosium.HLS"
    }

    private func runPipeline(for id: UUID) async {
        defer {
            activeTasks[id] = nil
            speedTrackers[id] = nil
            activeRunStartedAt[id] = nil
            syncKeepAlive()
            pumpQueue()
        }

        guard let initial = jobs.first(where: { $0.id == id }) else { return }
        let jobStagingDir = LiveContainerEnvironment.stagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: jobStagingDir, withIntermediateDirectories: true)

        do {
            // Plane 1: Resolve Transfer Plan (reusing persisted plan when resuming)
            let explicitName = initial.title != initial.sourceURL.lastPathComponent ? initial.title : nil
            var plan: ResolvedTransferPlan
            if let existingPlan = initial.plan {
                plan = existingPlan
            } else {
                let resolved = try await resolver.resolve(
                    url: initial.sourceURL,
                    headers: initial.initialHeaders,
                    preferredFilename: explicitName
                )
                plan = resolved
                mutateJob(id: id) { job in
                    job.plan = resolved
                    job.title = resolved.title
                    job.siteDomain = resolved.siteDomain
                    job.kind = resolved.kind
                    job.totalBytes = resolved.tracks.count == 1 ? resolved.tracks.first?.expectedBytes : nil
                    job.lifecycle = resolved.kind == .hlsStream ? .resolving : .downloading
                }
            }

            try Task.checkCancellation()
            mutateJob(id: id) { job in
                let isUnresolvedHLS = plan.kind == .hlsStream && (job.totalSegments ?? 0) == 0
                job.lifecycle = isUnresolvedHLS ? .resolving : .downloading
            }

            // Plane 2: Execute Data Plane per track (with one automatic re-resolve on HTTP 403
            // when `sourcePageURL` is present so expired signed CDN URLs recover seamlessly).
            activeRunStartedAt[id] = ContinuousClock.now
            var resumeSlices: [ByteRangeSlice]? = initial.slices.isEmpty ? nil : initial.slices
            var stagedTrackFiles: [(ResolvedTrackDescriptor.TrackRole, URL)] = []
            var didAttempt403ReResolve = false

            while true {
                do {
                    stagedTrackFiles = try await executeDataPlaneTracks(
                        for: id,
                        initial: initial,
                        plan: plan,
                        jobStagingDir: jobStagingDir,
                        resumeSlices: resumeSlices
                    )
                    break
                } catch {
                    guard !didAttempt403ReResolve,
                          Self.isExpiredSignedURL403(error),
                          let refreshPageURL = initial.sourcePageURL else {
                        throw error
                    }
                    didAttempt403ReResolve = true
                    try Task.checkCancellation()
                    mutateJob(id: id) { job in
                        job.lifecycle = .resolving
                        job.activeLanes = 0
                        job.speedBytesPerSec = 0
                    }

                    let previousETag = plan.etag
                    let refreshHeaders = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
                        from: initial.initialHeaders,
                        sourceURL: initial.sourceURL,
                        destinationURL: refreshPageURL
                    )
                    let refreshed = try await resolver.resolve(
                        url: refreshPageURL,
                        headers: refreshHeaders,
                        preferredFilename: explicitName
                    )
                    let canReuseSlices = (previousETag != nil && refreshed.etag == previousETag)
                        && refreshed.tracks.count == 1
                        && plan.tracks.count == 1
                    if !canReuseSlices {
                        resumeSlices = nil
                        try? FileManager.default.removeItem(at: jobStagingDir)
                        try? FileManager.default.createDirectory(at: jobStagingDir, withIntermediateDirectories: true)
                    }
                    plan = refreshed
                    mutateJob(id: id) { job in
                        job.plan = refreshed
                        job.kind = refreshed.kind
                        job.totalBytes = refreshed.tracks.count == 1 ? refreshed.tracks.first?.expectedBytes : nil
                        if !canReuseSlices {
                            job.slices = []
                            job.downloadedBytes = 0
                            job.completedSegments = 0
                            job.totalSegments = nil
                        }
                        job.lifecycle = refreshed.kind == .hlsStream ? .resolving : .downloading
                    }
                    speedTrackers[id] = ThroughputMeter(initialBytes: canReuseSlices ? (jobs.first(where: { $0.id == id })?.downloadedBytes ?? 0) : 0)
                }
            }

            try Task.checkCancellation()
            let dataPlaneElapsed = consumeActiveRunElapsed(for: id)

            // Plane 3: Post-Processing / Atomic Vault Commit
            // Always perform FFmpeg C-API muxing inside fast local `jobStagingDir` first so
            // external FileProvider / iCloud Drive Custom Save Folders only ever see completed atomic commits.
            let finalVaultURL: URL

            if plan.requiresMuxing,
               let videoEntry = stagedTrackFiles.first(where: { $0.0 == .videoOnly }),
               let audioEntry = stagedTrackFiles.first(where: { $0.0 == .audioOnly }) {
                mutateJob(id: id) {
                    if dataPlaneElapsed > 0 {
                        $0.activeDurationSeconds = ($0.activeDurationSeconds ?? 0) + dataPlaneElapsed
                    }
                    $0.lifecycle = .muxing
                    $0.activeLanes = 0
                    $0.speedBytesPerSec = 0
                }
                let stagedMuxOutput = jobStagingDir.appendingPathComponent("muxed-\(UUID().uuidString.prefix(8)).mp4")
                try await FFmpegMuxActor.shared.remux(
                    videoURL: videoEntry.1,
                    audioURL: audioEntry.1,
                    destinationURL: stagedMuxOutput
                )
                finalVaultURL = try LiveContainerEnvironment.commitStagedFile(
                    from: stagedMuxOutput,
                    toDirectory: LiveContainerEnvironment.downloadsDirectory,
                    preferredFilename: plan.outputFilename,
                    removeSource: true
                )
            } else if plan.kind == .hlsStream, let primary = stagedTrackFiles.first?.1 {
                mutateJob(id: id) {
                    if dataPlaneElapsed > 0 {
                        $0.activeDurationSeconds = ($0.activeDurationSeconds ?? 0) + dataPlaneElapsed
                    }
                    $0.lifecycle = .muxing
                    $0.activeLanes = 0
                    $0.speedBytesPerSec = 0
                }
                let stagedMuxOutput = jobStagingDir.appendingPathComponent("remuxed-\(UUID().uuidString.prefix(8)).mp4")
                try await FFmpegMuxActor.shared.remuxSingleStreamToMP4(
                    sourceURL: primary,
                    destinationURL: stagedMuxOutput
                )
                finalVaultURL = try LiveContainerEnvironment.commitStagedFile(
                    from: stagedMuxOutput,
                    toDirectory: LiveContainerEnvironment.downloadsDirectory,
                    preferredFilename: plan.outputFilename,
                    removeSource: true
                )
            } else if let primary = stagedTrackFiles.first?.1 {
                finalVaultURL = try LiveContainerEnvironment.commitStagedFile(
                    from: primary,
                    toDirectory: LiveContainerEnvironment.downloadsDirectory,
                    preferredFilename: plan.outputFilename,
                    removeSource: true
                )
            } else {
                let fallbackName = uniqueVaultFilename(desired: plan.outputFilename)
                finalVaultURL = LiveContainerEnvironment.downloadsDirectory.appendingPathComponent(fallbackName)
            }
            let finalFilename = finalVaultURL.lastPathComponent

            try? FileManager.default.removeItem(at: jobStagingDir)
            let committedSize = (try? FileManager.default.attributesOfItem(atPath: finalVaultURL.path)[.size] as? Int64)
            let completedNow = Date()
            let muxingAlreadyAccumulated = plan.requiresMuxing || plan.kind == .hlsStream

            mutateJob(id: id) { job in
                if !muxingAlreadyAccumulated && dataPlaneElapsed > 0 {
                    job.activeDurationSeconds = (job.activeDurationSeconds ?? 0) + dataPlaneElapsed
                }
                let finalBytes = (committedSize ?? 0) > 0 ? committedSize! : job.downloadedBytes
                let totalActiveSec = max(job.activeDurationSeconds ?? completedNow.timeIntervalSince(job.createdAt), 0.05)
                let avgSpeed = finalBytes > 0 ? Double(finalBytes) / totalActiveSec : 0
                let peakSpeed = max(job.peakSpeedBytesPerSec ?? 0, job.throughputSamples.max() ?? 0, avgSpeed)

                job.lifecycle = .completed
                job.activeLanes = 0
                job.speedBytesPerSec = 0
                job.completedAt = completedNow
                job.activeDurationSeconds = totalActiveSec
                job.averageSpeedBytesPerSec = avgSpeed > 0 ? avgSpeed : nil
                job.peakSpeedBytesPerSec = peakSpeed > 0 ? peakSpeed : nil
                if job.throughputSamples.isEmpty && avgSpeed > 0 {
                    job.throughputSamples = [avgSpeed, peakSpeed]
                }
                if let committedSize, committedSize > 0 {
                    job.downloadedBytes = committedSize
                    job.totalBytes = committedSize
                }
                job.destinationRelativePath = finalFilename
                // Automatically scrub sensitive Cookie/Authorization headers on completion before persisting.
                job = job.strippingAuthHeaders()
            }
        } catch is CancellationError {
            // Pause/remove already transitioned state cleanly.
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            // Cancelled URLSession task during pause.
        } catch {
            let runElapsed = consumeActiveRunElapsed(for: id)
            mutateJob(id: id) { job in
                guard job.lifecycle != .paused else { return }
                if runElapsed > 0 {
                    job.activeDurationSeconds = (job.activeDurationSeconds ?? 0) + runElapsed
                }
                job.lifecycle = .failed
                job.activeLanes = 0
                job.speedBytesPerSec = 0
                job.errorMessage = error.localizedDescription
            }
        }
    }

    private func executeDataPlaneTracks(
        for id: UUID,
        initial: TransferJob,
        plan: ResolvedTransferPlan,
        jobStagingDir: URL,
        resumeSlices: [ByteRangeSlice]?
    ) async throws -> [(ResolvedTrackDescriptor.TrackRole, URL)] {
        var stagedTrackFiles: [(ResolvedTrackDescriptor.TrackRole, URL)] = []
        let isMultiTrack = plan.tracks.count > 1
        let aggregateExpectedBytes: Int64? = {
            let sizes = plan.tracks.compactMap(\.expectedBytes)
            return sizes.count == plan.tracks.count ? sizes.reduce(0, +) : initial.totalBytes
        }()
        let ifRangeValidator = RangeTransferEngine.resolveIfRangeValidator(
            etag: plan.etag,
            lastModified: plan.lastModified
        )
        var completedTracksBytes: Int64 = 0

        for (trackIdx, track) in plan.tracks.enumerated() {
            try Task.checkCancellation()
            let stagedFile = jobStagingDir.appendingPathComponent("track-\(trackIdx).\(track.fileExtension)")
            // Treat `track.headers` as the complete, destination-scoped header set produced by
            // `MediaResolver` or `enqueue(...)` so credentials stripped across redirects are never
            // re-introduced from `initial.initialHeaders`.
            let trackHeaders = track.headers
            let baseOffset = completedTracksBytes

            if track.isHLSManifest {
                let finalHLS = try await hlsEngine.downloadPlaylist(
                    manifestURL: track.remoteURL,
                    headers: trackHeaders,
                    destinationURL: stagedFile,
                    concurrency: initial.configuredLanes,
                    preloadedManifestText: track.preloadedManifestText
                ) { [weak self] prog in
                    Task { @MainActor [weak self] in
                        self?.applyHLSProgress(id: id, update: prog)
                    }
                }
                applyHLSProgress(id: id, update: finalHLS)
                completedTracksBytes += finalHLS.downloadedBytes
            } else {
                let cfg = RangeEngineConfiguration(maxLanes: initial.configuredLanes)
                let finalRange = try await rangeEngine.download(
                    url: track.remoteURL,
                    headers: trackHeaders,
                    destinationURL: stagedFile,
                    knownTotalBytes: track.expectedBytes,
                    supportsRangesHint: track.supportsByteRanges,
                    existingSlices: (!isMultiTrack && trackIdx == 0) ? resumeSlices : nil,
                    ifRangeValidator: (!isMultiTrack && trackIdx == 0) ? ifRangeValidator : nil,
                    configuration: cfg
                ) { [weak self] prog in
                    let adjusted = isMultiTrack
                        ? RangeProgressUpdate(
                            downloadedBytes: baseOffset + prog.downloadedBytes,
                            totalBytes: aggregateExpectedBytes,
                            activeLanes: prog.activeLanes,
                            slices: trackIdx == 0 ? prog.slices : []
                        )
                        : prog
                    Task { @MainActor [weak self] in
                        self?.applyRangeProgress(id: id, update: adjusted)
                    }
                }
                let adjustedFinal = isMultiTrack
                    ? RangeProgressUpdate(
                        downloadedBytes: baseOffset + finalRange.downloadedBytes,
                        totalBytes: aggregateExpectedBytes,
                        activeLanes: finalRange.activeLanes,
                        slices: trackIdx == 0 ? finalRange.slices : []
                    )
                    : finalRange
                applyRangeProgress(id: id, update: adjustedFinal)
                completedTracksBytes += finalRange.downloadedBytes
            }
            stagedTrackFiles.append((track.role, stagedFile))
        }

        return stagedTrackFiles
    }

    private func consumeActiveRunElapsed(for id: UUID) -> Double {
        guard let started = activeRunStartedAt.removeValue(forKey: id) else { return 0 }
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return max(0, seconds)
    }

    private func applyRangeProgress(id: UUID, update: RangeProgressUpdate) {
        let isTerminal = update.totalBytes.map { update.downloadedBytes >= $0 } ?? false
        guard let measurement = speedTrackers[id]?.record(totalBytesNow: update.downloadedBytes, force: isTerminal) else {
            return
        }
        mutateJob(id: id, persistImmediately: measurement.shouldPersist || isTerminal) { job in
            guard job.lifecycle == .downloading else { return }
            job.downloadedBytes = update.downloadedBytes
            job.totalBytes = update.totalBytes ?? job.totalBytes
            job.activeLanes = update.activeLanes
            job.slices = update.slices
            job.speedBytesPerSec = measurement.emaBytesPerSec
            if measurement.emaBytesPerSec > (job.peakSpeedBytesPerSec ?? 0) {
                job.peakSpeedBytesPerSec = measurement.emaBytesPerSec
            }
            if measurement.didSampleSparkline {
                job.throughputSamples.append(measurement.emaBytesPerSec)
                if job.throughputSamples.count > 36 {
                    job.throughputSamples.removeFirst(job.throughputSamples.count - 36)
                }
            }
        }
    }

    private func applyHLSProgress(id: UUID, update: HLSProgressUpdate) {
        let isTerminal = update.totalSegments > 0 && update.completedSegments >= update.totalSegments
        let isInitialConnect = update.completedSegments == 0 && update.totalSegments > 0 && update.activeLanes > 0
        guard let measurement = speedTrackers[id]?.record(totalBytesNow: update.downloadedBytes, force: isTerminal || isInitialConnect) else {
            return
        }
        mutateJob(id: id, persistImmediately: measurement.shouldPersist || isTerminal || isInitialConnect) { job in
            guard job.lifecycle == .downloading || job.lifecycle == .resolving else { return }
            if job.lifecycle == .resolving {
                job.lifecycle = .downloading
            }
            job.completedSegments = update.completedSegments
            job.totalSegments = update.totalSegments
            job.downloadedBytes = update.downloadedBytes
            job.activeLanes = update.activeLanes
            job.speedBytesPerSec = measurement.emaBytesPerSec
            if measurement.emaBytesPerSec > (job.peakSpeedBytesPerSec ?? 0) {
                job.peakSpeedBytesPerSec = measurement.emaBytesPerSec
            }
            if measurement.didSampleSparkline {
                job.throughputSamples.append(measurement.emaBytesPerSec)
                if job.throughputSamples.count > 36 {
                    job.throughputSamples.removeFirst(job.throughputSamples.count - 36)
                }
            }
        }
    }

    private func mutateJob(id: UUID, persistImmediately: Bool = true, _ transform: (inout TransferJob) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        transform(&jobs[idx])
        jobs[idx].updatedAt = Date()
        if persistImmediately {
            persist(jobs[idx])
        }
    }

    private func persist(_ job: TransferJob) {
        guard let store else { return }
        Task { await store.upsert(job) }
    }

    private func syncKeepAlive() {
        let needsAudio = jobs.contains(where: \.lifecycle.isActive)
        SilentAudioKeepAlive.shared.setRequired(needsAudio)
    }

    private func uniqueVaultFilename(desired: String) -> String {
        let vault = LiveContainerEnvironment.vaultDirectory
        let nsName = desired as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var candidate = desired
        var counter = 2
        while FileManager.default.fileExists(atPath: vault.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            counter += 1
        }
        return candidate
    }
}

private struct ThroughputMeter {
    struct Sample {
        let emaBytesPerSec: Double
        let didSampleSparkline: Bool
        let shouldPersist: Bool
    }

    private var lastBytes: Int64
    private var lastTick: ContinuousClock.Instant
    private var lastSparklineTick: ContinuousClock.Instant
    private var lastPersistTick: ContinuousClock.Instant
    private var ema: Double = 0

    init(initialBytes: Int64) {
        let now = ContinuousClock.now
        self.lastBytes = initialBytes
        self.lastTick = now
        self.lastSparklineTick = now
        self.lastPersistTick = now
    }

    mutating func record(totalBytesNow: Int64, force: Bool = false) -> Sample? {
        let now = ContinuousClock.now
        let elapsed = now - lastTick
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard force || seconds >= 0.22 else { return nil }

        let safeSeconds = max(seconds, 0.001)
        let delta = max(0, totalBytesNow - lastBytes)
        let instant = Double(delta) / safeSeconds
        ema = ema == 0 ? instant : (0.35 * instant + 0.65 * ema)
        lastBytes = totalBytesNow
        lastTick = now

        let sparkElapsed = now - lastSparklineTick
        let sparkSec = Double(sparkElapsed.components.seconds) + Double(sparkElapsed.components.attoseconds) / 1e18
        let didSpark = sparkSec >= 0.5
        if didSpark { lastSparklineTick = now }

        let persistElapsed = now - lastPersistTick
        let persistSec = Double(persistElapsed.components.seconds) + Double(persistElapsed.components.attoseconds) / 1e18
        let shouldPersist = persistSec >= 3.0
        if shouldPersist { lastPersistTick = now }

        return Sample(emaBytesPerSec: ema, didSampleSparkline: didSpark, shouldPersist: shouldPersist)
    }
}
