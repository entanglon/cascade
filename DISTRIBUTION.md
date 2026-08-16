# xCloud — Distribution Notes (v1.1.1)

## What's ready

- **`xCloud-1.1.1.dmg`** — the installer, built from the Release configuration, signed
  (hardened runtime; **not sandboxed** — a deliberate choice, see below), with a custom
  background, volume icon, icon layout, and an `Applications` shortcut. Drag the app to
  Applications.
  v1.1.1 fixes the fresh-install deadlock: the API-credentials login form now appears
  immediately when no credentials are stored (previously the app sat on a loading
  splash forever). Logging in after install: first run → optional onboarding → "Connect
  Telegram" API form → phone/code/password → your cloud.
- Rebuild it anytime: `bash scripts/make_dmg.sh 1.1.1`
  (requires a Release build: `xcodebuild -project xCloud.xcodeproj -scheme xCloud -configuration Release -derivedDataPath build build`)

## Release vs. dev separation (by design)

The released app must never share state with the testing build, so they're fully isolated:

| | Dev build (Xcode) | Released app (DMG) |
|---|---|---|
| Bundle ID | `com.nemesys.xcloud.xCloud` | `com.nemesys.xcloud.xCloud.prod` |
| Sandbox | Unsandboxed (plain paths) | **Not sandboxed** — plain paths |
| Data | `~/Library/Application Support/xCloud/` | `~/Library/Application Support/xCloud-Prod/` |
| Keychain | `com.nemesys.xcloud.xCloud` | `com.nemesys.xcloud.xCloud.prod` |

- The Keychain service is derived from the bundle ID, so the two builds can never see each
  other's Telegram session, vault PIN, or master key. Logging into your personal account in
  the released app has zero effect on the dev app (and vice versa).
- Data folders are scoped per build via `App/AppPaths.swift` (`"xCloud"` vs
  `"xCloud-Prod"`): separate database, TDLib state, downloads, and URL handoff files.
- Both can be installed and run side by side.
- The released app is **unsandboxed on purpose**: it's a full-fledged desktop app (your call),
  which also means it is **not Mac App Store eligible** — App Store requires sandboxing.
  Direct distribution (DMG) is the right path for this app anyway.
- Consequence of the split: the production app starts "fresh" (new folders + keychain
  space) — enter the test account credentials once on first launch. Old dev data and old
  keychain items remain on disk; delete them when you no longer need them.

## Opening share links

Both builds claim the `xcloud://` scheme; the browser opens whichever app registered it
**last**. The deterministic way to import a link into the production app is the
**File → Import Shared Link… (⌘⇧I)** command. If you want the browser click to open the
production app, launch it once after installing (which registers it) and avoid launching
the dev app until the test is done.

## Honest status: this build runs on your Mac — not (yet) on strangers' Macs

The app is signed with the **Apple Development** identity (`Apple Development: haditbutt7@gmail.com`).
That's the correct identity for developing and testing on your own machine, but **Gatekeeper on
other Macs will refuse it** (you can verify: `spctl --assess --type execute xCloud.app` → `rejected`).

For a DMG that anyone can download and open without "can't be opened because Apple cannot check
it for malicious software", you need two things from a **paid** Apple Developer account:

1. **Developer ID Application certificate** (Xcode → Settings → Accounts → Manage Certificates
   → "+" → Developer ID Application). This is the certificate that tells macOS "this is a real
   developer, not malware".
2. **Notarization** — Apple scans the app before it ships. One-time setup:

```bash
# Once (store the credential; use an app-specific password from appleid.apple.com)
xcrun notarytool store-credentials "xCloud-Notary" \
  --apple-id "your-apple-id@example.com" \
  --team-id "A6388Z7T5U" \
  --password "app-specific-password"
```

Then build the DMG **while the Developer ID certificate is selected** in
Signing & Capabilities (or `CODE_SIGN_IDENTITY="Developer ID Application"` on the xcodebuild
command), and run:

```bash
bash scripts/notarize.sh xCloud-1.1.1.dmg
```

`notarize.sh` submits to Apple, waits for approval, staples the ticket to the DMG, and validates.
After that, the DMG opens cleanly on any modern Mac — first-time users just right-click → Open,
or the system trusts it outright after first launch.

## Other things to know before a public release

- **API credentials**: each user enters their own `api_id`/`api_hash` (my.telegram.org) on first
  launch — they're stored in the user's Keychain. This is deliberate: a shared hardcoded hash
  would let Telegram ban the whole app if one user abuses it. Keep it this way.
- **Deployment target** is `macOS 26.5` — fine for now, but consider lowering it later to reach
  more machines.
- **App Store**: the released app is unsandboxed by design, so it is **not** App-Store
  eligible. If you ever want the App Store, that would be a separate sandboxed build.
  (App Review would also ask hard questions about storing user files on Telegram —
  direct-download distribution is the pragmatic path for this app.)
- **Versioning**: bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in the project before
  each release; the DMG name carries the version.
