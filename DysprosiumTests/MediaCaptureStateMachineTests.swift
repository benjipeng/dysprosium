import Foundation
import WebKit
import XCTest
@testable import Dysprosium

final class MediaCaptureStateMachineTests: XCTestCase {
    private actor ProbeGate {
        private var startedContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var hasStarted = false
        private var isReleased = false
        private var didObserveCancel = false

        func markStarted() {
            hasStarted = true
            startedContinuation?.resume()
            startedContinuation = nil
        }

        func waitUntilStarted() async {
            if hasStarted { return }
            await withCheckedContinuation { cont in
                startedContinuation = cont
            }
        }

        func waitForReleaseOrCancel() async {
            if isReleased { return }
            await withTaskCancellationHandler {
                await withCheckedContinuation { cont in
                    if isReleased {
                        cont.resume()
                    } else {
                        releaseContinuation = cont
                    }
                }
            } onCancel: {
                Task { await self.markCancelledAndResume() }
            }
        }

        private func markCancelledAndResume() {
            didObserveCancel = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }

        func release() {
            isReleased = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }

        func wasCancelled() -> Bool {
            didObserveCancel
        }
    }

    private actor CallCounter {
        private var count = 0
        func increment() -> Int {
            count += 1
            return count
        }
        func value() -> Int {
            count
        }
    }

    @MainActor
    func testDeterministicTransitionsIdleDiscoveredProbingReady() async {
        let gate = ProbeGate()
        let streamURL = URL(string: "https://cdn.example.com/hls/movie-1080p/master.m3u8")!

        let coordinator = MediaCaptureCoordinator(
            candidateProber: { candidate, _, _, _ in
                await gate.markStarted()
                await gate.waitForReleaseOrCancel()
                let variant = SniffedVariantOption(
                    id: candidate.streamURL.absoluteString,
                    url: candidate.streamURL,
                    format: .hls,
                    resolutionLabel: "1080p",
                    width: 1920,
                    height: 1080,
                    bandwidthBps: 5_000_000,
                    exactOrEstimatedBytes: 120_000_000,
                    headers: candidate.headers,
                    qualityRank: 1080
                )
                return StreamMetadataProber.EnrichedProbeOutput(
                    groupStemHint: "movie-1080p",
                    durationSeconds: 180.0,
                    thumbnailJPEGData: nil,
                    expandedVariants: [variant]
                )
            },
            cookieProvider: { [] }
        )

        XCTAssertEqual(coordinator.capturePhase, .idle)
        XCTAssertFalse(coordinator.isProbing)
        XCTAssertEqual(coordinator.activeProbeCount, 0)

        let accepted = coordinator.ingestSniffedCandidate(
            payload: [
                "url": streamURL.absoluteString,
                "hint": "fetch",
                "referer": "https://example.com/watch",
                "origin": "https://example.com"
            ],
            pageTitle: "Sample Feature Film",
            currentURLString: "https://example.com/watch"
        )
        XCTAssertTrue(accepted)
        XCTAssertEqual(coordinator.capturePhase, .discovered(candidateCount: 1))
        XCTAssertEqual(coordinator.streamStates[streamURL.absoluteString], .discovered)
        XCTAssertEqual(coordinator.discoveredMediaBadgeCount, 1)

        let enrichTask = Task { @MainActor in
            await coordinator.enrichPendingCandidatesIfNeeded(
                fallbackReferer: "https://example.com/watch",
                pageTitle: "Sample Feature Film"
            )
        }

        await gate.waitUntilStarted()
        XCTAssertEqual(coordinator.capturePhase, .probing(activeCount: 1, readyCount: 0))
        XCTAssertTrue(coordinator.isProbing)
        XCTAssertEqual(coordinator.activeProbeCount, 1)
        XCTAssertEqual(coordinator.inFlightProbeTaskCount, 1)
        XCTAssertEqual(coordinator.streamStates[streamURL.absoluteString], .probing)

        await gate.release()
        await enrichTask.value

        XCTAssertEqual(coordinator.capturePhase, .ready(groupCount: 1))
        XCTAssertFalse(coordinator.isProbing)
        XCTAssertEqual(coordinator.activeProbeCount, 0)
        XCTAssertEqual(coordinator.inFlightProbeTaskCount, 0)
        XCTAssertEqual(coordinator.streamStates[streamURL.absoluteString], .ready)
        XCTAssertEqual(coordinator.discoveredMediaGroups.count, 1)
        XCTAssertEqual(coordinator.discoveredMediaGroups.first?.title, "Sample Feature Film")
        XCTAssertEqual(coordinator.discoveredMediaGroups.first?.isSelectedForDownload, true)
    }

