import Foundation

struct ToolChecker {
    private static let searchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    static let ytDlp   = resolveTool("yt-dlp")
    static let ffmpeg  = resolveTool("ffmpeg")
    static let ffprobe = resolveTool("ffprobe")
    static let deno    = resolveTool("deno")

    struct CheckResult: Sendable {
        let ytDlpAvailable: Bool
        let ffmpegAvailable: Bool
        let ffprobeAvailable: Bool
        let denoAvailable: Bool
        let resolvedPaths: [String: String]

        var missingTools: [String] {
            var missing: [String] = []
            if !ytDlpAvailable {
                missing.append("yt-dlp (searched: \(Self.searchSummary(for: "yt-dlp"))) — install with: brew install yt-dlp")
            }
            if !ffmpegAvailable {
                missing.append("ffmpeg (searched: \(Self.searchSummary(for: "ffmpeg"))) — install with: brew install ffmpeg")
            }
            if !ffprobeAvailable {
                missing.append("ffprobe (searched: \(Self.searchSummary(for: "ffprobe"))) — install with: brew install ffmpeg")
            }
            if !denoAvailable {
                missing.append("deno (searched: \(Self.searchSummary(for: "deno"))) — install with: brew install deno")
            }
            return missing
        }

        private static func searchSummary(for name: String) -> String {
            searchLocations(for: name).joined(separator: ", ")
        }
    }

  nonisolated static func checkAll() async -> CheckResult {
        let ytDlpPath   = resolveTool("yt-dlp")
        let ffmpegPath  = resolveTool("ffmpeg")
        let ffprobePath = resolveTool("ffprobe")
        let denoPath    = resolveTool("deno")

        async let ytDlpOk   = probe(path: ytDlpPath,   args: ["--version"])
        async let ffmpegOk  = probe(path: ffmpegPath,  args: ["-version"])
        async let ffprobeOk = probe(path: ffprobePath, args: ["-version"])
        async let denoOk    = probe(path: denoPath,    args: ["--version"])

        return await CheckResult(
            ytDlpAvailable: ytDlpOk,
            ffmpegAvailable: ffmpegOk,
            ffprobeAvailable: ffprobeOk,
            denoAvailable: denoOk,
            resolvedPaths: [
                "yt-dlp": ytDlpPath,
                "ffmpeg": ffmpegPath,
                "ffprobe": ffprobePath,
                "deno": denoPath,
            ]
        )
    }

    /// Resolves an executable by searching common install locations and the process `PATH`.
    static func resolveTool(_ name: String) -> String {
        for location in searchLocations(for: name) {
            if FileManager.default.isExecutableFile(atPath: location) {
                return location
            }
        }
        return "\(searchDirectories[0])/\(name)"
    }

    static func searchLocations(for name: String) -> [String] {
        var locations: [String] = searchDirectories.map { "\($0)/\(name)" }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
                locations.append("\(dir)/\(name)")
            }
        }
        return locations
    }

    nonisolated private static func probe(path: String, args: [String]) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        do {
            let result = try await ProcessRunner.run(executablePath: path, arguments: args)
            return result.exitCode == 0
        } catch {
            return false
        }
    }
}
