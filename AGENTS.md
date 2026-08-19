# AGENTS.md — Working instructions for coding agents on xCloud

> Read this file FIRST, before any other file in the repo. It exists so that no
> work is ever lost (the 2026-08-16 freebuff incident: a diverged worktree lost
> a full session's edits) and so every session leaves the repo in a state the
> next agent can pick up cold.

## 1. Non-negotiable session rules

1. **Update docs after every task, not at the end of the day.** If you complete
   any user-visible work (feature, fix, investigation with conclusions), update
   `JOURNAL.md` (chronological log) AND `HANDOVER.md` (current state) in the
   SAME session as the code. Never commit code without the docs for it.
2. **Commit after every complete task.** One task = one commit (plus a follow-up
   `docs:` hash-correction commit when a doc mentions a commit hash that
   changed — see conventions below). Do not batch multiple tasks into one
   commit, and do not leave the working tree dirty at the end of a session.
3. **Never lose work to "cleanup".** Never run `git clean`, `git reset --hard`,
   or `git checkout` on a dirty tree without the user's explicit OK. Back up
   before destructive ops (`cp -R` or commit first). The `.freebuff/` tree
   contains worktree clones — never delete it (see gotchas).
4. **Debug builds only by default.** Do NOT build or install a Release build
   unless the user explicitly approves it (user policy since 2026-08-17). The
   Release app in `/Applications/xCloud.app` is intentionally an older build.
5. **Do not touch the stash/branch `batch2-mystery-changes-2026-08-17`**
   (merge `bc88d74`, NOT an ancestor of HEAD). Do not restore or cherry-pick
   it.
6. **Answer questions first.** If the user asks "what would happen if…", answer
   from the code before changing anything. Prefer `rg`/`grep` over guesses;
   state code paths with `file:line`.
7. **Ask before big structural moves.** Anything that renames files, restructures
   folders, or changes DB schema beyond an additive migration: propose first.
8. **External model help (Qwen / Claude via the user).** The user keeps separate
   chats with Qwen and Claude as consultants. Whenever I'm stuck — a bug that
   resists root-causing, an Apple API behavior that contradicts docs/harness
   evidence, a design choice with several options — STOP guessing and ask the
   user to forward a help prompt. The prompt must be SELF-CONTAINED (repo
   context, exact `file:line`, a short code excerpt, what was tried + results,
   the specific question) so the consultant can answer without the repo. The
   user pastes the reply back; verify the suggestion against the code before
   implementing. Do not burn hours on a problem the user's consultants could
   answer in minutes.

## 2. Build / test / run

```sh
# Kill a running app before rebuilding or replacing it
pkill -9 -f "xCloud.app/Contents/MacOS/xCloud"

# Build (always Debug unless approved)
xcodebuild -configuration Debug \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/xCloud-cdpcjcegyfsbheeztqhmjnnukgcv \
  -scheme xCloud -destination 'platform=macOS' build

# Full test suite (unit + UI + launch). Runs against the REAL Debug DB
# (~/Library/Application Support/xCloud/xCloud.sqlite), which holds real
# active shares — pool/count tests are baseline-relative by design.
xcodebuild -configuration Debug \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/xCloud-cdpcjcegyfsbheeztqhmjnnukgcv \
  -scheme xCloud -destination 'platform=macOS' test

# Run the Debug app
open ~/Library/Developer/Xcode/DerivedData/xCloud-cdpcjcegyfsbheeztqhmjnnukgcv/Build/Products/Debug/xCloud.app
```

- Report the test tally (e.g. "67: 59 unit + 4 UI + 4 launch", `** TEST
  SUCCEEDED **`) whenever you run the suite.
- After launch, verify live DB effects with sqlite3 (Debug DB path above;
  Release: `~/Library/Application Support/xCloud-Prod/xCloud.sqlite`).

## 3. Commit conventions

- Branch: always `main`. Do not create feature branches; do not rebase/amend
  pushed history.
- Message style: imperative, one line, prefixed with the round/task context.
  Recent examples:
  - `Round 6: Share menu (Private/Public), channel naming, duplicate-object heal, rename field fixes`
  - `Fix volume slider for Bluetooth output devices (probe volume element); Shared page: Public/Private headers, Space opens share`
  - `docs: correct commit hash` — used as a tiny follow-up when a doc's stated
    hash changed (e.g. a commit got amended); the repo deliberately keeps these
    as separate commits.
- Stage with `git add -A` after verifying `git status` shows only intended
  files. Never commit secrets (Telegram API keys live in user defaults /
  Keychain, not the repo; `.gitignore` covers local state).
- If a commit is rejected by hooks or fails, fix and make a NEW commit — never
  `--amend` a failed one.
- After committing, update the doc "Last entry" headers if the docs changed.

## 4. Documentation conventions

Three living docs + this file:

- **`JOURNAL.md`** — chronological log. New work = new dated section at the
  TOP of the body (after the header blockquote), format:
  `## YYYY-MM-DD (morning|afternoon|evening) — short title`. Include: what the
  user asked, what was found (root causes with file:line), what was changed,
  test/build results, commit hash. Also update the header blockquote's
  "Last entry:" line.
- **`HANDOVER.md`** — current-state reference for a cold reader. Numbered
  `N. **Title** (date — status)` entries at the end of the history section,
  mirroring each journal round in condensed form (root cause, fix, verification,
  commit hash, policy notes). Keep the `## Pending / next steps` section
  current — move done items out, add new ones.
- **`ROADMAP.md`** — deferred plans; only touch when a planned item is
  implemented or cancelled.
- **`AGENTS.md`** (this file) — agent workflow rules; extend it when a new
  lesson would have saved work or time.
- Other docs: `PROJECT_SUMMARY.md` (orientation), `OPENCODE_HANDOVER.md`,
  `DISTRIBUTION.md` (build/ship specifics). Update only when they become
  wrong.

If a doc references a commit hash for work you're about to commit, write the
doc AFTER the commit and use the real hash, or accept that you'll need a
`docs: correct commit hash` follow-up (that is normal in this repo).

## 5. Project gotchas (learned the hard way)

- **`Features/` is an EXPLICIT pbxproj group**, not a synchronized folder: any
  NEW Swift file must be added to `xCloud.xcodeproj/project.pbxproj` manually
  (Xcode would do it via the navigator; from the CLI, edit the pbxproj or open
  Xcode once). Editing existing files needs no pbxproj change.
- **Worktrees diverge silently.** `.freebuff/worktrees/<id>/` are throwaway
  clones; `xcodebuild` runs from MAIN (`~/Projects/xCloud`) only. After a
  session, verify `git log --oneline -5` on main and `git status` are clean.
- **`import` is a Swift keyword** — the direction enum case is `inbound`
  (not `import`).
- **Type-checker limit**: `FileBrowserView.mainContent` hit the compiler's
  complexity limit → parts were extracted into `destinationContent` /
  `FileGridItem` / `FileListRow` / `FileItemContextMenu`. When adding to these
  views, keep new chunks small or extract further.
- **Tests run against the REAL Debug DB** (which has real active private
  shares). Tests that count pool slots are baseline-relative;
  `ShareEngine.underXCTest` blocks real Telegram calls in tests.
- **Post-auth heal block** (`App/AppState.swift` ~line 700): chunk-level and
  object-level dedupe run at every launch after auth and republish a corrected
  checkpoint if anything was removed. If you add a dedupe/repair, wire it
  there and keep it idempotent (healthy catalog → 0).
- **DB schemas**: Debug `~/Library/Application Support/xCloud/xCloud.sqlite`;
  Release `…/xCloud-Prod/xCloud.sqlite` (prod session user 946154826, backup
  `xCloud-Prod.bak-2026-08-17`). Schema migrations live in
  `Storage/DatabaseManager.swift`; models in `Storage/Models.swift`.
- **Naming/identity**: object uniqueness by content = rootHash; the
  `uniqueName` helper is used for share imports only. Moves do NOT dedupe
  names (two files with the same name can coexist in one folder — that is
  current intended behavior; see HANDOVER round 6).
- **Key components**: `App/AppState.swift` (state + actions), `Engine/`
  (ShareEngine, TransferCenter, AudioPlayerEngine incl. SystemVolumeManager,
  ThumbnailService incl. BookCoverFetcher, VideoStreamingEngine),
  `Storage/` (DatabaseManager, VaultRepair, CatalogSnapshot),
  `Features/` (FileBrowserView, ShareManagerView, TransfersView, MPVVideoView
  — HDR/EDR pipeline + Dolby passthrough live here), `Telegram/TelegramClient.swift`.

## 6. Session end checklist

1. `git status --short` — clean (except files you're explicitly leaving).
2. `git log --oneline -5` — the day's commits present, on main.
3. JOURNAL.md + HANDOVER.md updated for every task done; "Last entry" headers
   current.
4. Tests green (or a documented, user-approved reason they aren't).
5. Debug app relaunched if the build changed. No Release build without approval.