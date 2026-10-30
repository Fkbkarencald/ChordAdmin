import Foundation

@MainActor
func runTimingIntegrationTests() async {
    section("Downbeat and audio-structure pipeline integration")
    guard let expected = ProcessInfo.processInfo.environment["CHORDADMIN_BACKEND_URL"],
          let port = URL(string: expected)?.port,
          let backend = try? FakeBackend(fixedPort: UInt16(port)) else {
        check(false, "timing integration has an isolated backend address")
        return
    }
    do { try backend.start() }
    catch { check(false, "timing integration backend starts: \(error)"); return }
    defer { backend.stop() }
    backend.update {
        $0.beatPositions = (0..<64).map { ($0 + 2) % 4 + 1 }
        $0.suggestedPickupBeats = 2
    }

    func waitUntil(_ predicate: () -> Bool, seconds: Double = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    func seed(_ suffix: String, offset: Int? = nil) async -> (JobManager, SongRef, URL, Data) {
        let id = "timing-integration-" + suffix
        let folder = LocalFileStore.baseDirectory.appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = Data(repeating: 0x37, count: 2048)
        let wav = folder.appendingPathComponent("analysis.wav")
        try? audio.write(to: wav)
        var job = AnalysisJob(id: id, sourceUrl: "https://youtu.be/" + id, status: .audioReady,
                              createdAt: Date(), title: "Timing " + suffix,
                              songDocumentID: id, songVideoID: id)
        job.analysisWavPath = wav.path
        job.barAlignmentOffset = offset
        var report = StageReport()
        for stage in PipelineStage.audioStages { report.set(stage, .done) }
        job.stageReport = report
        try? LocalFileStore.saveJob(job, to: folder)
        let manager = JobManager()
        await manager.hydrate()
        let song = SongRef(documentID: id, title: "Timing " + suffix, artist: nil, url: job.sourceUrl)
        return (manager, song, folder, audio)
    }

    func read(_ path: String?) -> [String: Any]? {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // This catches inferred pickup being lost by finish/adoptUserEdits, which a
    // pure resolver test cannot observe: every persisted representation agrees.
    let (automatic, automaticSong, automaticFolder, automaticAudio) = await seed("automatic")
    automatic.start(automaticSong, resumeIfPossible: true)
    check(await waitUntil({ !automatic.isBusy }), "automatic-downbeat resume finishes")
    let auto = automatic.job(for: automaticSong.documentID)
    check(auto?.status == .completed || auto?.status == .completedWithWarnings,
          "the automatic-downbeat pipeline completes successfully")
    check(auto?.barAlignmentOffset == 2, "stage completion persists the detected two-beat pickup")
    check(read(auto?.beatGridPath)?["barAlignmentOffset"] as? Int == 2,
          "the saved beat grid uses that same pickup")
    check(read(auto?.chartConfigPath)?["barAlignmentOffset"] as? Int == 2,
          "the saved chart configuration agrees with the detected pickup")
    check(TuningDraft.from(job: auto).offset == 2,
          "the tuning picker reopens on the pickup the chart actually uses")
    let saved = try? Data(contentsOf: automaticFolder.appendingPathComponent("job.json"))
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let persisted = saved.flatMap { try? decoder.decode(AnalysisJob.self, from: $0) }
    check(persisted?.barAlignmentOffset == 2, "job.json retains the detected pickup across hydration")
    check((try? Data(contentsOf: automaticFolder.appendingPathComponent("analysis.wav"))) == automaticAudio,
          "automatic pickup reuses the saved audio without rewriting it")

    func barOne(_ job: AnalysisJob?) -> Double? {
        ((read(job?.beatGridPath)?["bars"] as? [[String: Any]])?.first?["start"] as? NSNumber)?.doubleValue
    }
    // Re-detection returns a track that starts on a different beat. Reusing the
    // old pickup count would put bar 1 on the wrong beat of the new track.
    backend.update {
        $0.beats = (0..<64).map { 0.25 + Double($0) * 0.5 }
        $0.beatPositions = (0..<64).map { ($0 + 3) % 4 + 1 }
        $0.suggestedPickupBeats = 1
    }
    await automatic.redetectBeats(songID: automaticSong.documentID)
    let redetected = automatic.job(for: automaticSong.documentID)
    check(redetected?.barAlignmentOffset == 1 && barOne(redetected) == 0.75,
          "re-detection adopts the new track's downbeat instead of the old pickup count")
    await automatic.regenerateCharts(songID: automaticSong.documentID, offset: 3)
    check(automatic.job(for: automaticSong.documentID)?.pickupChosenManually == true
          && barOne(automatic.job(for: automaticSong.documentID)) == 1.75,
          "a pickup applied in Tuning is recorded as the owner's choice")
    backend.update {
        $0.beats = (0..<64).map { 0.75 + Double($0) * 0.5 }
        $0.beatPositions = (0..<64).map { $0 % 4 + 1 }
        $0.suggestedPickupBeats = 0
    }
    await automatic.redetectBeats(songID: automaticSong.documentID)
    let anchored = automatic.job(for: automaticSong.documentID)
    check(anchored?.barAlignmentOffset == 2 && barOne(anchored) == 1.75,
          "the owner's bar 1 stays at the same time on a re-detected track")

    let (manual, manualSong, _, _) = await seed("manual-zero", offset: 0)
    manual.start(manualSong, resumeIfPossible: true)
    check(await waitUntil({ !manual.isBusy }), "manual-pickup resume finishes")
    let kept = manual.job(for: manualSong.documentID)
    check(kept?.barAlignmentOffset == 0
          && read(kept?.beatGridPath)?["barAlignmentOffset"] as? Int == 0
          && read(kept?.chartConfigPath)?["barAlignmentOffset"] as? Int == 0,
          "an explicit saved zero survives a conflicting automatic proposal everywhere")

    // Hold a real HTTP structure request open, then edit through SectionStore.
    // The analysis may save new evidence, but must not replace the owner's file.
    backend.update {
        $0.structureCapability = true
        $0.structureDelay = 1.5
        $0.structureResponse = [
            "status": "success", "version": 1, "method": "multiscale-audio-novelty",
            "boundaries": [["bar": 1, "time": 1.0, "score": 1.0],
                           ["bar": 9, "time": 17.0, "score": 0.9]],
            "warnings": [String](),
        ]
    }
    let requestsBefore = backend.requestedPaths.filter { $0 == "/api/detect-structure" }.count
    let (editing, editingSong, editingFolder, _) = await seed("mid-analysis-edit")
    editing.start(editingSong, resumeIfPossible: true)
    let inFlight = await waitUntil {
        backend.requestedPaths.filter { $0 == "/api/detect-structure" }.count > requestsBefore
    }
    check(inFlight && editing.isBusy, "structure analysis is genuinely in flight before the owner edits")
    let store = SectionStore()
    if let live = editing.job(for: editingSong.documentID), inFlight {
        store.onEdit = { editing.noteEdit(songID: editingSong.documentID) }
        store.load(for: live, jobFolder: editingFolder)
        if let first = store.sections.first { store.rename(section: first.id, to: "Owner's opening") }
        store.startNewSection(at: 5)
        let sectionPath = editingFolder.appendingPathComponent("sections.json")
        let ownerBytes = try? Data(contentsOf: sectionPath)
        check(store.saveError == nil && store.sections.first?.name == "Owner's opening"
              && store.sections.contains { $0.startBar == 5 },
              "owner rename and split have landed while analysis is waiting")
        check(await waitUntil({ !editing.isBusy }), "the delayed structure pipeline still finishes")
        let finished = editing.job(for: editingSong.documentID)
        check(finished?.status == .completed || finished?.status == .completedWithWarnings,
              "preserving edits does not fail successful structure processing")
        check(ownerBytes != nil && (try? Data(contentsOf: sectionPath)) == ownerBytes,
              "the owner's section file survives the asynchronous result byte for byte")
        check(finished?.audioStructurePath.map { FileManager.default.fileExists(atPath: $0) } == true,
              "new audio-structure evidence is still saved for later review")
        let candidates = read(finished?.sectionCandidatesPath)
        check((candidates?["audioBoundaries"] as? [[String: Any]])?.count == 2,
              "candidate audio boundaries are available without replacing saved sections")

        // An existing completed job can refresh suggestions without rebuilding
        // anything that the owner has already tuned or labelled.
        backend.update { $0.structureDelay = 0 }
        let preservedPaths = [sectionPath.path, finished?.chordChartDraftPath,
                              finished?.chordChartPerformerPath, finished?.chartConfigPath,
                              finished?.beatGridPath, finished?.analysisWavPath].compactMap { $0 }
        let preserved = preservedPaths.reduce(into: [String: Data]()) { snapshot, path in
            snapshot[path] = try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        let refreshError = await editing.refreshAudioStructure(songID: editingSong.documentID)
        check(refreshError == nil, "a completed saved job can refresh acoustic suggestions")
        check(preserved.count == preservedPaths.count
              && preserved.allSatisfy { path, bytes in
                  (try? Data(contentsOf: URL(fileURLWithPath: path))) == bytes
              }, "refresh leaves owner sections, charts, timing and WAV byte for byte unchanged")
        let refreshed = editing.job(for: editingSong.documentID)
        check(refreshed?.audioStructurePath.map { FileManager.default.fileExists(atPath: $0) } == true,
              "refresh stores reviewable acoustic evidence for the existing job")
        check(!editing.isBusy && editing.structureAnalyzingSongID == nil,
              "successful refresh releases its busy state")

        backend.update { $0.structureCapability = false }
        let unsupported = await editing.refreshAudioStructure(songID: editingSong.documentID)
        check(unsupported?.contains("does not support") == true,
              "an older backend gives a readable unsupported-refresh error")
        check(preserved.allSatisfy { path, bytes in
            (try? Data(contentsOf: URL(fileURLWithPath: path))) == bytes
        }, "unsupported refresh also preserves all saved work")
        check(!editing.isBusy && editing.structureAnalyzingSongID == nil,
              "unsupported refresh releases its busy state")

        // "Detect sections again" refreshes first, so a song analysed by an
        // older engine picks up the current engine's named sections.
        backend.update {
            $0.structureCapability = true
            $0.structureResponse = [
                "status": "success", "version": 2, "method": "bar-repetition-novelty",
                "boundaries": [["bar": 1, "time": 1.0, "score": 1.0, "label": "A", "name": "Intro"],
                               ["bar": 9, "time": 17.0, "score": 0.9, "label": "B", "name": "Verse 1"]],
                "warnings": [String](),
            ]
        }
        check(await editing.refreshAudioStructure(songID: editingSong.documentID) == nil,
              "a refresh against the current engine succeeds")
        if let current = editing.job(for: editingSong.documentID), store.isLoaded(for: current) {
            store.autoDetectSections(for: current)
            check(store.sections.map(\.name) == ["Intro", "Verse 1"],
                  "re-detecting after a refresh applies the current engine's section names")
        } else {
            check(false, "the refreshed job is still the one loaded for section editing")
        }
    } else {
        check(false, "a current chart is available for the owner-edit preservation test")
        _ = await waitUntil({ !editing.isBusy })
    }
    check(!backend.requestedPaths.contains("/api/translate-to-stagebee"),
          "timing and structure verification never publishes or translates a song")
}
