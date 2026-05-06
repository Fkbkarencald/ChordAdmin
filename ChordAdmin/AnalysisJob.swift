import Foundation

enum JobStatus: String, Codable, Sendable {
    case pending
    case checkingTools
    case downloading
    case converting
    case completed
    case failed

    var displayName: String {
        switch self {
        case .pending:       return "Pending"
        case .checkingTools: return "Checking Tools"
        case .downloading:   return "Downloading"
        case .converting:    return "Converting"
        case .completed:     return "Completed"
        case .failed:        return "Failed"
        }
    }
}

struct AnalysisJob: Codable, Identifiable, Sendable {
    var id: String
    var sourceUrl: String
    var title: String?
    var status: JobStatus
    var createdAt: Date
    var completedAt: Date?
    var originalAudioPath: String?
    var analysisWavPath: String?
    var errorMessage: String?
}