    @MainActor
    func testAllUnreachableTransitionsAndUpgradesWhenManifestArrives() async {
        let streamURL = URL(string: "https://waf.example.com/protected/index.m3u8")!
        let sampleManifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg0.ts
        #EXTINF:6.0,
        seg1.ts
        #EXT-X-ENDLIST
        """

        let coordinator = MediaCaptureCoordinator(
            candidateProber: { candidate, _, capturedManifests, _ in
                if let manifest = capturedManifests[candidate.streamURL.absoluteString],
                   manifest.hasPrefix("#EXTM3U") {
                    let upgraded = SniffedVariantOption(
                        id: candidate.streamURL.absoluteString,
                        url: candidate.streamURL,
                        format: .hls,
                        resolutionLabel: "720p",
                        width: 1280,
                        height: 720,
                        bandwidthBps: 2_800_000,
                        exactOrEstimatedBytes: 4_200_000,
                        headers: candidate.headers,
                        qualityRank: 720,
                        probeError: nil,
                        preloadedManifestText: manifest
                    )
                    return StreamMetadataProber.EnrichedProbeOutput(
                        groupStemHint: "protected",
                        durationSeconds: 12.0,
                        thumbnailJPEGData: nil,
                        expandedVariants: [upgraded]
                    )
                }
                let failed = SniffedVariantOption(
                    id: candidate.streamURL.absoluteString,
                    url: candidate.streamURL,
                    format: .hls,
                    resolutionLabel: "HLS Stream",
                    width: nil,
                    height: nil,
                    bandwidthBps: nil,
                    exactOrEstimatedBytes: nil,
                    headers: candidate.headers,
                    qualityRank: -1,
                    probeError: "HTTP 403",
                    preloadedManifestText: nil
                )
                return StreamMetadataProber.EnrichedProbeOutput(
                    groupStemHint: "protected",
                    durationSeconds: nil,
                    thumbnailJPEGData: nil,
                    expandedVariants: [failed]
                )
            },
            cookieProvider: { [] }
        )

        coordinator.ingestSniffedCandidate(
            payload: ["url": streamURL.absoluteString, "hint": "fetch"],
            pageTitle: "Protected Clip",
            currentURLString: "https://waf.example.com/player"
        )
        await coordinator.enrichPendingCandidatesIfNeeded(
            fallbackReferer: "https://waf.example.com/player",
            pageTitle: "Protected Clip"
        )

        XCTAssertEqual(coordinator.capturePhase, .allUnreachable(groupCount: 1))
        XCTAssertEqual(coordinator.streamStates[streamURL.absoluteString], .unreachable(reason: "HTTP 403"))
        XCTAssertEqual(coordinator.mediaGroups.first?.isUnreachable, true)
        XCTAssertEqual(coordinator.mediaGroups.first?.isSelectedForDownload, false)

        // Late live-WKWebView `#EXTM3U` response arrives for the same URL -> re-queues and upgrades.
        let requeued = coordinator.ingestSniffedCandidate(
            payload: [
                "url": streamURL.absoluteString,
                "hint": "fetch-body",
                "manifestText": sampleManifest
            ],
            pageTitle: "Protected Clip",
            currentURLString: "https://waf.example.com/player"
        )
        XCTAssertTrue(requeued)
        XCTAssertEqual(coordinator.pendingCandidateCount, 1)

        await coordinator.enrichPendingCandidatesIfNeeded(
            fallbackReferer: "https://waf.example.com/player",
            pageTitle: "Protected Clip"
        )

        XCTAssertEqual(coordinator.capturePhase, .ready(groupCount: 1))
        XCTAssertEqual(coordinator.streamStates[streamURL.absoluteString], .ready)
        XCTAssertEqual(coordinator.mediaGroups.count, 1)
        XCTAssertEqual(coordinator.mediaGroups.first?.isUnreachable, false)
        XCTAssertEqual(coordinator.mediaGroups.first?.isSelectedForDownload, true)
        XCTAssertEqual(coordinator.mediaGroups.first?.selectedVariant?.preloadedManifestText, sampleManifest)
    }

    @MainActor
    func testNavigationResetCancelsInFlightProbesWithoutLeakingStaleGroups() async {
        let gate = ProbeGate()
        let staleURL = URL(string: "https://old.example.com/stream/master.m3u8")!

        let coordinator = MediaCaptureCoordinator(
            candidateProber: { candidate, _, _, _ in
                await gate.markStarted()
                await gate.waitForReleaseOrCancel()
                // Intentionally return a valid variant even after cancellation to verify
                // the coordinator's generation + cancellation guard drops stale completions.
                let staleVariant = SniffedVariantOption(
                    id: candidate.streamURL.absoluteString,
                    url: candidate.streamURL,
                    format: .hls,
                    resolutionLabel: "1080p",
                    width: 1920,
                    height: 1080,
                    bandwidthBps: 4_000_000,
                    exactOrEstimatedBytes: 50_000_000,
                    headers: candidate.headers,
                    qualityRank: 1080
                )
                return StreamMetadataProber.EnrichedProbeOutput(
                    groupStemHint: "stale-stream",
                    durationSeconds: 90.0,
                    thumbnailJPEGData: nil,
                    expandedVariants: [staleVariant]
                )
            },
            cookieProvider: { [] }
        )

        coordinator.ingestSniffedCandidate(
            payload: ["url": staleURL.absoluteString, "hint": "fetch"],
            pageTitle: "Old Page",
            currentURLString: "https://old.example.com/video"
        )

        let enrichTask = Task { @MainActor in
            await coordinator.enrichPendingCandidatesIfNeeded(
                fallbackReferer: "https://old.example.com/video",
                pageTitle: "Old Page"
            )
        }

        await gate.waitUntilStarted()
        XCTAssertEqual(coordinator.capturePhase, .probing(activeCount: 1, readyCount: 0))
        XCTAssertEqual(coordinator.inFlightProbeTaskCount, 1)

        // Simulate main-frame navigation away from the old page mid-probe.
        coordinator.resetForMainFrameNavigation(to: URL(string: "https://new.example.com/home")!)

        XCTAssertEqual(coordinator.capturePhase, .idle)
        XCTAssertEqual(coordinator.activeProbeCount, 0)
        XCTAssertEqual(coordinator.inFlightProbeTaskCount, 0)
        XCTAssertTrue(coordinator.candidates.isEmpty)
        XCTAssertTrue(coordinator.mediaGroups.isEmpty)
        XCTAssertTrue(coordinator.streamStates.isEmpty)

        await enrichTask.value

        let cancelled = await gate.wasCancelled()
        XCTAssertTrue(cancelled, "Expected in-flight probe task to receive cancellation on navigation reset")
        XCTAssertEqual(coordinator.capturePhase, .idle)
        XCTAssertTrue(coordinator.mediaGroups.isEmpty, "Stale probe output must never leak after navigation reset")
        XCTAssertTrue(coordinator.candidates.isEmpty)
    }

    @MainActor
    func testPreloadedEXTM3UManifestPassthroughAndInPageFallbackCache() async {
        let directURL = URL(string: "https://stream.example.com/live/chunklist.m3u8")!
        let manifestBody = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST"

        let fallbackURL = URL(string: "https://cf.example.com/token/index.m3u8")!
        let fallbackManifest = "#EXTM3U\n#EXTINF:5.0,\ncf0.ts\n#EXT-X-ENDLIST"
        let fetchCounter = CallCounter()

        let coordinator = MediaCaptureCoordinator(
            candidateProber: { candidate, _, capturedManifests, _ in
                XCTAssertEqual(capturedManifests[candidate.streamURL.absoluteString], manifestBody)
                // Intentionally omit `preloadedManifestText` here to verify coordinator hydration fallback.
                let variant = SniffedVariantOption(
                    id: candidate.streamURL.absoluteString,
                    url: candidate.streamURL,
                    format: .hls,
                    resolutionLabel: "720p",
                    width: 1280,
                    height: 720,
                    bandwidthBps: 2_500_000,
                    exactOrEstimatedBytes: 1_250_000,
                    headers: candidate.headers,
                    qualityRank: 720,
                    probeError: nil,
                    preloadedManifestText: nil
                )
                return StreamMetadataProber.EnrichedProbeOutput(
                    groupStemHint: "live-chunklist",
                    durationSeconds: 4.0,
                    thumbnailJPEGData: nil,
                    expandedVariants: [variant]
                )
            },
            cookieProvider: { [] },
            inPageManifestFetcher: { url, _ in
                _ = await fetchCounter.increment()
                if url == fallbackURL {
                    return "  \n\(fallbackManifest)\n  "
                }
                return "<html>403 Forbidden</html>"
            }
        )

        coordinator.ingestSniffedCandidate(
            payload: [
                "url": directURL.absoluteString,
                "hint": "fetch",
                "manifestText": "  \(manifestBody)\n"
            ],
            pageTitle: "Preloaded Stream",
            currentURLString: "https://stream.example.com/watch"
        )
        XCTAssertEqual(coordinator.cachedManifestText(for: directURL.absoluteString), manifestBody)

        await coordinator.enrichPendingCandidatesIfNeeded(
            fallbackReferer: "https://stream.example.com/watch",
            pageTitle: "Preloaded Stream"
        )
        XCTAssertEqual(coordinator.mediaGroups.first?.selectedVariant?.preloadedManifestText, manifestBody)

        // Same-origin in-page fallback caches valid `#EXTM3U` and rejects non-HLS HTML error bodies.
        let firstFetch = await coordinator.fetchManifestInWebView(url: fallbackURL)
        XCTAssertEqual(firstFetch, fallbackManifest)
        let secondFetch = await coordinator.fetchManifestInWebView(url: fallbackURL)
        XCTAssertEqual(secondFetch, fallbackManifest)
        let callCountAfterCacheHit = await fetchCounter.value()
        XCTAssertEqual(callCountAfterCacheHit, 1, "Second fetch should hit capturedManifests cache without re-running JS")

        let invalidFetch = await coordinator.fetchManifestInWebView(url: URL(string: "https://cf.example.com/not-hls.m3u8")!)
        XCTAssertNil(invalidFetch)
    }

    @MainActor
    func testDiscoveredMediaGroupsSortReachableBeforeUnreachable() async {
        let unreachableURL = URL(string: "https://cdn.example.com/a-blocked/master.m3u8")!
        let shortClipURL = URL(string: "https://cdn.example.com/b-short/preview.mp4")!
        let mainVideoURL = URL(string: "https://cdn.example.com/c-main/feature.m3u8")!

        let coordinator = MediaCaptureCoordinator(
            candidateProber: { candidate, _, _, _ in
                switch candidate.streamURL {
                case unreachableURL:
                    return StreamMetadataProber.EnrichedProbeOutput(
                        groupStemHint: "group-unreachable",
                        durationSeconds: 600.0,
                        thumbnailJPEGData: nil,
                        expandedVariants: [
                            SniffedVariantOption(
                                id: candidate.id,
                                url: candidate.streamURL,
                                format: .hls,
                                resolutionLabel: "HLS Stream",
                                width: nil,
                                height: nil,
                                bandwidthBps: nil,
                                exactOrEstimatedBytes: nil,
                                headers: candidate.headers,
                                qualityRank: -1,
                                probeError: "HTTP 403"
                            )
                        ]
                    )
                case shortClipURL:
                    return StreamMetadataProber.EnrichedProbeOutput(
                        groupStemHint: "group-short",
                        durationSeconds: 3.0,
                        thumbnailJPEGData: nil,
                        expandedVariants: [
                            SniffedVariantOption(
                                id: candidate.id,
                                url: candidate.streamURL,
                                format: .mp4,
                                resolutionLabel: "480p",
                                width: 854,
                                height: 480,
                                bandwidthBps: nil,
                                exactOrEstimatedBytes: 800_000,
                                headers: candidate.headers,
                                qualityRank: 480
                            )
                        ]
                    )
                default:
                    return StreamMetadataProber.EnrichedProbeOutput(
                        groupStemHint: "group-main",
                        durationSeconds: 120.0,
                        thumbnailJPEGData: nil,
                        expandedVariants: [
                            SniffedVariantOption(
                                id: candidate.id,
                                url: candidate.streamURL,
                                format: .hls,
                                resolutionLabel: "1080p",
                                width: 1920,
                                height: 1080,
                                bandwidthBps: 5_000_000,
                                exactOrEstimatedBytes: 75_000_000,
                                headers: candidate.headers,
                                qualityRank: 1080
                            )
                        ]
                    )
                }
            },
            cookieProvider: { [] }
        )

        // Ingest unreachable FIRST, then short clip, then main video.
        coordinator.ingestSniffedCandidate(
            payload: ["url": unreachableURL.absoluteString, "hint": "fetch"],
            pageTitle: "Sorting Test",
            currentURLString: "https://example.com/watch"
        )
        coordinator.ingestSniffedCandidate(
            payload: ["url": shortClipURL.absoluteString, "hint": "video-src"],
            pageTitle: "Sorting Test",
            currentURLString: "https://example.com/watch"
        )
        coordinator.ingestSniffedCandidate(
            payload: ["url": mainVideoURL.absoluteString, "hint": "fetch"],
            pageTitle: "Sorting Test",
            currentURLString: "https://example.com/watch"
        )

        await coordinator.enrichPendingCandidatesIfNeeded(
            fallbackReferer: "https://example.com/watch",
            pageTitle: "Sorting Test"
        )

        XCTAssertEqual(coordinator.capturePhase, .ready(groupCount: 3))
        XCTAssertEqual(
            coordinator.discoveredMediaGroups.map(\.id),
            ["group-main", "group-short", "group-unreachable"]
        )
        XCTAssertEqual(coordinator.discoveredMediaGroups[0].isUnreachable, false)
        XCTAssertEqual(coordinator.discoveredMediaGroups[0].isSelectedForDownload, true)
        XCTAssertEqual(coordinator.discoveredMediaGroups[2].isUnreachable, true)
        XCTAssertEqual(coordinator.discoveredMediaGroups[2].isSelectedForDownload, false)
    }

    @MainActor
    func testSessionBypassableHostNormalizationAndCaptureForwarding() {
        let session = CleanroomWebKitSession(isPrivate: true)
        defer { session.teardown() }

        XCTAssertNil(session.currentBypassableHost)
        XCTAssertFalse(session.isShieldBypassedForCurrentHost)
        XCTAssertEqual(session.capturePhase, .idle)
        XCTAssertFalse(session.isProbingMedia)

        session.stageDeferredRestore(urlString: "about:blank", title: "Blank")
        XCTAssertNil(session.currentBypassableHost)

        session.stageDeferredRestore(urlString: "https://www.Example.COM/video/42", title: "Video 42")
        XCTAssertEqual(session.currentBypassableHost, "example.com")
    }
}
