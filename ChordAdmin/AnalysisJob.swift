import Foundation

// MARK: - Supporting types

nonisolated struct CleanedChord: Codable, Sendable {
    var start: Double
    var end: Double
    var rawChord: String
    var displayChord: String
}

nonisolated struct ChordChartChordEntry: Codable, Sendable {
    var displayChord: String
    var start: Double
    var end: Double
    var overlapSeconds: Double
}

nonisolated struct ChordChartBarEntry: Codable, Sendable {
    var bar: Int
    var start: Double
    var end: Double
    var primaryChord: String?
    var chords: [ChordChartChordEntry]
}

nonisolated struct SectionCandidateMatch: Codable, Sendable {
    var startBar: Int
    var endBar: Int
}

nonisolated struct SectionCandidate: Sendable {
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

nonisolated struct PerformerChartBarEntry: Sendable {
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

// MARK: - Job status

nonisolated enum JobStatus: String, Codable, Sendable {
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
    case generatingSimpleChart      // legacy: never written, kept so old job.json still decodes
    case detectingSections
    case completed
    /// Audio is downloaded and converted, but analysis has not run — usually
    /// because the backend was unreachable. Resumable without re-downloading.
    case audioReady
    case completedWithWarnings
    case cancelled
    case failed

    /// Unknown values from a newer build decode as `.pending` rather than
    /// making the whole job.json unreadable.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobStatus(rawValue: raw) ?? .pending
    }

    var displayName: String {
        switch self {
        case .pending:                 return "Pending"
        case .checkingTools:           return "Checking tools"
        case .downloading:             return "Downloading"
        case .converting:              return "Converting"
        case .extractingMetadata:      return "Reading metadata"
        case .analysingAudioHealth:    return "Analysing audio health"
        case .checkingAnalysisBackend: return "Checking backend"
        case .detectingBeats:          return "Detecting beats"
        case .generatingBeatGrid:      return "Building beat grid"
        case .recognizingChords:       return "Recognising chords"
        case .generatingChordChart:    return "Building chart"
        case .generatingSimpleChart:   return "Building chart"
        case .detectingSections:       return "Detecting sections"
        case .completed:               return "Analysed"
        case .audioReady:              return "Audio ready — analysis paused"
        case .completedWithWarnings:   return "Analysed with warnings"
        case .cancelled:               return "Cancelled"
        case .failed:                  return "Failed"
        }
    }

    /// True while the pipeline is actively working.
    var isRunning: Bool {
        switch self {
        case .pending, .completed, .audioReady, .completedWithWarnings, .cancelled, .failed:
            return false
        default:
            return true
        }
    }
}

// MARK: - Export record

/// What was last written to TheStageBee for this job, and what it replaced.
/// Kept so the UI can show "exported 2 minutes ago", flag local edits made
/// since, and let the user see what a re-export would overwrite.
nonisolated struct ExportRecord: Codable, Sendable, Equatable {
    var exportedAt: Date
    var documentID: String
    var songTitle: String?
    var tempo: Int?
    var sectionCount: Int
    var previousTempo: Int?
    var previousSectionCount: Int?
}

// MARK: - Analysis job

nonisolated struct AnalysisJob: Codable, Identifiable, Sendable {
    var id: String
    var sourceUrl: String
    var title: String?
    var status: JobStatus
    var createdAt: Date
    var completedAt: Date?

    // — Song identity —
    // Stamped when the job is created so an analysis can never be exported onto
    // a different song's Firestore document than the one it was run for.
    var songDocumentID: String?
    var songVideoID: String?

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

    // — Backend —
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

    // — Charts —
    var chordChartDraftPath: String?
    var chordChartBarCount: Int?
    var chordChartPreview: [ChordChartBarEntry]?
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
    /// How many bars of the built chart carry no chord at all. Counted over the
    /// whole chart, not the eight-bar preview — the preview count reported a
    /// clean run for a song that was half "N.C.".
    var barsWithoutChords: Int?

    // — Progress, edits and export —
    var stages: [StageRecord]?
    /// Per-bar subdivision chosen by the user; persisted so it survives relaunch
    /// and is reused at export time. Keys are bar numbers as strings.
    var barSubdivisions: [String: Int]?
    /// Last time the user changed sections or subdivisions for this job.
    var lastEditedAt: Date?
    var lastExport: ExportRecord?

    var errorMessage: String?
    /// Something the user should know about a job that is otherwise fine — set
    /// when a re-analysis was rolled back and the previous one put back, which
    /// would otherwise look like the new run simply vanished.
    var notice: String?
    /// True when the run stopped because the user cancelled it, as opposed to a
    /// quit or crash. Both leave `.audioReady`, but they read very differently.
    var stoppedByUser: Bool?

    init(
        id: String,
        sourceUrl: String,
        status: JobStatus,
        createdAt: Date,
        title: String? = nil,
        songDocumentID: String? = nil,
        songVideoID: String? = nil
    ) {
        self.id = id
        self.sourceUrl = sourceUrl
        self.status = status
        self.createdAt = createdAt
        self.title = title
        self.songDocumentID = songDocumentID
        self.songVideoID = songVideoID
    }
}

// MARK: - Derived state

// `nonisolated` to match the type: these are pure reads of a value type, and
// hydration has to consult them off the main actor while reading job folders.
nonisolated extension AnalysisJob {
    var stageReport: StageReport {
        get { StageReport(records: stages ?? []) }
        set { stages = newValue.records }
    }

    /// True when the chart pane has something real to show.
    var hasChart: Bool { chordChartPerformerPath != nil || chordChartDraftPath != nil }

    /// Why an analysis stopped short, so the UI does not blame the backend for
    /// something the user cancelled or a quit interrupted.
    enum PauseCause {
        case backendUnavailable(String)
        case cancelled
        case interrupted

        var isBackend: Bool {
            if case .backendUnavailable = self { return true }
            return false
        }
    }

    var pauseCause: PauseCause {
        if stoppedByUser == true { return .cancelled }
        if let message = backendErrorMessage { return .backendUnavailable(message) }
        if status == .cancelled { return .cancelled }
        return .interrupted
    }

    /// Audio exists locally, so analysis can resume without downloading again.
    var hasAudio: Bool {
        guard let path = analysisWavPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var isExportable: Bool { chordChartPerformerPath != nil && sectionsPath != nil }

    /// The user has changed sections or subdivisions since the last export.
    /// Whether the exported document is out of date.
    ///
    /// A re-analysis rewrites the whole chart without touching `lastEditedAt`,
    /// so completion counts as a change too — otherwise a song re-analysed after
    /// an export still reads as "Exported" and nothing tells the user the
    /// document no longer matches what is on screen.
    var hasUnexportedEdits: Bool {
        guard let export = lastExport else { return false }
        guard let changed = [lastEditedAt, completedAt].compactMap({ $0 }).max() else { return false }
        return changed > export.exportedAt
    }

    var subdivisionsByBar: [Int: Int] {
        get {
            guard let stored = barSubdivisions else { return [:] }
            return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
        }
        set {
            barSubdivisions = newValue.isEmpty
                ? nil
                : Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
        }
    }

    /// Audio-health warnings, derived from the stored measurements so the UI and
    /// the stage checklist never disagree about what was flagged.
    var audioHealthWarnings: [String] {
        var warnings: [String] = []
        if let maxVolume = maxVolumeDb, maxVolume > -0.5 {
            warnings.append("Possible clipping or very hot master")
        }
        if let meanVolume = meanVolumeDb, meanVolume < -35 {
            warnings.append(String(format: "Very quiet audio (%.0f dB mean) — chords may be less reliable", meanVolume))
        }
        if let duration = durationSeconds, duration > 0,
           let silence = totalSilenceDurationSeconds, (silence / duration) > 0.2 {
            warnings.append("Large silent sections detected")
        }
        return warnings
    }
}
