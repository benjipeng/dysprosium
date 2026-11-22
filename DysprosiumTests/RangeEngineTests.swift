import AVFoundation
import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore
import Network
import WebKit
import XCTest
@testable import Dysprosium

final class RangeEngineTests: XCTestCase {
    func testMultiLaneRangeWorkStealingByteIntegrity() async throws {
        let server = LoopbackRangeServer()
        await configureStragglerServer(server)
        let payloadSize = 4 * 1024 * 1024 // 4 MiB
        let url = try await server.ensureRunning(sizeBytes: payloadSize)
        let expected = await server.expectedPayload()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dest = tempDir.appendingPathComponent("output.bin")

        let engine = RangeTransferEngine()
        let config = RangeEngineConfiguration(
            maxLanes: 4,
            maxWindowBytes: 1024 * 1024,
            minimumStealBytes: 128 * 1024
        )

        let finalSnapshot = try await engine.download(
            url: url,
            destinationURL: dest,
            configuration: config
        ) { _ in }

        await server.stop()

        let written = try Data(contentsOf: dest)
        XCTAssertEqual(written.count, payloadSize)
        XCTAssertEqual(SHA256.hash(data: written), SHA256.hash(data: expected))
        // Because every 2nd connection was throttled, fast lanes must have stolen work,
        // resulting in > 4 completed slices!
        XCTAssertGreaterThan(finalSnapshot.slices.count, 4, "Expected midpoint work-stealing to split throttled slices")
        XCTAssertTrue(finalSnapshot.slices.allSatisfy(\.isComplete))
    }

    func testSQLiteWALPersistenceTransitionsActiveJobsToPausedWithSlicesIntact() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.sqlite3")
        let store = try TransferStore(databaseURL: dbURL)

        let slice0 = ByteRangeSlice(id: 0, startOffset: 0, currentOffset: 524_288, endOffset: 1_048_575, isActiveLane: true)
        let slice1 = ByteRangeSlice(id: 1, startOffset: 1_048_576, currentOffset: 2_097_152, endOffset: 2_097_151, isActiveLane: false)
        let job = TransferJob(
            sourceURL: URL(string: "https://example.com/archive.tar.zst")!,
            lifecycle: .downloading,
            configuredLanes: 8,
            activeLanes: 1,
            downloadedBytes: 1_572_864,
            totalBytes: 2_097_152,
            slices: [slice0, slice1]
        )
        await store.upsert(job)

