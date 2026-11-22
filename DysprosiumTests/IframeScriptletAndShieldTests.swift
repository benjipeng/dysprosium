import Foundation
import WebKit
import XCTest
@testable import Dysprosium

final class IframeScriptletAndShieldTests: XCTestCase {

    @MainActor
    private func makeOfflineBlocker(
        in directory: URL,
        filterPayload: String
    ) async throws -> CleanroomContentBlocker {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let subs: [FilterSubscription] = CleanroomContentBlocker.defaultCommunitySubscriptions.map { seed in
            var copy = seed
            if seed.id == "ubo-unbreak" {
                copy.isEnabled = true
                copy.lastSyncedAt = now
            } else {
                copy.isEnabled = false
            }
            return copy
        }
        try JSONEncoder().encode(subs).write(to: directory.appendingPathComponent("subscriptions.json"))
        try Data(filterPayload.utf8).write(to: directory.appendingPathComponent("ubo-unbreak.cache"))
        let blocker = CleanroomContentBlocker(storageDirectory: directory)
        _ = await blocker.ensureCompiledLists()
        return blocker
    }

    // MARK: - 1. Per-Site Content Shield Bypass Normalization & Persistence

    @MainActor
    func testBypassHostNormalizationPersistenceAndEffectiveShieldState() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dysprosium-bypass-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blocker = CleanroomContentBlocker(storageDirectory: tempDir)

        // Normalization invariants
        XCTAssertNil(blocker.normalizeBypassHost(nil))
        XCTAssertNil(blocker.normalizeBypassHost(""))
        XCTAssertNil(blocker.normalizeBypassHost("   "))
        XCTAssertNil(blocker.normalizeBypassHost("..."))
        XCTAssertEqual(blocker.normalizeBypassHost("WWW.Example.COM."), "example.com")
        XCTAssertEqual(blocker.normalizeBypassHost("example.com"), "example.com")
        XCTAssertEqual(blocker.normalizeBypassHost("  www.video.example.com  "), "video.example.com")
        XCTAssertEqual(blocker.normalizeBypassHost("cdn.example.com"), "cdn.example.com")

        // Initially nothing bypassed
        XCTAssertTrue(blocker.bypassedHosts.isEmpty)
        XCTAssertFalse(blocker.isHostBypassed("www.videohost.test"))
        XCTAssertTrue(blocker.effectiveShieldEnabled(globalEnabled: true, forHost: "www.videohost.test"))
        XCTAssertFalse(blocker.effectiveShieldEnabled(globalEnabled: false, forHost: "www.videohost.test"))

        // Pause shield on www.videohost.test -> normalizes to videohost.test
        await blocker.setHostBypassed(true, for: "WWW.VideoHost.Test.")
        XCTAssertEqual(blocker.bypassedHosts, ["videohost.test"])
        XCTAssertTrue(blocker.isHostBypassed("videohost.test"))
        XCTAssertTrue(blocker.isHostBypassed("www.videohost.test"))
        XCTAssertFalse(blocker.isHostBypassed("other.test"))
        XCTAssertFalse(blocker.effectiveShieldEnabled(globalEnabled: true, forHost: "videohost.test"))
        XCTAssertFalse(blocker.effectiveShieldEnabled(globalEnabled: true, forHost: "www.videohost.test"))
        XCTAssertTrue(blocker.effectiveShieldEnabled(globalEnabled: true, forHost: "other.test"))
        XCTAssertTrue(blocker.effectiveShieldEnabled(globalEnabled: true, forHost: nil))

        // Reloading from same storage namespace restores persisted bypassedHosts
        let restored = CleanroomContentBlocker(storageDirectory: tempDir)
        XCTAssertEqual(restored.bypassedHosts, ["videohost.test"])
        XCTAssertTrue(restored.isHostBypassed("www.videohost.test"))
        XCTAssertFalse(restored.effectiveShieldEnabled(globalEnabled: true, forHost: "videohost.test"))

        // Removing bypass persists removal
        await restored.setHostBypassed(false, for: "videohost.test")
        XCTAssertTrue(restored.bypassedHosts.isEmpty)
        XCTAssertTrue(restored.effectiveShieldEnabled(globalEnabled: true, forHost: "www.videohost.test"))

