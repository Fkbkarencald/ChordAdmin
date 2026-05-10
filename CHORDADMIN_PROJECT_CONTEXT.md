# ChordAdmin Project Context

---

## 1. Project Overview

ChordAdmin is a **native macOS SwiftUI application** (minimum window 1100×520 pt) that takes a YouTube URL as input, downloads the audio, and runs a full audio analysis pipeline to produce a chord chart with section labels.

**App purpose:** Given a YouTube song URL, ChordAdmin produces a bar-by-bar chord chart that a musician can use as a performance reference. It detects tempo, beats, bar boundaries, chords, and repeating song sections.

**Main user workflow:**
1. User pastes a YouTube URL into the text field and clicks **Start**.
2. The app downloads the audio, converts it to mono WAV, runs ffprobe metadata extraction, and analyses audio health — all using local command-line tools.
3. The app calls a **locally-running Python backend** (port 5001) for beat detection and chord recognition.
4. All chart generation (beat grid, chord chart draft, performer chart, section candidates, sections) is performed **client-side in Swift**.
5. Results are displayed in a three-pane layout: left (job info/metadata), centre (chord chart + waveform), right (collapsible log).
6. The user can adjust the bar alignment offset (0–3), toggle half-tempo mode, and interactively edit section boundaries.

**Platform:** macOS only — uses `NSWorkspace`, `NSPasteboard`, `NSColor`, `AVAudioPlayer`, and `AVAudioFile`.

**Local backend:** Yes. A local Python server at `http://localhost:5001` is required for beat detection and chord recognition. If unavailable, the job completes with warnings and no chord/beat data is produced.

**Local files:** Each analysis job writes files to `~/Library/Application Support/ChordAdmin/jobs/<UUID>/`. A URL cache at `~/Library/Application Support/ChordAdmin/url_cache.json` maps previously-analysed URLs to their job folders, enabling instant replay.

---

## 2. Project Structure

```
ChordAdmin/
├── ChordAdmin/
│   ├── ChordAdminApp.swift          ← App entry point
│   ├── ContentView.swift            ← Entire UI (~1 200 lines)
│   ├── JobManager.swift             ← Core pipeline orchestrator (~1 500 lines)
│   ├── AnalysisJob.swift            ← All data models and enums
│   ├── LocalFileStore.swift         ← File I/O helpers
│   ├── ProcessRunner.swift          ← Async subprocess wrapper
│   ├── SectionStore.swift           ← Section state management
│   └── ToolChecker.swift            ← CLI tool availability check
├── CHORDADMIN_PROJECT_CONTEXT.md    ← This file
└── ChordAdmin.xcodeproj/
```

### File-by-file breakdown

| File | What it does | Why it matters |
|---|---|---|
| `ChordAdminApp.swift` | `@main` entry, creates a `WindowGroup` with `ContentView` | App lifecycle entry point |
| `ContentView.swift` | Full UI: URL input, three-pane bento layout, waveform viewer, chord chart, log panel, audio playback, section editing | All user interaction happens here |
| `JobManager.swift` | `@MainActor ObservableObject`; orchestrates the entire pipeline from URL input through download → convert → health → backend calls → chart generation | Heart of the app — contains all business logic |
| `AnalysisJob.swift` | `AnalysisJob` struct + all supporting types (`JobStatus`, `CleanedChord`, `ChordChartBarEntry`, `PerformerChartBarEntry`, `SectionCandidate`, etc.) | Data contract between pipeline, storage, and UI |
| `LocalFileStore.swift` | Creates job folders, writes `job.json`, appends `logs.txt`, manages `url_cache.json` | All filesystem operations |
| `ProcessRunner.swift` | Wraps `Foundation.Process` in `async/await` with streaming stdout+stderr | Used to run yt-dlp, ffmpeg, ffprobe |
| `SectionStore.swift` | `@MainActor ObservableObject`; loads, persists, splits, merges, and renames sections | Drives section-editing UI in chord chart pane |
| `ToolChecker.swift` | Probes `/opt/homebrew/bin/{yt-dlp,ffmpeg,ffprobe,deno}` with `--version` | Guards the pipeline before any download attempt |

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
GET http://localhost:5001/health
  → if 404 / error: job.status = .completedWithWarnings  ← pipeline ends here without charts
  → if 200: continue