        let reloadedStore = try TransferStore(databaseURL: dbURL)
        let jobs = await reloadedStore.loadAllJobs()
        XCTAssertEqual(jobs.count, 1)
        let restored = try XCTUnwrap(jobs.first)
        XCTAssertEqual(restored.lifecycle, .paused)
        XCTAssertEqual(restored.activeLanes, 0)
        XCTAssertEqual(restored.slices.count, 2)
        XCTAssertEqual(restored.slices[0].currentOffset, 524_288)
        XCTAssertFalse(restored.slices[0].isActiveLane)
    }

    func testHLSManifestSelectionAndAES128Decryption() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720
        low/prog.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6400000,RESOLUTION=1920x1080
        high/prog.m3u8
        """
        let base = URL(string: "https://cdn.example.com/live/master.m3u8")!
        let selected = HLSStreamEngine.selectHighestBandwidthVariant(manifestText: master, baseURL: base)
        XCTAssertEqual(selected?.absoluteString, "https://cdn.example.com/live/high/prog.m3u8")

        let media = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:42
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/key.bin",IV=0x0000000000000000000000000000002A
        #EXTINF:4.0,
        seg0.m4s
        #EXTINF:4.0,
        seg1.m4s
        """
        let parsed = HLSStreamEngine.parseMediaPlaylist(manifestText: media, baseURL: selected!)
        XCTAssertEqual(parsed.initializationMapURL?.absoluteString, "https://cdn.example.com/live/high/init.mp4")
        XCTAssertEqual(parsed.segments.count, 2)
        XCTAssertEqual(parsed.segments[0].mediaSequence, 42)
        XCTAssertEqual(parsed.segments[1].url.absoluteString, "https://cdn.example.com/live/high/seg1.m4s")

        // Verify AES-128-CBC round-trip via CommonCrypto
        let key = Data((0..<16).map(UInt8.init))
        let iv = Data((16..<32).map(UInt8.init))
        let plaintext = Data("Dysprosium iPhone Duo Liquid Glass HLS Segment Payload".utf8)
        let ciphertext = try encryptAES128CBC(plaintext: plaintext, key: key, iv: iv)
        let decrypted = try HLSStreamEngine.decryptAES128CBC(ciphertext: ciphertext, key: key, iv: iv)
        XCTAssertEqual(decrypted, plaintext)
    }

    @MainActor
    func testBlinkURLSchemeHandoffEnqueuesWithHeaders() throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("handoff.sqlite3")
        try FileManager.default.createDirectory(at: tempDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDB.deletingLastPathComponent()) }

        let scheduler = TransferScheduler(store: try TransferStore(databaseURL: tempDB))
        scheduler.maxConcurrentTransfers = 0 // Hold in queue for inspection

        let handoff = URL(string: "dysprosium://enqueue?url=https%3A%2F%2Fcdn.example.com%2Fvideo.mp4&referer=https%3A%2F%2Fexample.com&lanes=16&filename=demo.mp4")!
        XCTAssertTrue(scheduler.handleIncomingURL(handoff))
        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertEqual(scheduler.jobs[0].configuredLanes, 16)
        XCTAssertEqual(scheduler.jobs[0].initialHeaders["Referer"], "https://example.com")
        XCTAssertEqual(scheduler.jobs[0].title, "demo.mp4")
    }

    func testAntiPoisoningFakePNGHeaderSanitizerAndDiscontinuityAdFilter() {
        // 1. Construct fake 72-byte PNG header prepended before 4 genuine 188-byte 0x47 MPEG-TS packets
        var poisoned = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        poisoned.append(Data(repeating: 0xAA, count: 64))

        var cleanTS = Data()
        for packetIdx in 0..<4 {
            var pkt = Data(repeating: UInt8(packetIdx + 1), count: 188)
            pkt[0] = 0x47
            cleanTS.append(pkt)
        }
        poisoned.append(cleanTS)

        let sanitized = HLSStreamEngine.sanitizeMPEGTSPayload(poisoned)
        XCTAssertEqual(sanitized.count, cleanTS.count)
        XCTAssertEqual(sanitized, cleanTS, "Expected fake 72-byte PNG header to be cleanly stripped at 0x47 stride")

        // 2. Verify #EXT-X-DISCONTINUITY injected ad-pod stripping on disguised .jpg segments
        let hostileManifest = """
        #EXTM3U
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_000.jpg
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_001.jpg
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_002.jpg
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_003.jpg
        #EXT-X-DISCONTINUITY
        #EXTINF:5.0,
        https://ad-pod.promo.example/preroll/ad_0.ts
        #EXTINF:5.0,
        https://ad-pod.promo.example/preroll/ad_1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_004.jpg
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_005.jpg
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_006.jpg
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_007.jpg
        """
        let parsed = HLSStreamEngine.parseMediaPlaylist(
            manifestText: hostileManifest,
            baseURL: URL(string: "https://cdn-main.stream-host.example/vod/master.txt")!
        )
        XCTAssertEqual(parsed.strippedAdSegmentsCount, 2)
        XCTAssertEqual(parsed.segments.count, 8)
        XCTAssertTrue(parsed.segments.allSatisfy { $0.url.host() == "cdn-main.stream-host.example" })
        XCTAssertEqual(parsed.segments.map(\.sequenceIndex), Array(0..<8))
    }

    func testNativeMPEGTSRemuxProducesPlayableFastStartMP4() async throws {
        let appleTSSegmentURL = URL(
            string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/gear2/fileSequence0.ts"
        )!
        let (rawTS, response) = try await URLSession.shared.data(from: appleTSSegmentURL)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        // Poison the real Apple MPEG-TS segment with a fake 64-byte PNG header, sanitize, then remux natively to .mp4!
        var poisonedTS = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        poisonedTS.append(Data(repeating: 0x42, count: 56))
        poisonedTS.append(rawTS)

        let sanitizedTS = HLSStreamEngine.sanitizeMPEGTSPayload(poisonedTS)
        XCTAssertEqual(sanitizedTS.count, rawTS.count)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tsFile = tempDir.appendingPathComponent("segment.ts")
        let mp4File = tempDir.appendingPathComponent("remuxed.mp4")
        try sanitizedTS.write(to: tsFile)
        XCTAssertFalse(NativeMP4Remuxer.isISOBaseMediaFile(at: tsFile))

        try await NativeMP4Remuxer.remuxMPEGTS(from: tsFile, to: mp4File)
        XCTAssertTrue(NativeMP4Remuxer.isISOBaseMediaFile(at: mp4File))

        let asset = AVURLAsset(url: mp4File)
        let isPlayable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        XCTAssertTrue(isPlayable, "Remuxed .mp4 must be natively playable by AVURLAsset")
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertGreaterThan(duration.seconds, 5.5)

        // Now verify unaligned PES boundaries (`nginx-vod-module` style where H.264 slices & ADTS AAC frames
        // spill across consecutive PES packets) reassemble losslessly and decode every video & audio frame cleanly.
        let unalignedTS = Self.repackageWithUnalignedPESBoundaries(rawTS)
        let unalignedTSFile = tempDir.appendingPathComponent("unaligned.ts")
        let unalignedMP4File = tempDir.appendingPathComponent("unaligned.mp4")
        try unalignedTS.write(to: unalignedTSFile)
        try await NativeMP4Remuxer.remuxMPEGTS(from: unalignedTSFile, to: unalignedMP4File)

        let unalignedAsset = AVURLAsset(url: unalignedMP4File)
        let unalignedPlayable = try await unalignedAsset.load(.isPlayable)
        XCTAssertTrue(unalignedPlayable)

        let origVideoCount = try await Self.countDecodedFrames(asset: asset, mediaType: .video)
        let unalignedVideoCount = try await Self.countDecodedFrames(asset: unalignedAsset, mediaType: .video)
        XCTAssertGreaterThan(origVideoCount, 100)
        XCTAssertEqual(unalignedVideoCount, origVideoCount, "Unaligned PES remux must preserve and decode every video frame")

        let origAudioSamples = try await Self.countDecodedFrames(asset: asset, mediaType: .audio)
        let unalignedAudioSamples = try await Self.countDecodedFrames(asset: unalignedAsset, mediaType: .audio)
        XCTAssertGreaterThan(origAudioSamples, 200_000)
        XCTAssertEqual(unalignedAudioSamples, origAudioSamples, "Unaligned PES remux must preserve and decode every audio sample")
    }

    /// Repackages a clean MPEG-TS segment so the tail of every video & audio PES payload spills into the start
    /// of the next PES packet (matching `nginx-vod-module` muxing) while preserving PAT/PMT and timestamps.
    private static func repackageWithUnalignedPESBoundaries(_ ts: Data) -> Data {
        var patPacket = Data()
        var pmtPacket = Data()
        var pmtPID: UInt16?
        var videoPID: UInt16?
        var audioPID: UInt16?
        var videoPESList: [(header: Data, payload: Data)] = []
        var audioPESList: [(header: Data, payload: Data)] = []
        var curVideo = Data()
        var curAudio = Data()

        func splitPES(_ pes: Data) -> (Data, Data)? {
            guard pes.count >= 9, pes[0] == 0x00, pes[1] == 0x00, pes[2] == 0x01 else { return nil }
            let hlen = 9 + Int(pes[8])
            guard hlen <= pes.count else { return nil }
            var hdr = Data(pes[0..<hlen])
            // Zero PES packet length so variable-length shifted payloads remain valid.
            hdr[4] = 0
            hdr[5] = 0
            return (hdr, Data(pes[hlen...]))
        }

        ts.withUnsafeBytes { raw in
            guard let b = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var off = 0
            while off + 188 <= ts.count {
                let pusi = (b[off + 1] & 0x40) != 0
                let pid = (UInt16(b[off + 1] & 0x1F) << 8) | UInt16(b[off + 2])
                let afc = (b[off + 3] >> 4) & 0x03
                var p = off + 4
                if (afc & 0x02) != 0 { p += 1 + Int(b[off + 4]) }
                if (afc & 0x01) != 0, p < off + 188 {
                    if pid == 0x0000 {
                        if patPacket.isEmpty { patPacket = Data(bytes: b + off, count: 188) }
                        var s = p
                        if pusi { s += 1 + Int(b[s]) }
                        if s + 12 <= off + 188 {
                            pmtPID = (UInt16(b[s + 10] & 0x1F) << 8) | UInt16(b[s + 11])
                        }
                    } else if let knownPMT = pmtPID, pid == knownPMT {
                        if pmtPacket.isEmpty { pmtPacket = Data(bytes: b + off, count: 188) }
                        var s = p
                        if pusi { s += 1 + Int(b[s]) }
                        if s + 12 <= off + 188 {
                            let secLen = (Int(b[s + 1] & 0x0F) << 8) | Int(b[s + 2])
                            let secEnd = min(off + 188, s + 3 + secLen - 4)
                            let progInfo = (Int(b[s + 10] & 0x0F) << 8) | Int(b[s + 11])
                            var es = s + 12 + progInfo
                            while es + 5 <= secEnd {
                                let st = b[es]
                                let esPID = (UInt16(b[es + 1] & 0x1F) << 8) | UInt16(b[es + 2])
                                let esInfo = (Int(b[es + 3] & 0x0F) << 8) | Int(b[es + 4])
                                if st == 0x1B && videoPID == nil { videoPID = esPID }
                                if st == 0x0F && audioPID == nil { audioPID = esPID }
                                es += 5 + esInfo
                            }
                        }
                    } else if let vPID = videoPID, pid == vPID {
                        if pusi, !curVideo.isEmpty {
                            if let s = splitPES(curVideo) { videoPESList.append(s) }
                            curVideo.removeAll(keepingCapacity: true)
                        }
                        curVideo.append(b + p, count: off + 188 - p)
                    } else if let aPID = audioPID, pid == aPID {
                        if pusi, !curAudio.isEmpty {
                            if let s = splitPES(curAudio) { audioPESList.append(s) }
                            curAudio.removeAll(keepingCapacity: true)
                        }
                        curAudio.append(b + p, count: off + 188 - p)
                    }
                }
                off += 188
            }
        }
        if !curVideo.isEmpty, let s = splitPES(curVideo) { videoPESList.append(s) }
        if !curAudio.isEmpty, let s = splitPES(curAudio) { audioPESList.append(s) }

        func shiftTail(_ list: inout [(header: Data, payload: Data)], bytes: Int) {
            guard list.count > 1 else { return }
            var carry = Data()
            for i in 0..<list.count {
                var combined = carry
                combined.append(list[i].payload)
                if i + 1 < list.count && combined.count > bytes + 16 {
                    let cut = combined.count - bytes
                    carry = Data(combined[cut...])
                    list[i].payload = Data(combined[0..<cut])
                } else {
                    carry = Data()
                    list[i].payload = combined
                }
            }
        }

        shiftTail(&videoPESList, bytes: 43)
        shiftTail(&audioPESList, bytes: 37)

        var out = Data()
        out.append(patPacket)
        out.append(pmtPacket)

        func emitPES(_ pes: Data, pid: UInt16, cc: inout UInt8) {
            var offset = 0
            var first = true
            while offset < pes.count {
                let remaining = pes.count - offset
                var pkt = Data(repeating: 0xFF, count: 188)
                pkt[0] = 0x47
                pkt[1] = UInt8((first ? 0x40 : 0x00) | Int((pid >> 8) & 0x1F))
                pkt[2] = UInt8(pid & 0xFF)
                if remaining >= 184 {
                    pkt[3] = 0x10 | (cc & 0x0F)
                    pkt.replaceSubrange(4..<188, with: pes[offset..<(offset + 184)])
                    offset += 184
                } else {
                    let pad = 184 - remaining
                    pkt[3] = 0x30 | (cc & 0x0F)
                    pkt[4] = UInt8(pad - 1)
                    if pad > 1 { pkt[5] = 0x00 }
                    pkt.replaceSubrange((4 + pad)..<188, with: pes[offset..<(offset + remaining)])
                    offset += remaining
                }
                cc = (cc + 1) & 0x0F
                first = false
                out.append(pkt)
            }
        }

        var vCC: UInt8 = 0
        var aCC: UInt8 = 0
        if let vPID = videoPID {
            for item in videoPESList {
                var full = item.header
                full.append(item.payload)
                emitPES(full, pid: vPID, cc: &vCC)
            }
        }
        if let aPID = audioPID {
            for item in audioPESList {
                var full = item.header
                full.append(item.payload)
                emitPES(full, pid: aPID, cc: &aCC)
            }
        }
        return out
    }

    private static func countDecodedFrames(asset: AVURLAsset, mediaType: AVMediaType) async throws -> Int {
        let tracks = try await asset.loadTracks(withMediaType: mediaType)
        guard let track = tracks.first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = mediaType == .video
            ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            : [AVFormatIDKey: kAudioFormatLinearPCM]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let sb = output.copyNextSampleBuffer() {
            count += mediaType == .audio ? CMSampleBufferGetNumSamples(sb) : 1
        }
        XCTAssertEqual(reader.status, .completed, "AVAssetReader failed decoding \(mediaType.rawValue): \(reader.error?.localizedDescription ?? "none")")
        return count
    }

    @MainActor
    func testDataDrivenFilterCompilerProducesValidWebKitBytecode() async throws {
        let dnrSample = """
        [
          {"id": 1, "action": {"type": "block"}, "condition": {"requestDomains": ["html-load.com"], "resourceTypes": ["script", "xmlhttprequest"], "domainType": "thirdParty"}},
          {"id": 2, "action": {"type": "allow"}, "condition": {"urlFilter": "||publisher.example/bait-ads.js^", "initiatorDomains": ["publisher.example"]}}
        ]
        """.data(using: .utf8)!

        let abpSample = """
        [Adblock Plus 2.0]
        ! Comment line
        ||popunder-network.example^$popup,third-party
        /adb_script/*
        ##.cookie-modal-backdrop
        ##.adblock-warning-banner
        publisher.example##.sponsored-slot
        @@||publisher.example/px.gif$image,domain=publisher.example
        """

        let dnrBuckets = CleanroomContentBlocker.parseDNRJSONToBuckets(dnrSample)
        let abpBuckets = CleanroomContentBlocker.parseABPFilterTextToBuckets(abpSample)

        XCTAssertEqual(dnrBuckets.blockAndCosmeticRules.count, 1)
        XCTAssertEqual(dnrBuckets.allowRules.count, 1)
        XCTAssertEqual(abpBuckets.blockAndCosmeticRules.count, 4) // 2 network + 1 domain cosmetic + 1 batched global cosmetic
        XCTAssertEqual(abpBuckets.allowRules.count, 1)

        let combined = dnrBuckets.blockAndCosmeticRules + abpBuckets.blockAndCosmeticRules + dnrBuckets.allowRules + abpBuckets.allowRules
        let jsonData = try JSONSerialization.data(withJSONObject: combined)
        let jsonText = try XCTUnwrap(String(data: jsonData, encoding: .utf8))

        let compiled = try await WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "dysprosium.test.filters",
            encodedContentRuleList: jsonText
        )
        XCTAssertNotNil(compiled, "Expected WKContentRuleListStore C++ compiler to accept translated DNR + ABP + Anti-Adblock rules")
    }

    @MainActor
    func testStoryboardRejectionAndContainerWrappedHLSResolution() async throws {
        let storyboardURL = URL(string: "https://edge.cdn.media-host.example/video/sample/stream/clip.Faa.mp4")!
        let emptyRangeTemplateURL = URL(string: "https://edge.cdn.media-host.example/video/sample/stream/clip.haa.tar?r_file=chunklist.m3u8&r_range=")!
        let tsSegmentInsideTarURL = URL(string: "https://edge.cdn.media-host.example/video/sample/stream/clip.haa.tar?r_file=media-0.ts&r_type=video%2Fmp2t&r_range=512-628243")!
        let realTarHLSURL = URL(string: "https://edge.cdn.media-host.example/video/sample/stream/clip.haa.tar?r_file=chunklist.m3u8&r_type=application%2Fvnd.apple.mpegurl&r_range=314169856-314175992")!

        XCTAssertNil(CleanroomWebKitSession.classifyStreamFormat(url: storyboardURL, hint: "inline-script"))
        XCTAssertNil(CleanroomWebKitSession.classifyStreamFormat(url: emptyRangeTemplateURL, hint: "inline-script"))
        XCTAssertNil(CleanroomWebKitSession.classifyStreamFormat(url: tsSegmentInsideTarURL, hint: "perf"))
        XCTAssertEqual(CleanroomWebKitSession.classifyStreamFormat(url: realTarHLSURL, hint: "inline-script"), .hls)

        let resolver = MediaResolver()
        let plan = try await resolver.resolve(url: realTarHLSURL, preferredFilename: "Workout [1080p].mp4")
        XCTAssertEqual(plan.kind, .hlsStream)
        XCTAssertEqual(plan.outputFilename, "Workout [1080p].mp4")
        XCTAssertEqual(plan.tracks.first?.isHLSManifest, true)
    }

    @MainActor
    func testBrowserStoreMultiTabAndEphemeralPrivacy() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DysprosiumTabTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = CleanroomBrowserStore(customStateDirectory: tempDir)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertFalse(store.activeSession.isPrivate)
        XCTAssertTrue(store.activeSession.webView.configuration.websiteDataStore.isPersistent)

        // Open background tab without switching focus
        let firstID = store.activeTabID
        let bgTab = store.openNewTab(urlString: nil, isPrivate: false, activate: false)
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.activeTabID, firstID)

        // Open foreground ephemeral private tab
        let privTab = store.openNewTab(urlString: nil, isPrivate: true, activate: true)
        XCTAssertEqual(store.tabs.count, 3)
        XCTAssertEqual(store.activeTabID, privTab.id)
        XCTAssertTrue(store.activeSession.isPrivate)
        XCTAssertFalse(store.activeSession.webView.configuration.websiteDataStore.isPersistent)

        store.closeTab(id: privTab.id)
        store.closeTab(id: bgTab.id)
        XCTAssertEqual(store.tabs.count, 1)
    }

    func testScriptletCompilerParsesUBOSyntaxAdGuardSyntaxAliasesAndExceptions() {
        let filterText = """
        [Adblock Plus 2.0]
        ! uBlock Origin ##+js(...) with excluded subdomain, quoted comma, escaped comma, and empty positional arg
        video-example.test,~live.video-example.test,mirror-example.test##+js(set, player.config.ads, false)
        video-example.test##+js(aopr, AaDetector)
        video-example.test##+js(aopw.js, adblockFlag)
        video-example.test##+js(acis, String.fromCharCode, /a\\,b\\.c/)
        video-example.test##+js(aeld, , "detect,Wall")
        video-example.test##+js(nostif, adCheck, 1500)
        video-example.test##+js(nano-sib, nagTimer, 500)
        video-example.test##+js(no-fetch-if, method:HEAD /probe)
        video-example.test##+js(no-xhr-if, /\\/adtag\\//)
        video-example.test##+js(json-prune, adPlacements playerAds)

        ! AdGuard #%#//scriptlet(...) syntax with ubo- prefix
        player-example.test,~embed.player-example.test#%#//scriptlet('ubo-set-constant', 'cleanStream', 'true')
        player-example.test#%#//scriptlet('ubo-aopr', 'BlockProbe')

        ! Full cancellation via #@#+js(...) using canonical name against short alias
        cancel-example.test##+js(aopr, cancelledProp)
        cancel-example.test#@#+js(abort-on-property-read, cancelledProp)

        ! Subdomain narrowing via #@#+js(...)
        video-example.test##+js(set, scopedFlag, 1)
        sub.video-example.test#@#+js(set-constant, scopedFlag, 1)

        ! Safety rejections: wildcard-only, global empty-domain, and unknown primitives
        *##+js(aopr, globalWildcard)
        ##+js(aopr, globalEmpty)
        video-example.test##+js(unsupported-custom-gadget, arg1)
        """

        let buckets = WebKitRuleCompiler.parseABPFilterTextToBuckets(filterText)
        XCTAssertEqual(buckets.scriptletRules.count, 13)
        XCTAssertEqual(buckets.totalCount, 13)

        XCTAssertFalse(buckets.scriptletRules.contains { $0.positiveDomains.contains("cancel-example.test") })
        XCTAssertFalse(buckets.scriptletRules.contains { $0.primitive == "unsupported-custom-gadget" })

        let setRule = buckets.scriptletRules.first { $0.args == ["player.config.ads", "false"] }
        XCTAssertEqual(setRule?.primitive, "set-constant")
        XCTAssertEqual(setRule?.positiveDomains, ["video-example.test", "mirror-example.test"])
        XCTAssertEqual(setRule?.excludedDomains, ["live.video-example.test"])

        let acisRule = buckets.scriptletRules.first { $0.primitive == "abort-current-inline-script" }
        XCTAssertEqual(acisRule?.args, ["String.fromCharCode", "/a,b\\.c/"])

        let aeldRule = buckets.scriptletRules.first { $0.primitive == "addEventListener-defuser" }
        XCTAssertEqual(aeldRule?.args, ["", "detect,Wall"])

        let nostifRule = buckets.scriptletRules.first { $0.primitive == "no-setTimeout-if" }
        XCTAssertEqual(nostifRule?.args, ["adCheck", "1500"])

        let nanoSibRule = buckets.scriptletRules.first { $0.primitive == "adjust-setInterval" }
        XCTAssertEqual(nanoSibRule?.args, ["nagTimer", "500"])

        let adGuardSetRule = buckets.scriptletRules.first { $0.positiveDomains == ["player-example.test"] && $0.primitive == "set-constant" }
        XCTAssertEqual(adGuardSetRule?.args, ["cleanStream", "true"])
        XCTAssertEqual(adGuardSetRule?.excludedDomains, ["embed.player-example.test"])

        let narrowedRule = buckets.scriptletRules.first { $0.args == ["scopedFlag", "1"] }
        XCTAssertEqual(narrowedRule?.positiveDomains, ["video-example.test"])
        XCTAssertEqual(narrowedRule?.excludedDomains, ["sub.video-example.test"])
    }

    func testGeneratedScriptletRuntimeExecutesAllPrimitivesAndHonorsDomainExclusions() throws {
        let sampleFilter = """
        video-example.test,~live.video-example.test##+js(set, player.config.adsEnabled, false)
        video-example.test##+js(set-constant, emptyText, '')
        video-example.test##+js(set-constant, stubFn, trueFunc)
        video-example.test##+js(aopr, AaDetector)
        video-example.test##+js(aopw, adblockDetected)
        video-example.test##+js(acis, Math.random, /adblock_wall\\.js/)
        video-example.test##+js(aeld, , detectWall)
        video-example.test##+js(nostif, adblockCheck, 1500)
        video-example.test##+js(nosiif, NagLoop, 500)
        video-example.test##+js(no-fetch-if, method:HEAD /probe)
        video-example.test##+js(no-xhr-if, /\\/adtag\\//)
        video-example.test##+js(json-prune, adPlacements pods.*.ads, videoDetails.id)
        """

        let buckets = WebKitRuleCompiler.parseABPFilterTextToBuckets(sampleFilter)
        let runtimeJS = BrowserInjectedScripts.buildScriptletRuntimeScript(rules: buckets.scriptletRules)
        XCTAssertFalse(runtimeJS.isEmpty)
        XCTAssertTrue(BrowserInjectedScripts.buildScriptletRuntimeScript(rules: []).isEmpty)

        // 1. Verify active execution on matching child subdomain `vod.video-example.test`
        let activeCtx = try XCTUnwrap(JSContext())
        var jsException: String?
        activeCtx.exceptionHandler = { _, exc in
            jsException = exc?.toString()
        }
        activeCtx.evaluateScript("""
        var window = globalThis;
        window.location = { hostname: 'vod.video-example.test' };
        window.document = { currentScript: null };
        var recordedEvents = [];
        window.addEventListener = function(type, fn) { recordedEvents.push(type); };
        var recordedTimers = [];
        window.setTimeout = function(fn, delay) { recordedTimers.push('t:' + delay); return 1; };
        window.setInterval = function(fn, delay) { recordedTimers.push('i:' + delay); return 2; };
        var networkFetches = 0;
        window.fetch = function(url, init) { networkFetches++; return Promise.resolve({ status: 503 }); };
        function XMLHttpRequest() { this.networkSent = false; }
        XMLHttpRequest.prototype.open = function(m, u) { this.u = u; };
        XMLHttpRequest.prototype.setRequestHeader = function() {};
        XMLHttpRequest.prototype.send = function() { this.networkSent = true; };
        window.XMLHttpRequest = XMLHttpRequest;
        """)
        activeCtx.evaluateScript(runtimeJS)
        XCTAssertNil(jsException)

        let outcome = activeCtx.evaluateScript("""
        (function() {
            window.player = { config: { adsEnabled: true } };
            if (window.player.config.adsEnabled !== false) return 'fail:set-dot';
            if (window.emptyText !== '') return 'fail:set-empty';
            if (typeof window.stubFn !== 'function' || window.stubFn() !== true) return 'fail:set-trueFunc';

            let aoprThrew = false;
            try { void window.AaDetector; } catch (e) { aoprThrew = (e instanceof ReferenceError); }
            if (!aoprThrew) return 'fail:aopr';

            let aopwThrew = false;
            try { window.adblockDetected = 1; } catch (e) { aopwThrew = (e instanceof ReferenceError); }
            if (!aopwThrew) return 'fail:aopw';

            window.document.currentScript = { src: '', textContent: 'bootstrapPlayer()' };
            if (typeof Math.random() !== 'number') return 'fail:acis-clean';
            let acisThrew = false;
            window.document.currentScript = { src: '', textContent: 'inject("adblock_wall.js")' };
            try { Math.random(); } catch (e) { acisThrew = (e instanceof ReferenceError); }
            window.document.currentScript = null;
            if (!acisThrew) return 'fail:acis-abort';

            window.addEventListener('load', function detectWall() {});
            window.addEventListener('load', function initCleanUI() {});
            if (recordedEvents.length !== 1) return 'fail:aeld';

            window.setTimeout(function() { return 'adblockCheck'; }, 1500);
            window.setTimeout(function() { return 'keepAlive'; }, 1500);
            window.setInterval(function() { return 'NagLoop'; }, 500);
            if (recordedTimers.join(',') !== 't:1500') return 'fail:timers';

            window.fetch('https://vod.video-example.test/probe', { method: 'HEAD' });
            window.fetch('https://vod.video-example.test/api/video', { method: 'GET' });
            if (networkFetches !== 1) return 'fail:no-fetch-if';

            const blockedXhr = new XMLHttpRequest();
            blockedXhr.open('GET', 'https://cdn-example.test/adtag/vast.xml');
            blockedXhr.send();
            if (blockedXhr.networkSent || blockedXhr.status !== 200 || blockedXhr.readyState !== 4) return 'fail:no-xhr-if';

            const pruned = JSON.parse('{"videoDetails":{"id":"clip1"},"adPlacements":[1],"pods":[{"ads":[2],"title":"main"}]}');
            if ('adPlacements' in pruned || ('ads' in pruned.pods[0]) || pruned.pods[0].title !== 'main') return 'fail:json-prune';

            return 'OK';
        })()
        """)?.toString()
        XCTAssertEqual(outcome, "OK")

        // 2. Verify excluded subdomain `live.video-example.test` skips excluded rule
        let excludedCtx = try XCTUnwrap(JSContext())
        excludedCtx.evaluateScript("""
        var window = globalThis;
        window.location = { hostname: 'live.video-example.test' };
        window.document = { currentScript: null };
        """)
        excludedCtx.evaluateScript(runtimeJS)
        let excludedAdsEnabled = excludedCtx.evaluateScript("""
        window.player = { config: { adsEnabled: true } };
        window.player.config.adsEnabled;
        """)?.toBool()
        XCTAssertEqual(excludedAdsEnabled, true, "Excluded subdomain must not apply set-constant trap")
    }

    @MainActor
    func testContentBlockerSeedsUnbreakQuickFixesAndPersistsCompiledScriptlets() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let migrationDir = tempRoot.appendingPathComponent("migration", isDirectory: true)
        let compileDir = tempRoot.appendingPathComponent("compile", isDirectory: true)
        try FileManager.default.createDirectory(at: migrationDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: compileDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // 1. Verify legacy subscriptions.json missing ubo-unbreak & ubo-quick-fixes auto-appends and persists them
        let legacyOnly = CleanroomContentBlocker.defaultCommunitySubscriptions.filter {
            $0.id != "ubo-unbreak" && $0.id != "ubo-quick-fixes"
        }
        let legacyData = try JSONEncoder().encode(legacyOnly)
        try legacyData.write(to: migrationDir.appendingPathComponent("subscriptions.json"))

        let migratedBlocker = CleanroomContentBlocker(storageDirectory: migrationDir)
        XCTAssertTrue(migratedBlocker.subscriptions.contains { $0.id == "ubo-unbreak" && $0.maxRuleBudget == 12_000 })
        XCTAssertTrue(migratedBlocker.subscriptions.contains { $0.id == "ubo-quick-fixes" && $0.maxRuleBudget == 12_000 })

        let persistedManifest = try JSONDecoder().decode(
            [FilterSubscription].self,
            from: Data(contentsOf: migrationDir.appendingPathComponent("subscriptions.json"))
        )
        XCTAssertTrue(persistedManifest.contains { $0.id == "ubo-unbreak" })
        XCTAssertTrue(persistedManifest.contains { $0.id == "ubo-quick-fixes" })

        // 2. Verify off-MainActor scriptlet compilation, scriptlets_compiled.json persistence, and launch restoration
        let now = Date()
        let offlineSubs: [FilterSubscription] = CleanroomContentBlocker.defaultCommunitySubscriptions.map { seed in
            var copy = seed
            if seed.id == "ubo-unbreak" {
                copy.isEnabled = true
                copy.lastSyncedAt = now
            } else {
                copy.isEnabled = false
            }
            return copy
        }
        try JSONEncoder().encode(offlineSubs).write(to: compileDir.appendingPathComponent("subscriptions.json"))
        let cachedFilterPayload = """
        video-example.test##+js(aopr, AaDetector)
        player-example.test#%#//scriptlet('ubo-set-constant', 'adsEnabled', 'false')
        ||ad-banner.test^$third-party
        """
        try Data(cachedFilterPayload.utf8).write(to: compileDir.appendingPathComponent("ubo-unbreak.cache"))

        let blocker1 = CleanroomContentBlocker(storageDirectory: compileDir)
        _ = await blocker1.ensureCompiledLists()
        XCTAssertEqual(blocker1.compiledScriptletRules.count, 2)
        XCTAssertFalse(blocker1.compiledScriptletRuntimeSource.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compileDir.appendingPathComponent("scriptlets_compiled.json").path))

        // Fresh launch instance restores scriptlets_compiled.json off `@MainActor` and wires WKUserContentController
        let blocker2 = CleanroomContentBlocker(storageDirectory: compileDir)
        _ = await blocker2.ensureCompiledLists()
        XCTAssertEqual(blocker2.compiledScriptletRules.count, 2)
        XCTAssertFalse(blocker2.compiledScriptletRuntimeSource.isEmpty)

        let controller = WKUserContentController()
        // Host with matching scriptlets receives its minimal per-host runtime; unmatched host receives 0 bytes of scriptlets!
        XCTAssertNotNil(blocker2.scriptletSource(forHost: "player-example.test"))
        XCTAssertNil(blocker2.scriptletSource(forHost: "clean-site.test"))

        blocker2.installUserScripts(on: controller, shieldEnabled: true, forHost: "player-example.test")
        XCTAssertGreaterThanOrEqual(controller.userScripts.count, 3)

        blocker2.installUserScripts(on: controller, shieldEnabled: false, forHost: "clean-site.test")
        XCTAssertLessThanOrEqual(controller.userScripts.count, 4) // optional 0-frame FingerprintShield + optional macOS UA + optional DarkReader + streamInterceptor (0 ad-block scriptlets)

        // Verify official Dark Reader 4.9.135 Dynamic Engine bundle, dark-sites.config, and per-host dynamic-theme-fixes splitting
        XCTAssertTrue(DarkReaderEngine.shared.isKnownNativeDarkHost("netflix.com"))
        XCTAssertNil(DarkReaderEngine.shared.makeUserScriptSource(forHost: "netflix.com", enabled: true))

        let genericFix = DarkReaderEngine.shared.dynamicFix(forHost: "example.com")
        XCTAssertLessThan(genericFix.invert.count, 40, "Common fix must NOT swallow site-specific blocks")
        XCTAssertLessThan(genericFix.css.count, 12_000, "Common CSS must remain compact (~few KB, not 823 KB)")

        let wikiFix = DarkReaderEngine.shared.dynamicFix(forHost: "en.wikipedia.org")
        XCTAssertTrue(wikiFix.invert.contains(".mw-logo-wordmark"))
        XCTAssertLessThan(wikiFix.css.count, 16_000)

        let biliFix = DarkReaderEngine.shared.dynamicFix(forHost: "www.bilibili.com")
        XCTAssertTrue(biliFix.css.contains("--darkreader-neutral-background"))
        XCTAssertFalse(biliFix.invert.contains(".mw-logo-wordmark"), "Site fixes must stay isolated per host")

        let wikiScript = DarkReaderEngine.shared.makeUserScriptSource(forHost: "en.wikipedia.org", enabled: true)
        XCTAssertNotNil(wikiScript)
        XCTAssertTrue(wikiScript?.contains("DarkReader") == true)
        XCTAssertLessThan(wikiScript?.count ?? Int.max, 180_000, "Host-scoped Dark Reader script must stay compact (~125 KB)")
    }

    @MainActor
    func testDarkReaderDynamicModeInRealWKWebView() async throws {
        let scriptSrc = try XCTUnwrap(DarkReaderEngine.shared.makeUserScriptSource(forHost: "en.wikipedia.org", enabled: true))
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        // Force dark prefers-color-scheme match in WKWebView test regardless of host trait
        let forceDarkMQ = """
        window.matchMedia = function(q) {
            return { matches: q.includes('dark'), media: q, addEventListener: function(){}, removeEventListener: function(){} };
        };
        """
        ucc.addUserScript(WKUserScript(source: forceDarkMQ, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: scriptSrc, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 669, height: 951), configuration: config)
        let html = """
        <!DOCTYPE html>
        <html class="skin-theme-clientpref-day">
        <head><style>body { background-color: #ffffff; color: #202122; }</style></head>
        <body><h1>Dysprosium</h1><p>Element 66</p></body>
        </html>
        """
        wv.loadHTMLString(html, baseURL: URL(string: "https://en.wikipedia.org/wiki/Dysprosium"))
        var diag = ""
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(120))
            diag = (try? await wv.evaluateJavaScript("""
            JSON.stringify({
                href: location.href,
                title: document.title,
                readyState: document.readyState,
                hasHook: typeof window.__dysprosiumSetAutoDark,
                hasDR: Boolean(window.DarkReader),
                enabled: Boolean(window.DarkReader && window.DarkReader.isEnabled()),
                scheme: document.documentElement.getAttribute('data-darkreader-scheme'),
                bodyBg: getComputedStyle(document.body).backgroundColor,
                htmlBg: getComputedStyle(document.documentElement).backgroundColor,
                htmlFilter: getComputedStyle(document.documentElement).filter,
                lastErr: window.__dysprosiumDarkErr || null
            })
            """) as? String) ?? ""
            if diag.contains("\"enabled\":true") {
                break
            }
        }
        print("DARKREADER_WKWEBVIEW_DIAG:", diag)
        XCTAssertTrue(diag.contains("\"enabled\":true"), "DarkReader did not activate: \(diag)")
        XCTAssertTrue(diag.contains("\"htmlFilter\":\"none\""), "Dynamic mode must NOT use root CSS filter: \(diag)")
    }

    private func configureStragglerServer(_ server: LoopbackRangeServer) async {
        await server.configureThrottling(everyNth: 2, delayNanoseconds: 25_000_000)
    }

    func testUnifiedBrowserSQLiteSchemaFTS5AndTenThousandVisits() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DysprosiumPlacesPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let now = Date()
        let legacyFoldersJSON = tempDir.appendingPathComponent("favorite_folders.json")
        let legacyBookmarksJSON = tempDir.appendingPathComponent("bookmarks.json")
        let legacyHistoryJSON = tempDir.appendingPathComponent("history.json")

        let seedFolder = BrowserFavoriteFolder(id: "folder-media", title: "Media")
        try JSONEncoder().encode([seedFolder]).write(to: legacyFoldersJSON)
        try JSONEncoder().encode([
            BrowserBookmark(title: "Bilibili", urlString: "https://www.bilibili.com/en", folderID: "folder-media")
        ]).write(to: legacyBookmarksJSON)
        try JSONEncoder().encode([
            BrowserHistoryEntry(title: "崩坏星穹铁道 PV", urlString: "https://legacy.example/item", visitedAt: now)
        ]).write(to: legacyHistoryJSON)

        let store = BrowserSQLiteStore(stateDirectory: tempDir)
        XCTAssertEqual(store.schemaVersion, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("favorites_backup.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFoldersJSON.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyBookmarksJSON.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyHistoryJSON.path))
        XCTAssertEqual(store.loadFolders().map(\.title), ["Media"])
        XCTAssertEqual(store.loadBookmarks().first?.folderID, "folder-media")
        XCTAssertEqual(store.totalCount(), 1)

        // Foreign-key ON DELETE SET NULL ungrouping check
        store.deleteFolder(id: "folder-media", keepBookmarks: true)
        XCTAssertTrue(store.loadFolders().isEmpty)
        XCTAssertNil(store.loadBookmarks().first?.folderID)

        // Open tabs & site rules round-trip
        let tabID = UUID()
        store.saveOpenTabs([PersistedOpenTab(id: tabID, urlString: "https://duckduckgo.com", title: "DDG", sortOrder: 100, isActive: true)])
        XCTAssertEqual(store.loadOpenTabs().first?.id, tabID)
        store.upsertSiteRule(SiteRuleRecord(host: "www.bilibili.com", shieldMode: 1, darkMode: -1, uaMode: 2, pageZoom: 1.25))
        XCTAssertEqual(store.siteRule(forHost: "bilibili.com")?.darkMode, -1)
        XCTAssertEqual(store.siteRule(forHost: "bilibili.com")?.pageZoom ?? 0, 1.25, accuracy: 0.001)

        var synthetic: [BrowserHistoryEntry] = []
        synthetic.reserveCapacity(10_000)
        for i in 0..<10_000 {
            let dayOffset = TimeInterval(-(i % 45) * 86_400 - (i % 3_600))
            // Coprime with 45 (`gcd(45, 1501) == 1`) so each of the 10,000 visits lands on a distinct `(day, place)` pair
            let canonicalIdx = i % 1_501
            synthetic.append(
                BrowserHistoryEntry(
                    title: "Article #\(canonicalIdx) — High Concurrency Systems",
                    urlString: "https://site-\(canonicalIdx % 120).example/post/\(canonicalIdx)",
                    visitedAt: now.addingTimeInterval(dayOffset)
                )
            )
        }
        store.bulkInsertHistory(synthetic)
        let baselineTotal = store.totalCount()
        XCTAssertGreaterThan(baselineTotal, 8_000)

        let t0 = ContinuousClock.now
        store.recordVisit(url: URL(string: "https://legacy.example/item")!, title: "崩坏星穹铁道 PV Updated", visitedAt: now.addingTimeInterval(5))
        let upsertElapsed = ContinuousClock.now - t0
        XCTAssertEqual(store.totalCount(), baselineTotal)

        let t1 = ContinuousClock.now
        let summaries = store.queryDaySummaries()
        let summaryElapsed = ContinuousClock.now - t1
        XCTAssertEqual(summaries.count, 45)

        let t2 = ContinuousClock.now
        let ftsLatin = store.queryEntriesPage(searchQuery: "article #999", limit: 80, offset: 0)
        let ftsSearchElapsed = ContinuousClock.now - t2
        XCTAssertFalse(ftsLatin.isEmpty)

        // Verify both >=3 char CJK FTS5 trigram AND 2-char CJK fallback
        XCTAssertFalse(store.queryEntriesPage(searchQuery: "星穹铁", limit: 10).isEmpty)
        XCTAssertFalse(store.queryEntriesPage(searchQuery: "星穹", limit: 10).isEmpty)
        XCTAssertEqual(store.queryTopPlaces(matching: "星穹铁").first?.visitCount, 2)

        print("PERF_PLACES_FTS5 upsert=\(upsertElapsed) summaries=\(summaryElapsed) ftsTrigram=\(ftsSearchElapsed)")
    }

    func testHLSManifestPermanentHTTP404FailsFastWithoutRetryStorm() async {
        final class CounterBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func reset() { lock.withLock { value = 0 } }
            func increment() { lock.withLock { value += 1 } }
            var current: Int { lock.withLock { value } }
        }
        final class Counting404URLProtocol: URLProtocol, @unchecked Sendable {
            static let counter = CounterBox()

            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Self.counter.increment()
                let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        Counting404URLProtocol.counter.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Counting404URLProtocol.self]
        let session = URLSession(configuration: cfg)
        let engine = HLSStreamEngine(session: session)

        do {
            _ = try await engine.resolveMediaPlaylist(
                from: URL(string: "https://dead-cdn.example/hls/master.m3u8")!,
                headers: [:]
            )
            XCTFail("Expected HTTP 404 to throw")
        } catch let nsErr as NSError {
            XCTAssertEqual(nsErr.code, 404)
        }
        XCTAssertEqual(Counting404URLProtocol.counter.current, 1, "Permanent HTTP 404 must fail fast without retrying 5 times")
    }

    func testHLSStreamEmitsInitialConnectProgressWithTotalSegmentsAndActiveLanes() async throws {
        final class MockHLSURLProtocol: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let url = request.url!
                let body: Data
                if url.lastPathComponent.hasSuffix(".m3u8") {
                    let playlist = """
                    #EXTM3U
                    #EXT-X-VERSION:3
                    #EXT-X-TARGETDURATION:4
                    #EXTINF:4.0,
                    seg0.ts
                    #EXTINF:4.0,
                    seg1.ts
                    #EXT-X-ENDLIST
                    """
                    body = Data(playlist.utf8)
                } else {
                    var ts = Data(repeating: 0x00, count: 188 * 3)
                    ts[0] = 0x47
                    ts[188] = 0x47
                    ts[376] = 0x47
                    body = ts
                }
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockHLSURLProtocol.self]
        let engine = HLSStreamEngine(session: URLSession(configuration: cfg))
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("hls-init-progress-\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: dest) }

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [HLSProgressUpdate] = []
            func append(_ item: HLSProgressUpdate) { lock.withLock { items.append(item) } }
            var snapshot: [HLSProgressUpdate] { lock.withLock { items } }
        }
        let collector = Collector()

        let final = try await engine.downloadPlaylist(
            manifestURL: URL(string: "https://mock-hls.example/master.m3u8")!,
            headers: [:],
            destinationURL: dest,
            concurrency: 4
        ) { update in
            collector.append(update)
        }

        let updates = collector.snapshot
        XCTAssertGreaterThanOrEqual(updates.count, 2)
        XCTAssertEqual(updates.first?.completedSegments, 0)
        XCTAssertEqual(updates.first?.totalSegments, 2)
        XCTAssertGreaterThan(updates.first?.activeLanes ?? 0, 0)
        XCTAssertEqual(final.completedSegments, 2)
        XCTAssertEqual(final.totalSegments, 2)
    }

    func testHLSPreloadedManifestBypassesCloudflare403OnManifestOrigin() async throws {
        final class Origin403CDNSegmentProtocol: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let url = request.url!
                if url.host() == "waf-origin.example" {
                    // Manifest host rejects out-of-band URLSession requests with HTTP 403.
                    let resp = HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                // CDN segment host serves PNG-disguised MPEG-TS cleanly.
                var disguised = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                disguised.append(Data(repeating: 0xAA, count: 62))
                var ts = Data(repeating: 0x00, count: 188 * 3)
                ts[0] = 0x47
                ts[188] = 0x47
                ts[376] = 0x47
                disguised.append(ts)
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: disguised)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Origin403CDNSegmentProtocol.self]
        let engine = HLSStreamEngine(session: URLSession(configuration: cfg))
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("hls-preloaded-\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: dest) }

        let capturedPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXTINF:10.0,
        https://public-cdn.example/seg0.image
        #EXTINF:10.0,
        https://public-cdn.example/seg1.image
        #EXT-X-ENDLIST
        """

        let result = try await engine.downloadPlaylist(
            manifestURL: URL(string: "https://waf-origin.example/stream/token/index-v1-a1.m3u8")!,
            headers: ["Origin": "https://waf-origin.example", "Referer": "https://waf-origin.example/v/abc"],
            destinationURL: dest,
            concurrency: 4,
            preloadedManifestText: capturedPlaylist
        ) { _ in }

        XCTAssertEqual(result.completedSegments, 2)
        XCTAssertEqual(result.totalSegments, 2)
        XCTAssertEqual(result.downloadedBytes, Int64(188 * 3 * 2))
    }

    @MainActor
    func testAntiAdblockDefuserNeutralizesJustDetectAdblockAndBaitGlobals() async throws {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.addUserScript(
            WKUserScript(
                source: BrowserInjectedScripts.genericAntiAdblockDefuser,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        config.userContentController = ucc

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: config)
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <script>
        "use strict";
        // Simulate hostile strict-mode UMD bundle (`just-detect-adblock`) trying to overwrite globalThis.justDetectAdblock.
        (function(g) {
            g.justDetectAdblock = {
                detectAnyAdblocker: function() { return Promise.resolve(true); },
                isDetected: function() { return true; }
            };
        })(globalThis);
        // Simulate hostile FuckAdBlock overwrite attempt.
        window.FuckAdBlock = function() { this.check = function() { return true; }; };
        window.fuckAdBlock = { onDetected: function(fn) { fn(); } };

        window.__result = {
            defined: window.justDetectAdblock !== undefined,
            cRAds: window.cRAds === true,
            xRds: window.xRds === false,
            syncDetected: window.justDetectAdblock.isDetected(),
            fabDetectedCalled: false,
            fabNotDetectedCalled: false,
            asyncDetected: null
        };
        window.fuckAdBlock.onDetected(function() { window.__result.fabDetectedCalled = true; });
        window.fuckAdBlock.onNotDetected(function() { window.__result.fabNotDetectedCalled = true; });
        window.justDetectAdblock.detectAnyAdblocker().then(function(detected) {
            window.__result.asyncDetected = detected;
        });
        </script>
        </head>
        <body></body>
        </html>
        """
        wv.loadHTMLString(html, baseURL: URL(string: "https://embed-player.test/e/demo"))
        var json = ""
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(80))
            json = (try? await wv.evaluateJavaScript("JSON.stringify(window.__result || null)") as? String) ?? ""
            if json.contains("\"asyncDetected\":false") {
                break
            }
        }
        XCTAssertTrue(json.contains("\"defined\":true"), "justDetectAdblock must never be undefined: \(json)")
        XCTAssertTrue(json.contains("\"cRAds\":true"), "cRAds bait global must be true: \(json)")
        XCTAssertTrue(json.contains("\"xRds\":true"), "xRds bait global must be false: \(json)")
        XCTAssertTrue(json.contains("\"syncDetected\":false"), "isDetected() must stay false after overwrite attempt: \(json)")
        XCTAssertTrue(json.contains("\"asyncDetected\":false"), "detectAnyAdblocker() must resolve false: \(json)")
        XCTAssertTrue(json.contains("\"fabDetectedCalled\":false"), "fuckAdBlock.onDetected must be neutralized: \(json)")
        XCTAssertTrue(json.contains("\"fabNotDetectedCalled\":true"), "fuckAdBlock.onNotDetected must invoke callback: \(json)")
    }

    func testTransferJobLegacyDecodingAndInsightFallbacks() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(25.0)
        let original = TransferJob(
            sourceURL: URL(string: "https://cdn.example.com/media/clip.mp4")!,
            title: "clip.mp4",
            siteDomain: "cdn.example.com",
            kind: .directRange,
            lifecycle: .completed,
            configuredLanes: 16,
            downloadedBytes: 250_000_000,
            totalBytes: 250_000_000,
            throughputSamples: [8_000_000, 12_500_000, 11_000_000],
            slices: [
                ByteRangeSlice(id: 0, startOffset: 0, currentOffset: 125_000_000, endOffset: 124_999_999),
                ByteRangeSlice(id: 1, startOffset: 125_000_000, currentOffset: 250_000_000, endOffset: 249_999_999)
            ],
            createdAt: start,
            updatedAt: end
        )

        let rawData = try JSONEncoder().encode(original)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: rawData) as? [String: Any])
        obj.removeValue(forKey: "completedAt")
        obj.removeValue(forKey: "activeDurationSeconds")
        obj.removeValue(forKey: "peakSpeedBytesPerSec")
        obj.removeValue(forKey: "averageSpeedBytesPerSec")
        let legacyData = try JSONSerialization.data(withJSONObject: obj)

        let decoded = try JSONDecoder().decode(TransferJob.self, from: legacyData)
        XCTAssertEqual(try XCTUnwrap(decoded.effectiveDurationSeconds), 25.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(decoded.effectiveAverageSpeedBytesPerSec), 10_000_000, accuracy: 1.0)
        XCTAssertEqual(try XCTUnwrap(decoded.effectivePeakSpeedBytesPerSec), 12_500_000, accuracy: 1.0)
        XCTAssertEqual(decoded.segmentTopologySummary, "16× Lanes · 2 Byte-Range Slices")
        XCTAssertTrue(decoded.compactInsightSummary.contains("2× slices"))
        XCTAssertTrue(decoded.compactInsightSummary.contains("25s"))
    }

    @MainActor
    func testTransferSchedulerRetainsInsightsAcrossLocalFileRemovalAndClearsHistoryCleanly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DysprosiumInsights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try TransferStore(databaseURL: tempDir.appendingPathComponent("state.sqlite3"))
        let scheduler = TransferScheduler(store: store)
        let server = LoopbackRangeServer()
        await server.configureThrottling(everyNth: 0, delayNanoseconds: 0)
        let benchURL = try await server.ensureRunning(sizeBytes: 2 * 1024 * 1024)
        defer { Task { await server.stop() } }
        let job = scheduler.enqueue(url: benchURL, lanes: 4, suggestedTitle: "InsightsTest-\(UUID().uuidString).bin")

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let current = scheduler.job(for: job.id),
               current.lifecycle == .completed || current.lifecycle == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let completed = try XCTUnwrap(scheduler.job(for: job.id))
        XCTAssertEqual(completed.lifecycle, .completed, "Transfer failed: \(completed.errorMessage ?? "unknown")")
        XCTAssertNotNil(completed.completedAt)
        XCTAssertGreaterThan(completed.activeDurationSeconds ?? 0, 0)
        XCTAssertGreaterThan(completed.averageSpeedBytesPerSec ?? 0, 0)
        XCTAssertGreaterThan(completed.peakSpeedBytesPerSec ?? 0, 0)
        XCTAssertGreaterThan(completed.slices.count, 1)

        let localURL = try XCTUnwrap(scheduler.vaultFileURL(for: completed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))

        // Remove ONLY the local file while preserving SQLite transfer insights.
        scheduler.removeLocalFileKeepingHistory(jobID: completed.id, fileURL: localURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertNotNil(scheduler.job(for: completed.id), "Completed insights record must remain in history after removing local file")
        XCTAssertNil(scheduler.vaultFileURL(for: completed))

        // Clear off-device history cleanly.
        scheduler.clearDownloadHistory(onlyOffDevice: true)
        XCTAssertNil(scheduler.job(for: completed.id), "Off-device history entry must clear cleanly")
    }

    func testDarkReaderSSRFRejectsPrivateLoopbackAndMetadataAddresses() {
        let blocked = [
            "http://127.0.0.1/secret.css",
            "http://localhost:8080/admin.css",
            "http://192.168.1.1/router.css",
            "http://10.0.0.5/internal.css",
            "http://172.16.0.10/corp.css",
            "http://169.254.169.254/latest/meta-data/",
            "http://[::1]/loopback.css",
            "http://0x7f000001/hex-loopback.css",
            "http://router.local/style.css",
            "http://intranet/style.css",
            "file:///etc/passwd",
            "https://user:pass@example.com/style.css"
        ]
        for raw in blocked {
            let url = URL(string: raw)!
            XCTAssertFalse(
                DarkReaderEngine.isAllowedPublicStylesheetURL(url),
                "SSRF guard must block \(raw)"
            )
        }
    }

    func testHostNormalizerAndOmniboxURLResolutionHeuristics() {
        // HostNormalizer must never corrupt ".com." via substring replacement
        XCTAssertEqual(LiveContainerEnvironment.HostNormalizer.normalize("WWW.YouTube.COM."), "youtube.com")
        XCTAssertEqual(LiveContainerEnvironment.HostNormalizer.normalize("m.bilibili.com"), "bilibili.com")
        XCTAssertEqual(LiveContainerEnvironment.HostNormalizer.normalize("mobile.example.org."), "example.org")
        XCTAssertEqual(LiveContainerEnvironment.HostNormalizer.normalize("medium.com"), "medium.com")

        // Local dev & LAN hosts navigate over HTTP
        XCTAssertEqual(
            CleanroomWebKitSession.resolveNavigationURL(from: "localhost:8080/api")?.absoluteString,
            "http://localhost:8080/api"
        )
        XCTAssertEqual(
            CleanroomWebKitSession.resolveNavigationURL(from: "192.168.1.1:3000")?.absoluteString,
            "http://192.168.1.1:3000"
        )

        // Filenames/frameworks route to search instead of broken https://Node.js
        let nodeSearch = CleanroomWebKitSession.resolveNavigationURL(from: "Node.js", searchEngine: .duckDuckGo)
        XCTAssertEqual(nodeSearch?.host, "duckduckgo.com")

        // Reserved query characters (+, &, #, =) must be strictly percent-encoded
        let specialSearch = CleanroomWebKitSession.resolveNavigationURL(
            from: "C++ & Swift #1 = fast",
            searchEngine: .google
        )
        XCTAssertEqual(specialSearch?.host, "www.google.com")
        let comps = specialSearch.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(comps?.queryItems?.first(where: { $0.name == "q" })?.value, "C++ & Swift #1 = fast")

        // Custom search engine template support
        let custom = CleanroomWebKitSession.resolveNavigationURL(
            from: "webkit",
            searchEngine: .custom,
            customSearchTemplate: "https://search.example.test/?query=%s"
        )
        XCTAssertEqual(custom?.absoluteString, "https://search.example.test/?query=webkit")
    }

    @MainActor
    func testBookmarksNetscapeHTMLAndJSONExportImportRoundTripWithDeduplication() async throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("dysprosium-bm-a-\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory
            .appendingPathComponent("dysprosium-bm-b-\(UUID().uuidString)", isDirectory: true)
        let dirC = FileManager.default.temporaryDirectory
            .appendingPathComponent("dysprosium-bm-c-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
            try? FileManager.default.removeItem(at: dirC)
        }

        let source = CleanroomBrowserStore(customStateDirectory: dirA)
        await source.waitForInitialHydration()
        let folder = try XCTUnwrap(source.createFolder(title: "Research"))
        source.addBookmark(title: "WebKit Docs & Notes", urlString: "https://webkit.org/docs", folderID: folder.id)
        source.addBookmark(title: "Swift Evolution", urlString: "https://swift.org/evolution", folderID: nil)

        let htmlData = source.exportBookmarksNetscapeHTML()
        let jsonData = source.exportBookmarksJSON()
        XCTAssertTrue(String(decoding: htmlData, as: UTF8.self).contains("NETSCAPE-Bookmark-file-1"))

        let htmlTarget = CleanroomBrowserStore(customStateDirectory: dirB)
        await htmlTarget.waitForInitialHydration()
        let importedHTML = htmlTarget.importBookmarks(from: htmlData)
        XCTAssertGreaterThanOrEqual(importedHTML, 2)
        XCTAssertTrue(htmlTarget.bookmarks.contains { $0.urlString == "https://webkit.org/docs" })
        XCTAssertTrue(htmlTarget.favoriteFolders.contains { $0.title == "Research" })
        // Re-importing same file must deduplicate to 0 new entries
        XCTAssertEqual(htmlTarget.importBookmarks(from: htmlData), 0)

        let jsonTarget = CleanroomBrowserStore(customStateDirectory: dirC)
        await jsonTarget.waitForInitialHydration()
        let importedJSON = jsonTarget.importBookmarks(from: jsonData)
        XCTAssertGreaterThanOrEqual(importedJSON, 2)
        XCTAssertEqual(jsonTarget.importBookmarks(from: jsonData), 0)
    }

    func testSQLiteReclaimStorageShrinksDiskFootprintAfterClearingHistory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dysprosium-reclaim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = BrowserSQLiteStore(stateDirectory: tempDir)
        let now = Date()
        var entries: [BrowserHistoryEntry] = []
        entries.reserveCapacity(2_500)
        for idx in 0..<2_500 {
            entries.append(
                BrowserHistoryEntry(
                    title: "Long Benchmark Entry Title #\(idx) With Extra Indexed Search Tokens",
                    urlString: "https://host-\(idx % 200).example.test/articles/\(idx)?ref=bench",
                    visitedAt: now.addingTimeInterval(TimeInterval(-idx * 60))
                )
            )
        }
        store.bulkInsertHistory(entries)
        let peakBytes = store.databaseDiskUsageBytes()
        XCTAssertGreaterThan(peakBytes, 200_000)

        store.clearAll()
        store.reclaimStorage(fullVacuum: true)
        let reclaimedBytes = store.databaseDiskUsageBytes()
        XCTAssertLessThan(reclaimedBytes, peakBytes / 2, "VACUUM + WAL truncate must physically reclaim ghost SQLite storage")
    }

    @MainActor
    func testLazyWebViewAllocationAndLRUHibernationCycle() {
        let session = CleanroomWebKitSession(id: UUID(), isPrivate: false)
        XCTAssertFalse(session.hasLiveWebView, "Dormant tabs must allocate zero WKWebView instances on init")
        XCTAssertFalse(session.isHibernated)

        session.stageDeferredRestore(urlString: "https://example.com", title: "Example")
        XCTAssertFalse(session.hasLiveWebView, "Staged restored tab must remain dormant until hydrated")
        _ = session.ensureWebView()
        XCTAssertTrue(session.hasLiveWebView)
        XCTAssertFalse(session.isHibernated)

        session.hibernateWebView()
        XCTAssertFalse(session.hasLiveWebView, "Hibernation must release backing WKWebView")
        XCTAssertTrue(session.isHibernated)

        _ = session.ensureWebView()
        XCTAssertTrue(session.hasLiveWebView)
        XCTAssertFalse(session.isHibernated)
    }

    func testBrowserTopChromeLayoutAcrossAllDuoPosturesAndFallback() {
        // 1. iPhone Duo Outer Portrait (466×678, trailing 84 pt vertical bar -> 382×644 safe area)
        let outerPortrait = BrowserTopChromeLayout.resolve(
            size: CGSize(width: 382, height: 644),
            topLeadingCornerInset: CGSize(width: 8, height: 8),
            topTrailingCornerInset: CGSize(width: 59, height: 59),
            occlusionRects: [CGRect(x: 382, y: 0, width: 84, height: 174)],
            verticalHingeRect: nil,
            verticalBarEdge: .trailing,
            windowTopSafeAreaInset: 0
        )
        XCTAssertEqual(outerPortrait.top, 29)
        XCTAssertEqual(outerPortrait.leading, 14)
        XCTAssertEqual(outerPortrait.trailing, 12)
        XCTAssertNil(outerPortrait.maxWidth)
        XCTAssertEqual(outerPortrait.compactTop, 6)
        XCTAssertEqual(outerPortrait.compactLeading, 14)
        XCTAssertEqual(outerPortrait.compactTrailing, 12)

        // 2. iPhone Duo Inner Landscape Flat (951×669, trailing 84 pt vertical bar -> 867×635 safe area)
        let innerLandscape = BrowserTopChromeLayout.resolve(
            size: CGSize(width: 867, height: 635),
            topLeadingCornerInset: CGSize(width: 59, height: 59),
            topTrailingCornerInset: CGSize(width: 59, height: 59),
            occlusionRects: [CGRect(x: 867, y: 0, width: 84, height: 124)],
            verticalHingeRect: nil,
            verticalBarEdge: .trailing,
            windowTopSafeAreaInset: 0
        )
        XCTAssertEqual(innerLandscape.top, 14)
        XCTAssertEqual(innerLandscape.leading, 18)
        XCTAssertEqual(innerLandscape.trailing, 12)
        XCTAssertEqual(innerLandscape.maxWidth, DysprosiumTokens.Space.omniboxMaxWidth)
        XCTAssertEqual(innerLandscape.compactTop, 6)

        // 3. iPhone Duo Book Pose (active 40 pt vertical .division hinge at x = 455.5..495.5)
        let bookPose = BrowserTopChromeLayout.resolve(
            size: CGSize(width: 867, height: 635),
            topLeadingCornerInset: CGSize(width: 59, height: 59),
            topTrailingCornerInset: CGSize(width: 59, height: 59),
            occlusionRects: [CGRect(x: 867, y: 0, width: 84, height: 124)],
            verticalHingeRect: CGRect(x: 455.5, y: 0, width: 40, height: 635),
            verticalBarEdge: .trailing,
            windowTopSafeAreaInset: 0
        )
        XCTAssertEqual(bookPose.leading, 505.5)
        XCTAssertEqual(bookPose.compactLeading, 505.5)
        XCTAssertEqual(bookPose.maxWidth ?? 0, 349.5, accuracy: 0.5)

        // 4. iPhone Duo Inner Portrait (669×951, horizontal bar, 82 pt top band with occlusion(525, 0, 144×82))
        let innerPortrait = BrowserTopChromeLayout.resolve(
            size: CGSize(width: 669, height: 917),
            topLeadingCornerInset: CGSize(width: 59, height: 59),
            topTrailingCornerInset: CGSize(width: 59, height: 59),
            occlusionRects: [CGRect(x: 525, y: 0, width: 144, height: 82)],
            verticalHingeRect: nil,
            verticalBarEdge: .none,
            windowTopSafeAreaInset: 82
        )
        XCTAssertEqual(innerPortrait.top, 30, "Inner Portrait expanded 36 pt chrome must sit inside the 82 pt top band (midY = 48)")
        XCTAssertEqual(innerPortrait.leading, 18)
        XCTAssertEqual(innerPortrait.trailing, 144)
        XCTAssertEqual(innerPortrait.compactTop, 10, "Compact domain pill must tuck near the top edge")
        XCTAssertEqual(innerPortrait.compactLeading, 18)
        XCTAssertEqual(innerPortrait.compactTrailing, 18, "Compact pill must true-center horizontally when clear of top-right occlusion")

        // 5. iPhone Duo Inner Portrait with widened Live Activity occlusion (467, 0, 202×82) still centers cleanly
        let innerPortraitLiveActivity = BrowserTopChromeLayout.resolve(
            size: CGSize(width: 669, height: 917),
            topLeadingCornerInset: CGSize(width: 59, height: 59),
            topTrailingCornerInset: CGSize(width: 59, height: 59),
            occlusionRects: [CGRect(x: 467, y: 0, width: 202, height: 82)],
            verticalHingeRect: nil,
            verticalBarEdge: .none,
            windowTopSafeAreaInset: 82
        )
        XCTAssertEqual(innerPortraitLiveActivity.trailing, 202)
        XCTAssertEqual(innerPortraitLiveActivity.compactTrailing, 18)

        // 5b. Continuous single-capsule interpolation from expanded (p = 0) to dead-center compact pill (p = 1)
        let expandedFrame = innerPortrait.omniboxFrame(
            viewportWidth: 669,
            isVerticalRailActive: false,
            hasBackButton: false,
            trailingClusterWidth: 116,
            compactPillWidth: 118,
            progress: 0
        )
        let midFrame = innerPortrait.omniboxFrame(
            viewportWidth: 669,
            isVerticalRailActive: false,
            hasBackButton: false,
            trailingClusterWidth: 116,
            compactPillWidth: 118,
            progress: 0.5
        )
        let compactFrame = innerPortrait.omniboxFrame(
            viewportWidth: 669,
            isVerticalRailActive: false,
            hasBackButton: false,
            trailingClusterWidth: 116,
            compactPillWidth: 118,
            progress: 1
        )
        XCTAssertEqual(expandedFrame, CGRect(x: 18, y: 30, width: 383, height: 36))
        XCTAssertEqual(midFrame.minY, 20, accuracy: 0.01)
        XCTAssertEqual(midFrame.height, 30, accuracy: 0.01)
        XCTAssertEqual(compactFrame.minY, 10, accuracy: 0.01)
        XCTAssertEqual(compactFrame.height, 24, accuracy: 0.01)
        XCTAssertEqual(compactFrame.midX, 334.5, accuracy: 0.01, "Compact domain pill must sit dead-center on Inner Portrait")

        // 6. Standard Dynamic Island / notched iPhone fallback (no top-right occlusion, safeAreaInsets.top = 59)
        let standardPhone = BrowserTopChromeLayout.resolve(
            size: CGSize(width: 393, height: 818),
            topLeadingCornerInset: CGSize(width: 47, height: 47),
            topTrailingCornerInset: CGSize(width: 47, height: 47),
            occlusionRects: [],
            verticalHingeRect: nil,
            verticalBarEdge: .none,
            windowTopSafeAreaInset: 59
        )
        XCTAssertEqual(standardPhone.top, 65)
        XCTAssertEqual(standardPhone.compactTop, 61)
    }

    func testBrowserChromeScrollStateHysteresisAndBounceProtection() {
        var state = BrowserChromeScrollState()
        let topInset: CGFloat = 74
        let viewportHeight: CGFloat = 850
        let longContentHeight: CGFloat = 3_000

        // Short page never collapses
        XCTAssertFalse(
            state.handleScroll(
                contentOffsetY: 50,
                topInset: topInset,
                bottomInset: 0,
                contentHeight: 820,
                viewportHeight: viewportHeight,
                isUserDriven: true
            )
        )
        XCTAssertEqual(state.progress, 0, accuracy: 0.001)

        // Seed initial top offset, then drag down continuously over the 56 pt travel band
        _ = state.handleScroll(contentOffsetY: -topInset, topInset: topInset, bottomInset: 0, contentHeight: longContentHeight, viewportHeight: viewportHeight, isUserDriven: true)
        _ = state.handleScroll(contentOffsetY: -topInset + 20, topInset: topInset, bottomInset: 0, contentHeight: longContentHeight, viewportHeight: viewportHeight, isUserDriven: true)
        XCTAssertGreaterThan(state.progress, 0.2)
        XCTAssertLessThan(state.progress, 0.5)

        // Mid-flight finger lift settles cleanly based on velocity or threshold
        XCTAssertTrue(state.settleIfPartial(preferMinimize: true))
        XCTAssertEqual(state.progress, 1, accuracy: 0.001)
        XCTAssertTrue(state.isMinimized)

        // Continued downward scrolling once clamped at 1.0 emits zero SwiftUI updates
        XCTAssertFalse(state.handleScroll(contentOffsetY: -topInset + 400, topInset: topInset, bottomInset: 0, contentHeight: longContentHeight, viewportHeight: viewportHeight, isUserDriven: true))
        XCTAssertEqual(state.progress, 1, accuracy: 0.001)

        // Bottom rubber-band overscroll recoil does not flicker open
        let maxY = longContentHeight - viewportHeight + topInset
        XCTAssertFalse(state.handleScroll(contentOffsetY: -topInset + maxY + 35, topInset: topInset, bottomInset: 0, contentHeight: longContentHeight, viewportHeight: viewportHeight, isUserDriven: true))
        XCTAssertFalse(state.handleScroll(contentOffsetY: -topInset + maxY, topInset: topInset, bottomInset: 0, contentHeight: longContentHeight, viewportHeight: viewportHeight, isUserDriven: true))
        XCTAssertEqual(state.progress, 1, accuracy: 0.001)

        // Intentional upward scroll smoothly reduces progress 1 -> 0
        XCTAssertFalse(state.handleScroll(contentOffsetY: -topInset + 500, topInset: topInset, bottomInset: 0, contentHeight: longContentHeight, viewportHeight: viewportHeight, isUserDriven: false))
        XCTAssertTrue(state.handleScroll(contentOffsetY: -topInset + 440, topInset: topInset, bottomInset: 0, contentHeight: longContentHeight, viewportHeight: viewportHeight, isUserDriven: true))
        XCTAssertEqual(state.progress, 0, accuracy: 0.001)
        XCTAssertFalse(state.isMinimized)

        // External pill tap re-anchors cleanly so subsequent downward scroll tracks smoothly from 0
        state.syncExternal(progress: 0, currentEffectiveY: 520)
        XCTAssertTrue(state.handleScroll(contentOffsetY: -topInset + 548, topInset: topInset, bottomInset: 0, contentHeight: longContentHeight, viewportHeight: viewportHeight, isUserDriven: true))
        XCTAssertEqual(state.progress, 0.5, accuracy: 0.02)
        XCTAssertTrue(state.settleIfPartial(preferMinimize: nil))
        XCTAssertEqual(state.progress, 1, accuracy: 0.001)

        // Reaching top of page (e.g. programmatic status-bar tap) always expands to 0
        XCTAssertTrue(state.handleScroll(contentOffsetY: -topInset + 4, topInset: topInset, bottomInset: 0, contentHeight: longContentHeight, viewportHeight: viewportHeight, isUserDriven: false))
        XCTAssertEqual(state.progress, 0, accuracy: 0.001)
    }

    func testBrowserChromeScrollStateRemainsStableWhenTopInsetCollapsesDynamically() {
        var state = BrowserChromeScrollState()
        let expandedTop: CGFloat = 56
        let viewportHeight: CGFloat = 669
        let contentHeight: CGFloat = 3_000

        // Start resting at document top (`contentOffsetY = -56`, `topInset = 56`)
        _ = state.handleScroll(contentOffsetY: -56, topInset: expandedTop, bottomInset: 34, contentHeight: contentHeight, viewportHeight: viewportHeight, isUserDriven: true)
        XCTAssertEqual(state.progress, 0, accuracy: 0.001)

        // Scroll smoothly across the 56 pt travel band while `topInset` simultaneously shrinks 56 -> 0
        let offsets: [CGFloat] = [-36, -16, 0, 4, 24, 120]
        for offsetY in offsets {
            let currentTop = max(0, expandedTop * (1 - state.progress))
            _ = state.handleScroll(
                contentOffsetY: offsetY,
                topInset: currentTop,
                bottomInset: 34,
                contentHeight: contentHeight,
                viewportHeight: viewportHeight,
                isUserDriven: true
            )
        }
        XCTAssertEqual(state.progress, 1, accuracy: 0.001, "Collapsing topInset to 0 while pushing downward past y=0 must never snap progress back to 0")

        // Mutating topInset alone at constant `contentOffsetY = 250` must inject zero scroll delta (zero feedback oscillation)
        XCTAssertFalse(state.handleScroll(contentOffsetY: 250, topInset: 0, bottomInset: 34, contentHeight: contentHeight, viewportHeight: viewportHeight, isUserDriven: true))
        XCTAssertFalse(state.handleScroll(contentOffsetY: 250, topInset: 56, bottomInset: 34, contentHeight: contentHeight, viewportHeight: viewportHeight, isUserDriven: true))
        XCTAssertFalse(state.handleScroll(contentOffsetY: 250, topInset: 0, bottomInset: 34, contentHeight: contentHeight, viewportHeight: viewportHeight, isUserDriven: true))
        XCTAssertEqual(state.progress, 1, accuracy: 0.001)

        // Scrolling upward smoothly re-expands chrome to 0 even while topInset grows 0 -> 56
        XCTAssertTrue(state.handleScroll(contentOffsetY: 222, topInset: 0, bottomInset: 34, contentHeight: contentHeight, viewportHeight: viewportHeight, isUserDriven: true))
        XCTAssertEqual(state.progress, 0.5, accuracy: 0.02)
        XCTAssertTrue(state.handleScroll(contentOffsetY: 194, topInset: 28, bottomInset: 34, contentHeight: contentHeight, viewportHeight: viewportHeight, isUserDriven: true))
        XCTAssertEqual(state.progress, 0, accuracy: 0.001)
    }

    @MainActor
    func testFingerprintShieldSkipsGetComputedStyleOnNormalLayoutAndCachesUserScript() async throws {
        // 1. Reusing identical (seed, mask, profile) returns the exact same WKUserScript instance (JSC bytecode cache hit)
        let seed = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let s1 = FingerprintShieldEngine.makeUserScript(seed: seed, maskFoldableScreen: true, profile: .iosSafari)
        let s2 = FingerprintShieldEngine.makeUserScript(seed: seed, maskFoldableScreen: true, profile: .iosSafari)
        XCTAssertTrue(s1 === s2, "FingerprintShieldEngine must cache WKUserScript instances to preserve JSC bytecode cache")

        // 2. Global unscoped :has(...) is rejected while domain-scoped :has(...) stays compiled
        let abp = """
        ##div:has(> .ad-banner)
        example.com##div:has(> .ad-banner)
        """
        let buckets = WebKitRuleCompiler.parseABPFilterTextToBuckets(abp)
        XCTAssertEqual(buckets.blockAndCosmeticRules.count, 1, "Only domain-scoped :has() rule should compile")

        // 3. Normal layout getBoundingClientRect() invokes ZERO window.getComputedStyle calls while inline font probes still farble
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addUserScript(s1)
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 466, height: 678), configuration: cfg)
        let html = """
        <!doctype html><html><body>
          <div id="normal-div">Regular paragraph text in page body</div>
          <span id="normal-span">Regular inline label</span>
          <span id="font-probe" style="font-family: Georgia, serif; font-size: 72px;">mmMwWLliI0fiflO&amp;1</span>
        </body></html>
        """
        wv.loadHTMLString(html, baseURL: URL(string: "https://example.com/")!)
        var diag = ""
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(80))
            diag = (try? await wv.evaluateJavaScript("""
            (() => {
              if (document.readyState !== 'complete') return '';
              let csCalls = 0;
              const origCS = window.getComputedStyle;
              window.getComputedStyle = function() { csCalls++; return origCS.apply(this, arguments); };
              const nd = document.getElementById('normal-div');
              const ns = document.getElementById('normal-span');
              const fp = document.getElementById('font-probe');
              for (let i = 0; i < 30; i++) {
                nd.getBoundingClientRect();
                ns.getBoundingClientRect();
              }
              const csAfterNormal = csCalls;
              const r1 = fp.getBoundingClientRect().width;
              const r2 = fp.getBoundingClientRect().width;
              return JSON.stringify({ csAfterNormal, csTotal: csCalls, probeDeterministic: Math.abs(r1 - r2) < 1e-9, probeWidth: r1 });
            })()
            """) as? String) ?? ""
            if !diag.isEmpty { break }
        }
        XCTAssertTrue(diag.contains("\"csAfterNormal\":0"), "Normal layout getBoundingClientRect must invoke 0 getComputedStyle calls: \(diag)")
        XCTAssertTrue(diag.contains("\"csTotal\":0"), "Inline font probe must also avoid forced getComputedStyle: \(diag)")
        XCTAssertTrue(diag.contains("\"probeDeterministic\":true"), "Font probe width must stay deterministic: \(diag)")
    }

    @MainActor
    func testDarkReaderPresetsAndRefinementOnTailwindGradientsSVGAndHamburger() async throws {
        // 1. Verify calibrated presets avoid black-crushing contrast < 100 and never inject blanket ignoreImageAnalysis: ["*"].
        for preset in DarkReaderEngine.WebDarkThemePreset.allCases {
            XCTAssertTrue(preset.themeJSONLiteral.contains("\"contrast\":100"), "Preset \(preset) must keep contrast at 100")
            let activation = try XCTUnwrap(DarkReaderEngine.shared.makeActivationScript(forHost: "fingerprint.com", preset: preset))
            XCTAssertFalse(activation.contains("\"ignoreImageAnalysis\":[\"*\"]"), "Must not force blanket ignoreImageAnalysis wildcard")
        }

        // 2. Verify live WKWebView refinement against the exact Tailwind v4 CSS-var gradient, dark SVG logo,
        //    already-white SVG logo, and CSS-drawn hamburger bars from fingerprint.com/demo/.
        let cfg = WKWebViewConfiguration()
        let forceDarkMQ = """
        window.matchMedia = function(q) {
            return { matches: q.includes('dark'), media: q, addEventListener: function(){}, removeEventListener: function(){} };
        };
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: forceDarkMQ, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        let scriptSrc = try XCTUnwrap(
            DarkReaderEngine.shared.makeUserScriptSource(forHost: "fingerprint.com", enabled: true, preset: .oled)
        )
        cfg.userContentController.addUserScript(
            WKUserScript(source: scriptSrc, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 669, height: 900), configuration: cfg)

        let darkLogoSVG = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 120 24' fill='none'><path d='M0 0h10v10H0z' fill='#F35B22'/><path d='M20 0h80v10H20z' fill='#181916'/></svg>"
        let lightLogoSVG = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 120 24' fill='none'><path d='M20 0h80v10H20z' fill='#FFFFFF'/></svg>"
        let darkLogoDataURL = "data:image/svg+xml;base64,\(Data(darkLogoSVG.utf8).base64EncodedString())"
        let lightLogoDataURL = "data:image/svg+xml;base64,\(Data(lightLogoSVG.utf8).base64EncodedString())"

        let html = """
        <!doctype html>
        <html>
        <head>
          <style>
            body { background: #ffffff; color: #181916; margin: 0; }
            section { --accent-rgb: 243, 91, 34; }
            .fp-card {
              width: 500px;
              height: 200px;
              background: linear-gradient(128deg, #fff 27%, rgba(var(--accent-rgb), 0.08) 92.75%), #fff;
            }
            .hamburger-btn { width: 24px; height: 24px; background: transparent; border: 0; position: relative; }
            .hamburger-bar { display: block; width: 16px; height: 2px; background-color: #202021; margin: 3px 0; }
          </style>
        </head>
        <body>
          <header style="background:#fff; padding:12px; display:flex; justify-content:space-between;">
            <img id="dark-logo" src="\(darkLogoDataURL)" width="128" height="23">
            <img id="light-logo" src="\(lightLogoDataURL)" width="128" height="23">
            <button id="menu-btn" class="hamburger-btn" aria-label="Mobile Menu">
              <span id="ham-bar" class="hamburger-bar"></span>
            </button>
          </header>
          <section>
            <div id="fp-card" class="fp-card">Visitor ID Card</div>
          </section>
        </body>
        </html>
        """

        wv.loadHTMLString(html, baseURL: URL(string: "https://fingerprint.com/demo/")!)

        var diag = ""
        for _ in 0..<35 {
            try await Task.sleep(for: .milliseconds(100))
            diag = (try? await wv.evaluateJavaScript("""
            (() => {
              const card = document.getElementById('fp-card');
              const dLogo = document.getElementById('dark-logo');
              const lLogo = document.getElementById('light-logo');
              const bar = document.getElementById('ham-bar');
              if (!card || !dLogo || !bar) return '';
              const gradFixed = card.getAttribute('data-dy-grad') === '1';
              const svgFixed = dLogo.getAttribute('data-dy-dark-svg') === '1';
              const barFixed = bar.getAttribute('data-dy-dark-bar') === '1';
              if (!gradFixed || !svgFixed || !barFixed) return '';
              return JSON.stringify({
                bodyBg: getComputedStyle(document.body).backgroundColor,
                cardImg: getComputedStyle(card).backgroundImage,
                cardBg: getComputedStyle(card).backgroundColor,
                darkLogoFixed: svgFixed,
                lightLogoUntouched: lLogo.getAttribute('data-dy-dark-svg') === null,
                barBg: getComputedStyle(bar).backgroundColor,
                barFixed: barFixed
              });
            })()
            """) as? String) ?? ""
            if !diag.isEmpty { break }
        }
        XCTAssertFalse(diag.isEmpty, "Dark Reader surface refinement did not converge in WKWebView")
        XCTAssertTrue(diag.contains("\"bodyBg\":\"rgb(0, 0, 0)\""), "OLED preset must render true #000000 body background: \(diag)")
        XCTAssertFalse(diag.contains("rgb(255, 255, 255)"), "Card gradient must not leak raw rgb(255, 255, 255): \(diag)")
        XCTAssertTrue(diag.contains("rgba(243, 91, 34, 0.08)"), "Card gradient must preserve orange brand accent tint: \(diag)")
        XCTAssertTrue(diag.contains("\"darkLogoFixed\":true"), "Dark monochrome SVG logo must invert cleanly: \(diag)")
        XCTAssertTrue(diag.contains("\"lightLogoUntouched\":true"), "Already-white SVG logo must stay untouched: \(diag)")
        XCTAssertTrue(diag.contains("\"barFixed\":true"), "CSS-drawn dark hamburger bar must gain high contrast: \(diag)")
        XCTAssertTrue(diag.contains("\"barBg\":\"rgb(242, 242, 247)\""), "Hamburger bar style must carry class=darkreader so DarkReader never re-darkens it: \(diag)")
    }

    func testWebKitDFACompilerAvoidsNestedKleeneStarAndExplosionBombs() {
        let domainRule = WebKitRuleCompiler.convertDNRURLFilterToWebKitDFA("||ads.example.com^")
        XCTAssertEqual(domainRule, "^https?://+([^:/]+\\.)?ads\\.example\\.com[/:?#]")
        XCTAssertFalse(domainRule?.contains("([a-z0-9-]+\\.)*") == true, "Must not emit nested Kleene star")
        XCTAssertFalse(domainRule?.contains(".*$") == true, "Host-only domain rule must stay lean without .*$ tail")

        let pathRule = WebKitRuleCompiler.convertDNRURLFilterToWebKitDFA("||cdn.example.com/track^")
        XCTAssertEqual(pathRule, "^https?://+([^:/]+\\.)?cdn\\.example\\.com/track([/:?#&].*)?$")

        // Pathological unanchored multi-wildcard patterns must be rejected to keep DFAs lean.
        XCTAssertNil(WebKitRuleCompiler.convertDNRURLFilterToWebKitDFA("ad*banner*track"))
        XCTAssertNil(WebKitRuleCompiler.convertDNRURLFilterToWebKitDFA("||example.com/*/a/*/b/*/c"))
    }

    @MainActor
    func testPlaybackTruthAndMIMETruthDetectExtensionlessAndDisguisedStreams() async throws {
        // 1. Classifier accepts extensionless & disguised-extension streams when proven by playback or MIME.
        let extlessURL = URL(string: "https://edge-04.cdn.example.test/d/8f4c1a2b~token?expiry=1795275000")!
        XCTAssertEqual(MediaURLClassifier.classifyStreamFormat(url: extlessURL, hint: "video-src"), .mp4)
        XCTAssertEqual(MediaURLClassifier.classifyStreamFormat(url: extlessURL, hint: "video-mime"), .mp4)
        XCTAssertEqual(MediaURLClassifier.classifyStreamFormat(url: extlessURL, hint: "m3u8-manifest"), .hls)
        XCTAssertEqual(MediaURLClassifier.classifyStreamFormat(url: extlessURL, hint: "dash-mime"), .dash)
        XCTAssertNil(MediaURLClassifier.classifyStreamFormat(url: extlessURL, hint: "fetch"))

        let disguisedJPG = URL(string: "https://edge-04.cdn.example.test/v/stream99.jpg?token=abc")!
        XCTAssertEqual(MediaURLClassifier.classifyStreamFormat(url: disguisedJPG, hint: "video-src"), .mp4)
        XCTAssertNil(MediaURLClassifier.classifyStreamFormat(url: disguisedJPG, hint: "perf"))

        // 2. Live WKWebView verification: extensionless `<video src>` bypasses CANDIDATE_RE and reports with omitOrigin.
        final class SnifferBox: NSObject, WKScriptMessageHandler {
            var payloads: [[String: Any]] = []
            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                if let dict = message.body as? [String: Any] {
                    payloads.append(dict)
                }
            }
        }
        let box = SnifferBox()
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(box, name: BrowserInjectedScripts.snifferMessageHandlerName)
        cfg.userContentController.addUserScript(
            WKUserScript(source: BrowserInjectedScripts.allFramesStreamInterceptor, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 640), configuration: cfg)
        let html = """
        <!doctype html><html><body>
          <video id="v"></video>
          <script>
            const v = document.getElementById('v');
            v.src = 'https://edge-04.cdn.example.test/d/8f4c1a2b~token?expiry=1795275000';
          </script>
        </body></html>
        """
        wv.loadHTMLString(html, baseURL: URL(string: "https://embed.example.test/e/demo123")!)
        for _ in 0..<25 {
            if !box.payloads.isEmpty { break }
            try await Task.sleep(for: .milliseconds(80))
        }
        let first = try XCTUnwrap(box.payloads.first, "Extensionless <video src> must be reported to Swift sniffer")
        XCTAssertEqual(first["url"] as? String, "https://edge-04.cdn.example.test/d/8f4c1a2b~token?expiry=1795275000")
        XCTAssertEqual(first["hint"] as? String, "video-src")
        XCTAssertEqual(first["omitOrigin"] as? Bool, true, "Non-CORS <video> must omit Origin header for strict CDNs")
        XCTAssertEqual(first["referer"] as? String, "https://embed.example.test/e/demo123")

        // 4. Coordinator ingests initial src assignment and upgrades duration/dimensions from late `loadedmetadata` without duplicating.
        let coordinator = MediaCaptureCoordinator()
        XCTAssertTrue(
            coordinator.ingestSniffedCandidate(
                payload: first,
                pageTitle: "Sample Video",
                currentURLString: "https://site.example.test/watch/1"
            )
        )
        XCTAssertEqual(coordinator.candidates.count, 1)
        XCTAssertNil(coordinator.candidates.first?.headers["Origin"])
        XCTAssertNil(coordinator.candidates.first?.hintedDuration)

        var lateMetaPayload = first
        lateMetaPayload["duration"] = 912.5
        lateMetaPayload["videoWidth"] = 1920
        lateMetaPayload["videoHeight"] = 1080
        XCTAssertTrue(
            coordinator.ingestSniffedCandidate(
                payload: lateMetaPayload,
                pageTitle: "Sample Video",
                currentURLString: "https://site.example.test/watch/1"
            )
        )
        XCTAssertEqual(coordinator.candidates.count, 1)
        XCTAssertEqual(coordinator.candidates.first?.hintedDuration, 912.5)
        XCTAssertEqual(coordinator.candidates.first?.hintedWidth, 1920)
        XCTAssertEqual(coordinator.candidates.first?.hintedHeight, 1080)
    }

    func testDirectStreamProberRejectsTiny200ErrorsAndRetriesOriginReferer() async throws {
        // 1. Synthetic ranking defaults (500 MP4, 860/960 HLS) must never masquerade as video pixel heights.
        XCTAssertNil(MediaURLClassifier.inferredPixelHeight(fromQualityScore: 500))
        XCTAssertNil(MediaURLClassifier.inferredPixelHeight(fromQualityScore: 860))
        XCTAssertNil(MediaURLClassifier.inferredPixelHeight(fromQualityScore: 960))
        XCTAssertEqual(MediaURLClassifier.inferredPixelHeight(fromQualityScore: 720), 720)
        XCTAssertEqual(MediaURLClassifier.inferredPixelHeight(fromQualityScore: 1080), 1080)

        // 2. Spin up a local loopback HTTP server simulating:
        //    - `/always-error`: HTTP 200 text/plain 14-byte body ("Access denied!")
        //    - `/origin-only`: rejects full-path Referer with 200 text/plain 14-byte body,
        //                      accepts origin-only Referer ("https://embed.example.test/") with 206 MP4 (`ftyp` box + 100 MiB Content-Range).
        let queue = DispatchQueue(label: "com.dysprosium.test.prober-loopback")
        let listener = try NWListener(using: .tcp, on: .any)
        final class PortBox: @unchecked Sendable {
            var port: UInt16 = 0
        }
        let portBox = PortBox()
        let readyExp = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue {
                portBox.port = port
                readyExp.fulfill()
            }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let reqText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let firstLine = reqText.split(separator: "\r\n").first.map(String.init) ?? ""
                let lowerReq = reqText.lowercased()
                let hasOriginOnlyReferer = lowerReq.contains("referer: https://embed.example.test/\r\n")

                let responseData: Data
                if firstLine.contains("GET /origin-only") && hasOriginOnlyReferer {
                    // Valid 64-byte MP4 ftyp header + Content-Range indicating 104,857,600 bytes total.
                    var body = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
                    body.append(Data(repeating: 0x00, count: 52))
                    let header = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Range: bytes 0-63/104857600\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    var full = Data(header.utf8)
                    full.append(body)
                    responseData = full
                } else {
                    let body = "Access denied!" // 14 bytes
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    responseData = Data(header.utf8)
                }
                conn.send(content: responseData, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [readyExp], timeout: 5.0)
        let boundPort = portBox.port
        XCTAssertGreaterThan(boundPort, 0)

        // 2a. Always-14-byte-200 error must be surfaced as probeError with nil bytes and nil fabricated height.
        let errURL = URL(string: "http://127.0.0.1:\(boundPort)/always-error?token=expired")!
        let errCand = SniffedStreamCandidate(
            id: errURL.absoluteString,
            streamURL: errURL,
            format: .mp4,
            qualityScore: 500,
            pageTitle: "Test Video",
            sourceDomain: "127.0.0.1",
            headers: ["Referer": "https://embed.example.test/e/demo123"],
            discoveredAt: Date()
        )
        let errProbe = await StreamMetadataProber.probeCandidate(errCand, posterURL: nil)
        let errVariant = try XCTUnwrap(errProbe.expandedVariants.first)
        XCTAssertNotNil(errVariant.probeError, "14-byte text/plain 200 OK response must be flagged as probeError, not valid video")
        XCTAssertTrue(errVariant.probeError?.contains("Access denied") == true, "Got unexpected error: \(errVariant.probeError ?? "nil")")
        XCTAssertNil(errVariant.exactOrEstimatedBytes, "Rejected error body must not report 14 bytes as video size")
        XCTAssertNil(errVariant.height, "Synthetic qualityScore 500 must not produce fake [500p] height")
        XCTAssertEqual(errVariant.resolutionLabel, "MP4 Video")

        // 2b. Origin-only Referer retry recovers from 200 text rejection and reports true 100 MiB size + winning header.
        let okURL = URL(string: "http://127.0.0.1:\(boundPort)/origin-only?token=valid")!
        let okCand = SniffedStreamCandidate(
            id: okURL.absoluteString,
            streamURL: okURL,
            format: .mp4,
            qualityScore: 500,
            pageTitle: "Test Video",
            sourceDomain: "127.0.0.1",
            headers: ["Referer": "https://embed.example.test/e/demo123"],
            discoveredAt: Date(),
            hintedDuration: 1234.0,
            hintedWidth: 1280,
            hintedHeight: 720
        )
        let okProbe = await StreamMetadataProber.probeCandidate(okCand, posterURL: nil)
        let okVariant = try XCTUnwrap(okProbe.expandedVariants.first)
        XCTAssertNil(okVariant.probeError, "Origin-only Referer retry must recover cleanly")
        XCTAssertEqual(okVariant.exactOrEstimatedBytes, 104_857_600)
        XCTAssertEqual(okVariant.headers["Referer"], "https://embed.example.test/")
        XCTAssertEqual(okProbe.durationSeconds, 1234.0)
        XCTAssertEqual(okVariant.height, 720)
        XCTAssertEqual(okVariant.resolutionLabel, "720p")
    }

    func testSystemProxyBridgeResolvesManualProxyWithFailoverDisabledAndLoopbackExcluded() async throws {
        // 1. Loopback manual HTTP/HTTPS/SOCKS proxy (e.g. macOS Clash) -> HTTP CONNECT with allowFailover = false
        //    and parsed RFC1918 CIDR exceptions preserved for direct URLSession bypass.
        let macClashSettings: [String: Any] = [
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": 7897,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": 7897,
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": 7897,
            "ExceptionsList": ["127.0.0.1", "192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "localhost", "*.local", "*.example.internal", "<local>"]
        ]
        let desc = try XCTUnwrap(SystemProxyBridge.resolveDescriptor(from: macClashSettings))
        XCTAssertEqual(desc.kind, .httpConnect)
        XCTAssertEqual(desc.host, "127.0.0.1")
        XCTAssertEqual(desc.port, 7897)
        XCTAssertTrue(desc.excludedDomains.contains("127.0.0.1"))
        XCTAssertTrue(desc.excludedDomains.contains("localhost"))
        XCTAssertTrue(desc.excludedDomains.contains("local"))
        XCTAssertTrue(desc.excludedDomains.contains("example.internal"))
        XCTAssertFalse(desc.excludedDomains.contains("<local>"))
        XCTAssertTrue(desc.excludeSimpleHostnames)
        XCTAssertEqual(desc.excludedCIDRs.count, 3)

        // Exact IPv4 CIDR bitmask bypass evaluation (RFC1918 & <local> bypass; public 172.2.x.x does NOT).
        XCTAssertTrue(desc.shouldBypass(url: URL(string: "http://192.168.1.42/clip.mp4")!))
        XCTAssertTrue(desc.shouldBypass(url: URL(string: "http://10.4.5.6/clip.mp4")!))
        XCTAssertTrue(desc.shouldBypass(url: URL(string: "http://172.20.1.5/clip.mp4")!))
        XCTAssertTrue(desc.shouldBypass(url: URL(string: "http://nas/clip.mp4")!))
        XCTAssertFalse(desc.shouldBypass(url: URL(string: "https://172.2.1.5/clip.mp4")!))
        XCTAssertFalse(desc.shouldBypass(url: URL(string: "https://cdn.example.test/clip.mp4")!))

        let configs = SystemProxyBridge.makeProxyConfigurations(for: desc)
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs.first?.allowFailover, false, "Explicit HTTP CONNECT proxy must disable direct QUIC failover")

        // 2. SOCKS-only fallback -> socksv5.
        let socksOnly: [String: Any] = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": 1080
        ]
        XCTAssertEqual(SystemProxyBridge.resolveDescriptor(from: socksOnly)?.kind, .socks5)

        // 3. No manual proxy (direct Wi-Fi or iOS TUN VPN) -> nil (zero override).
        let directSettings: [String: Any] = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0
        ]
        XCTAssertNil(SystemProxyBridge.resolveDescriptor(from: directSettings))

        // 4. PAC script or authenticated corporate proxy -> nil (never break PAC or strip Keychain auth).
        let pacSettings: [String: Any] = [
            "ProxyAutoConfigEnable": 1,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": 7897
        ]
        XCTAssertNil(SystemProxyBridge.resolveDescriptor(from: pacSettings))

        let authSettings: [String: Any] = [
            "HTTPSEnable": 1,
            "HTTPSProxy": "proxy.corp.example",
            "HTTPSPort": 8080,
            "HTTPSUser": "alice"
        ]
        XCTAssertNil(SystemProxyBridge.resolveDescriptor(from: authSettings))

        // 5. Distinct HTTP vs HTTPS proxy endpoints, public CIDRs (`172.2.0.0/16`, `10.0.0.0/4`, `203.0.113.0/24`),
        //    or non-loopback proxies carrying CIDR bypasses -> nil (preserve OS proxy policy).
        let mismatchedEndpoints: [String: Any] = [
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": 7890,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": 7891
        ]
        XCTAssertNil(SystemProxyBridge.resolveDescriptor(from: mismatchedEndpoints))

        for badCIDR in ["172.2.0.0/16", "10.0.0.0/4", "203.0.113.0/24", "not-an-ip/16"] {
            let s: [String: Any] = [
                "HTTPSEnable": 1,
                "HTTPSProxy": "127.0.0.1",
                "HTTPSPort": 7897,
                "ExceptionsList": [badCIDR]
            ]
            XCTAssertNil(SystemProxyBridge.resolveDescriptor(from: s), "Must reject non-private or malformed CIDR \(badCIDR)")
        }

        let remoteProxyWithRFC1918CIDR: [String: Any] = [
            "HTTPSEnable": 1,
            "HTTPSProxy": "10.0.0.5",
            "HTTPSPort": 8080,
            "ExceptionsList": ["192.168.0.0/16"]
        ]
        XCTAssertNil(
            SystemProxyBridge.resolveDescriptor(from: remoteProxyWithRFC1918CIDR),
            "Non-loopback proxy with CIDR exceptions must defer to system proxy stack"
        )

        // 6. Lease-tracked session pool: honors CIDR bypass per target URL AND keeps leased sessions
        //    valid for new tasks even after proxy rotation until the lease releases (no invalidated crash).
        let lanBypassLease = SystemProxyBridge.acquireSessionLease(
            for: .rangeTransfer,
            targetURL: URL(string: "http://192.168.1.42/clip.mp4")!,
            descriptorOverride: .some(desc)
        )
        defer { lanBypassLease.release() }
        XCTAssertTrue(
            lanBypassLease.session.configuration.proxyConfigurations.isEmpty,
            "RFC1918 CIDR-excluded target must obtain a direct bypass session"
        )
        let privateLanSession = SystemProxyBridge.makeOneShotEphemeralSession(
            for: .mediaResolver,
            targetURL: URL(string: "http://192.168.1.42/clip.mp4")!,
            descriptorOverride: .some(desc)
        )
        defer { privateLanSession.invalidateAndCancel() }
        XCTAssertTrue(
            privateLanSession.configuration.proxyConfigurations.isEmpty,
            "Private-tab one-shot session must honor the same RFC1918 CIDR bypass policy"
        )

        let queue = DispatchQueue(label: "com.dysprosium.test.proxy-lease")
        let listener = try NWListener(using: .tcp, on: .any)
        final class PortBox: @unchecked Sendable { var port: UInt16 = 0 }
        let portBox = PortBox()
        let readyExp = expectation(description: "proxy lease loopback ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state, let p = listener.port?.rawValue {
                portBox.port = p
                readyExp.fulfill()
            }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [readyExp], timeout: 5.0)
        let loopbackURL = URL(string: "http://127.0.0.1:\(portBox.port)/slice")!

        // Acquire Lease 1 (proxied, with 127.0.0.1 excluded so loopback succeeds directly), then rotate proxy -> direct.
        let lease1 = SystemProxyBridge.acquireSessionLease(for: .rangeTransfer, descriptorOverride: .some(desc))
        XCTAssertEqual(lease1.session.configuration.proxyConfigurations.count, 1)

        let lease2 = SystemProxyBridge.acquireSessionLease(for: .rangeTransfer, descriptorOverride: .some(nil))
        defer { lease2.release() }
        XCTAssertTrue(lease2.session.configuration.proxyConfigurations.isEmpty)
        XCTAssertFalse(lease1.session === lease2.session)

        // Issuing TWO sequential new requests on the displaced `lease1` AFTER proxy rotation must succeed cleanly.
        let (d1, r1) = try await lease1.session.data(from: loopbackURL)
        XCTAssertEqual((r1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: d1, encoding: .utf8), "OK")
        let (d2, r2) = try await lease1.session.data(from: loopbackURL)
        XCTAssertEqual((r2 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: d2, encoding: .utf8), "OK")
        lease1.release()
    }

    func testCrossOriginRedirectReScopesProberCredentials() async throws {
        // Server B (`localhost`) records all received headers; Server A (`127.0.0.1`) 302-redirects to Server B.
        let queue = DispatchQueue(label: "com.dysprosium.test.redirect-creds")
        final class StateBox: @unchecked Sendable {
            var portA: UInt16 = 0
            var portB: UInt16 = 0
            var receivedRequestsOnB: [String] = []
        }
        let state = StateBox()

        let listenerB = try NWListener(using: .tcp, on: .any)
        let readyB = expectation(description: "listener B ready")
        listenerB.stateUpdateHandler = { s in
            if case .ready = s, let p = listenerB.port?.rawValue {
                state.portB = p
                readyB.fulfill()
            }
        }
        listenerB.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if let req = data.flatMap({ String(data: $0, encoding: .utf8) }) {
                    state.receivedRequestsOnB.append(req)
                }
                var body = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
                body.append(Data(repeating: 0x00, count: 52))
                let header = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Range: bytes 0-63/2097152\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                var full = Data(header.utf8)
                full.append(body)
                conn.send(content: full, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listenerB.start(queue: queue)
        defer { listenerB.cancel() }
        await fulfillment(of: [readyB], timeout: 5.0)

        let listenerA = try NWListener(using: .tcp, on: .any)
        let readyA = expectation(description: "listener A ready")
        listenerA.stateUpdateHandler = { s in
            if case .ready = s, let p = listenerA.port?.rawValue {
                state.portA = p
                readyA.fulfill()
            }
        }
        listenerA.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let header = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(state.portB)/final-stream\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listenerA.start(queue: queue)
        defer { listenerA.cancel() }
        await fulfillment(of: [readyA], timeout: 5.0)

        let startURL = URL(string: "http://127.0.0.1:\(state.portA)/start")!
        let cand = SniffedStreamCandidate(
            id: startURL.absoluteString,
            streamURL: startURL,
            format: .mp4,
            qualityScore: 500,
            pageTitle: "Redirect Test",
            sourceDomain: "127.0.0.1",
            headers: [
                "Referer": "https://embed.example.test/e/1",
                "Cookie": "session=originA_secret",
                "Authorization": "Bearer originA_token"
            ],
            discoveredAt: Date()
        )

        let posterOnB = URL(string: "http://localhost:\(state.portB)/poster.jpg")!
        let probe = await StreamMetadataProber.probeCandidate(
            cand,
            posterURL: posterOnB,
            cookieHeaderBuilder: { dest in
                dest.host()?.lowercased() == "localhost" ? "dest_b=scoped_only" : nil
            }
        )
        let variant = try XCTUnwrap(probe.expandedVariants.first)
        XCTAssertEqual(variant.url.host(), "localhost")
        XCTAssertNil(variant.headers["Authorization"], "Cross-origin Authorization must be stripped from variant headers")
        XCTAssertEqual(variant.headers["Cookie"], "dest_b=scoped_only", "Cross-origin Cookie must be rebuilt for destination host, never reusing Origin A's cookie")
        XCTAssertFalse(state.receivedRequestsOnB.isEmpty)
        for req in state.receivedRequestsOnB {
            XCTAssertFalse(req.contains("originA_secret"), "Origin A Cookie leaked to cross-origin redirect target: \(req)")
            XCTAssertFalse(req.contains("originA_token"), "Origin A Authorization leaked to cross-origin redirect target: \(req)")
        }
    }

    @MainActor
    func testLateHLSUpgradeMidProbeMetadataAndFormatEvidenceEndToEnd() async throws {
        // 1. MIME truth overrides `/hls/` URL path guess; container extensions & DASH unsupported are preserved.
        let mp4OnHLSPath = URL(string: "https://cdn.example.test/hls/movie-no-ext")!
        XCTAssertEqual(
            MediaURLClassifier.classifyStreamFormat(url: mp4OnHLSPath, hint: "video-mime", mimeType: "video/mp4"),
            .mp4,
            "Genuine video/mp4 must never be routed to HLS probing just because URL contains /hls/"
        )
        XCTAssertEqual(
            MediaURLClassifier.preferredFileExtension(url: URL(string: "https://cdn.example.test/stream")!, format: .mp4, mimeType: "video/webm; codecs=vp9"),
            "webm"
        )
        XCTAssertEqual(
            MediaURLClassifier.preferredFileExtension(url: URL(string: "https://cdn.example.test/track")!, format: .mp4, mimeType: "audio/mpeg"),
            "mp3"
        )

        // 2. Late `#EXTM3U` manifest upgrades already-queued `.mp4` candidate in place to `.hls` and probes from cache.
        let streamURL = URL(string: "https://cdn.example.test/stream/one-time-token")!
        let coordinator = MediaCaptureCoordinator()
        XCTAssertTrue(coordinator.ingestSniffedCandidate(
            payload: [
                "url": streamURL.absoluteString,
                "hint": "video-src",
                "referer": "https://embed.example.test/e/1"
            ],
            pageTitle: "Demo",
            currentURLString: "https://embed.example.test/e/1"
        ))
        XCTAssertEqual(coordinator.candidates.first?.format, .mp4)

        let manifestBody = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXTINF:12.0,\nseg0.ts\n#EXT-X-ENDLIST\n"
        XCTAssertTrue(coordinator.ingestSniffedCandidate(
            payload: [
                "url": streamURL.absoluteString,
                "hint": "xhr-manifest",
                "manifestText": manifestBody,
                "referer": "https://embed.example.test/e/1"
            ],
            pageTitle: "Demo",
            currentURLString: "https://embed.example.test/e/1"
        ))
        XCTAssertEqual(coordinator.candidates.first?.format, .hls, "Late #EXTM3U must upgrade stored candidate format in place to .hls")

        let cachedProbe = await StreamMetadataProber.probeCandidate(
            try XCTUnwrap(coordinator.candidates.first),
            posterURL: nil,
            capturedManifests: [streamURL.absoluteString: StreamMetadataProber.CapturedManifest(text: manifestBody, finalURL: streamURL)]
        )
        XCTAssertEqual(cachedProbe.expandedVariants.first?.format, .hls)
        XCTAssertEqual(cachedProbe.durationSeconds ?? 0, 12.0, accuracy: 0.1)

        // 3. Mid-probe `loadedmetadata` duration (3.0s short clip) propagates on merge & reconciles auto-selection
        //    while preserving explicit manual user toggle.
        let (enteredStream, enteredCont) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseCont) = AsyncStream<Void>.makeStream()
        let shortURL = URL(string: "https://cdn.example.test/clip/intro")!
        let lateCoord = MediaCaptureCoordinator(candidateProber: { cand, _, _, _ in
            enteredCont.yield(())
            enteredCont.finish()
            var it = releaseStream.makeAsyncIterator()
            _ = await it.next()
            let v = SniffedVariantOption(
                id: cand.id,
                url: cand.streamURL,
                format: .mp4,
                resolutionLabel: "MP4 Video",
                width: nil,
                height: nil,
                bandwidthBps: nil,
                exactOrEstimatedBytes: 1_500_000,
                headers: cand.headers,
                qualityRank: 500
            )
            return StreamMetadataProber.EnrichedProbeOutput(
                groupStemHint: "intro",
                durationSeconds: nil,
                thumbnailJPEGData: nil,
                expandedVariants: [v]
            )
        })
        XCTAssertTrue(lateCoord.ingestSniffedCandidate(
            payload: ["url": shortURL.absoluteString, "hint": "video-src"],
            pageTitle: "Intro Clip",
            currentURLString: "https://site.example.test/watch"
        ))
        let enrichTask = Task { @MainActor in
            await lateCoord.enrichPendingCandidatesIfNeeded(fallbackReferer: "https://site.example.test/watch", pageTitle: "Intro Clip")
        }
        var enteredIt = enteredStream.makeAsyncIterator()
        _ = await enteredIt.next()
        // Deliver 3.0s duration + 720p dimensions while probe is in flight.
        XCTAssertTrue(lateCoord.ingestSniffedCandidate(
            payload: ["url": shortURL.absoluteString, "hint": "video-src", "duration": 3.0, "videoWidth": 1280, "videoHeight": 720],
            pageTitle: "Intro Clip",
            currentURLString: "https://site.example.test/watch"
        ))
        releaseCont.yield(())
        releaseCont.finish()
        await enrichTask.value
        let mergedGroup = try XCTUnwrap(lateCoord.mediaGroups.first)
        XCTAssertEqual(mergedGroup.durationSeconds, 3.0)
        XCTAssertTrue(mergedGroup.isShortClipCandidate)
        XCTAssertFalse(mergedGroup.isSelectedForDownload, "3s short clip discovered mid-probe must not stay auto-selected")
        XCTAssertEqual(mergedGroup.selectedVariant?.height, 720)

        // Manual user selection must be preserved.
        lateCoord.toggleGroupSelection(groupID: mergedGroup.id)
        XCTAssertTrue(lateCoord.mediaGroups.first?.isSelectedForDownload == true)

        // 4. DASH candidate is flagged unsupported cleanly rather than downloading XML as `.mp4`.
        let dashCand = SniffedStreamCandidate(
            id: "https://cdn.example.test/manifest.mpd",
            streamURL: URL(string: "https://cdn.example.test/manifest.mpd")!,
            format: .dash,
            qualityScore: 500,
            pageTitle: "DASH Test",
            sourceDomain: "cdn.example.test",
            headers: [:],
            discoveredAt: Date()
        )
        let dashProbe = await StreamMetadataProber.probeCandidate(dashCand, posterURL: nil)
        let dashVariant = try XCTUnwrap(dashProbe.expandedVariants.first)
        XCTAssertFalse(dashVariant.isDownloadSupported)
        XCTAssertFalse(dashVariant.isPlayableInNativePlayer, "Unplayable DASH manifest must disable native poster/row Play buttons")
        XCTAssertEqual(dashVariant.badgeSummary, "DASH Stream", "DASH badgeSummary must stay concise without tripling the Unsupported label")
    }

    @MainActor
    func testTrailingCaretEndOfURLAndJSInterceptorXHRAndBaseHref() async throws {
        // 1. Trailing `^` on path rule matches BOTH end-of-URL and query separator, without matching prefix extensions,
        //    and compiles cleanly in WebKit's real WKContentRuleListStore alongside an unanchored allow rule.
        let pathRule = try XCTUnwrap(WebKitRuleCompiler.convertDNRURLFilterToWebKitDFA("||ads.example.test/pixel^"))
        let regex = try NSRegularExpression(pattern: pathRule)
        func matches(_ s: String) -> Bool {
            regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        XCTAssertTrue(matches("https://ads.example.test/pixel"))
        XCTAssertTrue(matches("https://ads.example.test/pixel?id=1"))
        XCTAssertTrue(matches("https://sub.ads.example.test/pixel/x"))
        XCTAssertFalse(matches("https://ads.example.test/pixelated"))

        let buckets = WebKitRuleCompiler.parseABPFilterTextToBuckets("""
        ||ads.example.test/pixel^
        @@/pixel?allow=1
        """)
        let combinedRules = buckets.blockAndCosmeticRules + buckets.allowRules
        let jsonData = try JSONSerialization.data(withJSONObject: combinedRules)
        let jsonString = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        let testRuleID = "dysprosium.test.v9.allow.\(UUID().uuidString)"
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let compiledList = try await store.compileContentRuleList(forIdentifier: testRuleID, encodedContentRuleList: jsonString)
        XCTAssertNotNil(compiledList, "Trailing ^ path rule + unanchored allow rule must compile cleanly in WKContentRuleListStore")
        try? await store.removeContentRuleList(forIdentifier: testRuleID)

        // 2. Real WKWebView test: `<base href>` resolution + single-attach XHR listener (4 reuses = 4 header reads, not 10)
        //    + bounded generic text/plain fetch aborts on chunk 1 instead of pulling 11 chunks.
        final class SnifferBox: NSObject, WKScriptMessageHandler {
            var payloads: [[String: Any]] = []
            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                if let dict = message.body as? [String: Any] {
                    payloads.append(dict)
                }
            }
        }
        let box = SnifferBox()
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(box, name: BrowserInjectedScripts.snifferMessageHandlerName)
        // Pre-install a synthetic `window.fetch` BEFORE the stream interceptor hooks it, returning:
        // - `/notes.txt`: an unconsumed 20 x 64 KiB `text/plain` stream (no Content-Length) counting pulls
        // - `/gzip-bomb.m3u8`: a compressed-expansion stream claiming Content-Length: 100 but emitting 15 x 64 KiB (> 512 KiB)
        let preFetchStub = """
        window.__pulledPlainChunks = 0;
        window.__pulledBombChunks = 0;
        window.fetch = function(input) {
          const urlStr = (typeof input === 'string') ? input : (input && input.url) || 'https://embed.example.test/notes.txt';
          if (urlStr.includes('gzip-bomb')) {
            const stream = new ReadableStream({
              pull(controller) {
                window.__pulledBombChunks++;
                if (window.__pulledBombChunks > 15) { controller.close(); return; }
                const prefix = window.__pulledBombChunks === 1 ? '#EXTM3U\\n' : '#EXTINF:1\\n';
                controller.enqueue(new TextEncoder().encode(prefix + 'a'.repeat(65520)));
              }
            });
            const resp = new Response(stream, {
              status: 200,
              headers: { 'Content-Type': 'application/vnd.apple.mpegurl', 'Content-Length': '100' }
            });
            try { Object.defineProperty(resp, 'url', { value: urlStr }); } catch (_) {}
            return Promise.resolve(resp);
          }
          const stream = new ReadableStream({
            pull(controller) {
              window.__pulledPlainChunks++;
              if (window.__pulledPlainChunks > 20) { controller.close(); return; }
              controller.enqueue(new TextEncoder().encode('NOT_HLS_' + 'x'.repeat(65528)));
            }
          });
          const resp = new Response(stream, { status: 200, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
          try { Object.defineProperty(resp, 'url', { value: urlStr }); } catch (_) {}
          return Promise.resolve(resp);
        };
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: preFetchStub, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        cfg.userContentController.addUserScript(
            WKUserScript(source: BrowserInjectedScripts.allFramesStreamInterceptor, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 640), configuration: cfg)
        let html = """
        <!doctype html><html><head><base href="https://embed.example.test/assets/"></head><body>
          <video id="v"></video>
          <script>
            const v = document.getElementById('v');
            v.src = 'clip-token-99';

            window.__ctReads = 0;
            const origGetRespHeader = XMLHttpRequest.prototype.getResponseHeader;
            XMLHttpRequest.prototype.getResponseHeader = function(name) {
              if (String(name).toLowerCase() === 'content-type') window.__ctReads++;
              return origGetRespHeader.apply(this, arguments);
            };
            const x = new XMLHttpRequest();
            for (let i = 0; i < 4; i++) {
              x.open('GET', 'https://embed.example.test/api/' + i);
              Object.defineProperty(x, 'readyState', { value: 2, configurable: true });
              x.dispatchEvent(new Event('readystatechange'));
            }

            // Fire fetches whose bodies the page never consumes; sniffer must abort both cleanly.
            window.__fetchDone = false;
            Promise.all([
              window.fetch('https://embed.example.test/notes.txt'),
              window.fetch('https://embed.example.test/gzip-bomb.m3u8')
            ]).then(() => {
              setTimeout(() => { window.__fetchDone = true; }, 160);
            });
          </script>
        </body></html>
        """
        wv.loadHTMLString(html, baseURL: URL(string: "https://embed.example.test/watch/1")!)
        for _ in 0..<30 {
            let done = (try? await wv.evaluateJavaScript("window.__fetchDone === true")) as? Bool ?? false
            if !box.payloads.isEmpty && done { break }
            try await Task.sleep(for: .milliseconds(80))
        }
        let first = try XCTUnwrap(box.payloads.first)
        XCTAssertEqual(
            first["url"] as? String,
            "https://embed.example.test/assets/clip-token-99",
            "Native setter must run first so `<base href>` resolves relative video.src accurately"
        )
        let ctReads = try await wv.evaluateJavaScript("window.__ctReads") as? Int
        XCTAssertEqual(ctReads, 4, "Reusing an XHR 4 times must attach listeners once (4 Content-Type reads, not 1+2+3+4=10)")
        let pulledPlainChunks = try await wv.evaluateJavaScript("window.__pulledPlainChunks") as? Int ?? 99
        XCTAssertGreaterThanOrEqual(pulledPlainChunks, 1, "Sniffer should inspect the leading chunk of text/plain fetch")
        XCTAssertLessThanOrEqual(pulledPlainChunks, 3, "Sniffer must cancel non-#EXTM3U text/plain stream on chunk 1 (allowing WebKit ReadableStreamTee HWM=1 prefetch), never draining 20 chunks (got \(pulledPlainChunks))")
        let pulledBombChunks = try await wv.evaluateJavaScript("window.__pulledBombChunks") as? Int ?? 99
        XCTAssertLessThan(pulledBombChunks, 13, "Decompressed 512 KiB reader cap must abort gzip-expanded streams even when Content-Length is small (got \(pulledBombChunks))")
        XCTAssertFalse(
            box.payloads.contains(where: { ($0["hint"] as? String) == "fetch-manifest" }),
            "Aborted streams must never emit partial fetch-manifest payloads"
        )
    }

    @MainActor
    func testTransferSchedulerStripsCredentialsAcrossRedirectAndPairedAudioTrack() async throws {
        // 1. Server A (`127.0.0.1`) 302-redirects to Server B (`localhost`); TransferScheduler must NOT
        //    re-inject stripped Cookie/Authorization from `initial.initialHeaders` during Data Plane slices.
        let queue = DispatchQueue(label: "com.dysprosium.test.scheduler-redirect-creds")
        final class StateBox: @unchecked Sendable {
            var portA: UInt16 = 0
            var portB: UInt16 = 0
            var requestsOnB: [String] = []
        }
        let state = StateBox()
        let payloadBytes = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]) + Data(repeating: 0xAB, count: 4084)

        let listenerB = try NWListener(using: .tcp, on: .any)
        let readyB = expectation(description: "scheduler listener B ready")
        listenerB.stateUpdateHandler = { s in
            if case .ready = s, let p = listenerB.port?.rawValue {
                state.portB = p
                readyB.fulfill()
            }
        }
        listenerB.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                state.requestsOnB.append(req)
                // Parse optional Range: bytes=start-end
                var start = 0
                var end = payloadBytes.count - 1
                var isPartial = false
                for line in req.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("range:") {
                    if let eq = line.firstIndex(of: "=") {
                        let rangePart = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                        let bounds = rangePart.split(separator: "-")
                        if let s = bounds.first.flatMap({ Int($0) }) {
                            start = max(0, min(s, payloadBytes.count - 1))
                            end = bounds.count > 1 ? min(payloadBytes.count - 1, Int(bounds[1]) ?? (payloadBytes.count - 1)) : (payloadBytes.count - 1)
                            isPartial = true
                        }
                    }
                }
                let slice = payloadBytes[start...end]
                let statusLine = isPartial ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
                let rangeHdr = isPartial ? "Content-Range: bytes \(start)-\(end)/\(payloadBytes.count)\r\n" : ""
                let hdr = "\(statusLine)\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\n\(rangeHdr)Content-Length: \(slice.count)\r\nConnection: close\r\n\r\n"
                var resp = Data(hdr.utf8)
                resp.append(slice)
                conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listenerB.start(queue: queue)
        defer { listenerB.cancel() }
        await fulfillment(of: [readyB], timeout: 5.0)

        let listenerA = try NWListener(using: .tcp, on: .any)
        let readyA = expectation(description: "scheduler listener A ready")
        listenerA.stateUpdateHandler = { s in
            if case .ready = s, let p = listenerA.port?.rawValue {
                state.portA = p
                readyA.fulfill()
            }
        }
        listenerA.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let hdr = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(state.portB)/final-video.mp4\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(hdr.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listenerA.start(queue: queue)
        defer { listenerA.cancel() }
        await fulfillment(of: [readyA], timeout: 5.0)

        let scheduler = TransferScheduler(store: nil)
        let startURL = URL(string: "http://127.0.0.1:\(state.portA)/start.mp4")!
        let uniqueName = "redirect-cred-check-\(UUID().uuidString.prefix(8)).mp4"
        let job = scheduler.enqueue(
            url: startURL,
            lanes: 2,
            headers: [
                "Cookie": "originA_secret=topsecret",
                "Authorization": "Bearer originA_bearer",
                "Referer": "https://site.example.test/watch"
            ],
            suggestedTitle: uniqueName
        )

        for _ in 0..<50 {
            if let current = scheduler.jobs.first(where: { $0.id == job.id }),
               current.lifecycle == .completed || current.lifecycle == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        let finished = try XCTUnwrap(scheduler.jobs.first(where: { $0.id == job.id }))
        if let rel = finished.destinationRelativePath {
            try? FileManager.default.removeItem(at: LiveContainerEnvironment.vaultDirectory.appendingPathComponent(rel))
        }
        XCTAssertEqual(finished.lifecycle, .completed, "Redirected TransferScheduler download should complete cleanly (err: \(finished.errorMessage ?? "none"))")
        XCTAssertGreaterThanOrEqual(state.requestsOnB.count, 2, "Expected both probe and Data Plane slice requests on Server B")
        for req in state.requestsOnB {
            XCTAssertFalse(req.contains("originA_secret"), "TransferScheduler re-injected stripped Cookie into Data Plane request: \(req)")
            XCTAssertFalse(req.contains("originA_bearer"), "TransferScheduler re-injected stripped Authorization into Data Plane request: \(req)")
        }

        // 2. Paired audio track on a different origin must strip video-origin Cookie/Authorization at enqueue time.
        let pairedScheduler = TransferScheduler(store: nil)
        let videoURL = URL(string: "https://video-cdn.example.test/v.mp4")!
        let audioURL = URL(string: "https://audio-cdn.example.test/a.m4a")!
        let pairedJob = pairedScheduler.enqueue(
            url: videoURL,
            pairedAudioURL: audioURL,
            headers: [
                "Cookie": "video_only=1",
                "Authorization": "Bearer video_only",
                "Referer": "https://site.example.test/"
            ],
            suggestedTitle: "paired-test.mp4"
        )
        pairedScheduler.pause(id: pairedJob.id)
        let audioTrack = try XCTUnwrap(pairedJob.plan?.tracks.first(where: { $0.role == .audioOnly }))
        XCTAssertNil(audioTrack.headers["Cookie"], "Cross-origin paired audio track must strip video-origin Cookie")
        XCTAssertNil(audioTrack.headers["Authorization"], "Cross-origin paired audio track must strip video-origin Authorization")
        XCTAssertEqual(audioTrack.headers["Referer"], "https://site.example.test/")
    }

    @MainActor
    func testMidProbeHLSUpgradeDiscardsStaleMP4AndCompletesHLSFromCache() async throws {
        // Replicates the exact race: `.mp4` probe is ALREADY in flight (neither in pending nor mediaGroups)
        // when `#EXTM3U` arrives for the same URL. Even if the in-flight `.mp4` probe finishes with HTTP 403,
        // evidence versioning must discard it and re-probe from cache as `.hls`.
        let (enteredStream, enteredCont) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseCont) = AsyncStream<Void>.makeStream()
        let streamURL = URL(string: "https://cdn.example.test/stream/race-token")!
        let manifestBody = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXTINF:15.0,\nseg0.ts\n#EXT-X-ENDLIST\n"

        final class CounterBox: @unchecked Sendable { var calls = 0 }
        let counter = CounterBox()

        let coord = MediaCaptureCoordinator(candidateProber: { cand, _, manifests, _ in
            counter.calls += 1
            if cand.format == .mp4 {
                enteredCont.yield(())
                enteredCont.finish()
                var it = releaseStream.makeAsyncIterator()
                _ = await it.next()
                // Deliberately return a failing MP4/403 result even after cancellation to verify version guard.
                let bad = SniffedVariantOption(
                    id: cand.id,
                    url: cand.streamURL,
                    format: .mp4,
                    resolutionLabel: "MP4 Video",
                    width: nil,
                    height: nil,
                    bandwidthBps: nil,
                    exactOrEstimatedBytes: nil,
                    headers: cand.headers,
                    qualityRank: -1,
                    probeError: "HTTP 403"
                )
                return StreamMetadataProber.EnrichedProbeOutput(
                    groupStemHint: "race-token",
                    durationSeconds: nil,
                    thumbnailJPEGData: nil,
                    expandedVariants: [bad]
                )
            } else {
                let cachedText = manifests[cand.streamURL.absoluteString]
                let good = SniffedVariantOption(
                    id: cand.id,
                    url: cand.streamURL,
                    format: .hls,
                    resolutionLabel: "HLS Stream",
                    width: nil,
                    height: nil,
                    bandwidthBps: nil,
                    exactOrEstimatedBytes: 12_000_000,
                    headers: cand.headers,
                    qualityRank: 720,
                    preloadedManifestText: cachedText
                )
                return StreamMetadataProber.EnrichedProbeOutput(
                    groupStemHint: "race-token",
                    durationSeconds: 15.0,
                    thumbnailJPEGData: nil,
                    expandedVariants: [good]
                )
            }
        })

        XCTAssertTrue(coord.ingestSniffedCandidate(
            payload: ["url": streamURL.absoluteString, "hint": "video-src"],
            pageTitle: "Race Demo",
            currentURLString: "https://site.example.test/watch"
        ))
        let enrichTask = Task { @MainActor in
            await coord.enrichPendingCandidatesIfNeeded(fallbackReferer: "https://site.example.test/watch", pageTitle: "Race Demo")
        }
        var enteredIt = enteredStream.makeAsyncIterator()
        _ = await enteredIt.next()

        // Manifest arrives WHILE MP4 probe is in flight (pending is empty, mediaGroups is empty).
        XCTAssertEqual(coord.pendingCandidateCount, 0)
        XCTAssertTrue(coord.mediaGroups.isEmpty)
        XCTAssertTrue(coord.ingestSniffedCandidate(
            payload: ["url": streamURL.absoluteString, "hint": "xhr-manifest", "manifestText": manifestBody],
            pageTitle: "Race Demo",
            currentURLString: "https://site.example.test/watch"
        ))

        releaseCont.yield(())
        releaseCont.finish()
        await enrichTask.value

        XCTAssertEqual(coord.pendingCandidateCount, 0)
        let group = try XCTUnwrap(coord.mediaGroups.first)
        XCTAssertEqual(group.selectedVariant?.format, .hls, "Stale MP4/403 must be discarded and replaced by cached HLS")
        XCTAssertNil(group.selectedVariant?.probeError, "Upgraded HLS card must not retain HTTP 403 error")
        XCTAssertEqual(group.selectedVariant?.preloadedManifestText, manifestBody.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(group.durationSeconds, 15.0)
        XCTAssertGreaterThanOrEqual(counter.calls, 2)
    }

    func testHLSRedirectResolvesRelativeSegmentsAndProberUpdatesSubPlaylistBaseURL() async throws {
        // Loopback server:
        // - `/original/master.m3u8` -> master pointing to relative `sub.m3u8`
        // - `/original/sub.m3u8` -> 302 redirect to `/moved/sub.m3u8`
        // - `/moved/sub.m3u8` -> media playlist pointing to relative `segment0.ts`
        // - `/moved/segment0.ts` -> valid 188-byte MPEG-TS packet; `/original/segment0.ts` -> 404!
        let queue = DispatchQueue(label: "com.dysprosium.test.hls-redirect-base")
        final class PortBox: @unchecked Sendable { var port: UInt16 = 0 }
        let portBox = PortBox()
        let readyExp = expectation(description: "hls redirect listener ready")

        var tsPacket = Data(repeating: 0x00, count: 188)
        tsPacket[0] = 0x47
        tsPacket[1] = 0x40
        tsPacket[2] = 0x00
        tsPacket[3] = 0x10

        let listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { s in
            if case .ready = s, let p = listener.port?.rawValue {
                portBox.port = p
                readyExp.fulfill()
            }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let firstLine = req.split(separator: "\r\n").first.map(String.init) ?? ""
                let resp: Data
                if firstLine.contains("GET /original/master.m3u8") {
                    let body = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720\nsub.m3u8\n"
                    resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                } else if firstLine.contains("GET /original/sub.m3u8") {
                    resp = Data("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(portBox.port)/moved/sub.m3u8\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                } else if firstLine.contains("GET /moved/sub.m3u8") {
                    let body = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nsegment0.ts\n#EXT-X-ENDLIST\n"
                    resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                } else if firstLine.contains("GET /moved/segment0.ts") {
                    var full = Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: \(tsPacket.count)\r\nConnection: close\r\n\r\n".utf8)
                    full.append(tsPacket)
                    resp = full
                } else {
                    resp = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                }
                conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [readyExp], timeout: 5.0)

        // 1. HLSStreamEngine direct media playlist redirect resolves `/moved/segment0.ts` (never 404 `/original/segment0.ts`).
        let engine = HLSStreamEngine()
        let redirectedMediaURL = URL(string: "http://127.0.0.1:\(portBox.port)/original/sub.m3u8")!
        let parsed = try await engine.resolveMediaPlaylist(from: redirectedMediaURL, headers: [:])
        XCTAssertEqual(parsed.resolvedPlaylistURL.path, "/moved/sub.m3u8")
        XCTAssertEqual(parsed.segments.first?.url.path, "/moved/segment0.ts")

        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("hls-redirect-\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: outFile) }
        let progress = try await engine.downloadPlaylist(manifestURL: redirectedMediaURL, destinationURL: outFile) { _ in }
        XCTAssertEqual(progress.completedSegments, 1)
        XCTAssertEqual(progress.downloadedBytes, Int64(tsPacket.count))

        // 2. StreamMetadataProber updates the variant URL to `/moved/sub.m3u8` when caching a redirected sub-playlist.
        let masterURL = URL(string: "http://127.0.0.1:\(portBox.port)/original/master.m3u8")!
        let masterCand = SniffedStreamCandidate(
            id: masterURL.absoluteString,
            streamURL: masterURL,
            format: .hls,
            qualityScore: 860,
            pageTitle: "Redirected Sub",
            sourceDomain: "127.0.0.1",
            headers: [:],
            discoveredAt: Date()
        )
        let probe = await StreamMetadataProber.probeCandidate(masterCand, posterURL: nil)
        let variant = try XCTUnwrap(probe.expandedVariants.first)
        XCTAssertEqual(variant.url.path, "/moved/sub.m3u8", "Cached sub-playlist variant must adopt final post-redirect URL as base")
        XCTAssertNotNil(variant.preloadedManifestText)

        // 3. Cross-origin HLS download isolation: Origin A (`127.0.0.1`) master redirects / points to
        //    Origin B (`localhost`) media playlist with `#EXT-X-MAP`, `#EXT-X-KEY` (AES-128), and segment;
        //    Origin A's Cookie/Authorization must NEVER reach Origin B on playlist, init map, key, or segment.
        final class HLSOriginBState: @unchecked Sendable {
            var portB: UInt16 = 0
            var requestsOnB: [String] = []
        }
        let bState = HLSOriginBState()
        let aesKey = Data(repeating: 0x2A, count: 16)
        let aesIV = Data(repeating: 0x01, count: 16)
        let encryptedSeg = try encryptAES128CBC(plaintext: tsPacket, key: aesKey, iv: aesIV)
        let initBox = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]) + Data(repeating: 0x00, count: 12)

        let listenerB = try NWListener(using: .tcp, on: .any)
        let readyB = expectation(description: "hls cross-origin listener B ready")
        listenerB.stateUpdateHandler = { s in
            if case .ready = s, let p = listenerB.port?.rawValue {
                bState.portB = p
                readyB.fulfill()
            }
        }
        listenerB.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                bState.requestsOnB.append(req)
                let firstLine = req.split(separator: "\r\n").first.map(String.init) ?? ""
                let resp: Data
                if firstLine.contains("GET /b/media.m3u8") {
                    let body = """
                    #EXTM3U
                    #EXT-X-VERSION:7
                    #EXT-X-TARGETDURATION:4
                    #EXT-X-MAP:URI="init.mp4"
                    #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x01010101010101010101010101010101
                    #EXTINF:4.0,
                    seg0.m4s
                    #EXT-X-ENDLIST
                    """
                    resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                } else if firstLine.contains("GET /b/init.mp4") {
                    var full = Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: \(initBox.count)\r\nConnection: close\r\n\r\n".utf8)
                    full.append(initBox)
                    resp = full
                } else if firstLine.contains("GET /b/key.bin") {
                    var full = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(aesKey.count)\r\nConnection: close\r\n\r\n".utf8)
                    full.append(aesKey)
                    resp = full
                } else if firstLine.contains("GET /b/seg0.m4s") {
                    var full = Data("HTTP/1.1 200 OK\r\nContent-Type: video/iso.segment\r\nContent-Length: \(encryptedSeg.count)\r\nConnection: close\r\n\r\n".utf8)
                    full.append(encryptedSeg)
                    resp = full
                } else {
                    resp = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                }
                conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listenerB.start(queue: queue)
        defer { listenerB.cancel() }
        await fulfillment(of: [readyB], timeout: 5.0)

        let listenerA = try NWListener(using: .tcp, on: .any)
        let readyA = expectation(description: "hls cross-origin listener A ready")
        final class PortABox: @unchecked Sendable { var port: UInt16 = 0 }
        let portABox = PortABox()
        listenerA.stateUpdateHandler = { s in
            if case .ready = s, let p = listenerA.port?.rawValue {
                portABox.port = p
                readyA.fulfill()
            }
        }
        listenerA.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let hdr = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(bState.portB)/b/media.m3u8\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(hdr.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listenerA.start(queue: queue)
        defer { listenerA.cancel() }
        await fulfillment(of: [readyA], timeout: 5.0)

        let xOriginOut = FileManager.default.temporaryDirectory.appendingPathComponent("hls-xorigin-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: xOriginOut) }
        let xOriginManifest = URL(string: "http://127.0.0.1:\(portABox.port)/a/manifest.m3u8")!
        let xProg = try await engine.downloadPlaylist(
            manifestURL: xOriginManifest,
            headers: ["Cookie": "hlsA_secret=1", "Authorization": "Bearer hlsA_token"],
            destinationURL: xOriginOut
        ) { _ in }
        XCTAssertEqual(xProg.completedSegments, 1)
        XCTAssertEqual(bState.requestsOnB.count, 4, "Expected media.m3u8, init.mp4, key.bin, and seg0.m4s on Origin B")
        for req in bState.requestsOnB {
            XCTAssertFalse(req.contains("hlsA_secret"), "Origin A Cookie leaked to Origin B HLS asset: \(req)")
            XCTAssertFalse(req.contains("hlsA_token"), "Origin A Authorization leaked to Origin B HLS asset: \(req)")
        }
    }

    func testMediaResolverRejectsDASHOnWebpageSniffAndPreservesExtensions() async throws {
        let pageURL = URL(string: "https://site.example.test/watch")!
        let streamURL = URL(string: "https://origin-a.example.test/stream")!
        let lease = SystemProxyBridge.acquireSessionLease(for: .mediaResolver, descriptorOverride: .some(nil))
        defer { lease.release() }

        // 1. Explicit `.dash` sniffed candidate -> HTTP -415.
        do {
            _ = try await MediaResolver.buildPlanFromCandidateStream(
                sourceURL: pageURL,
                initialStreamURL: streamURL,
                initialHeaders: [:],
                hintedFormat: .dash,
                hintedMIME: "application/dash+xml",
                probe: nil,
                host: "site.example.test",
                preferredFilename: "video",
                session: lease.session
            )
            XCTFail("Expected DASH candidate to throw -415")
        } catch let err as NSError {
            XCTAssertEqual(err.code, -415)
        }

        // 2. Redirected `.mpd` or `application/dash+xml` MIME discovered during probe -> HTTP -415.
        let dashProbe = RangeProbeResult(
            finalURL: URL(string: "https://cdn.example.test/live/manifest.mpd")!,
            totalBytes: 2048,
            supportsByteRanges: true,
            suggestedFilename: "manifest.mpd",
            etag: nil,
            lastModified: nil,
            mimeType: "application/dash+xml"
        )
        do {
            _ = try await MediaResolver.buildPlanFromCandidateStream(
                sourceURL: pageURL,
                initialStreamURL: streamURL,
                initialHeaders: [:],
                hintedFormat: .mp4,
                hintedMIME: nil,
                probe: dashProbe,
                host: "site.example.test",
                preferredFilename: "video",
                session: lease.session
            )
            XCTFail("Expected post-redirect DASH probe to throw -415")
        } catch let err as NSError {
            XCTAssertEqual(err.code, -415)
        }

        // 3. Cross-origin WebM redirect strips auth headers and preserves `.webm` container extension.
        let webmProbe = RangeProbeResult(
            finalURL: URL(string: "https://cdn-b.example.test/asset/token123")!,
            totalBytes: 10_485_760,
            supportsByteRanges: true,
            suggestedFilename: nil,
            etag: nil,
            lastModified: nil,
            mimeType: "video/webm"
        )
        let plan = try await MediaResolver.buildPlanFromCandidateStream(
            sourceURL: pageURL,
            initialStreamURL: streamURL,
            initialHeaders: ["Cookie": "a=secret", "Authorization": "Bearer secret", "Referer": "https://site.example.test/"],
            hintedFormat: .mp4,
            hintedMIME: nil,
            probe: webmProbe,
            host: "site.example.test",
            preferredFilename: "clip",
            session: lease.session
        )
        let track = try XCTUnwrap(plan.tracks.first)
        XCTAssertEqual(track.fileExtension, "webm")
        XCTAssertTrue(plan.outputFilename.hasSuffix(".webm"))
        XCTAssertNil(track.headers["Cookie"])
        XCTAssertNil(track.headers["Authorization"])
    }

    @MainActor
    func testDoubleWildcardAllowRuleSurvivesCompilationAndJSFetchURLObjectAndMIMEUpgrade() async throws {
        // 1. Unanchored double-wildcard allow rule compiles (unlike block rule) and compiles in WKContentRuleListStore.
        let buckets = WebKitRuleCompiler.parseABPFilterTextToBuckets("""
        ||cdn.example.test/player/init.js
        @@*player*init*
        ad*banner*track
        """)
        XCTAssertEqual(buckets.blockAndCosmeticRules.count, 1, "Unanchored 2-wildcard block rule must stay rejected")
        XCTAssertEqual(buckets.allowRules.count, 1, "Unanchored 2-wildcard @@ allow rule must survive compilation")

        let combined = buckets.blockAndCosmeticRules + buckets.allowRules
        let jsonStr = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: combined), encoding: .utf8))
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let ruleID = "dysprosium.test.v10.allow2wild.\(UUID().uuidString)"
        let compiled = try await store.compileContentRuleList(forIdentifier: ruleID, encodedContentRuleList: jsonStr)
        XCTAssertNotNil(compiled)
        try? await store.removeContentRuleList(forIdentifier: ruleID)

        // 2. Real WKWebView: `fetch(new URL(...))` captures extensionless video MIME, AND a URL already
        //    reported by suffix (`video.mp4`) still forwards a stronger `application/dash+xml` MIME upgrade
        //    which MediaCaptureCoordinator reclassifies from `.mp4` -> `.dash`.
        final class SnifferBox: NSObject, WKScriptMessageHandler {
            var payloads: [[String: Any]] = []
            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                if let dict = message.body as? [String: Any] {
                    payloads.append(dict)
                }
            }
        }
        let box = SnifferBox()
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(box, name: BrowserInjectedScripts.snifferMessageHandlerName)
        let preFetchStub = """
        window.fetch = function(input) {
          const urlStr = (typeof input === 'string') ? input : ((input && (input.url || input.href)) || '');
          if (urlStr.includes('extless-url-obj')) {
            const resp = new Response('', { status: 200, headers: { 'Content-Type': 'video/mp4' } });
            try { Object.defineProperty(resp, 'url', { value: urlStr }); } catch (_) {}
            return Promise.resolve(resp);
          }
          const resp = new Response('<MPD/>', { status: 200, headers: { 'Content-Type': 'application/dash+xml' } });
          try { Object.defineProperty(resp, 'url', { value: urlStr }); } catch (_) {}
          return Promise.resolve(resp);
        };
        """
        cfg.userContentController.addUserScript(WKUserScript(source: preFetchStub, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(WKUserScript(source: BrowserInjectedScripts.allFramesStreamInterceptor, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 640), configuration: cfg)
        let html = """
        <!doctype html><html><body><script>
          window.__done = false;
          Promise.all([
            window.fetch(new URL('https://cdn.example.test/extless-url-obj')),
            window.fetch('https://cdn.example.test/disguised.mp4')
          ]).then(() => { setTimeout(() => { window.__done = true; }, 100); });
        </script></body></html>
        """
        wv.loadHTMLString(html, baseURL: URL(string: "https://site.example.test/watch")!)
        for _ in 0..<30 {
            let done = (try? await wv.evaluateJavaScript("window.__done === true")) as? Bool ?? false
            if done && box.payloads.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(80))
        }

        let urlObjReport = box.payloads.first(where: {
            ($0["url"] as? String) == "https://cdn.example.test/extless-url-obj" && ($0["hint"] as? String) == "video-mime"
        })
        XCTAssertNotNil(urlObjReport, "fetch(new URL(...)) must report extensionless video MIME: \(box.payloads)")

        let disguisedPayloads = box.payloads.filter { ($0["url"] as? String) == "https://cdn.example.test/disguised.mp4" }
        XCTAssertTrue(
            disguisedPayloads.contains(where: { ($0["hint"] as? String) == "dash-mime" }),
            "JS dedup must allow a stronger MIME upgrade after initial suffix fetch report: \(disguisedPayloads)"
        )

        let coord = MediaCaptureCoordinator()
        for p in disguisedPayloads {
            _ = coord.ingestSniffedCandidate(payload: p, pageTitle: "MIME Upgrade", currentURLString: "https://site.example.test/watch")
        }
        XCTAssertEqual(coord.candidates.first?.format, .dash, "Coordinator must reclassify .mp4 -> .dash when authoritative dash-mime arrives")
    }

    @MainActor
    func testRFC6265CookieScopingMediaResolverNaming40CapUpgradeAndInPageRedirectURL() async throws {
        // 1. Production RFC 6265 `MediaCaptureCoordinator.buildCookieHeader(cookies:for:)`:
        //    preserves host-only vs leading-dot domain scope, Path prefix boundaries, Secure flag, and path specificity.
        let hostOnly = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "example.test",
            .path: "/",
            .name: "host_only",
            .value: "apex"
        ]))
        let domainWide = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".example.test",
            .path: "/",
            .name: "dom_wide",
            .value: "all"
        ]))
        let scopedPath = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".example.test",
            .path: "/app",
            .name: "path_scoped",
            .value: "app_only"
        ]))
        let secureOnly = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".example.test",
            .path: "/",
            .name: "sec_only",
            .value: "https_only",
            .secure: "TRUE"
        ]))
        let cookies = [hostOnly, domainWide, scopedPath, secureOnly]

        let apexHeader = MediaCaptureCoordinator.buildCookieHeader(
            cookies: cookies,
            for: URL(string: "https://example.test/app/video.mp4")!
        )
        XCTAssertTrue(apexHeader.contains("host_only=apex"))
        XCTAssertTrue(apexHeader.contains("dom_wide=all"))
        XCTAssertTrue(apexHeader.contains("path_scoped=app_only"))
        XCTAssertTrue(apexHeader.contains("sec_only=https_only"))
        // Longer path (`/app`) must precede root (`/`) per RFC 6265 §5.4.
        XCTAssertTrue(apexHeader.hasPrefix("path_scoped=app_only"))

        let subHeader = MediaCaptureCoordinator.buildCookieHeader(
            cookies: cookies,
            for: URL(string: "https://cdn.example.test/app2/video.mp4")!
        )
        XCTAssertFalse(subHeader.contains("host_only=apex"), "Host-only cookie must NEVER leak to subdomain")
        XCTAssertFalse(subHeader.contains("path_scoped=app_only"), "Path=/app must NOT match /app2")
        XCTAssertTrue(subHeader.contains("dom_wide=all"))
        XCTAssertTrue(subHeader.contains("sec_only=https_only"))

        let httpSubHeader = MediaCaptureCoordinator.buildCookieHeader(
            cookies: cookies,
            for: URL(string: "http://cdn.example.test/app/video.mp4")!
        )
        XCTAssertFalse(httpSubHeader.contains("sec_only=https_only"), "Secure cookie must NOT be sent over HTTP")
        XCTAssertTrue(httpSubHeader.contains("path_scoped=app_only"))

        // 2. MediaResolver filename preservation:
        //    - Ordinary `application/octet-stream` `firmware.bin` keeps `.bin` (never becomes `.mp4`).
        //    - Extensionless webpage candidate (`fallbackStem: "Clip"`) with confirmed `video/webm` outputs `Clip.webm`.
        let lease = SystemProxyBridge.acquireSessionLease(for: .mediaResolver, descriptorOverride: .some(nil))
        defer { lease.release() }

        let binProbe = RangeProbeResult(
            finalURL: URL(string: "https://downloads.example.test/releases/firmware.bin")!,
            totalBytes: 4_194_304,
            supportsByteRanges: true,
            suggestedFilename: "firmware.bin",
            etag: nil,
            lastModified: nil,
            mimeType: "application/octet-stream"
        )
        let binPlan = try await MediaResolver.buildPlanFromCandidateStream(
            sourceURL: binProbe.finalURL,
            initialStreamURL: binProbe.finalURL,
            initialHeaders: [:],
            hintedFormat: nil,
            hintedMIME: nil,
            probe: binProbe,
            host: "downloads.example.test",
            preferredFilename: nil,
            session: lease.session
        )
        XCTAssertEqual(binPlan.outputFilename, "firmware.bin", "Ordinary binary download must never be renamed to .mp4")
        XCTAssertEqual(binPlan.tracks.first?.fileExtension, "bin")

        let webpageWebmProbe = RangeProbeResult(
            finalURL: URL(string: "https://cdn.example.test/d/opaque-token-123")!,
            totalBytes: 8_388_608,
            supportsByteRanges: true,
            suggestedFilename: nil,
            etag: nil,
            lastModified: nil,
            mimeType: "video/webm"
        )
        let webpageWebmPlan = try await MediaResolver.buildPlanFromCandidateStream(
            sourceURL: URL(string: "https://site.example.test/watch/1")!,
            initialStreamURL: webpageWebmProbe.finalURL,
            initialHeaders: [:],
            hintedFormat: .mp4,
            hintedMIME: nil,
            probe: webpageWebmProbe,
            host: "site.example.test",
            preferredFilename: nil,
            fallbackStem: "Clip",
            session: lease.session
        )
        XCTAssertEqual(webpageWebmPlan.outputFilename, "Clip.webm", "Confirmed video/webm must override tentative webpage stem extension")
        XCTAssertEqual(webpageWebmPlan.tracks.first?.fileExtension, "webm")

        // 3. JS 40-URL cap only limits NEW URLs; URL #40 still receives its stronger `dash-mime` upgrade while URL #41 is capped.
        final class SnifferBox: NSObject, WKScriptMessageHandler {
            var payloads: [[String: Any]] = []
            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                if let dict = message.body as? [String: Any] {
                    payloads.append(dict)
                }
            }
        }
        let box = SnifferBox()
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(box, name: BrowserInjectedScripts.snifferMessageHandlerName)
        let preStub = """
        window.fetch = function(input) {
          const urlStr = (typeof input === 'string') ? input : ((input && (input.url || input.href)) || '');
          const is40 = urlStr.includes('item-40.mp4');
          const ct = is40 ? 'application/dash+xml' : 'application/octet-stream';
          const resp = new Response('', { status: 200, headers: { 'Content-Type': ct } });
          try { Object.defineProperty(resp, 'url', { value: urlStr }); } catch (_) {}
          return Promise.resolve(resp);
        };
        """
        cfg.userContentController.addUserScript(WKUserScript(source: preStub, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(WKUserScript(source: BrowserInjectedScripts.allFramesStreamInterceptor, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 640), configuration: cfg)
        let html = """
        <!doctype html><html><body><script>
          window.__capDone = false;
          const ps = [];
          for (let i = 1; i <= 41; i++) {
            ps.push(window.fetch('https://cdn.example.test/item-' + i + '.mp4'));
          }
          Promise.all(ps).then(() => { setTimeout(() => { window.__capDone = true; }, 120); });
        </script></body></html>
        """
        wv.loadHTMLString(html, baseURL: URL(string: "https://site.example.test/watch")!)
        for _ in 0..<30 {
            let done = (try? await wv.evaluateJavaScript("window.__capDone === true")) as? Bool ?? false
            if done { break }
            try await Task.sleep(for: .milliseconds(80))
        }
        XCTAssertTrue(
            box.payloads.contains(where: { ($0["url"] as? String) == "https://cdn.example.test/item-40.mp4" && ($0["hint"] as? String) == "dash-mime" }),
            "URL #40 must still emit its stronger dash-mime upgrade after hitting the 40-URL cap"
        )
        XCTAssertFalse(
            box.payloads.contains(where: { ($0["url"] as? String) == "https://cdn.example.test/item-41.mp4" }),
            "New URL #41 beyond the 40-URL cap must remain blocked"
        )

        // 4. In-page WebKit manifest fallback preserves post-redirect `finalURL` as the base URL for relative variants.
        let queue = DispatchQueue(label: "com.dysprosium.test.inpage-redirect")
        let listener = try NWListener(using: .tcp, on: .any)
        final class PortBox: @unchecked Sendable { var port: UInt16 = 0 }
        let portBox = PortBox()
        let readyExp = expectation(description: "403 origin ready")
        listener.stateUpdateHandler = { s in
            if case .ready = s, let p = listener.port?.rawValue {
                portBox.port = p
                readyExp.fulfill()
            }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [readyExp], timeout: 5.0)

        let origURL = URL(string: "http://127.0.0.1:\(portBox.port)/original/master.m3u8")!
        let movedMasterURL = URL(string: "http://127.0.0.1:\(portBox.port)/moved/master.m3u8")!
        let movedSubURL = URL(string: "http://127.0.0.1:\(portBox.port)/moved/sub.m3u8")!
        let cand = SniffedStreamCandidate(
            id: origURL.absoluteString,
            streamURL: origURL,
            format: .hls,
            qualityScore: 860,
            pageTitle: "InPage Redirect",
            sourceDomain: "127.0.0.1",
            headers: [:],
            discoveredAt: Date()
        )
        let inPageProbe = await StreamMetadataProber.probeCandidate(
            cand,
            posterURL: nil,
            inPageManifestFetcher: { requested in
                if requested == origURL {
                    return StreamMetadataProber.CapturedManifest(
                        text: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720\nsub.m3u8\n",
                        finalURL: movedMasterURL
                    )
                }
                if requested == movedSubURL {
                    return StreamMetadataProber.CapturedManifest(
                        text: "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:10.0,\nseg0.ts\n#EXT-X-ENDLIST\n",
                        finalURL: movedSubURL
                    )
                }
                return nil
            }
        )
        let resolvedVariant = try XCTUnwrap(inPageProbe.expandedVariants.first)
        XCTAssertEqual(resolvedVariant.url, movedSubURL, "In-page fallback must resolve relative sub.m3u8 against redirected /moved/master.m3u8")
        XCTAssertEqual(inPageProbe.durationSeconds ?? 0, 10.0, accuracy: 0.1)
    }

    private func encryptAES128CBC(plaintext: Data, key: Data, iv: Data) throws -> Data {
        let cap = plaintext.count + kCCBlockSizeAES128
        var out = Data(count: cap)
        var moved: size_t = 0
        let status = out.withUnsafeMutableBytes { outBuf in
            plaintext.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, plaintext.count,
                            outBuf.baseAddress, cap,
                            &moved
                        )
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        out.count = moved
        return out
    }
}
