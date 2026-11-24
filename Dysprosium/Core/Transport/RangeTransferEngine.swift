import Foundation

public struct RangeProbeResult: Sendable {
    public let finalURL: URL
    public let totalBytes: Int64?
    public let supportsByteRanges: Bool
    public let suggestedFilename: String?
    public let etag: String?
    public let lastModified: String?
    public let mimeType: String?
}

public struct RangeEngineConfiguration: Sendable {
    public var maxLanes: Int
    /// Maximum byte span per individual HTTP Range request (~9.0 MiB defeats CDN single-range throttling).
    public var maxWindowBytes: Int64
    /// Minimum remaining bytes on a straggler slice before an idle lane steals its back half.
    public var minimumStealBytes: Int64

    public init(
        maxLanes: Int = 8,
        maxWindowBytes: Int64 = 9 * 1024 * 1024,
        minimumStealBytes: Int64 = 1024 * 1024
    ) {
        self.maxLanes = max(1, min(maxLanes, 32))
        self.maxWindowBytes = max(64 * 1024, maxWindowBytes)
        self.minimumStealBytes = max(64 * 1024, minimumStealBytes)
    }
}

public struct RangeProgressUpdate: Sendable {
    public let downloadedBytes: Int64
    public let totalBytes: Int64?
    public let activeLanes: Int
    public let slices: [ByteRangeSlice]
}

public enum RangeTransferError: LocalizedError, Sendable {
    case remoteResourceModified

    public var errorDescription: String? {
        switch self {
        case .remoteResourceModified:
            return L("Remote file changed since the transfer was paused; restarting from the beginning.")
        }
    }
}

