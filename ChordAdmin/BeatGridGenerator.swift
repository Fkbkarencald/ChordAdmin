import Foundation

enum BeatGridGenerator {
    /// Infers beats per bar from a time-signature string such as `3/4` or `6/8`.
    /// Returns 4 when the signature is missing or unrecognised.
    static func beatsPerBar(fromTimeSignature signature: String?) -> Int {
        guard let signature, !signature.isEmpty else { return 4 }
        let parts = signature.split(separator: "/")
        guard let numerator = parts.first.flatMap({ Int($0) }), numerator > 0 else { return 4 }
        return numerator
    }

    /// Human-readable time signature label for a beats-per-bar grouping.
    static func timeSignatureLabel(forBeatsPerBar bpb: Int) -> String {
        switch max(1, bpb) {
        case 2: return "2/4"
        case 3: return "3/4"
        case 6: return "6/8"
        default: return "4/4"
        }
    }

    /// Reads an optional `timeSignature` field from beat.detection.json data.
    static func detectedTimeSignature(from beatData: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: beatData) as? [String: Any] else {
            return nil
        }
        return json["timeSignature"] as? String
    }

    /// Effective beats per bar: explicit override wins, then backend signature, then 4/4 default.
    static func effectiveBeatsPerBar(override: Int?, beatData: Data) -> Int {
        if let override { return max(1, override) }
        let detected = detectedTimeSignature(from: beatData)
        return beatsPerBar(fromTimeSignature: detected)
    }

    /// Generates a beat grid from beat.detection.json data.
    /// Returns (gridPayload, barCount) — gridPayload is empty on parse failure.
    static func generateBeatGrid(
        from beatData: Data,
        bpm: Double?,
        barAlignmentOffset: Int = 0,
        beatsPerBar: Int = 4
    ) -> (payload: [String: Any], barCount: Int) {
        guard let json = try? JSONSerialization.jsonObject(with: beatData) as? [String: Any],
              let rawBeats = json["beats"] as? [[String: Any]] else {
            return ([:], 0)
        }

        let allBeatTimes = rawBeats.compactMap { $0["time"] as? Double }
        let bpb = max(1, beatsPerBar)
        let offset = max(0, min(bpb - 1, barAlignmentOffset))
        var warnings: [String] = []

        if allBeatTimes.count < bpb {
            warnings.append("Not enough beats for a complete bar.")
        }

        let pickupTimes = offset > 0 ? Array(allBeatTimes.prefix(offset)) : []
        let barBeatTimes = Array(allBeatTimes.dropFirst(offset))

        let pickupBeats: [[String: Any]] = pickupTimes.enumerated().map { idx, t in
            ["beat": idx + 1, "time": jsonDecimal(t, 3)]
        }

        var bars: [[String: Any]] = []
        var i = 0
        while i < barBeatTimes.count {
            let slice = barBeatTimes[i ..< min(i + bpb, barBeatTimes.count)]
            let barBeats = Array(slice)
            let barStartRaw = barBeats[0]
            let nextBarStartRaw: Double? = (i + bpb < barBeatTimes.count) ? barBeatTimes[i + bpb] : nil
            let beatEntries: [[String: Any]] = barBeats.enumerated().map { idx, t in
                ["beat": idx + 1, "time": jsonDecimal(t, 3)]
            }
            let barEndRaw: Double = nextBarStartRaw ?? (barBeats.last ?? barStartRaw)
            bars.append([
                "bar": i / bpb + 1,
                "start": jsonDecimal(barStartRaw, 3),
                "end": jsonDecimal(barEndRaw, 3),
                "beats": beatEntries,
            ])
            i += bpb
        }

        let timeSig = timeSignatureLabel(forBeatsPerBar: bpb)
        let bpmJson: Any = bpm.map { jsonDecimal($0, 2) as NSObject } ?? NSNull()
        let payload: [String: Any] = [
            "bpm": bpmJson,
            "beatCount": allBeatTimes.count,
            "estimatedTimeSignature": timeSig,
            "beatsPerBar": bpb,
            "barAlignmentOffset": offset,
            "pickupBeats": pickupBeats,
            "bars": bars,
            "warnings": warnings,
        ]
        return (payload, bars.count)
    }

    private static func jsonDecimal(_ v: Double, _ places: Int) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.*f", places, v))
    }
}
