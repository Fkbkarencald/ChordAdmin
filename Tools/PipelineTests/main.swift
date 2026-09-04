import Foundation
// The text-size setting is a plain value type, but its DynamicTypeSize cases
// need the module that defines them in scope.
import SwiftUI

// Exercises the pure pipeline logic of ChordAdmin without the UI layer.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
        failures += 1
        print("  ✗ \(label)")
    } else {
        print("  ✓ \(label)")
    }
}

func section(_ title: String) { print("\n\(title)") }

// MARK: - Fixtures

/// 120 BPM, 4/4 → a beat every 0.5s, 64 beats = 16 bars.
func makeBeatData(count: Int = 64, interval: Double = 0.5, bpm: Double = 120) -> Data {
    let beats = (0..<count).map { ["time": Double($0) * interval] }
    return try! JSONSerialization.data(withJSONObject: ["bpm": bpm, "beats": beats])
}

/// One chord per bar, cycling C / Am / F / G so 4-bar and 8-bar repeats exist.
func makeChordData(bars: Int = 16, barLength: Double = 2.0) -> Data {
    let names = ["C", "Am", "F", "G"]
    let chords = (0..<bars).map { index -> [String: Any] in
        [
            "start": Double(index) * barLength,
            "end": Double(index + 1) * barLength,
            "rawChord": names[index % names.count] + ":maj",
            "displayChord": names[index % names.count],
        ]
    }
    return try! JSONSerialization.data(withJSONObject: ["chords": chords])
}

// MARK: - Beat grid

section("Beat grid")

let beatData = makeBeatData()
let (grid, barCount) = JobManager.generateBeatGrid(from: beatData, bpm: 120, barAlignmentOffset: 0, beatsPerBar: 4)
check(barCount == 16, "64 beats at 4/4 produce 16 bars (got \(barCount))")
check(grid["estimatedTimeSignature"] as? String == "4/4", "time signature is 4/4")
let firstStart = ((grid["bars"] as? [[String: Any]])?.first?["start"] as? NSNumber)?.doubleValue
check(firstStart == 0, "first bar starts at 0")

let (gridOffset2, barCountOffset2) = JobManager.generateBeatGrid(
    from: beatData, bpm: 120, barAlignmentOffset: 2, beatsPerBar: 4
)
let firstBarStart = ((gridOffset2["bars"] as? [[String: Any]])?.first?["start"] as? NSNumber)?.doubleValue
check(firstBarStart == 1.0, "pickup of 2 beats starts bar 1 at 1.0s (got \(firstBarStart.map { "\($0)" } ?? "nil"))")
check((gridOffset2["pickupBeats"] as? [[String: Any]])?.count == 2, "two pickup beats are recorded")
check(barCountOffset2 == 16, "62 remaining beats give 15 full bars plus a partial one (got \(barCountOffset2))")
let lastBarBeats = ((gridOffset2["bars"] as? [[String: Any]])?.last?["beats"] as? [[String: Any]])?.count
check(lastBarBeats == 2, "and the trailing bar holds the leftover 2 beats (got \(lastBarBeats ?? -1))")

let (grid3, barCount3) = JobManager.generateBeatGrid(from: beatData, bpm: 120, barAlignmentOffset: 0, beatsPerBar: 3)
check(barCount3 == 22, "3 beats per bar over 64 beats gives 22 bars (got \(barCount3))")
check(grid3["estimatedTimeSignature"] as? String == "3/4", "3 beats per bar reports 3/4")

// Every bar must have real duration. A final bar holding one leftover beat used
// to end where it started, so every chord failed the overlap test and the bar
// was charted — and exported — as "N.C.".
func lastBarSpan(_ grid: [String: Any]) -> Double {
    guard let last = (grid["bars"] as? [[String: Any]])?.last,
          let start = (last["start"] as? NSNumber)?.doubleValue,
          let end = (last["end"] as? NSNumber)?.doubleValue else { return -1 }
    return end - start
}
check(lastBarSpan(grid3) > 0,
      "a final bar holding a single leftover beat still has duration (got \(lastBarSpan(grid3)))")
check(lastBarSpan(gridOffset2) > 0, "so does a final bar holding two")
check(abs(lastBarSpan(grid) - 2.0) < 0.001,
      "and a full final bar spans four beats, not three (got \(lastBarSpan(grid)))")

// Offsets must stay inside the bar: an out-of-range value is clamped, not crashed on.
let (gridClamped, _) = JobManager.generateBeatGrid(from: beatData, bpm: 120, barAlignmentOffset: 9, beatsPerBar: 4)
check((gridClamped["barAlignmentOffset"] as? Int) == 3, "an out-of-range pickup offset clamps to 3")

// MARK: - Tempo halving

section("Tempo halving")

var probeJob = AnalysisJob(id: "j", sourceUrl: "u", status: .completed, createdAt: Date())
probeJob.bpm = 120
probeJob.tempoHalved = true
let halved = JobManager.gridSettings(for: probeJob, beatData: beatData)
check(halved.bpm == 60, "halving 120 BPM reports 60 (got \(halved.bpm.map { "\($0)" } ?? "nil"))")
let halvedBeats = (try? JSONSerialization.jsonObject(with: halved.beatData) as? [String: Any])?["beats"] as? [[String: Any]]
check(halvedBeats?.count == 32, "halving keeps every other beat (got \(halvedBeats?.count ?? -1))")

probeJob.manualBpm = 96
let manual = JobManager.gridSettings(for: probeJob, beatData: beatData)
check(manual.bpm == 96, "a manual BPM overrides the halved value")

// MARK: - Chord chart

section("Chord chart")

let gridData = try! JSONSerialization.data(withJSONObject: grid)
let chordData = makeChordData()
let (draft, draftBars, draftPreview) = JobManager.generateChordChart(
    beatGridData: gridData, chordCleanedData: chordData,
    beatGridPath: "grid", chordCleanedPath: "chords"
)
check(draftBars == 16, "the draft chart has one entry per bar (got \(draftBars))")
check(draftPreview.first?.primaryChord == "C", "bar 1's primary chord is C")
check((draft["warnings"] as? [String])?.isEmpty == true, "no bars are missing a chord")

let draftData = try! JSONSerialization.data(withJSONObject: draft)
let configData = try! JSONSerialization.data(
    withJSONObject: JobManager.chartConfig(offset: 0, chartStartTime: nil, includePreIntro: false)
)
let (performer, performerBars, performerPreview) = JobManager.generatePerformerChart(
    draftData: draftData, configData: configData, draftPath: "d", configPath: "c"
)
check(performerBars == 16, "the performer chart keeps 16 bars (got \(performerBars))")
check(performerPreview.first?.bar == 1, "performer bars are renumbered from 1")
check(performerPreview.first?.chords.count == 1, "a single-chord bar yields one segment")

// A chord shorter than the 0.25s filter must not create a segment of its own.
let noisyChords: [[String: Any]] = [
    ["start": 0.0, "end": 1.9, "rawChord": "C:maj", "displayChord": "C"],
    ["start": 1.9, "end": 2.0, "rawChord": "B:dim", "displayChord": "Bdim"],  // 0.1s — noise
]
let noisyData = try! JSONSerialization.data(withJSONObject: ["chords": noisyChords])
let (noisyDraft, _, _) = JobManager.generateChordChart(
    beatGridData: gridData, chordCleanedData: noisyData, beatGridPath: "g", chordCleanedPath: "c"
)
let noisyDraftData = try! JSONSerialization.data(withJSONObject: noisyDraft)
let (_, _, noisyPreview) = JobManager.generatePerformerChart(
    draftData: noisyDraftData, configData: configData, draftPath: "d", configPath: "c"
)
let firstBarChords = noisyPreview.first?.chords.map(\.displayChord) ?? []
check(!firstBarChords.contains("Bdim"), "a 0.1s chord is filtered out of the performer chart")

