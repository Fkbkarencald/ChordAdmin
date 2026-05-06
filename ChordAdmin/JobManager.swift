import Foundation
import Combine

enum JobError: LocalizedError {
    case missingTools([String])
    case downloadFailed(String)
    case conversionFailed(String)
    case metadataFailed(String)
    case audioHealthFailed(String)

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
        }
    }
}

@MainActor
final class JobManager: ObservableObject {

    // MARK: - Backend config
    private static let backendBaseUrl    = "http://localhost:5001"
    private static let defaultBeatModel  = "auto"
    private static let defaultChordModel = "chord-cnn-lstm"

    @Published var currentJob: AnalysisJob?
    @Published var logOutput: String = ""
    @Published var isRunning: Bool = false

    private(set) var jobFolder: URL?

    func startJob(url: String) async {
        guard !isRunning else { return }

        let cleanedUrl = Self.cleanYouTubeURL(url)

        // — URL cache check —
        if let cachedFolder = LocalFileStore.cachedJobFolder(for: cleanedUrl) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let data = try? Data(contentsOf: cachedFolder.appendingPathComponent("job.json")),
               let cached = try? decoder.decode(AnalysisJob.self, from: data) {
                jobFolder  = cachedFolder
                currentJob = cached
                logOutput  = "(Loaded from cache — song and analysis results are reused)\n"
                isRunning  = false
                return
            } else {
                // Stale entry — evict and proceed normally
                LocalFileStore.evictURLCache(url: cleanedUrl)
            }
        }

        let jobId = UUID().uuidString
        var job = AnalysisJob(
            id: jobId,
            sourceUrl: cleanedUrl,
            status: .pending,
            createdAt: Date()
        )

        isRunning = true
        logOutput = ""
        currentJob = job
        jobFolder = nil

