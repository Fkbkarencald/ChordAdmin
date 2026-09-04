# ChordAdmin Project Context

---

## 1. Project Overview

ChordAdmin is a **native macOS SwiftUI application** that takes a TheStageBee song with a YouTube
link, downloads the audio, and runs a full audio analysis pipeline to produce a chord chart with
section labels which can then be written back to TheStageBee's Firestore `songs` collection.

**App purpose:** produce a bar-by-bar chord chart a musician can use as a performance reference. It
detects tempo, beats, bar boundaries, chords and repeating song sections.

**Main user workflow:**
1. The library sidebar lists every TheStageBee song with its state — not analysed, analysed, edited,
   exported — plus filters and search.
2. Selecting a song opens the workspace: transport, waveform overview and the chord chart.
   With nothing selected the window shows a launch dashboard (continue where you left off, analyse
   new songs as a queue, recent exports, environment readiness).
3. Analysis runs as an 11-stage pipeline, reported as a per-stage checklist with timings, warnings,
   retry and cancel.
4. The user corrects beat alignment in the Tuning inspector (pickup offset, beats per bar, halved
   tempo, manual BPM) — previewed live in memory, applied explicitly.
5. Sections are edited on the chart itself, anchored to the selected bar (split / merge / rename,
   with S / M / R shortcuts scoped to chart focus).
6. Export shows a confirmation sheet with the tempo and section diff before it overwrites the
   Firestore document.

**Platform:** macOS only — uses `NSWorkspace`, `NSPasteboard`, `NSColor`, `AVAudioPlayer`, `AVAudioFile`.

**Local backend:** required. A local Python server at `http://localhost:5051` performs beat detection,
chord recognition and the StageBee translation. If it is unreachable the job stops at
`.audioReady` — a resumable pause, not a terminal state, and no audio is downloaded twice.

**Local files:** each job writes to `~/Library/Application Support/ChordAdmin/jobs/<UUID>/`. Jobs are
keyed by the song's Firestore document ID, stamped into `job.json`.

---


## 2. Project Structure

```
ChordAdmin/
├── ChordAdmin/
│   ├── ChordAdminApp.swift          ← App entry point
│   ├── AppTermination.swift         ← Quit handling: settles an in-flight re-analysis, warns mid-run
│   │   — Models and services —
│   ├── AnalysisJob.swift            ← Job record, statuses, chart/section value types
│   ├── PipelineStage.swift          ← The 11 stages, per-stage state, StageReport
│   ├── JobManager.swift             ← Per-song orchestration, queue, cancel, resume, retry
│   ├── ChartGeneration.swift        ← Pure transforms (beat grid, charts, section candidates)
│   ├── ChartNavigation.swift        ← Where each arrow key lands in the ragged bar grid
│   ├── SectionStore.swift           ← Section state and persistence
│   ├── StageBeeExportService.swift  ← Export preview (diff) and commit
│   ├── FirebaseSongStore.swift      ← Firestore song list
│   ├── FirebaseSong.swift           ← Song document model
│   ├── AuthStore.swift              ← Sign in with Apple → Firebase Auth
│   ├── EnvironmentStore.swift       ← Tool + backend readiness
│   ├── ToolChecker.swift            ← PATH-aware tool resolution and versions
│   ├── ProcessRunner.swift          ← Async subprocess wrapper with cancellation
│   ├── LocalFileStore.swift         ← Job folder I/O, URL cache
│   ├── Library.swift                ← Song work state, filters, library rows
│   │   — UI —
│   ├── ContentView.swift            ← Root: split view, toolbar, sheets, state wiring
│   ├── LibrarySidebar.swift         ← Song list, filters, environment footer
│   ├── FrontScreenView.swift        ← Launch dashboard (no selection)
│   ├── SongWorkspaceView.swift      ← Transport, waveform, chart host
│   ├── WaveformView.swift           ← Canvas waveform with section band and chord lane
│   ├── ChordChartView.swift         ← Sectioned bar grid and bar-anchored actions
│   ├── InspectorView.swift          ← Bar / Tuning / Analysis / Info tabs
│   ├── ExportSheet.swift            ← Export confirmation with diff
│   ├── AudioPlayback.swift          ← Player and waveform sample loader
│   ├── DesignKit.swift              ← Shared UI atoms
│   └── WorkspaceState.swift         ← Inspector tab, tuning draft, formatting
├── CHORDADMIN_PROJECT_CONTEXT.md    ← This file
├── design/                          ← Redesign artboards + build.py generator
└── ChordAdmin.xcodeproj/
```