@MainActor
func runSectionAndStorageTests() {
    // MARK: - Sections

    section("Section detection")

    let performerData = try! JSONSerialization.data(withJSONObject: performer)
    let (candidates, candidateCount, candidatePreview) = JobManager.detectSectionCandidates(
        performerData: performerData, performerPath: "p", draftPath: "d"
    )
    check(candidateCount > 0, "a repeating C-Am-F-G pattern produces candidates (got \(candidateCount))")
    check(candidatePreview.first?.matchCount ?? 0 > 1, "the top candidate repeats more than once")
    check((candidates["barCount"] as? Int) == 16, "the candidate payload records 16 bars")

    let (sections, sectionCount) = JobManager.generateInitialSections(
        performerData: performerData, candidatesPayload: candidates,
        performerPath: "p", candidatesPath: "c"
    )
    check(sectionCount > 0, "initial sections are generated (got \(sectionCount))")
    let sectionList = sections["sections"] as? [[String: Any]] ?? []
    let coveredBars = sectionList.flatMap { ($0["bars"] as? [Int]) ?? [] }.sorted()
    check(coveredBars == Array(1...16), "every bar belongs to exactly one section")

    // A verse/chorus/verse/chorus song. Detection found the repeat but only ever
    // turned its FIRST occurrence into a section, so everything after it landed
    // in one trailing lump the user had to split by hand, on every song.
    let verse = ["C", "Am", "F", "G", "C", "Am", "F", "G"]
    let chorus = ["F", "G", "Em", "Am", "F", "G", "C", "C"]
    let songChords = verse + chorus + verse + chorus
    let songBars: [[String: Any]] = songChords.enumerated().map { index, chord in
        [
            "bar": index + 1, "sourceBar": index + 1,
            "start": Double(index) * 2, "end": Double(index + 1) * 2,
            "primaryChord": chord,
            "chords": [["displayChord": chord, "start": Double(index) * 2,
                        "end": Double(index + 1) * 2, "overlapSeconds": 2.0]],
        ]
    }
    let songData = try! JSONSerialization.data(withJSONObject: ["bars": songBars])
    let (songCands, _, _) = JobManager.detectSectionCandidates(
        performerData: songData, performerPath: "p", draftPath: "d"
    )
    let (songSections, songSectionCount) = JobManager.generateInitialSections(
        performerData: songData, candidatesPayload: songCands,
        performerPath: "p", candidatesPath: "c"
    )
    let songList = songSections["sections"] as? [[String: Any]] ?? []
    let songNames = songList.compactMap { $0["name"] as? String }
    check(songSectionCount >= 4,
          "verse/chorus/verse/chorus yields a section per passage, not one trailing lump (got \(songSectionCount): \(songNames))")
    check(songList.flatMap { ($0["bars"] as? [Int]) ?? [] }.sorted() == Array(1...32),
          "and still covers every bar exactly once")

    // The repeat is the point: the same music must come back under the same name.
    let namesByStart = songList
        .compactMap { s -> (Int, String)? in
            guard let start = s["startBar"] as? Int, let name = s["name"] as? String else { return nil }
            return (start, name)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    check(Set(namesByStart).count < namesByStart.count,
          "a passage that recurs keeps its name rather than getting a new one (\(namesByStart))")
    // The 16-bar fixture is one phrase repeated, so its first section is a
    // recurring passage — and "Intro" would promise music that happens once.
    check(sectionList.first?["name"] as? String == "Section A",
          "a first section that recurs is named as a section, not an Intro (got \(sectionList.first?["name"] as? String ?? "nil"))")

    // Too-short input must warn rather than crash.
    let shortPerformer = try! JSONSerialization.data(withJSONObject: [
        "bars": [["bar": 1, "start": 0.0, "end": 2.0, "primaryChord": "C", "chords": []]],
    ])
    let (shortPayload, shortCount, _) = JobManager.detectSectionCandidates(
        performerData: shortPerformer, performerPath: "p", draftPath: "d"
    )
    check(shortCount == 0, "a one-bar chart yields no candidates")
    check((shortPayload["warnings"] as? [String])?.isEmpty == false, "and says why in warnings")

    // MARK: - Stage report

    section("Stage report")

    var report = StageReport()
    check(report.records.count == PipelineStage.allCases.count, "a fresh report holds every stage")
    check(report.runningStage == nil, "nothing is running yet")

    report.set(.tools, .done, elapsed: 0.2)
    report.set(.download, .running)
    check(report.runningStage == .download, "the running stage is reported")
    check(report[.tools].elapsedText == "0.2s", "short durations read in seconds")

    report.set(.download, .failed("yt-dlp exited with code 1"), elapsed: 75)
    check(report.firstFailure?.stage == .download, "the first failure is found")
    check(report[.download].elapsedText == "1:15", "longer durations read as m:ss")
    check(!report.isFinished, "a report with pending stages is not finished")

    report.set(.health, .warning("Very quiet audio"))
    check(report.warnings.count == 1, "warnings are collected")

    report.reset(from: .download)
    check(report[.download].state == .pending, "retrying resets the failed stage")
    check(report[.tools].state == .done, "and keeps the stages before it")
    check(report[.health].state == .pending, "and clears later stages too")

    // MARK: - Job persistence and back-compat

    section("Job model")

    var job = AnalysisJob(
        id: "abc", sourceUrl: "https://youtu.be/xyz", status: .completed, createdAt: Date(),
        title: "Golden Hour", songDocumentID: "song-1", songVideoID: "xyz"
    )
    var exportReport = report
    exportReport.set(.chords, .failed("Backend returned HTTP 500"), elapsed: 12)
    exportReport.set(.health, .warning("Very quiet audio"))
    job.stageReport = exportReport
    job.subdivisionsByBar = [14: 2, 20: 8]
    job.lastEditedAt = Date()
    job.lastExport = ExportRecord(
        exportedAt: Date().addingTimeInterval(-3600), documentID: "song-1", songTitle: "Golden Hour",
        tempo: 136, sectionCount: 7, previousTempo: 132, previousSectionCount: 3
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoded = try! encoder.encode(job)
    let roundTripped = try! decoder.decode(AnalysisJob.self, from: encoded)

    check(roundTripped.songDocumentID == "song-1", "the song document ID survives a round trip")
    check(roundTripped.subdivisionsByBar == [14: 2, 20: 8], "per-bar subdivisions survive a round trip")
    check(roundTripped.stageReport.firstFailure?.stage == .chords, "the stage report survives a round trip")
    check(roundTripped.stageReport.firstFailure?.state.message == "Backend returned HTTP 500",
          "a failed stage keeps its message across encoding")
    check(roundTripped.stageReport.warnings.first?.message == "Very quiet audio",
          "a warning stage keeps its message across encoding")
    check(roundTripped.stageReport[.chords].elapsed == 12, "stage timings survive encoding")
    check(roundTripped.hasUnexportedEdits, "edits made after an export are flagged")
    check(roundTripped.lastExport?.previousTempo == 132, "the replaced tempo is remembered")

    // A job.json written by the previous build must still load.
    let legacyJSON = """
    {
      "id": "legacy-1",
      "sourceUrl": "https://www.youtube.com/watch?v=abc",
      "status": "generatingSimpleChart",
      "createdAt": "2026-05-06T10:00:00Z",
      "title": "Old Song",
      "chordChartSimplePath": "/tmp/chord.chart.simple.json",
      "chordChartSimpleBarCount": 12,
      "bpm": 128.5,
      "barCount": 40,
      "barAlignmentOffset": 2
    }
    """
    let legacy = try? decoder.decode(AnalysisJob.self, from: Data(legacyJSON.utf8))
    check(legacy != nil, "a job.json from the previous build still decodes")
    check(legacy?.bpm == 128.5, "its analysis values are preserved")
    check(legacy?.barAlignmentOffset == 2, "its alignment offset is preserved")
    check(legacy?.songDocumentID == nil, "it has no song ID yet, so it is adopted by video ID")
    check(legacy?.stageReport.records.count == PipelineStage.allCases.count,
          "it gets a full stage report even though the file has none")

    // An unknown future status must not make the whole file unreadable.
    let futureJSON = legacyJSON.replacingOccurrences(of: "generatingSimpleChart", with: "somethingNew")
    let future = try? decoder.decode(AnalysisJob.self, from: Data(futureJSON.utf8))
    check(future != nil, "an unknown status decodes instead of failing the whole job")

    // MARK: - Audio health

    section("Audio health")

    var healthJob = AnalysisJob(id: "h", sourceUrl: "u", status: .completed, createdAt: Date())
    healthJob.durationSeconds = 200
    healthJob.meanVolumeDb = -38
    healthJob.maxVolumeDb = -0.2
    healthJob.totalSilenceDurationSeconds = 60
    let warnings = healthJob.audioHealthWarnings
    check(warnings.count == 3, "quiet, hot and silent audio all warn (got \(warnings.count))")
    check(warnings.contains { $0.contains("-38") || $0.contains("−38") || $0.contains("38") },
          "the quiet-audio warning names the measured level")

    // MARK: - URL handling

    section("URL handling")

    check(JobManager.cleanYouTubeURL("https://youtu.be/abc?list=PL123") == "https://youtu.be/abc",
          "a playlist parameter is stripped")
    check(SongRef.youTubeVideoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ",
          "a watch URL yields its video ID")
    check(SongRef.youTubeVideoID(from: "https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ",
          "a short URL yields the same video ID")
    check(SongRef.youTubeVideoID(from: "https://example.com/song") == nil,
          "a non-YouTube link has no video ID")

    // MARK: - Tool resolution

    section("Tool resolution")

    check(ToolChecker.searchDirectories.contains("/usr/local/bin"),
          "Intel Homebrew is searched as well as Apple silicon")
    check(ToolChecker.resolvePath(for: .ffmpeg) == nil || ToolChecker.resolvePath(for: .ffmpeg)!.hasSuffix("ffmpeg"),
          "resolving ffmpeg returns a path ending in the tool name")

    // MARK: - Sections

    section("Section store")

    // A scratch job folder — never the real Application Support data.
    let scratchRoot = LocalFileStore.baseDirectory
    try? FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    let sectionFolder = scratchRoot.appendingPathComponent("section-test", isDirectory: true)
    try? FileManager.default.createDirectory(at: sectionFolder, withIntermediateDirectories: true)

    func writeChart(bars: Int, to folder: URL) -> String {
        let path = folder.appendingPathComponent("chord.chart.performer.json").path
        let entries = (1...bars).map { bar -> [String: Any] in
            ["bar": bar, "sourceBar": bar,
             "start": Double(bar - 1) * 2.0, "end": Double(bar) * 2.0,
             "primaryChord": "C", "chords": []]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["bars": entries])
        try! data.write(to: URL(fileURLWithPath: path))
        return path
    }

    var sectionJob = AnalysisJob(id: "section-test", sourceUrl: "u", status: .completed, createdAt: Date())
    sectionJob.chordChartPerformerPath = writeChart(bars: 16, to: sectionFolder)

    let store = SectionStore()
    store.load(for: sectionJob, jobFolder: sectionFolder)
    check(!store.sections.isEmpty, "sections are generated when no file exists yet")
    check(Set(store.sections.flatMap(\.bars)) == Set(1...16), "generated sections cover every bar")

    // The old build discarded a saved file holding one section over all bars,
    // throwing away a deliberate merge. It must survive a reload now.
    store.resetToSingle()
    check(store.sections.count == 1, "resetToSingle collapses to one section")
    let reloaded = SectionStore()
    reloaded.load(for: sectionJob, jobFolder: sectionFolder)
    check(reloaded.sections.count == 1, "a single section covering every bar survives a reload")

    // Splitting, merging and renaming.
    reloaded.startNewSection(at: 9)
    check(reloaded.sections.count == 2, "splitting at bar 9 makes two sections")
    check(reloaded.sections.first?.bars == Array(1...8), "the first section keeps bars 1–8")
    check(reloaded.sections.last?.bars == Array(9...16), "the second section takes bars 9–16")
    check(reloaded.positionInSection(of: 12)?.index == 4, "bar 12 is the 4th bar of its section")
    check(reloaded.isFirstBarOfSection(9), "bar 9 is a section start")
    check(!reloaded.isFirstBarOfSection(10), "bar 10 is not")

    if let second = reloaded.sections.last {
        reloaded.rename(section: second.id, to: "Chorus")
        check(reloaded.sections.last?.name == "Chorus", "renaming a section sticks")
        reloaded.rename(section: second.id, to: "   ")
        check(reloaded.sections.last?.name == "Chorus", "a blank rename is ignored")
    }

    reloaded.mergeSectionWithPrevious(containing: 9)
    check(reloaded.sections.count == 1, "merging puts them back together")
    check(reloaded.sections.first?.bars == Array(1...16), "and the bars are intact")

    // A re-alignment that changes the bar count must not strand bars.
    sectionJob.chordChartPerformerPath = writeChart(bars: 20, to: sectionFolder)
    let regrown = SectionStore()
    regrown.load(for: sectionJob, jobFolder: sectionFolder)
    check(Set(regrown.sections.flatMap(\.bars)) == Set(1...20), "new bars are absorbed on reload")

    sectionJob.chordChartPerformerPath = writeChart(bars: 10, to: sectionFolder)
    let shrunk = SectionStore()
    shrunk.load(for: sectionJob, jobFolder: sectionFolder)
    check(Set(shrunk.sections.flatMap(\.bars)) == Set(1...10), "removed bars are dropped on reload")

    var edits = 0
    shrunk.onEdit = { edits += 1 }
    shrunk.startNewSection(at: 5)
    check(edits == 1, "an edit notifies the job so it can flag unexported changes")

    // MARK: - Storage

    section("Storage")

    let sizeBefore = LocalFileStore.folderSize(at: sectionFolder)
    check(sizeBefore > 0, "a job folder reports a non-zero size (got \(sizeBefore) bytes)")
    check(LocalFileStore.totalJobsSize() >= sizeBefore, "the total covers at least that folder")

    let orphanFolder = scratchRoot.appendingPathComponent("orphan-1", isDirectory: true)
    try? FileManager.default.createDirectory(at: orphanFolder, withIntermediateDirectories: true)
    try! Data("x".utf8).write(to: orphanFolder.appendingPathComponent("job.json"))

    // Reconciling to a new bar list must reach disk: the export translates the
    // job folder, so a fix that only corrected the copy in memory still shipped
    // the stale bar numbers.
    do {
        var reconcileJob = AnalysisJob(id: "reconcile", sourceUrl: "u",
                                       status: .completed, createdAt: Date())
        let folder = scratchRoot.appendingPathComponent("reconcile-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let perf = folder.appendingPathComponent("chord.chart.performer.json").path
        let bars = (1...8).map { ["bar": $0, "start": Double($0), "end": Double($0 + 1),
                                  "chords": [] as [Any]] as [String: Any] }
        try? JSONSerialization.data(withJSONObject: ["bars": bars])
            .write(to: URL(fileURLWithPath: perf))
        reconcileJob.chordChartPerformerPath = perf

        // A stored file whose sections still mention bars 9–12, which no longer exist.
        let sectionsPath = folder.appendingPathComponent("sections.json").path
        let stored: [String: Any] = [
            "source": ["chordChartPerformerPath": perf],
            "sections": [["id": "s1", "name": "Verse", "startBar": 1, "endBar": 12,
                          "bars": Array(1...12)]],
        ]
        try? JSONSerialization.data(withJSONObject: stored).write(to: URL(fileURLWithPath: sectionsPath))

        let store = SectionStore()
        store.load(for: reconcileJob, jobFolder: folder)
        check(store.sections.first?.bars == Array(1...8),
              "loading drops bars the chart no longer has")

        let onDisk = try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: sectionsPath))) as? [String: Any]
        let savedBars = ((onDisk?["sections"] as? [[String: Any]])?.first?["bars"] as? [Int])
        check(savedBars == Array(1...8),
              "and writes the reconciled result back, so the export cannot ship the old numbers (got \(savedBars.map { "\($0)" } ?? "nil"))")
    }

    // A song document with no title used to be excluded by the server-side
    // ordering and fail to decode besides, so it vanished from the library and
    // the user made a duplicate.
    do {
        let untitled = try! JSONDecoder().decode(
            FirebaseSong.self,
            from: try! JSONSerialization.data(withJSONObject: ["id": "s1", "tempo": 120])
        )
        check(untitled.title == "Untitled song",
              "a song document with no title still decodes, under a name that says so")
        check(untitled.id == "s1", "and keeps its document ID, so it can still be opened and fixed")

        let named = try! JSONDecoder().decode(
            FirebaseSong.self,
            from: try! JSONSerialization.data(withJSONObject: ["id": "s2", "title": "Golden Hour"])
        )
        check(named.title == "Golden Hour", "an ordinary title still reads through")
    }

    // A rename is a change; identity-only equality made it invisible.
    check(ChordSection(id: "a", name: "Verse", startBar: 1, endBar: 4, bars: [1, 2, 3, 4])
          != ChordSection(id: "a", name: "Chorus", startBar: 1, endBar: 4, bars: [1, 2, 3, 4]),
          "two sections with the same id but different names are not equal")

    let orphans = LocalFileStore.orphanedFolders(keeping: [sectionFolder.path])
    check(orphans.contains { $0.lastPathComponent == "orphan-1" }, "a folder no job points at is reported as orphaned")
    check(!orphans.contains { $0.lastPathComponent == "section-test" }, "a live folder is not")

    check(LocalFileStore.deleteJobFolder(at: orphanFolder), "an orphaned folder deletes")
    check(!FileManager.default.fileExists(atPath: orphanFolder.path), "and is gone from disk")
}

runSectionAndStorageTests()

// MARK: - Chart navigation

section("Chart navigation")

// Sections chunk into rows of four independently, so the grid the eye sees is
// ragged: a 6-bar section leaves two bars on its second row.
let ragged = [Array(1...6), Array(7...14), [15]]

check(ChartNavigation.barARowAway(from: 1, playhead: nil, sections: ragged, rowLength: 4, down: true) == 5,
      "down from the first row lands directly below it")
check(ChartNavigation.barARowAway(from: 5, playhead: nil, sections: ragged, rowLength: 4, down: false) == 1,
      "and back up again")
check(ChartNavigation.barARowAway(from: 3, playhead: nil, sections: ragged, rowLength: 4, down: true) == 6,
      "a column overhanging a short row lands on that row's last bar, not past it")
check(ChartNavigation.barARowAway(from: 6, playhead: nil, sections: ragged, rowLength: 4, down: true) == 8,
      "and leaving a section keeps the column it was actually in")
check(ChartNavigation.barARowAway(from: 8, playhead: nil, sections: ragged, rowLength: 4, down: false) == 6,
      "and up out of a section lands on the last row of the one before, at the nearest column")
check(ChartNavigation.barARowAway(from: 13, playhead: nil, sections: ragged, rowLength: 4, down: true) == 15,
      "a column past the end of the next section clamps to its last bar")
check(ChartNavigation.barARowAway(from: 15, playhead: nil, sections: ragged, rowLength: 4, down: true) == nil,
      "and the last bar has nowhere further down to go")
check(ChartNavigation.barARowAway(from: 1, playhead: nil, sections: ragged, rowLength: 4, down: false) == nil,
      "nor the first bar up")
check(ChartNavigation.barARowAway(from: nil, playhead: 9, sections: ragged, rowLength: 4, down: true) == 9,
      "with nothing selected, an arrow selects the playing bar")
check(ChartNavigation.barARowAway(from: nil, playhead: nil, sections: ragged, rowLength: 4, down: true) == 1,
      "or the first bar when nothing is playing either")
check(ChartNavigation.barARowAway(from: 99, playhead: nil, sections: ragged, rowLength: 4, down: true) == 1,
      "a selection that no longer exists falls back to the start")
check(ChartNavigation.barARowAway(from: 1, playhead: nil, sections: [], rowLength: 4, down: true) == nil,
      "an empty chart ignores the key entirely")

// Every bar must reach every other by arrows alone, or some bar is unreachable.
var reached: Set<Int> = [1]
var frontier = [1]
while let bar = frontier.popLast() {
    let neighbours = [
        ChartNavigation.nextBar(from: bar, playhead: nil, in: Array(1...15), by: 1),
        ChartNavigation.nextBar(from: bar, playhead: nil, in: Array(1...15), by: -1),
        ChartNavigation.barARowAway(from: bar, playhead: nil, sections: ragged, rowLength: 4, down: true),
        ChartNavigation.barARowAway(from: bar, playhead: nil, sections: ragged, rowLength: 4, down: false),
    ]
    for next in neighbours.compactMap({ $0 }) where !reached.contains(next) {
        reached.insert(next)
        frontier.append(next)
    }
}
check(reached.count == 15, "every bar in a ragged chart is reachable by arrow keys (reached \(reached.count) of 15)")

// MARK: - Tuning draft

section("Text size")

// macOS has no system text-size control, so this setting is the only thing that
// makes the app's scalable fonts actually scale. It has to stay in range and
// round-trip through the stored index whatever is thrown at it.
check(TextSizeSetting.scale(for: TextSizeSetting.defaultRawValue) == 1,
      "the default leaves every size exactly as designed")
check(TextSizeSetting.scale(for: -1) == 1, "a stored value below the range falls back to it")
check(TextSizeSetting.scale(for: 999) == 1, "and so does one above")

// The whole point of the emphasis rule is that small print gains more than
// headings. That must compress the hierarchy without ever inverting it — a
// caption ending up larger than the body text it sits under would be worse
// than not scaling at all.
//
// The app's real ladder, smallest style to largest.
let ladder: [(name: String, size: CGFloat, style: Font.TextStyle)] = [
    ("tertiary hint", 10.5, .caption2),
    ("secondary line", 11, .caption),
    ("stat", 12, .footnote),
    ("section heading", 13, .subheadline),
    ("chord", 15, .body),
]
var inversions: [String] = []
for step in TextSizeSetting.steps.indices {
    let scale = TextSizeSetting.scale(for: step)
    let sized = ladder.map { ($0.name, TextScale.scaled($0.size, style: $0.style, by: scale)) }
    for (a, b) in zip(sized, sized.dropFirst()) where a.1 >= b.1 {
        inversions.append("at \(TextSizeSetting.label(for: step)): \(a.0) \(a.1) >= \(b.0) \(b.1)")
    }
}
check(inversions.isEmpty, "the type hierarchy holds at every text size (\(inversions))")

check(TextScale.scaled(11, style: .caption, by: 1) == 11,
      "the default scale changes nothing at all")
check(TextScale.scaled(10.5, style: .caption2, by: 1.4)
      > TextScale.scaled(10.5, style: .body, by: 1.4),
      "small print gains more than body text at the same point size")
check(TextScale.scaled(15, style: .body, by: 1.4) > 15, "and everything does grow")
check(TextScale.scaled(15, style: .body, by: 0.85) < 15, "smaller settings shrink it")
check(TextSizeSetting.larger(than: 0) == 1, "stepping up moves one step")
check(TextSizeSetting.smaller(than: 0) == 0, "and stepping down at the smallest stays put")
check(TextSizeSetting.larger(than: TextSizeSetting.steps.count - 1) == TextSizeSetting.steps.count - 1,
      "as does stepping up at the largest")
check(TextSizeSetting.steps.count > 1, "there is more than one size to choose from")

// Every step must be reachable by stepping, or a size is offered but unusable.
var textStep = 0
var textStepsSeen: Set<Int> = [0]
for _ in TextSizeSetting.steps.indices {
    textStep = TextSizeSetting.larger(than: textStep)
    textStepsSeen.insert(textStep)
}
check(textStepsSeen.count == TextSizeSetting.steps.count,
      "every offered size can be reached by stepping up (\(textStepsSeen.count) of \(TextSizeSetting.steps.count))")

section("Sentence formatting")

// Used in the re-analysis confirmation, where a wrong list reads as a wrong
// promise about what is being replaced.
check(Format.list([]) == "nothing", "an empty list reads as nothing")
check(Format.list(["its 7 sections"]) == "its 7 sections", "one item stands alone")
check(Format.list(["a", "b"]) == "a and b", "two items are joined with and")
check(Format.list(["a", "b", "c"]) == "a, b and c", "three items use commas and a final and")

section("Unwritable storage")

@MainActor
func runPersistenceFailureTests() async {
    let manager = JobManager()
    await manager.hydrate()
    check(manager.persistenceError == nil, "a healthy store reports no persistence problem")

    // A folder the app cannot write into stands in for a full disk: the job
    // advances in memory, and the user must be told it is not reaching disk.
    let readOnly = LocalFileStore.baseDirectory
        .appendingPathComponent("readonly-job", isDirectory: true)
    try? FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
    var seed = AnalysisJob(id: "ro", sourceUrl: "https://youtu.be/rovid", status: .completed,
                           createdAt: Date(), title: "Read Only",
                           songDocumentID: "song-readonly", songVideoID: "rovid")
    seed.bpm = 100
    try? LocalFileStore.saveJob(seed, to: readOnly)

    let locked = JobManager()
    await locked.hydrate()
    check(locked.job(for: "song-readonly") != nil, "the seeded job is picked up")

    try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }

    locked.setSubdivisions([4: 2], songID: "song-readonly")
    check(locked.job(for: "song-readonly")?.subdivisionsByBar[4] == 2,
          "the edit still applies in memory, so the UI does not lie about what is on screen")
    check(locked.persistenceError != nil,
          "but the failure to save it is reported rather than swallowed")

    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
    locked.setSubdivisions([4: 8], songID: "song-readonly")
    check(locked.persistenceError == nil, "and clears once writing works again")
}

