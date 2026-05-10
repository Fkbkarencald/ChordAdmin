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

struct SectionCandidateMatch: Codable, Sendable {
    var startBar: Int
    var endBar: Int
}

struct SectionCandidate: Sendable {
    var label: String
    var startBar: Int
    var endBar: Int
    var barCount: Int
    var barSignatures: [String]
    var matchCount: Int
    var matches: [SectionCandidateMatch]

    init(label: String, startBar: Int, endBar: Int, barCount: Int,
         barSignatures: [String], matchCount: Int, matches: [SectionCandidateMatch]) {
        self.label         = label
        self.startBar      = startBar
        self.endBar        = endBar
        self.barCount      = barCount
        self.barSignatures = barSignatures
        self.matchCount    = matchCount
        self.matches       = matches
    }
}

extension SectionCandidate: Codable {
    private enum CodingKeys: String, CodingKey {
        case label, startBar, endBar, barCount, barSignatures, matchCount, matches
        case chords // backward compat — old format stored [String] chords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label      = try c.decode(String.self, forKey: .label)
        startBar   = try c.decode(Int.self,    forKey: .startBar)
        endBar     = try c.decode(Int.self,    forKey: .endBar)
        barCount   = try c.decode(Int.self,    forKey: .barCount)
        matchCount = try c.decode(Int.self,    forKey: .matchCount)
        if let bs = try? c.decode([String].self, forKey: .barSignatures) {
            barSignatures = bs
        } else if let ch = try? c.decode([String].self, forKey: .chords) {
            barSignatures = ch // migrate old format
        } else {
            barSignatures = []
        }
        matches = (try? c.decode([SectionCandidateMatch].self, forKey: .matches)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label,         forKey: .label)
        try c.encode(startBar,      forKey: .startBar)
        try c.encode(endBar,        forKey: .endBar)
        try c.encode(barCount,      forKey: .barCount)
        try c.encode(barSignatures, forKey: .barSignatures)
        try c.encode(matchCount,    forKey: .matchCount)
        try c.encode(matches,       forKey: .matches)
    }
}

struct PerformerChartBarEntry: Sendable {
    var bar: Int          // renumbered from 1, or original bar number
    var sourceBar: Int    // original bar number from draft chart
    var start: Double
    var end: Double
    var primaryChord: String?
    var chords: [ChordChartChordEntry]

    init(bar: Int, sourceBar: Int, start: Double, end: Double,
         primaryChord: String?, chords: [ChordChartChordEntry]) {
        self.bar          = bar
        self.sourceBar    = sourceBar
        self.start        = start
        self.end          = end
        self.primaryChord = primaryChord
        self.chords       = chords
    }
}

extension PerformerChartBarEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case bar, sourceBar, start, end, primaryChord, chords
        case chord // backward compat — old format stored a single chord string
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bar       = try  c.decode(Int.self,    forKey: .bar)
        sourceBar = try  c.decode(Int.self,    forKey: .sourceBar)
        start     = try  c.decode(Double.self, forKey: .start)
        end       = try  c.decode(Double.self, forKey: .end)
        // Try new field first, fall back to old single-chord field
        primaryChord = (try? c.decode(String.self, forKey: .primaryChord))
                    ?? (try? c.decode(String.self, forKey: .chord))
        chords = (try? c.decode([ChordChartChordEntry].self, forKey: .chords)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bar,                   forKey: .bar)
        try c.encode(sourceBar,             forKey: .sourceBar)
        try c.encode(start,                 forKey: .start)
        try c.encode(end,                   forKey: .end)
        try c.encodeIfPresent(primaryChord, forKey: .primaryChord)
        try c.encode(chords,                forKey: .chords)
    }
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
        case .generatingSimpleChart:       return "Generating Charts"  // kept for compat
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
    var sectionsPath: String?
    var sectionCount: Int?
    var barAlignmentOffset: Int?
    var beatsPerBarOverride: Int?
    var manualBpm: Double?
    var tempoHalved: Bool?
    var chartConfigPath: String?
    var chordChartPerformerPath: String?
    var chartStartTime: Double?
    var includePreIntro: Bool?
    var performerChartPreview: [PerformerChartBarEntry]?
    var chartsVersion: Int?
    var errorMessage: String?
}
