import Foundation
import WebKit
import XCTest
@testable import Dysprosium

final class FingerprintAuditTests: XCTestCase {

    // MARK: - 1. Unified LC 1 / LC 2 / LC 3+ Shared App Group Resolution & Lossless Migration

    func testLiveContainerEnvironmentPrefersSharedAppGroupAcrossHostsAndMigratesLegacyData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dysprosium-lc-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sharedGroupRoot = root.appendingPathComponent("SharedAppGroup", isDirectory: true)
        let lc1HostRoot = root.appendingPathComponent("LC1HostContainer", isDirectory: true)
        let guestAppSupport = root.appendingPathComponent("GuestAppSupport", isDirectory: true)

        // Both Private App path (`.../Documents/Data/Application/<UUID>`) and
        // Shared App path (`.../LiveContainer/Data/Application/<UUID>`) must resolve cleanly.
        let privateGuestPath = lc1HostRoot
            .appendingPathComponent("Documents/Data/Application/808144CA-8836-4D30-B368-0EA4EDE0B9DD").path
        let sharedGuestPath = sharedGroupRoot
            .appendingPathComponent("LiveContainer/Data/Application/808144CA-8836-4D30-B368-0EA4EDE0B9DD").path

        XCTAssertEqual(
            LiveContainerEnvironment.resolveLiveContainerHostRoot(fromCandidatePaths: [privateGuestPath])?.standardizedFileURL.path,
            lc1HostRoot.standardizedFileURL.path
        )
        XCTAssertEqual(
            LiveContainerEnvironment.resolveLiveContainerHostRoot(fromCandidatePaths: [sharedGuestPath])?.standardizedFileURL.path,
            sharedGroupRoot.standardizedFileURL.path
        )

        // When App Group is available in LiveContainer, LC 1, LC 2, LC 3+ all converge on SharedAppGroup/Library/Application Support/Dysprosium
        let resolvedShared = LiveContainerEnvironment.resolvePersistentAppSupportDirectory(
            isLiveContainer: true,
            sharedAppGroupURL: sharedGroupRoot,
            hostRootURL: lc1HostRoot,
            guestAppSupportURL: guestAppSupport
        )
        XCTAssertEqual(
            resolvedShared.standardizedFileURL.path,
            sharedGroupRoot.appendingPathComponent("Library/Application Support/Dysprosium").standardizedFileURL.path
        )

        // Fallback when App Group is unavailable still uses Host Container
        let resolvedHostFallback = LiveContainerEnvironment.resolvePersistentAppSupportDirectory(
            isLiveContainer: true,
            sharedAppGroupURL: nil,
            hostRootURL: lc1HostRoot,
            guestAppSupportURL: guestAppSupport
        )
        XCTAssertEqual(
            resolvedHostFallback.standardizedFileURL.path,
            lc1HostRoot.appendingPathComponent("Library/Application Support/Dysprosium").standardizedFileURL.path
        )

        // Seed legacy LC1 BrowserState data and verify non-destructive migration into Shared App Group
        let legacyBrowserState = resolvedHostFallback.appendingPathComponent("BrowserState", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyBrowserState, withIntermediateDirectories: true)
        let sentinelJSON = #"{"folders":[{"title":"1DM"}],"bookmarks":[{"urlString":"https://example.test"}]}"#
        try Data(sentinelJSON.utf8).write(to: legacyBrowserState.appendingPathComponent("favorites_backup.json"))

        let targetBrowserState = resolvedShared.appendingPathComponent("BrowserState", isDirectory: true)
        try FileManager.default.createDirectory(at: targetBrowserState, withIntermediateDirectories: true)

