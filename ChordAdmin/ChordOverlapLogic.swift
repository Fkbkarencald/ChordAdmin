import Foundation

struct ChordOverlapResult: Equatable {
    var displayChord: String
    var start: Double
    var end: Double
    var overlapSeconds: Double
}

/// Chord-to-bar overlap calculations used when building chord chart drafts.
enum ChordOverlapLogic {
    /// Returns chords that overlap `barStart...barEnd`, sorted by overlap duration descending.
    static func overlappingChords(
        barStart: Double,
        barEnd: Double,
        chords: [[String: Any]]
    ) -> [ChordOverlapResult] {
        var results: [ChordOverlapResult] = []

        for chord in chords {
            guard let chordStart = chord["start"] as? Double,
                  let chordEnd = chord["end"] as? Double,
                  let displayChord = chord["displayChord"] as? String else { continue }

            let overlapSecs = min(barEnd, chordEnd) - max(barStart, chordStart)
            guard overlapSecs > 0 else { continue }

            results.append(ChordOverlapResult(
                displayChord: displayChord,
                start: chordStart,
                end: chordEnd,
                overlapSeconds: overlapSecs
            ))
        }

        return results.sorted { $0.overlapSeconds > $1.overlapSeconds }
    }

    /// Primary chord is the one with the greatest overlap in the bar.
    static func primaryChord(from overlaps: [ChordOverlapResult]) -> String? {
        overlaps.max(by: { $0.overlapSeconds < $1.overlapSeconds })?.displayChord
    }
}
