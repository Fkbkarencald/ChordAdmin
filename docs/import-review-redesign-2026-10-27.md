# ChordAdmin import review integrated with the September workspace

Date: 27 October 2026 (Australia/Melbourne)
Agent: Commander Axiom (`commander-axiom`)
Quest Console task: `e8b88b61-67bf-46a0-a9ba-697c3119173d`
Work session: `ffdeff94-6562-4d2e-99bf-71c6f2c08049`
Branch: `codex/import-review-redesign`, based on main `311e5d1`.

## Scope and behavior

Frankie confirmed both existing-song analysis and reviewed new-song imports, with only the owner using the app initially. The September library/workspace/inspector, tuning preview, section editing, and existing-song export flow remain the foundation. The old staging branch was selectively reapplied rather than merged over the redesign.

- **Song Imports** is available in the toolbar and with Cmd+N. A YouTube source, title, artist and optional key create a durable `songImportStaging` record before analysis starts. Duplicate candidates stop automatic processing and publication; metadata can be corrected, duplicates rechecked, or the import rejected without deleting its history.
- Draft songs appear in the normal library with a separate `staging-<recordID>` local identity. They use the same chart workspace and serial `JobManager` as existing songs. The toolbar identifies them as unpublished imports.
- Processing records download, conversion, analysis, cleanup, translation and publication state. Failed steps have readable errors and redacted actor/timestamp history. Cleanup verifies durable local outputs; it does not delete the chart or source audio.
- Analyse/resume and retry execute work. Retrying failed chords reuses successful beats/grid and audio when their files remain available. Translation-only retries call translation without repeating model analysis. Fresh re-analysis invalidates the old publication payload and processing evidence. Paused/interrupted jobs can be resumed using their persisted local folder.
- Opening a draft's publication preview translates the latest edited chart, validates nested sections/lines/bars/chords and tempo, and shows the canonical destination plus reviewed metadata. Metadata changes, new chart revisions and section edits invalidate an earlier preview.
- Approval reads the current staging record and destination in one Firestore transaction. It refuses an existing destination for a new import, blocks duplicate candidates and incomplete work, and atomically creates the song and records approval. Repeated approval of that record returns its existing song ID. The older existing-song staging records can update sections/tempo without replacing canonical metadata.
- Successful publication rebinds the local analysis and export history to the new canonical library row. This is persisted and verified across hydration; an existing local job is never overwritten by that move.
- Review mutations require the signed-in account's `users/<uid>.isAdmin`. No additional reviewer account setup was introduced. Signing out clears import state and is blocked during active import work/publication.
- YouTube URL variants resolve to stable source identities. Video-ID case is preserved, lookalike hosts are rejected, and stored canonical URLs exclude unrelated/access-bearing parameters.

## Validation

- `./Tools/verify.sh check`: the complete app typechecks cleanly, without warnings.
- `./Tools/verify.sh test`: **366/366 checks passed**. The existing 324 checks remain, plus 42 import checks covering duplicate and permission denial, terminal rejection, idempotent domain approval, chart validation, stale previews, HTTP chord failure, actual retry execution, translation failure/retry, retained audio/analysis, direct-export refusal, and persistent canonical reassociation. Import tests use the real JobManager, a local HTTP backend and an in-memory review-store adapter; they do not contact production Firebase or fetch media.
- Normal Xcode Debug build with the real Firebase SDK and configured development signing passed; no deployment-target override was required. The only build warning was the standard AppIntents metadata notice because this app does not use AppIntents.
- The render harness rendered the existing views and added import-review/publication states in light and dark. The 0.85x and 1.4x text-scale sweeps completed; the new failure card and publication sheet were visually inspected.
- `git diff --check`: passed.

## Remaining release work

This is a local application integration, not a production release. The paired staging-rules change still exists separately in TheStageBee's `codex/chordadmin-import-staging-rules` (`fc2b3ec`). Its staging envelope matches the fields/payload format used here, but it must be reconciled with current TheStageBee rules and emulator-tested before a separately approved production deployment.

Production Firebase sign-in, browsing, transaction behavior and canonical publication have not been live-tested in this session. The local backend was not started, no source media was downloaded, no production songs or rules were changed, and the app was not installed or released. A live acceptance run needs the rules release, running backend and a selected test source/destination.

The complete persisted/reorderable batch queue from the older branch remains a separate follow-up; this change reuses the September engine's queue rather than introducing a second engine or landing the old batch UI.