        do {
            let folder = try LocalFileStore.createJobFolder(jobId: jobId)
            jobFolder = folder
            try LocalFileStore.saveSourceInfo(["url": cleanedUrl, "jobId": jobId], to: folder)

            // — Check tools —
            job.status = .checkingTools
            persist(job)
            log("Checking tools…\n")

            let toolCheck = await ToolChecker.checkAll()
            guard toolCheck.missingTools.isEmpty else {
                throw JobError.missingTools(toolCheck.missingTools)
            }
            log("All tools found.\n")

            // — Download —
            job.status = .downloading
            persist(job)
            log("Downloading: \(cleanedUrl)\n")

            let outputTemplate = folder.appendingPathComponent("audio.original.%(ext)s").path
            let dlResult = try await ProcessRunner.run(
                executablePath: ToolChecker.ytDlp,
                arguments: [
                    "-f", "ba/b",
                    "--no-playlist",
                    "--js-runtimes", "deno:/opt/homebrew/bin/deno",
                    "--print", "after_move:filepath",
                    "-o", outputTemplate,
                    cleanedUrl
                ],
                onOutput: { [weak self] text in
                    Task { @MainActor [weak self] in self?.log(text) }
                }
            )

            guard dlResult.exitCode == 0 else {
                throw JobError.downloadFailed("yt-dlp exited with code \(dlResult.exitCode)")
            }

            // The --print after_move:filepath line is the path of the downloaded file
            let downloadedPath = dlResult.output
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .last(where: { $0.hasPrefix(folder.path) && !$0.isEmpty })
                ?? ""

            guard !downloadedPath.isEmpty else {
                throw JobError.downloadFailed("Could not determine downloaded file path from yt-dlp output")
            }

            job.originalAudioPath = downloadedPath
            persist(job)
            log("Downloaded: \(downloadedPath)\n")

            // — Convert —
            job.status = .converting
            persist(job)
            log("Converting to analysis.wav…\n")

            let wavPath = folder.appendingPathComponent("analysis.wav").path
            let cvResult = try await ProcessRunner.run(
                executablePath: ToolChecker.ffmpeg,
                arguments: [
                    "-y",
                    "-i", downloadedPath,
                    "-ar", "44100",
                    "-ac", "1",
                    wavPath
                ],
                onOutput: { [weak self] text in
                    Task { @MainActor [weak self] in self?.log(text) }
                }
            )

            guard cvResult.exitCode == 0 else {
                throw JobError.conversionFailed("ffmpeg exited with code \(cvResult.exitCode)")
            }

            job.analysisWavPath = wavPath
            persist(job)
            log("Done. analysis.wav written to: \(wavPath)\n")

            // — Extract metadata —
            job.status = .extractingMetadata
            persist(job)
            log("Extracting metadata with ffprobe…\n")

            let metaPath = folder.appendingPathComponent("metadata.json").path
            let metaResult = try await ProcessRunner.run(
                executablePath: ToolChecker.ffprobe,
                arguments: [
                    "-v", "quiet",
                    "-print_format", "json",
                    "-show_format",
                    "-show_streams",
                    wavPath
                ]
            )

            guard metaResult.exitCode == 0 else {
                throw JobError.metadataFailed("ffprobe exited with code \(metaResult.exitCode)")
            }

            guard let metaData = metaResult.output.data(using: .utf8) else {
                throw JobError.metadataFailed("ffprobe produced no output")
            }
            try metaData.write(to: URL(fileURLWithPath: metaPath))

            let parsed = try Self.parseFFprobeOutput(metaData)
            job.metadataPath    = metaPath
            job.durationSeconds = parsed.duration
            job.sampleRate      = parsed.sampleRate
            job.channels        = parsed.channels
            job.codecName       = parsed.codecName
            job.bitRate         = parsed.bitRate
            job.fileSizeBytes   = parsed.fileSizeBytes

            persist(job)
            log("Metadata saved to: \(metaPath)\n")

            // — Analyse audio health —
            job.status = .analysingAudioHealth
            persist(job)
            log("Analysing audio health...\n")

            // Volume detection
            let volResult = try await ProcessRunner.run(
                executablePath: ToolChecker.ffmpeg,
                arguments: ["-i", wavPath, "-af", "volumedetect", "-f", "null", "-"],
                onOutput: { [weak self] text in
                    Task { @MainActor [weak self] in self?.log(text) }
                }
            )
            let (meanVol, maxVol) = Self.parseVolumeDetect(volResult.output)
            if let m = meanVol { log("Mean volume: \(m) dB\n") }
            if let m = maxVol  { log("Max volume:  \(m) dB\n") }

            // Silence detection
            let silResult = try await ProcessRunner.run(
                executablePath: ToolChecker.ffmpeg,
                arguments: ["-i", wavPath, "-af", "silencedetect=noise=-40dB:d=0.5", "-f", "null", "-"],
                onOutput: { [weak self] text in
                    Task { @MainActor [weak self] in self?.log(text) }
                }
            )
            let silenceRegions = Self.parseSilenceDetect(silResult.output)
            let totalSilence = silenceRegions.reduce(0.0) { $0 + $1.duration }
            log("Silence regions found: \(silenceRegions.count)\n")

            // Warnings
            var warnings: [String] = []
            if let max = maxVol, max > -0.5 {
                warnings.append("Possible clipping or very hot master")
            }
            if let mean = meanVol, mean < -35 {
                warnings.append("Very quiet audio")
            }
            if let dur = job.durationSeconds, dur > 0, (totalSilence / dur) > 0.2 {
                warnings.append("Large silent sections detected")
            }

            // Save audio.health.json
            let healthPath = folder.appendingPathComponent("audio.health.json").path
            let healthPayload: [String: Any] = [
                "meanVolumeDb": meanVol as Any,
                "maxVolumeDb":  maxVol as Any,
                "silenceRegions": silenceRegions.map { [
                    "start":    $0.start,
                    "end":      $0.end,
                    "duration": $0.duration
                ] },
                "totalSilenceDurationSeconds": totalSilence,
                "warnings": warnings
            ]
            let healthData = try JSONSerialization.data(withJSONObject: healthPayload, options: .prettyPrinted)
            try healthData.write(to: URL(fileURLWithPath: healthPath))

            job.audioHealthPath              = healthPath
            job.meanVolumeDb                 = meanVol
            job.maxVolumeDb                  = maxVol
            job.silenceRegionCount           = silenceRegions.count
            job.totalSilenceDurationSeconds  = totalSilence

            persist(job)
            log("Audio health saved to: \(healthPath)\n")
            if !warnings.isEmpty { log("Warnings: \(warnings.joined(separator: "; "))\n") }

            // — Check backend —
            job.status = .checkingAnalysisBackend
            persist(job)
            log("Checking backend at \(Self.backendBaseUrl)\u{2026}\n")

            let backendAvailable = await Self.checkBackendHealth(baseUrl: Self.backendBaseUrl)
            job.analysisBackendAvailable = backendAvailable
            job.backendBaseUrl = Self.backendBaseUrl

            if !backendAvailable {
                job.backendErrorMessage = "Backend unavailable at \(Self.backendBaseUrl)"
                log("Backend unavailable. Job completed with warnings.\n")
                job.status = .completedWithWarnings
                job.completedAt = Date()
                persist(job)
            } else {
                log("Backend available.\n")

                let wavURL = URL(fileURLWithPath: wavPath)

                // — Detect beats —
                job.status = .detectingBeats
                job.requestedBeatModel = Self.defaultBeatModel
                persist(job)
                log("Detecting beats (model: \(Self.defaultBeatModel))\u{2026}\n")

                let beatPath = folder.appendingPathComponent("beat.detection.json").path
                do {
                    let beatData = try await Self.postAudioFile(
                        to: "\(Self.backendBaseUrl)/api/detect-beats",
                        fileURL: wavURL,
                        params: ["model": Self.defaultBeatModel]
                    )
                    try beatData.write(to: URL(fileURLWithPath: beatPath))
                    job.beatDetectionPath = beatPath
                    let (bpm, beatCount, resolvedModel) = Self.parseBeatResponse(beatData)
                    job.bpm              = bpm
                    job.beatCount        = beatCount
                    job.resolvedBeatModel = resolvedModel
                    persist(job)
                    let beatCached = (try? JSONSerialization.jsonObject(with: beatData) as? [String: Any])?["cached"] as? Bool == true
                    log("Beat detection saved to: \(beatPath)\(beatCached ? " (cached)" : "")\n")
                    if let b = bpm        { log("BPM: \(b)\n") }
                    if let bc = beatCount  { log("Beat count: \(bc)\n") }
                    if let rm = resolvedModel { log("Resolved beat model: \(rm)\n") }

                    // — Generate beat grid —
                    job.status = .generatingBeatGrid
                    persist(job)
                    log("Generating beat grid…\n")
                    let gridPath = folder.appendingPathComponent("beat.grid.json").path
                    let (gridPayload, barCount) = Self.generateBeatGrid(from: beatData, bpm: bpm, barAlignmentOffset: 0)
                    if !gridPayload.isEmpty,
                       let gridData = try? JSONSerialization.data(withJSONObject: gridPayload, options: .prettyPrinted) {
                        try gridData.write(to: URL(fileURLWithPath: gridPath))
                        job.beatGridPath            = gridPath
                        job.barCount                = barCount
                        job.barAlignmentOffset      = 0
                        job.estimatedTimeSignature  = gridPayload["estimatedTimeSignature"] as? String
                        persist(job)
                        log("Beat grid saved to: \(gridPath)\n")
                        log("Bar count: \(barCount)\n")
                    }
                } catch {
                    log("Beat detection failed: \(error.localizedDescription)\n")
                }

                // — Recognise chords —
                job.status = .recognizingChords
                job.chordModel = Self.defaultChordModel
                persist(job)
                log("Recognising chords (model: \(Self.defaultChordModel))\u{2026}\n")

                let chordPath = folder.appendingPathComponent("chord.recognition.json").path
                do {
                    let chordData = try await Self.postAudioFile(
                        to: "\(Self.backendBaseUrl)/api/recognize-chords",
                        fileURL: wavURL,
                        params: ["model": Self.defaultChordModel]
                    )
                    try chordData.write(to: URL(fileURLWithPath: chordPath))
                    job.chordRecognitionPath = chordPath
                    let (chordCount, previewChords, cleanedData) = Self.parseChordResponse(chordData)
                    job.chordCount   = chordCount
                    job.chordPreview = previewChords
                    persist(job)
                    let chordCached = (try? JSONSerialization.jsonObject(with: chordData) as? [String: Any])?["cached"] as? Bool == true
                    log("Chord recognition saved to: \(chordPath)\(chordCached ? " (cached)" : "")\n")
                    if let cc = job.chordCount { log("Chord count: \(cc)\n") }

                    // Write chord.cleaned.json from the normalised payload
                    if let cleaned = cleanedData {
                        let cleanedPath = folder.appendingPathComponent("chord.cleaned.json").path
                        try cleaned.write(to: URL(fileURLWithPath: cleanedPath))
                        job.chordCleanedPath = cleanedPath
                        persist(job)
                        log("Chord cleanup saved to: \(cleanedPath)\n")
                    }
                } catch {
                    log("Chord recognition failed: \(error.localizedDescription)\n")
                }

                // — Generate chord chart draft —
                job.status = .generatingChordChart
                persist(job)
                log("Generating chord chart draft...\n")
                if let gridPath    = job.beatGridPath,
                   let cleanedPath = job.chordCleanedPath,
                   let gridData    = try? Data(contentsOf: URL(fileURLWithPath: gridPath)),
                   let cleanedData = try? Data(contentsOf: URL(fileURLWithPath: cleanedPath)) {
                    let chartPath = folder.appendingPathComponent("chord.chart.draft.json").path
                    let (chartPayload, chartBarCount, previewBars) = Self.generateChordChart(
                        beatGridData:     gridData,
                        chordCleanedData: cleanedData,
                        beatGridPath:     gridPath,
                        chordCleanedPath: cleanedPath
                    )
                    if !chartPayload.isEmpty,
                       let chartData = try? JSONSerialization.data(withJSONObject: chartPayload, options: .prettyPrinted) {
                        try? chartData.write(to: URL(fileURLWithPath: chartPath))
                        job.chordChartDraftPath  = chartPath
                        job.chordChartBarCount   = chartBarCount
                        job.chordChartPreview    = previewBars
                        persist(job)
                        log("Chord chart draft saved to: \(chartPath)\n")
                        log("Chart bars: \(chartBarCount)\n")
                    }
                }

                // — Generate performer chart (initial default config) —
                // draft → performer (multi-chord, filtered/deduped)
                if let draftPath = job.chordChartDraftPath,
                   let draftData = try? Data(contentsOf: URL(fileURLWithPath: draftPath)) {
                    let configPath = folder.appendingPathComponent("chart.config.json").path
                    let configPayload: [String: Any] = [
                        "barAlignmentOffset": job.barAlignmentOffset ?? 0,
                        "chartStartTime":     0.0,
                        "chartStartSource":   "auto",
                        "chartStartBarMode":  "renumberFromOne",
                        "includePreIntro":    false,
                        "preIntroLabel":      "Pre-intro",
                    ]
                    if let configData = try? JSONSerialization.data(withJSONObject: configPayload, options: .prettyPrinted) {
                        try? configData.write(to: URL(fileURLWithPath: configPath))
                        job.chartConfigPath = configPath
                        job.includePreIntro = false
                        let performerPath = folder.appendingPathComponent("chord.chart.performer.json").path
                        let (perfPayload, _, perfPreview) = Self.generatePerformerChart(
                            draftData: draftData, configData: configData,
                            draftPath: draftPath, configPath: configPath
                        )
                        if !perfPayload.isEmpty,
                           let perfData = try? JSONSerialization.data(withJSONObject: perfPayload, options: .prettyPrinted) {
                            try? perfData.write(to: URL(fileURLWithPath: performerPath))
                            job.chordChartPerformerPath = performerPath
                            job.performerChartPreview   = perfPreview
                            persist(job)
                            log("Performer chart saved to: \(performerPath)\n")

                            // — Detect section candidates (from performer chart) —
                            job.status = .detectingSections
                            persist(job)
                            log("Detecting section candidates...\n")
                            let candidatesPath = folder.appendingPathComponent("section.candidates.json").path
                            let (candidatesPayload, candidateCount, candidatePreview) = Self.detectSectionCandidates(
                                performerData: perfData,
                                performerPath: performerPath,
                                draftPath:     draftPath
                            )
                            if !candidatesPayload.isEmpty,
                               let candidatesData = try? JSONSerialization.data(withJSONObject: candidatesPayload, options: .prettyPrinted) {
                                try? candidatesData.write(to: URL(fileURLWithPath: candidatesPath))
                                job.sectionCandidatesPath   = candidatesPath
                                job.sectionCandidateCount   = candidateCount
                                job.sectionCandidatePreview = candidatePreview
                                persist(job)
                                log("Section candidates saved to: \(candidatesPath)\n")
                                log("Section candidates: \(candidateCount)\n")

                                // — Generate initial sections from candidates —
                                let sectionsPath = folder.appendingPathComponent("sections.json").path
                                let (sectionsPayload, sectionCount) = Self.generateInitialSections(
                                    performerData:      perfData,
                                    candidatesPayload:  candidatesPayload,
                                    performerPath:      performerPath,
                                    candidatesPath:     candidatesPath
                                )
                                if !sectionsPayload.isEmpty,
                                   let sectionsData = try? JSONSerialization.data(withJSONObject: sectionsPayload, options: .prettyPrinted) {
                                    try? sectionsData.write(to: URL(fileURLWithPath: sectionsPath))
                                    job.sectionsPath = sectionsPath
                                    job.sectionCount = sectionCount
                                    persist(job)
                                    log("Initial sections saved to: \(sectionsPath)\n")
                                    log("Sections: \(sectionCount)\n")
                                }
                            }
                        }
                    }
                }

                job.status = .completed
                job.completedAt = Date()
                persist(job)
                log("Completed.\n")

                // Save to URL cache so re-submitting the same URL is instant
                LocalFileStore.saveURLCache(url: cleanedUrl, folderPath: folder.path)
            }

        } catch {
            job.status = .failed
            job.errorMessage = error.localizedDescription
            if let folder = jobFolder { try? LocalFileStore.saveJob(job, to: folder) }
            log("ERROR: \(error.localizedDescription)\n")
            currentJob = job
        }