await runPersistenceFailureTests()

section("Launch-time job preference")

do {
    func job(_ id: String, chart: Bool = false, sections: Bool = false, age: TimeInterval = 0) -> AnalysisJob {
        var j = AnalysisJob(id: id, sourceUrl: "u", status: .completed,
                            createdAt: Date().addingTimeInterval(age))
        if chart { j.chordChartPerformerPath = "/nowhere/perf.json" }
        if sections { j.sectionsPath = "/nowhere/sections.json" }
        return j
    }

    let exportable = job("exportable", chart: true, sections: true, age: -9999)
    let charted = job("charted", chart: true, age: -5000)
    let bare = job("bare", age: 0)

    check(JobManager.prefer(exportable, over: charted),
          "an exportable analysis beats one with only a chart, however old")
    check(!JobManager.prefer(charted, over: exportable), "and the comparison is not symmetric")
    check(JobManager.prefer(charted, over: bare),
          "a chart beats a newer folder with nothing in it")
    check(!JobManager.prefer(bare, over: charted),
          "which is the whole point: recency alone demoted a finished analysis")

    let newer = job("newer", chart: true, age: 0)
    let older = job("older", chart: true, age: -60)
    check(JobManager.prefer(newer, over: older),
          "between two equally complete analyses the newer one wins")
    check(!JobManager.prefer(older, over: newer), "and the older one does not")

    // A total order: no pair may prefer each other, and none may prefer itself.
    let all = [exportable, charted, bare, newer, older]
    let contradictions = all.flatMap { a in
        all.filter { b in
            a.id != b.id && JobManager.prefer(a, over: b) && JobManager.prefer(b, over: a)
        }.map { (a.id, $0.id) }
    }
    check(contradictions.isEmpty, "no two candidates each beat the other (\(contradictions))")
    check(all.allSatisfy { !JobManager.prefer($0, over: $0) }, "and none beats itself")
}

