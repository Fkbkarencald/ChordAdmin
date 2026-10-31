import Foundation

@MainActor
final class MemoryImportStore: SongImportProcessingStore {
    var record: SongImportRecord
    var denyAccess = false
    let actor = SongImportReviewer(id: "owner", name: "Owner", canReview: true)
    init(_ record: SongImportRecord) { self.record = record }
    func load(_ id: String) async throws -> SongImportRecord {
        if denyAccess { throw SongImportWorkflowError.permissionDenied }
        return record
    }
    func markStep(_ step: SongImportProcessingStep, state: SongImportStepState, error: String?, in record: SongImportRecord) async throws {
        guard self.record.mediaStatus.first(where: { $0.step == step })?.state != state else { return }
        try self.record.recordStep(step, state: state, error: error, actor: actor)
    }
    func queueRetry(_ record: SongImportRecord) async throws -> [SongImportProcessingStep] {
        try self.record.queueRetryOfFailedSteps(reviewer: actor)
    }
    func beginProcessing(_ record: SongImportRecord, fresh: Bool) async throws {
        try self.record.beginProcessing(fresh: fresh, actor: actor)
    }
    func attachPayload(_ payload: Data, to record: SongImportRecord) async throws {
        _ = try SongImportPayload.validate(payload)
        self.record.publicationPayload = payload
        try self.record.recordStep(.translation, state: .succeeded, actor: actor)
    }
}

