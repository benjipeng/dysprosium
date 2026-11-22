#!/bin/zsh
set -euo pipefail

# Builds an unsigned Release IPA linked against the latest iOS 27.1+ SDK for
# direct import into LiveContainer (which handles guest ad-hoc signing / JIT).

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# ~/.zshrc exports SDKROOT pointing to MacOSX.sdk, which breaks iOS builds.
unset SDKROOT

PROJECT="Dysprosium.xcodeproj"
SCHEME="Dysprosium"
BUILD_DIR="$ROOT_DIR/build"

SDK=$(xcodebuild -showsdks | awk '/iphoneos/ {print $NF}' | sort -V | tail -n 1)
if [ -z "$SDK" ]; then
  echo "Error: No iphoneos SDK found." >&2
  exit 1
fi

echo "==> Building Dysprosium against SDK: $SDK (LiveContainer unsigned target)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

ARCHIVE_ARGS=(
  archive
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -archivePath "$BUILD_DIR/Dysprosium.xcarchive"
  -destination "generic/platform=iOS"
  -sdk "$SDK"
  CODE_SIGN_IDENTITY=""
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO
  AD_HOC_CODE_SIGNING_ALLOWED=NO
)
if [ -n "${DERIVED_DATA_PATH:-}" ]; then
  ARCHIVE_ARGS+=(-derivedDataPath "$DERIVED_DATA_PATH")
fi

xcodebuild "${ARCHIVE_ARGS[@]}"

APP_PATH="$BUILD_DIR/Dysprosium.xcarchive/Products/Applications/Dysprosium.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: Missing Dysprosium.app at $APP_PATH" >&2
  exit 1
fi

echo "==> Verifying Mach-O LC_BUILD_VERSION SDK >= 27.2..."
VTOOL_OUT="$(vtool -show-build "$APP_PATH/Dysprosium")"
echo "$VTOOL_OUT" | grep -E "platform|sdk" || true
if ! echo "$VTOOL_OUT" | grep -q "platform IOS"; then
  echo "Error: Binary is not built for platform IOS." >&2
  exit 1
fi
BUILT_SDK="$(echo "$VTOOL_OUT" | awk '/^[[:space:]]*sdk / {print $2; exit}')"
if [ -z "$BUILT_SDK" ] || [ "$(printf '%s\n27.2\n' "$BUILT_SDK" | sort -V | head -n 1)" != "27.2" ]; then
  echo "Error: Binary SDK ($BUILT_SDK) is below required 27.2." >&2
  exit 1
fi
echo "OK: Verified platform=IOS and sdk=$BUILT_SDK"

MARKETING_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Info.plist" 2>/dev/null || echo "0.1.0")
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Info.plist" 2>/dev/null || echo "1")
VERSIONED_IPA="Dysprosium-v${MARKETING_VER}_b${BUILD_NUM}.ipa"

mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP_PATH" "$BUILD_DIR/Payload/"
(
  cd "$BUILD_DIR"
  zip -qr "$VERSIONED_IPA" Payload
  cp "$VERSIONED_IPA" "Dysprosium-LiveContainer.ipa"
)
rm -rf "$BUILD_DIR/Payload"

echo "==> Created LiveContainer IPA: $BUILD_DIR/$VERSIONED_IPA (alias: Dysprosium-LiveContainer.ipa)"
