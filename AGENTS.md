# Dysprosium repository instructions

Dysprosium (`Dy`) is a LiveContainer-native high-concurrency downloader and WebKit media browser targeting iOS 27.2 and iPhone Duo (`iPhone19,4`). Control, Data, and Post-Processing execution planes live in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## WebKit and Dark Mode

- Keep `WKWebView.isOpaque = true` so WebKit composites directly over the matched page canvas without alpha blending penalties.
- Never apply whole-page CSS `filter: invert()`. Use Dark Reader CSSOM/HSL dynamic theming with lazy on-demand runtime injection, per-site `dynamic-theme-fixes.config` rules (never forcing blanket `ignoreImageAnalysis: ["*"]`, which breaks CSS gradients), same-origin cache-backed fetch, SSRF-hardened cross-origin `text/css` fetch bridge, and zero-canvas computed-style refinement for CSS-var gradients, dark monochrome SVG logos, and header icon bars.

## iPhone Duo Browser Top Chrome Invariant

- Keep `.ignoresSafeArea(.container, edges: .top)` on `CleanroomBrowserWorkspaceView`'s root `GeometryReader` and resolve all top-chrome coordinates exclusively via `BrowserTopChromeLayout.resolve(...)`. Removing `.ignoresSafeArea(.container, edges: .top)` drops the Inner Portrait (`669×951`) omnibox and trailing controls below the `82 pt` top safe-area band.
- Drive `WKWebView` insets explicitly via `contentInsetAdjustmentBehavior = .never`, `scrollView.contentInset`, `WKWebView.obscuredContentInsets`, and `setMinimumViewportInset(_:maximumViewportInset:)` (bypassing `NavigationStack`'s phantom `24 pt` top safe area) with inset-invariant raw `contentOffsetY` deltas in `BrowserChromeScrollState` so fixed/sticky site headers uplift cleanly to `0 pt` on scroll-down without oscillation. Never overwrite `WKWebView.scrollView.delegate` (use passive KVO on `contentOffset`).
- Mount `NativeWebKitHost` and `NativePDFHost` mutually exclusively as direct edge-to-edge children (`Z = 0`, `.ignoresSafeArea(edges: [.top, .bottom])`) so `TabView.tabBarMinimizeBehavior(.onScrollDown)` always binds unambiguously to the active scroll view.
- Any change to browser chrome or posture geometry must be verified across all three postures (Outer Portrait `466×678`, Inner Landscape `951×669`, Inner Portrait `669×951`) on `iphone_duo_27_2` Simulator.

## Thermal, Concurrency, and Main-Thread Hygiene

- Never run synchronous SQLite queries or `FileManager` scans inside SwiftUI `body` or on `@MainActor` at cold launch.
- Harden SQLite WAL against `0xdead10cc` suspension crashes: run `sqlite3_wal_checkpoint_v2(..., SQLITE_CHECKPOINT_TRUNCATE)` on rare high-value writes and `willResignActive`/`didEnterBackground`, and re-apply `com.apple.runningboard.can-suspend-locked` after the first WAL write creates `-wal`/`-shm`.
- Throttle multi-lane transport progress emissions globally (`>= 200 ms`) and keep root-level `@Observable` counters decoupled from byte-progress ticks.
- Gate LiveContainer silent-audio keep-alive strictly on **both** background state and active work (`backgrounded && activeTaskCount > 0`), tearing it down immediately on `willEnterForeground` or queue idle.
- Suspend background tab media (`setAllMediaPlaybackSuspended(true)`) and use lazy tab hydration so inactive tabs do not burn CPU or wake decoders.
- Verify settled process CPU and RSS (`ps`) on `Release` builds alongside Simulator UI verification.

## References

- Project overview and installation: [`README.md`](README.md)
- Architecture and runtime contracts: [`ARCHITECTURE.md`](ARCHITECTURE.md)
- Unsigned LiveContainer Release IPA builder: [`scripts/build_livecontainer_ipa.sh`](scripts/build_livecontainer_ipa.sh)
