import Foundation
import Observation
import UIKit
import WebKit

/// Audit posture for running the local, air-gapped FingerprintJS + Integrity probe.
public enum FingerprintAuditMode: String, CaseIterable, Identifiable, Sendable {
    case standard
    case privateEphemeral
    case shieldPaused

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: return "Standard"
        case .privateEphemeral: return "Private"
        case .shieldPaused: return "No Shield"
        }
    }

    public var subtitle: String {
        switch self {
        case .standard: return "Persistent store + Content Shield"
        case .privateEphemeral: return "Ephemeral .nonPersistent() + Shield"
        case .shieldPaused: return "Persistent store without Content Shield"
        }
    }

    public var systemImage: String {
        switch self {
        case .standard: return "safari"
        case .privateEphemeral: return "hand.raised.fill"
        case .shieldPaused: return "shield.slash"
        }
    }
}

public enum FingerprintEntropyRisk: String, CaseIterable, Comparable, Sendable {
    case high
    case medium
    case low

    private var sortOrder: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    public static func < (lhs: FingerprintEntropyRisk, rhs: FingerprintEntropyRisk) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    public var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Med"
        case .low: return "Low"
        }
    }
}

public enum FingerprintSignalCategory: String, CaseIterable, Identifiable, Sendable {
    case displayGraphics = "Display & Graphics"
    case localePreferences = "Locale & Preferences"
    case audioHardware = "Audio & Hardware"
    case shieldCapabilities = "Shield & Storage"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .displayGraphics: return "display"
        case .localePreferences: return "globe"
        case .audioHardware: return "waveform"
        case .shieldCapabilities: return "shield.lefthalf.filled"
        }
    }
}

public struct FingerprintSignalItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let category: FingerprintSignalCategory
    public let summary: String
    public let rawDetail: String
    public let entropyRisk: FingerprintEntropyRisk
    public let riskReason: String?
    public let durationMs: Int?

    public init(
        id: String,
        title: String,
        category: FingerprintSignalCategory,
        summary: String,
        rawDetail: String,
        entropyRisk: FingerprintEntropyRisk,
        riskReason: String? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.summary = summary
        self.rawDetail = rawDetail
        self.entropyRisk = entropyRisk
        self.riskReason = riskReason
        self.durationMs = durationMs
    }
}

public struct FingerprintLieCheck: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let passed: Bool
    public let detail: String

    public init(id: String, title: String, passed: Bool, detail: String) {
        self.id = id
        self.title = title
        self.passed = passed
        self.detail = detail
    }
}

public struct FingerprintAuditSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let mode: FingerprintAuditMode
    public let userAgentProfileTitle: String
    public let visitorId: String
    public let fpjsVersion: String
    public let confidenceScore: Double
    public let totalDurationMs: Int
    public let viewportSize: CGSize
    public let screenSize: CGSize
    public let devicePixelRatio: Double
    public let dynamicTypePx: Double?
    public let signals: [FingerprintSignalItem]
    public let lieChecks: [FingerprintLieCheck]
    public let rawJSONReport: String

    public var lieCount: Int {
        lieChecks.filter { !$0.passed }.count
    }

    public var highRiskSignals: [FingerprintSignalItem] {
        signals.filter { $0.entropyRisk == .high }
    }

    public var formattedVisitorID: String {
        let chars = Array(visitorId)
        guard chars.count >= 8 else { return visitorId }
        var groups: [String] = []
        var idx = 0
        while idx < chars.count {
            let end = min(idx + 4, chars.count)
            groups.append(String(chars[idx..<end]))
            idx = end
        }
        return groups.joined(separator: " ")
    }

    public func changedSignalIDs(comparedTo baseline: FingerprintAuditSnapshot) -> Set<String> {
        let baseByID = Dictionary(uniqueKeysWithValues: baseline.signals.map { ($0.id, $0) })
        var changed = Set<String>()
        for item in signals {
            if let old = baseByID[item.id] {
                if old.summary != item.summary || old.rawDetail != item.rawDetail {
                    changed.insert(item.id)
                }
            } else {
                changed.insert(item.id)
            }
        }
        return changed
    }
}

