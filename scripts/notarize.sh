#!/bin/bash
# notarize.sh — notarizes and staples a Cascade DMG for public distribution.
# Usage: ./scripts/notarize.sh <path-to.dmg>
#
# Prereqs (see DISTRIBUTION.md):
#   1. Paid Apple Developer account + Developer ID Application certificate
#      selected when building the DMG (or CODE_SIGN_IDENTITY="Developer ID Application").
#   2. One-time setup:
#        xcrun notarytool store-credentials "Cascade-Notary" \
#          --apple-id "you@example.com" --team-id "A6388Z7T5U" --password "app-specific-password"
set -euo pipefail

DMG="${1:?usage: notarize.sh <path-to.dmg>}"

PROFILE="Cascade-Notary"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    if xcrun notarytool history --keychain-profile "xCloud-Notary" >/dev/null 2>&1; then
        PROFILE="xCloud-Notary"
    fi
fi

echo "==> Submitting $DMG to Apple for notarization using profile '$PROFILE'"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$DMG"

echo "==> Validating"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "✅ $DMG is notarized and ready to distribute"
