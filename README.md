<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="DesignAssets/AppIconFinal/AppIcon-Dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="DesignAssets/AppIconFinal/AppIcon-Light.svg">
    <img src="DesignAssets/AppIconFinal/AppIcon-Dark.svg" width="112" height="112" alt="Dysprosium App Icon">
  </picture>
</p>

<h1 align="center">Dysprosium (Dy)</h1>

<p align="center">
  <strong>A LiveContainer-native iOS 27.2 cleanroom WebKit browser, live Media Radar, native PDF reader, and parallel range downloader engineered for iPhone Duo and Liquid Glass.</strong>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-34C759.svg" alt="MIT License"></a>
  <a href="../../actions/workflows/ci.yml"><img src="https://github.com/benjipeng/dysprosium/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/benjipeng/dysprosium?color=0A84FF" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/Platform-iOS%2027.2%20SDK-0A84FF.svg" alt="iOS 27.2 SDK">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138.svg" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/Runtime-LiveContainer-5E5CE6.svg" alt="LiveContainer">
</p>

---

## Highlights

- **Cleanroom WebKit Browser**: Multi-tab browsing with Private tabs, SQLite FTS5 history & bookmarks, native `WKContentRuleList` ad/tracker blocking (v10 chunked compiler with ABP/uBO subscriptions & scriptlets), 0-frame Fingerprint Shield, and Dark Reader CSSOM/HSL theming (OLED `#000000`, Obsidian, Graphite, Warm Paper).
- **Immersive iPhone Duo & Liquid Glass Chrome**: Built natively against iOS 27.2 SDK for Outer Portrait (`466×678`), Inner Portrait (`669×951`), Inner Landscape (`951×669`), and Book Pose (`40 pt` `.division` hinge). Scroll-linked floating top capsule uplifts fixed site navbars flush to `0 pt`, auto-hides the corner status cluster on scroll down, and coordinates with `TabView.tabBarMinimizeBehavior(.onScrollDown)`.
- **Live Media Radar & Parallel Transfer Engine**: Domain-agnostic playback/MIME stream sniffer with `SystemProxyBridge` parity, RFC 6265 cookie scoping, cross-origin redirect credential stripping, multi-lane HTTP `Range` downloading (`fcntl(F_PREALLOCATE)` + `pwrite`), native HLS (`.m3u8` / AES-128 / fMP4 / MPEG-TS) remuxing, and in-app Quick Look / `AVPlayerViewController` preview.
- **Native In-Tab `PDFKit` Reader**: Renders PDFs directly inside browser tabs without forcing a download—complete with iPhone Duo Two-Up Book Spread across the center crease, single-pass hue-preserving Dark & Paper modes, outline/page navigator, search, encrypted PDF unlock, and one-tap Save Original to Downloads.
- **Multi-Instance Custom Save Folder**: Choose a shared user-visible folder in iOS Files via Security-Scoped Folder Bookmarks (per-host LiveContainer bookmark isolation + `NSFileCoordinator` atomic commits + one-shot migration) so multiple LiveContainer instances share one consistent Downloads directory.

---

## Installation (LiveContainer)

Official Release IPAs are built reproducibly on GitHub Actions (`xcode-27`, iOS `27.2` SDK) and published directly to [Releases](../../releases) for import into [LiveContainer](https://github.com/LiveContainer/LiveContainer):

1. Download the latest `Dysprosium-v*_b*.ipa` from the [Releases](../../releases) page.
2. Open **LiveContainer**, tap **+**, and import the `.ipa` (LiveContainer handles `MH_EXECUTE` → `MH_DYLIB` patching and ad-hoc signing automatically).
3. *(Optional, for multi-instance setups)* Open **Downloads › Choose Save Folder…** or **Engine & Host › Storage & Sandbox › Save Location** to pick a shared folder in Files (e.g., `On My iPhone › Downloads`). When launching from a second LiveContainer host (`LiveContainer2`), tap **Grant Access…** once to authorize that same folder.

---

## Building from Source

### Requirements

- macOS with **Xcode 27.2** (iOS `27.2` SDK)
- Swift `6.0`

### Build Unsigned LiveContainer Release IPA

```bash
./scripts/build_livecontainer_ipa.sh
```

The script automatically clears `SDKROOT`, archives `Release` for `generic/platform=iOS`, verifies `vtool -show-build` reports `platform IOS` and `sdk >= 27.2`, and outputs:

- `build/Dysprosium-v<marketing>_b<build>.ipa`
- `build/Dysprosium-LiveContainer.ipa`

### Run Test Suite (Simulator)

```bash
unset SDKROOT
xcodebuild test \
  -project Dysprosium.xcodeproj \
  -scheme Dysprosium \
  -destination 'platform=iOS Simulator,name=iPhone Duo' \
  -derivedDataPath DerivedData
```

*(Optional)* Run `./scripts/bootstrap_frameworks.sh` to fetch QuickJS-NG and view instructions for optional external `XCFramework` drop-ins (`Python.xcframework`, `SwiftFFmpeg-iOS`, `SwiftCurlCffi-iOS`). Dysprosium compiles and runs its native Swift Range, HLS, and MP4 remux engines out of the box without them.

---

## Architecture & Roadmap

- Full Control / Data / Post-Processing architecture, LiveContainer sandbox invariants, and SQLite WAL `0xdead10cc` hardening are documented in [`ARCHITECTURE.md`](ARCHITECTURE.md).
- **Planned**: Native non-DRM MPEG-DASH (`.mpd`) manifest parser & paired video/audio fMP4 downloader (currently detected and explicitly labeled `DASH · Unsupported` in Media Radar).

---

## License

Dysprosium is released under the [MIT License](LICENSE). See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for bundled third-party components and licenses.
