# ChordAdmin

Native macOS app for preparing TheStageBee song data from YouTube audio. It downloads a source track, converts it to analysis audio, calls the local ChordAdminBackend service for beat and chord analysis, and can export cleaned section/tempo data back into TheStageBee's Firestore song records.

The window has three columns: the song library on the left, the song being worked on in the middle (transport, waveform, chord chart), and an inspector on the right (Bar / Tuning / Analysis / Info). With no song selected it shows a launch dashboard. Analysis runs as an eleven-stage pipeline reported as a checklist, with per-stage retry, resume and cancel.

## Using the packaged app

Open **ChordAdmin.app**. It starts and manages its own private local analysis
service, Python runtime, beat/chord models, FFmpeg, FFprobe, Deno and downloader.
No Terminal command, Homebrew installation or separate backend startup is needed.
The analysis status in the library footer shows startup progress, recovery and logs.
The app stops its helper when it quits; the helper also exits if its parent crashes.

Internet is needed to sign in, load/update TheStageBee, acquire new recordings and
publish/review cloud imports. Once audio is downloaded, beat/chord analysis,
timing and section editing, and export preparation stay local. Saved local jobs
remain available in the library before the online catalogue loads. Model and
numerical-runtime initialisation have been checked with networking and developer
folders denied; no new full-song test was performed in this work session.

The current development package targets **Apple Silicon, macOS 26.4 or later**.
It is approximately 824 MiB unpacked; see the measured report below. It is a
local development build, not a notarised general-distribution release.

## Downbeats and section suggestions

New analyses detect beat positions within each bar and choose the pickup from
the first detected downbeat. Existing saved pickup choices remain in place;
Tuning offers **Use detected pickup** after beat re-detection. Requested metre
(2, 3 or 4 beats per bar) is explicit. Metrical ambiguity is shown as a warning.

Section suggestions use sustained changes in timbre, harmonic content, dynamics
and percussive texture. In **Bar → All sections**, **Refresh audio suggestions**
uses the saved WAV and keeps the current chart and sections. **Detect sections
again** applies the suggestions only after the replacement confirmation.
These acoustic suggestions use generic labels and still need musical review.
Vocal/instrumental stem separation is a possible later extension; it is not part
of this pass. See [the timing report](docs/downbeats-and-audio-sections-2026-10-27.md).

## Building the self-contained app

Building requires Xcode and the existing verified Python 3.9 backend/model build
inputs. These are build-time inputs and are not required on a user's Mac. The
packager freezes the actual backend and follows native-library dependencies;
the runtime does not install packages or fetch models on first launch.

```sh
export CHORDADMIN_SIGNING_IDENTITY=<your-signing-certificate-hash>
./Tools/Backend/package_app.sh
```

`CHORDADMIN_BACKEND_SOURCE` can point to the backend source/model directory.
`CHORDADMIN_PACKAGING_PYTHON` selects its compatible build interpreter.
`CHORDADMIN_DERIVED_DATA` selects a fresh output directory. Do not build over a
running app; this work uses a separate output to preserve the owner's session.
Generated runtimes and packaging caches are excluded from Git.

The pinned standalone downloader is verified against its SHA-256 lock. Its
upstream one-file signature is retained; only re-signing that outer executable
would invalidate its extracted Python libraries. The analysis helper and native
libraries are signed separately, then embedded by Xcode's native Copy Files phase.
The helper alone needs JIT/executable-memory entitlements for the numerical stack;
the main app does not receive those entitlements.

Model licences and general-distribution constraints are recorded in
[the runtime and layout report](docs/local-runtime-and-sidebar-2026-10-27.md).

## Environment Variables

Firebase configuration is bundled through the Xcode project. The analysis backend address lives in one place, `JobManager.backendBaseUrl`, and both the analysis and the export use it.

| Variable | Used by | Purpose |
| --- | --- | --- |
| `CHORDADMIN_JOBS_DIR` | app and `Tools/verify.sh` | Redirects job folders and the URL cache away from `~/Library/Application Support/ChordAdmin`. Set by the render harness so it never touches real data. |
| `CHORDADMIN_BACKEND_URL` | app and `Tools/verify.sh` | Points the app at a different analysis backend, e.g. when ChordAdminBackend is moved off 5051 with its own `CHORDADMIN_BACKEND_PORT`. Normally uses a private loopback port chosen at launch; set this only for a developer-managed service. |
| `CHORDADMIN_SDK` | `Tools/verify.sh` | macOS SDK to typecheck against. Defaults to `MacOSX26.5.sdk`. |

## What "finished" means here

The brief for this work was open-ended, so this is the bar it was held to. Each
line is checked by something that runs, not by inspection:

