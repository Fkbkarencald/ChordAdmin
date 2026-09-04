import SwiftUI

// MARK: - Inspector

enum InspectorTab: String, CaseIterable, Identifiable {
    case bar, tuning, analysis, info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bar:      return "Bar"
        case .tuning:   return "Tuning"
        case .analysis: return "Analysis"
        case .info:     return "Info"
        }
    }
}

// MARK: - Tuning draft

/// Pending beat/bar settings while the user is trying options.
///
/// Nothing is recomputed on disk until Apply: the chart shows a live preview
/// built in memory, which replaces the old loop of clicking an offset button
/// and waiting for a full chart regeneration to find out what it did.
struct TuningDraft: Equatable {
    /// What the user actually asked for. The pickers read `offset`, which is
    /// this clamped into the current metre, so widening the metre again restores
    /// the choice instead of having silently lost it.
    private var requestedOffset: Int = 0
    var offset: Int {
        get { min(requestedOffset, max(0, beatsPerBar - 1)) }
        set { requestedOffset = newValue }
    }
    var beatsPerBar: Int = 4
    var halved: Bool = false
    var manualBpmText: String = ""

    /// The values currently written to the job, for comparison.
    var appliedOffset: Int = 0
    var appliedBeatsPerBar: Int = 4
    var appliedHalved: Bool = false
    var appliedManualBpm: Double?

    var manualBpm: Double? {
        let trimmed = manualBpmText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed), value > 10, value < 500 else { return nil }
        return value
    }

    /// The field holds something that is not a usable BPM (out of range, or not
    /// a number). Applying in that state would silently clear an existing
    /// override instead of doing what the user typed.
    var hasInvalidManualBpm: Bool {
        let trimmed = manualBpmText.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && manualBpm == nil
    }

    var isDirty: Bool {
        offset != appliedOffset
            || beatsPerBar != appliedBeatsPerBar
            || halved != appliedHalved
            || manualBpm != appliedManualBpm
    }

    static func from(job: AnalysisJob?) -> TuningDraft {
        guard let job else { return TuningDraft() }
        let offset = job.barAlignmentOffset ?? 0
        let beatsPerBar = job.beatsPerBarOverride ?? 4
        let halved = job.tempoHalved ?? false
        let text = job.manualBpm.map { String(format: "%.0f", $0) } ?? ""
        var draft = TuningDraft()
        draft.beatsPerBar = beatsPerBar
        draft.offset = offset
        draft.halved = halved
        draft.manualBpmText = text
        draft.appliedOffset = offset
        draft.appliedBeatsPerBar = beatsPerBar
        draft.appliedHalved = halved
        draft.appliedManualBpm = job.manualBpm
        // The field shows a whole number, so compare against what that text
        // actually parses to — otherwise a stored 136.4 reads as an unapplied
        // edit the moment the song opens.
        draft.appliedManualBpm = draft.manualBpm
        return draft
    }

    mutating func markApplied() {
        appliedOffset = offset
        appliedBeatsPerBar = beatsPerBar
        appliedHalved = halved
        appliedManualBpm = manualBpm
    }

    mutating func revert() {
        offset = appliedOffset
        beatsPerBar = appliedBeatsPerBar
        halved = appliedHalved
        manualBpmText = appliedManualBpm.map { String(format: "%.0f", $0) } ?? ""
    }
}

// MARK: - Formatting

enum Format {
    /// "a, b and c" — for sentences that name a variable number of things.
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0:  return "nothing"
        case 1:  return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// "1:23.4" — the transport clock.
    static func time(_ seconds: Double, showTenths: Bool = true) -> String {
        guard seconds.isFinite, seconds >= 0 else { return showTenths ? "0:00.0" : "0:00" }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return showTenths
            ? String(format: "%d:%04.1f", minutes, remainder)
            : String(format: "%d:%02d", minutes, Int(remainder))
    }

    static func bpm(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }
}
