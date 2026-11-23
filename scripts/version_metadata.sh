#!/usr/bin/env bash
set -euo pipefail

# Reads DYSPROSIUM_MARKETING_VERSION and DYSPROSIUM_CURRENT_PROJECT_VERSION
# from Version.xcconfig, optionally validates that a git tag matches
# v<MARKETING_VERSION> (or v<MARKETING_VERSION>-<prerelease>), and optionally
# exports `version` and `build_number` to a GitHub Actions output file.

CONFIG_FILE="Version.xcconfig"
VERIFY_TAG=""
GITHUB_OUTPUT_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file)
      CONFIG_FILE="${2:?Missing value for --file}"
      shift 2
      ;;
    --verify-tag)
      VERIFY_TAG="${2:-}"
      shift 2
      ;;
    --github-output)
      GITHUB_OUTPUT_FILE="${2:?Missing value for --github-output}"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--file Version.xcconfig] [--verify-tag vX.Y.Z] [--github-output PATH]" >&2
      exit 2
      ;;
  esac
done

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: Version config not found at '$CONFIG_FILE'" >&2
  exit 1
fi

read_xcconfig_var() {
  awk -F'=' -v k="$1" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      sub(/^[^=]*=/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      print $0
      exit
    }
  ' "$2"
}

VERSION="$(read_xcconfig_var DYSPROSIUM_MARKETING_VERSION "$CONFIG_FILE")"
BUILD_NUM="$(read_xcconfig_var DYSPROSIUM_CURRENT_PROJECT_VERSION "$CONFIG_FILE")"

if [ -z "$VERSION" ] || [ -z "$BUILD_NUM" ]; then
  echo "Error: Failed to parse version/build from '$CONFIG_FILE' (version='$VERSION', build='$BUILD_NUM')" >&2
  exit 1
fi

if [ -n "$VERIFY_TAG" ]; then
  if [ "$VERIFY_TAG" != "v${VERSION}" ] && [[ "$VERIFY_TAG" != "v${VERSION}-"* ]]; then
    echo "Error: Release tag '${VERIFY_TAG}' does not match ${CONFIG_FILE} DYSPROSIUM_MARKETING_VERSION '${VERSION}' (expected 'v${VERSION}' or 'v${VERSION}-*')." >&2
    exit 1
  fi
  echo "Verified release tag '${VERIFY_TAG}' matches ${CONFIG_FILE} (${VERSION} build ${BUILD_NUM})."
  RELEASE_TAG="$VERIFY_TAG"
else
  RELEASE_TAG="v${VERSION}"
fi

if [ -n "$GITHUB_OUTPUT_FILE" ]; then
  {
    echo "version=${VERSION}"
    echo "build_number=${BUILD_NUM}"
    echo "release_tag=${RELEASE_TAG}"
  } >> "$GITHUB_OUTPUT_FILE"
else
  echo "version=${VERSION}"
  echo "build_number=${BUILD_NUM}"
  echo "release_tag=${RELEASE_TAG}"
fi
