import Foundation

enum BackendHTTPError: LocalizedError {
    case badURL
    case timeout(String)
    case fileTooLarge(bytes: Int64, limit: Int64)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid backend URL"
        case .timeout(let operation):
            return "\(operation) timed out — check that the backend is running and reachable"
        case .fileTooLarge(let bytes, let limit):
            let mb = Double(bytes) / (1024 * 1024)
            let limitMB = Double(limit) / (1024 * 1024)
            return String(format: "Audio file is too large to upload (%.1f MB; limit %.0f MB)", mb, limitMB)
        case .httpStatus(let code):
            return "Backend returned HTTP \(code)"
        }
    }
}

/// Shared URLSession instances with operation-specific timeouts.
enum BackendHTTPClient {
    enum RequestKind {
        case healthCheck
        case audioUpload
        case stageBeeExport

        var timeout: TimeInterval {
            switch self {
            case .healthCheck:    return 5
            case .audioUpload:    return 120
            case .stageBeeExport: return 30
            }
        }
    }

    private static var sessions: [RequestKind: URLSession] = [:]
    private static let lock = NSLock()

    static func session(for kind: RequestKind) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[kind] { return existing }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = kind.timeout
        config.timeoutIntervalForResource = kind.timeout
        let session = URLSession(configuration: config)
        sessions[kind] = session
        return session
    }

    static func mapURLError(_ error: Error, operation: String) -> Error {
        if let urlError = error as? URLError,
           urlError.code == .timedOut || urlError.code == .networkConnectionLost {
            return BackendHTTPError.timeout(operation)
        }
        return error
    }
}