        isRunning = false
    }

    // MARK: - Bar alignment regeneration

    /// Regenerates beat grid + both chord charts for the current job using `offset`.
    /// Does NOT re-download, re-convert, re-detect beats or re-recognise chords.
    func regenerateCharts(offset: Int) async {
        guard var job = currentJob,
              let folder = jobFolder,
              let beatPath  = job.beatDetectionPath,
              let cleanedPath = job.chordCleanedPath,
              let beatData    = try? Data(contentsOf: URL(fileURLWithPath: beatPath)),
              let cleanedData = try? Data(contentsOf: URL(fileURLWithPath: cleanedPath))
        else { return }

        isRunning = true
        log("Regenerating charts with bar alignment offset \(offset)…\n")

        // Beat grid
        let effectiveBeatData: Data
        let effectiveBpm: Double?
        if job.tempoHalved == true {
            let (thinned, halvedBpm) = Self.applyTempoHalving(to: beatData)
            effectiveBeatData = thinned
            effectiveBpm = halvedBpm ?? job.bpm.map { $0 / 2 }
        } else {
            effectiveBeatData = beatData
            effectiveBpm = job.bpm
        }
        let (gridPayload, barCount) = Self.generateBeatGrid(from: effectiveBeatData, bpm: effectiveBpm, barAlignmentOffset: offset)
        guard !gridPayload.isEmpty,
              let gridData = try? JSONSerialization.data(withJSONObject: gridPayload, options: .prettyPrinted)
        else { isRunning = false; return }

        let gridPath = folder.appendingPathComponent("beat.grid.json").path
        try? gridData.write(to: URL(fileURLWithPath: gridPath))
        job.beatGridPath           = gridPath
        job.barCount               = barCount
        job.barAlignmentOffset     = offset
        job.estimatedTimeSignature = gridPayload["estimatedTimeSignature"] as? String
        log("Beat grid regenerated (\(barCount) bars).\n")

        // Chord chart draft
        let chartPath = folder.appendingPathComponent("chord.chart.draft.json").path
        let (chartPayload, chartBarCount, previewBars) = Self.generateChordChart(
            beatGridData: gridData, chordCleanedData: cleanedData,
            beatGridPath: gridPath, chordCleanedPath: cleanedPath
        )
        if !chartPayload.isEmpty,
           let chartData = try? JSONSerialization.data(withJSONObject: chartPayload, options: .prettyPrinted) {
            try? chartData.write(to: URL(fileURLWithPath: chartPath))
            job.chordChartDraftPath = chartPath
            job.chordChartBarCount  = chartBarCount
            job.chordChartPreview   = previewBars
            log("Chord chart draft regenerated (\(chartBarCount) bars).\n")
        }

        // Regenerate performer chart from draft, then section candidates from performer
        if let configPath = job.chartConfigPath,
           let draftPath  = job.chordChartDraftPath,
           let draftData  = try? Data(contentsOf: URL(fileURLWithPath: draftPath)) {
            var configJson = (try? JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: configPath))) as? [String: Any]) ?? [:]
            configJson["barAlignmentOffset"] = offset
            if let updatedCfg = try? JSONSerialization.data(withJSONObject: configJson, options: .prettyPrinted) {
                try? updatedCfg.write(to: URL(fileURLWithPath: configPath))
                let performerPath = folder.appendingPathComponent("chord.chart.performer.json").path
                let (perfPayload, _, perfPreview) = Self.generatePerformerChart(
                    draftData: draftData, configData: updatedCfg,
                    draftPath: draftPath, configPath: configPath
                )
                if !perfPayload.isEmpty,
                   let perfData = try? JSONSerialization.data(withJSONObject: perfPayload, options: .prettyPrinted) {
                    try? perfData.write(to: URL(fileURLWithPath: performerPath))
                    job.chordChartPerformerPath = performerPath
                    job.performerChartPreview   = perfPreview
                    log("Performer chart updated after realignment.\n")

                    let candidatesPath = folder.appendingPathComponent("section.candidates.json").path
                    let (candPayload, candCount, candPreview) = Self.detectSectionCandidates(
                        performerData: perfData, performerPath: performerPath, draftPath: draftPath
                    )
                    if !candPayload.isEmpty,
                       let candData = try? JSONSerialization.data(withJSONObject: candPayload, options: .prettyPrinted) {
                        try? candData.write(to: URL(fileURLWithPath: candidatesPath))
                        job.sectionCandidatesPath   = candidatesPath
                        job.sectionCandidateCount   = candCount
                        job.sectionCandidatePreview = candPreview
                    }
                }
            }
        }
        job.chartsVersion = (job.chartsVersion ?? 0) + 1
        persist(job)
        isRunning = false
        log("Alignment offset \(offset) applied.\n")
    }

    // MARK: - Tempo halving

    /// Toggles halved-tempo mode and regenerates all charts.
    func halveTempo(_ halve: Bool) async {
        guard var job = currentJob else { return }
        job.tempoHalved = halve
        currentJob = job
        persist(job)
        log(halve ? "Halving tempo — keeping every other beat…\n" : "Restoring full tempo…\n")
        await regenerateCharts(offset: job.barAlignmentOffset ?? 0)
    }

    // MARK: - Performer chart config update

    /// Updates chart.config.json and regenerates chord.chart.performer.json (from draft).
    /// Also regenerates section.candidates.json.
    /// Does NOT re-run any backend analysis.
    func updatePerformerChart(chartStartTime: Double?, includePreIntro: Bool) async {
        guard var job = currentJob,
              let folder    = jobFolder,
              let draftPath = job.chordChartDraftPath,
              let draftData = try? Data(contentsOf: URL(fileURLWithPath: draftPath))
        else { return }

        let configPath = folder.appendingPathComponent("chart.config.json").path
        let configPayload: [String: Any] = [
            "barAlignmentOffset": job.barAlignmentOffset ?? 0,
            "chartStartTime":     chartStartTime ?? 0.0,
            "chartStartSource":   chartStartTime == nil ? "auto" : "manual",
            "chartStartBarMode":  "renumberFromOne",
            "includePreIntro":    includePreIntro,
            "preIntroLabel":      "Pre-intro",
        ]
        guard let configData = try? JSONSerialization.data(withJSONObject: configPayload, options: .prettyPrinted) else { return }
        try? configData.write(to: URL(fileURLWithPath: configPath))
        job.chartConfigPath = configPath
        job.chartStartTime  = chartStartTime
        job.includePreIntro = includePreIntro

        let performerPath = folder.appendingPathComponent("chord.chart.performer.json").path
        let (performerPayload, _, performerPreview) = Self.generatePerformerChart(
            draftData:  draftData,
            configData: configData,
            draftPath:  draftPath,
            configPath: configPath
        )
        if !performerPayload.isEmpty,
           let performerData = try? JSONSerialization.data(withJSONObject: performerPayload, options: .prettyPrinted) {
            try? performerData.write(to: URL(fileURLWithPath: performerPath))
            job.chordChartPerformerPath = performerPath
            job.performerChartPreview   = performerPreview

            // Also update section candidates
            let candidatesPath = folder.appendingPathComponent("section.candidates.json").path
            let (candPayload, candCount, candPreview) = Self.detectSectionCandidates(
                performerData: performerData, performerPath: performerPath, draftPath: draftPath
            )
            if !candPayload.isEmpty,
               let candData = try? JSONSerialization.data(withJSONObject: candPayload, options: .prettyPrinted) {
                try? candData.write(to: URL(fileURLWithPath: candidatesPath))
                job.sectionCandidatesPath   = candidatesPath
                job.sectionCandidateCount   = candCount
                job.sectionCandidatePreview = candPreview
            }
        }
        job.chartsVersion = (job.chartsVersion ?? 0) + 1
        persist(job)
        let tStr = chartStartTime.map { String(format: "%.3f", $0) } ?? "0.000"
        log("Performer chart updated (chartStartTime=\(tStr)s, includePreIntro=\(includePreIntro)).\n")
    }

    // MARK: - Private helpers

    private func persist(_ job: AnalysisJob) {
        currentJob = job
        if let folder = jobFolder { try? LocalFileStore.saveJob(job, to: folder) }
    }

    private func log(_ text: String) {
        logOutput += text
        if let folder = jobFolder { LocalFileStore.appendLog(text, to: folder) }
    }

    // MARK: - Audio health parsing

    private struct SilenceRegion {
        var start: Double
        var end: Double
        var duration: Double
    }

    /// Parses `mean_volume` and `max_volume` from ffmpeg volumedetect stderr.
    nonisolated private static func parseVolumeDetect(_ output: String) -> (mean: Double?, max: Double?) {
        var mean: Double? = nil
        var max: Double?  = nil
        for line in output.components(separatedBy: "\n") {
            if let r = line.range(of: "mean_volume: ") {
                let rest = String(line[r.upperBound...])
                mean = Double(rest.components(separatedBy: " ").first ?? "")
            }
            if let r = line.range(of: "max_volume: ") {
                let rest = String(line[r.upperBound...])
                max = Double(rest.components(separatedBy: " ").first ?? "")
            }
        }
        return (mean, max)
    }

    /// Parses silence_start / silence_end / silence_duration lines from ffmpeg silencedetect stderr.
    nonisolated private static func parseSilenceDetect(_ output: String) -> [SilenceRegion] {
        var regions: [SilenceRegion] = []
        var pendingStart: Double? = nil
        for line in output.components(separatedBy: "\n") {
            if let r = line.range(of: "silence_start: ") {
                let rest = String(line[r.upperBound...])
                pendingStart = Double(rest.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if line.contains("silence_end:"), let r = line.range(of: "silence_end: ") {
                let endAndRest = String(line[r.upperBound...])
                let parts = endAndRest.components(separatedBy: " | silence_duration: ")
                guard let endVal = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                      let durStr = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                      let durVal = Double(durStr) else { continue }
                let start = pendingStart ?? (endVal - durVal)
                regions.append(SilenceRegion(start: start, end: endVal, duration: durVal))
                pendingStart = nil
            }
        }
        return regions
    }

    // MARK: - Section candidate detection (performer-chart based)

    nonisolated private static func detectSectionCandidates(
        performerData: Data,
        performerPath: String,
        draftPath: String
    ) -> (payload: [String: Any], candidateCount: Int, preview: [SectionCandidate]) {

        guard let json    = try? JSONSerialization.jsonObject(with: performerData) as? [String: Any],
              let rawBars = json["bars"] as? [[String: Any]] else {
            return ([:], 0, [])
        }

        let bpmDouble: Double? = (json["bpm"] as? NSNumber).map { $0.doubleValue }
        let timeSignature = json["timeSignature"] as? String ?? "4/4"
        var warnings: [String] = []

        // Build bar-signature array from filtered/deduped chords
        var barNumbers:  [Int]    = []
        var signatures:  [String] = []

        for bar in rawBars {
            guard let barNum = bar["bar"] as? Int else { continue }
            let primaryChord = bar["primaryChord"] as? String
            let rawChords    = bar["chords"] as? [[String: Any]] ?? []

            let filtered = rawChords
                .compactMap { c -> (chord: String, start: Double)? in
                    guard let dc = c["displayChord"]   as? String,
                          let cs = (c["start"]          as? NSNumber).map({ $0.doubleValue }),
                          let ov = (c["overlapSeconds"] as? NSNumber).map({ $0.doubleValue }),
                          ov >= 0.25 else { return nil }
                    return (dc, cs)
                }
                .sorted { $0.start < $1.start }

            // Remove adjacent duplicates
            var deduped: [String] = []
            for item in filtered {
                if deduped.last != item.chord { deduped.append(item.chord) }
            }

            let sig: String
            if !deduped.isEmpty {
                sig = deduped.joined(separator: "-")
            } else {
                sig = primaryChord ?? "N.C."
            }
            barNumbers.append(barNum)
            signatures.append(sig)
        }

        let totalBarCount = barNumbers.count
        guard totalBarCount >= 4 else {
            warnings.append("Not enough bars for section detection (need ≥ 4, got \(totalBarCount)).")
            let payload: [String: Any] = [
                "source":        ["chordChartPerformerPath": performerPath, "chordChartDraftPath": draftPath],
                "bpm":           bpmDouble.map { jsonDecimal($0, 2) as NSObject } ?? NSNull(),
                "timeSignature": timeSignature,
                "barCount":      totalBarCount,
                "candidates":    [[String: Any]](),
                "warnings":      warnings,
            ]
            return (payload, 0, [])
        }

        // Collect all occurrences of each unique window
        struct Occurrence {
            let firstIndex: Int    // 0-based index into signatures[]
            let windowSize: Int
            var startIndices: [Int]  // all 0-based start indices
        }

        var occurrenceMap:  [String: Occurrence] = [:]
        var insertionOrder: [String]             = []

        for windowSize in [4, 8] {
            guard totalBarCount >= windowSize else { continue }
            for startIndex in 0...(totalBarCount - windowSize) {
                let slice = Array(signatures[startIndex..<(startIndex + windowSize)])
                let key   = "\(windowSize):\(slice.joined(separator: ","))"
                if var existing = occurrenceMap[key] {
                    existing.startIndices.append(startIndex)
                    occurrenceMap[key] = existing
                } else {
                    occurrenceMap[key] = Occurrence(firstIndex: startIndex, windowSize: windowSize, startIndices: [startIndex])
                    insertionOrder.append(key)
                }
            }
        }

        // Keep only repeated sequences
        let repeatedKeys = insertionOrder.filter { occurrenceMap[$0]!.startIndices.count > 1 }

        // Sort: 8-bar first, then higher matchCount, then earlier firstIndex
        let sortedKeys = repeatedKeys.sorted { a, b in
            let oa = occurrenceMap[a]!, ob = occurrenceMap[b]!
            if oa.windowSize != ob.windowSize { return oa.windowSize > ob.windowSize }
            if oa.startIndices.count != ob.startIndices.count { return oa.startIndices.count > ob.startIndices.count }
            return oa.firstIndex < ob.firstIndex
        }

        // Track accepted 8-bar index ranges so we can suppress contained 4-bar candidates
        var accepted8BarIndexRanges: [(start: Int, end: Int)] = []

        let alphabet  = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var labelIndex = 0
        var candidates:     [SectionCandidate]  = []
        var candidatesJSON: [[String: Any]]      = []

        for key in sortedKeys {
            guard let occ = occurrenceMap[key], labelIndex < alphabet.count else { continue }

            // Suppress 4-bar candidates fully contained within an accepted 8-bar candidate
            if occ.windowSize == 4 {
                let contained = accepted8BarIndexRanges.contains { range in
                    occ.firstIndex >= range.start && (occ.firstIndex + 4) <= (range.start + 8)
                }
                if contained { continue }
            }

            if occ.windowSize == 8 {
                accepted8BarIndexRanges.append((start: occ.firstIndex, end: occ.firstIndex + 8))
            }

            let startBar    = barNumbers[occ.firstIndex]
            let endBarIndex = min(occ.firstIndex + occ.windowSize - 1, barNumbers.count - 1)
            let endBar      = barNumbers[endBarIndex]
            let sliceSigs   = Array(signatures[occ.firstIndex..<(occ.firstIndex + occ.windowSize)])

            // Build all matches from every start index
            let matchCount = occ.startIndices.count
            let matches: [SectionCandidateMatch] = occ.startIndices.map { idx in
                let mEnd = barNumbers[min(idx + occ.windowSize - 1, barNumbers.count - 1)]
                return SectionCandidateMatch(startBar: barNumbers[idx], endBar: mEnd)
            }
            let matchesJSON: [[String: Any]] = matches.map { ["startBar": $0.startBar, "endBar": $0.endBar] }

            let label = String(alphabet[alphabet.index(alphabet.startIndex, offsetBy: labelIndex)])
            labelIndex += 1

            candidates.append(SectionCandidate(
                label: label, startBar: startBar, endBar: endBar,
                barCount: occ.windowSize, barSignatures: sliceSigs,
                matchCount: matchCount, matches: matches
            ))
            candidatesJSON.append([
                "label":         label,
                "startBar":      startBar,
                "endBar":        endBar,
                "barCount":      occ.windowSize,
                "barSignatures": sliceSigs,
                "matchCount":    matchCount,
                "matches":       matchesJSON,
            ])
        }

        let payload: [String: Any] = [
            "source": ["chordChartPerformerPath": performerPath, "chordChartDraftPath": draftPath],
            "bpm":           bpmDouble.map { jsonDecimal($0, 2) as NSObject } ?? NSNull(),
            "timeSignature": timeSignature,
            "barCount":      totalBarCount,
            "candidates":    candidatesJSON,
            "warnings":      warnings,
        ]
        return (payload, candidates.count, Array(candidates.prefix(5)))
    }

    // MARK: - Performer chart generation (draft-based, multi-chord bars)

    nonisolated private static func generatePerformerChart(
        draftData:  Data,
        configData: Data,
        draftPath:  String,
        configPath: String
    ) -> (payload: [String: Any], barCount: Int, preview: [PerformerChartBarEntry]) {

        guard let draftJson  = try? JSONSerialization.jsonObject(with: draftData)  as? [String: Any],
              let configJson = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let rawBars    = draftJson["bars"] as? [[String: Any]] else {
            return ([:], 0, [])
        }

        let bpmDouble: Double?    = (draftJson["bpm"] as? NSNumber).map { $0.doubleValue }
        let timeSignature          = draftJson["timeSignature"] as? String ?? "4/4"
        let chartStartTime: Double = (configJson["chartStartTime"] as? NSNumber).map { $0.doubleValue } ?? 0.0
        let includePreIntro        = configJson["includePreIntro"] as? Bool ?? false
        let barMode                = configJson["chartStartBarMode"] as? String ?? "renumberFromOne"

        var preIntroJson: [[String: Any]]        = []
        var mainJson:     [[String: Any]]        = []
        var preview:      [PerformerChartBarEntry] = []
        var mainCounter   = 0

        for bar in rawBars {
            guard let sourceBar = bar["bar"]   as? Int,
                  let barStart  = (bar["start"] as? NSNumber).map({ $0.doubleValue }),
                  let barEnd    = (bar["end"]   as? NSNumber).map({ $0.doubleValue }) else { continue }

            let primaryChord = bar["primaryChord"] as? String
            let rawChords    = bar["chords"] as? [[String: Any]] ?? []

            // Filter (≥ 0.25 s overlap), sort by start, remove adjacent duplicates
            let filtered = rawChords
                .compactMap { c -> (chord: String, start: Double, end: Double, overlap: Double)? in
                    guard let dc = c["displayChord"]   as? String,
                          let cs = (c["start"]          as? NSNumber).map({ $0.doubleValue }),
                          let ce = (c["end"]            as? NSNumber).map({ $0.doubleValue }),
                          let ov = (c["overlapSeconds"] as? NSNumber).map({ $0.doubleValue }),
                          ov >= 0.25 else { return nil }
                    return (dc, cs, ce, ov)
                }
                .sorted { $0.start < $1.start }

            var deduped: [(chord: String, start: Double, end: Double, overlap: Double)] = []
            for item in filtered {
                if deduped.last?.chord != item.chord { deduped.append(item) }
            }

            // Best primary: use existing primaryChord, fall back to highest-overlap deduped, then N.C.
            let effectivePrimary: String = primaryChord
                ?? deduped.max(by: { $0.overlap < $1.overlap })?.chord
                ?? "N.C."

            // If no chord survives filtering, represent the bar with a single primaryChord entry
            let chordsJson: [[String: Any]]
            let chordEntries: [ChordChartChordEntry]
            if deduped.isEmpty {
                chordsJson = [[
                    "displayChord":   effectivePrimary,
                    "start":          jsonDecimal(barStart, 3),
                    "end":            jsonDecimal(barEnd,   3),
                    "overlapSeconds": jsonDecimal(max(0, barEnd - barStart), 3),
                ]]
                chordEntries = [ChordChartChordEntry(
                    displayChord: effectivePrimary,
                    start: round3(barStart), end: round3(barEnd),
                    overlapSeconds: round3(max(0, barEnd - barStart))
                )]
            } else {
                chordsJson = deduped.map { c in [
                    "displayChord":   c.chord,
                    "start":          jsonDecimal(c.start,   3),
                    "end":            jsonDecimal(c.end,     3),
                    "overlapSeconds": jsonDecimal(c.overlap, 3),
                ] }
                chordEntries = deduped.map { c in
                    ChordChartChordEntry(displayChord: c.chord,
                                        start:   round3(c.start), end: round3(c.end),
                                        overlapSeconds: round3(c.overlap))
                }
            }

            if barStart < chartStartTime && !includePreIntro {
                preIntroJson.append([
                    "sourceBar":    sourceBar,
                    "start":        jsonDecimal(barStart, 3),
                    "end":          jsonDecimal(barEnd,   3),
                    "primaryChord": effectivePrimary,
                    "chords":       chordsJson,
                ])
            } else {
                mainCounter += 1
                let displayBar = barMode == "renumberFromOne" ? mainCounter : sourceBar
                mainJson.append([
                    "bar":          displayBar,
                    "sourceBar":    sourceBar,
                    "start":        jsonDecimal(barStart, 3),
                    "end":          jsonDecimal(barEnd,   3),
                    "primaryChord": effectivePrimary,
                    "chords":       chordsJson,
                ])
                if preview.count < 16 {
                    preview.append(PerformerChartBarEntry(
                        bar: displayBar, sourceBar: sourceBar,
                        start: round3(barStart), end: round3(barEnd),
                        primaryChord: effectivePrimary, chords: chordEntries
                    ))
                }
            }
        }

        let bpmJson: Any = bpmDouble.map { jsonDecimal($0, 2) as NSObject } ?? NSNull()
        let payload: [String: Any] = [
            "source": [
                "chordChartDraftPath": draftPath,
                "chartConfigPath":     configPath,
            ] as [String: Any],
            "bpm":             bpmJson,
            "timeSignature":   timeSignature,
            "chartStartTime":  jsonDecimal(chartStartTime, 3),
            "includePreIntro": includePreIntro,
            "preIntro":        preIntroJson,
            "bars":            mainJson,
            "warnings":        [String](),
        ]
        return (payload, mainJson.count, preview)
    }

    // MARK: - Initial sections generation (from candidates + performer bar list)

    nonisolated private static func generateInitialSections(
        performerData: Data,
        candidatesPayload: [String: Any],
        performerPath: String,
        candidatesPath: String
    ) -> (payload: [String: Any], sectionCount: Int) {

        guard let perfJson  = try? JSONSerialization.jsonObject(with: performerData) as? [String: Any],
              let rawBars   = perfJson["bars"] as? [[String: Any]] else { return ([:], 0) }

        let allBars = rawBars.compactMap { $0["bar"] as? Int }.sorted()
        guard !allBars.isEmpty else { return ([:], 0) }

        // Parse candidates from payload
        let rawCands = candidatesPayload["candidates"] as? [[String: Any]] ?? []
        struct Cand { var label: String; var startBar: Int; var endBar: Int
                      var barCount: Int; var matchCount: Int }
        let candidates: [Cand] = rawCands.compactMap { c in
            guard let label = c["label"]      as? String,
                  let sb    = c["startBar"]   as? Int,
                  let eb    = c["endBar"]     as? Int,
                  let bc    = c["barCount"]   as? Int,
                  let mc    = c["matchCount"] as? Int else { return nil }
            return Cand(label: label, startBar: sb, endBar: eb, barCount: bc, matchCount: mc)
        }

        // Select non-overlapping candidates (prefer 8-bar, then higher matchCount)
        let sorted = candidates.sorted { a, b in
            if a.barCount != b.barCount   { return a.barCount   > b.barCount   }
            if a.matchCount != b.matchCount { return a.matchCount > b.matchCount }
            return a.startBar < b.startBar
        }
        var accepted: [Cand] = []
        for cand in sorted {
            let overlaps = accepted.contains { a in
                cand.startBar <= a.endBar && cand.endBar >= a.startBar
            }
            if !overlaps { accepted.append(cand) }
        }
        let ordered = accepted.sorted { $0.startBar < $1.startBar }

        // Build section ranges from allBars + accepted candidates
        struct SecRange { var start: Int; var end: Int }
        var ranges: [SecRange] = []
        var cursor = allBars.first!
        for cand in ordered {
            let gapBars = allBars.filter { $0 >= cursor && $0 < cand.startBar }
            if !gapBars.isEmpty {
                ranges.append(SecRange(start: gapBars.first!, end: gapBars.last!))
            }
            let candBars = allBars.filter { $0 >= cand.startBar && $0 <= cand.endBar }
            if !candBars.isEmpty {
                ranges.append(SecRange(start: candBars.first!, end: candBars.last!))
            }
            cursor = allBars.first(where: { $0 > cand.endBar }) ?? (allBars.last! + 1)
        }
        let tailBars = allBars.filter { $0 >= cursor }
        if !tailBars.isEmpty { ranges.append(SecRange(start: tailBars.first!, end: tailBars.last!)) }
        if ranges.isEmpty    { ranges = [SecRange(start: allBars.first!, end: allBars.last!)] }

        // Assign names
        let letters     = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var letterIndex = 0
        var sectionsJson: [[String: Any]] = []
        for (i, range) in ranges.enumerated() {
            let isFirst  = (i == 0)
            let isLast   = (i == ranges.count - 1)
            let bars     = allBars.filter { $0 >= range.start && $0 <= range.end }
            let barCount = bars.count
            let name: String
            if isFirst {
                name = "Intro"
            } else if isLast {
                name = barCount <= 4 ? "Outro" : "Ending"
            } else {
                if letterIndex < letters.count {
                    let letter = String(letters[letters.index(letters.startIndex, offsetBy: letterIndex)])
                    name = "Section \(letter)"
                } else {
                    name = "Section \(letterIndex + 1)"
                }
                letterIndex += 1
            }
            sectionsJson.append([
                "id":       "section-\(i + 1)",
                "name":     name,
                "startBar": range.start,
                "endBar":   range.end,
                "bars":     bars,
            ])
        }

        let payload: [String: Any] = [
            "source": [
                "chordChartPerformerPath": performerPath,
                "sectionCandidatesPath":   candidatesPath,
            ] as [String: Any],
            "sections": sectionsJson,
        ]
        return (payload, sectionsJson.count)
    }

    // MARK: - Chord chart draft generation

    nonisolated private static func generateChordChart(
        beatGridData: Data,
        chordCleanedData: Data,
        beatGridPath: String,
        chordCleanedPath: String
    ) -> (payload: [String: Any], barCount: Int, previewBars: [ChordChartBarEntry]) {
        guard let gridJson  = try? JSONSerialization.jsonObject(with: beatGridData)     as? [String: Any],
              let chordJson = try? JSONSerialization.jsonObject(with: chordCleanedData) as? [String: Any] else {
            return ([:], 0, [])
        }

        let rawBars       = gridJson["bars"]   as? [[String: Any]] ?? []
        let rawChords     = chordJson["chords"] as? [[String: Any]] ?? []
        let bpmDouble: Double? = (gridJson["bpm"] as? NSNumber).map { $0.doubleValue }
        let timeSignature = gridJson["estimatedTimeSignature"] as? String ?? "4/4"

        var warnings:   [String]               = []
        var chartBars:  [[String: Any]]        = []
        var previewBars: [ChordChartBarEntry]  = []

        for bar in rawBars {
            guard let barStart = bar["start"] as? Double,
                  let barEnd   = bar["end"]   as? Double,
                  let barNum   = bar["bar"]   as? Int else { continue }

            var overlapping:   [[String: Any]]          = []
            var previewChords: [ChordChartChordEntry]   = []
            var primaryChord: String? = nil
            var maxOverlap   = 0.0

            for chord in rawChords {
                guard let chordStart   = chord["start"]        as? Double,
                      let chordEnd     = chord["end"]          as? Double,
                      let displayChord = chord["displayChord"] as? String else { continue }

                let overlapSecs = min(barEnd, chordEnd) - max(barStart, chordStart)
                guard overlapSecs > 0 else { continue }

                overlapping.append([
                    "displayChord":   displayChord,
                    "start":          jsonDecimal(chordStart, 3),
                    "end":            jsonDecimal(chordEnd, 3),
                    "overlapSeconds": jsonDecimal(overlapSecs, 3),
                ])
                previewChords.append(ChordChartChordEntry(
                    displayChord:   displayChord,
                    start:          round3(chordStart),
                    end:            round3(chordEnd),
                    overlapSeconds: round3(overlapSecs)
                ))

                if overlapSecs > maxOverlap {
                    maxOverlap   = overlapSecs
                    primaryChord = displayChord
                }
            }

            if primaryChord == nil {
                warnings.append("Bar \(barNum) has no chord overlap")
            }

            let primaryChordValue: Any = primaryChord.map { $0 as Any } ?? NSNull()
            chartBars.append([
                "bar":          barNum,
                "start":        jsonDecimal(barStart, 3),
                "end":          jsonDecimal(barEnd, 3),
                "chords":       overlapping,
                "primaryChord": primaryChordValue,
            ])

            if previewBars.count < 8 {
                previewBars.append(ChordChartBarEntry(
                    bar:          barNum,
                    start:        round3(barStart),
                    end:          round3(barEnd),
                    primaryChord: primaryChord,
                    chords:       previewChords
                ))
            }
        }

        let payload: [String: Any] = [
            "source": [
                "beatGridPath":     beatGridPath,
                "chordCleanedPath": chordCleanedPath,
            ],
            "bpm":           bpmDouble.map { jsonDecimal($0, 2) as NSObject } ?? NSNull(),
            "timeSignature": timeSignature,
            "barCount":      chartBars.count,
            "bars":          chartBars,
            "warnings":      warnings,
        ]
        return (payload, chartBars.count, previewBars)
    }

    // MARK: - ffprobe output parsing

    private struct FFprobeResult {
        var duration: Double?
        var sampleRate: Int?
        var channels: Int?
        var codecName: String?
        var bitRate: Int?
        var fileSizeBytes: Int64?
    }

    nonisolated private static func parseFFprobeOutput(_ data: Data) throws -> FFprobeResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JobError.metadataFailed("Could not parse ffprobe JSON")
        }
        var result = FFprobeResult()

        // First audio stream
        if let streams = root["streams"] as? [[String: Any]],
           let audioStream = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) {
            result.codecName  = audioStream["codec_name"] as? String
            result.channels   = audioStream["channels"] as? Int
            if let srStr = audioStream["sample_rate"] as? String { result.sampleRate = Int(srStr) }
            if let brStr = audioStream["bit_rate"] as? String    { result.bitRate    = Int(brStr) }
        }

        // Format block
        if let format = root["format"] as? [String: Any] {
            if let durStr  = format["duration"]  as? String { result.duration      = Double(durStr) }
            if let sizeStr = format["size"]       as? String { result.fileSizeBytes = Int64(sizeStr) }
            // Fall back to format bit_rate if stream didn't provide one
            if result.bitRate == nil, let brStr = format["bit_rate"] as? String { result.bitRate = Int(brStr) }
        }

        return result
    }

    // MARK: - Backend helpers

    nonisolated private static func checkBackendHealth(baseUrl: String) async -> Bool {
        guard let url = URL(string: "\(baseUrl)/health") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    nonisolated private static func postAudioFile(
        to urlString: String,
        fileURL: URL,
        params: [String: String]
    ) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        for (key, value) in params {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        let filename = fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    /// Returns an `NSDecimalNumber` formatted to `places` decimal places.
    /// Use for all `Double` values in `[String: Any]` dicts written via `JSONSerialization`
    /// to prevent IEEE 754 artefacts (e.g. 0.86 serialising as 0.85999999999999999).
    nonisolated private static func jsonDecimal(_ v: Double, _ places: Int) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.*f", places, v))
    }

    /// Rounds a Double to N decimal places for use in Swift `Codable` model values.
    /// (JSONEncoder uses Ryu/shortest-decimal and does not need NSDecimalNumber.)
    nonisolated private static func round3(_ v: Double) -> Double {
        Double(String(format: "%.3f", v)) ?? v
    }

    /// Returns a modified copy of beat.detection.json data with every other beat removed
    /// and BPM halved — used when the detector fires at double the true tempo.
    nonisolated private static func applyTempoHalving(to beatData: Data) -> (data: Data, bpm: Double?) {
        guard var json = try? JSONSerialization.jsonObject(with: beatData) as? [String: Any],
              let rawBeats = json["beats"] as? [[String: Any]] else {
            return (beatData, nil)
        }
        json["beats"] = rawBeats.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
        let halvedBpm: Double?
        if let v = json["bpm"] as? Double {
            halvedBpm = v / 2.0
            json["bpm"] = jsonDecimal(v / 2.0, 2)
        } else {
            halvedBpm = nil
        }
        let modData = (try? JSONSerialization.data(withJSONObject: json)) ?? beatData
        return (modData, halvedBpm)
    }

    nonisolated private static func parseBeatResponse(_ data: Data) -> (bpm: Double?, beatCount: Int?, resolvedModel: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        let bpm: Double?
        if let v = json["bpm"] as? Double      { bpm = v }
        else if let v = json["bpm"] as? Int    { bpm = Double(v) }
        else                                    { bpm = nil }

        let beatCount: Int?
        if let v = json["beatCount"] as? Int          { beatCount = v }
        else if let beats = json["beats"] as? [Any]   { beatCount = beats.count }
        else                                           { beatCount = nil }

        let resolvedModel = json["model"] as? String

        return (bpm, beatCount, resolvedModel)
    }

    /// Generates a 4/4 beat grid from beat.detection.json data.
    /// Returns (gridPayload, barCount) — gridPayload is empty on parse failure.
    nonisolated private static func generateBeatGrid(
        from beatData: Data,
        bpm: Double?,
        barAlignmentOffset: Int = 0
    ) -> (payload: [String: Any], barCount: Int) {
        guard let json = try? JSONSerialization.jsonObject(with: beatData) as? [String: Any],
              let rawBeats = json["beats"] as? [[String: Any]] else {
            return ([:], 0)
        }

        let allBeatTimes = rawBeats.compactMap { $0["time"] as? Double }
        let beatsPerBar  = 4
        let offset       = max(0, min(3, barAlignmentOffset))
        var warnings: [String] = []

        if allBeatTimes.count < beatsPerBar {
            warnings.append("Not enough beats for a complete bar.")
        }

        // Pickup beats are those before the first full bar
        let pickupTimes = offset > 0 ? Array(allBeatTimes.prefix(offset)) : []
        let barBeatTimes = Array(allBeatTimes.dropFirst(offset))

        let pickupBeats: [[String: Any]] = pickupTimes.enumerated().map { idx, t in
            ["beat": idx + 1, "time": jsonDecimal(t, 3)]
        }

        var bars: [[String: Any]] = []
        var i = 0
        while i < barBeatTimes.count {
            let slice    = barBeatTimes[i ..< min(i + beatsPerBar, barBeatTimes.count)]
            let barBeats = Array(slice)
            let barStartRaw = barBeats[0]
            let nextBarStartRaw: Double? = (i + beatsPerBar < barBeatTimes.count)
                ? barBeatTimes[i + beatsPerBar]
                : nil
            let beatEntries: [[String: Any]] = barBeats.enumerated().map { idx, t in
                ["beat": idx + 1, "time": jsonDecimal(t, 3)]
            }
            let barEndRaw: Double = nextBarStartRaw ?? (barBeats.last ?? barStartRaw)
            bars.append([
                "bar":   i / beatsPerBar + 1,
                "start": jsonDecimal(barStartRaw, 3),
                "end":   jsonDecimal(barEndRaw, 3),
                "beats": beatEntries,
            ])
            i += beatsPerBar
        }

        let bpmJson: Any = bpm.map { jsonDecimal($0, 2) as NSObject } ?? NSNull()
        let payload: [String: Any] = [
            "bpm":                    bpmJson,
            "beatCount":              allBeatTimes.count,
            "estimatedTimeSignature": "4/4",
            "beatsPerBar":            beatsPerBar,
            "barAlignmentOffset":     offset,
            "pickupBeats":            pickupBeats,
            "bars":                   bars,
            "warnings":               warnings,
        ]
        return (payload, bars.count)
    }

    nonisolated private static func parseChordResponse(
        _ data: Data
    ) -> (chordCount: Int?, previewChords: [CleanedChord]?, cleanedData: Data?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }

        // Prefer values from the normalised cleanedChords payload
        guard let cleaned = json["cleanedChords"] as? [String: Any] else {
            // Fallback for older / stub responses
            let count: Int?
            if let v = json["chordCount"] as? Int       { count = v }
            else if let ch = json["chords"] as? [Any]   { count = ch.count }
            else                                         { count = nil }
            return (count, nil, nil)
        }

        let chordCount = cleaned["chordCount"] as? Int

        // Parse first 10 chords for the UI preview
        let rawList = (cleaned["chords"] as? [[String: Any]]) ?? []
        let previewChords: [CleanedChord] = rawList.prefix(10).compactMap { entry in
            guard let start = entry["start"] as? Double,
                  let end   = entry["end"]   as? Double,
                  let raw   = entry["rawChord"]     as? String,
                  let disp  = entry["displayChord"] as? String else { return nil }
            return CleanedChord(start: round3(start), end: round3(end), rawChord: raw, displayChord: disp)
        }

        // Serialise the cleaned dict for writing to chord.cleaned.json,
        // rounding start/end to 3dp to eliminate floating-point artefacts.
        var mutableCleaned = cleaned
        if var chords = mutableCleaned["chords"] as? [[String: Any]] {
            chords = chords.map { chord in
                var c = chord
                if let s = c["start"] as? Double { c["start"] = jsonDecimal(s, 3) }
                if let e = c["end"]   as? Double { c["end"]   = jsonDecimal(e, 3) }
                return c
            }
            mutableCleaned["chords"] = chords
        }
        let cleanedData = try? JSONSerialization.data(
            withJSONObject: mutableCleaned,
            options: .prettyPrinted
        )

        return (chordCount, previewChords.isEmpty ? nil : previewChords, cleanedData)
    }

    // MARK: - URL cleanup

    /// Strips the `list` query parameter from youtu.be and youtube.com short-link URLs
    /// so --no-playlist doesn't fail on playlist-appended share links.
    nonisolated static func cleanYouTubeURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return raw
        }
        let isYouTube = components.host?.contains("youtu.be") == true
            || components.host?.contains("youtube.com") == true
        guard isYouTube, var items = components.queryItems, !items.isEmpty else {
            return raw
        }
        items.removeAll { $0.name == "list" }
        components.queryItems = items.isEmpty ? nil : items
        return components.url?.absoluteString ?? raw
    }
}