The Xcode project uses a file-system-synchronised group (`objectVersion = 77`), so files added to
`ChordAdmin/` are picked up without editing `project.pbxproj`.

---


## 3. Current Audio Processing Flow

```txt
User enters YouTube URL → JobManager.startJob(url:)
↓
URL cache check (LocalFileStore.cachedJobFolder)
  → if hit and job.json + analysis.wav exist: load cached job, return
  → if stale: evict cache entry, continue
↓
Create job folder: ~/Library/Application Support/ChordAdmin/jobs/<UUID>/
Write source.info.json  { url, jobId }
↓
ToolChecker.checkAll()  — probes yt-dlp, ffmpeg, ffprobe, deno
  → failure: throw JobError.missingTools → status = .failed
↓
status = .downloading
yt-dlp -f ba/b --no-playlist --js-runtimes deno:... -o audio.original.%(ext)s <url>
  → writes audio.original.<ext> to job folder
  → determines path from --print after_move:filepath
  → failure: throw JobError.downloadFailed
↓
status = .converting
ffmpeg -y -i <downloaded> -ar 44100 -ac 1 analysis.wav
  → writes analysis.wav (mono, 44 100 Hz)
  → stores path in job.analysisWavPath
  → failure: throw JobError.conversionFailed
↓
status = .extractingMetadata
ffprobe -v quiet -print_format json -show_format -show_streams analysis.wav
  → writes metadata.json
  → populates job: durationSeconds, sampleRate, channels, codecName, bitRate, fileSizeBytes
  → failure: throw JobError.metadataFailed
↓
status = .analysingAudioHealth
ffmpeg volumedetect + silencedetect on analysis.wav
  → writes audio.health.json  { meanVolumeDb, maxVolumeDb, silenceRegions, warnings }
  → populates job: meanVolumeDb, maxVolumeDb, silenceRegionCount, totalSilenceDurationSeconds
↓
status = .checkingAnalysisBackend
GET http://localhost:5051/health
  → if 404 / error: job.status = .completedWithWarnings  ← pipeline ends here without charts
  → if 200: continue
↓
status = .detectingBeats
POST http://localhost:5051/api/detect-beats  (multipart; file=analysis.wav, model=auto)
  → writes beat.detection.json
  → populates job: bpm, beatCount, resolvedBeatModel
↓
status = .generatingBeatGrid  (client-side, no network)
generateBeatGrid(from: beat.detection.json, bpm:, barAlignmentOffset: 0)
  → writes beat.grid.json  { bpm, bars: [{bar, start, end, beats}], estimatedTimeSignature }
  → populates job: beatGridPath, barCount, estimatedTimeSignature
↓
status = .recognizingChords
POST http://localhost:5051/api/recognize-chords  (multipart; file=analysis.wav, model=chord-cnn-lstm)
  → writes chord.recognition.json
  → writes chord.cleaned.json  (normalised chord list with displayChord)
  → populates job: chordCount, chordPreview, chordRecognitionPath, chordCleanedPath
↓
status = .generatingChordChart  (client-side)
generateChordChart(beatGridData:, chordCleanedData:)
  → overlaps each cleaned chord against each bar from beat grid
  → writes chord.chart.draft.json  { bars: [{bar, start, end, primaryChord, chords:[]}] }
  → populates job: chordChartDraftPath, chordChartBarCount, chordChartPreview
↓
generatePerformerChart(draftData:, configData:)  (client-side)
  → filters chords with overlapSeconds ≥ 0.25 s, removes adjacent duplicates
  → applies chartStartTime, includePreIntro, barAlignmentOffset from chart.config.json
  → writes chart.config.json  { barAlignmentOffset, chartStartTime, includePreIntro, ... }
  → writes chord.chart.performer.json  { bars: [{bar, sourceBar, primaryChord, chords:[]}] }
  → populates job: chordChartPerformerPath, performerChartPreview
↓
status = .detectingSections  (client-side)
detectSectionCandidates(performerData:)
  → builds bar-signature strings (deduplicated chord sequence per bar)
  → finds 4-bar and 8-bar windows that repeat; labels them A, B, C...
  → writes section.candidates.json  { candidates: [{label, startBar, endBar, barCount, matchCount, matches}] }
  → populates job: sectionCandidatesPath, sectionCandidateCount, sectionCandidatePreview
↓
generateInitialSections(performerData:, candidatesPayload:)
  → selects non-overlapping candidates (prefer 8-bar), assigns names (Intro, Section A…, Outro)
  → writes sections.json  { sections: [{id, name, startBar, endBar, bars:[]}] }
  → populates job: sectionsPath, sectionCount
↓
status = .completed
LocalFileStore.saveURLCache(url:, folderPath:)  ← caches for instant replay
↓
UI displays chord chart (ChordChartModeSwitcher), waveform (WaveformView),
section labels (SectionStore), log panel
```

