#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IDENTITY="${SOTTO_DEVELOPMENT_CODESIGN_IDENTITY:-Sotto Local Development}"

if ! command -v security >/dev/null 2>&1; then
    printf 'error: macOS security tool was not found\n' >&2
    exit 1
fi

AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"
if [[ "$AVAILABLE_IDENTITIES" != *"\"$IDENTITY\""* ]]; then
    cat >&2 <<EOF
error: code-signing identity "$IDENTITY" was not found.

Create it once in Keychain Access:
  1. Keychain Access > Certificate Assistant > Create a Certificate
  2. Name: $IDENTITY
  3. Identity Type: Self Signed Root
  4. Certificate Type: Code Signing
  5. Enable "Let me override defaults" and accept the remaining defaults

Then verify it with:
  security find-identity -v -p codesigning
EOF
    exit 1
fi

printf 'Using stable local development identity: %s\n' "$IDENTITY"
SOTTO_CODESIGN_IDENTITY="$IDENTITY" \
SOTTO_CODESIGN_TIMESTAMP=none \
    "$SCRIPT_DIR/package-app.sh"
