import Foundation
import Combine

enum JobError: LocalizedError {
    case missingTools([String])
    case downloadFailed(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTools(let tools):
            return "Missing required tools: \(tools.joined(separator: ", "))"
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .conversionFailed(let msg):
            return "Conversion failed: \(msg)"
        }
    }
}

@MainActor
final class JobManager: ObservableObject {

    @Published var currentJob: AnalysisJob?
    @Published var logOutput: String = ""
    @Published var isRunning: Bool = false

    private var jobFolder: URL?

    func startJob(url: String) async {
        guard !isRunning else { return }

        let cleanedUrl = Self.cleanYouTubeURL(url)
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
            job.status = .completed
            job.completedAt = Date()
            persist(job)
            log("Done. analysis.wav written to: \(wavPath)\n")

        } catch {
            job.status = .failed
            job.errorMessage = error.localizedDescription
            if let folder = jobFolder { try? LocalFileStore.saveJob(job, to: folder) }
            log("ERROR: \(error.localizedDescription)\n")
            currentJob = job
        }

        isRunning = false
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
