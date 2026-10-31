import Foundation

/// The song form, checked against a chart corrected by hand: နမၤနၢၤယဝံကလၤ as
/// Frankie fixed it in TheStageBee on 30 October 2026 (four identical verses
/// with a 6/4 fourth bar, choruses ending where the next one's head begins, a
/// 6/4 final bar). Inputs are that job's own beat and chord files.
@MainActor
func runSongFormTests() {
    section("Song form from section signatures")
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/song-form-namanaw")
    func json(_ name: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(name))) as! [String: Any]
    }
    let meta = json("meta.json")
    let expected = json("expected.json")
    let expectedSections = expected["sections"] as! [[String: Any]]
    let beatData = try! Data(contentsOf: folder.appendingPathComponent("beat.detection.json"))
    let chordData = try! Data(contentsOf: folder.appendingPathComponent("chord.cleaned.json"))

    let started = Date()
    guard let form = SongForm.analyse(beatData: beatData, cleanedChordData: chordData,
                                      audioEnd: (meta["audioEnd"] as! NSNumber).doubleValue) else {
        check(false, "the corrected song yields a form")
        return
    }
    let seconds = Date().timeIntervalSince(started)
    check(seconds < 3, String(format: "analysis of a six-minute song is quick (%.2f s)", seconds))

    check(form.key == expected["key"] as? String, "key is \(form.key), as corrected (Em)")
    check(form.sections.map(\.name) == expectedSections.map { $0["title"] as! String },
          "sections and their names match the corrected chart: \(form.sections.map(\.name).joined(separator: ", "))")
    let expectedBars = expectedSections.map { $0["bars"] as! [[String: Any]] }
    check(form.sections.map(\.bars.count) == expectedBars.map(\.count), "every section has the corrected number of bars")
    check(form.sections.flatMap { $0.bars.map(\.beats) } == expectedBars.flatMap { $0.map { $0["beats"] as! Int } },
          "every bar's length matches, the 6/4 bars included")

    // TheStageBee spells minor with an uppercase M and flats with @.
    func stageBee(_ name: String) -> SongForm.Harmony? {
        var n = name.replacingOccurrences(of: "@", with: "b")
        if let r = n.range(of: #"^[A-G][#b]?M(?!aj)"#, options: .regularExpression) {
            n.replaceSubrange(r, with: String(n[r].dropLast()) + "m")
        }
        return SongForm.harmony(n)
    }
    var chordMismatches: [String] = []
    var structureMismatches: [String] = []
    for (section, bars) in zip(form.sections, expectedBars) where section.name != "Intro" {
        for (i, (bar, want)) in zip(section.bars, bars).enumerated() {
            if bar.chords.map({ SongForm.harmony($0.name) }) != (want["chords"] as! [String]).map(stageBee) {
                chordMismatches.append("\(section.name) bar \(i + 1)")
            } else if bar.structure != want["structure"] as? String {
                structureMismatches.append("\(section.name) bar \(i + 1)")
            }
        }
    }
    // The intro's half-bar chords and colours (Em(add9) G | Dsus2) need the
    // audio check; recognition alone reads whole-bar Em | D | Em | Asus4.
    check(chordMismatches.isEmpty, "every chord after the intro matches \(chordMismatches)")
    check(structureMismatches.isEmpty, "chord spacing in every bar matches \(structureMismatches)")

    let verses = form.sections.filter { $0.name.hasPrefix("Verse") }
    check(verses.count == 4 && Set(verses.map(\.letter)).count == 1, "the four verses are one repeated section")
    check(verses.allSatisfy { $0.bars.count == 8 && $0.bars[3].beats == 6 && $0.bars.last?.chords.map(\.name) == ["Em"] },
          "each verse's 6/4 is its fourth bar, and each ends on its held Em")
    if let second = form.sections.first(where: { $0.name == "Verse 2" }) {
        check(abs(form.beatEdges[second.startBeat] - 60.08) < 0.1, "Verse 2 starts at 1:00, where the drums come in")
    }
    let choruses = form.sections.filter { $0.name.hasPrefix("Chorus") }
    check(choruses.allSatisfy { $0.bars.prefix(4).map { $0.chords.map(\.name) } == [["Em"], ["G"], ["Am"], ["Em"]] },
          "every chorus begins on its own head, Em | G | Am | Em")
    check(form.sections.last?.bars.last?.beats == 6, "the final chord rings out over a 6/4 last bar")

    // — Into the chart pipeline —
    let grid = JobManager.formBeatGrid(form, bpm: 66.67)
    let chords = JobManager.formChords(form)
    let gridData = try! JSONSerialization.data(withJSONObject: grid)
    let chordsData = try! JSONSerialization.data(withJSONObject: chords)
    let (draft, draftBars, _) = JobManager.generateChordChart(beatGridData: gridData, chordCleanedData: chordsData,
                                                              beatGridPath: "", chordCleanedPath: "")
    check(draftBars == form.bars.count, "the chart has one bar per form bar (\(draftBars))")
    check((draft["warnings"] as? [String])?.isEmpty == true, "no chart bar is left without a chord")
    let config = try! JSONSerialization.data(withJSONObject: JobManager.chartConfig(offset: 0, chartStartTime: nil,
                                                                                    includePreIntro: false))
    let (performer, performerBars, _) = JobManager.generatePerformerChart(
        draftData: try! JSONSerialization.data(withJSONObject: draft), configData: config, draftPath: "", configPath: "")
    let performerData = try! JSONSerialization.data(withJSONObject: performer)
    check(performerBars == form.bars.count, "the performer chart keeps every form bar")
    let performerChords = (performer["bars"] as! [[String: Any]]).map { bar in
        (bar["chords"] as! [[String: Any]]).map { $0["displayChord"] as! String }
    }
    check(performerChords == form.bars.map { $0.chords.map(\.name) }, "the performer chart shows the form's chords bar for bar")
    let sections = JobManager.sectionsFromForm(form, performerData: performerData)?["sections"] as? [[String: Any]] ?? []
    check(sections.map { $0["name"] as? String ?? "" } == form.sections.map(\.name)
          && sections.map { ($0["bars"] as? [Int])?.count ?? 0 } == form.sections.map(\.bars.count),
          "sections.json carries the form's sections over the chart's bar numbers")

    // — Export —
    let translated: [[String: Any]] = form.sections.map { section in
        ["title": section.name, "timeSignature": [4, 4],
         "lines": stride(from: 0, to: section.bars.count, by: 4).map { start in
             ["bars": section.bars[start..<min(start + 4, section.bars.count)].map { bar in
                 ["structure": bar.chords.count > 1 ? "1fr 3fr" : "1fr", "timeSignature": [4, 4],
                  "chords": bar.chords.map { ["chord": $0.name, "hit": false, "pause": false] }] as [String: Any]
             }] as [String: Any]
         }] as [String: Any]
    }
    let fixed = StageBeeExportService.applyingFormMeter(to: translated, form: form) as! [[String: Any]]
    let fixedBars = fixed.flatMap { ($0["lines"] as! [[String: Any]]).flatMap { $0["bars"] as! [[String: Any]] } }
    check(zip(fixedBars, form.bars).allSatisfy { ($0["timeSignature"] as! [Int]) == [$1.beats, 4] },
          "the export writes each bar's own time signature")
    check(zip(fixedBars, form.bars).filter { $1.beats == 6 && $1.chords.count == 2 }
            .allSatisfy { $0.0["structure"] as? String == "1fr 2fr" },
          "a 6/4 bar of D for two beats and G for four is spaced 1fr 2fr, not the translator's guess")
    if let odd = form.bars.firstIndex(where: { $0.beats == 6 && $0.chords.count == 2 }) {
        let kept = StageBeeExportService.applyingFormMeter(to: translated, form: form, editedBars: [odd + 1]) as! [[String: Any]]
        let keptBar = kept.flatMap { ($0["lines"] as! [[String: Any]]).flatMap { $0["bars"] as! [[String: Any]] } }[odd]
        check(keptBar["structure"] as? String == "1fr 3fr" && (keptBar["timeSignature"] as! [Int]) == [6, 4],
              "a 6/4 bar whose subdivision the owner set keeps the translator's spacing but still gets its meter")
    } else {
        check(false, "the fixture has a two-chord 6/4 bar to test subdivision edits on")
    }
    var shortened = translated
    shortened.removeLast()
    let untouched = StageBeeExportService.applyingFormMeter(to: shortened, form: form) as! [[String: Any]]
    check(untouched.count == shortened.count
          && untouched.flatMap { ($0["lines"] as! [[String: Any]]).flatMap { $0["bars"] as! [[String: Any]] } }
             .allSatisfy { ($0["timeSignature"] as! [Int]) == [4, 4] },
          "a chart whose bars no longer match the form is exported as it is")

    // — Parts —
    check(SongForm.Key(tonic: 8, minor: false).accidental == "b"
          && SongForm.Key(tonic: 4, minor: false).accidental == "#"
          && SongForm.Key(tonic: 5, minor: true).accidental == "b"
          && SongForm.Key(tonic: 9, minor: true).accidental == nil
          && SongForm.Key(tonic: 1, minor: false, spelling: .sharps).accidental == "#",
          "flat keys write flats, sharp keys sharps, C and Am leave the detector's spelling")
    check(SongForm.respelled("C#", accidental: "b") == "Db"
          && SongForm.respelled("G#m7/D#", accidental: "b") == "Abm7/Eb"
          && SongForm.respelled("Bbm/b3", accidental: "#") == "A#m/b3"
          && SongForm.respelled("Eb/G", accidental: "b") == "Eb/G",
          "a chord's root and bass are respelt, a bass degree is left alone")
    check(SongForm.harmony("F#m7") == SongForm.Harmony(root: 6, quality: .minor)
          && SongForm.harmony("Ab/b7") == SongForm.Harmony(root: 8, quality: .major)
          && SongForm.harmony("Dsus2") == SongForm.Harmony(root: 2, quality: .sus2)
          && SongForm.harmony("Cmaj7") == SongForm.Harmony(root: 0, quality: .major)
          && SongForm.harmony("N.C.") == nil,
          "chords reduce to root and quality; colours and bass notes don't change the match")
    func key(_ names: [String]) -> String {
        SongForm.estimateKey(names.flatMap { Array(repeating: SongForm.harmony($0), count: 4) }).name
    }
    check(key(["C", "F", "G", "C", "Am", "F", "G", "C"]) == "C", "a song centred on C is in C")
    check(key(["Am", "Dm", "E", "Am", "F", "G", "E", "Am"]) == "Am", "a major V resolving to a minor tonic is a minor key")
    check(key(["C#m", "A", "B", "E", "C#m", "A", "B", "E"]) == "E",
          "a progression that sits equally in E and C#m reads as the major key")
    let verseChanges: [Int: Int] = [2: 2, 4: 2, 6: 4, 10: 2, 12: 2, 14: 4, 18: 2, 20: 2, 22: 2, 24: 2, 26: 2, 28: 2, 30: 4]
    check(SongForm.layout(changes: verseChanges, length: 34, meter: 4) == [4, 4, 4, 6, 4, 4, 4, 4],
          "a 34-beat verse puts its 6/4 at the end of the first phrase, not first")
    check(SongForm.layout(changes: [4: 4, 8: 4, 12: 4], length: 16, meter: 4) == [4, 4, 4, 4],
          "whole-bar chords keep plain 4/4 bars")

    // — Vocals —
    let perBar: [String: Any] = ["status": "success", "boundaries": [["time": 0.0, "sung": true]],
                                 "barVocals": [["bar": 1, "start": 0.0, "end": 2.0, "sung": false],
                                               ["bar": 2, "start": 2.0, "end": 4.0, "sung": true],
                                               ["bar": 3, "start": 4.0, "end": 6.0, "sung": true],
                                               ["bar": 4, "start": 6.0, "end": 8.0, "sung": false]]]
    let spans = SongForm.vocals(fromStructure: try! JSONSerialization.data(withJSONObject: perBar))
    check(spans?.map(\.start) == [0, 2, 6] && spans?.map(\.sung) == [false, true, false],
          "per-bar vocal activity is preferred to the coarse section flags")
    let coarse: [String: Any] = ["boundaries": [["time": 0.0, "sung": false], ["time": 9.5, "sung": true]]]
    check(SongForm.vocals(fromStructure: try! JSONSerialization.data(withJSONObject: coarse))?.map(\.start) == [0, 9.5],
          "an older backend's section flags still work")

    // — Reading the form again when vocal timing arrives —
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("song-form-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    for file in ["beat.detection.json", "chord.cleaned.json"] {
        try! FileManager.default.copyItem(at: folder.appendingPathComponent(file), to: work.appendingPathComponent(file))
    }
    var job = AnalysisJob(id: "song-form-vocals", sourceUrl: "https://youtu.be/x", status: .completed, createdAt: Date())
    job.beatDetectionPath = work.appendingPathComponent("beat.detection.json").path
    job.chordCleanedPath = work.appendingPathComponent("chord.cleaned.json").path
    if let first = JobManager.applyForm(job: &job, folder: work, beatData: beatData, cleanedData: chordData),
       (try? JobManager.buildCharts(job: &job, folder: work, gridPath: first.gridPath, gridData: first.gridData,
                                    cleanedPath: first.cleanedPath, cleanedData: first.cleanedData)) != nil,
       let stem = try? Data(contentsOf: folder.appendingPathComponent("vocals.backend.json")),
       let realVocals = SongForm.vocals(fromStructure: stem) {
        check((try? JobManager.reapplyForm(job: &job, folder: work, vocals: realVocals)) == nil,
              "the song's own vocal timing confirms its form, so nothing is rebuilt")
        // No singing anywhere: every verse and chorus becomes an instrumental.
        let vocals = [SongForm.VocalSpan(start: 0, sung: false)]
        let before = JobManager.loadForm(job: job)
        let refreshed = try? JobManager.reapplyForm(job: &job, folder: work, vocals: vocals)
        let performerBars = (refreshed.flatMap { try? JSONSerialization.jsonObject(with: $0.performerData) as? [String: Any] }?["bars"] as? [Any])?.count
        check(refreshed != nil && refreshed?.form.sections != before?.sections
              && performerBars == refreshed?.form.bars.count && JobManager.loadForm(job: job) == refreshed?.form,
              "vocal timing that changes the form rebuilds the chart from it")
        check((try? JobManager.reapplyForm(job: &job, folder: work, vocals: vocals)) == nil,
              "the same vocal timing a second time changes nothing and rebuilds nothing")
    } else {
        check(false, "the reference song's form and chart build in a scratch folder")
    }
}

