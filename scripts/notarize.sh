#!/bin/bash
# notarize.sh — notarizes and staples an xCloud DMG for public distribution.
# Usage: ./scripts/notarize.sh <path-to.dmg>
#
# Prereqs (see DISTRIBUTION.md):
#   1. Paid Apple Developer account + Developer ID Application certificate
#      selected when building the DMG (or CODE_SIGN_IDENTITY="Developer ID Application").
#   2. One-time: xcrun notarytool store-credentials "xCloud-Notary" \
#        --apple-id "you@example.com" --team-id "A6388Z7T5U" --password "app-specific-password"
set -euo pipefail

DMG="${1:?usage: notarize.sh <path-to.dmg>}"

echo "==> Submitting $DMG to Apple for notarization"
xcrun notarytool submit "$DMG" --keychain-profile "xCloud-Notary" --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$DMG"

echo "==> Validating"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "✅ $DMG is notarized and ready to distribute"
