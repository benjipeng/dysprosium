#!/usr/bin/env bash
set -euo pipefail

# Formats structured release notes and idempotently publishes or updates a
# GitHub Release containing the unsigned LiveContainer IPA and SHA-256 digest.
# Pass --dry-run to print the rendered Markdown notes without calling `gh`.

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
fi

: "${RELEASE_TAG:?Missing RELEASE_TAG}"
: "${VERSION:?Missing VERSION}"
: "${BUILD_NUM:?Missing BUILD_NUM}"
: "${IPA_PATH:?Missing IPA_PATH}"
: "${SHA_PATH:?Missing SHA_PATH}"
: "${IPA_NAME:?Missing IPA_NAME}"
: "${IPA_SHA256:?Missing IPA_SHA256}"
: "${IPA_SIZE:?Missing IPA_SIZE}"
: "${SDK_VERSION:?Missing SDK_VERSION}"
: "${XCODE_VERSION:?Missing XCODE_VERSION}"
: "${XCODE_BUILD:?Missing XCODE_BUILD}"
: "${SOURCE_SHA:?Missing SOURCE_SHA}"
: "${RUN_URL:?Missing RUN_URL}"
: "${RUN_NUMBER:?Missing RUN_NUMBER}"

EXTRA_NOTES="${EXTRA_NOTES:-}"
PRERELEASE="${PRERELEASE:-false}"

notes_file="$(mktemp "${TMPDIR:-/tmp}/dysprosium-release-notes.XXXXXX.md")"
trap 'rm -f "$notes_file"' EXIT

{
  if [ -n "$EXTRA_NOTES" ]; then
    printf '%s\n\n' "$EXTRA_NOTES"
  fi
  cat <<EOF
## Dysprosium v${VERSION} (build ${BUILD_NUM})

Unsigned \`arm64\` Release IPA built reproducibly on GitHub Actions (\`xcode-27\`) against **iOS ${SDK_VERSION} SDK** for [LiveContainer](https://github.com/LiveContainer/LiveContainer).

| Field | Value |
| --- | --- |
| **Artifact** | \`${IPA_NAME}\` (${IPA_SIZE}) |
| **SHA-256** | \`${IPA_SHA256}\` |
| **iOS SDK** | \`iphoneos${SDK_VERSION}\` (\`arm64\`) |
| **Toolchain** | Xcode \`${XCODE_VERSION}\` (\`${XCODE_BUILD}\`) |
| **Source Commit** | \`${SOURCE_SHA:0:7}\` |
| **Build Run** | [#${RUN_NUMBER}](${RUN_URL}) |

### Installation
1. Download \`${IPA_NAME}\` below.
2. Open **LiveContainer**, tap **+**, and import the \`.ipa\`.
EOF
} > "$notes_file"

if [ "$DRY_RUN" = true ]; then
  cat "$notes_file"
  exit 0
fi

if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  gh release edit "$RELEASE_TAG" \
    --title "Dysprosium v${VERSION} (build ${BUILD_NUM})" \
    --notes-file "$notes_file"
  gh release upload "$RELEASE_TAG" "$IPA_PATH" "$SHA_PATH" --clobber
else
  extra_flags=()
  if [ "$PRERELEASE" = "true" ]; then
    extra_flags+=(--prerelease)
  fi
  gh release create "$RELEASE_TAG" \
    "$IPA_PATH" "$SHA_PATH" \
    --target "$SOURCE_SHA" \
    --title "Dysprosium v${VERSION} (build ${BUILD_NUM})" \
    --notes-file "$notes_file" \
    --generate-notes \
    ${extra_flags[@]+"${extra_flags[@]}"}
fi

echo "Published GitHub Release: ${RELEASE_TAG}"
