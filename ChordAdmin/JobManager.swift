import Foundation
import Combine

// MARK: - Errors

nonisolated enum JobError: LocalizedError {
    case missingTools([String])
    case downloadFailed(String)
    case conversionFailed(String)
    case metadataFailed(String)
    case audioHealthFailed(String)
    case backendUnavailable(String)
    case backendRejected(String)

    var errorDescription: String? {
        switch self {
        case .missingTools(let tools):
            return "Missing required tools: \(tools.joined(separator: ", "))"
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .conversionFailed(let msg):
            return "Conversion failed: \(msg)"
        case .metadataFailed(let msg):
            return "Metadata extraction failed: \(msg)"
        case .audioHealthFailed(let msg):
            return "Audio health analysis failed: \(msg)"
        case .backendUnavailable(let msg):
            return msg
        case .backendRejected(let msg):
            return msg
        }
    }
}

// MARK: - Song reference

/// The minimum a job needs to know about the song it belongs to. Keeps the
/// pipeline free of Firestore types, and carries the document ID that binds an
/// analysis to exactly one TheStageBee song.
nonisolated struct SongRef: Sendable, Hashable, Identifiable {
    let documentID: String
    let title: String
    let artist: String?
    let url: String

    var id: String { documentID }

    var videoID: String? { SongRef.youTubeVideoID(from: url) }

    static func youTubeVideoID(from urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        if url.host?.contains("youtu.be") == true {
            return url.pathComponents.dropFirst().first
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first(where: { $0.name == "v" })?.value
    }
}

// MARK: - Job manager

/// Owns every analysis job, keyed by the song it was run for.
///
/// The previous build kept a single app-wide `currentJob`, so opening another
/// song showed the last song's analysis — and exporting from that screen wrote
/// it onto the wrong Firestore document. Jobs are now addressed by song.
@MainActor
final class JobManager: ObservableObject {

    // MARK: Backend config
    /// Where the analysis backend lives. ChordAdminBackend can be moved off
    /// 5051 with its own `CHORDADMIN_BACKEND_PORT`, so the app has to be able to
    /// follow it; this is also what lets the tests point at a stub server.
    nonisolated static let backendBaseUrl: String = {
        guard let override = ProcessInfo.processInfo.environment["CHORDADMIN_BACKEND_URL"],
              !override.isEmpty else { return "http://localhost:5051" }
        return override.hasSuffix("/") ? String(override.dropLast()) : override
    }()
    nonisolated static let defaultBeatModel  = "auto"
    nonisolated static let defaultChordModel = "chord-cnn-lstm"

    // MARK: Published state

    /// songDocumentID → job
    @Published private(set) var jobs: [String: AnalysisJob] = [:]
    /// songDocumentID → job folder on disk
    @Published private(set) var folders: [String: URL] = [:]
    /// songDocumentID → pipeline log
    @Published private(set) var logs: [String: String] = [:]
    /// The song currently being analysed, if any.
    @Published private(set) var runningSongID: String?
    /// Songs waiting their turn, in order.
    @Published private(set) var queue: [SongRef] = []
    /// Whether each queued song may reuse audio already on disk. Kept beside the
    /// queue so a queued "Re-analyse" is still a re-analysis when its turn comes.
    private var queuedResumeFlags: [String: Bool] = [:]
    /// Folders a running re-analysis is replacing, kept off the leftover list
    /// until the run finishes one way or the other.
    private var supersededFolders: [String: URL] = [:]
    /// Per song, the folders hydration found but did not choose — the remains of
    /// a re-analysis the app never got to settle. They hold a chart, so they are
    /// kept off the leftover list rather than silently swept away. Keyed by song
    /// so deleting a song's analysis, or finishing a fresh one, can release them.
    @Published private(set) var protectedFolders: [String: [URL]] = [:]
    /// Why the last attempt to write a job to disk failed, if it did. Everything
    /// on screen is then memory-only and will not survive a relaunch, which the
    /// user has to be told rather than left to discover.
    @Published private(set) var persistenceError: String?
    /// Set while `hydrate()` is reading job folders at launch.
    @Published private(set) var isHydrating = false
    /// The song whose beats are being re-detected, if any. Re-detection runs
    /// outside the main pipeline, so it needs its own busy flag.
    @Published private(set) var redetectingSongID: String?

    /// Jobs found on disk that predate per-song keying, indexed by YouTube video
    /// ID so they can be adopted when their song is opened.
    private var legacyJobsByVideoID: [String: (job: AnalysisJob, folder: URL)] = [:]

    private var runningTask: Task<Void, Never>?

    // MARK: - Accessors

    func job(for songID: String) -> AnalysisJob? { jobs[songID] }
    func folder(for songID: String) -> URL? { folders[songID] }
    func log(for songID: String) -> String { logs[songID] ?? "" }
    func isRunning(_ songID: String) -> Bool { runningSongID == songID }
    func isRedetecting(_ songID: String) -> Bool { redetectingSongID == songID }
    var isBusy: Bool { runningSongID != nil || redetectingSongID != nil }
    func queuePosition(of songID: String) -> Int? {
        queue.firstIndex(where: { $0.documentID == songID }).map { $0 + 1 }
    }

    // MARK: - Hydration

    /// Reads every job folder under Application Support so the library shows
    /// real per-song state at launch instead of "no active job".
    func hydrate() async {
        guard !isHydrating else { return }
        isHydrating = true
        defer { isHydrating = false }

        let base = LocalFileStore.baseDirectory
        let decoded: [(job: AnalysisJob, folder: URL)] = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return [] }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var result: [(job: AnalysisJob, folder: URL)] = []
            for folder in entries {
                let jobFile = folder.appendingPathComponent("job.json")
                guard let data = try? Data(contentsOf: jobFile),
                      let job = try? decoder.decode(AnalysisJob.self, from: data) else { continue }
                result.append((job, folder))
            }
            return result
        }.value

        var bySong: [String: (job: AnalysisJob, folder: URL)] = [:]
        var byVideo: [String: (job: AnalysisJob, folder: URL)] = [:]
        // Folders a song did not pick, kept out of the orphan sweep so a quit
        // mid-re-analysis can never leave the finished work one click from gone.
        var strandedFolders: [String: [URL]] = [:]

        for entry in decoded {
            var job = entry.job
            // A job left mid-run by a quit or crash is not running now.
            if job.status.isRunning {
                job.status = job.hasAudio ? .audioReady : .failed
                if job.errorMessage == nil && !job.hasAudio {
                    job.errorMessage = "Interrupted before the audio was ready."
                }
                var report = job.stageReport
                report.resetUnfinished()
                job.stageReport = report
            } else if job.stageReport.runningStage != nil {
                // A beat re-detection records a running stage without touching
                // `status`, so an interrupted one left the Analysis tab showing
                // a spinner on a stage that had long since stopped, on every
                // launch, with nothing offering a way out.
                var report = job.stageReport
                report.resetUnfinished()
                job.stageReport = report
            }

            if let songID = job.songDocumentID {
                if let existing = bySong[songID], !Self.prefer(job, over: existing.job) {
                    // A folder we are not keeping is only worth protecting when
                    // it holds a chart; an empty one is genuinely leftover.
                    if job.hasChart { strandedFolders[songID, default: []].append(entry.folder) }
                    continue
                }
                if let existing = bySong[songID], existing.job.hasChart {
                    strandedFolders[songID, default: []].append(existing.folder)
                }
                bySong[songID] = (job, entry.folder)
            }
            // Only jobs that predate per-song keying are adoption candidates.
            // Indexing keyed jobs here too would let one song's folder be
            // adopted by another song that happens to share a video ID.
            if job.songDocumentID == nil,
               let videoID = job.songVideoID ?? SongRef.youTubeVideoID(from: job.sourceUrl) {
                if let existing = byVideo[videoID], existing.job.createdAt > job.createdAt { continue }
                byVideo[videoID] = (job, entry.folder)
            }
        }

        jobs = bySong.mapValues(\.job)
        folders = bySong.mapValues(\.folder)
        legacyJobsByVideoID = byVideo
        let kept = Set(bySong.values.map { LocalFileStore.comparablePath($0.folder) })
        protectedFolders = strandedFolders.compactMapValues { folders in
            let remaining = folders.filter { !kept.contains(LocalFileStore.comparablePath($0)) }
            return remaining.isEmpty ? nil : remaining
        }
    }

    /// Which of two folders for the same song wins at launch.
    ///
    /// Recency alone is wrong: quitting during a re-analysis leaves a newer,
    /// emptier folder beside the finished one, and picking it presented a
    /// completed, hand-edited, exported analysis as a failed run with no chart —
    /// and then offered its folder for deletion as leftover. Completeness comes
    /// first, and recency only breaks ties between equals.
    nonisolated static func prefer(_ candidate: AnalysisJob, over incumbent: AnalysisJob) -> Bool {
        if candidate.isExportable != incumbent.isExportable { return candidate.isExportable }
        if candidate.hasChart != incumbent.hasChart { return candidate.hasChart }
        if candidate.hasAudio != incumbent.hasAudio { return candidate.hasAudio }
        return candidate.createdAt > incumbent.createdAt
    }

    /// Binds a job that was run before per-song keying to the song it belongs
    /// to, matching on YouTube video ID, so existing work is not stranded.
    func adoptLegacyJobIfNeeded(for song: SongRef) {
        guard jobs[song.documentID] == nil,
              let videoID = song.videoID,
              let candidate = legacyJobsByVideoID[videoID] else { return }

        // The folder can have gone (deleted in Finder, or a migration). Binding
        // a song to a missing directory yields a song the library calls
        // "analysed" with an empty chart and no way back.
        guard FileManager.default.fileExists(atPath: candidate.folder.path) else {
            legacyJobsByVideoID.removeValue(forKey: videoID)
            return
        }

        var job = candidate.job
        job.songDocumentID = song.documentID
        job.songVideoID = videoID
        if job.title == nil { job.title = song.title }
        jobs[song.documentID] = job
        folders[song.documentID] = candidate.folder
        // Claimed: a folder belongs to one song, so it must stop being an
        // adoption candidate for any other.
        legacyJobsByVideoID.removeValue(forKey: videoID)
        try? LocalFileStore.saveJob(job, to: candidate.folder)
    }

    // MARK: - Running

    /// Starts (or queues) an analysis for `song`.
    /// - Parameter resumeIfPossible: when the audio is already on disk, skip
    ///   straight to the backend stages instead of downloading again.
    func start(_ song: SongRef, resumeIfPossible: Bool = true) {
        guard runningSongID != song.documentID else { return }
        if queue.contains(where: { $0.documentID == song.documentID }) {
            // Already waiting: upgrade a queued resume into a full re-analysis
            // rather than silently keeping the weaker request.
            if !resumeIfPossible { queuedResumeFlags[song.documentID] = false }
            return
        }

        // A re-detection is a backend run on this song's folder too. Starting a
        // pipeline alongside it repointed the song at a new folder mid-flight,
        // so the re-detection's result landed in the wrong job — and the toolbar
        // was already promising the run would wait its turn.
        if runningSongID != nil || redetectingSongID != nil {
            queue.append(song)
            queuedResumeFlags[song.documentID] = resumeIfPossible
            return
        }
        launch(song, resumeIfPossible: resumeIfPossible)
    }

    /// Adds several songs to the queue in one go — the batch path the library's
    /// "Analyse all" action uses.
    func enqueue(_ songs: [SongRef]) {
        for song in songs {
            guard jobs[song.documentID]?.status != .completed else { continue }
            start(song)
        }
    }

    func removeFromQueue(_ songID: String) {
        queue.removeAll { $0.documentID == songID }
        queuedResumeFlags.removeValue(forKey: songID)
    }

    func clearQueue() {
        queue.removeAll()
        queuedResumeFlags.removeAll()
    }

    /// Stops the running job. Finished stages and downloaded audio are kept, so
    /// a later run resumes rather than starting over.
    func cancelRun() {
        runningTask?.cancel()
    }

    /// Settles a re-analysis that quitting would otherwise abandon.
    ///
    /// Nothing runs after the process dies, so an in-flight re-analysis left two
    /// folders on disk with only an in-memory note of which replaced which. The
    /// next launch had to reconstruct the relationship by guesswork. Rolling the
    /// decision forward on the way out means the state on disk is already right.
    ///
    /// Returns the number of songs settled, so a caller can say whether it did
    /// anything. Safe to call when nothing is running.
    @discardableResult
    func settleForTermination() -> Int {
        var settled = 0
        for (songID, supersededFolder) in supersededFolders {
            guard let folder = folders[songID] else { continue }
            // Quitting mid-run is an abort, whatever stage it reached — the same
            // rules a cancel goes through, so the more complete analysis wins.
            let didRestore = settleSuperseded(
                supersededFolder, replacing: folder, songID: songID,
                reason: "Re-analysis was interrupted when the app quit — the previous chart was kept.",
                runSucceeded: false
            )
            if didRestore { settled += 1 }
        }
        supersededFolders.removeAll()

        // A job recorded mid-stage is not running any more, and saying so now
        // spares the next launch from inferring it.
        for (songID, var job) in jobs where job.status.isRunning || job.stageReport.runningStage != nil {
            if job.status.isRunning {
                job.status = job.hasAudio ? .audioReady : .cancelled
            }
            var report = job.stageReport
            report.resetUnfinished()
            job.stageReport = report
            persist(job, songID: songID)
        }
        return settled
    }

    private func launch(_ song: SongRef, resumeIfPossible: Bool) {
        runningSongID = song.documentID
        runningTask = Task { [weak self] in
            await self?.runPipeline(for: song, resumeIfPossible: resumeIfPossible)
            self?.finishRun()
        }
    }

    private func finishRun() {
        runningTask = nil
        runningSongID = nil
        startNextQueued()
    }

    /// Starts whatever is waiting, once nothing else is using the backend.
    private func startNextQueued() {
        guard runningSongID == nil, redetectingSongID == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        let resume = queuedResumeFlags.removeValue(forKey: next.documentID) ?? true
        launch(next, resumeIfPossible: resume)
    }

    // MARK: - Pipeline

    private func runPipeline(for song: SongRef, resumeIfPossible: Bool) async {
        let songID = song.documentID
        let cleanedUrl = Self.cleanYouTubeURL(song.url)

        // Reuse the existing job when we already have its audio.
        var job: AnalysisJob
        var folder: URL
        let resuming: Bool
        // Re-analysing writes a new folder; the old one is removed only once the
        // replacement has actually produced something, so a failed re-run never
        // costs the user their existing chart.
        var supersededFolder: URL?

        if resumeIfPossible,
           let existing = jobs[songID],
           let existingFolder = folders[songID],
           existing.hasAudio {
            job = existing
            folder = existingFolder
            resuming = true
            appendLog("\n— Resuming analysis; audio already downloaded —\n", songID: songID, folder: folder)
        } else {
            supersededFolder = folders[songID]
            if let supersededFolder { supersededFolders[songID] = supersededFolder }
            let jobId = UUID().uuidString
            job = AnalysisJob(
                id: jobId,
                sourceUrl: cleanedUrl,
                status: .pending,
                createdAt: Date(),
                title: song.title,
                songDocumentID: songID,
                songVideoID: song.videoID
            )
            // A re-analysis replaces the *detection*, not the user's decisions.
            // Dropping these silently reset a hand-tuned pickup and metre, wiped
            // every per-bar subdivision, and made a song that had been exported
            // read as though it never had been.
            if let previous = jobs[songID] {
                job.barAlignmentOffset = previous.barAlignmentOffset
                job.beatsPerBarOverride = previous.beatsPerBarOverride
                job.manualBpm = previous.manualBpm
                job.tempoHalved = previous.tempoHalved
                job.includePreIntro = previous.includePreIntro
                job.barSubdivisions = previous.barSubdivisions
                job.lastExport = previous.lastExport
            }
            guard let created = try? LocalFileStore.createJobFolder(jobId: jobId) else {
                // Leave the previous analysis exactly as it was rather than
                // replacing it with a job that has nowhere to live.
                var failure = jobs[songID] ?? job
                failure.errorMessage = "Could not create the job folder in Application Support."
                jobs[songID] = failure
                return
            }
            folder = created
            resuming = false
            logs[songID] = ""
            try? LocalFileStore.saveSourceInfo(["url": cleanedUrl, "jobId": jobId], to: folder)
        }

        folders[songID] = folder
        var report = job.stageReport
        if !resuming { report = StageReport() } else { report.reset(from: .backend) }
        job.stageReport = report
        job.errorMessage = nil
        job.backendErrorMessage = nil
        // Belongs to the run that is starting now, not the one before it.
        job.stoppedByUser = nil
        persist(job, songID: songID)

        do {
            if !resuming {
                let tools = try await runAudioStages(job: &job, songID: songID, folder: folder, url: cleanedUrl)
                _ = tools
            }
            try Task.checkCancellation()
            try await runAnalysisStages(job: &job, songID: songID, folder: folder, url: cleanedUrl)
            // `runAnalysisStages` also returns normally when the backend never
            // came up, which is not a success — the job has no chart.
            let finished = jobs[songID]?.status
            let succeeded = finished == .completed || finished == .completedWithWarnings
            settleSuperseded(
                supersededFolder, replacing: folder, songID: songID,
                reason: "Re-analysis could not finish — the previous chart was kept.",
                runSucceeded: succeeded
            )
            // A run that finished is the settled analysis those folders were
            // being held against, so the protection can end — but they are only
            // released to the leftover list, never deleted from under the user.
            if succeeded { releaseProtectedFolders(for: songID, deleting: false) }
        } catch let error where Self.isCancellation(error) {
            job.status = job.hasAudio ? .audioReady : .cancelled
            job.stoppedByUser = true
            var report = job.stageReport
            if let running = report.runningStage {
                report.set(running, .skipped("Cancelled"))
            }
            report.resetUnfinished()
            job.stageReport = report
            appendLog("\nCancelled.\n", songID: songID, folder: folder)
            // Cancelling skips the stage's own `finish`, so this is the one
            // write on the path — without adopting first it reverted whatever
            // the user did while the stage was in flight.
            adoptUserEdits(into: &job, songID: songID)
            persist(job, songID: songID)
            settleSuperseded(supersededFolder, replacing: folder, songID: songID,
                             reason: "Re-analysis cancelled — the previous chart was kept.",
                             runSucceeded: false)
            return
        } catch {
            job.status = .failed
            job.errorMessage = error.localizedDescription
            appendLog("ERROR: \(error.localizedDescription)\n", songID: songID, folder: folder)
            adoptUserEdits(into: &job, songID: songID)
            persist(job, songID: songID)

            // A re-analysis that failed should not cost the user the chart they
            // already had.
            settleSuperseded(supersededFolder, replacing: folder, songID: songID,
                             reason: "Re-analysis failed: \(error.localizedDescription)",
                             runSucceeded: false)
            return
        }
    }

    /// Stages 1–5: everything that happens on this machine.
    private func runAudioStages(
        job: inout AnalysisJob,
        songID: String,
        folder: URL,
        url: String
    ) async throws -> ToolReport {

        // — Tools —
        begin(.tools, job: &job, songID: songID)
        let started = Date()
        let tools = try await ToolChecker.check()
        guard tools.allAvailable else {
            finish(.tools, .failed(tools.missingDescriptions.joined(separator: "\n")),
                   job: &job, songID: songID, since: started)
            throw JobError.missingTools(tools.missingDescriptions)
        }
        finish(.tools, .done, job: &job, songID: songID, since: started)
        appendLog("All tools found.\n", songID: songID, folder: folder)

        guard let ytDlpPath = tools.path(for: .ytDlp),
              let ffmpegPath = tools.path(for: .ffmpeg),
              let ffprobePath = tools.path(for: .ffprobe) else {
            throw JobError.missingTools(tools.missingDescriptions)
        }

        // — Download —
        try await stage(.download, job: &job, songID: songID, folder: folder) { job in
            job.status = .downloading
            self.appendLog("Downloading: \(url)\n", songID: songID, folder: folder)

            var arguments = [
                "-f", "ba/b",
                "--no-playlist",
            ]
            if let denoPath = tools.path(for: .deno) {
                arguments.append(contentsOf: ["--js-runtimes", "deno:\(denoPath)"])
            }
            arguments.append(contentsOf: [
                "--print", "after_move:filepath",
                "-o", folder.appendingPathComponent("audio.original.%(ext)s").path,
                url,
            ])

            let result = try await ProcessRunner.run(
                executablePath: ytDlpPath,
                arguments: arguments,
                onOutput: { [weak self] text in
                    Task { @MainActor [weak self] in
                        self?.appendLog(text, songID: songID, folder: folder)
                    }
                }
            )
            guard result.exitCode == 0 else {
                throw JobError.downloadFailed("yt-dlp exited with code \(result.exitCode)")
            }

            guard let downloadedPath = Self.downloadedFile(from: result.output, in: folder) else {
                throw JobError.downloadFailed("Could not determine the downloaded file path from yt-dlp output")
            }
            job.originalAudioPath = downloadedPath
            return .done
        }

        // — Convert —
        try await stage(.convert, job: &job, songID: songID, folder: folder) { job in
            job.status = .converting
            guard let source = job.originalAudioPath else {
                throw JobError.conversionFailed("No downloaded audio to convert")
            }
            let wavPath = folder.appendingPathComponent("analysis.wav").path
            let result = try await ProcessRunner.run(
                executablePath: ffmpegPath,
                arguments: ["-y", "-i", source, "-ar", "44100", "-ac", "1", wavPath],
                onOutput: { [weak self] text in
                    Task { @MainActor [weak self] in
                        self?.appendLog(text, songID: songID, folder: folder)
                    }
                }
            )
            guard result.exitCode == 0 else {
                throw JobError.conversionFailed("ffmpeg exited with code \(result.exitCode)")
            }
            job.analysisWavPath = wavPath
            return .done
        }

        // — Metadata —
        try await stage(.metadata, job: &job, songID: songID, folder: folder) { job in
            job.status = .extractingMetadata
            guard let wavPath = job.analysisWavPath else {
                throw JobError.metadataFailed("No analysis audio")
            }
            let metaPath = folder.appendingPathComponent("metadata.json").path
            let result = try await ProcessRunner.run(
                executablePath: ffprobePath,
                arguments: ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", wavPath]
            )
            guard result.exitCode == 0 else {
                throw JobError.metadataFailed("ffprobe exited with code \(result.exitCode)")
            }
            guard let metaData = result.output.data(using: .utf8) else {
                throw JobError.metadataFailed("ffprobe produced no output")
            }
            try metaData.write(to: URL(fileURLWithPath: metaPath), options: .atomic)

            let parsed = try Self.parseFFprobeOutput(metaData)
            job.metadataPath    = metaPath
            job.durationSeconds = parsed.duration
            job.sampleRate      = parsed.sampleRate
            job.channels        = parsed.channels
            job.codecName       = parsed.codecName
            job.bitRate         = parsed.bitRate
            job.fileSizeBytes   = parsed.fileSizeBytes
            return .done
        }

        // — Audio health —
        try await stage(.health, job: &job, songID: songID, folder: folder) { job in
            job.status = .analysingAudioHealth
            guard let wavPath = job.analysisWavPath else {
                throw JobError.audioHealthFailed("No analysis audio")
            }

            let volume = try await ProcessRunner.run(
                executablePath: ffmpegPath,
                arguments: ["-i", wavPath, "-af", "volumedetect", "-f", "null", "-"]
            )
            let (meanVolume, maxVolume) = Self.parseVolumeDetect(volume.output)

            let silence = try await ProcessRunner.run(
                executablePath: ffmpegPath,
                arguments: ["-i", wavPath, "-af", "silencedetect=noise=-40dB:d=0.5", "-f", "null", "-"]
            )
            let regions = Self.parseSilenceDetect(silence.output)
            let totalSilence = regions.reduce(0.0) { $0 + $1.duration }

            job.meanVolumeDb                = meanVolume
            job.maxVolumeDb                 = maxVolume
            job.silenceRegionCount          = regions.count
            job.totalSilenceDurationSeconds = totalSilence

            let healthPath = folder.appendingPathComponent("audio.health.json").path
            let payload: [String: Any] = [
                "meanVolumeDb": meanVolume as Any,
                "maxVolumeDb": maxVolume as Any,
                "silenceRegions": regions.map { ["start": $0.start, "end": $0.end, "duration": $0.duration] },
                "totalSilenceDurationSeconds": totalSilence,
                "warnings": job.audioHealthWarnings,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
                try? data.write(to: URL(fileURLWithPath: healthPath), options: .atomic)
                job.audioHealthPath = healthPath
            }

            let warnings = job.audioHealthWarnings
            return warnings.isEmpty ? .done : .warning(warnings.joined(separator: " · "))
        }

        return tools
    }

    /// Stages 6–11: everything that needs the local analysis backend.
    private func runAnalysisStages(
        job: inout AnalysisJob,
        songID: String,
        folder: URL,
        url: String
    ) async throws {

        guard let wavPath = job.analysisWavPath else {
            throw JobError.backendUnavailable("No analysis audio to send")
        }
        let wavURL = URL(fileURLWithPath: wavPath)

        // — Backend health —
        begin(.backend, job: &job, songID: songID)
        job.status = .checkingAnalysisBackend
        let backendStart = Date()
        let available = await Self.checkBackendHealth()
        // A cancel during the health check comes back as "unreachable"; do not
        // blame the backend for something the user did.
        try Task.checkCancellation()
        job.analysisBackendAvailable = available
        job.backendBaseUrl = Self.backendBaseUrl

        guard available else {
            let message = "Not reachable at \(Self.backendBaseUrl)"
            finish(.backend, .failed(message), job: &job, songID: songID, since: backendStart)
            for pending in [PipelineStage.beats, .beatGrid, .chords, .chart, .sections] {
                var report = job.stageReport
                report.set(pending, .skipped("Waiting for the analysis backend"))
                job.stageReport = report
            }
            job.backendErrorMessage = "Backend unavailable at \(Self.backendBaseUrl)"
            job.status = .audioReady
            appendLog("Backend unavailable — audio is ready and analysis can resume later.\n",
                      songID: songID, folder: folder)
            adoptUserEdits(into: &job, songID: songID)
            persist(job, songID: songID)
            return
        }
        finish(.backend, .done, job: &job, songID: songID, since: backendStart)

        // — Detect beats —
        try await stage(.beats, job: &job, songID: songID, folder: folder) { job in
            job.status = .detectingBeats
            job.requestedBeatModel = Self.defaultBeatModel
            let beatPath = folder.appendingPathComponent("beat.detection.json").path
            let data = try await Self.postAudioFile(
                to: "\(Self.backendBaseUrl)/api/detect-beats",
                fileURL: wavURL,
                params: ["model": Self.defaultBeatModel]
            )
            try data.write(to: URL(fileURLWithPath: beatPath), options: .atomic)
            job.beatDetectionPath = beatPath
            let (bpm, beatCount, resolvedModel) = Self.parseBeatResponse(data)
            job.bpm = bpm
            job.beatCount = beatCount
            job.resolvedBeatModel = resolvedModel
            guard bpm != nil, (beatCount ?? 0) > 0 else {
                throw JobError.backendRejected("The backend returned no usable beats")
            }
            self.appendLog("BPM: \(bpm.map { String(format: "%.2f", $0) } ?? "—"), beats: \(beatCount ?? 0)\n",
                           songID: songID, folder: folder)
            return .done
        }

        // — Beat grid —
        try await stage(.beatGrid, job: &job, songID: songID, folder: folder) { job in
            job.status = .generatingBeatGrid
            guard let beatPath = job.beatDetectionPath,
                  let beatData = try? Data(contentsOf: URL(fileURLWithPath: beatPath)) else {
                throw JobError.backendRejected("Beat data is missing")
            }
            let gridPath = folder.appendingPathComponent("beat.grid.json").path
            // Honour halved tempo and any manual BPM, as every other rebuild
            // does — otherwise a resumed run silently reverts those choices.
            let settings = Self.gridSettings(for: job, beatData: beatData)
            let (payload, barCount) = Self.generateBeatGrid(
                from: settings.beatData, bpm: settings.bpm,
                barAlignmentOffset: job.barAlignmentOffset ?? 0,
                beatsPerBar: job.beatsPerBarOverride ?? 4
            )
            guard !payload.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) else {
                throw JobError.backendRejected("Could not build a beat grid from the detected beats")
            }
            try data.write(to: URL(fileURLWithPath: gridPath), options: .atomic)
            job.beatGridPath = gridPath
            job.barCount = barCount
            job.barAlignmentOffset = job.barAlignmentOffset ?? 0
            job.estimatedTimeSignature = payload["estimatedTimeSignature"] as? String
            return .done
        }

        // — Recognise chords —
        try await stage(.chords, job: &job, songID: songID, folder: folder) { job in
            job.status = .recognizingChords
            job.chordModel = Self.defaultChordModel
            let chordPath = folder.appendingPathComponent("chord.recognition.json").path
            let data = try await Self.postAudioFile(
                to: "\(Self.backendBaseUrl)/api/recognize-chords",
                fileURL: wavURL,
                params: ["model": Self.defaultChordModel]
            )
            try data.write(to: URL(fileURLWithPath: chordPath), options: .atomic)
            job.chordRecognitionPath = chordPath

            let (chordCount, preview, cleaned) = Self.parseChordResponse(data)
            job.chordCount = chordCount
            job.chordPreview = preview
            guard let cleaned else {
                throw JobError.backendRejected("The backend returned no recognised chords")
            }
            let cleanedPath = folder.appendingPathComponent("chord.cleaned.json").path
            try cleaned.write(to: URL(fileURLWithPath: cleanedPath), options: .atomic)
            job.chordCleanedPath = cleanedPath
            self.appendLog("Chords: \(chordCount ?? 0)\n", songID: songID, folder: folder)
            return .done
        }

        // — Build chart —
        try await stage(.chart, job: &job, songID: songID, folder: folder) { job in
            job.status = .generatingChordChart
            guard let gridPath = job.beatGridPath,
                  let cleanedPath = job.chordCleanedPath,
                  let gridData = try? Data(contentsOf: URL(fileURLWithPath: gridPath)),
                  let cleanedData = try? Data(contentsOf: URL(fileURLWithPath: cleanedPath)) else {
                throw JobError.backendRejected("Beat grid or chord data is missing")
            }
            try Self.buildCharts(
                job: &job, folder: folder,
                gridPath: gridPath, gridData: gridData,
                cleanedPath: cleanedPath, cleanedData: cleanedData
            )
            let chordless = job.barsWithoutChords ?? 0
            if chordless > 0 {
                return .warning(chordless == 1
                                ? "1 bar has no chord overlap"
                                : "\(chordless) bars have no chord overlap")
            }
            return .done
        }

        // — Sections —
        try await stage(.sections, job: &job, songID: songID, folder: folder) { job in
            job.status = .detectingSections
            guard let performerPath = job.chordChartPerformerPath,
                  let draftPath = job.chordChartDraftPath,
                  let performerData = try? Data(contentsOf: URL(fileURLWithPath: performerPath)) else {
                throw JobError.backendRejected("Performer chart is missing")
            }
            let candidatesPath = folder.appendingPathComponent("section.candidates.json").path
            let (candPayload, candCount, candPreview) = Self.detectSectionCandidates(
                performerData: performerData, performerPath: performerPath, draftPath: draftPath
            )
            guard !candPayload.isEmpty,
                  let candData = try? JSONSerialization.data(withJSONObject: candPayload, options: .prettyPrinted) else {
                throw JobError.backendRejected("Could not analyse repeating sections")
            }
            try candData.write(to: URL(fileURLWithPath: candidatesPath), options: .atomic)
            job.sectionCandidatesPath = candidatesPath
            job.sectionCandidateCount = candCount
            job.sectionCandidatePreview = candPreview

            let sectionsPath = folder.appendingPathComponent("sections.json").path
            let (sectionsPayload, sectionCount) = Self.generateInitialSections(
                performerData: performerData, candidatesPayload: candPayload,
                performerPath: performerPath, candidatesPath: candidatesPath
            )
            if !sectionsPayload.isEmpty,
               let sectionsData = try? JSONSerialization.data(withJSONObject: sectionsPayload, options: .prettyPrinted) {
                try sectionsData.write(to: URL(fileURLWithPath: sectionsPath), options: .atomic)
                job.sectionsPath = sectionsPath
                job.sectionCount = sectionCount
            }

            let warnings = (candPayload["warnings"] as? [String]) ?? []
            return warnings.isEmpty ? .done : .warning(warnings.joined(separator: " · "))
        }

        let report = job.stageReport
        job.status = report.warnings.isEmpty ? .completed : .completedWithWarnings
        job.completedAt = Date()
        adoptUserEdits(into: &job, songID: songID)
        persist(job, songID: songID)
        appendLog("Completed.\n", songID: songID, folder: folder)
    }

    /// What should happen to the folder a re-analysis was replacing.
    nonisolated enum SupersedeDecision: Equatable {
        /// The new run wins; the old folder is spent and can go.
        case retireOld
        /// The new run wins, but nothing may be deleted yet.
        case keepBoth
        /// Put the old analysis back and clear the half-built folder. Once the
        /// song points at the old folder again the new one is unreachable, so
        /// keeping it would only leave clutter the user has to tidy up.
        case restoreOld
    }

    /// The rollback rules, as a pure function so they can be tested exhaustively.
    ///
    /// Retiring the previous analysis is a **success-only** act: a run that was
    /// cancelled or failed has not earned the right to replace it, however far
    /// it got. Getting this wrong deletes charts, section names and export
    /// records that cannot be regenerated.
    nonisolated static func supersedeDecision(
        runSucceeded: Bool,
        newHasChart: Bool,
        newHasAudio: Bool,
        newIsExportable: Bool,
        oldIsExportable: Bool
    ) -> SupersedeDecision {
        if runSucceeded {
            return newHasChart ? .retireOld : .keepBoth
        }
        // Aborted. Only stand down if the partial run is genuinely no worse.
        if newIsExportable { return .keepBoth }
        if !oldIsExportable && newHasChart { return .keepBoth }
        return .restoreOld
    }

    /// Applies `supersedeDecision` to the folders and the in-memory job map.
    @discardableResult
    private func settleSuperseded(
        _ supersededFolder: URL?,
        replacing folder: URL,
        songID: String,
        reason: String,
        runSucceeded: Bool
    ) -> Bool {
        defer { supersededFolders.removeValue(forKey: songID) }
        guard let supersededFolder, supersededFolder != folder else { return false }

        let current = jobs[songID]
        let previous = restoreJob(from: supersededFolder)
        let decision = Self.supersedeDecision(
            runSucceeded: runSucceeded,
            newHasChart: current?.hasChart ?? false,
            newHasAudio: current?.hasAudio ?? false,
            newIsExportable: current?.isExportable ?? false,
            oldIsExportable: previous?.isExportable ?? false
        )

        switch decision {
        case .retireOld:
            LocalFileStore.deleteJobFolder(at: supersededFolder)
            return false
        case .keepBoth:
            return false
        case .restoreOld:
            guard var restored = previous else { return false }
            // The restored job is a *completed* one, so an error message would
            // read as though it had failed. This is a notice about the run that
            // was abandoned, and the workspace shows it as one.
            restored.notice = reason
            jobs[songID] = restored
            folders[songID] = supersededFolder
            LocalFileStore.deleteJobFolder(at: folder)
            try? LocalFileStore.saveJob(restored, to: supersededFolder)
            return true
        }
    }

    /// Lets go of the folders hydration set aside for a song.
    ///
    /// The protection exists so an unsettled re-analysis cannot cost the user a
    /// finished chart. Once the song has a settled analysis — or the user has
    /// deleted it outright — there is nothing left to protect, and holding on
    /// would make the space unreclaimable from inside the app.
    private func releaseProtectedFolders(for songID: String, deleting: Bool) {
        guard let held = protectedFolders.removeValue(forKey: songID) else { return }
        guard deleting else {
            // Released, not removed: the folders now show up under "Left over"
            // and the user decides. Deleting them here would be the same silent
            // removal of a complete analysis this protection exists to prevent.
            return
        }
        // Whatever any song currently points at is off limits, however this was
        // reached — the point of the sweep is to remove what nothing references.
        let live = Set(folders.values.map(LocalFileStore.comparablePath))
            .union(supersededFolders.values.map(LocalFileStore.comparablePath))
        for folder in held where !live.contains(LocalFileStore.comparablePath(folder)) {
            LocalFileStore.deleteJobFolder(at: folder)
        }
    }

    /// Drops the rolled-back-re-analysis notice once the user has read it.
    func clearNotice(songID: String) {
        guard var job = jobs[songID], job.notice != nil else { return }
        job.notice = nil
        persist(job, songID: songID)
    }

    /// Reads a job back from a folder, for restoring a superseded analysis.
    private func restoreJob(from folder: URL) -> AnalysisJob? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("job.json")),
              let job = try? decoder.decode(AnalysisJob.self, from: data) else { return nil }
        return job
    }

    // MARK: - Stage plumbing

    private func begin(_ stage: PipelineStage, job: inout AnalysisJob, songID: String) {
        adoptUserEdits(into: &job, songID: songID)
        var report = job.stageReport
        report.set(stage, .running)
        job.stageReport = report
        persist(job, songID: songID)
    }

    /// Re-reads the fields the user owns before the pipeline writes its snapshot
    /// back.
    ///
    /// A run holds one `AnalysisJob` across every stage, which can be minutes on
    /// a resume with the chart still on screen and editable. Persisting that
    /// snapshot at each stage boundary rolled back whatever the user did in the
    /// meantime — subdivisions reverted, the "edited since last export" pill
    /// vanished, and an export completed mid-run was forgotten. The run owns the
    /// detection results and the stage report; these belong to the user.
    private func adoptUserEdits(into job: inout AnalysisJob, songID: String) {
        // Only for the same analysis: a re-analysis is a different job, and its
        // carried-over settings are chosen deliberately when it is created.
        guard let live = jobs[songID], live.id == job.id else { return }
        job.barSubdivisions = live.barSubdivisions
        job.lastEditedAt = live.lastEditedAt
        job.lastExport = live.lastExport
        // Tuning applied mid-run counts too, and it is not cosmetic: the beat
        // grid stage reads these back, so a stale snapshot did not merely
        // reset the pickers — it rebuilt every chart in the wrong metre.
        job.barAlignmentOffset = live.barAlignmentOffset
        job.beatsPerBarOverride = live.beatsPerBarOverride
        job.tempoHalved = live.tempoHalved
        job.manualBpm = live.manualBpm
        job.includePreIntro = live.includePreIntro
        job.chartStartTime = live.chartStartTime
        // Never *lower* the version: buildCharts bumps it on the local copy, and
        // taking the live value here would undo the bump the workspace reloads on.
        job.chartsVersion = max(job.chartsVersion ?? 0, live.chartsVersion ?? 0)
    }

    private func finish(
        _ stage: PipelineStage,
        _ state: StageState,
        job: inout AnalysisJob,
        songID: String,
        since start: Date
    ) {
        adoptUserEdits(into: &job, songID: songID)
        var report = job.stageReport
        report.set(stage, state, elapsed: Date().timeIntervalSince(start))
        job.stageReport = report
        persist(job, songID: songID)
    }

    /// Cancelling mid-upload surfaces as `URLError.cancelled` rather than
    /// `CancellationError`, which would otherwise be recorded as a failed stage
    /// and leave the user with "Failed" after they pressed Cancel.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        // Deliberately no `Task.isCancelled` fallback: a genuine failure that
        // lands while a cancel is in flight should still be reported as one.
        return false
    }

    /// Runs one stage, recording its state and duration, and turning a thrown
    /// error into a visible failure on that specific stage.
    private func stage(
        _ stage: PipelineStage,
        job: inout AnalysisJob,
        songID: String,
        folder: URL,
        _ body: (inout AnalysisJob) async throws -> StageState
    ) async throws {
        try Task.checkCancellation()
        begin(stage, job: &job, songID: songID)
        appendLog("\n▸ \(stage.title)\n", songID: songID, folder: folder)
        let started = Date()
        do {
            let outcome = try await body(&job)
            finish(stage, outcome, job: &job, songID: songID, since: started)
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            finish(stage, .failed(error.localizedDescription), job: &job, songID: songID, since: started)
            throw error
        }
    }

    // MARK: - Retry and resume

    /// Re-runs the pipeline from `stage` without discarding earlier work.
    func retry(from stage: PipelineStage, for song: SongRef) {
        guard var job = jobs[song.documentID] else { return }
        var report = job.stageReport
        report.reset(from: stage)
        job.stageReport = report
        job.errorMessage = nil
        jobs[song.documentID] = job
        if let folder = folders[song.documentID] { try? LocalFileStore.saveJob(job, to: folder) }

        // Anything from .backend onwards can reuse the audio already on disk.
        start(song, resumeIfPossible: !PipelineStage.audioStages.contains(stage))
    }


    // MARK: - Persistence

    /// Records a job in memory and on disk.
    ///
    /// The write used to be `try?`. On a full disk that meant the app carried on
    /// as though everything were saved — the chart, the sections, the export
    /// record all present on screen — and lost the lot at the next launch with
    /// nothing ever having said so.
    private func persist(_ job: AnalysisJob, songID: String) {
        jobs[songID] = job
        guard let folder = folders[songID] else { return }
        do {
            try LocalFileStore.saveJob(job, to: folder)
            if persistenceError != nil { persistenceError = nil }
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func appendLog(_ text: String, songID: String, folder: URL?) {
        logs[songID, default: ""] += text
        if let folder { LocalFileStore.appendLog(text, to: folder) }
    }

    /// Records that the user changed sections or subdivisions, which is what
    /// drives the "edited since last export" state in the library.
    func noteEdit(songID: String) {
        guard var job = jobs[songID] else { return }
        job.lastEditedAt = Date()
        persist(job, songID: songID)
    }

    func setSubdivisions(_ subdivisions: [Int: Int], songID: String) {
        guard var job = jobs[songID] else { return }
        job.subdivisionsByBar = subdivisions
        job.lastEditedAt = Date()
        persist(job, songID: songID)
    }

    // MARK: - Storage

    /// Bytes this song's analysis occupies on disk.
    func storageUsed(songID: String) -> Int64 {
        guard let folder = folders[songID] else { return 0 }
        return LocalFileStore.folderSize(at: folder)
    }

    /// Bytes every job folder occupies.
    func totalStorageUsed() -> Int64 { LocalFileStore.totalJobsSize() }

    /// Job folders no live job points at, usually left by earlier re-analyses.
    func orphanedFolders() -> [URL] {
        // Un-adopted legacy folders count as live: no song points at them yet,
        // but the moment their song is opened one will. Deleting them would
        // throw away an analysis the user still has every claim on.
        var live = Set(folders.values.map(\.path))
            .union(legacyJobsByVideoID.values.map { $0.folder.path })
        // A running re-analysis may still have to roll back onto the folder it
        // is replacing, so that is not leftover until the run has settled.
        live.formUnion(supersededFolders.values.map { $0.path })
        // Folders hydration set aside rather than discarded.
        live.formUnion(protectedFolders.values.flatMap { $0 }.map(\.path))
        return LocalFileStore.orphanedFolders(keeping: live)
    }

    @discardableResult
    func deleteOrphanedFolders() -> Int {
        orphanedFolders().reduce(0) { LocalFileStore.deleteJobFolder(at: $1) ? $0 + 1 : $0 }
    }

    /// Deletes this song's analysis: its folder, its cached charts and its
    /// in-memory state. The song itself is untouched.
    func deleteJob(songID: String) {
        guard runningSongID != songID, redetectingSongID != songID else { return }
        // Take it out of the queue first: that must happen even for a song with
        // nothing on disk yet, or a deleted analysis starts itself again.
        removeFromQueue(songID)
        // "Delete this analysis" means all of it. Leaving a set-aside folder
        // behind let the next launch adopt it and quietly undo the deletion,
        // with no way to remove it because it was still shielded.
        releaseProtectedFolders(for: songID, deleting: true)
        guard let folder = folders[songID] else {
            jobs.removeValue(forKey: songID)
            logs.removeValue(forKey: songID)
            return
        }
        LocalFileStore.deleteJobFolder(at: folder)
        jobs.removeValue(forKey: songID)
        folders.removeValue(forKey: songID)
        logs.removeValue(forKey: songID)
        let deleted = LocalFileStore.comparablePath(folder)
        legacyJobsByVideoID = legacyJobsByVideoID.filter {
            LocalFileStore.comparablePath($0.value.folder) != deleted
        }
    }

    /// Records a completed export against the analysis it was built from.
    ///
    /// Returns false when that analysis is no longer the song's current one — a
    /// queued re-analysis started while the sheet was open. Stamping the record
    /// onto the new run instead put it somewhere a rollback would discard, so
    /// Firestore held the export and the app claimed there had never been one.
    @discardableResult
    func recordExport(_ record: ExportRecord, songID: String, jobID: String? = nil) -> Bool {
        guard var job = jobs[songID] else { return false }
        if let jobID, job.id != jobID { return false }
        job.lastExport = record
        persist(job, songID: songID)
        return true
    }

    // MARK: - Chart adjustments

    /// Regenerates the beat grid and every downstream chart for `songID`.
    /// Re-uses the detected beats — nothing is downloaded or re-analysed.
    ///
    /// Returns false when the analysis on disk is too incomplete to rebuild
    /// from, so a caller does not report an edit that never landed.
    @discardableResult
    func regenerateCharts(
        songID: String,
        offset: Int? = nil,
        beatsPerBar: Int? = nil,
        halved: Bool? = nil,
        manualBpm: Double?? = nil
    ) async -> Bool {
        guard var job = jobs[songID],
              let folder = folders[songID],
              let beatPath = job.beatDetectionPath,
              let cleanedPath = job.chordCleanedPath,
              let beatData = try? Data(contentsOf: URL(fileURLWithPath: beatPath)),
              let cleanedData = try? Data(contentsOf: URL(fileURLWithPath: cleanedPath))
        else { return false }

        if let offset { job.barAlignmentOffset = offset }
        if let beatsPerBar { job.beatsPerBarOverride = beatsPerBar == 4 ? nil : beatsPerBar }
        if let halved { job.tempoHalved = halved }
        if let manualBpm { job.manualBpm = manualBpm }

        let settings = Self.gridSettings(for: job, beatData: beatData)
        let (gridPayload, barCount) = Self.generateBeatGrid(
            from: settings.beatData,
            bpm: settings.bpm,
            barAlignmentOffset: job.barAlignmentOffset ?? 0,
            beatsPerBar: job.beatsPerBarOverride ?? 4
        )
        guard !gridPayload.isEmpty,
              let gridData = try? JSONSerialization.data(withJSONObject: gridPayload, options: .prettyPrinted)
        else { return false }

        let gridPath = folder.appendingPathComponent("beat.grid.json").path
        try? gridData.write(to: URL(fileURLWithPath: gridPath), options: .atomic)
        job.beatGridPath = gridPath
        job.barCount = barCount
        job.estimatedTimeSignature = gridPayload["estimatedTimeSignature"] as? String

        do {
            try Self.buildCharts(
                job: &job, folder: folder,
                gridPath: gridPath, gridData: gridData,
                cleanedPath: cleanedPath, cleanedData: cleanedData
            )
        } catch {
            // Nothing was rebuilt, so nothing is persisted: reporting success
            // here left the job claiming a new offset while the chart on screen
            // and the one the export reads still belonged to the old one.
            return false
        }

        // Section candidates follow the new bar numbering.
        if let performerPath = job.chordChartPerformerPath,
           let draftPath = job.chordChartDraftPath,
           let performerData = try? Data(contentsOf: URL(fileURLWithPath: performerPath)) {
            let candidatesPath = folder.appendingPathComponent("section.candidates.json").path
            let (payload, count, preview) = Self.detectSectionCandidates(
                performerData: performerData, performerPath: performerPath, draftPath: draftPath
            )
            if !payload.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
                try? data.write(to: URL(fileURLWithPath: candidatesPath), options: .atomic)
                job.sectionCandidatesPath = candidatesPath
                job.sectionCandidateCount = count
                job.sectionCandidatePreview = preview
            }
        }

        job.lastEditedAt = Date()
        persist(job, songID: songID)
        return true
    }

    /// Rebuilds the candidate chart in memory for the tuning preview, without
    /// touching any file. This is what makes trying pickup offsets instant
    /// instead of a full regeneration per click.
    ///
    /// The rebuild costs tens of milliseconds on a long song, so it runs off the
    /// main actor and only the finished bars come back.
    func previewBars(
        songID: String,
        offset: Int,
        beatsPerBar: Int,
        halved: Bool,
        manualBpm: Double?
    ) async -> [ChordChartBarEntry] {
        guard let job = jobs[songID],
              let beatPath = job.beatDetectionPath,
              let cleanedPath = job.chordCleanedPath
        else { return [] }

        var probe = job
        probe.tempoHalved = halved
        probe.manualBpm = manualBpm
        let chartStartTime = job.chartStartTime
        let includePreIntro = job.includePreIntro ?? false

        return await Task.detached(priority: .userInitiated) {
            guard let beatData = try? Data(contentsOf: URL(fileURLWithPath: beatPath)),
                  let cleanedData = try? Data(contentsOf: URL(fileURLWithPath: cleanedPath))
            else { return [] }

            let settings = JobManager.gridSettings(for: probe, beatData: beatData)
            let (gridPayload, _) = JobManager.generateBeatGrid(
                from: settings.beatData, bpm: settings.bpm,
                barAlignmentOffset: offset, beatsPerBar: beatsPerBar
            )
            guard !gridPayload.isEmpty,
                  let gridData = try? JSONSerialization.data(withJSONObject: gridPayload)
            else { return [] }

            let (draftPayload, _, _) = JobManager.generateChordChart(
                beatGridData: gridData, chordCleanedData: cleanedData,
                beatGridPath: "", chordCleanedPath: ""
            )
            guard !draftPayload.isEmpty,
                  let draftData = try? JSONSerialization.data(withJSONObject: draftPayload),
                  let configData = try? JSONSerialization.data(withJSONObject: JobManager.chartConfig(
                      offset: offset, chartStartTime: chartStartTime, includePreIntro: includePreIntro
                  ))
            else { return [] }

            let (performerPayload, _, _) = JobManager.generatePerformerChart(
                draftData: draftData, configData: configData, draftPath: "", configPath: ""
            )
            guard let rawBars = performerPayload["bars"] as? [[String: Any]] else { return [] }
            return JobManager.decodeBars(rawBars)
        }.value
    }

    /// Beat times used to draw bar lines in the tuning preview.
    func beatTimes(songID: String, halved: Bool) -> [Double] {
        guard let job = jobs[songID],
              let beatPath = job.beatDetectionPath,
              let beatData = try? Data(contentsOf: URL(fileURLWithPath: beatPath)) else { return [] }
        var probe = job
        probe.tempoHalved = halved
        let settings = Self.gridSettings(for: probe, beatData: beatData)
        guard let json = try? JSONSerialization.jsonObject(with: settings.beatData) as? [String: Any],
              let rawBeats = json["beats"] as? [[String: Any]] else { return [] }
        return rawBeats.compactMap { ($0["time"] as? NSNumber)?.doubleValue }
    }





    /// Re-runs beat detection with tighter search parameters, then rebuilds
    /// every chart from the new beats.
    func redetectBeats(
        songID: String,
        minBpm: Double? = nil,
        maxBpm: Double? = nil,
        transitionLambda: Double? = nil
    ) async {
        guard let job = jobs[songID],
              let folder = folders[songID],
              let wavPath = job.analysisWavPath,
              redetectingSongID == nil,
              runningSongID != songID else { return }

        redetectingSongID = songID
        // Anything queued behind this re-detection has to be let go afterwards,
        // or it waits for a run that will never start.
        defer {
            redetectingSongID = nil
            startNextQueued()
        }

        mutateJob(songID) { $0.stageReport.set(.beats, .running) }

        let started = Date()
        do {
            var params: [String: String] = ["model": Self.defaultBeatModel, "force": "true"]
            if let minBpm { params["min_bpm"] = String(format: "%.1f", minBpm) }
            if let maxBpm { params["max_bpm"] = String(format: "%.1f", maxBpm) }
            if let transitionLambda { params["transition_lambda"] = String(format: "%.0f", transitionLambda) }

            let data = try await Self.postAudioFile(
                to: "\(Self.backendBaseUrl)/api/detect-beats",
                fileURL: URL(fileURLWithPath: wavPath),
                params: params
            )
            // Detection takes tens of seconds, and the chart stays editable
            // throughout. Anything written into the new folder of a re-analysis
            // that started meanwhile would corrupt that run, so stop here.
            guard folders[songID].map(LocalFileStore.comparablePath) == LocalFileStore.comparablePath(folder) else { return }

            let beatPath = folder.appendingPathComponent("beat.detection.json").path
            try data.write(to: URL(fileURLWithPath: beatPath), options: .atomic)
            let (bpm, beatCount, resolvedModel) = Self.parseBeatResponse(data)

            mutateJob(songID) { job in
                job.beatDetectionPath = beatPath
                job.bpm = bpm
                job.beatCount = beatCount
                job.resolvedBeatModel = resolvedModel
                job.tempoHalved = false
                job.manualBpm = nil
                job.stageReport.set(.beats, .done, elapsed: Date().timeIntervalSince(started))
            }
            appendLog("Re-detected beats — BPM \(bpm.map { String(format: "%.2f", $0) } ?? "—")\n",
                      songID: songID, folder: folder)
        } catch {
            mutateJob(songID) { job in
                job.stageReport.set(.beats, .failed(error.localizedDescription),
                                    elapsed: Date().timeIntervalSince(started))
                job.errorMessage = error.localizedDescription
            }
            appendLog("Beat re-detection failed: \(error.localizedDescription)\n",
                      songID: songID, folder: folder)
            return
        }

        await regenerateCharts(songID: songID)
    }

    /// Applies a change to whatever record the song holds *now* and persists it.
    ///
    /// The alternative — capturing an `AnalysisJob` before an await and writing
    /// it back after — silently reverted everything the user did during the wait:
    /// subdivisions set on the chart, section renames, even a completed export.
    private func mutateJob(_ songID: String, _ change: (inout AnalysisJob) -> Void) {
        guard var job = jobs[songID] else { return }
        change(&job)
        persist(job, songID: songID)
    }


    // MARK: - Shared chart building

    /// Default chart.config.json contents.
    nonisolated static func chartConfig(
        offset: Int,
        chartStartTime: Double?,
        includePreIntro: Bool
    ) -> [String: Any] {
        [
            "barAlignmentOffset": offset,
            "chartStartTime": chartStartTime ?? 0.0,
            "chartStartSource": chartStartTime == nil ? "auto" : "manual",
            "chartStartBarMode": "renumberFromOne",
            "includePreIntro": includePreIntro,
            "preIntroLabel": "Pre-intro",
        ]
    }

    /// Beat data and BPM to feed the grid, honouring halved tempo and any
    /// manual BPM override.
    nonisolated static func gridSettings(
        for job: AnalysisJob,
        beatData: Data
    ) -> (beatData: Data, bpm: Double?) {
        if job.tempoHalved == true {
            let (thinned, halvedBpm) = applyTempoHalving(to: beatData)
            return (thinned, job.manualBpm ?? halvedBpm ?? job.bpm.map { $0 / 2 })
        }
        return (beatData, job.manualBpm ?? job.bpm)
    }

    /// Draft chart → chart config → performer chart, written to the job folder.
    nonisolated static func buildCharts(
        job: inout AnalysisJob,
        folder: URL,
        gridPath: String,
        gridData: Data,
        cleanedPath: String,
        cleanedData: Data
    ) throws {
        let draftPath = folder.appendingPathComponent("chord.chart.draft.json").path
        let (draftPayload, draftBarCount, draftPreview) = generateChordChart(
            beatGridData: gridData, chordCleanedData: cleanedData,
            beatGridPath: gridPath, chordCleanedPath: cleanedPath
        )
        guard !draftPayload.isEmpty,
              let draftData = try? JSONSerialization.data(withJSONObject: draftPayload, options: .prettyPrinted)
        else { throw JobError.backendRejected("Could not build the chord chart") }

        try draftData.write(to: URL(fileURLWithPath: draftPath), options: .atomic)
        job.chordChartDraftPath = draftPath
        job.chordChartBarCount = draftBarCount
        job.chordChartPreview = draftPreview
        // The generator already recorded one warning per chordless bar across
        // the whole chart; the preview holds only the first eight.
        job.barsWithoutChords = (draftPayload["warnings"] as? [String])?.count ?? 0

        let configPath = folder.appendingPathComponent("chart.config.json").path
        let config = chartConfig(
            offset: job.barAlignmentOffset ?? 0,
            chartStartTime: job.chartStartTime,
            includePreIntro: job.includePreIntro ?? false
        )
        guard let configData = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
        else { throw JobError.backendRejected("Could not write the chart configuration") }
        try configData.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        job.chartConfigPath = configPath

        let performerPath = folder.appendingPathComponent("chord.chart.performer.json").path
        let (performerPayload, _, performerPreview) = generatePerformerChart(
            draftData: draftData, configData: configData,
            draftPath: draftPath, configPath: configPath
        )
        guard !performerPayload.isEmpty,
              let performerData = try? JSONSerialization.data(withJSONObject: performerPayload, options: .prettyPrinted)
        else { throw JobError.backendRejected("Could not build the performer chart") }
        try performerData.write(to: URL(fileURLWithPath: performerPath), options: .atomic)
        job.chordChartPerformerPath = performerPath
        job.performerChartPreview = performerPreview

        // The only place the chart files are rewritten, so the only place that
        // needs to bump the version the workspace reloads on.
        job.chartsVersion = (job.chartsVersion ?? 0) + 1
    }

    /// Shared decoder for the `bars` array of the draft and performer charts.
    nonisolated static func decodeBars(_ rawBars: [[String: Any]]) -> [ChordChartBarEntry] {
        rawBars.compactMap { bar in
            guard let barNumber = bar["bar"] as? Int,
                  let start = (bar["start"] as? NSNumber)?.doubleValue,
                  let end = (bar["end"] as? NSNumber)?.doubleValue else { return nil }
            let chords: [ChordChartChordEntry] = (bar["chords"] as? [[String: Any]] ?? []).compactMap { chord in
                guard let display = chord["displayChord"] as? String,
                      let chordStart = (chord["start"] as? NSNumber)?.doubleValue,
                      let chordEnd = (chord["end"] as? NSNumber)?.doubleValue,
                      let overlap = (chord["overlapSeconds"] as? NSNumber)?.doubleValue else { return nil }
                return ChordChartChordEntry(
                    displayChord: display, start: chordStart, end: chordEnd, overlapSeconds: overlap
                )
            }
            return ChordChartBarEntry(
                bar: barNumber, start: start, end: end,
                primaryChord: bar["primaryChord"] as? String, chords: chords
            )
        }
    }

    /// Reads and decodes a chart file written by the pipeline.
    nonisolated static func loadBars(atPath path: String?) -> [ChordChartBarEntry] {
        guard let path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawBars = json["bars"] as? [[String: Any]] else { return [] }
        return decodeBars(rawBars)
    }

    nonisolated static func loadRawChords(atPath path: String?) -> [CleanedChord] {
        guard let path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawList = json["chords"] as? [[String: Any]] else { return [] }
        return rawList.compactMap { entry in
            guard let start = (entry["start"] as? NSNumber)?.doubleValue,
                  let end = (entry["end"] as? NSNumber)?.doubleValue,
                  let raw = entry["rawChord"] as? String,
                  let display = entry["displayChord"] as? String else { return nil }
            return CleanedChord(start: start, end: end, rawChord: raw, displayChord: display)
        }
    }

    // MARK: - Backend transport

    /// Short-timeout session for liveness checks.
    nonisolated static let healthSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        return URLSession(configuration: configuration)
    }()

    /// Long-timeout session for analysis uploads. Bounded so a wedged backend
    /// eventually surfaces as a stage failure instead of hanging forever.
    nonisolated static let analysisSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }()

    /// Whether ChordAdminBackend — specifically — is answering.
    ///
    /// A 200 from that port is not enough on its own: this machine runs plenty
    /// of local services, and another one on 5051 would have reported "Backend
    /// ready" right up until every analysis failed against it. The body names
    /// the service, so it is checked. Anything that answers 200 without naming
    /// itself is still accepted, so an older build or a proxy is not locked out.
    nonisolated static func checkBackendHealth() async -> Bool {
        guard let url = URL(string: "\(backendBaseUrl)/health") else { return false }
        do {
            let (data, response) = try await healthSession.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let service = body["service"] as? String else { return true }
            return service == "ChordAdminBackend"
        } catch {
            return false
        }
    }

    /// Uploads `fileURL` as multipart form data.
    ///
    /// The body is assembled on disk and streamed, so a long track no longer
    /// has to be held in memory twice, and a non-2xx reply is raised as an
    /// error instead of being written to the job folder as if it were a result.
    nonisolated static func postAudioFile(
        to urlString: String,
        fileURL: URL,
        params: [String: String]
    ) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chordadmin-upload-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        try writeMultipartBody(to: bodyURL, boundary: boundary, params: params, fileURL: fileURL)

        let (data, response) = try await analysisSession.upload(for: request, fromFile: bodyURL)

        guard let http = response as? HTTPURLResponse else {
            throw JobError.backendRejected("The backend sent an unrecognised response")
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard (200...299).contains(http.statusCode) else {
            let detail = body?["message"] as? String
            throw JobError.backendRejected(
                detail.map { "Backend error \(http.statusCode): \($0)" } ?? "Backend returned HTTP \(http.statusCode)"
            )
        }

        // The backend reports a failed detection as `status: "error"` in the
        // body, still at HTTP 200 — `jsonify(result)` with no status code. Only
        // checking the HTTP code let that through as a success with no beats,
        // and the run then failed two stages later with "Could not build a beat
        // grid" while the real cause ("madmom is not installed") was in the
        // response all along. That is the likeliest first-run problem there is.
        if let status = body?["status"] as? String, status == "error" {
            // The endpoints disagree on the key: beat detection puts the reason
            // in `message`, chord recognition in `error`. Read both rather than
            // falling back to a generic line that says nothing.
            let reason = ["message", "error"]
                .compactMap { body?[$0] as? String }
                .first(where: { !$0.isEmpty })
                ?? "The backend could not process the audio"
            let details = (body?["details"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            throw JobError.backendRejected(details.map { "\(reason) — \($0)" } ?? reason)
        }

        return data
    }

    /// Which file yt-dlp actually wrote, given what it printed.
    ///
    /// Comparing its output against the folder's raw path string was too
    /// brittle to survive a real download: yt-dlp prints a normalised path, so
    /// on macOS the app's `/private/var/…` never matched the `/var/…` it echoed
    /// back, and a run that had downloaded the audio perfectly reported
    /// "Download failed" and threw it away. The paths are now compared the way
    /// the rest of the store compares them, and if that still finds nothing the
    /// folder is asked directly — the output template fixes the name, so the
    /// file is there to be found.
    nonisolated static func downloadedFile(from output: String, in folder: URL) -> String? {
        let wanted = LocalFileStore.comparablePath(folder)
        let printed = output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let match = printed.last(where: {
            LocalFileStore.comparablePath(URL(fileURLWithPath: $0)).hasPrefix(wanted)
        }) {
            return match
        }

        // Nothing usable was printed — but the download may still have landed.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents
            .first { $0.lastPathComponent.hasPrefix("audio.original.") }?
            .path
    }

    /// Streams the multipart envelope and the audio file into `destination`.
    nonisolated private static func writeMultipartBody(
        to destination: URL,
        boundary: String,
        params: [String: String],
        fileURL: URL
    ) throws {
        let fileManager = FileManager.default
        fileManager.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw URLError(.cannotCreateFile)
        }
        defer { try? handle.close() }

        var prologue = ""
        for (key, value) in params {
            prologue += "--\(boundary)\r\n"
            prologue += "Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n"
            prologue += "\(value)\r\n"
        }
        prologue += "--\(boundary)\r\n"
        prologue += "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
        prologue += "Content-Type: audio/wav\r\n\r\n"
        try handle.write(contentsOf: Data(prologue.utf8))

        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }

        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}
