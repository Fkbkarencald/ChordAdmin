import Foundation

struct ToolChecker {
    static let ytDlp   = "/opt/homebrew/bin/yt-dlp"
    static let ffmpeg  = "/opt/homebrew/bin/ffmpeg"
    static let ffprobe = "/opt/homebrew/bin/ffprobe"
    static let deno    = "/opt/homebrew/bin/deno"

    struct CheckResult: Sendable {
        let ytDlpAvailable: Bool
        let ffmpegAvailable: Bool
        let ffprobeAvailable: Bool
        let denoAvailable: Bool
        var missingTools: [String] {
            var missing: [String] = []
            if !ytDlpAvailable   { missing.append("yt-dlp (\(ytDlp)) — install with: brew install yt-dlp") }
            if !ffmpegAvailable  { missing.append("ffmpeg (\(ffmpeg)) — install with: brew install ffmpeg") }
            if !ffprobeAvailable { missing.append("ffprobe (\(ffprobe)) — install with: brew install ffmpeg") }
            if !denoAvailable    { missing.append("deno (\(deno)) — install with: brew install deno") }
            return missing
        }
    }

    nonisolated static func checkAll() async -> CheckResult {
        async let ytDlpOk   = probe(path: ytDlp,   args: ["--version"])
        async let ffmpegOk  = probe(path: ffmpeg,  args: ["-version"])
        async let ffprobeOk = probe(path: ffprobe, args: ["-version"])
        async let denoOk    = probe(path: deno,    args: ["--version"])
        return await CheckResult(
            ytDlpAvailable: ytDlpOk,
            ffmpegAvailable: ffmpegOk,
            ffprobeAvailable: ffprobeOk,
            denoAvailable: denoOk
        )
    }

    nonisolated private static func probe(path: String, args: [String]) async -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            let result = try await ProcessRunner.run(executablePath: path, arguments: args)
            return result.exitCode == 0
        } catch {
            return false
        }
    }
}