/// Section boundaries against every chart corrected by hand
/// (`Fixtures/song-form-*/truth.json`), within 0.6 s. The total is a ceiling
/// to keep, not a goal: lower it when a change improves the form analysis.
@MainActor
func runSongFormCorpusTests() {
    section("Song form across the corrected songs")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
        .filter { $0.hasPrefix("song-form-") }.sorted() ?? []
    func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    var total = 0, songs = 0
    for name in names {
        let folder = root.appendingPathComponent(name)
        guard let truth = json(folder.appendingPathComponent("truth.json"))?["sectionStarts"] as? [NSNumber],
              let meta = json(folder.appendingPathComponent("meta.json")),
              let beats = try? Data(contentsOf: folder.appendingPathComponent("beat.detection.json")),
              let chords = try? Data(contentsOf: folder.appendingPathComponent("chord.cleaned.json")) else { continue }
        // The backend's per-bar vocal activity, as the app receives it.
        let vocalData = try? Data(contentsOf: folder.appendingPathComponent("vocals.backend.json"))
        guard let form = SongForm.analyse(beatData: beats, cleanedChordData: chords,
                                          audioEnd: (meta["audioEnd"] as? NSNumber)?.doubleValue,
                                          vocals: vocalData.flatMap { SongForm.vocals(fromStructure: $0) }) else {
            check(false, "\(name) yields a form")
            continue
        }
        let starts = form.sections.dropFirst().map { form.beatEdges[$0.startBeat] }
        let expected = truth.map(\.doubleValue)
        let missed = expected.filter { t in !starts.contains { abs($0 - t) < 0.6 } }.count
        let extra = starts.filter { t in !expected.contains { abs($0 - t) < 0.6 } }.count
        print("  · \(name): \(missed) missed, \(extra) extra of \(expected.count) boundaries")
        total += missed + extra
        songs += 1
    }
    check(songs >= 8, "all \(songs) corrected songs are measured")
    check(total <= 85, "boundary errors across the corrected songs stay within 85 (\(total))")
}