---

## 4. Job Folder and File Outputs

All files live in:
```
~/Library/Application Support/ChordAdmin/jobs/<UUID>/
```

| File | Created by | When | Contains | Read by |
|---|---|---|---|---|
| `source.info.json` | `LocalFileStore.saveSourceInfo` | Job start | `{ url, jobId }` | Not read back; informational only |
| `audio.original.<ext>` | yt-dlp | Download step | Raw downloaded audio (webm, m4a, etc.) | ffmpeg (conversion input) |
| `analysis.wav` | ffmpeg | Convert step | Mono 44 100 Hz WAV | ffprobe, ffmpeg health, backend endpoints |
| `metadata.json` | ffprobe / `JobManager` | Metadata step | Full ffprobe JSON (format + streams) | UI (MetadataPanel reads fields from `AnalysisJob`) |
| `audio.health.json` | `JobManager` | Health step | `{ meanVolumeDb, maxVolumeDb, silenceRegions, totalSilenceDurationSeconds, warnings }` | UI (AudioHealthPanel) |
| `job.json` | `LocalFileStore.saveJob` | After every `persist()` call | Full `AnalysisJob` encoded as ISO-8601 JSON | URL cache reload, app restart recovery |
| `logs.txt` | `LocalFileStore.appendLog` | After every `log()` call | Append-only plaintext pipeline log | UI log panel (via in-memory `logOutput`); can be opened externally |
| `beat.detection.json` | `JobManager.postAudioFile` | Beat detection step | Backend response: `{ bpm, beats:[{time}], model, cached? }` | `generateBeatGrid`, `parseBeatResponse` |
| `beat.grid.json` | `JobManager.generateBeatGrid` | Beat grid step | `{ bpm, bars:[{bar, start, end, beats}], estimatedTimeSignature, barAlignmentOffset }` | `generateChordChart`, `regenerateCharts` |
| `chord.recognition.json` | `JobManager.postAudioFile` | Chord recognition step | Backend response: `{ cleanedChords:{ chords:[{start,end,rawChord,displayChord}] }, cached? }` | `parseChordResponse` |
| `chord.cleaned.json` | `JobManager.parseChordResponse` | Chord recognition step | `{ chords:[{start, end, rawChord, displayChord}] }` | `generateChordChart`, `regenerateCharts`, waveform overlay |
| `chord.chart.draft.json` | `JobManager.generateChordChart` | Chart generation step | `{ bars:[{bar, start, end, primaryChord, chords:[{displayChord,start,end,overlapSeconds}]}] }` | `generatePerformerChart`, `regenerateCharts` |
| `chart.config.json` | `JobManager` | Performer chart step | `{ barAlignmentOffset, chartStartTime, chartStartBarMode, includePreIntro }` | `generatePerformerChart`, `updatePerformerChart`, `regenerateCharts` |
| `chord.chart.performer.json` | `JobManager.generatePerformerChart` | Performer chart step | Draft bars filtered/deduped, renumbered; `{ bars:[{bar, sourceBar, primaryChord, chords}] }` | `detectSectionCandidates`, `SectionStore`, UI waveform, `ChordProgressionView` |
| `section.candidates.json` | `JobManager.detectSectionCandidates` | Section detection step | `{ candidates:[{label, startBar, endBar, barCount, matchCount, matches, barSignatures}] }` | `generateInitialSections`, `SectionStore` |
| `sections.json` | `JobManager.generateInitialSections` / `SectionStore.save()` | Section detection + user edits | `{ sections:[{id, name, startBar, endBar, bars:[]}] }` | `SectionStore`, `ChordProgressionView` |

> **Note:** `chordChartSimplePath` / `chordChartSimpleBarCount` / `chordChartSimplePreview` fields exist on `AnalysisJob` and a `generatingSimpleChart` `JobStatus` case exists, but no code in the current pipeline writes `chord.chart.simple.json`. These appear to be vestigial from an earlier implementation.

---

## 5. Backend Integration

