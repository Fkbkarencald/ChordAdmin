# ChordAdmin

Native macOS app for preparing TheStageBee song data from YouTube audio. It downloads a source track, converts it to analysis audio, calls the local ChordAdminBackend service for beat and chord analysis, and can export cleaned section/tempo data back into TheStageBee's Firestore song records.

The window has three columns: the song library on the left, the song being worked on in the middle (transport, waveform, chord chart), and an inspector on the right (Bar / Tuning / Analysis / Info). With no song selected it shows a launch dashboard. Analysis runs as an eleven-stage pipeline reported as a checklist, with per-stage retry, resume and cancel.

## Requirements

- macOS 26.4 or later, matching the current Xcode project deployment target.
- Xcode 26 or later.
- Homebrew tools used by the app:
  - `yt-dlp`
  - `ffmpeg` and `ffprobe`
  - `deno`
- Firebase configuration for the TheStageBee project.
- A running ChordAdminBackend service for beat and chord analysis.

## Setup

```sh
brew install yt-dlp ffmpeg deno
open ChordAdmin.xcodeproj
```

In Xcode, select the `ChordAdmin` scheme and set signing to your development team if needed.

## Environment Variables

Firebase configuration is bundled through the Xcode project. The analysis backend address lives in one place, `JobManager.backendBaseUrl`, and both the analysis and the export use it.

| Variable | Used by | Purpose |
| --- | --- | --- |
| `CHORDADMIN_JOBS_DIR` | app and `Tools/verify.sh` | Redirects job folders and the URL cache away from `~/Library/Application Support/ChordAdmin`. Set by the render harness so it never touches real data. |
| `CHORDADMIN_BACKEND_URL` | app and `Tools/verify.sh` | Points the app at a different analysis backend, e.g. when ChordAdminBackend is moved off 5051 with its own `CHORDADMIN_BACKEND_PORT`. Defaults to `http://localhost:5051`. |
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

**Still not met:** nothing here has touched real Firebase. Sign-in and the
library are stubbed, so the export's final `updateData` on `songs/<id>` has never
run, and neither has the signed-in library load. Everything up to that point —
download, convert, metadata, audio health, beats, grid, chords, chart, sections
and the export *translation* — has now been run for real end to end
(`verify.sh real`), against a synthesised file with known ground truth (120 BPM,
C–Am–F–G, recovered exactly) and against a real YouTube track.

## Run Locally

1. Start the backend:

   ```sh
   cd ../ChordAdminBackend
   ./start.sh
   ```

2. In Xcode, run the `ChordAdmin` scheme.
3. Sign in with Apple if Firestore access requires authentication.
4. Select a TheStageBee song with a YouTube link and start analysis.

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
| `./Tools/verify.sh test` | Builds and runs 324 checks: beat grid, tempo halving, chart generation, keyboard navigation across a ragged section grid, section detection, section editing, storage and job persistence (including older `job.json` files), hydration and the migration of pre-existing job folders, queueing, and export safety (an analysis can never be written onto a different song). A full analysis also runs against a stub backend on a free port, covering the resume path, a backend 500, an unreachable backend and cancelling mid-upload, and a deliberately failing re-analysis proves the previous chart survives. |
| `./Tools/verify.sh app` / `run` | Builds a launchable `ChordAdmin.app` against the Firebase stubs and, for `run`, launches it with job storage redirected to a temporary folder. There is no sign-in and no library, but the window, the menus and every local interaction are real — this is how the app gets exercised on a machine without Xcode. |
| `./Tools/verify.sh render` | Renders every SwiftUI view offscreen, light and dark, to `Tools/.render-output/*.png`, and flags any view that lays out to nothing. |

`Tools/Stubs` holds minimal stand-ins for FirebaseCore, FirebaseAuth and FirebaseFirestore so none of this needs the real SDK or network access. The stubs are never part of the app target — only `ChordAdmin/` is synchronised into the Xcode project.

Running the real app still needs Xcode.

## Deploy

No standalone deployment pipeline is configured. Distribution is currently an Xcode archive/signing task.

## Local Data

Each analysis writes to `~/Library/Application Support/ChordAdmin/jobs/<UUID>/`, keyed to the song's Firestore document ID. Downloaded audio and 44.1 kHz WAVs are large, so the inspector's Info tab reports how much disk each analysis uses, offers to delete one, and can remove folders left behind by earlier runs.

## Known Ports

| Service | Port |
| --- | ---: |
| ChordAdminBackend Flask API | `5051` |

## Related Projects

- `../ChordAdminBackend`: local Flask service for audio analysis.
- `../thestagebee`: web app whose Firestore data ChordAdmin reads and updates.
- `../thestagebeeiOS`: native iOS TheStageBee client.

