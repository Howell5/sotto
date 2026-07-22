#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="$PROJECT_ROOT/Packaging/Info.plist"
ENTITLEMENTS="$PROJECT_ROOT/Packaging/Sotto.entitlements"
ASSETS_DIR="$PROJECT_ROOT/Packaging/Assets"
OUTPUT_DIR="$PROJECT_ROOT/outputs"
APP_BUNDLE="$OUTPUT_DIR/Sotto.app"
SIGN_IDENTITY="${SOTTO_CODESIGN_IDENTITY:--}"
TIMESTAMP_MODE="${SOTTO_CODESIGN_TIMESTAMP:-auto}"

for tool in swift plutil codesign; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'error: required tool not found: %s\n' "$tool" >&2
        exit 1
    fi
done

if [[ ! -f "$INFO_PLIST" || ! -f "$ENTITLEMENTS" \
   || ! -f "$ASSETS_DIR/AppIcon.icns" \
   || ! -f "$ASSETS_DIR/SottoMenuBarTemplate.png" ]]; then
    printf 'error: packaging metadata is incomplete under %s/Packaging\n' "$PROJECT_ROOT" >&2
    exit 1
fi

plutil -lint "$INFO_PLIST" >/dev/null
plutil -lint "$ENTITLEMENTS" >/dev/null

printf 'Building Sotto in release mode…\n'
swift build \
    --package-path "$PROJECT_ROOT" \
    --configuration release \
    --product Sotto

BIN_DIR="$(swift build \
    --package-path "$PROJECT_ROOT" \
    --configuration release \
    --show-bin-path)"
BINARY="$BIN_DIR/Sotto"

if [[ ! -x "$BINARY" ]]; then
    printf 'error: release executable not found at %s\n' "$BINARY" >&2
    exit 1
fi

STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sotto-package.XXXXXX")"
STAGED_APP="$STAGING_ROOT/Sotto.app"
trap 'rm -rf -- "$STAGING_ROOT"' EXIT

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
install -m 0755 "$BINARY" "$STAGED_APP/Contents/MacOS/Sotto"
install -m 0644 "$INFO_PLIST" "$STAGED_APP/Contents/Info.plist"
install -m 0644 "$ASSETS_DIR/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
install -m 0644 \
    "$ASSETS_DIR/SottoMenuBarTemplate.png" \
    "$STAGED_APP/Contents/Resources/SottoMenuBarTemplate.png"

printf 'Signing app bundle with identity %s…\n' "$SIGN_IDENTITY"
case "$TIMESTAMP_MODE" in
    auto)
        if [[ "$SIGN_IDENTITY" == "-" ]]; then
            TIMESTAMP_ARGUMENT=(--timestamp=none)
        else
            TIMESTAMP_ARGUMENT=(--timestamp)
        fi
        ;;
    none)
        TIMESTAMP_ARGUMENT=(--timestamp=none)
        ;;
    secure)
        TIMESTAMP_ARGUMENT=(--timestamp)
        ;;
    *)
        printf 'error: SOTTO_CODESIGN_TIMESTAMP must be auto, none, or secure\n' >&2
        exit 1
        ;;
esac
codesign \
    --force \
    --options runtime \
    "${TIMESTAMP_ARGUMENT[@]}" \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$STAGED_APP"

codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null

mkdir -p "$OUTPUT_DIR"
if [[ -e "$APP_BUNDLE" ]]; then
    rm -rf -- "$APP_BUNDLE"
fi
mv "$STAGED_APP" "$APP_BUNDLE"

printf '\nPackaged: %s\n' "$APP_BUNDLE"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    printf 'Signature: ad hoc (not notarized; intended for local testing)\n'
else
    printf 'Signature: %s (not notarized by this script)\n' "$SIGN_IDENTITY"
fi
printf 'Launch with: open %q\n' "$APP_BUNDLE"
