#!/bin/zsh
set -euo pipefail

# Bootstraps optional heavy binary frameworks into Frameworks/ for full embedded
# yt-dlp + curl-cffi + QuickJS-NG + SwiftFFmpeg runtime support on iOS arm64.
# Dysprosium compiles and runs its native HTTP Range & HLS engines even before
# these frameworks are populated.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORKS_DIR="$ROOT_DIR/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

QUICKJS_VERSION="0.16.2"

echo "==> Preparing Frameworks directory at $FRAMEWORKS_DIR"

if [ ! -d "$FRAMEWORKS_DIR/QuickJS" ]; then
  echo "==> Downloading QuickJS-NG v${QUICKJS_VERSION}..."
  TMP_QJS="$(mktemp -d)"
  curl -fsSL "https://github.com/quickjs-ng/quickjs/archive/refs/tags/v${QUICKJS_VERSION}.tar.gz" -o "$TMP_QJS/qjs.tar.gz"
  tar -xzf "$TMP_QJS/qjs.tar.gz" -C "$TMP_QJS"
  mv "$TMP_QJS/quickjs-${QUICKJS_VERSION}" "$FRAMEWORKS_DIR/QuickJS"
  rm -rf "$TMP_QJS"
  echo "    Installed Frameworks/QuickJS"
else
  echo "    Frameworks/QuickJS already present"
fi

cat <<'EOF'

==> Optional Prebuilt XCFrameworks (for embedded Python yt-dlp & FFmpeg muxing):
  1. Python.xcframework:
     https://github.com/beeware/Python-Apple-support/releases/latest
     -> Extract Python.xcframework to Frameworks/Python.xcframework

  2. SwiftFFmpeg-iOS:
     https://github.com/tfourj/SwiftFFmpeg-iOS/releases/latest
     -> Extract to Frameworks/SwiftFFmpeg-iOS

  3. SwiftCurlCffi-iOS:
     https://github.com/tfourj/SwiftCurlCffi-iOS/releases/latest
     -> Extract to Frameworks/SwiftCurlCffi-iOS

Once placed in Frameworks/, Dysprosium's runtime loader (EmbeddedPythonBridge &
FFmpegMuxActor) automatically detects and activates them inside LiveContainer.
EOF
