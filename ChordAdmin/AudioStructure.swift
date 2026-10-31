import Foundation

extension JobManager {
    /// Backend structure methods by response version. Version 2 adds repetition
    /// structure (Verse 1 -> Verse 2) to the version 1 acoustic novelty.
    nonisolated static let audioStructureMethods: [Int: String] = [
        1: "multiscale-audio-novelty",
        2: "bar-repetition-novelty",
    ]

    /// Optional on older/external backends. A capable backend's failures remain
    /// visible as a stage warning; chord repeats are still a usable fallback.
    nonisolated static func requestAudioStructure(wavURL: URL, performerData: Data) async throws -> Data? {
        guard let healthURL = URL(string: backendBaseUrl + "/health") else { return nil }
        var request = URLRequest(url: healthURL, timeoutInterval: 5)
        BackendConnection.shared.authorize(&request)
        let (health, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let healthJSON = try JSONSerialization.jsonObject(with: health) as? [String: Any],
              let capabilities = healthJSON["capabilities"] as? [String: Any],
              capabilities["audioStructure"] as? Bool == true else { return nil }
        guard let performer = try JSONSerialization.jsonObject(with: performerData) as? [String: Any],
              let bars = performer["bars"] as? [[String: Any]] else { return nil }
        let timings: [[String: Any]] = bars.compactMap { bar in
            guard let number = bar["bar"] as? Int,
                  let start = (bar["start"] as? NSNumber)?.doubleValue,
                  let end = (bar["end"] as? NSNumber)?.doubleValue else { return nil }
            return ["bar": number, "start": start, "end": end]
        }
        guard timings.count == bars.count, !timings.isEmpty,
              let grid = String(data: try JSONSerialization.data(withJSONObject: timings), encoding: .utf8) else { return nil }
        return try await postAudioFile(to: backendBaseUrl + "/api/detect-structure", fileURL: wavURL,
                                       params: ["bars": grid])
    }

    /// Boundary *times* are mapped to the current chart after a pickup edit.
    /// Retaining old bar numbers here would move every suggestion by a bar.
    nonisolated static func addingAudioBoundaries(_ audioData: Data, to candidates: [String: Any],
                                                 performerData: Data) -> [String: Any]? {
        guard let audio = try? JSONSerialization.jsonObject(with: audioData) as? [String: Any],
              audio["status"] as? String == "success",
              let version = audio["version"] as? Int, let method = audio["method"] as? String,
              audioStructureMethods[version] == method,
              let boundaries = audio["boundaries"] as? [[String: Any]], !boundaries.isEmpty,
              let performer = try? JSONSerialization.jsonObject(with: performerData) as? [String: Any],
              let rawBars = performer["bars"] as? [[String: Any]], !rawBars.isEmpty else { return nil }
        let bars: [(number: Int, start: Double, end: Double)] = rawBars.compactMap { bar in
            guard let number = bar["bar"] as? Int,
                  let start = (bar["start"] as? NSNumber)?.doubleValue, start.isFinite,
                  let end = (bar["end"] as? NSNumber)?.doubleValue, end.isFinite, end > start else { return nil }
            return (number, start, end)
        }
        guard bars.count == rawBars.count, let first = bars.first else { return nil }
        var mapped: [[String: Any]] = [["bar": first.number, "time": first.start, "score": 1.0]]
        // Version 2 letters repeated material alike (verse = B each time). The
        // chart's first section takes the letter in force at bar 1.
        func label(_ boundary: [String: Any]) -> String? {
            guard let label = boundary["label"] as? String, (1...3).contains(label.count),
                  label.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
            return label
        }
        let opening = boundaries.last { (($0["time"] as? NSNumber)?.doubleValue ?? .infinity) <= first.start + 1e-3 }
            ?? boundaries.first
        // Role names ("Verse 2") come from the same response; plain text only.
        func name(_ boundary: [String: Any]) -> String? {
            guard let name = boundary["name"] as? String, (1...40).contains(name.count),
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }) else { return nil }
            return name
        }
        if let opening, let openingLabel = label(opening) { mapped[0]["label"] = openingLabel }
        if let opening, let openingName = name(opening) { mapped[0]["name"] = openingName }
        var previousTime = -Double.infinity
        for boundary in boundaries {
            guard let time = (boundary["time"] as? NSNumber)?.doubleValue, time.isFinite, time >= 0,
                  time > previousTime,
                  let score = (boundary["score"] as? NSNumber)?.doubleValue,
                  score.isFinite, (0...1).contains(score) else { return nil }
            previousTime = time
            guard time > first.start,
                  let nearest = bars.min(by: { abs($0.start - time) < abs($1.start - time) }),
                  abs(nearest.start - time) <= (nearest.end - nearest.start) * 0.5,
                  nearest.number > (mapped.last?["bar"] as? Int ?? first.number) else { continue }
            var entry: [String: Any] = ["bar": nearest.number, "time": nearest.start, "score": score,
                                        "evidence": boundary["evidence"] as? [String] ?? []]
            if let boundaryLabel = label(boundary) { entry["label"] = boundaryLabel }
            if let boundaryName = name(boundary) { entry["name"] = boundaryName }
            mapped.append(entry)
        }
        var result = candidates
        result["audioBoundaries"] = mapped
        result["sectionMethod"] = method
        result["audioWarnings"] = audio["warnings"] as? [String] ?? []
        return result
    }

    nonisolated static func sectionsFromAudioBoundaries(_ payload: [String: Any], allBars: [Int]) -> [ChordSection]? {
        guard let method = payload["sectionMethod"] as? String,
              audioStructureMethods.values.contains(method),
              let raw = payload["audioBoundaries"] as? [[String: Any]], !raw.isEmpty,
              let first = allBars.first else { return nil }
        let starts = raw.compactMap { $0["bar"] as? Int }
        guard starts.count == raw.count, starts.first == first,
              starts == starts.sorted(), Set(starts).count == starts.count,
              starts.allSatisfy({ allBars.contains($0) }) else { return nil }
        // Shared letters only when every section has one; a partial set would
        // mix two naming schemes.
        let labels = raw.map { $0["label"] as? String }
        let shared = labels.allSatisfy { $0 != nil }
        let names = raw.map { $0["name"] as? String }
        let named = names.allSatisfy { $0 != nil }
        return starts.enumerated().compactMap { index, start in
            let next = index + 1 < starts.count ? starts[index + 1] : Int.max
            let bars = allBars.filter { $0 >= start && $0 < next }
            guard let end = bars.last else { return nil }
            let label = shared ? labels[index]! : index < 26 ? String(UnicodeScalar(65 + index)!) : String(index + 1)
            return ChordSection(id: "section-\(index + 1)", name: named ? names[index]! : "Section \(label)",
                                startBar: start, endBar: end, bars: bars)
        }
    }
}