The backend is expected to run **locally** on the same machine as the app.

**Base URL (hardcoded):** `http://localhost:5051`  
Location: `JobManager.swift`, line with `private static let backendBaseUrl = "http://localhost:5051"`

### Health check

```
GET http://localhost:5051/health
```
- Expected response: HTTP 200 (any body)
- If anything other than 200: job is marked `.completedWithWarnings` and the pipeline stops without charts.

### Beat detection

```
POST http://localhost:5051/api/detect-beats
Content-Type: multipart/form-data

Fields:
  file     (filename: analysis.wav, content-type: audio/wav)
  model    "auto"
```

Expected response JSON:
```json
{
  "bpm": 120.0,
  "beats": [{ "time": 0.512 }, ...],
  "model": "madmom",
  "cached": false
}
```
Parsed by `JobManager.parseBeatResponse`. The `cached` flag is shown in the log.

### Chord recognition

```
POST http://localhost:5051/api/recognize-chords
Content-Type: multipart/form-data

Fields:
  file     (filename: analysis.wav, content-type: audio/wav)
  model    "chord-cnn-lstm"
```

Expected response JSON:
```json
{
  "cleanedChords": {
    "chordCount": 84,
    "chords": [
      { "start": 0.0, "end": 1.23, "rawChord": "C:maj", "displayChord": "C" },
      ...
    ]
  },
  "cached": false
}
```
Parsed by `JobManager.parseChordResponse`. If `cleanedChords` is absent, falls back to reading `chordCount` directly.

### Error handling and timeouts

- **No timeout** is set on `URLSession.shared.data(for:)` — calls can hang indefinitely if the backend stalls.
- **No retry logic** — a single failure logs the error and the pipeline continues without that result.
- Beat detection failure is non-fatal (logged, pipeline continues to chord recognition).
- Chord recognition failure is non-fatal (logged, pipeline continues to chart generation with whatever data exists).
- The entire WAV file is loaded into memory via `try Data(contentsOf: fileURL)` before sending. **Risk: large files cause high RAM use.**

### Where results are stored

Beat results → `beat.detection.json` → `beat.grid.json`  
Chord results → `chord.recognition.json` → `chord.cleaned.json`  
Both feed into client-side chart generation.

---

## 6. Existing Models and Data Types

All types live in `ChordAdmin/AnalysisJob.swift` unless otherwise noted.

### `AnalysisJob`
`struct AnalysisJob: Codable, Identifiable, Sendable`  
The central job record. Persisted to `job.json` after every pipeline step.

Key properties:

| Property | Type | Meaning |
|---|---|---|
| `id` | `String` | UUID |
| `sourceUrl` | `String` | Cleaned YouTube URL |
| `status` | `JobStatus` | Current pipeline stage |
| `originalAudioPath` | `String?` | Path to downloaded audio file |
| `analysisWavPath` | `String?` | Path to `analysis.wav` |
| `metadataPath` | `String?` | Path to `metadata.json` |
| `audioHealthPath` | `String?` | Path to `audio.health.json` |
| `beatDetectionPath` | `String?` | Path to `beat.detection.json` |
| `beatGridPath` | `String?` | Path to `beat.grid.json` |
| `chordRecognitionPath` | `String?` | Path to `chord.recognition.json` |
| `chordCleanedPath` | `String?` | Path to `chord.cleaned.json` |
| `chordChartDraftPath` | `String?` | Path to `chord.chart.draft.json` |
| `chartConfigPath` | `String?` | Path to `chart.config.json` |
| `chordChartPerformerPath` | `String?` | Path to `chord.chart.performer.json` |
| `sectionCandidatesPath` | `String?` | Path to `section.candidates.json` |
| `sectionsPath` | `String?` | Path to `sections.json` |
| `bpm` | `Double?` | Detected BPM |
| `barCount` | `Int?` | Total bars in beat grid |
| `chordCount` | `Int?` | Total cleaned chords |
| `chordChartPreview` | `[ChordChartBarEntry]?` | In-memory preview for UI |
| `performerChartPreview` | `[PerformerChartBarEntry]?` | In-memory preview for UI |
| `sectionCandidatePreview` | `[SectionCandidate]?` | In-memory preview for UI |
| `errorMessage` | `String?` | Last error description; only set on a job that actually failed |
| `notice` | `String?` | Something to tell the user about an otherwise healthy job — set when a rolled-back re-analysis put the previous one back |
| `barAlignmentOffset` | `Int?` | 0–3 beat pickup offset |
| `tempoHalved` | `Bool?` | Whether tempo-halving is active |
| `barsWithoutChords` | `Int?` | Chordless bars across the whole chart (the preview holds only eight) |
| `chartsVersion` | `Int?` | Bumped inside `buildCharts`, the one place the chart files are written, so it covers a first run, a resume, a retry and a re-tune alike. `ContentView.workspaceKey` reloads on it. |

