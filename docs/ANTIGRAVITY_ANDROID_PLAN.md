# ANTIGRAVITY COMMAND & EXECUTION PLAN — Cascade Android Port

> **File:** `docs/ANTIGRAVITY_ANDROID_PLAN.md`  
> **Target:** Build the full-featured native Android version of **Cascade** (`CascadeAndroid`) using Kotlin, Jetpack Compose, TDLib, Room, Ktor, and libmpv.  
> **Reference Codebase:** `/Users/zainulnazir/projects/Cascade` (Swift iOS/macOS)

---

## Ready-to-Copy Prompt for Antigravity

Copy and paste the exact block below into **Antigravity** to start the autonomous creation of the Cascade Android application:

```text
You are assigned to build the official native Android app for "Cascade" (formerly xCloud), a client-side encrypted cloud storage app that uses a Telegram account via TDLib as unlimited vault storage.

### Core Reference & Specification
Read the existing Swift implementation at `/Users/zainulnazir/projects/Cascade` for exact business logic, database schemas, and algorithms:
- App Overview & Architecture: `/Users/zainulnazir/projects/Cascade/PROJECT_SUMMARY.md`
- Shared Data & Database Schema: `/Users/zainulnazir/projects/Cascade/Storage/Models.swift` and `DatabaseManager.swift`
- Telegram Client & Auth: `/Users/zainulnazir/projects/Cascade/Telegram/TelegramClient.swift`
- Encryption & Key Management: `/Users/zainulnazir/projects/Cascade/Crypto/CryptoEngine.swift` and `KeychainStore.swift`
- Chunking & Transfers: `/Users/zainulnazir/projects/Cascade/Engine/UploadEngine.swift`, `DownloadEngine.swift`, `ChunkPlanner.swift`
- Local Byte Streaming: `/Users/zainulnazir/projects/Cascade/Engine/VaultStreamServer.swift`
- UI Patterns & Design: `/Users/zainulnazir/projects/Cascade/Cascade iOS/RootView.swift` and `Features/`

### Target Android Architecture & Technology Stack
1. Language & UI: Kotlin + Jetpack Compose (Material 3) + Jetpack Navigation / Compose Navigation
2. Async & Reactive: Kotlin Coroutines + StateFlow / SharedFlow
3. Database: Android Room (SQLite) matching GRDB tables (`objects`, `chunks`, `vaults`, `notes`, `transfers`)
4. Telegram API: TDLib Android JNI (`org.drinkless.tdlib`)
5. Encryption: Java AES-GCM 256-bit + Android KeyStore for master key encryption
6. Local Streaming: Local Embedded Ktor HTTP Byte-Range Server (`127.0.0.1`) for streaming uncached files directly to media player
7. Media Engine: libmpv for Android (NDK/JNI SurfaceView wrapper) for universal video/audio playback
8. Background Work: Android WorkManager + Foreground Service for transfers
9. Security & Links: BiometricPrompt (Private Vault) + Intent Filter for `cascade://` deep links

### Tasks to Complete
1. Initialize the Android Gradle project `CascadeAndroid` at `/Users/zainulnazir/projects/Cascade/CascadeAndroid`.
2. Implement Core Data Layer: Room database, entities, DAOs, and AES-GCM Encryption Engine using Android KeyStore.
3. Implement TDLib Client & Auth Flow: Telegram phone number/OTP authentication, channel management, message sending/receiving.
4. Implement Transfer & Streaming Engines:
   - Chunk Planner (128 MB standard, 256 MB archive, 64 MB media).
   - Chunked Upload/Download engines with pause/resume, progress reporting, and FLOOD_WAIT handling.
   - Embedded Ktor HTTP Server for byte-range loopback streaming (`127.0.0.1`).
5. Implement libmpv Integration & Player:
   - SurfaceView Compose wrapper for video playback.
   - Background Audio Service with MediaSession controls.
