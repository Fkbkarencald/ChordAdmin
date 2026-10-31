# Bundled local analysis and library layout

27 October 2026, Australia/Melbourne. Commander Axiom (`commander-axiom`).
Quest task: `7e4c795e-51f7-4486-8df8-8781d71b1608`.
Work session: `030a2ee9-8892-4f51-b1b2-a85f6cad3349`.
Branch: `codex/import-review-redesign`; all application changes remain uncommitted.

## Result

The Mac application embeds and manages its actual Python analysis service, five
chord checkpoints, madmom beat models, FFmpeg/FFprobe, Deno and standalone yt-dlp.
It needs no user Terminal startup, Homebrew, separate Python installation or
first-launch model downloads. The September library, chart workspace and inspector
remain the interface, including the previously integrated import-review workflow.

The helper starts on a private dynamic loopback port. The app validates its
instance, PID and model capabilities before using it. Requests require an
ephemeral secret; browser-origin requests are refused. Translation is restricted
to resolved folders within the app's jobs directory. Non-health work is serialised
because the inherited model adapter changes its working directory.

Only the child launched by this app is managed. Startup is coalesced; stale
readiness cannot revive a stopped child. Unexpected exits allow two automatic
restarts before an explicit recovery is required. Quitting stops the child, and
the helper independently watches for parent death. Logs, caches and job data stay
in Application Support; transient helper uploads are separate from source audio.
The status panel exposes recovery and the diagnostic log.

Internet remains necessary for TheStageBee sign-in/catalogue/review/publication
and obtaining new source recordings. Existing downloaded jobs appear locally
before the cloud catalogue loads. Model analysis, editing and export preparation
can run locally. This session verified model/runtime loading with networking
denied, but did not perform new media inference or an offline full-song run.

## Layout repair

The sidebar search, filter menu and status footer remain outside the scrolling
song list. A single native three-pane split replaces the nested navigation and
inspector containers that hid panes after selecting a song. Library visibility
is explicit; Cmd+F reopens it and focuses search. Restored oversized windows are
clamped to the visible screen, with a practical minimum size.

Native checks used an isolated 221-song synthetic catalogue to search/filter and
select rows. A separate app with Firebase stubs, a synthetic one-second WAV and
the real signed helper demonstrated automatic startup, Tools OK, offline-job
hydration and all three panes remaining visible after selection. No real recording
was processed. Offscreen renders at 0.85x and 1.4x text cover light/dark themes;
the compact 232x500 sidebar was visually inspected at 1.4x. Native border-drag
automation was unavailable, so manual resizing across screen sizes remains a
useful acceptance check. Render harness logs contain NSTableView reentrancy
warnings; rendering completed and the production build succeeded.

## Package and reproduction

Build with `Tools/Backend/package_app.sh` and a configured signing identity. It
uses a fresh pinned packaging target and leaves the backend virtual environment
unchanged. The Xcode native Copy Files phase embeds the signed helper; user-script
sandboxing stays enabled. Generated runtimes and caches are ignored by Git.

Build inputs:

- Backend source commit `cedefcd4cbd472edecb5afb3a67392fafae5a1b3` from the separate,
  unchanged `ChordAdminBackend` checkout; Python 3.9.6, torch 2.8.0 and madmom 0.16.1.
- PyInstaller 6.16.0, hooks 2025.9, setuptools 70.3.0.
- FFmpeg/FFprobe 8.1.1, Deno 2.9.6, yt-dlp 2026.10.26. The downloader's official
  release URL and SHA-256 are pinned in `download-tools.lock.json`.
- Native library dependencies are relocated into the helper. The embedded
  `runtime-manifest.json` records source revision, checkpoint hashes and downloader.

Development build:
`/tmp/chordadmin-managed-derived/Build/Products/Debug/ChordAdmin.app`.
Preserved copy:
`/Users/fkbcald/Applications/ChordAdmin Local Analysis.app`.
Measured regular-file content: **863,526,080 bytes (823.52 MiB)** before copying;
symlink targets are counted only once. This is an Apple Silicon build targeting
macOS 26.4 or later, signed with the available Apple Development certificate.
Deep strict signature verification passes. It is not notarised.
The delivery copy uses the local Applications folder: the cloud file provider in
Documents added Finder metadata that failed strict signature validation, so that
generated Documents copy was removed and the local copy verified separately.

The analysis helper requires JIT and unsigned executable-memory entitlements for
the numerical/libffi stack; these are confined to the helper. Deno receives its
JIT entitlement. Library validation is not disabled. The main app's entitlements
are unchanged. The standalone yt-dlp retains its upstream signature: re-signing
its outer one-file executable caused a verified Team-ID mismatch with its extracted
libraries, so the exact SHA-256-verified upstream artifact is preserved.

## Verification

- Clean typecheck of 37 application source files.
- **366/366 pipeline and import-review checks passed.** These use local test
  adapters rather than production Firestore.
- **17/17 runtime/window lifecycle checks passed**, using the actual signed frozen
  helper: startup coalescing, identity/capability readiness, request authentication,
  secret destination restriction, browser-origin rejection, translation path
  restriction, crash restart, bounded restart budget, explicit recovery, shutdown,
  cancellation, missing-package handling, and restored-window bounds.
- Parent-exit watchdog test passed.
- Frozen model/dependency self-test passed with all networking denied and reads to
  the backend checkout, Homebrew and Xcode/Command Line Tools Python locations denied.
  It loads the beat models, all five chord checkpoints and HMM dictionary and
  exercises numerical JIT; it performs no media inference.
- Bundled FFmpeg/FFprobe, Deno version/evaluation and yt-dlp version commands passed
  with a minimal PATH. Normal Xcode build with real Firebase SDK succeeded, and
  `codesign --verify --deep --strict` passed for the complete app.
- Light/dark render sweeps completed; native fixture app startup/layout verified.
- `git diff --check` passed.

## Preservation and release limits

The existing signed-in app was left running from
`/tmp/chordadmin-import-review-derived`; no build replaced that executable.
Before this work, tracked/untracked source and Application Support data were
backed up under
`/Users/fkbcald/Documents/Codex/2026-10-27/chordadmin-local-runtime-baseline/`.
No owner job was resumed, reanalysed or deleted. The separate test app uses only
temporary fixture storage. The running old app will continue showing its old
behavior until the owner closes it and opens the new package.

No production Firestore rules, canonical songs or cloud staging records were
changed, and no deployment/publication occurred. No new end-to-end recording test
was performed, as requested. The earlier import-review task remains open for
production rules reconciliation/emulator testing and live acceptance; this local
packaging result does not satisfy those gates.

Public distribution needs additional work. The [madmom model licence](https://github.com/CPJKU/madmom/blob/main/LICENSE)
is CC BY-NC-SA 4.0, distinct from its code licence; commercial use needs a compatible
permission/model choice. The chord repository supplies an
[MIT licence](https://github.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition/blob/master/LICENSE).
Collected notices accompany the helper, including FFmpeg components; a complete
third-party distribution and source-offer review is still required. The current
frozen Python comes from Apple's development-tools framework and is old; replace
it with an explicitly redistributable supported runtime before a public release.
Developer ID signing, upstream one-file downloader signing compatibility and
notarisation also need a distribution pass. Development signature verification
does not establish Gatekeeper acceptance on another Mac.