### `JobStatus`
`enum JobStatus: String, Codable, Sendable`  
Cases: `pending`, `checkingTools`, `downloading`, `converting`, `extractingMetadata`, `analysingAudioHealth`, `checkingAnalysisBackend`, `detectingBeats`, `generatingBeatGrid`, `recognizingChords`, `generatingChordChart`, `generatingSimpleChart` (vestigial), `detectingSections`, `completed`, `completedWithWarnings`, `failed`.

### `CleanedChord`
`struct CleanedChord: Codable, Sendable`  
`start`, `end`, `rawChord`, `displayChord` — represents one detected chord segment. Used in `chordPreview` and waveform overlay.

### `ChordChartBarEntry`
`struct ChordChartBarEntry: Codable, Sendable`  
`bar`, `start`, `end`, `primaryChord?`, `chords: [ChordChartChordEntry]` — one bar in the draft or performer chart. Used for waveform bar grid and `ChordProgressionView`.

### `ChordChartChordEntry`
`struct ChordChartChordEntry: Codable, Sendable`  
`displayChord`, `start`, `end`, `overlapSeconds` — one chord within a bar, with its overlap duration.

### `ChordChartSimpleBarEntry`
`struct ChordChartSimpleBarEntry: Codable, Sendable`  
`bar`, `start`, `end`, `chord` — vestigial simple one-chord-per-bar format; referenced in `AnalysisJob` but not actively generated.

### `PerformerChartBarEntry`
`struct PerformerChartBarEntry: Codable, Sendable`  
`bar`, `sourceBar`, `start`, `end`, `primaryChord?`, `chords` — performer view bar. Backward-compatible decoder reads old single-`chord` field. Used in `chord.chart.performer.json` and displayed in `ChordProgressionView`.

### `SectionCandidate`
`struct SectionCandidate: Sendable` (with manual `Codable`)  
`label` (A/B/C…), `startBar`, `endBar`, `barCount` (4 or 8), `barSignatures: [String]`, `matchCount`, `matches: [SectionCandidateMatch]` — a repeating musical section detected by window-matching. Backward-compat decoder handles old `chords` key.

### `SectionCandidateMatch`
`struct SectionCandidateMatch: Codable, Sendable`  
`startBar`, `endBar` — one occurrence of a repeated section pattern.

### `ChordSection` (SectionStore.swift)
`struct ChordSection: Codable, Identifiable, Sendable, Equatable`  
`id`, `name`, `startBar`, `endBar`, `bars: [Int]` — a named song section (e.g. "Intro", "Section A"). Stored in `sections.json` and managed interactively by `SectionStore`.

### `SectionsFile` (SectionStore.swift)
`struct SectionsFile: Codable, Sendable`  
`source`, `sections: [ChordSection]` — the on-disk representation of `sections.json`.

### `JobError` (JobManager.swift)
`enum JobError: LocalizedError`  
Cases: `missingTools([String])`, `downloadFailed(String)`, `conversionFailed(String)`, `metadataFailed(String)`, `audioHealthFailed(String)`. Only these five are fatal (thrown to the catch block). Backend and chart failures are non-fatal.

---

## 7. UI Screens and User Actions

One window, three columns: library sidebar, workspace, inspector.

### Root — `ContentView`
`NavigationSplitView` with the library as sidebar and, in the detail column, either the workspace
(a song is selected) or the front screen. The inspector is a trailing `.inspector` panel. Owns
`JobManager`, `FirebaseSongStore`, `AuthStore`, `EnvironmentStore`, `StageBeeExportService`,
`SectionStore`, `ChordAudioPlayer` and `WaveformLoader`, and hosts the export and rename sheets.

### `LibrarySidebar`
Search, filter chips (All / New / Analysed / Edited / Exported) with counts, and a row per song
showing thumbnail, title, secondary line and a state icon. Songs without a usable YouTube link stay
listed but dimmed. The footer shows backend reachability, tool status and the signed-in account, and
re-checks the environment on click.