6. Build Jetpack Compose UI:
   - Files / Drive view (Grid & List modes, Multi-selection, Context menus, Folders, Breadcrumbs).
   - Category Views (Photos, Videos, Audio, Documents).
   - Encrypted Notes (Google Keep pastel card layout + Markdown editor).
   - Private Vault (PIN / Biometric protected).
   - Transfer HUD & Center (Upload/Download progress cards with pause/resume).
   - Shared Links (`cascade://` scheme & link importer sheet).
   - Settings (Storage analytics, cache size limits, clear cache, lock now).

Begin execution step-by-step and keep the codebase clean, modular, and fully functional.
```

---

## Detailed Step-by-Step Task Breakdown for Agent Tracking

### Task 1: Project Initialization & Dependency Setup
- Create directory `/Users/zainulnazir/projects/Cascade/CascadeAndroid`.
- Configure `build.gradle.kts` (Project & App) with:
  - Compose BOM & Material 3
  - Room DB & KSP compiler
  - Kotlin Coroutines & Serialization
  - Ktor Server Core & Netty/CIO
  - TDLib JNI dependencies
  - AndroidX WorkManager, Biometric, DataStore

### Task 2: Data Models & Room Database
- Create Room Entities in `com.cascade.app.data.local`:
  - `ObjectEntity` (`objects` table)
  - `ChunkEntity` (`chunks` table)
  - `VaultEntity` (`vaults` table)
  - `NoteEntity` (`notes` table)
  - `TransferEntity` (`transfers` table)
- Write Type Converters & Migrations.
- Implement `AppDatabase` and DAOs.

### Task 3: Crypto Engine & Security
- Implement `CryptoEngine.kt`:
  - Key derivation and AES-256-GCM chunk encryption/decryption.
  - Integration with `AndroidKeyStore` for storing vault keys securely.
- Implement `BiometricHelper.kt` using `BiometricPrompt`.

### Task 4: TDLib Integration & Auth Service
- Add TDLib JNI native libraries (`libtdjson.so`).
- Build `TelegramClient.kt` wrapper handling:
  - State machine (WaitingForPhoneNumber, WaitingForCode, Ready).
  - Encrypted channel creation/finding.
  - File chunk uploads and downloads with progress callbacks.

### Task 5: Transfer Engines & Local Stream Server
- Port `UploadEngine.kt` and `DownloadEngine.kt`:
  - Automatic chunking (128 MB, 256 MB, 64 MB).
  - In-flight cancellation, instant pause, and chunk-boundary resume.
- Port `VaultStreamServer.kt`:
  - Ktor embedded HTTP server on `127.0.0.1:<random_port>`.
  - Byte-range HTTP header parser (`Range: bytes=start-end`).
  - Decrypts requested chunk ranges on-the-fly and streams bytes to player.

### Task 6: libmpv & Media Playback Layer
- Integrate `libmpv` NDK bindings.
- Build `MpvPlayerView.kt` Compose `AndroidView` wrapper.
- Build `AudioPlaybackService.kt` with `MediaSession` & Notification support.

### Task 7: Jetpack Compose UI
- **Root Screen**: Bottom Navigation Bar (Recents, Shared, Drive, Notes, Settings).
- **Drive Screen**: Top Bar (Search, View Mode Toggle, Context Menu), Grid/List view with selection state, folder navigation hierarchy.
- **Transfers HUD**: Floating or dedicated transfers screen for active uploads/downloads.
- **Notes Screen**: Pastel grid, markdown preview, pin toggle, tag filters.
- **Private Vault**: Pin entry & Biometric unlock overlay.

### Task 8: Verification & Testing
- Test TDLib login and channel creation.
- Test uploading a 1 GB file, pausing midway, resuming, and completing.
- Test byte-range streaming playback of non-cached MKV / MP4 video files via `VaultStreamServer` and `libmpv`.
- Test encrypted note persistence and Private Vault lock/unlock.

---

## Log & Handover Notes
- **Created on:** 2026-08-27
- **Purpose:** Antigravity prompt & project blueprint for creating `CascadeAndroid`.
