import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

/// Pure-native iOS zero-transcode MPEG-TS (`.ts`) -> ISO-BMFF (`.mp4`) streaming remuxer.
/// Runs a 2-pass zero-copy scan directly over the memory-mapped `.ts` file:
/// - Pass 1 discovers PAT/PMT PIDs, H.264/HEVC parameter sets (`VPS`/`SPS`/`PPS`), ADTS AAC config,
///   shared epoch origin (`minTick`), and B-frame `cttsShift` without buffering frame payloads.
/// - Pass 2 streams each complete Access Unit / AAC frame directly into `AVAssetWriterInput`
///   gated on `isReadyForMoreMediaData` via independent per-PID cursors, keeping dirty heap RAM O(1).
public enum NativeMP4Remuxer {
    public enum RemuxError: LocalizedError {
        case invalidTransportStream
        case noSupportedElementaryStreams
        case formatDescriptionCreationFailed(OSStatus)
        case assetWriterInitializationFailed(String)
        case assetWriterFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidTransportStream:
                return "Input stream does not contain valid 188-byte MPEG-TS sync packets."
            case .noSupportedElementaryStreams:
                return "No H.264/HEVC video or AAC audio elementary streams found in MPEG-TS."
            case .formatDescriptionCreationFailed(let status):
                return "CoreMedia format description creation failed (OSStatus \(status))."
            case .assetWriterInitializationFailed(let reason):
                return "AVAssetWriter initialization failed: \(reason)"
            case .assetWriterFailed(let reason):
                return "AVAssetWriter passthrough remux failed: \(reason)"
            }
        }
    }

    private enum VideoCodec {
        case h264
        case hevc
    }

    private struct VideoAccessUnit {
        let avccPayload: Data
        let pts90k: Int64
        let dts90k: Int64
        let isSync: Bool
    }

    private struct AudioAccessUnit {
        let rawAACPayload: Data
        let pts90k: Int64
        let sampleOffsetInPES: Int
    }

    private struct AACConfig: Equatable {
        let objectType: UInt8
        let freqIndex: UInt8
        let sampleRate: Int
        let channelConfig: UInt8
    }

    private struct StreamScanSummary {
        var videoPID: UInt16?
        var videoCodec: VideoCodec?
        var firstVideoPacketOffset: Int = -1
        var vps: Data?
        var sps: Data?
        var pps: Data?
        var videoSampleCount: Int = 0
        var cttsShift90k: Int64 = 0

        var audioPID: UInt16?
        var firstAudioPacketOffset: Int = -1
        var aacConfig: AACConfig?
        var audioSampleCount: Int = 0

        var minTick90k: Int64 = 0
    }

    private static let aacSampleRates: [Int] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000,
        24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350
    ]

    /// Inspects the leading bytes of a file to determine whether it is already an ISO-BMFF MP4/fMP4
    /// container (`ftyp` / `styp` / `moov`) or a raw MPEG-TS stream requiring `.ts` -> `.mp4` remuxing.
    public static func isISOBaseMediaFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 16),
              header.count >= 8 else {
            return false
        }
        try? handle.close()
        let fourCC = String(decoding: header[4..<8], as: UTF8.self)
        return ["ftyp", "styp", "moov", "moof", "sidx", "free"].contains(fourCC)
    }

    /// Losslessly remuxes a local MPEG-TS (`.ts`) file into a fast-start `.mp4` file using
    /// 2-pass streaming over a memory-mapped file into `CoreMedia` + `AVAssetWriter`.
    public static func remuxMPEGTS(from sourceURL: URL, to destinationURL: URL) async throws {
        let tsData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let scan = try scanTransportStream(tsData)

        guard scan.videoSampleCount > 0 || scan.audioSampleCount > 0 else {
            throw RemuxError.noSupportedElementaryStreams
        }

        let videoFormatDesc: CMVideoFormatDescription?
        if let codec = scan.videoCodec, scan.videoSampleCount > 0 {
            videoFormatDesc = try makeVideoFormatDescription(
                codec: codec,
                vps: scan.vps,
                sps: scan.sps,
                pps: scan.pps
            )
        } else {
            videoFormatDesc = nil
        }

        let audioFormatDesc: CMAudioFormatDescription?
        if let aacCfg = scan.aacConfig, scan.audioSampleCount > 0 {
            audioFormatDesc = try makeAACFormatDescription(config: aacCfg)
        } else {
            audioFormatDesc = nil
        }

        guard videoFormatDesc != nil || audioFormatDesc != nil else {
            throw RemuxError.noSupportedElementaryStreams
        }

        try? FileManager.default.removeItem(at: destinationURL)
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        var videoInput: AVAssetWriterInput?
        if let vDesc = videoFormatDesc, scan.videoSampleCount > 0 {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vDesc)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                videoInput = input
            }
        }

        var audioInput: AVAssetWriterInput?
        if let aDesc = audioFormatDesc, scan.audioSampleCount > 0 {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: aDesc)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw RemuxError.assetWriterInitializationFailed(writer.error?.localizedDescription ?? "startWriting returned false")
        }
        writer.startSession(atSourceTime: .zero)

        let videoCursor: VideoTSStreamCursor? = {
            guard videoInput != nil,
                  let vPID = scan.videoPID,
                  let codec = scan.videoCodec,
                  scan.firstVideoPacketOffset >= 0 else {
                return nil
            }
            return VideoTSStreamCursor(
                tsData: tsData,
                targetPID: vPID,
                codec: codec,
                startOffset: scan.firstVideoPacketOffset
            )
        }()

        let audioCursor: AudioTSStreamCursor? = {
            guard audioInput != nil,
                  let aPID = scan.audioPID,
                  scan.firstAudioPacketOffset >= 0 else {
                return nil
            }
            return AudioTSStreamCursor(
                tsData: tsData,
                targetPID: aPID,
                startOffset: scan.firstAudioPacketOffset
            )
        }()

        do {
            try await pumpStreamingSamples(
                writer: writer,
                videoCursor: videoCursor,
                videoFormat: videoFormatDesc,
                videoInput: videoInput,
                cttsShift90k: scan.cttsShift90k,
                audioCursor: audioCursor,
                audioFormat: audioFormatDesc,
                audioSampleRate: scan.aacConfig?.sampleRate ?? 44_100,
                audioInput: audioInput,
                epochOrigin90k: scan.minTick90k
            )
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: destinationURL)
            throw RemuxError.assetWriterFailed(writer.error?.localizedDescription ?? "Writer finished with status \(writer.status.rawValue)")
        }
    }

    // MARK: - Pass 1: Zero-Copy Metadata & Epoch Scan

    private static func scanTransportStream(_ data: Data) throws -> StreamScanSummary {
        let totalLen = data.count
        guard totalLen >= 188 else { throw RemuxError.invalidTransportStream }

        return try data.withUnsafeBytes { rawBuffer -> StreamScanSummary in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw RemuxError.invalidTransportStream
            }

            var cursor = findSyncOffset(base: base, count: totalLen, from: 0)
            guard cursor >= 0 else { throw RemuxError.invalidTransportStream }

            var pmtPID: UInt16?
            var videoPID: UInt16?
            var audioPID: UInt16?
            var videoCodec: VideoCodec?
            var firstVideoOffset = -1
            var firstAudioOffset = -1

            var videoAssembler: VideoESAssembler?
            let audioAssembler = AudioESAssembler(capturePayloads: false)

            var videoSampleCount = 0
            var audioSampleCount = 0
            var minTick = Int64.max
            var cttsShift: Int64 = 0

            let onVideoMeta: (VideoAccessUnit?, Int64, Int64) -> Void = { _, pts90k, dts90k in
                videoSampleCount += 1
                minTick = min(minTick, min(pts90k, dts90k))
                let delta = dts90k - pts90k
                if delta > cttsShift {
                    cttsShift = delta
                }
            }
            let onAudioMeta: (AudioAccessUnit?, Int64) -> Void = { _, pts90k in
                audioSampleCount += 1
                minTick = min(minTick, pts90k)
            }

            var videoPES = Data()
            videoPES.reserveCapacity(131_072)
            var audioPES = Data()
            audioPES.reserveCapacity(16_384)

            func flushVideoPES() {
                guard !videoPES.isEmpty, let codec = videoCodec else {
                    videoPES.removeAll(keepingCapacity: true)
                    return
                }
                if videoAssembler == nil {
                    videoAssembler = VideoESAssembler(codec: codec, capturePayloads: false)
                }
                if let parsed = parsePESHeader(videoPES), parsed.payloadOffset < videoPES.count {
                    videoAssembler?.appendPES(
                        payload: videoPES[parsed.payloadOffset...],
                        pts: parsed.pts,
                        dts: parsed.dts,
                        emit: onVideoMeta
                    )
                }
                videoPES.removeAll(keepingCapacity: true)
            }

            func flushAudioPES() {
                guard !audioPES.isEmpty else { return }
                if let parsed = parsePESHeader(audioPES), parsed.payloadOffset < audioPES.count {
                    audioAssembler.appendPES(
                        payload: audioPES[parsed.payloadOffset...],
                        pts: parsed.pts,
                        emit: onAudioMeta
                    )
                }
                audioPES.removeAll(keepingCapacity: true)
            }

            while cursor + 188 <= totalLen {
                if base[cursor] != 0x47 {
                    let resynced = findSyncOffset(base: base, count: totalLen, from: cursor)
                    if resynced < 0 { break }
                    cursor = resynced
                    continue
                }

                let b1 = base[cursor + 1]
                let b2 = base[cursor + 2]
                let b3 = base[cursor + 3]

                let transportError = (b1 & 0x80) != 0
                if transportError {
                    cursor += 188
                    continue
                }

                let pusi = (b1 & 0x40) != 0
                let pid = (UInt16(b1 & 0x1F) << 8) | UInt16(b2)
                let adaptationControl = (b3 >> 4) & 0x03

                var payloadStart = cursor + 4
                if (adaptationControl & 0x02) != 0 {
                    let adaptationLen = Int(base[cursor + 4])
                    payloadStart += 1 + adaptationLen
                }

                let hasPayload = (adaptationControl & 0x01) != 0
                let packetEnd = cursor + 188
                guard hasPayload, payloadStart < packetEnd else {
                    cursor += 188
                    continue
                }

                if pid == 0x0000 {
                    // Program Association Table (PAT)
                    var secStart = payloadStart
                    if pusi {
                        let ptr = Int(base[secStart])
                        secStart += 1 + ptr
                    }
                    if secStart + 8 <= packetEnd, base[secStart] == 0x00 {
                        let secLen = (Int(base[secStart + 1] & 0x0F) << 8) | Int(base[secStart + 2])
                        let secEnd = min(packetEnd, secStart + 3 + secLen - 4)
                        var entry = secStart + 8
                        while entry + 4 <= secEnd {
                            let progNum = (UInt16(base[entry]) << 8) | UInt16(base[entry + 1])
                            let candidatePID = (UInt16(base[entry + 2] & 0x1F) << 8) | UInt16(base[entry + 3])
                            if progNum != 0 {
                                pmtPID = candidatePID
                                break
                            }
                            entry += 4
                        }
                    }
                } else if let knownPMT = pmtPID, pid == knownPMT {
                    // Program Map Table (PMT)
                    var secStart = payloadStart
                    if pusi {
                        let ptr = Int(base[secStart])
                        secStart += 1 + ptr
                    }
                    if secStart + 12 <= packetEnd, base[secStart] == 0x02 {
                        let secLen = (Int(base[secStart + 1] & 0x0F) << 8) | Int(base[secStart + 2])
                        let secEnd = min(packetEnd, secStart + 3 + secLen - 4)
                        let progInfoLen = (Int(base[secStart + 10] & 0x0F) << 8) | Int(base[secStart + 11])
                        var esPos = secStart + 12 + progInfoLen
                        while esPos + 5 <= secEnd {
                            let streamType = base[esPos]
                            let esPID = (UInt16(base[esPos + 1] & 0x1F) << 8) | UInt16(base[esPos + 2])
                            let esInfoLen = (Int(base[esPos + 3] & 0x0F) << 8) | Int(base[esPos + 4])
                            switch streamType {
                            case 0x1B:
                                if videoPID == nil {
                                    videoPID = esPID
                                    videoCodec = .h264
                                }
                            case 0x24:
                                if videoPID == nil {
                                    videoPID = esPID
                                    videoCodec = .hevc
                                }
                            case 0x0F:
                                if audioPID == nil {
                                    audioPID = esPID
                                }
                            default:
                                break
                            }
                            esPos += 5 + esInfoLen
                        }
                    }
                } else if let vPID = videoPID, pid == vPID {
                    if firstVideoOffset < 0 { firstVideoOffset = cursor }
                    if pusi, !videoPES.isEmpty {
                        flushVideoPES()
                    }
                    videoPES.append(base + payloadStart, count: packetEnd - payloadStart)
                } else if let aPID = audioPID, pid == aPID {
                    if firstAudioOffset < 0 { firstAudioOffset = cursor }
                    if pusi, !audioPES.isEmpty {
                        flushAudioPES()
                    }
                    audioPES.append(base + payloadStart, count: packetEnd - payloadStart)
                }

                cursor += 188
            }

            flushVideoPES()
            flushAudioPES()
            videoAssembler?.finish(emit: onVideoMeta)
            audioAssembler.finish(emit: onAudioMeta)

            return StreamScanSummary(
                videoPID: videoPID,
                videoCodec: videoCodec,
                firstVideoPacketOffset: firstVideoOffset,
                vps: videoAssembler?.vps,
                sps: videoAssembler?.sps,
                pps: videoAssembler?.pps,
                videoSampleCount: videoSampleCount,
                cttsShift90k: cttsShift,
                audioPID: audioPID,
                firstAudioPacketOffset: firstAudioOffset,
                aacConfig: audioAssembler.config,
                audioSampleCount: audioSampleCount,
                minTick90k: minTick == Int64.max ? 0 : minTick
            )
        }
    }

    // MARK: - Pass 2: Independent Per-PID Streaming Cursors

    /// Pull-based streaming cursor that yields one `VideoAccessUnit` at a time directly from
    /// memory-mapped `.ts` data with a 1-sample lookahead for exact frame durations.
    private final class VideoTSStreamCursor {
        private let tsData: Data
        private let targetPID: UInt16
        private let assembler: VideoESAssembler
        private var cursor: Int
        private var eofReached: Bool = false
        private var pesBuffer = Data()
        private var readyQueue: [VideoAccessUnit] = []
        private var readyHead: Int = 0
        private var lookahead: VideoAccessUnit?
        private var didPrimeLookahead: Bool = false

        init(tsData: Data, targetPID: UInt16, codec: VideoCodec, startOffset: Int) {
            self.tsData = tsData
            self.targetPID = targetPID
            self.assembler = VideoESAssembler(codec: codec, capturePayloads: true)
            self.cursor = startOffset
            self.pesBuffer.reserveCapacity(131_072)
        }

        func nextSampleWithNextDTS() -> (sample: VideoAccessUnit, nextDTS90k: Int64?)? {
            if !didPrimeLookahead {
                didPrimeLookahead = true
                lookahead = pullOneSample()
            }
            guard let current = lookahead else { return nil }
            let following = pullOneSample()
            lookahead = following
            return (current, following?.dts90k)
        }

        private func pullOneSample() -> VideoAccessUnit? {
            if readyHead < readyQueue.count {
                return dequeueReady()
            }
            guard !eofReached else { return nil }

            let totalLen = tsData.count
            tsData.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    eofReached = true
                    return
                }

                while readyHead >= readyQueue.count, cursor + 188 <= totalLen {
                    if base[cursor] != 0x47 {
                        let resynced = NativeMP4Remuxer.findSyncOffset(base: base, count: totalLen, from: cursor)
                        if resynced < 0 {
                            cursor = totalLen
                            break
                        }
                        cursor = resynced
                        continue
                    }

                    let b1 = base[cursor + 1]
                    let b2 = base[cursor + 2]
                    if (b1 & 0x80) != 0 {
                        cursor += 188
                        continue
                    }

                    let pid = (UInt16(b1 & 0x1F) << 8) | UInt16(b2)
                    if pid != targetPID {
                        cursor += 188
                        continue
                    }

                    let pusi = (b1 & 0x40) != 0
                    let b3 = base[cursor + 3]
                    let adaptationControl = (b3 >> 4) & 0x03

                    var payloadStart = cursor + 4
                    if (adaptationControl & 0x02) != 0 {
                        payloadStart += 1 + Int(base[cursor + 4])
                    }
                    let hasPayload = (adaptationControl & 0x01) != 0
                    let packetEnd = cursor + 188

                    if hasPayload, payloadStart < packetEnd {
                        if pusi, !pesBuffer.isEmpty {
                            flushPES()
                        }
                        pesBuffer.append(base + payloadStart, count: packetEnd - payloadStart)
                    }

                    cursor += 188
                    if readyHead < readyQueue.count {
                        break
                    }
                }

                if cursor + 188 > totalLen {
                    eofReached = true
                    flushPES()
                    assembler.finish { sample, _, _ in
                        if let sample {
                            readyQueue.append(sample)
                        }
                    }
                    pesBuffer.removeAll(keepingCapacity: false)
                }
            }

            return readyHead < readyQueue.count ? dequeueReady() : nil
        }

        private func flushPES() {
            guard !pesBuffer.isEmpty else { return }
            if let parsed = NativeMP4Remuxer.parsePESHeader(pesBuffer), parsed.payloadOffset < pesBuffer.count {
                assembler.appendPES(
                    payload: pesBuffer[parsed.payloadOffset...],
                    pts: parsed.pts,
                    dts: parsed.dts
                ) { sample, _, _ in
                    if let sample {
                        readyQueue.append(sample)
                    }
                }
            }
            pesBuffer.removeAll(keepingCapacity: true)
        }

        private func dequeueReady() -> VideoAccessUnit {
            let item = readyQueue[readyHead]
            readyHead += 1
            if readyHead >= 16, readyHead * 2 >= readyQueue.count {
                readyQueue.removeFirst(readyHead)
                readyHead = 0
            }
            return item
        }
    }

    /// Pull-based streaming cursor that yields one ADTS `AudioAccessUnit` at a time directly from
    /// memory-mapped `.ts` data.
    private final class AudioTSStreamCursor {
        private let tsData: Data
        private let targetPID: UInt16
        private let assembler = AudioESAssembler(capturePayloads: true)
        private var cursor: Int
        private var eofReached: Bool = false
        private var pesBuffer = Data()
        private var readyQueue: [AudioAccessUnit] = []
        private var readyHead: Int = 0

        init(tsData: Data, targetPID: UInt16, startOffset: Int) {
            self.tsData = tsData
            self.targetPID = targetPID
            self.cursor = startOffset
            self.pesBuffer.reserveCapacity(16_384)
        }

        func nextSample() -> AudioAccessUnit? {
            if readyHead < readyQueue.count {
                return dequeueReady()
            }
            guard !eofReached else { return nil }

            let totalLen = tsData.count
            tsData.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    eofReached = true
                    return
                }

                while readyHead >= readyQueue.count, cursor + 188 <= totalLen {
                    if base[cursor] != 0x47 {
                        let resynced = NativeMP4Remuxer.findSyncOffset(base: base, count: totalLen, from: cursor)
                        if resynced < 0 {
                            cursor = totalLen
                            break
                        }
                        cursor = resynced
                        continue
                    }

                    let b1 = base[cursor + 1]
                    let b2 = base[cursor + 2]
                    if (b1 & 0x80) != 0 {
                        cursor += 188
                        continue
                    }

                    let pid = (UInt16(b1 & 0x1F) << 8) | UInt16(b2)
                    if pid != targetPID {
                        cursor += 188
                        continue
                    }

                    let pusi = (b1 & 0x40) != 0
                    let b3 = base[cursor + 3]
                    let adaptationControl = (b3 >> 4) & 0x03

                    var payloadStart = cursor + 4
                    if (adaptationControl & 0x02) != 0 {
                        payloadStart += 1 + Int(base[cursor + 4])
                    }
                    let hasPayload = (adaptationControl & 0x01) != 0
                    let packetEnd = cursor + 188

                    if hasPayload, payloadStart < packetEnd {
                        if pusi, !pesBuffer.isEmpty {
                            flushPES()
                        }
                        pesBuffer.append(base + payloadStart, count: packetEnd - payloadStart)
                    }

                    cursor += 188
                    if readyHead < readyQueue.count {
                        break
                    }
                }

                if cursor + 188 > totalLen {
                    eofReached = true
                    flushPES()
                    assembler.finish { sample, _ in
                        if let sample {
                            readyQueue.append(sample)
                        }
                    }
                    pesBuffer.removeAll(keepingCapacity: false)
                }
            }

            return readyHead < readyQueue.count ? dequeueReady() : nil
        }

        private func flushPES() {
            guard !pesBuffer.isEmpty else { return }
            if let parsed = NativeMP4Remuxer.parsePESHeader(pesBuffer), parsed.payloadOffset < pesBuffer.count {
                assembler.appendPES(
                    payload: pesBuffer[parsed.payloadOffset...],
                    pts: parsed.pts
                ) { sample, _ in
                    if let sample {
                        readyQueue.append(sample)
                    }
                }
            }
            pesBuffer.removeAll(keepingCapacity: true)
        }

        private func dequeueReady() -> AudioAccessUnit {
            let item = readyQueue[readyHead]
            readyHead += 1
            if readyHead >= 32, readyHead * 2 >= readyQueue.count {
                readyQueue.removeFirst(readyHead)
                readyHead = 0
            }
            return item
        }
    }

    // MARK: - Low-Level TS & PES Helpers

    private static func findSyncOffset(base: UnsafePointer<UInt8>, count: Int, from start: Int) -> Int {
        var idx = start
        while idx + 188 <= count {
            if base[idx] == 0x47 {
                if idx + 376 < count {
                    if base[idx + 188] == 0x47, base[idx + 376] == 0x47 {
                        return idx
                    }
                } else {
                    return idx
                }
            }
            idx += 1
        }
        return -1
    }

    private static func parsePESHeader(_ pes: Data) -> (pts: Int64?, dts: Int64?, payloadOffset: Int)? {
        guard pes.count >= 9 else { return nil }
        return pes.withUnsafeBytes { raw -> (Int64?, Int64?, Int)? in
            guard let b = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            guard b[0] == 0x00, b[1] == 0x00, b[2] == 0x01 else { return nil }

            let flags = (b[7] >> 6) & 0x03
            let headerDataLen = Int(b[8])
            let payloadOffset = 9 + headerDataLen
            guard payloadOffset <= pes.count else { return nil }

            var pts: Int64?
            var dts: Int64?

            if (flags == 0x02 || flags == 0x03), pes.count >= 14 {
                pts = read33BitTimestamp(b + 9)
            }
            if flags == 0x03, pes.count >= 19 {
                dts = read33BitTimestamp(b + 14)
            }
            return (pts, dts, payloadOffset)
        }
    }

    private static func read33BitTimestamp(_ p: UnsafePointer<UInt8>) -> Int64 {
        let p0 = Int64(p[0] & 0x0E) << 29
        let p1 = Int64(p[1]) << 22
        let p2 = Int64(p[2] & 0xFE) << 14
        let p3 = Int64(p[3]) << 7
        let p4 = Int64(p[4]) >> 1
        return p0 | p1 | p2 | p3 | p4
    }

    // MARK: - Streaming Annex-B NALU -> AVCC/HVCC Elementary Stream Reassembler

    /// Reassembles continuous Annex-B H.264/HEVC elementary streams across arbitrary PES boundaries
    /// (required for `nginx-vod-module` and broadcast muxers where frames span consecutive PES packets).
    /// Supports both metadata-only Pass 1 scanning (`capturePayloads: false`) and Pass 2 payload streaming.
    private final class VideoESAssembler {
        let codec: VideoCodec
        let capturePayloads: Bool
        var vps: Data?
        var sps: Data?
        var pps: Data?

        private var buffer = Data()
        private var consumedOffset: Int = 0
        private var pesAnchors: [(globalOffset: Int, pts: Int64?, dts: Int64?)] = []
        private var anchorHead: Int = 0

        private var currentAUAvcc = Data()
        private var currentAUHasPayload = false
        private var currentAUHasVCL = false
        private var currentAUIsSync = false
        private var currentAUStartOffset: Int?
        private var lastDTS: Int64 = 0
        private var hasEmittedSample = false

        init(codec: VideoCodec, capturePayloads: Bool) {
            self.codec = codec
            self.capturePayloads = capturePayloads
            self.buffer.reserveCapacity(131_072)
            if capturePayloads {
                self.currentAUAvcc.reserveCapacity(65_536)
            }
        }

        func appendPES(
            payload: Data.SubSequence,
            pts: Int64?,
            dts: Int64?,
            emit: (VideoAccessUnit?, Int64, Int64) -> Void
        ) {
            guard !payload.isEmpty else { return }
            if pts != nil || dts != nil {
                pesAnchors.append((globalOffset: consumedOffset + buffer.count, pts: pts, dts: dts))
            }
            buffer.append(contentsOf: payload)
            drainCompleteNALUs(flushFinal: false, emit: emit)
        }

        func finish(emit: (VideoAccessUnit?, Int64, Int64) -> Void) {
            drainCompleteNALUs(flushFinal: true, emit: emit)
            flushCurrentAU(emit: emit)
            buffer.removeAll(keepingCapacity: false)
            currentAUAvcc.removeAll(keepingCapacity: false)
            pesAnchors.removeAll(keepingCapacity: false)
        }

        private func drainCompleteNALUs(
            flushFinal: Bool,
            emit: (VideoAccessUnit?, Int64, Int64) -> Void
        ) {
            let n = buffer.count
            guard n >= 3 else { return }

            var startCodes: [(scStart: Int, nalStart: Int)] = []
            buffer.withUnsafeBytes { raw in
                guard let b = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var i = 0
                while i + 3 <= n {
                    if b[i] == 0x00, b[i + 1] == 0x00 {
                        if b[i + 2] == 0x01 {
                            startCodes.append((i, i + 3))
                            i += 3
                            continue
                        } else if i + 4 <= n, b[i + 2] == 0x00, b[i + 3] == 0x01 {
                            startCodes.append((i, i + 4))
                            i += 4
                            continue
                        }
                    }
                    i += 1
                }
            }

            if startCodes.isEmpty {
                // Keep trailing 3 bytes in case a 4-byte start code straddles the next PES boundary.
                if !flushFinal, n > 3 {
                    let dropCount = n - 3
                    buffer = Data(buffer[dropCount...])
                    consumedOffset += dropCount
                }
                return
            }

            let completeCount = flushFinal ? startCodes.count : max(0, startCodes.count - 1)
            if completeCount > 0 {
                buffer.withUnsafeBytes { raw in
                    guard let b = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    for idx in 0..<completeCount {
                        let sc = startCodes[idx]
                        let rawEnd = (idx + 1 < startCodes.count) ? startCodes[idx + 1].scStart : n
                        processCompleteNAL(
                            base: b,
                            nalStart: sc.nalStart,
                            rawEnd: rawEnd,
                            scGlobalOffset: consumedOffset + sc.scStart,
                            emit: emit
                        )
                    }
                }
            }

            if flushFinal {
                consumedOffset += n
                buffer.removeAll(keepingCapacity: true)
            } else if completeCount > 0 {
                let keepFrom = startCodes[completeCount].scStart
                if keepFrom > 0 {
                    buffer = Data(buffer[keepFrom...])
                    consumedOffset += keepFrom
                }
            }
        }

        private func processCompleteNAL(
            base b: UnsafePointer<UInt8>,
            nalStart: Int,
            rawEnd: Int,
            scGlobalOffset: Int,
            emit: (VideoAccessUnit?, Int64, Int64) -> Void
        ) {
            var end = rawEnd
            while end > nalStart, b[end - 1] == 0x00 {
                end -= 1
            }
            let len = end - nalStart
            guard len > 0 else { return }

            switch codec {
            case .h264:
                let nalType = b[nalStart] & 0x1F
                switch nalType {
                case 9:
                    if currentAUHasVCL {
                        flushCurrentAU(emit: emit)
                    }
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                case 7:
                    if currentAUHasVCL {
                        flushCurrentAU(emit: emit)
                    }
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                    if !capturePayloads {
                        sps = Data(bytes: b + nalStart, count: len)
                    }
                case 8:
                    if currentAUHasVCL {
                        flushCurrentAU(emit: emit)
                    }
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                    if !capturePayloads {
                        pps = Data(bytes: b + nalStart, count: len)
                    }
                case 6:
                    if currentAUHasVCL {
                        flushCurrentAU(emit: emit)
                    }
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                    currentAUHasPayload = true
                    if capturePayloads {
                        appendLengthPrefixed(bytes: b + nalStart, count: len, into: &currentAUAvcc)
                    }
                case 12:
                    break
                case 1...5:
                    let isFirstSlice = (len >= 2) && ((b[nalStart + 1] & 0x80) != 0)
                    if currentAUHasVCL && isFirstSlice {
                        flushCurrentAU(emit: emit)
                    }
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                    currentAUHasVCL = true
                    currentAUHasPayload = true
                    if nalType == 5 {
                        currentAUIsSync = true
                    }
                    if capturePayloads {
                        appendLengthPrefixed(bytes: b + nalStart, count: len, into: &currentAUAvcc)
                    }
                default:
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                    currentAUHasPayload = true
                    if capturePayloads {
                        appendLengthPrefixed(bytes: b + nalStart, count: len, into: &currentAUAvcc)
                    }
                }

            case .hevc:
                let nalType = (b[nalStart] >> 1) & 0x3F
                switch nalType {
                case 35:
                    if currentAUHasVCL {
                        flushCurrentAU(emit: emit)
                    }
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                case 32:
                    if currentAUHasVCL {
                        flushCurrentAU(emit: emit)
                    }
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                    if !capturePayloads {
                        vps = Data(bytes: b + nalStart, count: len)
                    }
                case 33:
                    if currentAUHasVCL {
                        flushCurrentAU(emit: emit)
                    }
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                    if !capturePayloads {
                        sps = Data(bytes: b + nalStart, count: len)
                    }
                case 34:
                    if currentAUHasVCL {
                        flushCurrentAU(emit: emit)
                    }
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                    if !capturePayloads {
                        pps = Data(bytes: b + nalStart, count: len)
                    }
                case 39:
                    if currentAUHasVCL {
                        flushCurrentAU(emit: emit)
                    }
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                    currentAUHasPayload = true
                    if capturePayloads {
                        appendLengthPrefixed(bytes: b + nalStart, count: len, into: &currentAUAvcc)
                    }
                case 38:
                    break
                case 0...21:
                    let isFirstSlice = (len >= 3) && ((b[nalStart + 2] & 0x80) != 0)
                    if currentAUHasVCL && isFirstSlice {
                        flushCurrentAU(emit: emit)
                    }
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                    currentAUHasVCL = true
                    currentAUHasPayload = true
                    if (16...21).contains(nalType) {
                        currentAUIsSync = true
                    }
                    if capturePayloads {
                        appendLengthPrefixed(bytes: b + nalStart, count: len, into: &currentAUAvcc)
                    }
                default:
                    if currentAUStartOffset == nil {
                        currentAUStartOffset = scGlobalOffset
                    }
                    currentAUHasPayload = true
                    if capturePayloads {
                        appendLengthPrefixed(bytes: b + nalStart, count: len, into: &currentAUAvcc)
                    }
                }
            }
        }

        private func flushCurrentAU(emit: (VideoAccessUnit?, Int64, Int64) -> Void) {
            guard currentAUHasPayload else {
                currentAUHasVCL = false
                currentAUIsSync = false
                currentAUStartOffset = nil
                return
            }

            let auStart = currentAUStartOffset ?? consumedOffset
            var matchedAnchor: (pts: Int64?, dts: Int64?)?
            while anchorHead < pesAnchors.count, pesAnchors[anchorHead].globalOffset <= auStart {
                matchedAnchor = (pesAnchors[anchorHead].pts, pesAnchors[anchorHead].dts)
                anchorHead += 1
            }
            if anchorHead > 256 {
                pesAnchors.removeFirst(anchorHead)
                anchorHead = 0
            }

            let fallbackDTS = hasEmittedSample ? (lastDTS + 3000) : 0
            let pts = matchedAnchor?.pts ?? fallbackDTS
            let dts = matchedAnchor?.dts ?? pts
            lastDTS = dts
            hasEmittedSample = true

            if capturePayloads {
                let sample = VideoAccessUnit(
                    avccPayload: currentAUAvcc,
                    pts90k: pts,
                    dts90k: dts,
                    isSync: currentAUIsSync
                )
                emit(sample, pts, dts)
                currentAUAvcc = Data()
                currentAUAvcc.reserveCapacity(65_536)
            } else {
                emit(nil, pts, dts)
            }

            currentAUHasPayload = false
            currentAUHasVCL = false
            currentAUIsSync = false
            currentAUStartOffset = nil
        }
    }

    private static func appendLengthPrefixed(bytes: UnsafePointer<UInt8>, count: Int, into out: inout Data) {
        var bigEndianLen = UInt32(count).bigEndian
        withUnsafeBytes(of: &bigEndianLen) { out.append(contentsOf: $0) }
        out.append(bytes, count: count)
    }

    // MARK: - Streaming ADTS AAC Elementary Stream Reassembler

    /// Reassembles ADTS AAC frames seamlessly across Audio PES boundaries.
    /// Supports both metadata-only Pass 1 scanning (`capturePayloads: false`) and Pass 2 payload streaming.
    private final class AudioESAssembler {
        let capturePayloads: Bool
        var config: AACConfig?

        private var buffer = Data()
        private var consumedOffset: Int = 0
        private var pesAnchors: [(globalOffset: Int, pts: Int64)] = []
        private var anchorHead: Int = 0
        private var activeBasePTS: Int64 = 0
        private var frameIdxInPES: Int = 0

        init(capturePayloads: Bool) {
            self.capturePayloads = capturePayloads
            self.buffer.reserveCapacity(32_768)
        }

        func appendPES(
            payload: Data.SubSequence,
            pts: Int64?,
            emit: (AudioAccessUnit?, Int64) -> Void
        ) {
            guard !payload.isEmpty else { return }
            if let pts {
                pesAnchors.append((globalOffset: consumedOffset + buffer.count, pts: pts))
            }
            buffer.append(contentsOf: payload)
            drainCompleteFrames(flushFinal: false, emit: emit)
        }

        func finish(emit: (AudioAccessUnit?, Int64) -> Void) {
            drainCompleteFrames(flushFinal: true, emit: emit)
            buffer.removeAll(keepingCapacity: false)
            pesAnchors.removeAll(keepingCapacity: false)
        }

        private func drainCompleteFrames(
            flushFinal: Bool,
            emit: (AudioAccessUnit?, Int64) -> Void
        ) {
            let n = buffer.count
            guard n >= 7 else { return }

            var consumed = 0
            buffer.withUnsafeBytes { raw in
                guard let b = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var pos = 0

                while pos + 7 <= n {
                    guard b[pos] == 0xFF, (b[pos + 1] & 0xF0) == 0xF0 else {
                        pos += 1
                        continue
                    }
                    let protectionAbsent = (b[pos + 1] & 0x01) != 0
                    let headerLen = protectionAbsent ? 7 : 9
                    let objectType = ((b[pos + 2] >> 6) & 0x03) + 1
                    let freqIndex = (b[pos + 2] >> 2) & 0x0F
                    let channelCfg = ((b[pos + 2] & 0x01) << 2) | ((b[pos + 3] >> 6) & 0x03)
                    let frameLen = (Int(b[pos + 3] & 0x03) << 11) | (Int(b[pos + 4]) << 3) | (Int(b[pos + 5]) >> 5)

                    guard frameLen > headerLen, Int(freqIndex) < aacSampleRates.count else {
                        pos += 1
                        continue
                    }

                    // Frame spans into the next PES packet: stop here and preserve trailing bytes.
                    if pos + frameLen > n {
                        if !flushFinal {
                            break
                        }
                        pos += 1
                        continue
                    }

                    // Validate next syncword when buffered bytes follow, avoiding false 0xFFF matches inside AAC data.
                    if pos + frameLen + 2 <= n {
                        let next0 = b[pos + frameLen]
                        let next1 = b[pos + frameLen + 1]
                        if next0 != 0xFF || (next1 & 0xF0) != 0xF0 {
                            pos += 1
                            continue
                        }
                    }

                    let frameGlobalOffset = consumedOffset + pos
                    var adoptedNewPTS = false
                    while anchorHead < pesAnchors.count, pesAnchors[anchorHead].globalOffset <= frameGlobalOffset {
                        activeBasePTS = pesAnchors[anchorHead].pts
                        anchorHead += 1
                        adoptedNewPTS = true
                    }
                    if adoptedNewPTS {
                        frameIdxInPES = 0
                    }

                    if config == nil {
                        config = AACConfig(
                            objectType: objectType,
                            freqIndex: freqIndex,
                            sampleRate: aacSampleRates[Int(freqIndex)],
                            channelConfig: max(1, channelCfg)
                        )
                    }

                    if capturePayloads {
                        let aacRaw = Data(bytes: b + pos + headerLen, count: frameLen - headerLen)
                        let sample = AudioAccessUnit(
                            rawAACPayload: aacRaw,
                            pts90k: activeBasePTS,
                            sampleOffsetInPES: frameIdxInPES * 1024
                        )
                        emit(sample, activeBasePTS)
                    } else {
                        emit(nil, activeBasePTS)
                    }

                    frameIdxInPES += 1
                    pos += frameLen
                    consumed = pos
                }

                if consumed == 0 && pos > 0 {
                    consumed = pos
                } else if pos > consumed {
                    consumed = pos
                }
            }

            if anchorHead > 256 {
                pesAnchors.removeFirst(anchorHead)
                anchorHead = 0
            }

            if flushFinal {
                consumedOffset += n
                buffer.removeAll(keepingCapacity: true)
            } else if consumed > 0 {
                buffer = Data(buffer[consumed...])
                consumedOffset += consumed
            }
        }
    }

    // MARK: - CoreMedia Format Descriptions & Streaming Sample Feeding

    private static func makeVideoFormatDescription(
        codec: VideoCodec,
        vps: Data?,
        sps: Data?,
        pps: Data?
    ) throws -> CMVideoFormatDescription {
        var desc: CMFormatDescription?
        let status: OSStatus

        switch codec {
        case .h264:
            guard let sps, let pps else {
                throw RemuxError.noSupportedElementaryStreams
            }
            status = sps.withUnsafeBytes { spsRaw in
                pps.withUnsafeBytes { ppsRaw in
                    let ptrs: [UnsafePointer<UInt8>] = [
                        spsRaw.bindMemory(to: UInt8.self).baseAddress!,
                        ppsRaw.bindMemory(to: UInt8.self).baseAddress!
                    ]
                    let sizes: [Int] = [sps.count, pps.count]
                    return ptrs.withUnsafeBufferPointer { ptrBuf in
                        sizes.withUnsafeBufferPointer { sizeBuf in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: ptrBuf.baseAddress!,
                                parameterSetSizes: sizeBuf.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &desc
                            )
                        }
                    }
                }
            }

        case .hevc:
            guard let vps, let sps, let pps else {
                throw RemuxError.noSupportedElementaryStreams
            }
            status = vps.withUnsafeBytes { vpsRaw in
                sps.withUnsafeBytes { spsRaw in
                    pps.withUnsafeBytes { ppsRaw in
                        let ptrs: [UnsafePointer<UInt8>] = [
                            vpsRaw.bindMemory(to: UInt8.self).baseAddress!,
                            spsRaw.bindMemory(to: UInt8.self).baseAddress!,
                            ppsRaw.bindMemory(to: UInt8.self).baseAddress!
                        ]
                        let sizes: [Int] = [vps.count, sps.count, pps.count]
                        return ptrs.withUnsafeBufferPointer { ptrBuf in
                            sizes.withUnsafeBufferPointer { sizeBuf in
                                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                    allocator: kCFAllocatorDefault,
                                    parameterSetCount: 3,
                                    parameterSetPointers: ptrBuf.baseAddress!,
                                    parameterSetSizes: sizeBuf.baseAddress!,
                                    nalUnitHeaderLength: 4,
                                    extensions: nil,
                                    formatDescriptionOut: &desc
                                )
                            }
                        }
                    }
                }
            }
        }

        guard status == noErr, let valid = desc else {
            throw RemuxError.formatDescriptionCreationFailed(status)
        }
        return valid
    }

    private static func makeAACFormatDescription(config: AACConfig) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(config.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(config.objectType),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(config.channelConfig),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // ISO/IEC 14496-3 2-byte AudioSpecificConfig wrapped in ISO 14496-1 ES_Descriptor magic cookie
        let asc0 = UInt8((config.objectType << 3) | ((config.freqIndex >> 1) & 0x07))
        let asc1 = UInt8(((config.freqIndex & 0x01) << 7) | (config.channelConfig << 3))
        let esdsCookie: [UInt8] = [
            0x03, 0x19,
            0x00, 0x01, 0x00,
            0x04, 0x11,
            0x40, 0x15, 0x00, 0x00, 0x00,
            0x00, 0x01, 0xF4, 0x00,
            0x00, 0x01, 0xF4, 0x00,
            0x05, 0x02, asc0, asc1,
            0x06, 0x01, 0x02
        ]

        var desc: CMAudioFormatDescription?
        let status = esdsCookie.withUnsafeBytes { cookieRaw in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: esdsCookie.count,
                magicCookie: cookieRaw.baseAddress,
                extensions: nil,
                formatDescriptionOut: &desc
            )
        }
        guard status == noErr, let valid = desc else {
            throw RemuxError.formatDescriptionCreationFailed(status)
        }
        return valid
    }

    private final class UncheckedBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private final class RemuxCancellationController: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var finishHandler: (@Sendable (Result<Void, Error>) -> Void)?

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        func register(_ handler: @escaping @Sendable (Result<Void, Error>) -> Void) -> Bool {
            lock.withLock {
                finishHandler = handler
                return cancelled
            }
        }

        func cancel(on queue: DispatchQueue) {
            let handler: (@Sendable (Result<Void, Error>) -> Void)? = lock.withLock {
                cancelled = true
                return finishHandler
            }
            if let handler {
                queue.async {
                    handler(.failure(CancellationError()))
                }
            }
        }
    }

    private static func pumpStreamingSamples(
        writer: AVAssetWriter,
        videoCursor: VideoTSStreamCursor?,
        videoFormat: CMVideoFormatDescription?,
        videoInput: AVAssetWriterInput?,
        cttsShift90k: Int64,
        audioCursor: AudioTSStreamCursor?,
        audioFormat: CMAudioFormatDescription?,
        audioSampleRate: Int,
        audioInput: AVAssetWriterInput?,
        epochOrigin90k: Int64
    ) async throws {
        let pumpQueue = DispatchQueue(label: "com.appautomaton.dysprosium.remux.pump", qos: .userInitiated)
        let writerBox = UncheckedBox(writer)
        let vInBox = videoInput.map(UncheckedBox.init)
        let aInBox = audioInput.map(UncheckedBox.init)
        let vCursorBox = videoCursor.map(UncheckedBox.init)
        let aCursorBox = audioCursor.map(UncheckedBox.init)
        let vDescBox = videoFormat.map(UncheckedBox.init)
        let aDescBox = audioFormat.map(UncheckedBox.init)

        try await withThrowingTaskGroup(of: Void.self) { group in
            if let vInBox, let vCursorBox, let vDescBox {
                group.addTask {
                    let cancellation = RemuxCancellationController()

                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                            let state = UncheckedBox((lastDTS: Int64(-1), finished: false))
                            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                                guard !state.value.finished else { return }
                                state.value.finished = true
                                vInBox.value.markAsFinished()
                                cont.resume(with: result)
                            }
                            if cancellation.register(finish) {
                                pumpQueue.async {
                                    finish(.failure(CancellationError()))
                                }
                                return
                            }

                            vInBox.value.requestMediaDataWhenReady(on: pumpQueue) {
                                while !state.value.finished && vInBox.value.isReadyForMoreMediaData {
                                    if cancellation.isCancelled {
                                        finish(.failure(CancellationError()))
                                        return
                                    }
                                    if writerBox.value.status != .writing {
                                        finish(.failure(RemuxError.assetWriterFailed(writerBox.value.error?.localizedDescription ?? "AVAssetWriter stopped writing")))
                                        return
                                    }
                                    let appendResult: Result<Bool, Error> = autoreleasepool {
                                        guard let next = vCursorBox.value.nextSampleWithNextDTS() else {
                                            return .success(false)
                                        }
                                        let sample = next.sample
                                        var normDTS = max(0, sample.dts90k - epochOrigin90k)
                                        if normDTS <= state.value.lastDTS {
                                            normDTS = state.value.lastDTS + 1
                                        }
                                        state.value.lastDTS = normDTS
                                        let normPTS = max(normDTS, sample.pts90k - epochOrigin90k + cttsShift90k)
                                        let nextDTS: Int64 = if let followingDTS = next.nextDTS90k {
                                            max(normDTS + 1, followingDTS - epochOrigin90k)
                                        } else {
                                            normDTS + 3000
                                        }
                                        let timing = CMSampleTimingInfo(
                                            duration: CMTime(value: max(1, nextDTS - normDTS), timescale: 90_000),
                                            presentationTimeStamp: CMTime(value: normPTS, timescale: 90_000),
                                            decodeTimeStamp: normPTS == normDTS ? .invalid : CMTime(value: normDTS, timescale: 90_000)
                                        )
                                        do {
                                            let sbuf = try makeSampleBuffer(
                                                payload: sample.avccPayload,
                                                formatDescription: vDescBox.value,
                                                timing: timing,
                                                isSync: sample.isSync
                                            )
                                            if !vInBox.value.append(sbuf) {
                                                return .failure(RemuxError.assetWriterFailed(writerBox.value.error?.localizedDescription ?? "Video append returned false"))
                                            }
                                            return .success(true)
                                        } catch {
                                            return .failure(error)
                                        }
                                    }

                                    switch appendResult {
                                    case .success(true):
                                        continue
                                    case .success(false):
                                        finish(.success(()))
                                        return
                                    case .failure(let error):
                                        finish(.failure(error))
                                        return
                                    }
                                }
                            }
                        }
                    } onCancel: {
                        cancellation.cancel(on: pumpQueue)
                    }
                }
            } else {
                videoInput?.markAsFinished()
            }

            if let aInBox, let aCursorBox, let aDescBox {
                let sr = Int32(audioSampleRate)
                let audioFrameDuration = CMTime(value: 1024, timescale: sr)
                group.addTask {
                    let cancellation = RemuxCancellationController()

                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                            let state = UncheckedBox((cursor: Int64(-1), finished: false))
                            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                                guard !state.value.finished else { return }
                                state.value.finished = true
                                aInBox.value.markAsFinished()
                                cont.resume(with: result)
                            }
                            if cancellation.register(finish) {
                                pumpQueue.async {
                                    finish(.failure(CancellationError()))
                                }
                                return
                            }

                            aInBox.value.requestMediaDataWhenReady(on: pumpQueue) {
                                while !state.value.finished && aInBox.value.isReadyForMoreMediaData {
                                    if cancellation.isCancelled {
                                        finish(.failure(CancellationError()))
                                        return
                                    }
                                    if writerBox.value.status != .writing {
                                        finish(.failure(RemuxError.assetWriterFailed(writerBox.value.error?.localizedDescription ?? "AVAssetWriter stopped writing")))
                                        return
                                    }
                                    let appendResult: Result<Bool, Error> = autoreleasepool {
                                        guard let sample = aCursorBox.value.nextSample() else {
                                            return .success(false)
                                        }
                                        let baseNorm90k = max(0, sample.pts90k - epochOrigin90k)
                                        let baseInSampleRate = (baseNorm90k * Int64(audioSampleRate)) / 90_000
                                        var exactSampleTime = baseInSampleRate + Int64(sample.sampleOffsetInPES)
                                        if exactSampleTime <= state.value.cursor {
                                            exactSampleTime = state.value.cursor + 1024
                                        }
                                        state.value.cursor = exactSampleTime
                                        let timing = CMSampleTimingInfo(
                                            duration: audioFrameDuration,
                                            presentationTimeStamp: CMTime(value: exactSampleTime, timescale: sr),
                                            decodeTimeStamp: .invalid
                                        )
                                        do {
                                            let sbuf = try makeSampleBuffer(
                                                payload: sample.rawAACPayload,
                                                formatDescription: aDescBox.value,
                                                timing: timing,
                                                isSync: true
                                            )
                                            if !aInBox.value.append(sbuf) {
                                                return .failure(RemuxError.assetWriterFailed(writerBox.value.error?.localizedDescription ?? "Audio append returned false"))
                                            }
                                            return .success(true)
                                        } catch {
                                            return .failure(error)
                                        }
                                    }

                                    switch appendResult {
                                    case .success(true):
                                        continue
                                    case .success(false):
                                        finish(.success(()))
                                        return
                                    case .failure(let error):
                                        finish(.failure(error))
                                        return
                                    }
                                }
                            }
                        }
                    } onCancel: {
                        cancellation.cancel(on: pumpQueue)
                    }
                }
            } else {
                audioInput?.markAsFinished()
            }

            try await group.waitForAll()
        }
    }

    private static func makeSampleBuffer(
        payload: Data,
        formatDescription: CMFormatDescription,
        timing: CMSampleTimingInfo,
        isSync: Bool
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let len = payload.count

        let status1 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: len,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: len,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status1 == kCMBlockBufferNoErr, let validBlock = blockBuffer else {
            throw RemuxError.formatDescriptionCreationFailed(status1)
        }

        let status2 = payload.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: validBlock,
                offsetIntoDestination: 0,
                dataLength: len
            )
        }
        guard status2 == kCMBlockBufferNoErr else {
            throw RemuxError.formatDescriptionCreationFailed(status2)
        }

        var sampleBuffer: CMSampleBuffer?
        var timingVar = timing
        var sampleSize = len
        let status3 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: validBlock,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingVar,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status3 == noErr, let validSample = sampleBuffer else {
            throw RemuxError.formatDescriptionCreationFailed(status3)
        }

        if !isSync,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(validSample, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_NotSync] = true
        }

        return validSample
    }
}