### `FrontScreenView`
Shown when nothing is selected: "Continue" cards for edited/analysed/paused songs, a grid of
not-yet-analysed songs with per-song Analyse and an "Analyse all" that fills the queue, recent
exports, and an environment readiness card.

### `SongWorkspaceView`
Transport (play/pause, clock, BPM/time-signature/bar/section pills, waveform zoom, follow toggle),
then either the waveform or a status strip (running with cancel, audio-ready with resume, failed,
or not analysed), then the chart. A skeleton chart renders while a job runs so the layout never jumps.

### `WaveformView`
Canvas: section colour band, bar grid with numbers, waveform, detected-chord lane, playhead. Drag to
scrub. Theme-aware (the previous version painted a hardcoded black background in light mode).

### `ChordChartView`
Bars grouped by section, four per row. Each bar is split into chord segments whose widths are
proportional to how long each chord sounds, using the per-bar subdivision. Selecting a bar seeks and
opens an action popover (Split / Merge / Rename with S / M / R hints, plus a Subdivide picker).
Keys are handled with focus-scoped `.onKeyPress`, so they cannot swallow typing elsewhere.

### `InspectorView`
- **Bar** — selected bar, its section and position, detected chords with their share of the bar,
  subdivision, and the section actions.
- **Tuning** — detected/override BPM, halve tempo, pickup offset, beats per bar, Apply/Revert while a
  preview is pending, and beat re-detection with BPM-range and stable-tempo options.
- **Analysis** — the stage checklist with timings and messages, retry on the failing stage, resume
  when the backend was down, cancel while running, and the raw log behind a disclosure.
- **Info** — file metadata, audio health with warnings, analysis stats, environment readiness with
  per-tool paths and versions, and Reveal in Finder.

### `ExportSheet`
Target song and document ID, the tempo change, the current versus new section list, backend and
account status, and an explicit "Overwrite …" confirm.

---


## 8. Configuration and Environment

### Defaults

| Value | Location | Purpose |
|---|---|---|
| `"http://localhost:5051"` | `JobManager.backendBaseUrl` | Analysis backend, overridable (below). Both the pipeline and the export read this one property. |
| `"auto"` | `JobManager.defaultBeatModel` | Beat detection model name |
| `"chord-cnn-lstm"` | `JobManager.defaultChordModel` | Chord recognition model name |
| `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, `/usr/bin`, `/bin` + `$PATH` | `ToolChecker.searchDirectories` | Where the tools are looked for. The previous build only searched Apple-silicon Homebrew, so every tool read as missing on an Intel Mac. |

### Environment variables

| Variable | Read by | Purpose |
|---|---|---|
| `CHORDADMIN_BACKEND_URL` | `JobManager.backendBaseUrl` | Points the app at another analysis backend, matching ChordAdminBackend's own `CHORDADMIN_BACKEND_PORT`. |
| `CHORDADMIN_JOBS_DIR` | `LocalFileStore.supportDirectory` | Redirects job folders and the URL cache. Used by `Tools/verify.sh` so tests never touch real data. |

Both are read once at first use, so they must be set before launch (Xcode: Edit Scheme → Run → Environment Variables).

### Plist / config files
None beyond the standard Xcode-generated `Info.plist` inside the `.xcodeproj`.

### Build settings / schemes
One scheme visible: default scheme inferred from `.xcodeproj`. No explicit debug-only flags observed.

### Best place for a future `LALAL_LICENSE_KEY`

The natural location is in `JobManager.swift`, alongside the existing static configuration constants:

```swift
// JobManager.swift — MARK: Backend config
private static let backendBaseUrl    = "http://localhost:5051"
private static let defaultBeatModel  = "auto"
private static let defaultChordModel = "chord-cnn-lstm"

// ↓ Future addition
private static let lalalLicenseKey: String? =
    ProcessInfo.processInfo.environment["LALAL_LICENSE_KEY"]
    .flatMap { $0.isEmpty ? nil : $0 }