@MainActor
func runImportReviewTests() async {
    section("Song import review")
    let owner = SongImportReviewer(id: "owner", name: "Owner", canReview: true)
    let stranger = SongImportReviewer(id: "stranger", name: "Stranger", canReview: false)
    let source = SongImportSource(url: "https://youtu.be/AbC_dEf-123")
    let fields = SongImportFields(title: "A song", artist: "An artist", key: "C", link: source.url)
    let record = SongImportRecord.staged(id: "new-import", source: source, detectedFields: fields, actor: owner)
    func refuses(_ label: String, _ action: () throws -> Void) {
        do { try action(); check(false, label) } catch { check(true, label) }
    }
    check(record.workspaceID != SongImportNormalizer.canonicalSongID(targetSongID: nil, source: source, stagingID: record.id),
          "a draft analysis never uses the canonical Firestore song ID")
    check(!SongImportSource(url: "https://www.youtube.com/watch?v=AbC_dEf-123&token=private&list=playlist").url.contains("private"),
          "stored YouTube sources drop unrelated and access-bearing URL parameters")
    check(SongImportSource(url: "https://www.youtube.com/shorts/AbC_dEf-123").stableIdentifier == source.stableIdentifier,
          "shorts and short links resolve to the same source")
    check(SongRef.youTubeVideoID(from: "https://youtube.com.attacker.example/watch?v=AbC_dEf-123") == nil,
          "a lookalike host is not accepted as YouTube")
    check(SongImportNormalizer.canonicalSongID(targetSongID: nil, source: source, stagingID: record.id)
          != SongImportNormalizer.canonicalSongID(targetSongID: nil, source: SongImportSource(url: "https://youtu.be/abc_def-123"), stagingID: record.id),
          "case-sensitive video IDs never collapse into the same canonical ID")
    var pending = record
    refuses("an import without analysis cannot be approved") { _ = try pending.approve(reviewer: owner) }
    refuses("a non-reviewer cannot edit metadata") { try pending.edit(fields: fields, reviewer: stranger) }
    refuses("a non-reviewer cannot reject an import") { try pending.reject(reviewer: stranger, reason: "no") }
    refuses("retry without a failure is refused") { _ = try pending.queueRetryOfFailedSteps(reviewer: owner) }
    let duplicate = SongImportCandidate(recordID: "existing-song", source: source, fields: fields)
    try? pending.edit(fields: fields, existing: [duplicate], reviewer: owner)
    check(pending.duplicateCandidates.count == 1, "editing recomputes stable-source duplicates")
    let titleCandidate = SongImportCandidate(recordID: "same-title", source: SongImportSource(url: "https://youtu.be/another"),
        fields: SongImportFields(title: "A SONG!", artist: "An Ártist", link: "https://youtu.be/another"))
    check(SongImportDuplicateDetector.candidates(source: source, fields: fields, among: [titleCandidate]).count == 1,
          "normalised artist/title matching finds duplicates from another URL")
    var changedLink = fields
    changedLink.link = "https://youtu.be/different"
    check(!SongImportValidator.warnings(for: changedLink, source: source).isEmpty,
          "reviewed metadata cannot quietly switch the source video")
    try? pending.reject(reviewer: owner, reason: "token=private-value")
    check(!pending.history.last!.detail.contains("private-value"), "audit details redact secrets")
    refuses("a rejected import cannot be reopened by processing") {
        try pending.recordStep(.analysis, state: .running, actor: owner)
    }

    let sections = [FakeBackend.section(titled: "Verse", bars: 4)]
    let payload = try! SongImportPayload.data(sections: sections, tempo: 120)
    check((try? SongImportPayload.validate(payload)) != nil, "a real nested StageBee chart validates")
    refuses("an empty nested chart is refused") {
        _ = try SongImportPayload.data(sections: [["title": "Verse", "lines": [["bars": []]]]], tempo: 120)
    }
    refuses("boolean tempo is refused") { _ = try SongImportPayload.data(sections: sections, tempo: true) }
    refuses("zero tempo is refused") { _ = try SongImportPayload.data(sections: sections, tempo: 0) }
    let threeFour: [String: Any] = ["sections": [["lines": [["bars": [["timeSignature": [3, 4]]]]]]]]
    check(SongImportPayload.timeSignature(threeFour) == [3, 4], "publication retains the reviewed metre")
    var ready = SongImportRecord.staged(id: "ready", source: source, detectedFields: fields,
                                        publicationPayload: payload, actor: owner)
    var duplicateReady = ready
    duplicateReady.duplicateCandidates = [SongImportDuplicateCandidate(recordID: "existing-song", title: "A song", artist: "An artist", reason: .stableSourceIdentifier)]
    refuses("a duplicate cannot be approved") { _ = try duplicateReady.approve(reviewer: owner) }
    let expected = ready
    try? ready.edit(fields: fields, reviewer: owner, now: ready.updatedAt.addingTimeInterval(1))
    refuses("a metadata edit invalidates an open publication preview") { _ = try ready.approve(expected: expected, reviewer: owner) }
    var restarted = ready
    try? restarted.beginProcessing(fresh: true, actor: owner)
    check(restarted.publicationPayload == nil && restarted.mediaStatus.allSatisfy { $0.state == .pending },
          "a fresh analysis invalidates the previous payload and all processing evidence")
    let firstID = try? ready.approve(reviewer: owner)
    let historyCount = ready.history.count
    check((try? ready.approve(reviewer: owner)) == firstID && ready.history.count == historyCount,
          "repeated approval returns one ID without a second audit event")

    // Real orchestration + real JobManager + an HTTP backend, with local audio
    // seeded as a completed download. This never fetches copyrighted media or Firebase.
    guard let expectedURL = ProcessInfo.processInfo.environment["CHORDADMIN_BACKEND_URL"],
          let port = URL(string: expectedURL)?.port,
          let backend = try? FakeBackend(fixedPort: UInt16(port)) else {
        check(false, "the import integration backend can be configured"); return
    }
    do { try backend.start() } catch { check(false, "the import backend starts: \(error)"); return }
    defer { backend.stop() }
    backend.update { $0.chordsStatus = 500 }
    let store = MemoryImportStore(record)
    let processor = SongImportProcessing()
    let folder = LocalFileStore.baseDirectory.appendingPathComponent("import-integration")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let wav = folder.appendingPathComponent("analysis.wav")
    try? Data(repeating: 0, count: 2048).write(to: wav)
    var seed = AnalysisJob(id: "import-integration", sourceUrl: source.url, status: .audioReady, createdAt: Date(),
                           title: fields.title, songDocumentID: record.workspaceID, songVideoID: source.stableIdentifier)
    seed.analysisWavPath = wav.path
    var report = StageReport()
    for stage in PipelineStage.audioStages { report.set(stage, .done) }
    seed.stageReport = report
    try? LocalFileStore.saveJob(seed, to: folder)
    let jobs = JobManager()
    await jobs.hydrate()
    await processor.process(record, jobs: jobs, store: store)
    check(store.record.mediaStatus.first { $0.step == .analysis }?.state == .failed,
          "a chord HTTP failure is recorded durably on the import")
    check(store.record.mediaStatus.first { $0.step == .download }?.state == .succeeded,
          "successful download evidence survives a later failure")
    let beatCalls = backend.requestedPaths.filter { $0 == "/api/detect-beats" }.count
    backend.update { $0.chordsStatus = 200 }
    await processor.process(store.record, jobs: jobs, store: store, retry: true)
    check(store.record.mediaStatus.filter { $0.step != .publication }.allSatisfy { $0.state.isSuccessful },
          "retry executes failed processing and reaches a complete translated review record")
    check(backend.requestedPaths.filter { $0 == "/api/detect-beats" }.count == beatCalls,
          "retrying failed chords does not run successful beat detection again")
    check(jobs.job(for: record.workspaceID)?.id == seed.id && FileManager.default.fileExists(atPath: wav.path),
          "retry retains the original local job and downloaded audio")
    check(store.record.status == .staged && store.record.publishedSongID == nil,
          "successful processing leaves publication as a separate owner action")
    let analysisRequests = backend.requestedPaths.filter { $0 == "/api/detect-beats" || $0 == "/api/recognize-chords" }.count
    backend.update { $0.translateStatus = 500 }
    await processor.process(store.record, jobs: jobs, store: store)
    check(store.record.mediaStatus.first { $0.step == .translation }?.state == .failed,
          "a translation failure stays on the existing staging record")
    backend.update { $0.translateStatus = 200 }
    await processor.process(store.record, jobs: jobs, store: store, retry: true)
    check(store.record.mediaStatus.first { $0.step == .translation }?.state == .succeeded,
          "translation-only retry actually executes translation")
    check(backend.requestedPaths.filter { $0 == "/api/detect-beats" || $0 == "/api/recognize-chords" }.count == analysisRequests,
          "translation-only retry never repeats download or model analysis")
    check(store.record.history.contains { $0.outcome == .retryQueued && $0.step == .translation },
          "the real retry is attributed in the staging history")

    if let job = jobs.job(for: record.workspaceID) {
        let savedRecord = folder.appendingPathComponent("job.json")
        let savedBytes = try? Data(contentsOf: savedRecord)
        try? FileManager.default.removeItem(at: savedRecord)
        refuses("missing durable job data blocks publication readiness") {
            try SongImportProcessing.validateSavedOutputs(job, folder: folder)
        }
        if let savedBytes { try? savedBytes.write(to: savedRecord) }
        let export = StageBeeExportService()
        if var preview = try? await export.prepare(job: job, jobFolder: folder, song: record.workspaceSong, isSignedIn: true) {
            preview.publication = store.record
            preview.importChartsVersion = job.chartsVersion
            preview.importEditedAt = job.lastEditedAt
            check(preview.matchesImportAnalysis(job), "an unchanged analysis matches its publication preview")
            var edited = job
            edited.lastEditedAt = Date().addingTimeInterval(1)
            check(!preview.matchesImportAnalysis(edited), "section edits invalidate an open publication preview")
            edited = job; edited.chartsVersion = (edited.chartsVersion ?? 0) + 1
            check(!preview.matchesImportAnalysis(edited), "regenerated charts invalidate an open publication preview")
            do { _ = try await export.commit(preview); check(false, "draft publication cannot use direct export") }
            catch { check(true, "draft publication cannot use direct export") }
        } else { check(false, "a prepared import can be previewed") }
    }
    let publishedID = SongImportNormalizer.canonicalSongID(targetSongID: nil, source: source, stagingID: record.id)
    let publication = ExportRecord(exportedAt: Date(), documentID: publishedID, sectionCount: 3)
    check(jobs.adoptPublishedImport(workspaceID: record.workspaceID, canonicalID: publishedID,
                                   jobID: seed.id, export: publication),
          "publication moves the reviewed local analysis onto its canonical library row")
    check(jobs.job(for: publishedID)?.lastExport?.documentID == publishedID && jobs.job(for: record.workspaceID) == nil,
          "the published song retains its chart and export history without a second draft row")
    let reloaded = JobManager()
    await reloaded.hydrate()
    check(reloaded.job(for: publishedID)?.id == seed.id && reloaded.job(for: record.workspaceID) == nil,
          "the publication association survives restarting the app")
    let deniedStore = MemoryImportStore(SongImportRecord.staged(id: "denied", source: source, detectedFields: fields, actor: owner))
    deniedStore.denyAccess = true
    await processor.process(deniedStore.record, jobs: jobs, store: deniedStore)
    check(jobs.job(for: deniedStore.record.workspaceID) == nil,
          "permission denial stops before any media processing")
}
