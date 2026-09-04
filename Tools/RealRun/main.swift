import Foundation

// Drives the real pipeline against the real ChordAdminBackend.
//
// The stub in Tools/PipelineTests proves the app's logic; this proves the
// contract. Everything here is the app's own code — JobManager, the real
// yt-dlp/ffmpeg stages, the real backend — with nothing substituted.
//
//   real-run <youtube-url> [--title T]      download, convert, analyse
//   real-run --audio <file.wav> [--title T] skip the download, analyse the file
//
// Job folders go to CHORDADMIN_JOBS_DIR, so this never touches real data.

@MainActor
func main() async {
    var args = Array(CommandLine.arguments.dropFirst())
    var audioPath: String?
    var title = "Real Run"
    var url: String?

    while let arg = args.first {
        args.removeFirst()
        switch arg {
        case "--audio": audioPath = args.isEmpty ? nil : args.removeFirst()
        case "--title": title = args.isEmpty ? title : args.removeFirst()
        default:        url = arg
        }
    }

    guard audioPath != nil || url != nil else {
        print("usage: real-run <youtube-url> | --audio <file> [--title T]")
        exit(2)
    }

    print("backend: \(JobManager.backendBaseUrl)")
    guard await JobManager.checkBackendHealth() else {
        print("✗ backend is not answering — start it first")
        exit(1)
    }
    print("✓ backend healthy")

    let manager = JobManager()
    await manager.hydrate()

    let songID = "real-run-song"
    let ref = SongRef(documentID: songID, title: title, artist: nil,
                      url: url ?? "https://youtu.be/local-audio")

    // Seed a job that already has its audio, so the run resumes at the backend
    // stages instead of downloading.
    if let audioPath {
        guard FileManager.default.fileExists(atPath: audioPath) else {
            print("✗ no such audio file: \(audioPath)")
            exit(1)
        }
        let folder = LocalFileStore.baseDirectory
            .appendingPathComponent("real-run", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent("analysis.wav")
        try? FileManager.default.removeItem(at: wav)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: audioPath), to: wav)

        var seed = AnalysisJob(id: "real-run", sourceUrl: ref.url, status: .audioReady,
                               createdAt: Date(), title: title,
                               songDocumentID: songID, songVideoID: "local")
        seed.analysisWavPath = wav.path
        var report = StageReport()
        for stage in PipelineStage.audioStages { report.set(stage, .done, elapsed: 0) }
        seed.stageReport = report
        try? LocalFileStore.saveJob(seed, to: folder)
        await manager.hydrate()
        print("▸ resuming from \(wav.path)")
    }

    let started = Date()
    manager.start(ref, resumeIfPossible: true)

    var lastLine = ""
    while manager.isRunning(songID) || manager.runningSongID != nil {
        if let stage = manager.job(for: songID)?.stageReport.runningStage {
            let line = "  … \(stage.title)"
            if line != lastLine { print(line); lastLine = line }
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    let elapsed = Date().timeIntervalSince(started)
    guard let job = manager.job(for: songID) else {
        print("✗ no job recorded")
        exit(1)
    }

    print("\n── result in \(String(format: "%.1f", elapsed))s ──")
    print("status        \(job.status.displayName)")
    print("bpm           \(job.bpm.map { String(format: "%.2f", $0) } ?? "—")")
    print("beats         \(job.beatCount.map(String.init) ?? "—")")
    print("time sig      \(job.estimatedTimeSignature ?? "—")")
    print("bars          \(job.barCount.map(String.init) ?? "—")")
    print("chords        \(job.chordCount.map(String.init) ?? "—")")
    print("chordless     \(job.barsWithoutChords.map(String.init) ?? "—")")
    print("sections      \(job.sectionCount.map(String.init) ?? "—")")
    print("exportable    \(job.isExportable)")
    if let message = job.errorMessage { print("error         \(message)") }

    print("\nstages:")
    for record in job.stageReport.records {
        let mark: String
        switch record.state {
        case .done:    mark = "✓"
        case .warning: mark = "!"
        case .failed:  mark = "✗"
        case .skipped: mark = "–"
        default:       mark = "?"
        }
        let detail = record.state.message.map { " — \($0)" } ?? ""
        print("  \(mark) \(record.stage.title)\(detail)")
    }

    if let folder = manager.folder(for: songID) {
        print("\nfolder: \(folder.path)")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files.sorted() {
            let path = folder.appendingPathComponent(file).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int ?? 0
            print(String(format: "  %-32@ %8d bytes", file as NSString, size))
        }
    }

    let chart = JobManager.loadBars(atPath: job.chordChartPerformerPath)
    if !chart.isEmpty {
        print("\nfirst 8 bars:")
        for bar in chart.prefix(8) {
            let chords = bar.chords.map(\.displayChord).joined(separator: " ")
            print(String(format: "  bar %-3d %6.2f–%6.2f  %@",
                         bar.bar, bar.start, bar.end,
                         chords.isEmpty ? "N.C." : chords))
        }
    }

    exit(job.isExportable ? 0 : 1)
}

await main()
