import Foundation

/// Central configuration for ChordAdmin runtime settings.
enum AppConfig {
    static let defaultBackendURL = "http://localhost:5001"

    /// Bump when analysis output format or pipeline behaviour changes so URL cache entries are regenerated.
    static let analysisPipelineVersion = 1

    /// Maximum WAV upload size for backend multipart requests (200 MB).
    static let maxWavUploadBytes: Int64 = 200 * 1024 * 1024

    /// Backend base URL from `CHORDADMIN_BACKEND_URL`, falling back to localhost.
    static var backendBaseURL: String {
        let env = ProcessInfo.processInfo.environment["CHORDADMIN_BACKEND_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if env.isEmpty { return defaultBackendURL }
        return env.hasSuffix("/") ? String(env.dropLast()) : env
    }
}