        let didMigrate = LiveContainerEnvironment.migrateLegacySubdirectoryIfNeeded(
            into: targetBrowserState,
            legacyCandidates: [legacyBrowserState, guestAppSupport.appendingPathComponent("BrowserState", isDirectory: true)]
        )
        XCTAssertTrue(didMigrate)
        let migratedContent = try String(contentsOf: targetBrowserState.appendingPathComponent("favorites_backup.json"), encoding: .utf8)
        XCTAssertEqual(migratedContent, sentinelJSON)
        // Original LC1 file remains intact as backup
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyBrowserState.appendingPathComponent("favorites_backup.json").path))

        // Subsequent migration call is a no-op once target is populated
        let migratedAgain = LiveContainerEnvironment.migrateLegacySubdirectoryIfNeeded(
            into: targetBrowserState,
            legacyCandidates: [legacyBrowserState]
        )
        XCTAssertFalse(migratedAgain)
    }

    // MARK: - 2. Air-Gapped Local FingerprintJS v4 Execution, Lie Checks & Baseline Diff

    @MainActor
    func testAirGappedFingerprintAuditProducesVisitorIDZeroLiesAndAccurateDiff() async throws {
        let engine = FingerprintAuditEngine()

        let rawOuter = await engine.runAudit(
            mode: .shieldPaused,
            viewportSize: CGSize(width: 466, height: 678)
        )
        let outerSnap = try XCTUnwrap(rawOuter)
        XCTAssertNil(engine.lastError)
        XCTAssertGreaterThanOrEqual(outerSnap.visitorId.count, 16, "Expected non-empty FingerprintJS v4 visitorId")
        XCTAssertGreaterThanOrEqual(outerSnap.signals.count, 25, "Expected full FingerprintJS component breakdown")
        XCTAssertEqual(outerSnap.lieCount, 0, "Stock WKWebView must report 0 lies: \(outerSnap.lieChecks)")
        XCTAssertEqual(Int(outerSnap.viewportSize.width), 466)
        XCTAssertEqual(Int(outerSnap.viewportSize.height), 678)
        XCTAssertTrue(outerSnap.signals.contains { $0.id == "viewportLive" })
        XCTAssertTrue(outerSnap.signals.contains { $0.id == "canvas" })
        XCTAssertTrue(outerSnap.signals.contains { $0.id == "languages" })

        engine.pinCurrentAsBaseline()
        XCTAssertEqual(engine.baselineSnapshot?.id, outerSnap.id)

        // Simulate unfolding iPhone Duo inner landscape display -> viewportLive must appear in baseline diff
        let rawInner = await engine.runAudit(
            mode: .privateEphemeral,
            viewportSize: CGSize(width: 951, height: 669)
        )
        let innerSnap = try XCTUnwrap(rawInner)
        XCTAssertEqual(innerSnap.lieCount, 0)
        let changed = innerSnap.changedSignalIDs(comparedTo: outerSnap)
        XCTAssertTrue(changed.contains("viewportLive"), "Unfolded viewport change must be flagged in baseline diff")
    }

    @MainActor
    func testZeroFrameFingerprintShieldMutatesVisitorIDWithZeroLiesAcrossAll8HardModeChecks() async throws {
        let engine = FingerprintAuditEngine()
        let viewport = CGSize(width: 466, height: 678)

        // 1. Raw native unshielded baseline
        let rawNative = await engine.runAudit(
            mode: .shieldPaused,
            viewportSize: viewport,
            userAgentProfile: .iosSafari
        )
        let nativeSnap = try XCTUnwrap(rawNative)
        XCTAssertEqual(nativeSnap.lieChecks.count, 8, "Audit engine must run all 8 hard-mode integrity checks")
        XCTAssertEqual(nativeSnap.lieCount, 0, "Native WebKit must pass 8/8 checks: \(nativeSnap.lieChecks)")

        // 2. Shielded Standard run with deterministic Seed A
        let seedA = "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff"
        let rawShieldA1 = await engine.runAudit(
            mode: .standard,
            viewportSize: viewport,
            userAgentProfile: .iosSafari,
            customSeed: seedA,
            maskFoldableScreen: false
        )
        let shieldA1 = try XCTUnwrap(rawShieldA1)
        XCTAssertEqual(shieldA1.lieChecks.count, 8)
        XCTAssertEqual(shieldA1.lieCount, 0, "0-Frame Fingerprint Shield must pass all 8/8 CreepJS/FP-Pro checks: \(shieldA1.lieChecks)")
        XCTAssertNotEqual(shieldA1.visitorId, nativeSnap.visitorId, "Shielded Visitor ID must diverge from raw native WebKit")

        let diffVsNative = shieldA1.changedSignalIDs(comparedTo: nativeSnap)
        XCTAssertTrue(diffVsNative.contains("canvas"), "Seeded farbling must mutate Canvas signal: \(diffVsNative)")
        XCTAssertTrue(diffVsNative.contains("audio"), "Seeded farbling must mutate WebAudio signal: \(diffVsNative)")

        // 3. Re-running with the exact same Seed A must be 100% deterministic (never random noise)
        let rawShieldA2 = await engine.runAudit(
            mode: .standard,
            viewportSize: viewport,
            userAgentProfile: .iosSafari,
            customSeed: seedA,
            maskFoldableScreen: false
        )
        let shieldA2 = try XCTUnwrap(rawShieldA2)
        XCTAssertEqual(shieldA2.visitorId, shieldA1.visitorId, "Same session seed must produce identical Visitor ID")
        XCTAssertEqual(shieldA2.lieCount, 0)

        // 4. Ephemeral Private session (fresh cryptographic seed) must rotate Visitor ID cleanly
        let rawPrivate = await engine.runAudit(
            mode: .privateEphemeral,
            viewportSize: viewport,
            userAgentProfile: .iosSafari,
            maskFoldableScreen: false
        )
        let privateSnap = try XCTUnwrap(rawPrivate)
        XCTAssertEqual(privateSnap.lieCount, 0, "Private shielded session must maintain 0 lies: \(privateSnap.lieChecks)")
        XCTAssertNotEqual(privateSnap.visitorId, shieldA1.visitorId, "Private ephemeral seed must rotate Visitor ID")
        XCTAssertNotEqual(privateSnap.visitorId, nativeSnap.visitorId, "Private ephemeral seed must diverge from native baseline")

        // 5. Optional Foldable Screen Class Masking must preserve innerWidth <= screen.width with 0 lies
        let rawMasked = await engine.runAudit(
            mode: .standard,
            viewportSize: CGSize(width: 951, height: 669),
            userAgentProfile: .iosSafari,
            customSeed: seedA,
            maskFoldableScreen: true
        )
        let maskedSnap = try XCTUnwrap(rawMasked)
        XCTAssertEqual(maskedSnap.lieCount, 0, "Screen masking must pass all 8/8 checks: \(maskedSnap.lieChecks)")
        XCTAssertGreaterThanOrEqual(maskedSnap.screenSize.width, maskedSnap.viewportSize.width)
        XCTAssertGreaterThanOrEqual(maskedSnap.screenSize.height, maskedSnap.viewportSize.height)
    }

    @MainActor
    func testLiveCommercialFingerprintProRotationInRealSession() async throws {
        guard ProcessInfo.processInfo.environment["DYSPROSIUM_LIVE_FPPRO_TEST"] == "1" else {
            return
        }
        // Test BOTH Standard mode and Private mode directly through production CleanroomWebKitSession
        for isPrivate in [false, true] {
            let modeLabel = isPrivate ? "PRIVATE" : "STANDARD"
            let session = CleanroomWebKitSession(isPrivate: isPrivate)
            session.webView.frame = CGRect(x: 0, y: 0, width: 466, height: 678) // exact iPhone Duo folded outer display geometry
            session.load(urlString: "https://fingerprint.com/demo/")

            let first = try await waitForFPProResult(webView: session.webView, requireFreshPage: false)
            print("[LIVE_FPPRO_\(modeLabel)_1]", first)

            // Mark the old document so we never accidentally scrape stale DOM before reload commits.
            _ = try? await session.webView.evaluateJavaScript("window.__dyOldPageMarker = true;")
            session.rotateFingerprintAndReload()
            let second = try await waitForFPProResult(webView: session.webView, requireFreshPage: true)
            print("[LIVE_FPPRO_\(modeLabel)_2]", second)

            XCTAssertNotNil(first["visitor_id"] as? String)
            XCTAssertNotNil(second["visitor_id"] as? String)
            XCTAssertNotEqual(
                first["visitor_id"] as? String,
                second["visitor_id"] as? String,
                "\(modeLabel) Rotate Fingerprint & Reload must produce a brand-new commercial Fingerprint Pro Visitor ID"
            )
            XCTAssertEqual(second["tampering"] as? String, "false", "\(modeLabel) rotation must keep tampering:false: \(second)")
        }
    }

    @MainActor
    private func waitForFPProResult(webView: WKWebView, requireFreshPage: Bool) async throws -> [String: Any] {
        let freshGate = requireFreshPage ? "if (window.__dyOldPageMarker) return '';" : ""
        let scrapeJS = """
        (() => {
          \(freshGate)
          const text = document.body ? document.body.innerText : '';
          const mId = text.match(/"visitor_id":\\s*"([^"]+)"/);
          const mTamp = text.match(/"tampering":\\s*(true|false)/);
          if (!mId || !mTamp) return '';
          const mFound = text.match(/"visitor_found":\\s*(true|false)/);
          const mScore = text.match(/"tampering_ml_score":\\s*([0-9.]+)/);
          const mIncog = text.match(/"incognito":\\s*(true|false)/);
          const mBot = text.match(/"bot":\\s*"([^"]+)"/);
          return JSON.stringify({
            visitor_id: mId[1],
            visitor_found: mFound ? mFound[1] : null,
            tampering: mTamp[1],
            tampering_ml_score: mScore ? mScore[1] : null,
            incognito: mIncog ? mIncog[1] : null,
            bot: mBot ? mBot[1] : null,
            ua: navigator.userAgent,
            screen: screen.width + 'x' + screen.height
          });
        })()
        """
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let raw = try? await webView.evaluateJavaScript(scrapeJS) as? String,
               !raw.isEmpty,
               let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        XCTFail("Timed out waiting for fingerprint.com/demo/ response")
        return [:]
    }
}