↓
status = .detectingBeats
POST http://localhost:5001/api/detect-beats  (multipart; file=analysis.wav, model=auto)
  → writes beat.detection.json
  → populates job: bpm, beatCount, resolvedBeatModel
↓
status = .generatingBeatGrid  (client-side, no network)
generateBeatGrid(from: beat.detection.json, bpm:, barAlignmentOffset: 0)
  → writes beat.grid.json  { bpm, bars: [{bar, start, end, beats}], estimatedTimeSignature }
  → populates job: beatGridPath, barCount, estimatedTimeSignature
↓
status = .recognizingChords
POST http://localhost:5001/api/recognize-chords  (multipart; file=analysis.wav, model=chord-cnn-lstm)
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

**Base URL (hardcoded):** `http://localhost:5001`  
Location: `JobManager.swift`, line with `private static let backendBaseUrl = "http://localhost:5001"`

### Health check

```
GET http://localhost:5001/health
```
- Expected response: HTTP 200 (any body)
- If anything other than 200: job is marked `.completedWithWarnings` and the pipeline stops without charts.

### Beat detection

```
POST http://localhost:5001/api/detect-beats
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
POST http://localhost:5001/api/recognize-chords
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
| `errorMessage` | `String?` | Last error description |
| `barAlignmentOffset` | `Int?` | 0–3 beat pickup offset |
| `tempoHalved` | `Bool?` | Whether tempo-halving is active |
| `chartsVersion` | `Int?` | Incremented on each chart regeneration to trigger UI reload |

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

All UI is in a single file: `ChordAdmin/ContentView.swift`.

### Main window — `ContentView`

**Purpose:** The only window. Hosts the URL input and the three-pane bento layout.

**State:**
- `@StateObject jobManager: JobManager` — job state and pipeline control
- `@State urlInput: String` — URL text field
- `@State logCollapsed: Bool` — log pane toggle

**Actions:**
- **Start** button → `Task { await jobManager.startJob(url: urlInput) }`
- **Copy** (log) → `NSPasteboard.general.setString(jobManager.logOutput)`
- **Collapse/Expand log** → `logCollapsed` toggle

**Left pane** (`width: 280`): `BentoSection` cards for Status, Files, Metadata, Audio Health, Backend  
**Middle pane** (flexible): `ChordChartModeSwitcher` — only visible when `chordChartPreview` or `chordChartSimplePreview` or `chordChartSimplePath` is non-nil  
**Right pane** (flexible, collapsible): Log output with auto-scroll

---

### `StatusBadge`
Displays `job.status.displayName` as a coloured capsule pill. Colour per status defined in switch.

---

### `PathRow`
Displays a labelled file path with **Reveal** (Finder) and optionally **Play** (NSWorkspace open) buttons.

---

### `MetadataPanel`
Grid of: duration, sample rate, channels, codec, bit rate, file size — read from `AnalysisJob`.

---

### `AudioHealthPanel`
Grid of: mean/max volume dB, silence region count, total silence duration. Re-derives warnings from `AnalysisJob` fields (does not read `audio.health.json`).

---

### `BackendPanel`
Displays backend availability status, paths to beat/chord JSON files, chord preview list, section candidates preview, and analysis stats (BPM, beat count, bar count, chord count, models). Reads from `AnalysisJob`.

---

### `ChordChartModeSwitcher` (middle pane)
**Purpose:** Interactive chord chart display with audio playback, waveform, and section editing.

**State objects:**
- `@StateObject audioPlayer: ChordAudioPlayer` — AVAudioPlayer wrapper
- `@StateObject waveformLoader: WaveformLoader` — AVAudioFile sample extractor
- `@StateObject sectionStore: SectionStore` — section editing
- `@State localOffset: Int` — bar alignment offset

**Actions:**
- **Play/Pause** → `audioPlayer.togglePlayPause()`
- **Bar offset buttons (0–3)** → `jobManager.regenerateCharts(offset: i)`
- **½ BPM toggle** → `jobManager.halveTempo(!isHalved)`
- **Waveform zoom** → `waveZoom` state
- **Follow playhead toggle** → `waveFollowPlayhead`
- **Waveform seek** → `audioPlayer.seek(to:)`

**Loads on `task(id:)` change (new job or `chartsVersion` bump):**
- Performer chart bars from `chord.chart.performer.json`
- Draft chart bars from `chord.chart.draft.json`
- Raw chords from `chord.cleaned.json`
- Sections via `sectionStore.load(for:jobFolder:)`
- Audio via `audioPlayer.load(path:)` + `waveformLoader.load(path:)`

---

### `WaveformView`
Canvas-drawn waveform. Draws: background, alternating bar shading, bar boundary lines, amplitude bars, raw chord overlay (cyan/mint with labels), red playhead. Handles `DragGesture` for seek.

---

### `ChordProgressionView` (defined in ContentView.swift, not shown in excerpt)
Displays the performer chart bars grouped by section. Allows section split/merge/rename. Reads `sectionStore.sections`. Calls `sectionStore.startNewSection`, `mergeSectionWithPrevious`, `rename`. Calls `onSeek` to seek audio on bar tap.

---

### `ChordAudioPlayer`
`@MainActor` `NSObject` wrapping `AVAudioPlayer`. Published: `currentTime`, `isPlaying`, `duration`, `isLoaded`. 0.1 s update timer. Implements `AVAudioPlayerDelegate` to reset at end.

---

### `WaveformLoader`
`@MainActor` `ObservableObject`. Loads audio via `AVAudioFile` in a detached `Task`, extracts 1 800 peak-amplitude samples for waveform rendering.

---

### `SectionStore` (SectionStore.swift)
`@MainActor` `ObservableObject`. Manages `[ChordSection]`. On `load(for:jobFolder:)`:
- Reads `sections.json`; skips if it's a single section covering all bars (treats as default)
- Falls back to building sections from `section.candidates.json`
- Falls back to a single "Intro" section

Persists to `sections.json` after every mutation.

---

## 8. Configuration and Environment

### Hardcoded values

| Value | Location | Purpose |
|---|---|---|
| `"http://localhost:5001"` | `JobManager.swift`, `private static let backendBaseUrl` | Local backend base URL |
| `"auto"` | `JobManager.swift`, `private static let defaultBeatModel` | Beat detection model name |
| `"chord-cnn-lstm"` | `JobManager.swift`, `private static let defaultChordModel` | Chord recognition model name |
| `"/opt/homebrew/bin/yt-dlp"` | `ToolChecker.swift` | yt-dlp path (Homebrew Apple Silicon) |
| `"/opt/homebrew/bin/ffmpeg"` | `ToolChecker.swift` | ffmpeg path |
| `"/opt/homebrew/bin/ffprobe"` | `ToolChecker.swift` | ffprobe path |
| `"/opt/homebrew/bin/deno"` | `ToolChecker.swift` | deno path (yt-dlp JS runtime) |

### Environment variables
None. No `ProcessInfo.processInfo.environment` lookups anywhere in the codebase.

### Plist / config files
None beyond the standard Xcode-generated `Info.plist` inside the `.xcodeproj`.

### Build settings / schemes
One scheme visible: default scheme inferred from `.xcodeproj`. No explicit debug-only flags observed.

### Best place for a future `LALAL_LICENSE_KEY`

The natural location is in `JobManager.swift`, alongside the existing static configuration constants:

```swift
// JobManager.swift — MARK: Backend config
private static let backendBaseUrl    = "http://localhost:5001"
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