/// Self-contained, 100% air-gapped FingerprintJS v4 + CreepJS-style integrity auditor.
/// Spins up a transient `WKWebView` only during an active audit run and tears it down immediately,
/// maintaining zero background RAM or CPU overhead when Fingerprint Lab is closed.
@Observable
@MainActor
public final class FingerprintAuditEngine {
    public private(set) var isRunning: Bool = false
    public private(set) var currentSnapshot: FingerprintAuditSnapshot?
    public private(set) var baselineSnapshot: FingerprintAuditSnapshot?
    public private(set) var lastError: String?

    public init() {}

    public func pinCurrentAsBaseline() {
        baselineSnapshot = currentSnapshot
    }

    public func clearBaseline() {
        baselineSnapshot = nil
    }

    /// Executes an air-gapped FingerprintJS v4 + 8-check CreepJS-style adversarial integrity audit.
    @discardableResult
    public func runAudit(
        mode: FingerprintAuditMode,
        viewportSize: CGSize,
        userAgentProfile: BrowserUserAgentProfile = BrowserUserAgentProfile.persistedCurrent,
        customSeed: String? = nil,
        maskFoldableScreen: Bool? = nil
    ) async -> FingerprintAuditSnapshot? {
        guard !isRunning else { return currentSnapshot }
        isRunning = true
        lastError = nil
        defer { isRunning = false }

        guard let fpjsSource = Self.loadBundledFPJSSource() else {
            lastError = "Missing bundled fp.min.js resource."
            return nil
        }

        let probeSize = CGSize(
            width: max(320, viewportSize.width.rounded()),
            height: max(480, viewportSize.height.rounded())
        )

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.preferredContentMode = userAgentProfile.preferredContentMode

        let controller = WKUserContentController()
        let receiver = AuditMessageReceiver()
        controller.add(receiver, name: "dysprosiumFingerprintAudit")
        config.userContentController = controller

        let shieldEngine = FingerprintShieldEngine.shared
        let effectiveMaskScreen = maskFoldableScreen ?? shieldEngine.maskFoldableScreen

        // Mirror Dysprosium's real Content Shield + 0-frame Fingerprint Shield on Standard / Private runs,
        // and keep `No Shield` 100% raw unshielded WebKit for honest A/B diffing.
        var activeSeedForUA: String? = nil
        switch mode {
        case .standard:
            let seed = customSeed ?? (shieldEngine.isEnabled ? shieldEngine.standardSeed : nil)
            activeSeedForUA = seed
            await CleanroomContentBlocker.shared.apply(
                enabled: true,
                to: controller,
                forHost: "audit.dysprosium.local",
                includeFingerprintShield: seed != nil,
                fingerprintSeedOverride: seed,
                maskFoldableScreenOverride: effectiveMaskScreen
            )
        case .privateEphemeral:
            let ephemeralSeed = customSeed ?? FingerprintShieldEngine.generateCryptographicSeed()
            activeSeedForUA = ephemeralSeed
            await CleanroomContentBlocker.shared.apply(
                enabled: true,
                to: controller,
                forHost: "audit.dysprosium.local",
                includeFingerprintShield: true,
                fingerprintSeedOverride: ephemeralSeed,
                maskFoldableScreenOverride: effectiveMaskScreen
            )
        case .shieldPaused:
            CleanroomContentBlocker.shared.installUserScripts(
                on: controller,
                shieldEnabled: false,
                forHost: "audit.dysprosium.local",
                includeFingerprintShield: false
            )
        }

        let webView = WKWebView(frame: CGRect(origin: .zero, size: probeSize), configuration: config)
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        // Attach off-screen behind the active window so iOS RunningBoard grants foreground
        // WebContent execution assertions (preventing detached-WebView suspension on headless VMs).
        let hostWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
        hostWindow?.insertSubview(webView, at: 0)

        if let activeSeedForUA {
            webView.customUserAgent = FingerprintShieldEngine.persona(forSeed: activeSeedForUA, profile: userAgentProfile).userAgent
        } else {
            webView.customUserAgent = userAgentProfile.userAgentString
        }
        let navGuard = AirGappedNavigationGuard()
        webView.navigationDelegate = navGuard

        defer {
            controller.removeScriptMessageHandler(forName: "dysprosiumFingerprintAudit")
            webView.navigationDelegate = nil
            webView.stopLoading()
            webView.removeFromSuperview()
        }

        let html = Self.buildOfflineAuditHTML(fpjsSource: fpjsSource)
        let startedAt = ContinuousClock.now
        webView.loadHTMLString(html, baseURL: URL(string: "https://audit.dysprosium.local/lab"))

        guard let payloadData = await receiver.waitForPayloadData(timeoutSeconds: 25),
              let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else {
            lastError = "Offline audit timed out before WebKit returned a report."
            return nil
        }

        let elapsed = startedAt.duration(to: ContinuousClock.now)
        let elapsedMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)