/// Shared `URLSessionTaskDelegate` that strips `Cookie`, `Authorization`, and `Proxy-Authorization`
/// headers whenever an HTTP 3xx redirect crosses scheme, host, or port boundaries.
final class CrossOriginRedirectAuthStripper: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = CrossOriginRedirectAuthStripper()

    private static let authHeaderNames: Set<String> = [
        "cookie",
        "authorization",
        "proxy-authorization"
    ]

    static func isSameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs,
              let s1 = lhs.scheme?.lowercased(), let s2 = rhs.scheme?.lowercased(), s1 == s2,
              let h1 = lhs.host()?.lowercased(), let h2 = rhs.host()?.lowercased(), h1 == h2 else {
            return false
        }
        let p1 = lhs.port ?? defaultPort(forScheme: s1)
        let p2 = rhs.port ?? defaultPort(forScheme: s2)
        return p1 == p2
    }

    private static func defaultPort(forScheme scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    static func sanitizedRedirectRequest(from sourceURL: URL?, to request: URLRequest) -> URLRequest {
        guard !isSameOrigin(sourceURL, request.url) else {
            return request
        }
        var sanitized = request
        if let headers = sanitized.allHTTPHeaderFields {
            for key in headers.keys where authHeaderNames.contains(key.lowercased()) {
                sanitized.setValue(nil, forHTTPHeaderField: key)
            }
        }
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        if sourceURL?.scheme?.lowercased() == "https",
           request.url?.scheme?.lowercased() == "http" {
            sanitized.setValue(nil, forHTTPHeaderField: "Referer")
            sanitized.setValue(nil, forHTTPHeaderField: "Origin")
        }
        return sanitized
    }

    /// Strips origin-bound credentials (`Cookie`, `Authorization`, `Proxy-Authorization`, plus
    /// `Referer`/`Origin` on HTTPS -> HTTP downgrades) whenever `destinationURL` crosses origins.
    static func stripCrossOriginAuthHeaders(
        from headers: [String: String],
        sourceURL: URL?,
        destinationURL: URL?
    ) -> [String: String] {
        guard !isSameOrigin(sourceURL, destinationURL) else {
            return headers
        }
        let isHTTPSDowngrade = (sourceURL?.scheme?.lowercased() == "https")
            && (destinationURL?.scheme?.lowercased() == "http")
        return headers.filter { key, _ in
            let lower = key.lowercased()
            if authHeaderNames.contains(lower) {
                return false
            }
            if isHTTPSDowngrade && (lower == "referer" || lower == "origin") {
                return false
            }
            return true
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originURL = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url
        completionHandler(Self.sanitizedRedirectRequest(from: originURL, to: request))
    }
}

/// Thread-safe byte-slice state machine supporting concurrent clamping and midpoint work-stealing.
final class SliceCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var slices: [ByteRangeSlice]
    private let minimumStealBytes: Int64
    private var nextSliceID: Int
    private var lastProgressReport: ContinuousClock.Instant = .now - .seconds(1)

    init(totalBytes: Int64, initialLanes: Int, existingSlices: [ByteRangeSlice]?, minimumStealBytes: Int64) {
        self.minimumStealBytes = minimumStealBytes
        if let existingSlices, !existingSlices.isEmpty,
           existingSlices.reduce(Int64(0), { $0 + $1.totalBytes }) == totalBytes {
            self.slices = existingSlices.map { slice in
                var copy = slice
                copy.isActiveLane = false
                return copy
            }
            self.nextSliceID = (existingSlices.map(\.id).max() ?? 0) + 1
        } else {
            let laneCount = max(1, min(initialLanes, Int(max(1, totalBytes / max(1, minimumStealBytes / 2)))))
            let baseChunk = totalBytes / Int64(laneCount)
            var built: [ByteRangeSlice] = []
            built.reserveCapacity(laneCount)
            var cursor: Int64 = 0
            for idx in 0..<laneCount {
                let end = (idx == laneCount - 1) ? (totalBytes - 1) : (cursor + baseChunk - 1)
                built.append(ByteRangeSlice(id: idx, startOffset: cursor, currentOffset: cursor, endOffset: end))
                cursor = end + 1
            }
            self.slices = built
            self.nextSliceID = laneCount
        }
    }

    /// Assigns an unclaimed incomplete slice, or steals the back half of the largest active straggler.
    func claimOrStealSlice() -> ByteRangeSlice? {
        lock.lock()
        defer { lock.unlock() }

        if let idleIdx = slices.firstIndex(where: { !$0.isActiveLane && !$0.isComplete }) {
            slices[idleIdx].isActiveLane = true
            return slices[idleIdx]
        }

        // Dynamic Midpoint Work-Stealing: find active lane with the largest remaining byte span.
        var bestIdx: Int?
        var largestRemaining: Int64 = 0
        for idx in slices.indices where slices[idx].isActiveLane {
            let rem = slices[idx].remainingBytes
            if rem >= minimumStealBytes * 2, rem > largestRemaining {
                largestRemaining = rem
                bestIdx = idx
            }
        }

        guard let targetIdx = bestIdx else { return nil }
        let victim = slices[targetIdx]
        let midpoint = victim.currentOffset + (victim.remainingBytes / 2)
        guard midpoint > victim.currentOffset, midpoint <= victim.endOffset else { return nil }

        let oldEnd = victim.endOffset
        slices[targetIdx].endOffset = midpoint - 1

        let stolen = ByteRangeSlice(
            id: nextSliceID,
            startOffset: midpoint,
            currentOffset: midpoint,
            endOffset: oldEnd,
            isActiveLane: true
        )
        nextSliceID += 1
        if targetIdx + 1 < slices.count {
            slices.insert(stolen, at: targetIdx + 1)
        } else {
            slices.append(stolen)
        }
        return stolen
    }

    /// Reserves up to `incomingCount` bytes for `sliceID`, strictly clamping to `endOffset`
    /// in case another worker stole the back half of this slice while TCP bytes were in flight.
    func commitChunk(sliceID: Int, incomingCount: Int) -> (writeOffset: Int64, allowedBytes: Int, reachedSliceEnd: Bool)? {
        lock.lock()
        defer { lock.unlock() }

        guard let idx = slices.firstIndex(where: { $0.id == sliceID }) else { return nil }
        let remaining = slices[idx].remainingBytes
        guard remaining > 0 else {
            slices[idx].isActiveLane = false
            return (slices[idx].currentOffset, 0, true)
        }

        let allowed = Int(min(Int64(incomingCount), remaining))
        let writeOffset = slices[idx].currentOffset
        slices[idx].currentOffset += Int64(allowed)
        let done = slices[idx].isComplete
        if done {
            slices[idx].isActiveLane = false
        }
        return (writeOffset, allowed, done)
    }

    func currentWindow(for sliceID: Int, maxWindowBytes: Int64) -> (start: Int64, end: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = slices.firstIndex(where: { $0.id == sliceID }),
              !slices[idx].isComplete else { return nil }
        let start = slices[idx].currentOffset
        let end = min(slices[idx].endOffset, start + maxWindowBytes - 1)
        return (start, end)
    }

    func releaseSlice(sliceID: Int) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = slices.firstIndex(where: { $0.id == sliceID }) {
            slices[idx].isActiveLane = false
        }
    }

    func snapshotIfDue(totalBytes: Int64, minInterval: Duration = .milliseconds(200)) -> RangeProgressUpdate? {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        guard now - lastProgressReport >= minInterval else { return nil }
        lastProgressReport = now
        var downloaded: Int64 = 0
        var active = 0
        for s in slices {
            downloaded += s.completedBytes
            if s.isActiveLane && !s.isComplete { active += 1 }
        }
        return RangeProgressUpdate(
            downloadedBytes: downloaded,
            totalBytes: totalBytes,
            activeLanes: active,
            slices: slices
        )
    }

    func snapshot(totalBytes: Int64) -> RangeProgressUpdate {
        lock.lock()
        defer { lock.unlock() }
        var downloaded: Int64 = 0
        var active = 0
        for slice in slices {
            downloaded += slice.completedBytes
            if slice.isActiveLane { active += 1 }
        }
        return RangeProgressUpdate(
            downloadedBytes: min(totalBytes, downloaded),
            totalBytes: totalBytes,
            activeLanes: active,
            slices: slices
        )
    }
}

