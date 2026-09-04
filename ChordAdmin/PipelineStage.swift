import Foundation

// MARK: - Pipeline stages

/// The user-facing steps of an analysis run, in execution order.
///
/// These replace the old "current status capsule" as the primary progress
/// surface: every stage reports its own outcome, so a run that produced no
/// chart can never present itself as a plain success.
nonisolated enum PipelineStage: String, Codable, CaseIterable, Sendable, Identifiable {
    case tools
    case download
    case convert
    case metadata
    case health
    case backend
    case beats
    case beatGrid
    case chords
    case chart
    case sections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tools:    return "Tools check"
        case .download: return "Download audio"
        case .convert:  return "Convert to WAV"
        case .metadata: return "Read metadata"
        case .health:   return "Audio health"
        case .backend:  return "Backend check"
        case .beats:    return "Detect beats"
        case .beatGrid: return "Beat grid"
        case .chords:   return "Recognise chords"
        case .chart:    return "Build chart"
        case .sections: return "Detect sections"
        }
    }

    /// Stages that run entirely on this machine, with no analysis backend.
    /// Everything from `.backend` onwards needs the local Python service.
    var needsBackend: Bool {
        switch self {
        case .tools, .download, .convert, .metadata, .health: return false
        case .backend, .beats, .beatGrid, .chords, .chart, .sections: return true
        }
    }

    /// Stages that produce the downloaded/converted audio. Once these are done a
    /// re-run can resume from `.backend` without downloading anything again.
    static var audioStages: [PipelineStage] { [.tools, .download, .convert, .metadata, .health] }

    static var analysisStages: [PipelineStage] { [.backend, .beats, .beatGrid, .chords, .chart, .sections] }
}

// MARK: - Stage state

nonisolated enum StageState: Codable, Sendable, Equatable {
    case pending
    case running
    case done
    /// Finished, but with something the user should read.
    case warning(String)
    /// Deliberately not run, with the reason why.
    case skipped(String)
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .pending, .running: return false
        case .done, .warning, .skipped, .failed: return true
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .warning(let m), .skipped(let m), .failed(let m): return m
        case .pending, .running, .done: return nil
        }
    }
}

nonisolated struct StageRecord: Codable, Sendable, Equatable, Identifiable {
    var stage: PipelineStage
    var state: StageState
    /// Wall-clock seconds the stage took, once it has finished.
    var elapsed: Double?

    var id: String { stage.rawValue }

    init(stage: PipelineStage, state: StageState = .pending, elapsed: Double? = nil) {
        self.stage = stage
        self.state = state
        self.elapsed = elapsed
    }

    /// "0:42" / "0.4s" — compact enough for the inspector's right margin.
    var elapsedText: String? {
        guard let elapsed else { return nil }
        if elapsed < 10 { return String(format: "%.1fs", elapsed) }
        let total = Int(elapsed.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Report

/// The full checklist for one job. Always holds every stage, in order.
nonisolated struct StageReport: Codable, Sendable, Equatable {
    private(set) var records: [StageRecord]

    init() {
        records = PipelineStage.allCases.map { StageRecord(stage: $0) }
    }

    init(records: [StageRecord]) {
        // Normalise: keep declared order and fill in any stage the stored file lacks.
        self.records = PipelineStage.allCases.map { stage in
            records.first(where: { $0.stage == stage }) ?? StageRecord(stage: stage)
        }
    }

    subscript(stage: PipelineStage) -> StageRecord {
        get { records.first(where: { $0.stage == stage }) ?? StageRecord(stage: stage) }
        set {
            if let idx = records.firstIndex(where: { $0.stage == stage }) {
                records[idx] = newValue
            } else {
                records.append(newValue)
            }
        }
    }

    mutating func set(_ stage: PipelineStage, _ state: StageState, elapsed: Double? = nil) {
        var record = self[stage]
        record.state = state
        if let elapsed { record.elapsed = elapsed }
        self[stage] = record
    }

    /// Clears a stage back to pending, timing included. `set(_:_:elapsed: nil)`
    /// cannot express "no duration", so a reset stage kept the previous run's.
    mutating func clear(_ stage: PipelineStage) {
        self[stage] = StageRecord(stage: stage)
    }

    /// Marks every stage that has not finished as pending — used when a run restarts.
    mutating func resetUnfinished() {
        for idx in records.indices where !records[idx].state.isTerminal {
            records[idx] = StageRecord(stage: records[idx].stage)
        }
    }

    mutating func reset(from stage: PipelineStage) {
        guard let start = PipelineStage.allCases.firstIndex(of: stage) else { return }
        for stageToReset in PipelineStage.allCases[start...] {
            clear(stageToReset)
        }
    }

    var runningStage: PipelineStage? {
        records.first(where: { $0.state == .running })?.stage
    }

    var firstFailure: StageRecord? {
        records.first(where: { $0.state.isFailure })
    }

    var warnings: [(stage: PipelineStage, message: String)] {
        records.compactMap { record in
            guard case .warning(let message) = record.state else { return nil }
            return (record.stage, message)
        }
    }

    var skipped: [(stage: PipelineStage, message: String)] {
        records.compactMap { record in
            guard case .skipped(let message) = record.state else { return nil }
            return (record.stage, message)
        }
    }

    /// True once every stage has reached a terminal state.
    var isFinished: Bool { records.allSatisfy { $0.state.isTerminal } }

    var completedCount: Int {
        records.filter { if case .done = $0.state { return true } else { return false } }.count
    }
}