### Log writing
- **In-memory:** `JobManager.logOutput: String` — appended via `log(_ text: String)`. Displayed in real-time in the right-pane `ScrollView`, auto-scrolling on change.
- **On-disk:** `LocalFileStore.appendLog` writes the same text to `logs.txt` in the job folder using `FileHandle.seekToEndOfFile`. Written after every `log()` call.

### Log visibility
The log pane in the UI is always present (collapsible). A **Copy** button copies the full log to the clipboard.

### Failed jobs
- Fatal errors (yt-dlp, ffmpeg, ffprobe, tool check) throw `JobError`, caught in `startJob`'s `catch` block: `job.status = .failed`, `job.errorMessage = error.localizedDescription`, persisted to `job.json`.
- `job.errorMessage` is shown below the `StatusBadge` in red.

### Backend failures
- Backend unavailable → `job.status = .completedWithWarnings`, `job.backendErrorMessage` set, shown in `BackendPanel` with a warning icon.
- Beat detection fails → logged as `"Beat detection failed: …"`, pipeline continues to chord recognition (non-fatal, no `JobError` thrown).
- Chord recognition fails → logged as `"Chord recognition failed: …"`, pipeline continues to chart generation (non-fatal).

### Audio conversion failures
- Thrown as `JobError.conversionFailed` → job status = `.failed`.

