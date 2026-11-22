# Third-Party Notices

Dysprosium's original source code is licensed under the [MIT License](LICENSE). The repository bundles or references the following third-party components, each governed by its own license terms.

---

## Bundled in Repository

### Dark Reader

- **Files**: `Dysprosium/Resources/DarkReader/darkreader.min.js`, `dark-sites.config`, `dynamic-theme-fixes.config`
- **Upstream**: <https://github.com/darkreader/darkreader>
- **License**: MIT License (Copyright (c) Dark Reader contributors)

### FingerprintJS v4.6.2 (Local Diagnostic Harness Only)

- **Files**: `Dysprosium/Resources/FingerprintLab/fp.min.js`
- **Upstream**: <https://github.com/fingerprintjs/fingerprintjs>
- **License**: Business Source License 1.1 (`BSL-1.1`, Copyright (c) FingerprintJS, Inc., 2025 — <https://mariadb.com/bsl11/>)
- **Scope**: Bundled strictly for the local, offline in-app **Fingerprint Lab** self-audit tool (`Dysprosium/Views/Engine/FingerprintLabView.swift`) and unit tests, and is not covered by Dysprosium's MIT License.

---

## Optional Externally Bootstrapped Dependencies (`scripts/bootstrap_frameworks.sh`)

These third-party libraries are **not** committed to this repository and may optionally be fetched locally by the user:

- **QuickJS-NG** — MIT License (<https://github.com/quickjs-ng/quickjs>)
- **Python-Apple-support (`Python.xcframework`)** — Python Software Foundation License / BSD (<https://github.com/beeware/Python-Apple-support>)
- **SwiftFFmpeg-iOS** — LGPL / GPL depending on upstream FFmpeg build configuration (<https://github.com/tfourj/SwiftFFmpeg-iOS>)
- **SwiftCurlCffi-iOS** — MIT / curl license (<https://github.com/tfourj/SwiftCurlCffi-iOS>)
- **Community Filter Subscriptions** (downloaded on demand by the user at runtime, e.g., EasyList, EasyPrivacy, Peter Lowe's List, AdGuard Mobile/Annoyances) — subject to their respective upstream licenses.