```

This makes `lalalLicenseKey` `nil` when unset (standard Swift optional), and reads from the process environment — which can be set in Xcode scheme environment variables (`Edit Scheme → Run → Environment Variables`) without touching source code.

---

## 9. Error Handling and Logging

### Stage-level reporting
Every stage ends in an explicit state — `done`, `warning(String)`, `skipped(String)` or
`failed(String)` — stored on the job as `stages: [StageRecord]` and shown as a checklist. A job that
produced no chart can no longer present itself as a plain success.

### Failure behaviour
- A thrown error fails **that stage** and stops the run, with the message on the stage row.
- `retry(from:)` resets that stage and everything after it and re-runs; stages before it keep their
  results, and anything from `.backend` onwards reuses the audio already on disk.
- Backend unreachable → `status = .audioReady`, later stages `skipped`, and a "Resume analysis"
  action. Nothing is re-downloaded.
- Non-2xx backend replies raise `JobError.backendRejected` instead of being written to the job folder
  as if they were results.
- Cancellation terminates the subprocess and cancels the request, keeping finished stages.
- An interrupted job found at launch is repaired during `hydrate()` rather than showing as running.

### Logging
`JobManager.logs[songID]` holds the per-song log, mirrored to `logs.txt` in the job folder. The log is
secondary: it lives behind a disclosure in the Analysis tab, with a Copy button.

---


## 10. Best Integration Point for LALAL.AI

### Where to insert

In `JobManager.startJob(url:)`, **between** the moment `analysis.wav` is confirmed written and the `let wavURL = URL(fileURLWithPath: wavPath)` assignment that feeds the backend calls.

The exact location in `JobManager.swift` is after these lines:

```swift
job.analysisWavPath = wavPath
persist(job)
log("Done. analysis.wav written to: \(wavPath)\n")
```

And **before** this section:

```swift
// — Check backend —
job.status = .checkingAnalysisBackend
...
let wavURL = URL(fileURLWithPath: wavPath)
```

### What the insertion would look like (do not implement yet)

```swift
// LALAL.AI pre-processing (future)
let effectiveWavPath: String
if let lalalKey = Self.lalalLicenseKey {
    // upload analysis.wav → receive instrumental.wav
    // effectiveWavPath = folder.appendingPathComponent("instrumental.wav").path
} else {
    effectiveWavPath = wavPath
}
let wavURL = URL(fileURLWithPath: effectiveWavPath)
```

### What the existing function currently receives

`wavURL` (a `URL` wrapping `wavPath`) is the value passed to **both** `postAudioFile` calls:
```swift
let beatData = try await Self.postAudioFile(
    to: "\(Self.backendBaseUrl)/api/detect-beats",
    fileURL: wavURL,   // ← this is what needs to switch
    params: ["model": Self.defaultBeatModel]
)