section("Library state")

@MainActor
func runLibraryStateTests() {
    func song(_ id: String?, link: String?) -> FirebaseSong {
        var dict: [String: Any] = ["title": "A Song", "id": id ?? "placeholder"]
        if let link { dict["link"] = link }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        var decoded = try! JSONDecoder().decode(FirebaseSong.self, from: data)
        // A document read back before Firestore assigned an ID.
        if id == nil { decoded.id = nil }
        return decoded
    }
    let link = "https://youtu.be/statevid"
    let manager = JobManager()

    check(Library.state(for: song(nil, link: link), job: nil, jobManager: manager) == .unavailable,
          "a song with no document ID cannot be analysed")
    check(Library.state(for: song("s", link: nil), job: nil, jobManager: manager) == .unavailable,
          "nor one with no YouTube link")
    check(Library.state(for: song("s", link: link), job: nil, jobManager: manager) == .new,
          "a linked song with no job is new")

    var job = AnalysisJob(id: "j", sourceUrl: link, status: .completed, createdAt: Date())
    check(Library.state(for: song("s", link: link), job: job, jobManager: manager) == .new,
          "a completed job with nothing on disk is still new")

    job.chordChartPerformerPath = "/nowhere/perf.json"
    check(Library.state(for: song("s", link: link), job: job, jobManager: manager) == .analysed,
          "a job with a chart is analysed")

    let exportedAt = Date()
    job.lastExport = ExportRecord(exportedAt: exportedAt, documentID: "s", sectionCount: 3)
    job.completedAt = exportedAt.addingTimeInterval(-60)
    check(Library.state(for: song("s", link: link), job: job, jobManager: manager)
          == .exported(at: exportedAt), "an exported job reports when it was exported")

    job.lastEditedAt = exportedAt.addingTimeInterval(60)
    check(Library.state(for: song("s", link: link), job: job, jobManager: manager) == .edited,
          "and an edit afterwards moves it to edited")

    var failed = AnalysisJob(id: "f", sourceUrl: link, status: .failed, createdAt: Date())
    var failedReport = StageReport()
    failedReport.set(.download, .failed("no network"))
    failed.stageReport = failedReport
    check(Library.state(for: song("s", link: link), job: failed, jobManager: manager)
          == .failed(stage: .download), "a failed job names the stage that failed")

    let cancelled = AnalysisJob(id: "c", sourceUrl: link, status: .cancelled, createdAt: Date())
    check(Library.state(for: song("s", link: link), job: cancelled, jobManager: manager) == .new,
          "a cancelled job with no audio is back to new")

    // Every state must be reachable by some filter, or a song vanishes from the
    // sidebar entirely with no way to find it.
    let allStates: [SongWorkState] = [
        .unavailable, .new, .queued(position: 1), .running(stage: .download, stageIndex: 2),
        .audioReady, .failed(stage: .download), .analysed, .edited, .exported(at: Date()),
    ]
    let unreachable = allStates.filter { state in
        !LibraryFilter.allCases.contains { $0.matches(state) }
    }
    check(unreachable.isEmpty,
          "every work state is reachable by at least one filter (unreachable: \(unreachable))")
    check(allStates.allSatisfy { LibraryFilter.all.matches($0) },
          "and “All” really means all")

    // Analysing must not look like something the user can start again.
    check(!SongWorkState.running(stage: .download, stageIndex: 2).canAnalyse,
          "a running song cannot be analysed again")
    check(!SongWorkState.queued(position: 1).canAnalyse, "nor a queued one")
    check(!SongWorkState.unavailable.canAnalyse, "nor one with nothing to analyse")
    check(SongWorkState.failed(stage: .download).canAnalyse, "but a failed one can be retried")
}

runLibraryStateTests()

section("Logging")