### Audio health warnings
Derived from `AnalysisJob` fields at display time (`AudioHealthPanel.derivedWarnings`):
- `maxVolumeDb > -0.5 dB` → "Possible clipping or very hot master"
- `meanVolumeDb < -35 dB` → "Very quiet audio"
- `totalSilence / duration > 0.2` → "Large silent sections detected"

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
| No URLSession timeout | High | `JobManager.postAudioFile`, `checkBackendHealth` | `URLSession.shared.data(for:)` with no timeout policy. If backend hangs, the app hangs indefinitely with no user-visible indication. |
| Entire WAV loaded into RAM | High | `JobManager.postAudioFile` | `let fileData = try Data(contentsOf: fileURL)` reads the full WAV before upload. A 10-min 44.1 kHz mono WAV ≈ 50 MB. Long tracks risk high memory pressure. |
| Hardcoded Homebrew paths | Medium | `ToolChecker.swift` | `/opt/homebrew/bin/` is correct for Apple Silicon Homebrew only. Intel Macs use `/usr/local/bin/`. The app will report all tools missing on Intel. |
| No retry logic | Medium | `JobManager` backend calls | One network error aborts the step with a log message. Transient backend errors are permanent failures. |
| ProcessRunner merges stdout+stderr | Medium | `ProcessRunner.swift` | Both pipes feed into `accumulated`. ffprobe relies on `-v quiet` to suppress stderr — if ffprobe emits any stderr, the JSON parse of `metaResult.output` will fail. |
| `generateBeatGrid` always assumes 4/4 | Medium | `JobManager.generateBeatGrid` | `beatsPerBar = 4` is hardcoded. The backend may return and the file stores `estimatedTimeSignature` but the grid builder ignores it. Songs in 3/4, 6/8, or 5/4 will produce misaligned bars. |
| URL cache has no expiry | Low | `LocalFileStore` | Cache entries are evicted only if `analysis.wav` or `job.json` are missing. A completed job with stale chord data (e.g. after a model upgrade) will always be served from cache. |
| `chord.chart.simple.json` is never generated | Low | `JobManager.swift` / `AnalysisJob.swift` | `chordChartSimplePath`, `chordChartSimpleBarCount`, `chordChartSimplePreview`, and the `generatingSimpleChart` status exist but are never written. The middle pane condition checks `chordChartSimplePath` — it will never be true. This is dead code. |
| No test suite | Low | Entire project | Zero unit or integration tests. Pipeline correctness is entirely manual. |
| Backend API contract is implicit | Low | `JobManager` response parsers | The expected JSON shapes are inferred from `parseBeatResponse` and `parseChordResponse` only. No schema, no OpenAPI spec in this repo. |
| `SectionStore.load` is synchronous on MainActor | Low | `SectionStore.swift` | Reads `sections.json` and `section.candidates.json` synchronously on the main thread. For very large charts this could cause a frame drop. |
| No `ASSUMPTION` — backend `cached` flag | Informational | `JobManager` | The backend can return `"cached": true`. The app logs this but does not expose any cache-invalidation mechanism. |

---

## 12. Compact Summary for ChatGPT

### ChordAdmin Context Summary

**ChordAdmin is** a native macOS SwiftUI app (macOS only, single window) that downloads a YouTube song, runs audio analysis, and produces a bar-by-bar chord chart with section labels. It is a developer/musician tool, not a consumer app.