        let restoredAfterResume = CleanroomContentBlocker(storageDirectory: tempDir)
        XCTAssertTrue(restoredAfterResume.bypassedHosts.isEmpty)
    }

    // MARK: - 2. Bypass Decouples Ad-Blocking from Stream Capture on Attached Controllers

    @MainActor
    func testHostBypassRemovesShieldScriptsWhileKeepingStreamInterceptorActive() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dysprosium-bypass-apply-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = """
        blocked-site.test##+js(set, __blockedSiteFlag, true)
        other-site.test##+js(set, __otherSiteFlag, true)
        embed-host.test##+js(set, __embedHostFlag, true)
        ||ad-network.test^$third-party
        """
        let blocker = try await makeOfflineBlocker(in: tempDir, filterPayload: payload)

        let bypassedController = WKUserContentController()
        let unaffectedController = WKUserContentController()

        await blocker.registerAndApply(
            to: bypassedController,
            currentHostProvider: { "www.blocked-site.test" },
            isEnabledProvider: { true }
        )
        await blocker.registerAndApply(
            to: unaffectedController,
            currentHostProvider: { "other-site.test" },
            isEnabledProvider: { true }
        )

        func hasStreamInterceptor(_ controller: WKUserContentController) -> Bool {
            controller.userScripts.contains { $0.source.contains("__dysprosiumHookInstalled") }
        }
        func hasAntiAdblockDefuser(_ controller: WKUserContentController) -> Bool {
            controller.userScripts.contains { $0.source.contains("__dysprosiumBaitDefuserInstalled") }
        }
        func hasScriptletToken(_ controller: WKUserContentController, token: String) -> Bool {
            controller.userScripts.contains { $0.source.contains(token) }
        }

        // Before bypass: both controllers have stream interceptor, bait defuser, and host scriptlet
        XCTAssertTrue(hasStreamInterceptor(bypassedController))
        XCTAssertTrue(hasAntiAdblockDefuser(bypassedController))
        XCTAssertTrue(hasScriptletToken(bypassedController, token: "__blockedSiteFlag"))

        XCTAssertTrue(hasStreamInterceptor(unaffectedController))
        XCTAssertTrue(hasAntiAdblockDefuser(unaffectedController))
        XCTAssertTrue(hasScriptletToken(unaffectedController, token: "__otherSiteFlag"))

        // Pause shield on blocked-site.test (matches www.blocked-site.test)
        await blocker.setHostBypassed(true, for: "blocked-site.test")

        // Bypassed controller keeps stream interceptor, strips anti-adblock & scriptlets
        XCTAssertTrue(hasStreamInterceptor(bypassedController), "Stream interceptor must stay active when host is bypassed")
        XCTAssertFalse(hasAntiAdblockDefuser(bypassedController), "Anti-adblock defuser must be removed when host is bypassed")
        XCTAssertFalse(hasScriptletToken(bypassedController, token: "__blockedSiteFlag"), "Host scriptlet must be removed when host is bypassed")

        // Subframe scriptlets must also be suppressed while mainHost is bypassed
        let injectedWhileBypassed = blocker.ensureSubframeScriptlets(
            forHost: "embed-host.test",
            on: bypassedController,
            shieldEnabled: true,
            mainHost: "www.blocked-site.test"
        )
        XCTAssertFalse(injectedWhileBypassed)
        XCTAssertFalse(hasScriptletToken(bypassedController, token: "__embedHostFlag"))

        // Unaffected controller remains fully shielded
        XCTAssertTrue(hasStreamInterceptor(unaffectedController))
        XCTAssertTrue(hasAntiAdblockDefuser(unaffectedController))
        XCTAssertTrue(hasScriptletToken(unaffectedController, token: "__otherSiteFlag"))

        // Resume shield on blocked-site.test -> shield scripts re-attached automatically
        await blocker.setHostBypassed(false, for: "www.blocked-site.test")
        XCTAssertTrue(hasStreamInterceptor(bypassedController))
        XCTAssertTrue(hasAntiAdblockDefuser(bypassedController))
        XCTAssertTrue(hasScriptletToken(bypassedController, token: "__blockedSiteFlag"))
    }

    // MARK: - 3. Subframe Scriptlet Dispatch, Deduplication, Reset & Zero-Bloat Invariant

    @MainActor
    func testEnsureSubframeScriptletsDeduplicationResetAndZeroBloat() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dysprosium-subframe-unit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = """
        parent-host.test##+js(set, __parentFlag, true)
        player-embed.test,~clean.player-embed.test##+js(set, __embedFlag, true)
        stream-host.test##+js(set, __streamFlag, true)
        """
        let blocker = try await makeOfflineBlocker(in: tempDir, filterPayload: payload)
        let controller = WKUserContentController()

        blocker.installUserScripts(on: controller, shieldEnabled: true, forHost: "parent-host.test")

        // Main-frame scriptlet must be installed with forMainFrameOnly == false
        let mainScriptlet = controller.userScripts.first { $0.source.contains("__parentFlag") }
        XCTAssertNotNil(mainScriptlet)
        XCTAssertEqual(mainScriptlet?.isForMainFrameOnly, false)

        let baselineCount = controller.userScripts.count

        // Unmatched host -> returns false with 0 scripts added
        XCTAssertFalse(
            blocker.ensureSubframeScriptlets(
                forHost: "random-unmatched.test",
                on: controller,
                shieldEnabled: true,
                mainHost: "parent-host.test"
            )
        )
        XCTAssertEqual(controller.userScripts.count, baselineCount)

        // Excluded subdomain -> returns false with 0 scripts added
        XCTAssertFalse(
            blocker.ensureSubframeScriptlets(
                forHost: "clean.player-embed.test",
                on: controller,
                shieldEnabled: true,
                mainHost: "parent-host.test"
            )
        )
        XCTAssertEqual(controller.userScripts.count, baselineCount)

        // Already-injected main host -> deduplicated, returns false
        XCTAssertFalse(
            blocker.ensureSubframeScriptlets(
                forHost: "parent-host.test",
                on: controller,
                shieldEnabled: true,
                mainHost: "parent-host.test"
            )
        )
        XCTAssertEqual(controller.userScripts.count, baselineCount)

        // Matching third-party video host -> appends without removing existing scripts
        XCTAssertTrue(
            blocker.ensureSubframeScriptlets(
                forHost: "embed.player-embed.test",
                on: controller,
                shieldEnabled: true,
                mainHost: "parent-host.test"
            )
        )
        XCTAssertEqual(controller.userScripts.count, baselineCount + 1)
        XCTAssertTrue(controller.userScripts.contains { $0.source.contains("__parentFlag") }, "Appending subframe scriptlet must not remove existing scripts")
        let appended = controller.userScripts.last
        XCTAssertTrue(appended?.source.contains("__embedFlag") == true)
        XCTAssertEqual(appended?.isForMainFrameOnly, false)

        // Second call for same subframe host on same controller -> deduplicated
        XCTAssertFalse(
            blocker.ensureSubframeScriptlets(
                forHost: "embed.player-embed.test",
                on: controller,
                shieldEnabled: true,
                mainHost: "parent-host.test"
            )
        )
        XCTAssertEqual(controller.userScripts.count, baselineCount + 1)

        // Shield globally disabled -> never injects
        XCTAssertFalse(
            blocker.ensureSubframeScriptlets(
                forHost: "stream-host.test",
                on: controller,
                shieldEnabled: false,
                mainHost: "parent-host.test"
            )
        )
        XCTAssertEqual(controller.userScripts.count, baselineCount + 1)

        // Reset via installUserScripts clears tracked subframe hosts so re-injection works on next navigation
        blocker.installUserScripts(on: controller, shieldEnabled: true, forHost: "parent-host.test")
        XCTAssertEqual(controller.userScripts.count, baselineCount)
        XCTAssertTrue(
            blocker.ensureSubframeScriptlets(
                forHost: "embed.player-embed.test",
                on: controller,
                shieldEnabled: true,
                mainHost: "parent-host.test"
            )
        )
        XCTAssertEqual(controller.userScripts.count, baselineCount + 1)
    }

    // MARK: - 4. Real WKWebView End-to-End Cross-Host Iframe Scriptlet Verification

    @MainActor
    func testRealWKWebViewDispatchesMatchingIframeScriptletWithoutBleedOrBloat() async throws {
        final class SyntheticSchemeHandler: NSObject, WKURLSchemeHandler {
            let pages: [String: String]
            init(pages: [String: String]) { self.pages = pages }

            func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
                guard let url = urlSchemeTask.request.url,
                      let host = url.host(),
                      let html = pages[host] else {
                    urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let data = Data(html.utf8)
                let response = URLResponse(
                    url: url,
                    mimeType: "text/html",
                    expectedContentLength: data.count,
                    textEncodingName: "utf-8"
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }

            func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
        }

        @MainActor
        final class SubframeWiringDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            let blocker: CleanroomContentBlocker
            let mainHost: String
            var ensureResultsByHost: [String: Bool] = [:]
            var reportedFrames: [String: [String: Any]] = [:]

            init(blocker: CleanroomContentBlocker, mainHost: String) {
                self.blocker = blocker
                self.mainHost = mainHost
            }

            func webView(
                _ webView: WKWebView,
                decidePolicyFor navigationAction: WKNavigationAction,
                decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
            ) {
                if navigationAction.targetFrame?.isMainFrame == false,
                   let subframeHost = navigationAction.request.url?.host() {
                    let didInject = blocker.ensureSubframeScriptlets(
                        forHost: subframeHost,
                        on: webView.configuration.userContentController,
                        shieldEnabled: true,
                        mainHost: mainHost
                    )
                    ensureResultsByHost[subframeHost] = didInject
                }
                decisionHandler(.allow)
            }

            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let dict = message.body as? [String: Any],
                      let host = dict["host"] as? String else { return }
                reportedFrames[host] = dict
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dysprosium-wk-iframe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = """
        portal.test##+js(set, __portalMainSentinel, true)
        player-embed.test,~excluded.player-embed.test##+js(set, __iframePlayerDefused, true)
        """
        let blocker = try await makeOfflineBlocker(in: tempDir, filterPayload: payload)

        func makeProbeHTML(extraBody: String = "") -> String {
            """
            <!DOCTYPE html>
            <html><head><script>
            window.webkit.messageHandlers.probeReport.postMessage({
                host: location.hostname,
                portalSentinel: window.__portalMainSentinel === true,
                iframeDefused: window.__iframePlayerDefused === true,
                scriptletsApplied: window.__dysprosiumScriptletsApplied === true
            });
            </script></head><body>\(extraBody)</body></html>
            """
        }

        let pages: [String: String] = [
            "portal.test": makeProbeHTML(extraBody: """
                <iframe src="dysptest://embed.player-embed.test/v/1"></iframe>
                <iframe src="dysptest://excluded.player-embed.test/v/2"></iframe>
                <iframe src="dysptest://unmatched-widget.test/box"></iframe>
            """),
            "embed.player-embed.test": makeProbeHTML(),
            "excluded.player-embed.test": makeProbeHTML(),
            "unmatched-widget.test": makeProbeHTML()
        ]

        let schemeHandler = SyntheticSchemeHandler(pages: pages)
        let delegate = SubframeWiringDelegate(blocker: blocker, mainHost: "portal.test")

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "dysptest")
        let ucc = WKUserContentController()
        ucc.add(delegate, name: "probeReport")
        config.userContentController = ucc

        blocker.installUserScripts(on: ucc, shieldEnabled: true, forHost: "portal.test")
        let scriptsAfterMainInstall = ucc.userScripts.count

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: config)
        wv.navigationDelegate = delegate
        wv.load(URLRequest(url: URL(string: "dysptest://portal.test/watch")!))

        for _ in 0..<50 {
            if delegate.reportedFrames.count >= 4 { break }
            try await Task.sleep(for: .milliseconds(60))
        }

        // Verify all 4 frames reported
        XCTAssertEqual(delegate.reportedFrames.count, 4, "Expected main frame + 3 iframes to report; got \(delegate.reportedFrames.keys.sorted())")

        // Verify ensureSubframeScriptlets injected ONLY for embed.player-embed.test (0 bytes for excluded & unmatched)
        XCTAssertEqual(delegate.ensureResultsByHost["embed.player-embed.test"], true)
        XCTAssertEqual(delegate.ensureResultsByHost["excluded.player-embed.test"], false)
        XCTAssertEqual(delegate.ensureResultsByHost["unmatched-widget.test"], false)
        XCTAssertEqual(ucc.userScripts.count, scriptsAfterMainInstall + 1, "Only the single matched subframe host should append a user script")

        // Main frame: received portal.test rule, did NOT receive player-embed.test rule
        let portal = try XCTUnwrap(delegate.reportedFrames["portal.test"])
        XCTAssertEqual(portal["portalSentinel"] as? Bool, true)
        XCTAssertEqual(portal["iframeDefused"] as? Bool, false)

        // Matched third-party iframe: received player-embed.test rule, did NOT receive portal.test rule
        let matchedIframe = try XCTUnwrap(delegate.reportedFrames["embed.player-embed.test"])
        XCTAssertEqual(matchedIframe["iframeDefused"] as? Bool, true, "Third-party iframe embed.player-embed.test must receive its matching uBO scriptlet")
        XCTAssertEqual(matchedIframe["portalSentinel"] as? Bool, false, "Main-frame portal.test scriptlet must NOT mis-fire inside third-party iframe")

        // Excluded subdomain iframe: did NOT receive player-embed.test rule or portal.test rule
        let excludedIframe = try XCTUnwrap(delegate.reportedFrames["excluded.player-embed.test"])
        XCTAssertEqual(excludedIframe["iframeDefused"] as? Bool, false, "Excluded subdomain must not execute parent scriptlet")
        XCTAssertEqual(excludedIframe["portalSentinel"] as? Bool, false)
        XCTAssertEqual(excludedIframe["scriptletsApplied"] as? Bool, false)

        // Unmatched third-party iframe: 0 bytes injected, no scriptlets applied
        let unmatchedIframe = try XCTUnwrap(delegate.reportedFrames["unmatched-widget.test"])
        XCTAssertEqual(unmatchedIframe["iframeDefused"] as? Bool, false)
        XCTAssertEqual(unmatchedIframe["portalSentinel"] as? Bool, false)
        XCTAssertEqual(unmatchedIframe["scriptletsApplied"] as? Bool, false)

        ucc.removeScriptMessageHandler(forName: "probeReport")
    }

    // MARK: - 5. Feature-Gated Minimal JS Size + Native `:has()`, `~domain`, Coalescing & `$doc` Bytecode

    @MainActor
    func testFeatureGatedRuntimeCompactnessAndNativeHasAndDocBytecodeCompilation() async throws {
        // 1. Verify feature-gated JS omits unused primitive machinery
        let singleSetBuckets = WebKitRuleCompiler.parseABPFilterTextToBuckets("lean.test##+js(set, cRAds, true)")
        let leanJS = BrowserInjectedScripts.buildScriptletRuntimeScript(rules: singleSetBuckets.scriptletRules)
        XCTAssertLessThan(leanJS.utf8.count, 7_800, "Single set-constant host script must stay lean: \(leanJS.utf8.count) B")
        XCTAssertFalse(leanJS.contains("ensureNoXhrInstalled"))
        XCTAssertFalse(leanJS.contains("ensureDomScrubInstalled"))
        XCTAssertFalse(leanJS.contains("makeDecoyWindow"))
        XCTAssertFalse(leanJS.contains("pruneNestedPath"))

        // 2. Verify native CSS `:has(...)`, `~excludedDomain`, domain selector coalescing, and `$doc` compile in WKContentRuleListStore
        let filterText = """
        twitch.tv##.player-overlay:has(> div.ad-slot)
        twitch.tv##.ad-banner-1
        twitch.tv##.ad-banner-2
        twitch.tv##.ad-banner-3
        ~safe-partner.test##.global-nag-banner:has(> button.close)
        procedural.test##div:has-text(Sponsored)
        procedural.test##div:contains(Promoted)
        ||popunder-malware.test^$doc
        ||frame-ad.test^$subdoc,third-party
        ||tracker.test^$~image,~stylesheet
        """
        let buckets = WebKitRuleCompiler.parseABPFilterTextToBuckets(filterText)
        // 4 twitch.tv selectors coalesced into 1 rule + 1 ~safe-partner.test rule + 3 network rules = 5 total DFA rules (procedural skipped!)
        XCTAssertEqual(buckets.blockAndCosmeticRules.count, 5, "Expected coalesced twitch.tv rule + unless-domain rule + 3 network rules")

        let jsonData = try JSONSerialization.data(withJSONObject: buckets.blockAndCosmeticRules)
        let jsonString = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let testID = "dysprosium.test.v5.\(UUID().uuidString)"
        let compiled = try await store.compileContentRuleList(forIdentifier: testID, encodedContentRuleList: jsonString)
        XCTAssertNotNil(compiled)
        try? await store.removeContentRuleList(forIdentifier: testID)
    }

    // MARK: - 6. Extended Universal Scriptlet Primitives in Real WKWebView

    @MainActor
    func testExtendedUniversalScriptletPrimitivesExecuteInRealWKWebView() async throws {
        let filterText = """
        suite.test##+js(nano-stb, countdownTick, 5000, 0.002)
        suite.test##+js(acs, Number.isInteger, hostileInlineMarker)
        suite.test#%#//scriptlet('prevent-window-open', 'popunder.evil', '5')
        suite.test##+js(nowoif, /nullpopup\\.evil/)
        suite.test##+js(aost, window.sharedProbeProp, hostileCallerFn)
        suite.test#%#//scriptlet('set-local-storage-item', 'cookieConsent', 'accepted')
        suite.test#%#//scriptlet('trusted-set-local-storage-item', 'customJsonState', '{"ads":0}')
        suite.test#%#//scriptlet('set-session-storage-item', 'ageVerified', '1')
        suite.test#%#//scriptlet('set-cookie', 'gdpr_ok', 'true')
        suite.test#%#//scriptlet('trusted-set-cookie', 'cmp_prefs', 'essential_only')
        suite.test#%#//scriptlet('remove-cookie', 'paywall_meter')
        suite.test##+js(rc, modal-locked|blur-wall, body)
        suite.test##+js(ra, inert|disabled, #player-wrap)
        suite.test##+js(rmnt, script, obfuscatedAdPayload)
        suite.test#%#//scriptlet('href-sanitizer', 'a.out-b64', '?url', 'base64decode')
        suite.test#%#//scriptlet('prevent-element-src-loading', 'script', 'evil-sdk.test')
        suite.test#%#//scriptlet('json-prune-fetch-response', 'adSlots playerAds', '', '/api/player')
        suite.test##+js(noeval-if, debuggerTrap)
        """
        let buckets = WebKitRuleCompiler.parseABPFilterTextToBuckets(filterText)
        XCTAssertEqual(buckets.scriptletRules.count, 18)

        let runtimeJS = BrowserInjectedScripts.buildScriptletRuntimeScript(rules: buckets.scriptletRules)
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        // Seed a pre-existing paywall cookie before scriptlets run so `remove-cookie` expires it
        let seedCookieJS = "document.cookie = 'paywall_meter=3; path=/';"
        ucc.addUserScript(WKUserScript(source: seedCookieJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: runtimeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = ucc

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 400), configuration: config)
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <script>
        window.sharedProbeProp = 'cleanValue';
        function cleanCallerFn() { return window.sharedProbeProp; }
        function hostileCallerFn() { return window.sharedProbeProp; }

        window.__acsCleanRan = false;
        if (Number.isInteger(42)) { window.__acsCleanRan = true; }
        </script>
        <script>
        // Should abort on Number.isInteger because inline text contains hostileInlineMarker
        window.__acsHostileCompleted = false;
        Number.isInteger(1);
        window.__acsHostileCompleted = true;
        </script>
        </head>
        <body class="modal-locked blur-wall keep-theme">
            <div id="player-wrap" inert disabled data-keep="1"></div>
            <a class="out-b64" href="https://suite.test/jump?url=aHR0cHM6Ly92aWRlby5leGFtcGxlL2NsZWFuLm1wNA==">Download</a>
            <script>window.__badRmntScript = "obfuscatedAdPayload";</script>
            <script>
            window.__timerBoostedMs = null;
            const t0 = performance.now();
            setTimeout(function countdownTick() {
                window.__timerBoostedMs = performance.now() - t0;
            }, 5000);

            const decoyWin = window.open('https://popunder.evil/ad', '_blank');
            const nullWin = window.open('https://nullpopup.evil/ad', '_blank');

            let aostAborted = false;
            try { hostileCallerFn(); } catch (e) { aostAborted = true; }
            const aostClean = cleanCallerFn();

            const blockedScript = document.createElement('script');
            let blockedScriptSyntheticLoad = false;
            blockedScript.onload = function() { blockedScriptSyntheticLoad = true; };
            blockedScript.src = 'https://evil-sdk.test/ad.js';

            const evalBlocked = window.eval('1 + 1 /* debuggerTrap */');
            const evalAllowed = window.eval('20 + 22');

            setTimeout(function() {
                const scriptsText = Array.from(document.querySelectorAll('script')).map(s => s.textContent).join('\\n');
                const rmntNeedle = 'obfuscated' + 'AdPayload';
                window.__suiteReport = {
                    timerFast: window.__timerBoostedMs !== null && window.__timerBoostedMs < 400,
                    acsClean: window.__acsCleanRan === true,
                    acsAborted: window.__acsHostileCompleted === false,
                    decoyObj: Boolean(decoyWin && decoyWin.closed === false && typeof decoyWin.focus === 'function'),
                    nullBlocked: nullWin === null,
                    aostAborted: aostAborted,
                    aostClean: aostClean === 'cleanValue',
                    lsSafe: localStorage.getItem('cookieConsent') === 'accepted',
                    lsTrusted: localStorage.getItem('customJsonState') === '{"ads":0}',
                    ssSafe: sessionStorage.getItem('ageVerified') === '1',
                    cookieSet: document.cookie.indexOf('gdpr_ok=true') !== -1 && document.cookie.indexOf('cmp_prefs=essential_only') !== -1,
                    cookieRemoved: document.cookie.indexOf('paywall_meter=3') === -1,
                    classScrubbed: !document.body.classList.contains('modal-locked') && !document.body.classList.contains('blur-wall') && document.body.classList.contains('keep-theme'),
                    attrScrubbed: !document.getElementById('player-wrap').hasAttribute('inert') && !document.getElementById('player-wrap').hasAttribute('disabled') && document.getElementById('player-wrap').getAttribute('data-keep') === '1',
                    rmntScrubbed: scriptsText.indexOf(rmntNeedle) === -1,
                    hrefSanitized: document.querySelector('a.out-b64').getAttribute('href') === 'https://video.example/clean.mp4',
                    srcPrevented: blockedScript.getAttribute('src') === null && blockedScriptSyntheticLoad === true,
                    evalBlocked: evalBlocked === undefined,
                    evalAllowed: evalAllowed === 42
                };
            }, 80);
            </script>
        </body>
        </html>
        """
        wv.loadHTMLString(html, baseURL: URL(string: "https://suite.test/watch"))
        var reportJSON = ""
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(60))
            reportJSON = (try? await wv.evaluateJavaScript("JSON.stringify(window.__suiteReport || null)") as? String) ?? ""
            if reportJSON != "null" && !reportJSON.isEmpty {
                break
            }
        }
        let data = try XCTUnwrap(reportJSON.data(using: .utf8))
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Bool])
        for (key, passed) in report {
            XCTAssertTrue(passed, "Primitive check '\(key)' failed in report: \(reportJSON)")
        }
        XCTAssertEqual(report.count, 19)
    }
}
