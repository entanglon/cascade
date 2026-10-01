# Contributing to Cascade

Thank you for your interest in contributing to **Cascade**! We welcome bug reports, feature suggestions, documentation enhancements, and pull requests from the developer community.

---

## Getting Started

### 1. Prerequisites
- **macOS 15.0+**
- **Xcode 16.0+** with Command Line Tools installed (`xcode-select --install`)
- Active git setup

### 2. Clone and Setup
1. Clone the repository locally:
   ```bash
   git clone https://github.com/entanglon/cascade.git
   cd cascade
   ```
   *(If you are contributing via a fork, fork the repo on GitHub and add your fork as a remote: `git remote add fork <your-fork-url>`)*
2. Verify you can build the scheme cleanly from your terminal:
   ```bash
   xcodebuild -project Cascade.xcodeproj -scheme Cascade -destination 'platform=macOS' build
   ```
3. Run the unit test suite:
   ```bash
   xcodebuild test -project Cascade.xcodeproj -scheme Cascade -destination 'platform=macOS' -only-testing:CascadeTests
   ```

---

## Development & Architecture Rules

Before submitting changes, please ensure your code respects Cascade's core architectural tenets:

1. **Native Media Pipeline**:
   - **`libmpv` is the sole media engine**. Do **not** re-introduce `AVFoundation` or `AVKit` (`AVPlayer`, `AVAsset`, etc.) for playback, duration calculation, or thumbnails.
2. **Chunking Standard**:
   - All file partitioning follows uniform **~1.9 GiB chunking** (`ChunkPlanner.maxSafeChunkSize`). Do not alter document boundaries or reintroduce fragmented per-profile chunk sizing.
3. **Storage & Vault Architecture**:
   - Vault files are stored in plaintext in the user's private cloud channel. Access gating and segregation are enforced locally via the PIN/biometric Private Vault.
4. **Swift Concurrency**:
   - All code is compiled with Swift 6 strict concurrency checks enabled. Avoid unchecked shared mutable state and respect `@MainActor` boundaries.

---

## Submitting Pull Requests

1. **Create a Feature Branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. **Commit Changes**:
   Write clear, descriptive commit messages:
   ```bash
   git commit -m "feat(player): add keyboard shortcut for audio track selection"
   ```
3. **Verify Tests**:
   Ensure all existing tests pass and add unit tests for any new business logic in `CascadeTests/`.
4. **Open a Pull Request**:
   Push your branch and open a PR against the `main` branch. Provide a clear summary of your changes, the rationale, and any visual UI recordings where applicable.

---

## Contributor License Agreement & Grant

To ensure that Cascade can be safely distributed to users worldwide across all platforms without conflicting licensing claims, all contributors agree to the following terms upon submitting a Pull Request:

1. **Original Work**: You certify that your contribution is entirely your own original creation or that you have the legal right to submit it under the project's license.
2. **License Grant**: You license your contribution under the **GNU General Public License v3.0 (GPLv3)** as set forth in the [LICENSE](LICENSE) file.
3. **Distribution Grant**: You grant **Entanglon** a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to incorporate, compile, distribute, and publish your contribution as part of official Cascade releases across all platforms, package repositories, and distribution channels.

---

## Trademark & Brand Guidelines

- **Code vs. Brand**: The open-source license applies to Cascade's code. It does **not** grant rights to Entanglon's trademarks, project names, or official brand assets.
- **Forks & Distributions**: If you distribute a modified or independent version of this software, you **must remove or replace** all official Cascade logos, app icons, and references to "Cascade" or "Entanglon" with your own distinct product name and brand identity.

---

## Security & Responsible Disclosure

If you discover a security vulnerability or sensitive bug:
- **Do not open a public issue.**
- Please send details privately to: **contact@entanglon.com** or reach out directly to the core maintainers.
- We will acknowledge receipt within 48 hours and work with you on a timely resolution prior to public disclosure.