**The main workflow is:**
1. User pastes a YouTube URL and clicks Start.
2. App downloads audio with yt-dlp, converts to mono 44.1 kHz WAV with ffmpeg.
3. App extracts metadata with ffprobe and runs audio health checks.
4. App checks a locally-running Python backend at `http://localhost:5001`.
5. Backend performs beat detection (`/api/detect-beats`) and chord recognition (`/api/recognize-chords`) — both receive `analysis.wav` as a multipart upload.
6. All chart generation (beat grid, chord chart draft, performer chart, section candidates, sections) is done client-side in Swift.
7. Results display in a three-pane layout: job info left, chord chart + waveform centre, log right.

**Important files are:**
- `ChordAdmin/JobManager.swift` — pipeline orchestrator, all business logic, backend calls, chart generation (~1 500 lines)
- `ChordAdmin/AnalysisJob.swift` — all Swift data models (`AnalysisJob`, `JobStatus`, `CleanedChord`, `ChordChartBarEntry`, `PerformerChartBarEntry`, `SectionCandidate`, etc.)
- `ChordAdmin/ContentView.swift` — entire UI including waveform, chord chart, audio player, section editor (~1 200 lines)
- `ChordAdmin/LocalFileStore.swift` — job folder I/O, URL cache
- `ChordAdmin/ToolChecker.swift` — checks for yt-dlp, ffmpeg, ffprobe, deno at `/opt/homebrew/bin/`
- `ChordAdmin/ProcessRunner.swift` — async subprocess wrapper
- `ChordAdmin/SectionStore.swift` — section state and persistence

**The current audio pipeline is:**
URL → yt-dlp download → ffmpeg → `analysis.wav` (mono, 44.1 kHz) → ffprobe metadata → audio health → `POST /api/detect-beats` → `beat.detection.json` → beat grid (client) → `POST /api/recognize-chords` → `chord.cleaned.json` → chord chart draft (client) → performer chart (client) → section candidates (client) → sections (client).

**The job folder contains** (at `~/Library/Application Support/ChordAdmin/jobs/<UUID>/`): `source.info.json`, `audio.original.<ext>`, `analysis.wav`, `metadata.json`, `audio.health.json`, `job.json`, `logs.txt`, `beat.detection.json`, `beat.grid.json`, `chord.recognition.json`, `chord.cleaned.json`, `chord.chart.draft.json`, `chart.config.json`, `chord.chart.performer.json`, `section.candidates.json`, `sections.json`.

**The backend integration works by** making two multipart `POST` requests from `JobManager.postAudioFile` — one to `/api/detect-beats` (model: `"auto"`) and one to `/api/recognize-chords` (model: `"chord-cnn-lstm"`) — each sending the full `analysis.wav` binary. The base URL `http://localhost:5001` is hardcoded in `JobManager.swift`. No timeout, no retry. The backend is expected to run locally.

**The best place to add LALAL.AI is** in `JobManager.startJob(url:)`, immediately after `analysis.wav` is written and `job.analysisWavPath` is set, and before the `let wavURL = URL(fileURLWithPath: wavPath)` line that feeds both backend calls. The pattern would be: if `LALAL_LICENSE_KEY` env var is set, upload `analysis.wav` to LALAL.AI, save the returned `instrumental.wav` to the job folder, and set `wavURL` to point to `instrumental.wav` instead. The `LALAL_LICENSE_KEY` should be read via `ProcessInfo.processInfo.environment["LALAL_LICENSE_KEY"]` and stored as `private static let lalalLicenseKey: String?` alongside the existing `backendBaseUrl` constant.

**Known risks/unknowns are:** no URLSession timeout (backend hang = app hang), entire WAV loaded into RAM for upload (large file risk), all tool paths hardcoded to `/opt/homebrew/bin/` (Intel Mac incompatible), no retry on backend errors, `generateBeatGrid` always assumes 4/4 time, URL cache has no expiry, `chord.chart.simple.json` path is dead code (never generated), no test suite, backend API contract is implicit (inferred from parsers only).
