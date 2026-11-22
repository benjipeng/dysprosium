# Dysprosium Architecture

**Dysprosium (`Dy`, Z = 66)** is a high-concurrency file and adaptive media stream downloader engineered specifically for **LiveContainer** on **iOS 27.2 SDK** with native **iPhone Duo** posture adaptation and **Liquid Glass** optical materiality.

---

## 1. Core Architectural Thesis: Decoupling Control Plane from Data Plane

Single-threaded Python downloaders execute `yt-dlp` end-to-end inside a single CPython thread—forcing extractor resolution, single-socket HTTP reads, HLS segment loops, and `Popen`-monkey-patched FFmpeg muxing through one serialized Global Interpreter Lock (GIL) context with `--no-continue`.

Dysprosium splits execution into three isolated planes inside LiveContainer's single host process:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ PLANE 1 · CONTROL PLANE (1× Dedicated 8 MB NSThread · Short-Lived Hold)     │
│ • Direct URL / HLS Fast-Path Probe (Swift native HEAD / Range 0-0 / .m3u8) │
│ • Embedded CPython + yt-dlp (extract_info(..., download=False) only)        │
│ • Embedded QuickJS-NG + curl-cffi TLS Impersonation                         │
│   ──► Emits immutable ResolvedTransferPlan in ~0.8–2.0s, frees Python GIL   │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ PLANE 2 · DATA PLANE (Swift Structured Concurrency · M Tasks × N Lanes)     │
│ • Engine A: RangeTransferEngine (Direct files, Progressive MP4, DASH tracks)│
│   - Single open() + fcntl(F_PREALLOCATE) + ftruncate()                      │
│   - Lock-free concurrent Darwin.pwrite() across N parallel byte lanes       │
│   - Dynamic Midpoint Work-Stealing (idle lanes split largest >4 MB straggler│
│   - Bounded ~9.5 MB sub-range windows to defeat CDN per-socket throttling   │
│ • Engine B: HLSStreamEngine (.m3u8 Master/Media playlists)                  │
│   - Bounded concurrent segment TaskGroup + in-memory CommonCrypto AES-128   │
│ • SQLite3 WAL Journal with 0xdead10cc suspension protection                 │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ PLANE 3 · POST-PROCESSING PLANE (1× Serialized Swift Actor)                 │
│ • FFmpegMuxActor: isolates non-reentrant FFmpeg C globals                   │
│ • Lossless stream copy (-c copy) audio+video remux at 400–800 MB/s NVMe I/O │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. LiveContainer Host Runtime Contract

Dysprosium targets **LiveContainer** exclusively, eliminating App Store privacy manifests, `ShareExtension` targets, `BGContinuedProcessingTask` (rejected by `runningboardd` because guest identifiers are absent from `LiveContainer.app/Info.plist`), and IPA self-patching bloat.

Five runtime invariants govern all native and C-ABI code:

1. **Explicit Guest Mach-O Symbol Lookup**: LiveContainer converts the guest executable from `MH_EXECUTE` to `MH_DYLIB` and loads it via `dlopen`. Passing `NULL` / `RTLD_DEFAULT` inspects the host executable first. All C-ABI bridges (`EmbeddedPythonBridge`, `FFmpegMuxActor`, QuickJS) resolve symbols against `Bundle.main.executablePath` (which LiveContainer rewrites via `overwriteMainNSBundle`).
2. **Demand-Driven Silent Audio Keep-Alive**: LiveContainer's host `Info.plist` declares `UIBackgroundModes = [audio]`. `SilentAudioKeepAlive` runs an `AVAudioEngine` looping zeroed PCM frames with `.playback` + `.mixWithOthers` **strictly while `backgrounded && activeTaskCount > 0`**, tearing down immediately on `willEnterForeground` or queue completion for zero idle drain.
3. **In-Process Persistence Over `nsurlsessiond`**: Because switching guest apps inside a single LiveContainer instance evicts the prior guest, Dysprosium relies on high-frequency SQLite WAL byte-offset journaling rather than background `URLSession` daemons. Interrupted transfers resume from exact byte cursors on next launch; expired CDN URLs (`HTTP 403`) re-invoke Plane 1 to refresh signed URLs while preserving downloaded byte ranges.
4. **Foundation-First Sandbox Paths**: LiveContainer virtualizes guest directories by swizzling `NSFileManager` and `NSHomeDirectory()` under `LC_HOME_PATH`. Every POSIX call (`open`, `pwrite`, `sqlite3_open_v2`) receives an absolute path resolved through `FileManager.default`.
5. **`0xdead10cc` Suspension Guard**: Every SQLite database and `-wal`/`-shm` sidecar receives `setxattr(path, "com.apple.runningboard.can-suspend-locked", &one, 1, 0, 0)` on creation so audio interruptions never trigger `runningboardd` file-lock termination.

---

## 3. Native iOS 27.2 SDK, iPhone Duo Adaptation & Lanthanide Design Tokens

Linked directly against `iphoneos27.2` (`LC_BUILD_VERSION` SDK `27.2`), Dysprosium unlocks full edge-to-edge rendering across both the `5.4"` outer display (`466 × 678 pt`) and `7.6"` inner display (`669 × 951 pt` portrait / `951 × 669 pt` landscape):

- **Immersive WebKit Viewport & Vertical Bar Harmony**: Primary navigation uses root-level `TabView` and `NavigationStack` containers (`.primaryAction` + `.secondaryAction` `•••` overflow menu) paired with `UITraitCollection.verticalBarEdge` (`DuoVerticalBarPlacement`). `CleanroomBrowserWorkspaceView` hosts a single-plane persistent Liquid Glass top chrome (`GeometryReader` + `.ignoresSafeArea(.container, edges: .top)`, resolved via `BrowserTopChromeLayout.resolve(...)`): in Inner Portrait (`669×951`), the `36 pt` omnibox and trailing capsule inhabit the `82 pt` top band alongside the corner clock/Wi-Fi ring (`occlusion(525, 0, 144×82)`); in Vertical-Bar postures (`Outer` & `Inner Landscape`), controls relocate into the `84 pt` hardware rail while the floating omnibox hovers over a full-bleed `pageCanvasColor`-matched `WKWebView` surface. While reading, passive `WKWebView.scrollView.contentOffset` and `panGestureRecognizer` tracking continuously interpolates the single persistent capsule (`36 pt` omnibox ↔ `24 pt` top-edge centered domain pill) 1:1 with the scroll gesture with zero view teardown and zero top blur scrim.
- **Lanthanide Design Tokens (`DesignTokens.swift`)**: Five user-selectable periodic palettes (`Dysprosium Cerulean · 66 Dy`, `Cobalt Ultramarine · 27 Co`, `Terbium Emerald · 65 Tb`, `Europium Vermilion · 63 Eu`, `Titanium Obsidian · 22 Ti`) calibrate Light/Dark `UIColor` traits (`WCAG AA >= 4.8:1`), `.symbolRenderingMode(.monochrome)` `onAccent` fills, and `glassIconPrimary` monochrome ink on Liquid Glass bars without view-level `@Environment(\.colorScheme)` branches.
- **Single-Hierarchy Keylines & Hinge Avoidance (`ReservedRegion`)**: Lists strictly use a single `.listStyle(.insetGrouped)` margin hierarchy (never stacking `.contentMargins(.horizontal, ...)` on `.insetGrouped`) so titles, search pills, section headers, and cards share one vertical keyline. Root containers inspect `GeometryProxy.reservedRegions(kind: .division, options: [.includeInactive])` and `.occlusion`, with zero usage of banned `UIScreen.main`, `UIDevice.current.orientation`, or `userInterfaceIdiom` APIs.
