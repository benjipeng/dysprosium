#if DEBUG
import Foundation
import Network

/// Ephemeral localhost HTTP/1.1 `206 Partial Content` server powered by `Network.framework`.
/// Serves deterministic synthetic payloads with optional straggler-lane throttling so both
/// XCTest suites and interactive iPhone Duo benchmarks verify real socket concurrency,
/// `Darwin.pwrite` byte-level integrity, and dynamic midpoint work-stealing.
public actor LoopbackRangeServer {
    public static let shared = LoopbackRangeServer()

    private var listener: NWListener?
    private var payload: Data = Data()
    private var requestCounter: Int = 0
    public private(set) var port: UInt16 = 0
    public var throttleEveryNthConnection: Int = 4
    public var chunkDelayNanoseconds: UInt64 = 14_000_000 // 14 ms per 64 KiB on stragglers

    public init() {}

    public func configureThrottling(everyNth: Int, delayNanoseconds: UInt64) {
        self.throttleEveryNthConnection = everyNth
        self.chunkDelayNanoseconds = delayNanoseconds
    }

    /// Starts (or reuses) the loopback listener with a deterministic pseudo-random payload of `sizeBytes`.
    public func ensureRunning(sizeBytes: Int = 16 * 1024 * 1024) async throws -> URL {
        if payload.count != sizeBytes {
            payload = Self.generateDeterministicPayload(sizeBytes: sizeBytes)
        }
        if let listener, listener.state == .ready, port > 0 {
            return URL(string: "http://127.0.0.1:\(port)/dysprosium-\(sizeBytes / (1024 * 1024))MB-benchmark.bin")!
        }

        listener?.cancel()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwListener = try NWListener(using: params, on: .any)

        let readyPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let assigned = nwListener.port?.rawValue, resumed.trySet() {
                        continuation.resume(returning: assigned)
                    }
                case .failed(let err):
                    if resumed.trySet() {
                        continuation.resume(throwing: err)
                    }
                default:
                    break
                }
            }
            nwListener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.accept(connection) }
            }
            nwListener.start(queue: DispatchQueue(label: "dev.korolov.Dysprosium.loopback"))
        }

        self.listener = nwListener
        self.port = readyPort
        return URL(string: "http://127.0.0.1:\(readyPort)/dysprosium-\(sizeBytes / (1024 * 1024))MB-benchmark.bin")!
    }

    public func expectedPayload() -> Data {
        payload
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func accept(_ connection: NWConnection) {
        requestCounter += 1
        let connIndex = requestCounter
        let snapshot = payload
        let shouldThrottle = throttleEveryNthConnection > 0 && (connIndex % throttleEveryNthConnection == 0)
        let delayNs = shouldThrottle ? chunkDelayNanoseconds : 2_500_000

        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        Task.detached {
            await Self.serveHTTPConnection(connection, payload: snapshot, delayNs: delayNs)
        }
    }

    private static func serveHTTPConnection(_ connection: NWConnection, payload: Data, delayNs: UInt64) async {
        defer { connection.cancel() }
        guard let headerData = await receiveHeaders(on: connection),
              let headerStr = String(data: headerData, encoding: .utf8) else { return }

        let total = payload.count
        let currentETag = "\"dysprosium-bench-\(total)\""
        var rangeStart = 0
        var rangeEnd = total - 1
        var isPartial = false
        var ifRangeHeader: String?

        for line in headerStr.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("range:") {
                let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("bytes=") {
                    let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                    if parts.count == 2 {
                        if let s = Int(parts[0]) { rangeStart = max(0, min(total - 1, s)) }
                        if let e = Int(parts[1]) { rangeEnd = max(rangeStart, min(total - 1, e)) }
                        isPartial = true
                    }
                }
            } else if lower.hasPrefix("if-range:") {
                ifRangeHeader = line.dropFirst(9).trimmingCharacters(in: .whitespaces)
            }
        }

        if isPartial, let ifRangeHeader, !ifRangeHeader.isEmpty, ifRangeHeader != currentETag {
            isPartial = false
            rangeStart = 0
            rangeEnd = total - 1
        }

        let contentLength = rangeEnd - rangeStart + 1
        let statusLine = isPartial ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
        var responseHeaders = [
            statusLine,
            "Accept-Ranges: bytes",
            "Content-Type: application/octet-stream",
            "Content-Length: \(contentLength)",
            "ETag: \(currentETag)",
            "Connection: close"
        ]
        if isPartial {
            responseHeaders.insert("Content-Range: bytes \(rangeStart)-\(rangeEnd)/\(total)", at: 2)
        }
        let headerBytes = Data((responseHeaders.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        guard await sendChunk(headerBytes, on: connection) else { return }

        let step = 64 * 1024
        var cursor = rangeStart
        while cursor <= rangeEnd {
            let chunkEnd = min(rangeEnd + 1, cursor + step)
            let sub = payload.subdata(in: cursor..<chunkEnd)
            guard await sendChunk(sub, on: connection) else { return }
            cursor = chunkEnd
            if cursor <= rangeEnd, delayNs > 0, contentLength > 1024 {
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }
        // Signal graceful TCP FIN before `defer { connection.cancel() }` tears down the socket.
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        try? await Task.sleep(for: .milliseconds(25))
    }

    private static func receiveHeaders(on connection: NWConnection) async -> Data? {
        var accumulated = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        while accumulated.range(of: delimiter) == nil && accumulated.count < 16 * 1024 {
            let next: Data? = await withCheckedContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, err in
                    if err != nil {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(returning: data)
                    }
                }
            }
            guard let next, !next.isEmpty else { return accumulated.isEmpty ? nil : accumulated }
            accumulated.append(next)
        }
        return accumulated
    }

    private static func sendChunk(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { cont in
            connection.send(content: data, completion: .contentProcessed { err in
                cont.resume(returning: err == nil)
            })
        }
    }

    public static func generateDeterministicPayload(sizeBytes: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: sizeBytes)
        var state: UInt64 = 0x4459_5350_524F_5336 // "DYSPROS6"
        bytes.withUnsafeMutableBytes { raw in
            var idx = 0
            while idx + 8 <= sizeBytes {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                raw.storeBytes(of: state.littleEndian, toByteOffset: idx, as: UInt64.self)
                idx += 8
            }
            while idx < sizeBytes {
                raw[idx] = UInt8(truncatingIfNeeded: state &+ UInt64(idx))
                idx += 1
            }
        }
        return Data(bytes)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if set { return false }
        set = true
        return true
    }
}
#endif