        if let err = payload["error"] as? String, !err.isEmpty {
            lastError = err
            return nil
        }

        let snapshot = Self.parseSnapshot(
            payload: payload,
            mode: mode,
            userAgentProfileTitle: userAgentProfile.title,
            fallbackDurationMs: max(1, elapsedMs)
        )
        currentSnapshot = snapshot
        return snapshot
    }

    // MARK: - Bundled Resource & Air-Gapped Probe HTML

    nonisolated private static func loadBundledFPJSSource() -> String? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "fp.min", withExtension: "js"),
            Bundle.main.url(forResource: "fp.min", withExtension: "js", subdirectory: "FingerprintLab"),
            Bundle.main.url(forResource: "fp.min", withExtension: "js", subdirectory: "Resources/FingerprintLab")
        ]
        for url in candidates.compactMap({ $0 }) {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    nonisolated private static func buildOfflineAuditHTML(fpjsSource: String) -> String {
        let safeScript = fpjsSource.replacingOccurrences(of: "</script>", with: "<\\/script>")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; worker-src blob:; connect-src 'none'; img-src data:; media-src 'none';">
        <style>
        html, body { margin: 0; padding: 0; font: -apple-system-body; }
        #dt-probe { font: -apple-system-body; position: absolute; visibility: hidden; }
        </style>
        <script>
        \(safeScript)
        </script>
        </head>
        <body>
        <span id="dt-probe">Dysprosium</span>
        <script>
        (async function() {
            const post = function(obj) {
                try {
                    window.webkit.messageHandlers.dysprosiumFingerprintAudit.postMessage(obj);
                } catch (_) {}
            };

            try {
                const t0 = performance.now();
                if (typeof FingerprintJS === 'undefined' || typeof FingerprintJS.load !== 'function') {
                    post({ error: 'FingerprintJS global unavailable in offline context.' });
                    return;
                }

                // Strictly offline: monitoring:false disables any remote telemetry beacon.
                const fp = await FingerprintJS.load({ monitoring: false });
                const result = await fp.get();

                // Additional Safari/iOS & CreepJS-style integrity probes
                const dtEl = document.getElementById('dt-probe');
                const dtFontPx = dtEl ? parseFloat(getComputedStyle(dtEl).fontSize || '0') : 0;

                const isNativeFn = function(fn) {
                    try {
                        if (typeof fn !== 'function') return false;
                        const s = Function.prototype.toString.call(fn);
                        return s.indexOf('[native code]') !== -1;
                    } catch (_) { return false; }
                };

                const navLangDesc = Object.getOwnPropertyDescriptor(Navigator.prototype, 'languages');
                const navUADesc = Object.getOwnPropertyDescriptor(Navigator.prototype, 'userAgent');
                const screenWDesc = Object.getOwnPropertyDescriptor(Screen.prototype, 'width');
                const canvasNative = isNativeFn(HTMLCanvasElement.prototype.toDataURL)
                    && isNativeFn(CanvasRenderingContext2D.prototype.getImageData);
                const navNative = Boolean(navLangDesc && isNativeFn(navLangDesc.get))
                    && Boolean(navUADesc && isNativeFn(navUADesc.get))
                    && !Object.prototype.hasOwnProperty.call(navigator, 'languages')
                    && !Object.prototype.hasOwnProperty.call(navigator, 'userAgent');
                const screenNative = Boolean(screenWDesc && isNativeFn(screenWDesc.get))
                    && !Object.prototype.hasOwnProperty.call(screen, 'width');
                const audioCtor = window.OfflineAudioContext || window.webkitOfflineAudioContext;
                const audioNative = !audioCtor || isNativeFn(audioCtor);

                // Main-thread vs Blob Web Worker consistency check
                let workerConsistent = true;
                let workerDetail = 'Main & Worker match';
                try {
                    const workerCode = "postMessage({ ua: navigator.userAgent, langs: Array.from(navigator.languages || []), hc: navigator.hardwareConcurrency || 0 });";
                    const blob = new Blob([workerCode], { type: 'application/javascript' });
                    const blobUrl = URL.createObjectURL(blob);
                    const wData = await new Promise(function(resolve) {
                        const w = new Worker(blobUrl);
                        const timer = setTimeout(function() { try { w.terminate(); } catch (_) {} resolve(null); }, 1500);
                        w.onmessage = function(ev) { clearTimeout(timer); try { w.terminate(); } catch (_) {} resolve(ev.data); };
                        w.onerror = function() { clearTimeout(timer); try { w.terminate(); } catch (_) {} resolve(null); };
                    });
                    URL.revokeObjectURL(blobUrl);
                    if (wData) {
                        const mainLangs = Array.from(navigator.languages || []).join(',');
                        const workerLangs = (wData.langs || []).join(',');
                        const uaOk = wData.ua === navigator.userAgent;
                        const langOk = workerLangs === mainLangs;
                        const hcOk = wData.hc === (navigator.hardwareConcurrency || 0);
                        workerConsistent = uaOk && langOk && hcOk;
                        workerDetail = workerConsistent
                            ? 'UA, languages & cores match Web Worker'
                            : ('Mismatch: ' + [!uaOk ? 'UA' : '', !langOk ? 'languages' : '', !hcOk ? 'cores' : ''].filter(Boolean).join(', '));
                    } else {
                        workerDetail = 'Worker probe unavailable in sandbox';
                    }
                } catch (_) {
                    workerDetail = 'Worker blocked by policy';
                }

                // Hard-mode Check 6: Repeat-draw Canvas determinism (catches naive random noise extensions)
                let drawDeterministicCanvas = function(doc) {
                    const c = doc.createElement('canvas');
                    c.width = 160;
                    c.height = 48;
                    const ctx = c.getContext('2d');
                    ctx.fillStyle = '#0d47a1';
                    ctx.fillRect(0, 0, 160, 48);
                    ctx.font = '18px -apple-system, sans-serif';
                    ctx.fillStyle = '#ffffff';
                    ctx.fillText('Dy-66-Probe', 10, 30);
                    return c.toDataURL();
                };
                let canvasDeterministic = false;
                try {
                    const d1 = drawDeterministicCanvas(document);
                    const d2 = drawDeterministicCanvas(document);
                    canvasDeterministic = Boolean(d1 && d1.length > 64 && d1 === d2);
                } catch (_) {
                    canvasDeterministic = false;
                }

                // Hard-mode Check 7: Clean about:blank iframe realm parity (Fingerprint Pro's signature tampering test)
                let iframeParity = false;
                let iframeParityDetail = 'Child realm unavailable';
                try {
                    const frame = document.createElement('iframe');
                    frame.style.display = 'none';
                    document.body.appendChild(frame);
                    const cw = frame.contentWindow;
                    const cd = frame.contentDocument;
                    const mainDraw = drawDeterministicCanvas(document);
                    const frameNative = Boolean(cw && isNativeFn(cw.HTMLCanvasElement.prototype.toDataURL));
                    const frameDraw = cd ? drawDeterministicCanvas(cd) : '';
                    iframeParity = frameNative && mainDraw.length > 64 && frameDraw === mainDraw;
                    iframeParityDetail = iframeParity
                        ? 'about:blank iframe matches main realm bit-for-bit'
                        : (!frameNative ? 'Child iframe prototype exposed non-native wrapper' : 'about:blank iframe returned mismatched canvas bytes');
                    frame.remove();
                } catch (_) {
                    iframeParity = false;
                    iframeParityDetail = 'Iframe realm probe threw exception';
                }

                // Hard-mode Check 8: Non-constructible native descriptor & Function.prototype.toString closure check
                let descriptorStealth = false;
                try {
                    const toDataURLFn = HTMLCanvasElement.prototype.toDataURL;
                    const getChFn = AudioBuffer.prototype.getChannelData;
                    const noProto = (toDataURLFn.prototype === undefined) && (getChFn.prototype === undefined);
                    const tsSelfNative = isNativeFn(Function.prototype.toString);
                    let throwsOnNew = false;
                    try { new toDataURLFn(); } catch (e) { throwsOnNew = (e instanceof TypeError); }
                    descriptorStealth = noProto && tsSelfNative && throwsOnNew;
                } catch (_) {
                    descriptorStealth = false;
                }

                // Serialize FingerprintJS components safely for Swift JSON bridging
                const serializedComponents = {};
                const compKeys = Object.keys(result.components || {});
                for (let i = 0; i < compKeys.length; i++) {
                    const k = compKeys[i];
                    const c = result.components[k];
                    serializedComponents[k] = {
                        duration: typeof c.duration === 'number' ? Math.round(c.duration) : 0,
                        value: c.value !== undefined ? c.value : null,
                        error: c.error ? String(c.error.message || c.error) : null
                    };
                }

                const intlOpts = (typeof Intl !== 'undefined' && Intl.DateTimeFormat)
                    ? Intl.DateTimeFormat().resolvedOptions()
                    : {};

                post({
                    visitorId: String(result.visitorId || ''),
                    version: String(result.version || '4.x'),
                    confidence: (result.confidence && typeof result.confidence.score === 'number') ? result.confidence.score : 0,
                    durationMs: Math.round(performance.now() - t0),
                    viewport: { width: window.innerWidth, height: window.innerHeight },
                    screen: { width: screen.width, height: screen.height, dpr: window.devicePixelRatio || 1 },
                    dynamicTypePx: isFinite(dtFontPx) && dtFontPx > 0 ? Math.round(dtFontPx * 10) / 10 : null,
                    intl: {
                        locale: String(intlOpts.locale || ''),
                        timeZone: String(intlOpts.timeZone || ''),
                        calendar: String(intlOpts.calendar || '')
                    },
                    userAgent: String(navigator.userAgent || ''),
                    lieChecks: [
                        { id: 'canvas-native', title: 'Canvas API Integrity', passed: canvasNative, detail: canvasNative ? 'toDataURL & getImageData report [native code]' : 'Canvas APIs appear monkey-patched' },
                        { id: 'canvas-determinism', title: 'Canvas Repeat-Draw Determinism', passed: canvasDeterministic, detail: canvasDeterministic ? 'Repeated draws return bit-identical PNGs' : 'Non-deterministic random noise detected' },
                        { id: 'iframe-realm-parity', title: 'Clean-Iframe Realm Parity', passed: iframeParity, detail: iframeParityDetail },
                        { id: 'descriptor-stealth', title: 'Native Descriptor & Non-Constructible', passed: descriptorStealth, detail: descriptorStealth ? 'prototype === undefined, toString cloaked, new() throws TypeError' : 'Wrapper leaked constructible prototype or toString mismatch' },
                        { id: 'navigator-native', title: 'Navigator Prototype Integrity', passed: navNative, detail: navNative ? 'languages & userAgent getters unmodified' : 'Own-property override or non-native getter detected' },
                        { id: 'screen-native', title: 'Screen Prototype Integrity', passed: screenNative, detail: screenNative ? 'Screen.prototype.width reports native getter' : 'Screen dimensions appear spoofed in JS' },
                        { id: 'audio-native', title: 'WebAudio Integrity', passed: audioNative, detail: audioNative ? 'OfflineAudioContext native constructor' : 'Audio constructor patched' },
                        { id: 'worker-parity', title: 'Main ↔ Web Worker Parity', passed: workerConsistent, detail: workerDetail }
                    ],
                    components: serializedComponents
                });
            } catch (err) {
                post({ error: String((err && err.message) || err || 'Unknown audit error') });
            }
        })();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Snapshot Parsing & Entropy Risk Classification

    nonisolated private static func parseSnapshot(
        payload: [String: Any],
        mode: FingerprintAuditMode,
        userAgentProfileTitle: String,
        fallbackDurationMs: Int
    ) -> FingerprintAuditSnapshot {
        let visitorId = (payload["visitorId"] as? String) ?? ""
        let version = (payload["version"] as? String) ?? "4.6"
        let confidence = (payload["confidence"] as? Double) ?? 0
        let durationMs = (payload["durationMs"] as? Int) ?? fallbackDurationMs

        let vpDict = payload["viewport"] as? [String: Any]
        let vpWidth = (vpDict?["width"] as? Double) ?? Double((vpDict?["width"] as? Int) ?? 0)
        let vpHeight = (vpDict?["height"] as? Double) ?? Double((vpDict?["height"] as? Int) ?? 0)

        let scrDict = payload["screen"] as? [String: Any]
        let scrWidth = (scrDict?["width"] as? Double) ?? Double((scrDict?["width"] as? Int) ?? 0)
        let scrHeight = (scrDict?["height"] as? Double) ?? Double((scrDict?["height"] as? Int) ?? 0)
        let dpr = (scrDict?["dpr"] as? Double) ?? 1.0
        let dynamicTypePx = payload["dynamicTypePx"] as? Double

        let rawLies = payload["lieChecks"] as? [[String: Any]] ?? []
        let lieChecks: [FingerprintLieCheck] = rawLies.compactMap { row in
            guard let id = row["id"] as? String,
                  let title = row["title"] as? String,
                  let passed = row["passed"] as? Bool else {
                return nil
            }
            return FingerprintLieCheck(
                id: id,
                title: title,
                passed: passed,
                detail: (row["detail"] as? String) ?? ""
            )
        }

        let components = payload["components"] as? [String: [String: Any]] ?? [:]
        var items: [FingerprintSignalItem] = []

        // Synthetic Safari/Duo-specific signals first
        let vpSummary = "\(Int(vpWidth)) × \(Int(vpHeight)) pt @\(String(format: "%.0f", dpr))x"
        let isRareViewport = !(
            (Int(vpWidth) == 393 && Int(vpHeight) == 852) ||
            (Int(vpWidth) == 390 && Int(vpHeight) == 844) ||
            (Int(vpWidth) == 430 && Int(vpHeight) == 932) ||
            (Int(vpWidth) == 402 && Int(vpHeight) == 874) ||
            (Int(vpWidth) == 440 && Int(vpHeight) == 956)
        )
        items.append(
            FingerprintSignalItem(
                id: "viewportLive",
                title: "Live Viewport",
                category: .displayGraphics,
                summary: vpSummary,
                rawDetail: "innerWidth: \(Int(vpWidth)), innerHeight: \(Int(vpHeight)), devicePixelRatio: \(dpr), screen: \(Int(scrWidth))×\(Int(scrHeight))",
                entropyRisk: isRareViewport ? .high : .low,
                riskReason: isRareViewport ? "Non-standard slab iPhone viewport (high distinction on foldables / split view)." : nil
            )
        )

        if let dynamicTypePx {
            let isNonDefaultDT = abs(dynamicTypePx - 17.0) > 0.5
            items.append(
                FingerprintSignalItem(
                    id: "dynamicType",
                    title: "Dynamic Type (-apple-system-body)",
                    category: .localePreferences,
                    summary: String(format: "%.1f px", dynamicTypePx),
                    rawDetail: "Computed -apple-system-body font-size: \(dynamicTypePx) px (iOS default Large = 17.0 px)",
                    entropyRisk: isNonDefaultDT ? .high : .low,
                    riskReason: isNonDefaultDT ? "Custom iOS text size setting exposes a narrow user cohort." : nil
                )
            )
        }

        // Convert every FingerprintJS v4 component into a clean editorial item
        for key in components.keys.sorted() {
            guard let entry = components[key] else { continue }
            let dur = entry["duration"] as? Int
            let val = entry["value"]
            let err = entry["error"] as? String
            let item = classifyComponent(key: key, value: val, error: err, durationMs: dur)
            items.append(item)
        }

        items.sort { lhs, rhs in
            if lhs.entropyRisk != rhs.entropyRisk { return lhs.entropyRisk < rhs.entropyRisk }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let prettyJSON: String
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: jsonData, encoding: .utf8) {
            prettyJSON = str
        } else {
            prettyJSON = "{}"
        }

        return FingerprintAuditSnapshot(
            id: UUID(),
            timestamp: Date(),
            mode: mode,
            userAgentProfileTitle: userAgentProfileTitle,
            visitorId: visitorId,
            fpjsVersion: version,
            confidenceScore: confidence,
            totalDurationMs: durationMs,
            viewportSize: CGSize(width: vpWidth, height: vpHeight),
            screenSize: CGSize(width: scrWidth, height: scrHeight),
            devicePixelRatio: dpr,
            dynamicTypePx: dynamicTypePx,
            signals: items,
            lieChecks: lieChecks,
            rawJSONReport: prettyJSON
        )
    }

    nonisolated private static func classifyComponent(
        key: String,
        value: Any?,
        error: String?,
        durationMs: Int?
    ) -> FingerprintSignalItem {
        let title = humanTitle(for: key)
        let category = categoryForComponent(key)
        let rawDetail = error.map { "Error: \($0)" } ?? stringifyDetail(value)
        let summary = error.map { "Unavailable (\($0))" } ?? summarizeValue(key: key, value: value)

        var risk: FingerprintEntropyRisk = .low
        var reason: String?

        switch key {
        case "languages":
            let flat = flattenStringArray(value)
            if flat.count >= 2 {
                risk = .high
                reason = "Ordered multi-language preference (\(flat.joined(separator: ", "))) narrows anonymity set sharply."
            } else {
                risk = .medium
            }
        case "domBlockers":
            let blocked = flattenStringArray(value)
            if !blocked.isEmpty {
                risk = .high
                reason = "Detected filter-list signature (\(blocked.count) matched lists) acts as a distinct blocker fingerprint."
            } else {
                risk = .low
            }
        case "screenResolution", "screenFrame":
            risk = .high
            reason = "Hardware display geometry distinguishes niche form factors (such as unfolded dual-display postures)."
        case "canvas", "audio", "webGlBasics", "webGlExtensions", "fontPreferences", "fonts":
            risk = .medium
            reason = "Rendering & GPU/audio pipeline signature varies by Apple Silicon generation and system settings."
        case "timezone", "dateTimeLocale":
            risk = .medium
            reason = "Combines with language order & IP geography for probabilistic matching."
        default:
            risk = .low
        }

        return FingerprintSignalItem(
            id: key,
            title: title,
            category: category,
            summary: summary,
            rawDetail: rawDetail,
            entropyRisk: risk,
            riskReason: reason,
            durationMs: durationMs
        )
    }

    nonisolated private static func categoryForComponent(_ key: String) -> FingerprintSignalCategory {
        switch key {
        case "canvas", "webGlBasics", "webGlExtensions", "screenResolution", "screenFrame",
             "colorDepth", "colorGamut", "hdr", "invertedColors", "forcedColors", "monochrome":
            return .displayGraphics
        case "languages", "timezone", "dateTimeLocale", "fonts", "fontPreferences",
             "contrast", "reducedMotion", "reducedTransparency":
            return .localePreferences
        case "audio", "audioBaseLatency", "hardwareConcurrency", "deviceMemory", "platform",
             "vendor", "vendorFlavors", "architecture", "cpuClass", "osCpu", "touchSupport",
             "math", "applePay", "privateClickMeasurement":
            return .audioHardware
        default:
            return .shieldCapabilities
        }
    }

    nonisolated private static func humanTitle(for key: String) -> String {
        switch key {
        case "domBlockers": return "Content Blocker Signature"
        case "webGlBasics": return "WebGL Renderer & Vendor"
        case "webGlExtensions": return "WebGL Extensions"
        case "fontPreferences": return "System Font Metrics"
        case "screenResolution": return "Physical Screen Resolution"
        case "screenFrame": return "Safe Screen Frame"
        case "hardwareConcurrency": return "CPU Logical Cores"
        case "audioBaseLatency": return "Audio Base Latency"
        case "colorGamut": return "Color Gamut"
        case "colorDepth": return "Color Depth"
        case "reducedMotion": return "Reduced Motion"
        case "reducedTransparency": return "Reduced Transparency"
        case "touchSupport": return "Touch Capabilities"
        case "localStorage": return "Local Storage"
        case "sessionStorage": return "Session Storage"
        case "indexedDB": return "IndexedDB"
        case "cookiesEnabled": return "Cookies Enabled"
        case "hdr": return "HDR Display"
        case "applePay": return "Apple Pay"
        case "pdfViewerEnabled": return "PDF Viewer"
        case "dateTimeLocale": return "Intl DateTime Locale"
        case "privateClickMeasurement": return "Private Click Measurement"
        default:
            // Convert camelCase -> Title Case
            var out = ""
            for ch in key {
                if ch.isUppercase && !out.isEmpty { out.append(" ") }
                out.append(out.isEmpty ? ch.uppercased() : String(ch))
            }
            return out
        }
    }

    nonisolated private static func summarizeValue(key: String, value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "—" }
        if key == "canvas", let dict = value as? [String: Any] {
            let winding = (dict["winding"] as? Bool) == true ? "winding" : "no-winding"
            let geoLen = (dict["geometry"] as? String)?.count ?? 0
            let txtLen = (dict["text"] as? String)?.count ?? 0
            return "\(winding) · geo \(geoLen)B · txt \(txtLen)B"
        }
        if key == "webGlBasics", let dict = value as? [String: Any] {
            let renderer = (dict["rendererUnmasked"] as? String) ?? (dict["renderer"] as? String) ?? "WebGL"
            return renderer
        }
        if key == "webGlExtensions", let dict = value as? [String: Any] {
            let extCount = (dict["extensions"] as? [Any])?.count ?? 0
            let paramCount = (dict["parameters"] as? [Any])?.count ?? 0
            return "\(extCount) extensions · \(paramCount) params"
        }
        if key == "domBlockers" {
            let list = flattenStringArray(value)
            if list.isEmpty { return "None detected" }
            let preview = list.prefix(3).joined(separator: ", ")
            return list.count > 3 ? "\(preview) +\(list.count - 3)" : preview
        }
        if key == "languages" {
            let list = flattenStringArray(value)
            return list.isEmpty ? "—" : list.joined(separator: " → ")
        }
        if key == "screenResolution", let arr = value as? [Any], arr.count == 2 {
            return "\(arr[0]) × \(arr[1])"
        }
        if key == "fontPreferences", let dict = value as? [String: Any] {
            if let defVal = dict["default"] as? Double {
                return String(format: "default %.2f px (%d styles)", defVal, dict.count)
            }
            return "\(dict.count) font metrics"
        }
        if let b = value as? Bool { return b ? "Yes" : "No" }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "Yes" : "No"
            }
            let d = n.doubleValue
            if d.rounded() == d { return String(Int64(d)) }
            return String(format: "%.6g", d)
        }
        if let s = value as? String {
            return s.count > 64 ? String(s.prefix(64)) + "…" : (s.isEmpty ? "Empty" : s)
        }
        if let arr = value as? [Any] {
            if arr.isEmpty { return "None (0)" }
            let flat = arr.prefix(4).map { String(describing: $0) }.joined(separator: ", ")
            return arr.count > 4 ? "\(flat) +\(arr.count - 4)" : flat
        }
        if let dict = value as? [String: Any] {
            return "\(dict.count) fields"
        }
        return String(describing: value)
    }

    nonisolated private static func flattenStringArray(_ value: Any?) -> [String] {
        guard let arr = value as? [Any] else { return [] }
        var out: [String] = []
        for el in arr {
            if let s = el as? String, !s.isEmpty {
                out.append(s)
            } else if let nested = el as? [String] {
                out.append(contentsOf: nested.filter { !$0.isEmpty })
            }
        }
        return out
    }

    nonisolated private static func stringifyDetail(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str.count > 2_000 ? String(str.prefix(2_000)) + "\n… [truncated]" : str
        }
        return String(describing: value)
    }
}

// MARK: - Private WebKit Bridge Helpers

@MainActor
private final class AuditMessageReceiver: NSObject, WKScriptMessageHandler {
    private var payloadData: Data?
    private var continuation: CheckedContinuation<Data?, Never>?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let dict = message.body as? [String: Any] ?? ["error": "Malformed audit message payload."]
        let encoded = (try? JSONSerialization.data(withJSONObject: dict))
            ?? Data("{\"error\":\"Failed to encode audit payload.\"}".utf8)
        payloadData = encoded
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: encoded)
        }
    }

    func waitForPayloadData(timeoutSeconds: Double) async -> Data? {
        if let existing = payloadData {
            return existing
        }
        return await withCheckedContinuation { cont in
            self.continuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard let self, let pending = self.continuation else { return }
                self.continuation = nil
                pending.resume(returning: nil)
            }
        }
    }
}

/// Strictly blocks any external network navigation inside the offline Fingerprint Lab WebView.
@MainActor
private final class AirGappedNavigationGuard: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.host() == "audit.dysprosium.local" || url.scheme == "about" || url.scheme == "blob" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
}
