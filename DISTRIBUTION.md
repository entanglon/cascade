# Cascade — macOS Distribution Guide (v1.2.0 Beta)

## What's Ready

- **`Cascade-1.2.0.dmg`** — The macOS installer disk image, built from the optimized Release configuration, signed with Hardened Runtime enabled, custom dark navy gradient background, volume icon, icon layout, and an `Applications` drop link. Drag the app to Applications.
- Rebuild the DMG anytime:
  ```bash
  bash scripts/make_dmg.sh 1.2.0
  ```
  This script automatically compiles the universal Release binary (`arm64` + `x86_64`) if needed and packages it with `create-dmg`.

## App Architecture & Isolation

| Attribute | Details |
|---|---|
| Product Name | `Cascade` |
| Bundle Identifier | `com.entanglon.cascade` |
| Universal Binary | `x86_64` (Intel) + `arm64` (Apple Silicon) |
| Hardened Runtime | Enabled (`ENABLE_HARDENED_RUNTIME = YES`) |
| Sandbox | Unsandboxed desktop client (native MPV engine, direct filesystem streaming) |
| URL Scheme | `cascade://` |
| Data Directory | `~/Library/Application Support/Cascade/` |
| Keychain Service | `com.entanglon.cascade` |

## Authentication & Credentials

- **Bundled Telegram API Credentials**: Cascade ships with pre-configured API credentials (`api_id` and `api_hash`), allowing seamless first-run login via phone number / QR code without requiring end-users to register at my.telegram.org.
- **Custom Credentials**: Users can still provide their own API ID and Hash in Settings or via Keychain if desired.

## Signing & Notarization for Public Release

The local build is signed with the configured development identity (`Apple Development: haditbutt7@gmail.com`). For distributing a public beta outside your own devices without Gatekeeper warnings:

1. **Developer ID Application Certificate**:
   Ensure you have a **Developer ID Application** certificate in Xcode (Xcode → Settings → Accounts → Manage Certificates → `+` → Developer ID Application).

2. **Notarization Profile** (One-time setup with Apple ID app-specific password):
   ```bash
   xcrun notarytool store-credentials "Cascade-Notary" \
     --apple-id "your-apple-id@example.com" \
     --team-id "A6388Z7T5U" \
     --password "app-specific-password"
   ```

3. **Notarize & Staple**:
   ```bash
   bash scripts/notarize.sh Cascade-1.2.0.dmg
   ```
   This submits the DMG to Apple's notarization service, waits for approval, staples the notarization ticket to the disk image, and validates Gatekeeper compliance.