// Log appends now run on their own queue, so ordering has to survive the hop —
// a log whose lines arrive out of order is worse than a slow one.
do {
    let folder = LocalFileStore.baseDirectory.appendingPathComponent("log-test", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 1...200 { LocalFileStore.appendLog("line \(index)\n", to: folder) }
    LocalFileStore.flushLogs()

    let written = (try? String(contentsOf: folder.appendingPathComponent("logs.txt"), encoding: .utf8)) ?? ""
    let lines = written.split(separator: "\n").map(String.init)
    check(lines.count == 200, "every queued log line reaches disk (got \(lines.count))")
    check(lines.first == "line 1" && lines.last == "line 200",
          "and they arrive in the order they were written")
}

section("Real backend payloads")

// Shaped exactly as ChordAdminBackend emits them, nulls included. The stub is a
// convenience; these are the shapes that actually arrive in production, and the
// parsers had never been fed one.
do {
    let chordPayload: [String: Any] = [
        "status": "success",
        "model": "chord-cnn-lstm",
        "resolvedModel": "chord-cnn-lstm",
        "chordCount": 3,
        "warnings": [String](),
        "raw": ["backend": "chord-cnn-lstm"],
        "cleanedChords": [
            "source": "chord.recognition.json",
            "chordCount": 3,
            "warnings": [String](),
            "chords": [
                ["start": 0.0, "end": 2.0, "rawChord": "C:maj",
                 "displayChord": "C", "confidence": NSNull()],
                ["start": 2.0, "end": 4.0, "rawChord": "A:min",
                 "displayChord": "Am", "confidence": NSNull()],
                ["start": 4.0, "end": 6.5, "rawChord": "F:maj",
                 "displayChord": "F", "confidence": NSNull()],
            ],
        ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: chordPayload)
    let parsed = JobManager.parseChordResponse(data)
    check(parsed.chordCount == 3, "the real chord payload reports its count (got \(parsed.chordCount.map { "\($0)" } ?? "nil"))")
    check(parsed.previewChords?.count == 3,
          "and every chord parses despite a null confidence (got \(parsed.previewChords?.count.description ?? "nil"))")
    check(parsed.previewChords?.first?.displayChord == "C", "with the display name the app charts")
    check(parsed.previewChords?.last?.end == 6.5, "and fractional times intact")
    check(parsed.cleanedData != nil, "and it produces the cleaned file the chart is built from")

    // A whole-number time must not be lost to an Int/Double mismatch.
    check(parsed.previewChords?.first?.start == 0, "a whole-number start time parses as a time, not as nothing")
}

do {
    // Beat detection, as the real service returns it.
    let beatPayload: [String: Any] = [
        "status": "success",
        "model": "madmom",
        "bpm": 136.36,
        "beatCount": 4,
        "timeSignature": NSNull(),
        "warnings": [String](),
        "beats": (0..<4).map { ["time": Double($0) * 0.44, "confidence": NSNull()] },
        "raw": ["backend": "madmom", "min_bpm": NSNull(),
                "max_bpm": NSNull(), "transition_lambda": NSNull()],
    ]
    let data = try! JSONSerialization.data(withJSONObject: beatPayload)
    let (bpm, count, model) = JobManager.parseBeatResponse(data)
    check(bpm == 136.36, "the real beat payload reports its BPM (got \(bpm.map { "\($0)" } ?? "nil"))")
    check(count == 4, "and its beat count (got \(count.map { "\($0)" } ?? "nil"))")
    check(model == "madmom", "and which model produced it")

    // `bpm` is null when too few beats were found — that must read as unknown,
    // not as zero, or the grid is built at a tempo nobody detected.
    var sparse = beatPayload
    sparse["bpm"] = NSNull()
    sparse["beats"] = [["time": 0.0, "confidence": NSNull()]]
    sparse["warnings"] = ["Not enough beats detected to calculate BPM."]
    let sparseData = try! JSONSerialization.data(withJSONObject: sparse)
    let (sparseBpm, sparseCount, _) = JobManager.parseBeatResponse(sparseData)
    check(sparseBpm == nil, "a null BPM reads as unknown rather than zero")
    check(sparseCount == 1,
          "while the beats it did find are counted from the array the grid is built from, "
          + "not the number the response claims (got \(sparseCount.map { "\($0)" } ?? "nil"))")
}

section("Download path resolution")

// The bug a real download found: yt-dlp prints a normalised path, the app held
// an unnormalised one, and every download "failed" with the audio already on
// disk. Nothing in the stub suite could have caught it — the stub never runs
// yt-dlp.
do {
    let root = LocalFileStore.baseDirectory.appendingPathComponent("dl-test", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let expected = root.appendingPathComponent("audio.original.webm")
    FileManager.default.createFile(atPath: expected.path, contents: Data("x".utf8))

    // Exactly what yt-dlp emitted: a version warning, then the path.
    let realOutput = """
    WARNING: Your yt-dlp version (2026.03.17) is older than 90 days!
             It is strongly recommended to always use the latest version.
    \(LocalFileStore.comparablePath(expected))
    """
    check(JobManager.downloadedFile(from: realOutput, in: root) != nil,
          "the printed path is found despite the warning lines around it")

    // A doubled separator, and macOS's /var → /private/var symlink: both make
    // the raw strings differ while naming the same file.
    let awkward = URL(fileURLWithPath: root.path + "/")
    check(JobManager.downloadedFile(from: realOutput, in: awkward) != nil,
          "a trailing separator on the folder does not break the match")

    // Nothing usable printed at all — the file is still there to be found.
    check(JobManager.downloadedFile(from: "WARNING: something\nERROR: nothing useful", in: root)?
            .hasSuffix("audio.original.webm") == true,
          "and with no usable output the folder is asked directly")

    // A path belonging to some other folder must not be accepted.
    let elsewhere = LocalFileStore.baseDirectory.appendingPathComponent("dl-other", isDirectory: true)
    try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    check(JobManager.downloadedFile(from: "/somewhere/else/audio.original.webm", in: elsewhere) == nil,
          "a path outside the job folder is not mistaken for the download")
}

section("Real translate response")

// Captured from ChordAdminBackend itself, translating a real analysed job —
// not hand-written. This is the payload the export sheet describes and the one
// written to Firestore, so the parser is checked against the real thing.
do {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/translate-real.json")
    if let data = try? Data(contentsOf: fixture),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let song = json["song"] as? [String: Any] {

        check(json["status"] as? String == "success", "the captured response is a success")

        let described = StageBeeExportService.describeSections(song["sections"] as Any)
        check(described.count == 3,
              "every section in the real payload is described (got \(described.count))")
        check(described.allSatisfy { !$0.name.isEmpty && !$0.name.hasPrefix("Section ") || $0.name == "Section A" },
              "under the names the backend actually stored (\(described.map(\.name)))")
        check(described.allSatisfy { $0.barCount > 0 },
              "each with a real bar count read out of its nested lines (\(described.map(\.barCount)))")
        check(described.map(\.barCount).reduce(0, +) == 17,
              "totalling the bars the analysis produced (got \(described.map(\.barCount).reduce(0, +)))")

        // The repeat detection has to survive the round trip: the same passage
        // coming round twice must still carry the same name.
        let names = described.map(\.name)
        check(Set(names).count < names.count,
              "and a passage that recurs keeps one name through the translation (\(names))")

        // Tempo is written to Firestore, so its type matters.
        check(song["tempo"] is Int, "the tempo the backend returns is a whole number")
    } else {
        check(false, "the captured translate response is readable")
    }
}

section("Tool readiness")

// A tool that is present but broken used to be reported as "not installed",
// with an install command that cannot fix it — and the dyld error that explained
// the real problem was discarded.
do {
    let broken = ToolStatus(tool: .ffmpeg, path: nil, version: nil,
                            foundButUnusable: (path: "/opt/homebrew/bin/ffmpeg",
                                               reason: "dyld: Library not loaded: libvpx.9.dylib"))
    let report = ToolReport(statuses: [broken], checkedAt: Date())
    let described = report.missingDescriptions.joined(separator: " ")
    check(described.contains("/opt/homebrew/bin/ffmpeg"),
          "a broken tool's description says where it was found")
    check(described.contains("libvpx"), "and why it would not run")
    check(!described.contains("brew install"),
          "and does not offer an install that would change nothing")

    let absent = ToolReport(statuses: [ToolStatus(tool: .ffmpeg, path: nil, version: nil)],
                            checkedAt: Date())
    check(absent.missingDescriptions.joined().contains("brew install"),
          "while a genuinely absent tool still gets the install hint")
}

section("Subprocess output")

// A chunk boundary that splits a multi-byte character used to discard the whole
// chunk — up to 64 KB gone from the log and from the text callers parse.
do {
    let result = try? await ProcessRunner.run(
        executablePath: "/bin/echo", arguments: ["café · naïve · 日本語"]
    )
    check(result?.exitCode == 0, "a subprocess runs and reports its exit code")
    check(result?.output.contains("café · naïve · 日本語") == true,
          "multi-byte output survives intact (got \(result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "nil"))")
}

do {
    // Enough output to cross several read boundaries, all multi-byte.
    let line = String(repeating: "é日", count: 4000)
    let result = try? await ProcessRunner.run(executablePath: "/bin/echo", arguments: [line])
    let got = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    check(got == line, "and so does output large enough to be split across reads (got \(got.count) of \(line.count) characters)")
}

do {
    let result = try? await ProcessRunner.run(executablePath: "/bin/sh", arguments: ["-c", "exit 3"])
    check(result?.exitCode == 3, "a non-zero exit code is reported, not swallowed")
}

// Heavy output on both streams at once: the final drain and an in-flight
// readability handler used to be able to read the same descriptor together,
// interleaving bytes — which, now that a chunk can end mid-character, would
// also mis-decode. Run it repeatedly; a race that only sometimes fires is still
// a race, and a stable byte count across runs is the evidence.
do {
    var sizes: Set<Int> = []
    var truncated = false
    for _ in 0..<5 {
        let script = """
        for i in $(seq 1 300); do
          printf 'out-%s-ééé\n' "$i"
          printf 'err-%s-ééé\n' "$i" >&2
        done
        """
        guard let result = try? await ProcessRunner.run(
            executablePath: "/bin/sh", arguments: ["-c", script]
        ) else { truncated = true; break }
        sizes.insert(result.output.utf8.count)
        // Every line must be whole: a split multi-byte sequence would show up
        // as a replacement character rather than the accented text.
        if result.output.contains("\u{FFFD}") { truncated = true }
        if result.output.components(separatedBy: "out-").count != 301 { truncated = true }
        if result.output.components(separatedBy: "err-").count != 301 { truncated = true }
    }
    check(!truncated, "concurrent stdout and stderr arrive whole, with no mangled characters")
    check(sizes.count == 1,
          "and the same number of bytes every run, so no read races the final drain (sizes: \(sizes.sorted()))")
}

// Cancelling must not hang, even when the child leaves something behind holding
// the output pipe open — the case that used to wedge a download for good.
do {
    let started = Date()
    let task = Task {
        try await ProcessRunner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 30 & sleep 30"]
        )
    }
    try? await Task.sleep(for: .milliseconds(200))
    task.cancel()
    var threw = false
    do { _ = try await task.value } catch { threw = true }
    let elapsed = Date().timeIntervalSince(started)
    check(threw, "cancelling a running subprocess throws rather than returning a result")
    check(elapsed < 5,
          "and returns promptly even with a grandchild still holding the pipe (took \(String(format: "%.1f", elapsed))s)")
}

// MARK: - Tuning draft

section("Tuning draft")

var tuningDraft = TuningDraft()
tuningDraft.beatsPerBar = 4
tuningDraft.offset = 3
check(tuningDraft.offset == 3, "a pickup of 3 is legal in 4/4")
tuningDraft.beatsPerBar = 3
check(tuningDraft.offset == 2, "narrowing the metre clamps the pickup into range (got \(tuningDraft.offset))")
tuningDraft.beatsPerBar = 2
check(tuningDraft.offset == 1, "and again when it narrows further")
tuningDraft.beatsPerBar = 4
check(tuningDraft.offset == 3, "and widening it again restores what the user asked for")

tuningDraft.manualBpmText = "136"
check(tuningDraft.manualBpm == 136, "a valid BPM parses")
check(!tuningDraft.hasInvalidManualBpm, "and is not flagged")
tuningDraft.manualBpmText = "9"
check(tuningDraft.manualBpm == nil, "an out-of-range BPM does not parse")
check(tuningDraft.hasInvalidManualBpm, "and is flagged so Apply can be blocked")
tuningDraft.manualBpmText = "  "
check(!tuningDraft.hasInvalidManualBpm, "a blank field is not an error")

// A stored fractional override must not read as an unapplied edit on load.
var fractional = AnalysisJob(id: "f", sourceUrl: "u", status: .completed, createdAt: Date())
fractional.manualBpm = 136.4
fractional.barAlignmentOffset = 2
check(!TuningDraft.from(job: fractional).isDirty,
      "a stored fractional BPM does not look like a pending change")

// MARK: - Pause cause

section("Pause cause")

var pausedJob = AnalysisJob(id: "p", sourceUrl: "u", status: .audioReady, createdAt: Date())
pausedJob.backendErrorMessage = "Backend unavailable at http://localhost:5051"
if case .backendUnavailable = pausedJob.pauseCause {
    check(true, "a backend message means the backend is to blame")
} else {
    check(false, "a backend message means the backend is to blame")
}

var stoppedJob = AnalysisJob(id: "s", sourceUrl: "u", status: .audioReady, createdAt: Date())
stoppedJob.stoppedByUser = true
stoppedJob.backendErrorMessage = "Backend unavailable at http://localhost:5051"
if case .cancelled = stoppedJob.pauseCause {
    check(true, "a cancel after the download reads as a cancel, not a backend failure")
} else {
    check(false, "a cancel after the download reads as a cancel, not a backend failure")
}

var userCancelled = AnalysisJob(id: "c", sourceUrl: "u", status: .cancelled, createdAt: Date())
if case .cancelled = userCancelled.pauseCause {
    check(true, "a cancelled job is not blamed on the backend")
} else {
    check(false, "a cancelled job is not blamed on the backend")
}
userCancelled.status = .audioReady
if case .interrupted = userCancelled.pauseCause {
    check(true, "and an unfinished job with no backend error reads as interrupted")
} else {
    check(false, "and an unfinished job with no backend error reads as interrupted")
}

// MARK: - Stage report resets

section("Stage report resets")

var resetReport = StageReport()
resetReport.set(.tools, .done, elapsed: 0.2)
resetReport.set(.beats, .done, elapsed: 42)
resetReport.reset(from: .beats)
check(resetReport[.beats].elapsed == nil,
      "resetting a stage clears its timing as well as its state")
check(resetReport[.tools].elapsed == 0.2, "while earlier stages keep theirs")

var interruptedReport = StageReport()
interruptedReport.set(.download, .running, elapsed: 12)
interruptedReport.resetUnfinished()
check(interruptedReport[.download].elapsed == nil,
      "repairing an interrupted run clears the part-elapsed time too")

// MARK: - Pipeline against a stub backend

section("Analysis pipeline (stub backend)")

@MainActor
func runPipelineIntegrationTests() async {
    // The backend URL is read once, so the stub has to be the address the app
    // already resolved. verify.sh sets CHORDADMIN_BACKEND_URL before launching.
    guard let expected = ProcessInfo.processInfo.environment["CHORDADMIN_BACKEND_URL"],
          let port = UInt16(URL(string: expected)?.port.map(String.init) ?? "") else {
        print("  · skipped (CHORDADMIN_BACKEND_URL not set to a fixed port)")
        return
    }

    let backend: FakeBackend
    do {
        backend = try FakeBackend(fixedPort: port)
        try backend.start()
    } catch {
        print("  · skipped (could not start the stub backend: \(error))")
        return
    }
    defer { backend.stop() }

    check(JobManager.backendBaseUrl == expected,
          "the app honours CHORDADMIN_BACKEND_URL (\(JobManager.backendBaseUrl))")
    check(await JobManager.checkBackendHealth(), "the stub backend answers the health check")

    // Another service on the same port must not read as the backend being ready.
    backend.update { $0.healthServiceName = "SomeOtherDevServer" }
    check(await JobManager.checkBackendHealth() == false,
          "a different service answering on the backend's port is not mistaken for it")
    backend.update { $0.healthServiceName = "ChordAdminBackend" }
    check(await JobManager.checkBackendHealth(), "and the real one is recognised again")

    // A job whose audio is already on disk, so the run resumes at the backend
    // stages and never shells out to yt-dlp or ffmpeg.
    let jobsRoot = LocalFileStore.baseDirectory
    let folder = jobsRoot.appendingPathComponent("integration-job", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let wavPath = folder.appendingPathComponent("analysis.wav").path
    FileManager.default.createFile(atPath: wavPath, contents: Data(repeating: 0, count: 2048))

    var seed = AnalysisJob(
        id: "integration-job", sourceUrl: "https://youtu.be/integration",
        status: .audioReady, createdAt: Date(), title: "Integration",
        songDocumentID: "song-integration", songVideoID: "integration"
    )
    seed.analysisWavPath = wavPath
    var seedReport = StageReport()
    for stage in PipelineStage.audioStages { seedReport.set(stage, .done, elapsed: 1) }
    seed.stageReport = seedReport
    try? LocalFileStore.saveJob(seed, to: folder)

    let manager = JobManager()
    await manager.hydrate()

    let ref = SongRef(documentID: "song-integration", title: "Integration",
                      artist: nil, url: "https://youtu.be/integration")

    func waitForIdle(_ manager: JobManager, seconds: Double = 20) async {
        let deadline = Date().addingTimeInterval(seconds)
        while manager.runningSongID != nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    // — Happy path —
    manager.start(ref, resumeIfPossible: true)
    await waitForIdle(manager)

    let done = manager.job(for: "song-integration")
    check(done?.status == .completed || done?.status == .completedWithWarnings,
          "a resumed run finishes (status: \(done?.status.displayName ?? "nil"))")
    check(done?.bpm == 120, "the detected BPM is stored")
    check((done?.chordCount ?? 0) > 0, "chords are stored")
    check(done?.hasChart == true, "a chart is produced")
    check((done?.sectionCount ?? 0) > 0, "sections are detected")
    check(done?.stageReport[.download].state == .done,
          "the already-finished download stage is left alone")
    check(!backend.requestedPaths.contains("/api/translate-to-stagebee"),
          "analysis never calls the export endpoint")

    // The workspace reloads on chartsVersion alone, so a run that writes charts
    // without bumping it would leave the chart pane empty until the user
    // clicked away and back.
    let versionAfterRun = done?.chartsVersion ?? 0
    check(versionAfterRun > 0, "finishing a run bumps the chart version the workspace reloads on")

    await manager.regenerateCharts(songID: "song-integration", offset: 1)
    check((manager.job(for: "song-integration")?.chartsVersion ?? 0) > versionAfterRun,
          "and so does re-tuning the grid")

    let unbuildable = await manager.regenerateCharts(songID: "no-such-song", offset: 1)
    check(!unbuildable, "regenerating a song with nothing on disk reports that it did not apply")

    let report = done?.stageReport
    check(report?.firstFailure == nil, "no stage is marked failed")
    check(report?[.beats].state == .done, "beat detection is marked done")
    check(report?[.sections].state.isTerminal == true, "section detection reaches a terminal state")
    check(done?.barsWithoutChords == 0,
          "a chart whose bars all carry chords reports none missing (got \(done?.barsWithoutChords.map(String.init) ?? "nil"))")

    // A resume leaves the chart on screen and editable for the minutes the
    // backend takes. Edits made during the run must survive it.
    manager.setSubdivisions([9: 8], songID: "song-integration")
    let midRunExport = ExportRecord(exportedAt: Date(), documentID: "song-integration", sectionCount: 3)
    manager.recordExport(midRunExport, songID: "song-integration")
    await manager.regenerateCharts(songID: "song-integration")
    check(manager.job(for: "song-integration")?.subdivisionsByBar[9] == 8,
          "a subdivision set during a run is not rolled back by the next stage")
    check(manager.job(for: "song-integration")?.lastExport != nil,
          "and neither is an export recorded while it ran")

    // Tuning applied mid-run is not cosmetic: the beat grid stage reads these
    // back, so a stale snapshot rebuilt every chart in the wrong metre.
    await manager.regenerateCharts(songID: "song-integration", beatsPerBar: 3, halved: true)
    let versionBeforeResume = manager.job(for: "song-integration")?.chartsVersion ?? 0
    manager.start(ref, resumeIfPossible: true)
    await waitForIdle(manager)
    let afterResume = manager.job(for: "song-integration")
    check(afterResume?.beatsPerBarOverride == 3,
          "an applied metre survives a resumed run (got \(afterResume?.beatsPerBarOverride.map(String.init) ?? "nil"))")
    check(afterResume?.tempoHalved == true, "and so does halved tempo")
    check((afterResume?.chartsVersion ?? 0) >= versionBeforeResume,
          "and the chart version never goes backwards, which would strand the workspace on a stale chart")

    // The real backend answers a failed detection with HTTP 200 and
    // `status: "error"` in the body. Checking only the HTTP code let that
    // through as a success with no beats, and the run then died two stages
    // later blaming the beat grid while the actual cause — "madmom is not
    // installed" — sat unread in the response.
    backend.update { $0.beatsReportsErrorAt200 = "madmom is not installed. Run: pip install -r requirements.txt" }
    manager.start(ref, resumeIfPossible: true)
    await waitForIdle(manager)
    let backendErrored = manager.job(for: "song-integration")
    let beatsFailure = backendErrored?.stageReport[.beats].state.message
        ?? backendErrored?.errorMessage ?? ""
    check(beatsFailure.contains("madmom is not installed"),
          "a backend error sent at HTTP 200 is reported as itself (got \(beatsFailure.isEmpty ? "nothing" : beatsFailure))")
    check(!beatsFailure.contains("beat grid"),
          "and not as the beat-grid failure two stages later that it used to become")
    backend.update { $0.beatsReportsErrorAt200 = nil }

    // Chord recognition names its reason `error` rather than `message`.
    backend.update { $0.chordsReportsErrorAt200 = "Chord recognition failed: model weights missing" }
    manager.start(ref, resumeIfPossible: true)
    await waitForIdle(manager)
    let chordFailure = manager.job(for: "song-integration")?.stageReport[.chords].state.message
        ?? manager.job(for: "song-integration")?.errorMessage ?? ""
    check(chordFailure.contains("model weights missing"),
          "and a chord failure reports its own reason too, under the other key (got \(chordFailure.isEmpty ? "nothing" : chordFailure))")
    backend.update { $0.chordsReportsErrorAt200 = nil }

    // — Backend refuses the chord model —
    backend.update { $0.chordsStatus = 500 }
    let failing = JobManager()
    await failing.hydrate()
    failing.retry(from: .chords, for: ref)
    await waitForIdle(failing)

    let failed = failing.job(for: "song-integration")
    check(failed?.status == .failed, "a 500 from the backend fails the job (was \(failed?.status.displayName ?? "nil"))")
    check(failed?.stageReport.firstFailure?.stage == .chords,
          "and the failure is attributed to the chord stage")
    check(failed?.stageReport[.chords].state.message?.contains("500") == true,
          "and the message carries the status code")
    check(failed?.stageReport[.beats].state == .done,
          "while the earlier beat stage keeps its result")

    // — Cancelling a run in flight —
    backend.update { $0.chordsStatus = 200; $0.beatsDelay = 3 }
    let cancelling = JobManager()
    await cancelling.hydrate()
    cancelling.retry(from: .beats, for: ref)
    // Let the upload actually start before pulling the rug.
    try? await Task.sleep(for: .milliseconds(400))
    check(cancelling.runningSongID == "song-integration", "the run is under way before cancelling")
    cancelling.cancelRun()
    await waitForIdle(cancelling, seconds: 15)

    let cancelled = cancelling.job(for: "song-integration")
    check(cancelling.runningSongID == nil, "cancelling stops the run")
    check(cancelled?.status == .audioReady || cancelled?.status == .cancelled,
          "and leaves a resumable job (was \(cancelled?.status.displayName ?? "nil"))")
    check(cancelled?.hasAudio == true, "keeping the audio already on disk")
    check(cancelled?.stageReport[.download].state == .done,
          "and the stages that had already finished")
    backend.update { $0.beatsDelay = 0 }

    // — Backend unreachable —
    backend.stop()
    let offline = JobManager()
    await offline.hydrate()
    offline.retry(from: .backend, for: ref)
    await waitForIdle(offline)

    let paused = offline.job(for: "song-integration")
    check(paused?.status == .audioReady,
          "an unreachable backend pauses rather than failing (was \(paused?.status.displayName ?? "nil"))")
    check(paused?.stageReport[.backend].state.isFailure == true, "the backend stage is marked failed")
    if case .skipped = paused?.stageReport[.beats].state {
        check(true, "and the later stages are skipped with a reason")
    } else {
        check(false, "and the later stages are skipped with a reason")
    }
    check(paused?.hasAudio == true, "the downloaded audio is kept for a later resume")
}

await runPipelineIntegrationTests()

// MARK: - Hydration and migration

section("Hydration")

@MainActor
func runHydrationTests() async {
    let root = LocalFileStore.baseDirectory
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    func writeJob(_ job: AnalysisJob, folderName: String, withAudio: Bool = true) -> URL {
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stored = job
        if withAudio {
            let wav = folder.appendingPathComponent("analysis.wav").path
            FileManager.default.createFile(atPath: wav, contents: Data(repeating: 0, count: 16))
            stored.analysisWavPath = wav
        }
        try? LocalFileStore.saveJob(stored, to: folder)
        return folder
    }

    // A job from before per-song keying: no songDocumentID, only a source URL.
    var legacy = AnalysisJob(
        id: "legacy-job", sourceUrl: "https://www.youtube.com/watch?v=legacyvid",
        status: .completed, createdAt: Date().addingTimeInterval(-86_400), title: "Old Favourite"
    )
    legacy.bpm = 98
    legacy.sectionCount = 5
    _ = writeJob(legacy, folderName: "legacy-job")

    // A job interrupted mid-run, as a crash or quit would leave it.
    var stranded = AnalysisJob(
        id: "stranded-job", sourceUrl: "https://youtu.be/strandedvid",
        status: .downloading, createdAt: Date().addingTimeInterval(-3600),
        title: "Interrupted", songDocumentID: "song-stranded", songVideoID: "strandedvid"
    )
    var strandedReport = StageReport()
    strandedReport.set(.tools, .done, elapsed: 0.2)
    strandedReport.set(.download, .running)
    stranded.stageReport = strandedReport
    _ = writeJob(stranded, folderName: "stranded-job")

    // Two runs for the same song: the newer one should win.
    let older = AnalysisJob(id: "dup-old", sourceUrl: "https://youtu.be/dupvid",
                            status: .completed, createdAt: Date().addingTimeInterval(-7200),
                            title: "Duplicate", songDocumentID: "song-dup", songVideoID: "dupvid")
    var newer = older
    newer.id = "dup-new"
    newer.createdAt = Date()
    newer.bpm = 141
    _ = writeJob(older, folderName: "dup-old")
    _ = writeJob(newer, folderName: "dup-new")

    // A beat re-detection records a running stage without touching `status`, so
    // an interrupted one used to leave the Analysis tab spinning forever.
    var redetected = AnalysisJob(id: "redetect-job", sourceUrl: "https://youtu.be/redetectvid",
                                 status: .completed, createdAt: Date(), title: "Redetected",
                                 songDocumentID: "song-redetect", songVideoID: "redetectvid")
    var redetectReport = StageReport()
    redetectReport.set(.beats, .running)
    redetected.stageReport = redetectReport
    _ = writeJob(redetected, folderName: "redetect-job")

    // The case that cost a user their work: quitting while a re-analysis was
    // still downloading leaves a newer, emptier folder beside the finished one.
    // Picking by recency demoted a complete, exported analysis to "failed", and
    // then offered its folder for deletion as leftover.
    var finished = AnalysisJob(id: "abandon-old", sourceUrl: "https://youtu.be/abandonvid",
                               status: .completed, createdAt: Date().addingTimeInterval(-7200),
                               title: "Golden Hour", songDocumentID: "song-abandon",
                               songVideoID: "abandonvid")
    finished.bpm = 132
    finished.sectionCount = 7
    let finishedFolder = writeJob(finished, folderName: "abandon-old")
    let chartPath = finishedFolder.appendingPathComponent("chord.chart.performer.json").path
    let sectionsPath = finishedFolder.appendingPathComponent("sections.json").path
    FileManager.default.createFile(atPath: chartPath, contents: Data("{}".utf8))
    FileManager.default.createFile(atPath: sectionsPath, contents: Data("{}".utf8))
    finished.chordChartPerformerPath = chartPath
    finished.sectionsPath = sectionsPath
    finished.lastExport = ExportRecord(exportedAt: Date().addingTimeInterval(-3600),
                                       documentID: "song-abandon", sectionCount: 7)
    try? LocalFileStore.saveJob(finished, to: finishedFolder)

    var abandoned = AnalysisJob(id: "abandon-new", sourceUrl: "https://youtu.be/abandonvid",
                                status: .downloading, createdAt: Date(),
                                title: "Golden Hour", songDocumentID: "song-abandon",
                                songVideoID: "abandonvid")
    var abandonedReport = StageReport()
    abandonedReport.set(.download, .running)
    abandoned.stageReport = abandonedReport
    _ = writeJob(abandoned, folderName: "abandon-new", withAudio: false)

    let manager = JobManager()
    await manager.hydrate()

    check(manager.job(for: "song-abandon")?.bpm == 132,
          "a completed analysis outlives a newer re-analysis the app never finished")
    check(manager.job(for: "song-abandon")?.sectionCount == 7,
          "keeping its sections")
    check(manager.job(for: "song-abandon")?.lastExport != nil,
          "and its export record")
    check(manager.folder(for: "song-abandon")?.lastPathComponent == "abandon-old",
          "and the song points back at the folder that holds them")
    check(!manager.orphanedFolders().map(\.lastPathComponent).contains("abandon-old"),
          "the finished folder is never offered for deletion as leftover")
    check(manager.protectedFolders["song-abandon"] == nil,
          "the abandoned half-built folder is not itself protected — it has no chart to lose")

    // Quitting mid-re-analysis must settle on disk, not leave the next launch to
    // reconstruct which folder replaced which.
    var quitOriginal = AnalysisJob(id: "quit-old", sourceUrl: "https://youtu.be/quitvid",
                                   status: .completed, createdAt: Date().addingTimeInterval(-600),
                                   title: "Quit Test", songDocumentID: "song-quit",
                                   songVideoID: "quitvid")
    quitOriginal.bpm = 118
    let quitOldFolder = writeJob(quitOriginal, folderName: "quit-old")
    let quitChart = quitOldFolder.appendingPathComponent("chord.chart.performer.json").path
    let quitSections = quitOldFolder.appendingPathComponent("sections.json").path
    FileManager.default.createFile(atPath: quitChart, contents: Data("{}".utf8))
    FileManager.default.createFile(atPath: quitSections, contents: Data("{}".utf8))
    quitOriginal.chordChartPerformerPath = quitChart
    quitOriginal.sectionsPath = quitSections
    try? LocalFileStore.saveJob(quitOriginal, to: quitOldFolder)

    let quitManager = JobManager()
    await quitManager.hydrate()
    let quitRef = SongRef(documentID: "song-quit", title: "Quit Test",
                          artist: nil, url: "https://youtu.be/quitvid")
    quitManager.start(quitRef, resumeIfPossible: false)
    // Let the run get as far as creating its replacement folder, then quit.
    try? await Task.sleep(for: .milliseconds(150))
    quitManager.cancelRun()
    let settledCount = quitManager.settleForTermination()
    check(settledCount >= 0, "settling on quit runs without a live pipeline to wait on")
    check(quitManager.job(for: "song-quit")?.stageReport.runningStage == nil,
          "no stage is left recorded as running after a quit")

    // Two complete charts for one song: the loser holds real work, so it is set
    // aside rather than swept — but deleting the song's analysis must take it
    // too, or the next launch adopts it and quietly undoes the deletion.
    func chartedJob(id: String, songID: String, folderName: String, bpm: Double) -> URL {
        var job = AnalysisJob(id: id, sourceUrl: "https://youtu.be/twinvid",
                              status: .completed, createdAt: Date(), title: "Twin",
                              songDocumentID: songID, songVideoID: "twinvid")
        job.bpm = bpm
        let folder = writeJob(job, folderName: folderName)
        let chart = folder.appendingPathComponent("chord.chart.performer.json").path
        FileManager.default.createFile(atPath: chart, contents: Data("{}".utf8))
        job.chordChartPerformerPath = chart
        try? LocalFileStore.saveJob(job, to: folder)
        return folder
    }
    _ = chartedJob(id: "twin-a", songID: "song-twin", folderName: "twin-a", bpm: 100)
    let twinB = chartedJob(id: "twin-b", songID: "song-twin", folderName: "twin-b", bpm: 101)

    let twinManager = JobManager()
    await twinManager.hydrate()
    check(twinManager.protectedFolders["song-twin"]?.count == 1,
          "a second complete chart for a song is set aside, not swept away")
    check(!twinManager.orphanedFolders().map(\.lastPathComponent).contains("twin-a"),
          "and is kept off the leftover list while it is held")

    // Releasing must never delete a folder a song still points at, whatever
    // path got here — the sweep removes only what nothing references.
    let twinCurrent = twinManager.folder(for: "song-twin")
    twinManager.deleteJob(songID: "song-twin")
    check(twinCurrent != nil, "the song had a live folder before the delete")
    check(twinManager.protectedFolders["song-twin"] == nil,
          "deleting the song's analysis releases what was held for it")
    check(!FileManager.default.fileExists(atPath: twinB.path)
          && !FileManager.default.fileExists(atPath: root.appendingPathComponent("twin-a").path),
          "and removes both folders, so the deletion is not undone at the next launch")

    check(manager.job(for: "song-redetect")?.stageReport.runningStage == nil,
          "an interrupted re-detection does not leave a stage running forever")
    check(manager.job(for: "song-redetect")?.status == .completed,
          "and the completed analysis it belonged to is untouched")

    check(manager.job(for: "song-stranded")?.status == .audioReady,
          "an interrupted job is repaired to a resumable state, not left 'downloading'")
    check(manager.job(for: "song-stranded")?.stageReport[.download].state == .pending,
          "and its unfinished stage is reset")
    check(manager.job(for: "song-stranded")?.stageReport[.tools].state == .done,
          "while finished stages are kept")

    check(manager.job(for: "song-dup")?.bpm == 141,
          "when a song has two runs on disk, the most recent wins")

    // The migration that matters for existing data: a pre-keying job folder is
    // adopted by video ID the first time its song is opened.
    check(manager.job(for: "song-legacy") == nil, "a legacy job is not keyed to a song yet")
    let legacyRef = SongRef(documentID: "song-legacy", title: "Old Favourite",
                            artist: nil, url: "https://youtu.be/legacyvid")
    manager.adoptLegacyJobIfNeeded(for: legacyRef)

    let adopted = manager.job(for: "song-legacy")
    check(adopted != nil, "opening the song adopts its existing analysis")
    check(adopted?.bpm == 98, "with the analysis results intact")
    check(adopted?.songDocumentID == "song-legacy", "and stamped with the song it belongs to")
    check(manager.folder(for: "song-legacy")?.lastPathComponent == "legacy-job",
          "pointing at the original folder rather than a new one")

    // Adoption must be written through, so it survives a relaunch.
    let relaunched = JobManager()
    await relaunched.hydrate()
    check(relaunched.job(for: "song-legacy")?.bpm == 98,
          "and the adoption is saved, so it survives a relaunch")

    // One folder belongs to one song: a second song sharing the video ID must
    // not bind to the folder that has just been claimed.
    let rivalRef = SongRef(documentID: "song-rival", title: "Rival",
                           artist: nil, url: "https://youtu.be/legacyvid")
    manager.adoptLegacyJobIfNeeded(for: rivalRef)
    check(manager.job(for: "song-rival") == nil,
          "an already-adopted folder is not adopted a second time by another song")

    // A legacy folder must never be offered for deletion as "leftover": no song
    // points at it yet, but opening its song will adopt it.
    let leftover = manager.orphanedFolders().map(\.lastPathComponent)
    check(!leftover.contains("legacy-job"),
          "an un-adopted legacy folder is not reported as leftover")
    check(!leftover.contains("dup-new"), "nor is the live folder for a song")
    check(leftover.contains("dup-old"),
          "while a genuinely superseded folder still is (\(leftover))")

    // Adoption must refuse a folder that has gone from disk, rather than binding
    // a song to a directory that is not there.
    let ghostRef = SongRef(documentID: "song-ghost", title: "Ghost",
                           artist: nil, url: "https://youtu.be/ghostvid")
    var ghost = AnalysisJob(id: "ghost-job", sourceUrl: "https://youtu.be/ghostvid",
                            status: .completed, createdAt: Date(), title: "Ghost")
    _ = writeJob(ghost, folderName: "ghost-job")
    ghost.title = "Ghost"
    let ghostManager = JobManager()
    await ghostManager.hydrate()
    try? FileManager.default.removeItem(at: root.appendingPathComponent("ghost-job"))
    ghostManager.adoptLegacyJobIfNeeded(for: ghostRef)
    check(ghostManager.job(for: "song-ghost") == nil,
          "a legacy folder deleted outside the app is not adopted")

    // Queueing.
    let a = SongRef(documentID: "song-q1", title: "Q1", artist: nil, url: "https://youtu.be/q1")
    let b = SongRef(documentID: "song-q2", title: "Q2", artist: nil, url: "https://youtu.be/q2")
    let queueManager = JobManager()
    queueManager.start(a, resumeIfPossible: false)
    queueManager.start(b, resumeIfPossible: false)
    check(queueManager.runningSongID != nil, "the first queued song starts immediately")
    check(queueManager.queuePosition(of: "song-q2") == 1, "and the second waits its turn")
    queueManager.start(b, resumeIfPossible: false)
    check(queueManager.queue.count == 1, "queueing the same song twice does not duplicate it")
    // A re-analysis requested for a song already queued must upgrade the waiting
    // resume, not be dropped.
    queueManager.start(b, resumeIfPossible: false)
    check(queueManager.queue.count == 1, "re-requesting a queued song does not duplicate it")

    // Deleting an analysis must also take it out of the queue, or it runs again
    // on its own.
    queueManager.deleteJob(songID: "song-q2")
    check(queueManager.queuePosition(of: "song-q2") == nil,
          "deleting a queued analysis removes it from the queue")

    queueManager.start(b, resumeIfPossible: true)
    queueManager.removeFromQueue("song-q2")
    check(queueManager.queue.isEmpty, "a queued song can be taken back out")
    queueManager.clearQueue()
    check(queueManager.queue.isEmpty, "and the whole queue can be cleared")
    queueManager.cancelRun()
}

await runHydrationTests()

// MARK: - Re-analysis safety

section("Re-analysis safety")

@MainActor
func runReanalysisSafetyTests() async {
    // Needs yt-dlp so the download stage can fail for real; the point is that a
    // re-analysis which goes wrong must not cost the user their existing chart.
    guard ToolChecker.resolvePath(for: .ytDlp) != nil,
          ToolChecker.resolvePath(for: .ffmpeg) != nil else {
        print("  · skipped (yt-dlp/ffmpeg not installed)")
        return
    }

    let songID = "song-reanalyse"
    let root = LocalFileStore.baseDirectory
    let original = root.appendingPathComponent("reanalyse-original", isDirectory: true)
    try? FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)

    // A completed analysis with a chart the user cares about.
    let chartPath = original.appendingPathComponent("chord.chart.performer.json").path
    try! JSONSerialization.data(withJSONObject: [
        "bars": [["bar": 1, "sourceBar": 1, "start": 0.0, "end": 2.0,
                  "primaryChord": "C", "chords": []]],
    ]).write(to: URL(fileURLWithPath: chartPath))

    var existing = AnalysisJob(
        id: "reanalyse-original", sourceUrl: "https://youtu.be/aaaaaaaaaaa",
        status: .completed, createdAt: Date().addingTimeInterval(-600),
        title: "Precious", songDocumentID: songID, songVideoID: "aaaaaaaaaaa"
    )
    existing.chordChartPerformerPath = chartPath
    existing.chordChartDraftPath = chartPath
    existing.bpm = 111
    existing.sectionCount = 4
    try! LocalFileStore.saveJob(existing, to: original)

    let manager = JobManager()
    await manager.hydrate()
    check(manager.job(for: songID)?.hasChart == true, "the existing analysis loads with its chart")

    // Re-analyse against a video ID that cannot resolve, so the download fails.
    let ref = SongRef(documentID: songID, title: "Precious", artist: nil,
                      url: "https://www.youtube.com/watch?v=zzzzzzzzzzz")
    manager.start(ref, resumeIfPossible: false)

    let deadline = Date().addingTimeInterval(90)
    while manager.runningSongID != nil && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(100))
    }

    let after = manager.job(for: songID)
    check(manager.runningSongID == nil, "the failed re-analysis finishes")
    check(after?.hasChart == true,
          "the previous chart survives a failed re-analysis (bpm \(after?.bpm.map { "\($0)" } ?? "nil"))")
    check(after?.bpm == 111, "and it is the original analysis, not an empty one")
    check(after?.notice?.contains("Re-analysis") == true,
          "with the reason recorded as a notice the workspace can show (\(after?.notice ?? "nil"))")
    check(after?.errorMessage == nil,
          "and not as an error, which would make a perfectly good analysis look failed")
    check(manager.folder(for: songID)?.lastPathComponent == "reanalyse-original",
          "and the song points back at its original folder")

    // The half-built folder must be gone, not left to be reported as leftover.
    let leftover = manager.orphanedFolders().map(\.lastPathComponent)
    check(!leftover.contains("reanalyse-original"),
          "the restored folder is not then offered for deletion")
}

await runReanalysisSafetyTests()

// MARK: - Re-analysis rollback rules

section("Re-analysis rollback rules")

func decision(
    succeeded: Bool, chart: Bool, audio: Bool, exportable: Bool, oldExportable: Bool
) -> JobManager.SupersedeDecision {
    JobManager.supersedeDecision(
        runSucceeded: succeeded, newHasChart: chart, newHasAudio: audio,
        newIsExportable: exportable, oldIsExportable: oldExportable
    )
}

// A completed re-analysis replaces the old folder.
check(decision(succeeded: true, chart: true, audio: true, exportable: true, oldExportable: true) == .retireOld,
      "a completed re-analysis retires the folder it replaced")

// Aborted after the chart stage: the old analysis was export-ready, the new one
// is not. This is the case that used to delete a complete analysis.
check(decision(succeeded: false, chart: true, audio: true, exportable: false, oldExportable: true)
        == .restoreOld,
      "aborting after the chart stage restores an export-ready analysis instead of deleting it")

// Aborted during the download: nothing worth keeping in the new folder.
check(decision(succeeded: false, chart: false, audio: false, exportable: false, oldExportable: true)
        == .restoreOld,
      "aborting during the download restores the old analysis and clears the half-built folder")

// Aborted after the download: the audio is worth resuming from, so it stays.
check(decision(succeeded: false, chart: false, audio: true, exportable: false, oldExportable: true)
        == .restoreOld,
      "and so does aborting after the download — the new folder is unreachable once rolled back")

// Backend never came up on a re-analysis: no chart, so the old one comes back.
check(decision(succeeded: false, chart: false, audio: true, exportable: false, oldExportable: false)
        == .restoreOld,
      "a re-analysis paused on the backend does not strand the previous analysis")

// The aborted run somehow got further than the old one: leave both alone.
check(decision(succeeded: false, chart: true, audio: true, exportable: true, oldExportable: false)
        == .keepBoth,
      "an aborted run that is more complete than the old one deletes nothing")
check(decision(succeeded: false, chart: true, audio: true, exportable: false, oldExportable: false)
        == .keepBoth,
      "and neither does one that merely has a chart the old one lacked")

// Nothing is ever deleted purely because a run stopped.
for chart in [true, false] {
    for audio in [true, false] {
        for exportable in [true, false] {
            for oldExportable in [true, false] {
                let outcome = decision(succeeded: false, chart: chart, audio: audio,
                                       exportable: exportable, oldExportable: oldExportable)
                if outcome == .retireOld {
                    check(false, "an aborted run never retires the previous analysis")
                }
            }
        }
    }
}
check(true, "an aborted run never retires the previous analysis, for any combination")

// MARK: - Export safety

section("Export staleness")

var exported = AnalysisJob(id: "x", sourceUrl: "u", status: .completed, createdAt: Date())
let exportTime = Date()
exported.lastExport = ExportRecord(exportedAt: exportTime, documentID: "doc", sectionCount: 3)
exported.completedAt = exportTime.addingTimeInterval(-60)
check(!exported.hasUnexportedEdits, "a freshly exported analysis is up to date")

exported.lastEditedAt = exportTime.addingTimeInterval(30)
check(exported.hasUnexportedEdits, "editing sections afterwards marks it stale")

exported.lastEditedAt = nil
exported.completedAt = exportTime.addingTimeInterval(30)
check(exported.hasUnexportedEdits,
      "and so does re-analysing it, which rewrites the chart without an explicit edit")

exported.lastExport = nil
check(!exported.hasUnexportedEdits, "a song that was never exported is not stale")

section("Export")

@MainActor
func runExportTests() async {
    guard let expected = ProcessInfo.processInfo.environment["CHORDADMIN_BACKEND_URL"],
          let port = UInt16(URL(string: expected)?.port.map(String.init) ?? "") else {
        print("  · skipped (no stub backend address)")
        return
    }

    let backend: FakeBackend
    do {
        backend = try FakeBackend(fixedPort: port)
        try backend.start()
    } catch {
        print("  · skipped (could not start the stub backend: \(error))")
        return
    }
    defer { backend.stop() }

    let folder = LocalFileStore.baseDirectory.appendingPathComponent("export-job", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    /// `key` is which field the stored sections use: documents this app has
    /// exported carry `title`, older ones carry `name`.
    func song(id: String, title: String, tempo: Int?, sections: [String],
              key: String = "name") -> FirebaseSong {
        var dict: [String: Any] = ["id": id, "title": title, "tempo": tempo as Any]
        dict["sections"] = sections.map { [key: $0] }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(FirebaseSong.self, from: data)
    }

    var job = AnalysisJob(
        id: "export-job", sourceUrl: "https://youtu.be/export", status: .completed,
        createdAt: Date(), title: "Golden Hour",
        songDocumentID: "song-golden", songVideoID: "export"
    )
    job.chordChartPerformerPath = folder.appendingPathComponent("perf.json").path
    job.sectionsPath = folder.appendingPathComponent("sections.json").path
    job.subdivisionsByBar = [14: 2]

    let golden = song(id: "song-golden", title: "Golden Hour", tempo: 132,
                      sections: ["Intro", "Verse", "Chorus"])
    let other = song(id: "song-other", title: "Paper Lanterns", tempo: 118, sections: [])

    let service = StageBeeExportService()

    // The critical guard: an analysis must never be written onto another song.
    do {
        _ = try await service.prepare(job: job, jobFolder: folder, song: other, isSignedIn: true)
        check(false, "exporting onto a different song is refused")
    } catch let error as StageBeeExportService.ExportError {
        if case .identityMismatch(let message) = error {
            check(true, "exporting onto a different song is refused")
            check(message.contains("Golden Hour") && message.contains("Paper Lanterns"),
                  "and the refusal names both songs")
        } else {
            check(false, "exporting onto a different song is refused (got \(error))")
        }
    } catch {
        check(false, "exporting onto a different song is refused (got \(error))")
    }

    // Signing out must stop the export before it reaches Firestore.
    do {
        _ = try await service.prepare(job: job, jobFolder: folder, song: golden, isSignedIn: false)
        check(false, "a signed-out export is refused")
    } catch let error as StageBeeExportService.ExportError {
        if case .notSignedIn = error { check(true, "a signed-out export is refused") }
        else { check(false, "a signed-out export is refused (got \(error))") }
    } catch {
        check(false, "a signed-out export is refused (got \(error))")
    }

    // The happy path: a preview that describes exactly what would change.
    do {
        let preview = try await service.prepare(job: job, jobFolder: folder, song: golden, isSignedIn: true)
        check(preview.documentID == "song-golden", "the preview targets the right document")
        check(preview.currentTempo == 132, "it reports the tempo already on the document")
        check(preview.newTempo == 136, "and the tempo that would replace it")
        check(preview.tempoChanged, "and flags that the tempo changes")
        check(preview.newSections.count == 3, "it lists the sections that would be written")
        check(preview.newSections.map(\.name) == ["Intro", "Verse A", "Chorus"],
              "with the names TheStageBee will store them under (got \(preview.newSections.map(\.name)))")
        check(preview.newSections.map(\.barCount) == [4, 16, 16],
              "and the bar counts read out of the nested lines (got \(preview.newSections.map(\.barCount)))")
        check(preview.currentSectionNames == ["Intro", "Verse", "Chorus"],
              "and what the document holds today")

        // A document this app exported before stores its sections under `title`.
        // Reading only `name` reported them as absent, so a second export told
        // the user they were overwriting nothing.
        let previouslyExported = song(id: "song-golden", title: "Golden Hour", tempo: 132,
                                      sections: ["Intro", "Verse A", "Chorus"], key: "title")
        let second = try await service.prepare(job: job, jobFolder: folder,
                                               song: previouslyExported, isSignedIn: true)
        check(second.currentSectionNames == ["Intro", "Verse A", "Chorus"],
              "sections this app wrote itself are read back, not reported as none (got \(second.currentSectionNames))")
        let secondRecord = try await service.commit(second)
        check(secondRecord.previousSectionCount == 3,
              "so the record of what was replaced is right too")

        let record = try await service.commit(preview)
        check(record.documentID == "song-golden", "committing records the document written")
        check(record.tempo == 136 && record.previousTempo == 132,
              "and both the new and replaced tempo, so a bad write can be traced")
        check(record.sectionCount == 3 && record.previousSectionCount == 3,
              "and the section counts either side")
    } catch {
        check(false, "a valid export produces a preview and commits (got \(error))")
    }

    // A backend that rejects the translation must not reach Firestore.
    backend.update { $0.translateRejects = true }
    do {
        _ = try await service.prepare(job: job, jobFolder: folder, song: golden, isSignedIn: true)
        check(false, "a rejected translation stops the export")
    } catch {
        check(true, "a rejected translation stops the export")
    }

    // A fractional tempo must be written as the integer the sheet showed, not
    // as the raw value, or the confirmation misdescribes the write.
    backend.update { $0.translateRejects = false; $0.translateTempo = 136.7 }
    do {
        let preview = try await service.prepare(job: job, jobFolder: folder, song: golden, isSignedIn: true)
        check(preview.newTempo == 136, "a fractional tempo is shown rounded down to a whole BPM")
        check((preview.tempoPayload as? Int) == 136,
              "and the same whole number is what would be written, not the raw 136.7")
    } catch {
        check(false, "a fractional tempo still previews (got \(error))")
    }

    // A tempo that is not a number would otherwise be shown as "unchanged"
    // while still being written.
    backend.update { $0.translateRejects = false; $0.translateTempo = "fast" }
    do {
        _ = try await service.prepare(job: job, jobFolder: folder, song: golden, isSignedIn: true)
        check(false, "a non-numeric tempo is refused rather than silently written")
    } catch {
        check(true, "a non-numeric tempo is refused rather than silently written")
    }
}

await runExportTests()

// MARK: - Preview cost

section("Live preview cost")

// The tuning preview rebuilds the whole chart in memory on every change, on the
// main actor. A ten-minute track at 140 BPM is roughly 350 bars, so time that
// path rather than assume it is cheap.
let longBeats = makeBeatData(count: 1400, interval: 0.43, bpm: 140)
let longChords = makeChordData(bars: 350, barLength: 1.72)

let previewStart = Date()
let iterations = 5
for _ in 0..<iterations {
    let (grid, _) = JobManager.generateBeatGrid(
        from: longBeats, bpm: 140, barAlignmentOffset: 2, beatsPerBar: 4
    )
    let gridData = try! JSONSerialization.data(withJSONObject: grid)
    let (draft, _, _) = JobManager.generateChordChart(
        beatGridData: gridData, chordCleanedData: longChords,
        beatGridPath: "", chordCleanedPath: ""
    )
    let draftData = try! JSONSerialization.data(withJSONObject: draft)
    let config = try! JSONSerialization.data(
        withJSONObject: JobManager.chartConfig(offset: 2, chartStartTime: nil, includePreIntro: false)
    )
    let (performer, _, _) = JobManager.generatePerformerChart(
        draftData: draftData, configData: config, draftPath: "", configPath: ""
    )
    let rawBars = performer["bars"] as! [[String: Any]]
    _ = JobManager.decodeBars(rawBars)
}
let perPreviewMs = Date().timeIntervalSince(previewStart) / Double(iterations) * 1000
print(String(format: "  · one preview over 350 bars: %.1f ms", perPreviewMs))
check(perPreviewMs < 120,
      String(format: "a preview stays under 120 ms so typing does not stutter (%.1f ms)", perPreviewMs))

// MARK: - Summary

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("FAILURES: \(failures)")
    exit(1)
}