| | How it is checked |
|---|---|
| Every source file typechecks with no warnings | `verify.sh check` |
| No known path loses the user's work | `verify.sh test` — rollback rules, launch-time folder choice, mid-run edits, unwritable storage |
| No known dead end: every failure states what happened and offers a way on | Backend down, tools missing or broken, library load failed, sign-in failed, section save failed, export refused, re-detection failed — each has a rendered state |
| A destructive action says what it will destroy before doing it | Re-analyse, detect-sections-again, merge-all, delete-analysis |
| The app's parsing matches what ChordAdminBackend really returns | `verify.sh test` — the real payload shapes, both error conventions (`message` vs `error`), and errors sent at HTTP 200 |
| What the export writes is what the sheet showed | `verify.sh test` — the diff is read from the real translated payload, and the tempo written is the integer displayed |
| Every action is reachable without a mouse | Menu bar covers each one; chart bars, pickup rows and library rows are buttons |
| Every view renders in light and dark, at the smallest and largest text | `verify.sh render` and `verify.sh stress` |
| The app builds and launches on a machine without Xcode | `verify.sh app` / `run` |
| The whole pipeline runs against the real backend, from a YouTube URL to an exportable chart | `verify.sh real <url>` — the app's own code, the real yt-dlp/ffmpeg stages, the real madmom and chord model |

**Historical pipeline evidence (before the bundled-runtime work):** the automated
suite has not exercised production Firebase. Sign-in and the
library are stubbed, so the export's final `updateData` on `songs/<id>` has never
run. Everything up to that point —
download, convert, metadata, audio health, beats, grid, chords, chart, sections
and the export *translation* — has now been run for real end to end
(`verify.sh real`), against a synthesised file with known ground truth (120 BPM,
C–Am–F–G, recovered exactly) and against a real YouTube track.
Those earlier runs do not constitute end-to-end verification of the new frozen
runtime; this session deliberately performed no new song analysis or publication.

## Reviewed new-song imports

Open **Song Imports…** in the toolbar or press **Cmd+N** after signing in with your
TheStageBee administrator account. Stage a YouTube URL with its title, artist and
optional key. The app records the import before processing it, then runs it through
the same analysis engine and three-pane workspace used for existing songs. Open
the chart to tune timing and edit sections, then choose **Review publication…**.
Publication previews the latest chart and reviewed metadata before creating the
canonical song. Duplicates, incomplete processing, stale previews and existing
canonical destinations are refused; rejection keeps the audit history.

Retries execute failed work and reuse successful outputs. Once published, the
local chart and export record follow the canonical song in the library.

The `songImportStaging` Firestore rules must be available before this workflow can
be used against production. The local integration and release boundaries are
recorded in [the implementation report](docs/import-review-redesign-2026-10-27.md).

## Run Locally

Use the packaged app built above. It manages its local service automatically.
`CHORDADMIN_BACKEND_URL` is an optional developer-only override for attaching to
an existing test service; ChordAdmin never terminates that external service.

## Build

```sh
xcodebuild \
  -project ChordAdmin.xcodeproj \
  -scheme ChordAdmin \
  -destination 'platform=macOS' \
  build
```

## Test And Verify

There is no XCTest target. Instead `Tools/verify.sh` checks the app with the Swift compiler alone, so it also works on a machine that has only the Command Line Tools:

```sh
./Tools/verify.sh all
```

| Command | What it does |
| --- | --- |
| `./Tools/verify.sh check` | Typechecks every source file with the target's own Swift settings (Swift 5 mode, `MainActor` default isolation). Should report no errors and no warnings. |
| `./Tools/verify.sh test` | Builds and runs 366 checks: beat grid, tempo halving, chart generation, keyboard navigation across a ragged section grid, section detection, section editing, storage and job persistence (including older `job.json` files), hydration and the migration of pre-existing job folders, queueing, and export safety (an analysis can never be written onto a different song). A full analysis also runs against a stub backend on a free port, covering the resume path, a backend 500, an unreachable backend and cancelling mid-upload, and a deliberately failing re-analysis proves the previous chart survives. |
| `./Tools/verify.sh app` / `run` | Builds a launchable `ChordAdmin.app` against the Firebase stubs and, for `run`, launches it with job storage redirected to a temporary folder. There is no sign-in and no library, but the window, the menus and every local interaction are real — this is how the app gets exercised on a machine without Xcode. |
| `./Tools/verify.sh render` | Renders every SwiftUI view offscreen, light and dark, to `Tools/.render-output/*.png`, and flags any view that lays out to nothing. |
| `./Tools/verify.sh runtime` | Runs 17 checks against the signed bundled helper, including private authentication, readiness, crash recovery, restart limits, shutdown, and restored-window placement. No media is analysed. Requires the generated helper package. |

`Tools/Stubs` holds minimal stand-ins for FirebaseCore, FirebaseAuth and FirebaseFirestore so none of this needs the real SDK or network access. The stubs are never part of the app target — only `ChordAdmin/` is synchronised into the Xcode project.

Building the Firebase production target requires Xcode; running its packaged app does not.

## Deploy

No standalone deployment pipeline is configured. Distribution is currently an Xcode archive/signing task.

## Local Data

Each analysis writes to `~/Library/Application Support/ChordAdmin/jobs/<UUID>/`, keyed to the song's Firestore document ID. Downloaded audio and 44.1 kHz WAVs are large, so the inspector's Info tab reports how much disk each analysis uses, offers to delete one, and can remove folders left behind by earlier runs.

## Known Ports

| Service | Port |
| --- | ---: |
| Bundled local analysis | Private loopback port allocated automatically |

## Related Projects

- `../ChordAdminBackend`: local Flask service for audio analysis.
- `../thestagebee`: web app whose Firestore data ChordAdmin reads and updates.
- `../thestagebeeiOS`: native iOS TheStageBee client.