let chordData = try await Self.postAudioFile(
    to: "\(Self.backendBaseUrl)/api/recognize-chords",
    fileURL: wavURL,   // ← and this
    params: ["model": Self.defaultChordModel]
)
```

### What code would need to receive either file

Only `wavURL` needs to change. Both `postAudioFile` calls use it. Nothing downstream of those calls refers to a file path — they work with the `Data` responses. The LALAL step would produce `instrumental.wav` on disk, and `wavURL` would point to it instead of `analysis.wav`.

### What should not be touched

- `analysis.wav` creation (ffmpeg step) — always runs; `analysis.wav` is the LALAL input
- `job.analysisWavPath` — should continue to point to `analysis.wav`, not the instrumental
- All chart generation logic (`generateBeatGrid`, `generateChordChart`, `generatePerformerChart`, etc.) — pure Swift, unaffected
- `LocalFileStore`, `ProcessRunner`, `ToolChecker`, `SectionStore` — no changes needed
- `ContentView` — no changes needed
- `AnalysisJob` — may need one new optional field (`instrumentalWavPath`) but is not required for the core insertion

---

## 11. Risks and Unknowns

| Risk | Severity | Location | Detail |
|---|---|---|---|
| `generateBeatGrid` assumes a fixed beats-per-bar | Medium | `ChartGeneration.generateBeatGrid` | The user can override 2/3/4 per bar, but `estimatedTimeSignature` from the backend is still not used to pick a default. |
| Trailing partial bar | Low | `ChartGeneration.generateBeatGrid` | With a pickup offset the final bar can hold fewer beats than a full bar; it is charted anyway. |
| URL cache has no expiry | Low | `LocalFileStore` | Entries are only evicted when files vanish; a job with stale chord data is still reused. Re-analyse forces a fresh run. |
| Job folders are never pruned | Low | `LocalFileStore` | Audio and WAVs accumulate; there is no size cap or cleanup command. |
| No test target | Low | project | There is no XCTest target; pipeline logic is covered by an ad-hoc harness, not by CI. |
| Backend API contract is implicit | Low | `JobManager` parsers | Shapes are inferred from the parsers; no schema is checked in. |
| Export translation is trusted | Low | `StageBeeExportService` | The section payload is summarised for the diff but not schema-validated before writing. |

### Fixed in the redesign
- Job state is keyed by song document ID, and export refuses a job/song mismatch — the previous
  build could write one song's analysis onto another song's document.
- Backend calls validate HTTP status, have timeouts, and stream the upload from disk instead of
  holding the whole WAV in memory.
- Runs can be cancelled; a hung tool or request no longer wedges the app.
- Tools resolve through a search path (including Intel Homebrew) and are checked at launch.
- `sections.json` is no longer discarded when it holds a single section covering every bar.
- Section save failures surface instead of being swallowed.

---


## 12. Compact Summary

**ChordAdmin is** a native macOS SwiftUI app (single window, three columns) that downloads a YouTube
song, runs audio analysis, and produces a bar-by-bar chord chart with section labels which it can
write back to TheStageBee's Firestore `songs` collection. It is a developer/musician tool.

**The workflow is:** pick a song in the library → analyse (11-stage pipeline, shown as a checklist) →
correct beat alignment with a live preview → edit sections on the chart → export behind a
confirmation sheet that shows the diff.

**Job state** is keyed by the song's Firestore document ID. `AnalysisJob` carries `songDocumentID`,
`stages`, `barSubdivisions`, `lastEditedAt` and `lastExport`; older `job.json` files still decode,
and jobs predating per-song keying are adopted by YouTube video ID.

**The pipeline is:** yt-dlp download → ffmpeg WAV → ffprobe metadata → audio health → backend health
→ `POST /api/detect-beats` → beat grid (local) → `POST /api/recognize-chords` → chord chart draft
(local) → performer chart (local) → section candidates and sections (local).

**Export** posts the job folder to `POST /api/translate-to-stagebee`, previews the resulting tempo
and sections against the current document, and only then calls `updateData` on `songs/<id>`.

**On quit** `ChordAdminAppDelegate.applicationShouldTerminate` warns while a run is in flight, then calls
`JobManager.settleForTermination()` so the supersede decision is resolved on disk rather than left for the
next launch to infer. Hydration still defends itself: it prefers the more complete analysis over the newer
one, and sets aside — rather than sweeps — a losing folder that holds a chart.

**Section detection** turns *every* occurrence of a repeated passage into its own section, with the
repeats sharing the first one's name; "Intro"/"Outro" are reserved for material that does not recur.
Candidates whose first occurrence overlaps an accepted one are suppressed, so a song built on a single
loop no longer reports the same phrase once per rotation.

**Accessibility.** Chart bars are single elements with spoken labels (number, chords, section,
subdivision, playing/changed state) and a select action; the waveform is one adjustable element that
scrubs a bar at a time; runs announce their progress and outcome. Decorative artwork, key caps and
status dots are hidden from the tree, and the states they carried are said in the labels beside them.
**Type scales — but the app does the scaling itself.** macOS has no Dynamic Type: `@ScaledMetric` and
`.dynamicTypeSize()` compile and do nothing. Measured directly (`Tools/` probe, every size including
`.accessibility3`): `@ScaledMetric` returns the base value unchanged. So `DesignKit` carries a
`chordAdminTextScale` environment value and `TextScale.scaled(_:style:by:)` multiplies the point size;
`.scaledFont(size:weight:design:relativeTo:)` is the single call site for all ~180 fonts, and the three
Canvas labels (which take a `Font` value, not a modifier) go through the same function.
`TextSizeSetting` (`AppCommands.swift`) holds the multipliers, the View menu offers ⌘+ / ⌘- / ⌘0, and
`ContentView` applies it. `style` sets how strongly each size responds — small print gains more than
headings — with the emphases tuned so the ladder never collides: a test walks the app's real ladder at
every step and fails on any pair that meets or inverts. `type-scale.png` shows it.

**Note on the render harness:** it does NOT honour `.dynamicTypeSize()` — a plain `.font(.body)` renders
identically at `.large` and `.xxxLarge`. That is why the scaling had to be app-applied to be
verifiable at all. The end-to-end path is checked by rendering the real `ContentView` twice with
different values written to the `textSize` default (`contentview-scale-small/large.png`), which
exercises `@AppStorage` → `chordAdminTextScale` → every font. That check is what caught the sidebar's
empty-state message truncating: a `.sidebar` List row clips its content to one line however the width
is proposed, so the placeholder is an overlay on the List rather than a row in it.

**Known limits:** no XCTest target, no job-folder pruning, the beat grid does not auto-select a time
signature, and the translated export payload is not schema-validated.
