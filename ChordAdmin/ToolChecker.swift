import Foundation

// MARK: - Tools

/// The command-line tools the download/convert stages shell out to.
nonisolated enum Tool: String, CaseIterable, Sendable, Identifiable {
    case ytDlp   = "yt-dlp"
    case ffmpeg  = "ffmpeg"
    case ffprobe = "ffprobe"
    case deno    = "deno"

    var id: String { rawValue }

    var versionArgument: String {
        switch self {
        case .ytDlp, .deno:      return "--version"
        case .ffmpeg, .ffprobe:  return "-version"
        }
    }

    var installHint: String {
        switch self {
        case .ytDlp:             return "brew install yt-dlp"
        case .ffmpeg, .ffprobe:  return "brew install ffmpeg"
        case .deno:              return "brew install deno"
        }
    }

    /// Why the tool matters, shown next to a missing tool so the user knows
    /// what actually stops working.
    var purpose: String {
        switch self {
        case .ytDlp:   return "needed to download audio"
        case .ffmpeg:  return "needed to convert audio"
        case .ffprobe: return "needed to read audio metadata"
        case .deno:    return "needed for YouTube downloads"
        }
    }
}

nonisolated struct ToolStatus: Sendable, Equatable, Identifiable {
    let tool: Tool
    /// Resolved absolute path, or nil when the tool could not be found.
    let path: String?
    /// First line of the tool's version output, trimmed.
    let version: String?
    /// Set when the tool was found but would not run — a Homebrew binary broken
    /// by a missing dylib, say. Without this the panel said "not installed" and
    /// offered a `brew install` that cannot fix it, having thrown away the one
    /// message that explained the real problem.
    var foundButUnusable: (path: String, reason: String)?

    init(tool: Tool, path: String?, version: String?,
         foundButUnusable: (path: String, reason: String)? = nil) {
        self.tool = tool
        self.path = path
        self.version = version
        self.foundButUnusable = foundButUnusable
    }

    var id: String { tool.rawValue }
    var isAvailable: Bool { path != nil }

    static func == (lhs: ToolStatus, rhs: ToolStatus) -> Bool {
        lhs.tool == rhs.tool && lhs.path == rhs.path && lhs.version == rhs.version
            && lhs.foundButUnusable?.path == rhs.foundButUnusable?.path
            && lhs.foundButUnusable?.reason == rhs.foundButUnusable?.reason
    }
}

nonisolated struct ToolReport: Sendable, Equatable {
    let statuses: [ToolStatus]
    let checkedAt: Date

    func status(for tool: Tool) -> ToolStatus? {
        statuses.first { $0.tool == tool }
    }

    func path(for tool: Tool) -> String? {
        status(for: tool)?.path
    }

    var missing: [Tool] { statuses.filter { !$0.isAvailable }.map(\.tool) }

    var allAvailable: Bool { missing.isEmpty }

    /// One line per missing tool, with the fix.
    var missingDescriptions: [String] {
        missing.map { tool in
            // A tool that is present but broken needs the error, not an install
            // command that will change nothing.
            if let broken = statuses.first(where: { $0.tool == tool })?.foundButUnusable {
                return "\(tool.rawValue) — \(tool.purpose). Found at \(broken.path) but it would not run: \(broken.reason)"
            }
            return "\(tool.rawValue) — \(tool.purpose). Install with: \(tool.installHint)"
        }
    }
}

// MARK: - Checker

nonisolated struct ToolChecker {

    /// Where to look, in order. Covers Apple-silicon Homebrew, Intel Homebrew,
    /// MacPorts and the system paths — the old build only ever looked in
    /// /opt/homebrew/bin, so every tool read as missing on an Intel Mac.
    static let searchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
        "/bin",
    ]

    /// Resolves a tool without running it. Also honours anything already on the
    /// process PATH, which covers unusual installs.
    nonisolated static func resolvePath(for tool: Tool) -> String? {
        var directories = searchDirectories
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
        }
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(tool.rawValue)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Resolves every tool and reads its version. Safe to call repeatedly —
    /// the readiness panel uses it for its "Check again" button.
    ///
    /// Throws `CancellationError` rather than reporting the tools as missing:
    /// a cancelled probe says nothing about whether ffmpeg is installed, and a
    /// caller that could not tell the difference blamed the user's setup for
    /// their own Cancel button.
    nonisolated static func check() async throws -> ToolReport {
        var statuses: [ToolStatus] = []
        for tool in Tool.allCases {
            try Task.checkCancellation()
            statuses.append(try await probe(tool))
        }
        return ToolReport(statuses: statuses, checkedAt: Date())
    }

    nonisolated private static func probe(_ tool: Tool) async throws -> ToolStatus {
        guard let path = resolvePath(for: tool) else {
            return ToolStatus(tool: tool, path: nil, version: nil)
        }
        do {
            let result = try await ProcessRunner.run(
                executablePath: path,
                arguments: [tool.versionArgument]
            )
            guard result.exitCode == 0 else {
                // Found, but it will not run. Keep the path and why.
                let reason = result.output
                    .split(separator: "\n")
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    ?? "exited with code \(result.exitCode)"
                return ToolStatus(tool: tool, path: nil, version: nil,
                                  foundButUnusable: (path: path, reason: reason))
            }
            return ToolStatus(tool: tool, path: path, version: shortVersion(from: result.output, tool: tool))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ToolStatus(tool: tool, path: nil, version: nil)
        }
    }

    /// ffmpeg prints a paragraph; yt-dlp and deno print a single token. Reduce
    /// both to something that fits one line in the inspector.
    nonisolated private static func shortVersion(from output: String, tool: Tool) -> String? {
        let firstLine = output
            .components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces)
        guard let firstLine, !firstLine.isEmpty else { return nil }

        switch tool {
        case .ffmpeg, .ffprobe:
            // "ffmpeg version 7.1 Copyright (c) 2000-2024 …"
            let parts = firstLine.components(separatedBy: " ")
            if let idx = parts.firstIndex(of: "version"), parts.count > idx + 1 {
                return parts[idx + 1]
            }
            return String(firstLine.prefix(40))
        case .deno:
            // "deno 2.1.4 (stable, release, aarch64-apple-darwin)"
            let parts = firstLine.components(separatedBy: " ")
            return parts.count > 1 ? parts[1] : firstLine
        case .ytDlp:
            return firstLine
        }
    }
}
