import Foundation
import CoreFoundation

/// Validate the complete chart before it is allowed into a canonical song.
/// A nonempty sections array alone does not prove its nested bars are usable.
nonisolated enum SongImportPayload {
    enum ValidationError: LocalizedError {
        case invalidChart, invalidTempo, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidChart: "The translated chart does not match TheStageBee's song format. Check the backend and retry translation."
            case .invalidTempo: "The translated tempo must be a number between 1 and 1000 BPM. Check the analysis and retry translation."
            case .tooLarge: "This translated chart is too large for a song record. Reduce the chart before publishing."
            }
        }
    }
    static func data(sections: Any, tempo: Any) throws -> Data {
        guard let bpm = tempo as? NSNumber, CFGetTypeID(bpm) != CFBooleanGetTypeID(),
              bpm.doubleValue.isFinite, bpm.intValue > 0, bpm.intValue <= 1000 else { throw ValidationError.invalidTempo }
        guard let sections = sections as? [[String: Any]], !sections.isEmpty else {
            throw ValidationError.invalidChart
        }
        for section in sections {
            guard let title = section["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let lines = section["lines"] as? [[String: Any]], !lines.isEmpty else {
                throw ValidationError.invalidChart
            }
            for line in lines {
                guard let bars = line["bars"] as? [[String: Any]], !bars.isEmpty else {
                    throw ValidationError.invalidChart
                }
                for bar in bars {
                    guard let chords = bar["chords"] as? [[String: Any]], !chords.isEmpty,
                          chords.allSatisfy({ ($0["chord"] as? String)?.isEmpty == false }),
                          let metre = bar["timeSignature"] as? [Int], metre.count == 2,
                          metre.allSatisfy({ $0 > 0 && $0 <= 64 }),
                          let structure = bar["structure"] as? String, !structure.isEmpty else {
                        throw ValidationError.invalidChart
                    }
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["sections": sections, "tempo": bpm.intValue], options: [.sortedKeys])
        guard data.count <= 800_000 else { throw ValidationError.tooLarge }
        return data
    }

    static func timeSignature(_ payload: [String: Any]) -> [Int] {
        let sections = payload["sections"] as? [[String: Any]]
        let lines = sections?.first?["lines"] as? [[String: Any]]
        let bars = lines?.first?["bars"] as? [[String: Any]]
        return bars?.first?["timeSignature"] as? [Int] ?? [4, 4]
    }

    static func validate(_ data: Data) throws -> [String: Any] {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(payload.keys) == Set(["sections", "tempo"]),
              let sections = payload["sections"], let tempo = payload["tempo"] else {
            throw ValidationError.invalidChart
        }
        let validated = try Self.data(sections: sections, tempo: tempo)
        return try JSONSerialization.jsonObject(with: validated) as! [String: Any]
    }
}