/// High-concurrency HTTP Range transfer engine backed by `URLSession` and `PreallocatedFileWriter`.
public struct RangeTransferEngine: Sendable {
    private let customSession: URLSession?

    public init(session: URLSession? = nil) {
        self.customSession = session
    }

    private func resolveSessionLease(for url: URL) -> SystemProxyBridge.SessionLease {
        if let customSession {
            return SystemProxyBridge.SessionLease(session: customSession)
        }
        return SystemProxyBridge.acquireSessionLease(for: .rangeTransfer, targetURL: url)
    }

    /// Probes byte-range support via `Range: bytes=0-0` (more reliable than `HEAD` on presigned CDN URLs).
    public func probe(url: URL, headers: [String: String] = [:]) async throws -> RangeProbeResult {
        let lease = resolveSessionLease(for: url)
        defer { lease.release() }
        return try await probe(url: url, headers: headers, session: lease.session)
    }

    private func probe(
        url: URL,
        headers: [String: String],
        session: URLSession
    ) async throws -> RangeProbeResult {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        let (asyncBytes, response) = try await session.bytes(for: req, delegate: CrossOriginRedirectAuthStripper.shared)
        defer { asyncBytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "Dysprosium.HTTP",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: L("HTTP \(http.statusCode) during stream probe")]
            )
        }

        let finalURL = http.url ?? url
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased()
        let supportsRanges = (http.statusCode == 206) || (acceptRanges == "bytes")

        var resolvedTotal: Int64?
        if let contentRange, let slashIdx = contentRange.lastIndex(of: "/") {
            let totalStr = contentRange[contentRange.index(after: slashIdx)...]
            if let parsed = Int64(totalStr.trimmingCharacters(in: .whitespaces)), parsed > 0 {
                resolvedTotal = parsed
            }
        }
        if resolvedTotal == nil, http.statusCode == 200, response.expectedContentLength > 0 {
            resolvedTotal = response.expectedContentLength
        }

        return RangeProbeResult(
            finalURL: finalURL,
            totalBytes: resolvedTotal,
            supportsByteRanges: supportsRanges && (resolvedTotal ?? 0) > 0,
            suggestedFilename: response.suggestedFilename,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            mimeType: response.mimeType
        )
    }

    /// Downloads `url` to `destinationURL` using multi-connection `Range` work-stealing when supported,
    /// or single-connection streaming fallback when the server lacks byte-range support.
    public func download(
        url: URL,
        headers: [String: String] = [:],
        destinationURL: URL,
        knownTotalBytes: Int64? = nil,
        supportsRangesHint: Bool? = nil,
        existingSlices: [ByteRangeSlice]? = nil,
        ifRangeValidator: String? = nil,
        configuration: RangeEngineConfiguration = RangeEngineConfiguration(),
        onProgress: @escaping @Sendable (RangeProgressUpdate) -> Void
    ) async throws -> RangeProgressUpdate {
        do {
            return try await executeDownload(
                url: url,
                headers: headers,
                destinationURL: destinationURL,
                knownTotalBytes: knownTotalBytes,
                supportsRangesHint: supportsRangesHint,
                existingSlices: existingSlices,
                ifRangeValidator: ifRangeValidator,
                configuration: configuration,
                onProgress: onProgress
            )
        } catch RangeTransferError.remoteResourceModified where existingSlices != nil {
            // Remote file changed since pause (`If-Range` rejected): re-probe and restart cleanly.
            return try await executeDownload(
                url: url,
                headers: headers,
                destinationURL: destinationURL,
                knownTotalBytes: nil,
                supportsRangesHint: nil,
                existingSlices: nil,
                ifRangeValidator: nil,
                configuration: configuration,
                onProgress: onProgress
            )
        }
    }

    private func executeDownload(
        url: URL,
        headers: [String: String],
        destinationURL: URL,
        knownTotalBytes: Int64?,
        supportsRangesHint: Bool?,
        existingSlices: [ByteRangeSlice]?,
        ifRangeValidator: String?,
        configuration: RangeEngineConfiguration,
        onProgress: @escaping @Sendable (RangeProgressUpdate) -> Void
    ) async throws -> RangeProgressUpdate {
        let lease = resolveSessionLease(for: url)
        defer { lease.release() }
        let activeSession = lease.session
        let totalBytes: Int64?
        let supportsRanges: Bool
        let targetURL: URL
        let effectiveIfRange: String?

        if let knownTotalBytes, knownTotalBytes > 0, let supportsRangesHint {
            totalBytes = knownTotalBytes
            supportsRanges = supportsRangesHint
            targetURL = url
            effectiveIfRange = Self.sanitizedIfRangeValidator(ifRangeValidator)
        } else {
            let probed = try await probe(url: url, headers: headers, session: activeSession)
            totalBytes = probed.totalBytes ?? knownTotalBytes
            supportsRanges = probed.supportsByteRanges
            targetURL = probed.finalURL
            effectiveIfRange = Self.sanitizedIfRangeValidator(ifRangeValidator)
                ?? Self.resolveIfRangeValidator(etag: probed.etag, lastModified: probed.lastModified)
        }

        let effectiveHeaders = CrossOriginRedirectAuthStripper.stripCrossOriginAuthHeaders(
            from: headers,
            sourceURL: url,
            destinationURL: targetURL
        )

        guard supportsRanges, let totalBytes, totalBytes > 0 else {
            return try await downloadSingleStreamFallback(
                url: targetURL,
                headers: effectiveHeaders,
                session: activeSession,
                destinationURL: destinationURL,
                expectedBytes: totalBytes,
                onProgress: onProgress
            )
        }

        let isFreshStart = (existingSlices == nil || existingSlices?.isEmpty == true)
            || !FileManager.default.fileExists(atPath: destinationURL.path)
        let writer = try PreallocatedFileWriter(
            fileURL: destinationURL,
            preallocateBytes: totalBytes,
            truncateExisting: isFreshStart
        )
        defer { try? writer.close() }

        let coordinator = SliceCoordinator(
            totalBytes: totalBytes,
            initialLanes: configuration.maxLanes,
            existingSlices: isFreshStart ? nil : existingSlices,
            minimumStealBytes: configuration.minimumStealBytes
        )

        onProgress(coordinator.snapshot(totalBytes: totalBytes))

        let workerCount = min(configuration.maxLanes, max(1, coordinator.snapshot(totalBytes: totalBytes).slices.count))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    try await runWorkerLoop(
                        url: targetURL,
                        headers: effectiveHeaders,
                        session: activeSession,
                        ifRangeValidator: effectiveIfRange,
                        writer: writer,
                        coordinator: coordinator,
                        totalBytes: totalBytes,
                        configuration: configuration,
                        onProgress: onProgress
                    )
                }
            }
            try await group.waitForAll()
        }

        try writer.synchronize()
        let finalSnapshot = coordinator.snapshot(totalBytes: totalBytes)
        onProgress(finalSnapshot)
        return finalSnapshot
    }

    static func resolveIfRangeValidator(etag: String?, lastModified: String?) -> String? {
        if let strongETag = sanitizedIfRangeValidator(etag) {
            return strongETag
        }
        if let lm = lastModified?.trimmingCharacters(in: .whitespacesAndNewlines), !lm.isEmpty {
            return lm
        }
        return nil
    }

    private static func sanitizedIfRangeValidator(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        // RFC 9110 §13.1.5: Weak entity-tags (`W/"..."`) must not be sent in `If-Range`.
        if trimmed.hasPrefix("W/") || trimmed.hasPrefix("w/") {
            return nil
        }
        return trimmed
    }

    private func runWorkerLoop(
        url: URL,
        headers: [String: String],
        session: URLSession,
        ifRangeValidator: String?,
        writer: PreallocatedFileWriter,
        coordinator: SliceCoordinator,
        totalBytes: Int64,
        configuration: RangeEngineConfiguration,
        onProgress: @escaping @Sendable (RangeProgressUpdate) -> Void
    ) async throws {
        while !Task.isCancelled {
            guard let claimed = coordinator.claimOrStealSlice() else {
                return
            }
            let sliceID = claimed.id
            do {
                while !Task.isCancelled,
                      let window = coordinator.currentWindow(for: sliceID, maxWindowBytes: configuration.maxWindowBytes) {
                    try await fetchWindow(
                        url: url,
                        headers: headers,
                        session: session,
                        ifRangeValidator: ifRangeValidator,
                        sliceID: sliceID,
                        windowStart: window.start,
                        windowEnd: window.end,
                        writer: writer,
                        coordinator: coordinator,
                        totalBytes: totalBytes,
                        onProgress: onProgress
                    )
                }
                coordinator.releaseSlice(sliceID: sliceID)
            } catch {
                coordinator.releaseSlice(sliceID: sliceID)
                throw error
            }
        }
    }

    /// Bounded bulk chunk-level HTTP body reader backed by `URLSessionDataDelegate`.
    /// Applies true TCP backpressure (`dataTask.suspend()` / `resume()`) at a 2 MiB per-lane
    /// high-water mark so multi-lane range downloads never accumulate unbounded RAM or drop bytes,
    /// while stripping `Cookie`/`Authorization` on cross-origin HTTP redirects.
    private final class BulkChunkReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private static let highWaterBytes = 2 * 1024 * 1024
        private static let lowWaterBytes = 512 * 1024

        private let lock = NSLock()
        private weak var activeTask: URLSessionDataTask?
        private var headerContinuation: CheckedContinuation<URLResponse, Error>?
        private var chunkContinuation: CheckedContinuation<Data?, Error>?
        private var pendingResponse: URLResponse?
        private var bufferedChunks: [Data] = []
        private var headIndex: Int = 0
        private var bufferedBytes: Int = 0
        private var isSuspendedForBackpressure: Bool = false
        private var streamCompleted: Bool = false
        private var streamError: Error?

        func start(request: URLRequest, via session: URLSession) async throws -> (URLResponse, URLSessionDataTask) {
            let task = session.dataTask(with: request)
            task.delegate = self
            lock.withLock {
                self.activeTask = task
            }

            let response: URLResponse = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    enum HeaderAction {
                        case returnResponse(URLResponse)
                        case throwError(Error)
                        case resumeTask
                    }
                    let action: HeaderAction = lock.withLock {
                        if let resp = pendingResponse {
                            return .returnResponse(resp)
                        }
                        if let err = streamError {
                            return .throwError(err)
                        }
                        if streamCompleted {
                            return .throwError(URLError(.badServerResponse))
                        }
                        headerContinuation = cont
                        return .resumeTask
                    }
                    switch action {
                    case .returnResponse(let resp):
                        cont.resume(returning: resp)
                    case .throwError(let err):
                        cont.resume(throwing: err)
                    case .resumeTask:
                        task.resume()
                    }
                }
            } onCancel: {
                self.cancelFromConsumer()
            }
            return (response, task)
        }

        func nextChunk() async throws -> Data? {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                    enum NextAction {
                        case deliver(Data, URLSessionDataTask?)
                        case finish
                        case fail(Error)
                        case wait
                    }

                    let action: NextAction = lock.withLock {
                        if let err = streamError {
                            return .fail(err)
                        }
                        if headIndex < bufferedChunks.count {
                            let chunk = bufferedChunks[headIndex]
                            bufferedChunks[headIndex] = Data()
                            headIndex += 1
                            bufferedBytes = max(0, bufferedBytes - chunk.count)
                            if headIndex >= 32, headIndex * 2 >= bufferedChunks.count {
                                bufferedChunks.removeFirst(headIndex)
                                headIndex = 0
                            }
                            var taskToResume: URLSessionDataTask?
                            if isSuspendedForBackpressure && bufferedBytes <= Self.lowWaterBytes {
                                isSuspendedForBackpressure = false
                                taskToResume = activeTask
                            }
                            return .deliver(chunk, taskToResume)
                        }
                        if streamCompleted {
                            return .finish
                        }
                        chunkContinuation = cont
                        return .wait
                    }

                    switch action {
                    case .deliver(let data, let taskToResume):
                        taskToResume?.resume()
                        cont.resume(returning: data)
                    case .finish:
                        cont.resume(returning: nil)
                    case .fail(let err):
                        cont.resume(throwing: err)
                    case .wait:
                        break
                    }
                }
            } onCancel: {
                self.cancelFromConsumer()
            }
        }

        private func cancelFromConsumer() {
            let (hCont, cCont, task): (CheckedContinuation<URLResponse, Error>?, CheckedContinuation<Data?, Error>?, URLSessionDataTask?) = lock.withLock {
                if streamError == nil {
                    streamError = CancellationError()
                }
                streamCompleted = true
                bufferedChunks.removeAll(keepingCapacity: false)
                headIndex = 0
                bufferedBytes = 0
                isSuspendedForBackpressure = false
                let h = headerContinuation
                headerContinuation = nil
                let c = chunkContinuation
                chunkContinuation = nil
                return (h, c, activeTask)
            }
            task?.cancel()
            hCont?.resume(throwing: CancellationError())
            cCont?.resume(throwing: CancellationError())
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            let originURL = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url
            completionHandler(CrossOriginRedirectAuthStripper.sanitizedRedirectRequest(from: originURL, to: request))
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            let cont: CheckedContinuation<URLResponse, Error>? = lock.withLock {
                pendingResponse = response
                let c = headerContinuation
                headerContinuation = nil
                return c
            }
            cont?.resume(returning: response)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !data.isEmpty else { return }
            let (directCont, shouldSuspend): (CheckedContinuation<Data?, Error>?, Bool) = lock.withLock {
                guard !streamCompleted else { return (nil, false) }
                if let waiting = chunkContinuation {
                    chunkContinuation = nil
                    return (waiting, false)
                }
                bufferedChunks.append(data)
                bufferedBytes += data.count
                if bufferedBytes >= Self.highWaterBytes && !isSuspendedForBackpressure {
                    isSuspendedForBackpressure = true
                    return (nil, true)
                }
                return (nil, false)
            }
            if let directCont {
                directCont.resume(returning: data)
            } else if shouldSuspend {
                dataTask.suspend()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (hCont, cCont, finalError): (CheckedContinuation<URLResponse, Error>?, CheckedContinuation<Data?, Error>?, Error?) = lock.withLock {
                streamCompleted = true
                if let error, streamError == nil {
                    streamError = error
                }
                let h = headerContinuation
                headerContinuation = nil
                let c = chunkContinuation
                chunkContinuation = nil
                return (h, c, streamError)
            }

            if let finalError {
                hCont?.resume(throwing: finalError)
                cCont?.resume(throwing: finalError)
            } else {
                hCont?.resume(throwing: URLError(.badServerResponse))
                cCont?.resume(returning: nil)
            }
        }
    }

    private func fetchWindow(
        url: URL,
        headers: [String: String],
        session: URLSession,
        ifRangeValidator: String?,
        sliceID: Int,
        windowStart: Int64,
        windowEnd: Int64,
        writer: PreallocatedFileWriter,
        coordinator: SliceCoordinator,
        totalBytes: Int64,
        onProgress: @escaping @Sendable (RangeProgressUpdate) -> Void
    ) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=\(windowStart)-\(windowEnd)", forHTTPHeaderField: "Range")
        if let ifRangeValidator, !ifRangeValidator.isEmpty {
            req.setValue(ifRangeValidator, forHTTPHeaderField: "If-Range")
        }

        let receiver = BulkChunkReceiver()
        let (response, task) = try await receiver.start(request: req, via: session)
        defer { task.cancel() }

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 200, ifRangeValidator != nil {
            throw RangeTransferError.remoteResourceModified
        }
        guard http.statusCode == 206 else {
            throw NSError(
                domain: "Dysprosium.Range",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: L("Expected 206 Partial Content, got HTTP \(http.statusCode)")]
            )
        }

        let flushSize = 128 * 1024
        var buffer = Data()
        buffer.reserveCapacity(flushSize)

        while let chunk = try await receiver.nextChunk() {
            try Task.checkCancellation()
            if buffer.isEmpty && chunk.count >= flushSize {
                let done = try commitAndWriteDirect(chunk, sliceID: sliceID, writer: writer, coordinator: coordinator)
                if let update = coordinator.snapshotIfDue(totalBytes: totalBytes) {
                    onProgress(update)
                }
                if done { return }
            } else {
                buffer.append(chunk)
                if buffer.count >= flushSize {
                    let done = try flushBuffer(&buffer, sliceID: sliceID, writer: writer, coordinator: coordinator)
                    if let update = coordinator.snapshotIfDue(totalBytes: totalBytes) {
                        onProgress(update)
                    }
                    if done { return }
                }
            }
        }

        if !buffer.isEmpty {
            _ = try flushBuffer(&buffer, sliceID: sliceID, writer: writer, coordinator: coordinator)
        }
        if let update = coordinator.snapshotIfDue(totalBytes: totalBytes) {
            onProgress(update)
        }
    }

    private func commitAndWriteDirect(
        _ chunk: Data,
        sliceID: Int,
        writer: PreallocatedFileWriter,
        coordinator: SliceCoordinator
    ) throws -> Bool {
        guard let commit = coordinator.commitChunk(sliceID: sliceID, incomingCount: chunk.count) else {
            return true
        }
        if commit.allowedBytes > 0 {
            if commit.allowedBytes == chunk.count {
                try writer.write(chunk, at: commit.writeOffset)
            } else {
                try writer.write(Data(chunk.prefix(commit.allowedBytes)), at: commit.writeOffset)
            }
        }
        return commit.reachedSliceEnd
    }

    private func flushBuffer(
        _ buffer: inout Data,
        sliceID: Int,
        writer: PreallocatedFileWriter,
        coordinator: SliceCoordinator
    ) throws -> Bool {
        defer { buffer.removeAll(keepingCapacity: true) }
        return try commitAndWriteDirect(buffer, sliceID: sliceID, writer: writer, coordinator: coordinator)
    }

    private func downloadSingleStreamFallback(
        url: URL,
        headers: [String: String],
        session: URLSession,
        destinationURL: URL,
        expectedBytes: Int64?,
        onProgress: @escaping @Sendable (RangeProgressUpdate) -> Void
    ) async throws -> RangeProgressUpdate {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let receiver = BulkChunkReceiver()
        let (response, task) = try await receiver.start(request: req, via: session)
        defer { task.cancel() }

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "Dysprosium.HTTP",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: L("HTTP \(http.statusCode) during stream download")]
            )
        }

        let writer = try PreallocatedFileWriter(fileURL: destinationURL, preallocateBytes: nil, truncateExisting: true)
        defer { try? writer.close() }

        var offset: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(128 * 1024)
        var lastReport = ContinuousClock.now

        while let chunk = try await receiver.nextChunk() {
            try Task.checkCancellation()
            buffer.append(chunk)
            if buffer.count >= 128 * 1024 {
                try writer.write(buffer, at: offset)
                offset += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let now = ContinuousClock.now
                if now - lastReport >= .milliseconds(200) {
                    lastReport = now
                    let slice = ByteRangeSlice(
                        id: 0,
                        startOffset: 0,
                        currentOffset: offset,
                        endOffset: max(offset, (expectedBytes ?? offset) - 1),
                        isActiveLane: true
                    )
                    onProgress(RangeProgressUpdate(
                        downloadedBytes: offset,
                        totalBytes: expectedBytes,
                        activeLanes: 1,
                        slices: [slice]
                    ))
                }
            }
        }

        if !buffer.isEmpty {
            try writer.write(buffer, at: offset)
            offset += Int64(buffer.count)
        }
        try writer.synchronize()

        let finalSlice = ByteRangeSlice(
            id: 0,
            startOffset: 0,
            currentOffset: offset,
            endOffset: max(0, offset - 1),
            isActiveLane: false
        )
        let summary = RangeProgressUpdate(
            downloadedBytes: offset,
            totalBytes: offset,
            activeLanes: 0,
            slices: [finalSlice]
        )
        onProgress(summary)
        return summary
    }
}
