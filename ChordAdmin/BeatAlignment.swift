import CoreFoundation
import Foundation

extension JobManager {
    /// Number of detected beats before the first complete bar. A phase proposal
    /// is usable only when the whole returned track agrees with the requested
    /// metre. Older beat-only responses deliberately have no proposal.
    nonisolated static func inferredBeatAlignment(from data: Data, beatsPerBar: Int = 4) -> Int? {
        guard (2...4).contains(beatsPerBar),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let beats = json["beats"] as? [[String: Any]],
              beats.count >= beatsPerBar else { return nil }

        func integer(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let raw = number.doubleValue
            guard raw.isFinite, raw.rounded() == raw,
                  raw >= Double(Int32.min), raw <= Double(Int32.max) else { return nil }
            return Int(raw)
        }

        if let supplied = json["beatsPerBar"], integer(supplied) != beatsPerBar { return nil }

        var previousTime: Double?
        var previousPosition: Int?
        var firstDownbeat: Int?
        for (index, beat) in beats.enumerated() {
            guard let number = beat["time"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let time = number.doubleValue
            guard time.isFinite, time >= 0,
                  previousTime.map({ time > $0 }) ?? true,
                  let position = integer(beat["beatInBar"] ?? beat["position"]),
                  (1...beatsPerBar).contains(position) else { return nil }
            if let alias = beat["position"], integer(alias) != position { return nil }
            if let previousPosition, position != previousPosition % beatsPerBar + 1 { return nil }
            if position == 1, firstDownbeat == nil { firstDownbeat = index }
            previousPosition = position
            previousTime = time
        }

        guard let firstDownbeat, firstDownbeat < beatsPerBar,
              beats.count >= firstDownbeat + beatsPerBar else { return nil }
        if let suggested = json["suggestedPickupBeats"], integer(suggested) != firstDownbeat { return nil }
        if let supplied = json["firstDownbeatIndex"], integer(supplied) != firstDownbeat { return nil }
        return firstDownbeat
    }

    /// Saved alignment first; then a manual bar 1 re-anchored onto these beats;
    /// then the detected downbeat. Callers clear the saved offset whenever the
    /// beat track it counted into is replaced.
    nonisolated static func resolvedBeatOffset(job: AnalysisJob, beatData: Data) -> Int {
        let metre = max(1, job.beatsPerBarOverride ?? 4)
        if let saved = job.barAlignmentOffset { return max(0, min(metre - 1, saved)) }
        if let anchor = job.manualBarOneTime,
           let anchored = anchoredBeatOffset(barOneTime: anchor, beatData: beatData, beatsPerBar: metre) {
            return anchored
        }
        return inferredBeatAlignment(from: beatData, beatsPerBar: metre) ?? 0
    }

    /// The pickup that puts a bar line on the beat nearest `barOneTime`, or nil
    /// when no beat is closer than half a beat to it.
    nonisolated static func anchoredBeatOffset(barOneTime: Double, beatData: Data, beatsPerBar: Int) -> Int? {
        guard beatsPerBar >= 1,
              let json = try? JSONSerialization.jsonObject(with: beatData) as? [String: Any],
              let beats = json["beats"] as? [[String: Any]] else { return nil }
        let times = beats.compactMap { ($0["time"] as? NSNumber)?.doubleValue }
        guard times.count == beats.count, times.count >= 2,
              let nearest = times.indices.min(by: { abs(times[$0] - barOneTime) < abs(times[$1] - barOneTime) })
        else { return nil }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
        guard abs(times[nearest] - barOneTime) < gaps[gaps.count / 2] / 2 else { return nil }
        return nearest % beatsPerBar
    }

    /// Bar 1's start time in a saved beat grid.
    nonisolated static func barOneTime(gridPath: String?) -> Double? {
        guard let gridPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: gridPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["bars"] as? [[String: Any]])?.first else { return nil }
        return (first["start"] as? NSNumber)?.doubleValue
    }

    /// A new beat track invalidates the saved pickup count. Keep a manual
    /// choice by its bar 1 time; otherwise let the new detection decide.
    nonisolated static func resetAlignmentForNewBeats(_ job: inout AnalysisJob, previousBarOneTime: Double?) {
        if job.pickupChosenManually == true {
            guard let anchor = previousBarOneTime ?? job.manualBarOneTime else { return }
            job.manualBarOneTime = anchor
        } else {
            job.manualBarOneTime = nil
        }
        job.barAlignmentOffset = nil
    }
}
