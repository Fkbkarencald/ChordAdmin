import Foundation

// MARK: - Supporting types

struct CleanedChord: Codable, Sendable {
    var start: Double
    var end: Double
    var rawChord: String
    var displayChord: String
}

struct ChordChartChordEntry: Codable, Sendable {
    var displayChord: String
    var start: Double
    var end: Double
    var overlapSeconds: Double
}

struct ChordChartBarEntry: Codable, Sendable {
    var bar: Int
    var start: Double
    var end: Double
    var primaryChord: String?
    var chords: [ChordChartChordEntry]
}

struct ChordChartSimpleBarEntry: Codable, Sendable {
    var bar: Int
    var start: Double
    var end: Double
    var chord: String
}

struct SectionCandidate: Codable, Sendable {
    var label: String
    var startBar: Int
    var endBar: Int
    var barCount: Int
    var chords: [String]
    var matchCount: Int
}

struct PerformerChartBarEntry: Codable, Sendable {
    var bar: Int          // renumbered from 1, or original bar number
    var sourceBar: Int    // original bar number from simple chart
    var start: Double
    var end: Double
    var chord: String
}

enum JobStatus: String, Codable, Sendable {
    case pending
    case checkingTools
    case downloading
    case converting
    case extractingMetadata
    case analysingAudioHealth
    case checkingAnalysisBackend
    case detectingBeats
    case generatingBeatGrid
    case recognizingChords
    case generatingChordChart
    case generatingSimpleChart
    case detectingSections
    case completed
    case completedWithWarnings
    case failed

    var displayName: String {
        switch self {
        case .pending:                   return "Pending"
        case .checkingTools:             return "Checking Tools"
        case .downloading:               return "Downloading"
        case .converting:                return "Converting"
        case .extractingMetadata:        return "Extracting Metadata"
        case .analysingAudioHealth:      return "Analysing Audio Health"
        case .checkingAnalysisBackend:   return "Checking Backend"
        case .detectingBeats:            return "Detecting Beats"
        case .generatingBeatGrid:        return "Generating Beat Grid"
        case .recognizingChords:         return "Recognising Chords"        case .generatingChordChart:       return "Generating Chord Chart"
        case .generatingSimpleChart:       return "Generating Simple Chart"
        case .detectingSections:           return "Detecting Sections"
        case .completed:                 return "Completed"
        case .completedWithWarnings:     return "Completed with Warnings"
        case .failed:                    return "Failed"
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
    var metadataPath: String?
    var durationSeconds: Double?
    var sampleRate: Int?
    var channels: Int?
    var codecName: String?
    var bitRate: Int?
    var fileSizeBytes: Int64?
    var audioHealthPath: String?
    var meanVolumeDb: Double?
    var maxVolumeDb: Double?
    var silenceRegionCount: Int?
    var totalSilenceDurationSeconds: Double?
    // Backend
    var analysisBackendAvailable: Bool?
    var backendBaseUrl: String?
    var backendErrorMessage: String?
    var requestedBeatModel: String?
    var resolvedBeatModel: String?
    var chordModel: String?
    var beatDetectionPath: String?
    var beatGridPath: String?
    var chordRecognitionPath: String?
    var chordCleanedPath: String?
    var bpm: Double?
    var beatCount: Int?
    var barCount: Int?
    var estimatedTimeSignature: String?
    var chordCount: Int?
    var chordPreview: [CleanedChord]?
    var chordChartDraftPath: String?
    var chordChartBarCount: Int?
    var chordChartPreview: [ChordChartBarEntry]?
    var chordChartSimplePath: String?
    var chordChartSimpleBarCount: Int?
    var chordChartSimplePreview: [ChordChartSimpleBarEntry]?
    var sectionCandidatesPath: String?
    var sectionCandidateCount: Int?
    var sectionCandidatePreview: [SectionCandidate]?
    var barAlignmentOffset: Int?
    var chartConfigPath: String?
    var chordChartPerformerPath: String?
    var chartStartTime: Double?
    var includePreIntro: Bool?
    var performerChartPreview: [PerformerChartBarEntry]?
    var chartsVersion: Int?
    var errorMessage: String?
}
