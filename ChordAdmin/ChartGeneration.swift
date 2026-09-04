import Foundation

// Pure, backend-independent transforms: parsing tool output and turning beat and
// chord data into the grid, charts and section candidates. Split out of
// JobManager so the orchestrator stays readable; behaviour is unchanged.
extension JobManager {

    // MARK: - Audio health parsing

    nonisolated struct SilenceRegion {
        var start: Double
        var end: Double
        var duration: Double
    }

    /// Parses `mean_volume` and `max_volume` from ffmpeg volumedetect stderr.
    nonisolated static func parseVolumeDetect(_ output: String) -> (mean: Double?, max: Double?) {
        var mean: Double? = nil
        var max: Double?  = nil
        for line in output.components(separatedBy: "\n") {
            if let r = line.range(of: "mean_volume: ") {
                let rest = String(line[r.upperBound...])
                mean = Double(rest.components(separatedBy: " ").first ?? "")
            }
            if let r = line.range(of: "max_volume: ") {
                let rest = String(line[r.upperBound...])
                max = Double(rest.components(separatedBy: " ").first ?? "")
            }
        }
        return (mean, max)
    }

    /// Parses silence_start / silence_end / silence_duration lines from ffmpeg silencedetect stderr.
    nonisolated static func parseSilenceDetect(_ output: String) -> [SilenceRegion] {
        var regions: [SilenceRegion] = []
        var pendingStart: Double? = nil
        for line in output.components(separatedBy: "\n") {
            if let r = line.range(of: "silence_start: ") {
                let rest = String(line[r.upperBound...])
                pendingStart = Double(rest.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if line.contains("silence_end:"), let r = line.range(of: "silence_end: ") {
                let endAndRest = String(line[r.upperBound...])
                let parts = endAndRest.components(separatedBy: " | silence_duration: ")
                guard let endVal = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                      let durStr = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                      let durVal = Double(durStr) else { continue }
                let start = pendingStart ?? (endVal - durVal)
                regions.append(SilenceRegion(start: start, end: endVal, duration: durVal))
                pendingStart = nil
            }
        }
        return regions
    }

    // MARK: - Section candidate detection (performer-chart based)

    nonisolated static func detectSectionCandidates(
        performerData: Data,
        performerPath: String,
        draftPath: String
    ) -> (payload: [String: Any], candidateCount: Int, preview: [SectionCandidate]) {

        guard let json    = try? JSONSerialization.jsonObject(with: performerData) as? [String: Any],
              let rawBars = json["bars"] as? [[String: Any]] else {
            return ([:], 0, [])
        }

        let bpmDouble: Double? = (json["bpm"] as? NSNumber).map { $0.doubleValue }
        let timeSignature = json["timeSignature"] as? String ?? "4/4"
        var warnings: [String] = []

        // Build bar-signature array from filtered/deduped chords
        var barNumbers:  [Int]    = []
        var signatures:  [String] = []

        for bar in rawBars {
            guard let barNum = bar["bar"] as? Int else { continue }
            let primaryChord = bar["primaryChord"] as? String
            let rawChords    = bar["chords"] as? [[String: Any]] ?? []

            let filtered = rawChords
                .compactMap { c -> (chord: String, start: Double)? in
                    guard let dc = c["displayChord"]   as? String,
                          let cs = (c["start"]          as? NSNumber).map({ $0.doubleValue }),
                          let ov = (c["overlapSeconds"] as? NSNumber).map({ $0.doubleValue }),
                          ov >= 0.25 else { return nil }
                    return (dc, cs)
                }
                .sorted { $0.start < $1.start }

            // Remove adjacent duplicates
            var deduped: [String] = []
            for item in filtered {
                if deduped.last != item.chord { deduped.append(item.chord) }
            }

            let sig: String
            if !deduped.isEmpty {
                sig = deduped.joined(separator: "-")
            } else {
                sig = primaryChord ?? "N.C."
            }
            barNumbers.append(barNum)
            signatures.append(sig)
        }

        let totalBarCount = barNumbers.count
        guard totalBarCount >= 4 else {
            warnings.append("Not enough bars for section detection (need ≥ 4, got \(totalBarCount)).")
            let payload: [String: Any] = [
                "source":        ["chordChartPerformerPath": performerPath, "chordChartDraftPath": draftPath],
                "bpm":           bpmDouble.map { jsonDecimal($0, 2) as NSObject } ?? NSNull(),
                "timeSignature": timeSignature,
                "barCount":      totalBarCount,
                "candidates":    [[String: Any]](),
                "warnings":      warnings,
            ]
            return (payload, 0, [])
        }

        // Collect all occurrences of each unique window
        struct Occurrence {
            let firstIndex: Int    // 0-based index into signatures[]
            let windowSize: Int
            var startIndices: [Int]  // all 0-based start indices
        }

        var occurrenceMap:  [String: Occurrence] = [:]
        var insertionOrder: [String]             = []

        for windowSize in [4, 8] {
            guard totalBarCount >= windowSize else { continue }
            for startIndex in 0...(totalBarCount - windowSize) {
                let slice = Array(signatures[startIndex..<(startIndex + windowSize)])
                let key   = "\(windowSize):\(slice.joined(separator: ","))"
                if var existing = occurrenceMap[key] {
                    existing.startIndices.append(startIndex)
                    occurrenceMap[key] = existing
                } else {
                    occurrenceMap[key] = Occurrence(firstIndex: startIndex, windowSize: windowSize, startIndices: [startIndex])
                    insertionOrder.append(key)
                }
            }
        }

        // Keep only repeated sequences
        let repeatedKeys = insertionOrder.filter { occurrenceMap[$0]!.startIndices.count > 1 }

        // Sort: 8-bar first, then higher matchCount, then earlier firstIndex
        let sortedKeys = repeatedKeys.sorted { a, b in
            let oa = occurrenceMap[a]!, ob = occurrenceMap[b]!
            if oa.windowSize != ob.windowSize { return oa.windowSize > ob.windowSize }
            if oa.startIndices.count != ob.startIndices.count { return oa.startIndices.count > ob.startIndices.count }
            return oa.firstIndex < ob.firstIndex
        }

        // Every accepted candidate's first-occurrence range. A song built on one
        // repeating loop yields that loop at every rotation — XYZW-XYZW,
        // YZWX-YZWX and so on — each a "repeat" in its own right, so the panel
        // announced four repeating passages where there is one, and the preview
        // showed the same phrase shifted a bar at a time.
        var acceptedIndexRanges: [(start: Int, end: Int)] = []

        let alphabet  = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var labelIndex = 0
        var candidates:     [SectionCandidate]  = []
        var candidatesJSON: [[String: Any]]      = []

        for key in sortedKeys {
            guard let occ = occurrenceMap[key], labelIndex < alphabet.count else { continue }

            // Overlapping an already-accepted passage means it is the same
            // music seen from a different starting bar, not a new section.
            let occEnd = occ.firstIndex + occ.windowSize
            let overlaps = acceptedIndexRanges.contains { range in
                occ.firstIndex < range.end && occEnd > range.start
            }
            if overlaps { continue }

            acceptedIndexRanges.append((start: occ.firstIndex, end: occEnd))

            let startBar    = barNumbers[occ.firstIndex]
            let endBarIndex = min(occ.firstIndex + occ.windowSize - 1, barNumbers.count - 1)
            let endBar      = barNumbers[endBarIndex]
            let sliceSigs   = Array(signatures[occ.firstIndex..<(occ.firstIndex + occ.windowSize)])

            // Build all matches from every start index
            let matchCount = occ.startIndices.count
            let matches: [SectionCandidateMatch] = occ.startIndices.map { idx in
                let mEnd = barNumbers[min(idx + occ.windowSize - 1, barNumbers.count - 1)]
                return SectionCandidateMatch(startBar: barNumbers[idx], endBar: mEnd)
            }
            let matchesJSON: [[String: Any]] = matches.map { ["startBar": $0.startBar, "endBar": $0.endBar] }

            let label = String(alphabet[alphabet.index(alphabet.startIndex, offsetBy: labelIndex)])
            labelIndex += 1

            candidates.append(SectionCandidate(
                label: label, startBar: startBar, endBar: endBar,
                barCount: occ.windowSize, barSignatures: sliceSigs,
                matchCount: matchCount, matches: matches
            ))
            candidatesJSON.append([
                "label":         label,
                "startBar":      startBar,
                "endBar":        endBar,
                "barCount":      occ.windowSize,
                "barSignatures": sliceSigs,
                "matchCount":    matchCount,
                "matches":       matchesJSON,
            ])
        }

        let payload: [String: Any] = [
            "source": ["chordChartPerformerPath": performerPath, "chordChartDraftPath": draftPath],
            "bpm":           bpmDouble.map { jsonDecimal($0, 2) as NSObject } ?? NSNull(),
            "timeSignature": timeSignature,
            "barCount":      totalBarCount,
            "candidates":    candidatesJSON,
            "warnings":      warnings,
        ]
        return (payload, candidates.count, Array(candidates.prefix(5)))
    }

    // MARK: - Performer chart generation (draft-based, multi-chord bars)

    nonisolated static func generatePerformerChart(
        draftData:  Data,
        configData: Data,
        draftPath:  String,
        configPath: String
    ) -> (payload: [String: Any], barCount: Int, preview: [PerformerChartBarEntry]) {

        guard let draftJson  = try? JSONSerialization.jsonObject(with: draftData)  as? [String: Any],
              let configJson = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let rawBars    = draftJson["bars"] as? [[String: Any]] else {
            return ([:], 0, [])
        }

        let bpmDouble: Double?    = (draftJson["bpm"] as? NSNumber).map { $0.doubleValue }
        let timeSignature          = draftJson["timeSignature"] as? String ?? "4/4"
        let chartStartTime: Double = (configJson["chartStartTime"] as? NSNumber).map { $0.doubleValue } ?? 0.0
        let includePreIntro        = configJson["includePreIntro"] as? Bool ?? false
        let barMode                = configJson["chartStartBarMode"] as? String ?? "renumberFromOne"

        var preIntroJson: [[String: Any]]        = []
        var mainJson:     [[String: Any]]        = []
        var preview:      [PerformerChartBarEntry] = []
        var mainCounter   = 0

        for bar in rawBars {
            guard let sourceBar = bar["bar"]   as? Int,
                  let barStart  = (bar["start"] as? NSNumber).map({ $0.doubleValue }),
                  let barEnd    = (bar["end"]   as? NSNumber).map({ $0.doubleValue }) else { continue }

            let primaryChord = bar["primaryChord"] as? String
            let rawChords    = bar["chords"] as? [[String: Any]] ?? []

            // Filter (≥ 0.25 s overlap), sort by start, remove adjacent duplicates
            let filtered = rawChords
                .compactMap { c -> (chord: String, start: Double, end: Double, overlap: Double)? in
                    guard let dc = c["displayChord"]   as? String,
                          let cs = (c["start"]          as? NSNumber).map({ $0.doubleValue }),
                          let ce = (c["end"]            as? NSNumber).map({ $0.doubleValue }),
                          let ov = (c["overlapSeconds"] as? NSNumber).map({ $0.doubleValue }),
                          ov >= 0.25 else { return nil }
                    return (dc, cs, ce, ov)
                }
                .sorted { $0.start < $1.start }

            var deduped: [(chord: String, start: Double, end: Double, overlap: Double)] = []
            for item in filtered {
                if deduped.last?.chord != item.chord { deduped.append(item) }
            }

            // Best primary: use existing primaryChord, fall back to highest-overlap deduped, then N.C.
            let effectivePrimary: String = primaryChord
                ?? deduped.max(by: { $0.overlap < $1.overlap })?.chord
                ?? "N.C."

            // If no chord survives filtering, represent the bar with a single primaryChord entry
            let chordsJson: [[String: Any]]
            let chordEntries: [ChordChartChordEntry]
            if deduped.isEmpty {
                chordsJson = [[
                    "displayChord":   effectivePrimary,
                    "start":          jsonDecimal(barStart, 3),
                    "end":            jsonDecimal(barEnd,   3),
                    "overlapSeconds": jsonDecimal(max(0, barEnd - barStart), 3),
                ]]
                chordEntries = [ChordChartChordEntry(
                    displayChord: effectivePrimary,
                    start: round3(barStart), end: round3(barEnd),
                    overlapSeconds: round3(max(0, barEnd - barStart))
                )]
            } else {
                chordsJson = deduped.map { c in [
                    "displayChord":   c.chord,
                    "start":          jsonDecimal(c.start,   3),
                    "end":            jsonDecimal(c.end,     3),
                    "overlapSeconds": jsonDecimal(c.overlap, 3),
                ] }
                chordEntries = deduped.map { c in
                    ChordChartChordEntry(displayChord: c.chord,
                                        start:   round3(c.start), end: round3(c.end),
                                        overlapSeconds: round3(c.overlap))
                }
            }

            if barStart < chartStartTime && !includePreIntro {
                preIntroJson.append([
                    "sourceBar":    sourceBar,
                    "start":        jsonDecimal(barStart, 3),
                    "end":          jsonDecimal(barEnd,   3),
                    "primaryChord": effectivePrimary,
                    "chords":       chordsJson,
                ])
            } else {
                mainCounter += 1
                let displayBar = barMode == "renumberFromOne" ? mainCounter : sourceBar
                mainJson.append([
                    "bar":          displayBar,
                    "sourceBar":    sourceBar,
                    "start":        jsonDecimal(barStart, 3),
                    "end":          jsonDecimal(barEnd,   3),
                    "primaryChord": effectivePrimary,
                    "chords":       chordsJson,
                ])
                if preview.count < 16 {
                    preview.append(PerformerChartBarEntry(
                        bar: displayBar, sourceBar: sourceBar,
                        start: round3(barStart), end: round3(barEnd),
                        primaryChord: effectivePrimary, chords: chordEntries
                    ))
                }
            }
        }

        let bpmJson: Any = bpmDouble.map { jsonDecimal($0, 2) as NSObject } ?? NSNull()
        let payload: [String: Any] = [
            "source": [
                "chordChartDraftPath": draftPath,
                "chartConfigPath":     configPath,
            ] as [String: Any],
            "bpm":             bpmJson,
            "timeSignature":   timeSignature,
            "chartStartTime":  jsonDecimal(chartStartTime, 3),
            "includePreIntro": includePreIntro,
            "preIntro":        preIntroJson,
            "bars":            mainJson,
            "warnings":        [String](),
        ]
        return (payload, mainJson.count, preview)
    }

    // MARK: - Initial sections generation (from candidates + performer bar list)

    nonisolated static func generateInitialSections(
        performerData: Data,
        candidatesPayload: [String: Any],
        performerPath: String,
        candidatesPath: String
    ) -> (payload: [String: Any], sectionCount: Int) {

        guard let perfJson  = try? JSONSerialization.jsonObject(with: performerData) as? [String: Any],
              let rawBars   = perfJson["bars"] as? [[String: Any]] else { return ([:], 0) }

        let allBars = rawBars.compactMap { $0["bar"] as? Int }.sorted()
        guard !allBars.isEmpty else { return ([:], 0) }

        // Parse candidates from payload
        let rawCands = candidatesPayload["candidates"] as? [[String: Any]] ?? []
        struct Cand { var label: String; var startBar: Int; var endBar: Int
                      var barCount: Int; var matchCount: Int
                      /// Every occurrence, not just the first.
                      var matches: [(start: Int, end: Int)] }
        let candidates: [Cand] = rawCands.compactMap { c in
            guard let label = c["label"]      as? String,
                  let sb    = c["startBar"]   as? Int,
                  let eb    = c["endBar"]     as? Int,
                  let bc    = c["barCount"]   as? Int,
                  let mc    = c["matchCount"] as? Int else { return nil }
            let matches: [(start: Int, end: Int)] = (c["matches"] as? [[String: Any]] ?? [])
                .compactMap { m in
                    guard let ms = m["startBar"] as? Int, let me = m["endBar"] as? Int else { return nil }
                    return (start: ms, end: me)
                }
            return Cand(label: label, startBar: sb, endBar: eb, barCount: bc,
                        matchCount: mc, matches: matches.isEmpty ? [(sb, eb)] : matches)
        }

        // Select non-overlapping candidates (prefer 8-bar, then higher matchCount)
        let sorted = candidates.sorted { a, b in
            if a.barCount != b.barCount   { return a.barCount   > b.barCount   }
            if a.matchCount != b.matchCount { return a.matchCount > b.matchCount }
            return a.startBar < b.startBar
        }
        var accepted: [Cand] = []
        for cand in sorted {
            let overlaps = accepted.contains { a in
                cand.startBar <= a.endBar && cand.endBar >= a.startBar
            }
            if !overlaps { accepted.append(cand) }
        }
        let ordered = accepted.sorted { $0.startBar < $1.startBar }

        // Every occurrence of an accepted passage becomes its own section, with
        // the repeats sharing the first one's label. Using only the first
        // occurrence left everything after it — usually the whole back half of
        // the song — as one undifferentiated trailing section to split by hand.
        struct Placed { var start: Int; var end: Int; var label: String }
        var placed: [Placed] = []
        for cand in ordered {
            for match in cand.matches {
                let bars = allBars.filter { $0 >= match.start && $0 <= match.end }
                guard let first = bars.first, let last = bars.last else { continue }
                let clashes = placed.contains { first <= $0.end && last >= $0.start }
                if clashes { continue }
                placed.append(Placed(start: first, end: last, label: cand.label))
            }
        }
        placed.sort { $0.start < $1.start }

        // Build section ranges from allBars + the placed passages
        struct SecRange { var start: Int; var end: Int; var label: String? }
        var ranges: [SecRange] = []
        var cursor = allBars.first!
        for passage in placed {
            let gapBars = allBars.filter { $0 >= cursor && $0 < passage.start }
            if !gapBars.isEmpty {
                ranges.append(SecRange(start: gapBars.first!, end: gapBars.last!, label: nil))
            }
            ranges.append(SecRange(start: passage.start, end: passage.end, label: passage.label))
            cursor = allBars.first(where: { $0 > passage.end }) ?? (allBars.last! + 1)
        }
        let tailBars = allBars.filter { $0 >= cursor }
        if !tailBars.isEmpty {
            ranges.append(SecRange(start: tailBars.first!, end: tailBars.last!, label: nil))
        }
        if ranges.isEmpty {
            ranges = [SecRange(start: allBars.first!, end: allBars.last!, label: nil)]
        }

        // Assign names. A passage that recurs keeps the same name every time it
        // comes round, which is the whole point of detecting the repeat.
        let letters     = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var letterIndex = 0
        var nameForLabel: [String: String] = [:]
        var sectionsJson: [[String: Any]] = []
        for (i, range) in ranges.enumerated() {
            let isFirst  = (i == 0)
            let isLast   = (i == ranges.count - 1)
            let bars     = allBars.filter { $0 >= range.start && $0 <= range.end }
            let barCount = bars.count
            let name: String
            if let label = range.label, let known = nameForLabel[label] {
                // Already named where it first came round.
                name = known
            } else if let label = range.label {
                // A recurring passage is never "Intro" or "Outro" however it is
                // placed — those names promise music that happens once.
                if letterIndex < letters.count {
                    let letter = String(letters[letters.index(letters.startIndex, offsetBy: letterIndex)])
                    name = "Section \(letter)"
                } else {
                    name = "Section \(letterIndex + 1)"
                }
                letterIndex += 1
                nameForLabel[label] = name
            } else if isFirst {
                name = "Intro"
            } else if isLast {
                name = barCount <= 4 ? "Outro" : "Ending"
            } else if letterIndex < letters.count {
                let letter = String(letters[letters.index(letters.startIndex, offsetBy: letterIndex)])
                name = "Section \(letter)"
                letterIndex += 1
            } else {
                name = "Section \(letterIndex + 1)"
                letterIndex += 1
            }
            sectionsJson.append([
                "id":       "section-\(i + 1)",
                "name":     name,
                "startBar": range.start,
                "endBar":   range.end,
                "bars":     bars,
            ])
        }

        let payload: [String: Any] = [
            "source": [
                "chordChartPerformerPath": performerPath,
                "sectionCandidatesPath":   candidatesPath,
            ] as [String: Any],
            "sections": sectionsJson,
        ]
        return (payload, sectionsJson.count)
    }

    // MARK: - Chord chart draft generation

    nonisolated static func generateChordChart(
        beatGridData: Data,
        chordCleanedData: Data,
        beatGridPath: String,
        chordCleanedPath: String
    ) -> (payload: [String: Any], barCount: Int, previewBars: [ChordChartBarEntry]) {
        guard let gridJson  = try? JSONSerialization.jsonObject(with: beatGridData)     as? [String: Any],
              let chordJson = try? JSONSerialization.jsonObject(with: chordCleanedData) as? [String: Any] else {
            return ([:], 0, [])
        }

        let rawBars       = gridJson["bars"]   as? [[String: Any]] ?? []
        let rawChords     = chordJson["chords"] as? [[String: Any]] ?? []
        let bpmDouble: Double? = (gridJson["bpm"] as? NSNumber).map { $0.doubleValue }
        let timeSignature = gridJson["estimatedTimeSignature"] as? String ?? "4/4"

        var warnings:   [String]               = []
        var chartBars:  [[String: Any]]        = []
        var previewBars: [ChordChartBarEntry]  = []

        for bar in rawBars {
            guard let barStart = bar["start"] as? Double,
                  let barEnd   = bar["end"]   as? Double,
                  let barNum   = bar["bar"]   as? Int else { continue }

            var overlapping:   [[String: Any]]          = []
            var previewChords: [ChordChartChordEntry]   = []
            var primaryChord: String? = nil
            var maxOverlap   = 0.0

            for chord in rawChords {
                guard let chordStart   = chord["start"]        as? Double,
                      let chordEnd     = chord["end"]          as? Double,
                      let displayChord = chord["displayChord"] as? String else { continue }

                let overlapSecs = min(barEnd, chordEnd) - max(barStart, chordStart)
                guard overlapSecs > 0 else { continue }

                overlapping.append([
                    "displayChord":   displayChord,
                    "start":          jsonDecimal(chordStart, 3),
                    "end":            jsonDecimal(chordEnd, 3),
                    "overlapSeconds": jsonDecimal(overlapSecs, 3),
                ])
                previewChords.append(ChordChartChordEntry(
                    displayChord:   displayChord,
                    start:          round3(chordStart),
                    end:            round3(chordEnd),
                    overlapSeconds: round3(overlapSecs)
                ))

                if overlapSecs > maxOverlap {
                    maxOverlap   = overlapSecs
                    primaryChord = displayChord
                }
            }

            if primaryChord == nil {
                warnings.append("Bar \(barNum) has no chord overlap")
            }

            let primaryChordValue: Any = primaryChord.map { $0 as Any } ?? NSNull()
            chartBars.append([
                "bar":          barNum,
                "start":        jsonDecimal(barStart, 3),
                "end":          jsonDecimal(barEnd, 3),
                "chords":       overlapping,
                "primaryChord": primaryChordValue,
            ])

            if previewBars.count < 8 {
                previewBars.append(ChordChartBarEntry(
                    bar:          barNum,
                    start:        round3(barStart),
                    end:          round3(barEnd),
                    primaryChord: primaryChord,
                    chords:       previewChords
                ))
            }
        }

        let payload: [String: Any] = [
            "source": [
                "beatGridPath":     beatGridPath,
                "chordCleanedPath": chordCleanedPath,
            ],
            "bpm":           bpmDouble.map { jsonDecimal($0, 2) as NSObject } ?? NSNull(),
            "timeSignature": timeSignature,
            "barCount":      chartBars.count,
            "bars":          chartBars,
            "warnings":      warnings,
        ]
        return (payload, chartBars.count, previewBars)
    }

    // MARK: - ffprobe output parsing

    nonisolated struct FFprobeResult {
        var duration: Double?
        var sampleRate: Int?
        var channels: Int?
        var codecName: String?
        var bitRate: Int?
        var fileSizeBytes: Int64?
    }

    nonisolated static func parseFFprobeOutput(_ data: Data) throws -> FFprobeResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JobError.metadataFailed("Could not parse ffprobe JSON")
        }
        var result = FFprobeResult()

        // First audio stream
        if let streams = root["streams"] as? [[String: Any]],
           let audioStream = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) {
            result.codecName  = audioStream["codec_name"] as? String
            result.channels   = audioStream["channels"] as? Int
            if let srStr = audioStream["sample_rate"] as? String { result.sampleRate = Int(srStr) }
            if let brStr = audioStream["bit_rate"] as? String    { result.bitRate    = Int(brStr) }
        }

        // Format block
        if let format = root["format"] as? [String: Any] {
            if let durStr  = format["duration"]  as? String { result.duration      = Double(durStr) }
            if let sizeStr = format["size"]       as? String { result.fileSizeBytes = Int64(sizeStr) }
            // Fall back to format bit_rate if stream didn't provide one
            if result.bitRate == nil, let brStr = format["bit_rate"] as? String { result.bitRate = Int(brStr) }
        }

        return result
    }
    /// Returns an `NSDecimalNumber` formatted to `places` decimal places.
    /// Use for all `Double` values in `[String: Any]` dicts written via `JSONSerialization`
    /// to prevent IEEE 754 artefacts (e.g. 0.86 serialising as 0.85999999999999999).
    nonisolated static func jsonDecimal(_ v: Double, _ places: Int) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.*f", places, v))
    }

    /// Rounds a Double to N decimal places for use in Swift `Codable` model values.
    /// (JSONEncoder uses Ryu/shortest-decimal and does not need NSDecimalNumber.)
    nonisolated static func round3(_ v: Double) -> Double {
        Double(String(format: "%.3f", v)) ?? v
    }

    /// Returns a modified copy of beat.detection.json data with every other beat removed
    /// and BPM halved — used when the detector fires at double the true tempo.
    nonisolated static func applyTempoHalving(to beatData: Data) -> (data: Data, bpm: Double?) {
        guard var json = try? JSONSerialization.jsonObject(with: beatData) as? [String: Any],
              let rawBeats = json["beats"] as? [[String: Any]] else {
            return (beatData, nil)
        }
        json["beats"] = rawBeats.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
        let halvedBpm: Double?
        if let v = json["bpm"] as? Double {
            halvedBpm = v / 2.0
            json["bpm"] = jsonDecimal(v / 2.0, 2)
        } else {
            halvedBpm = nil
        }
        let modData = (try? JSONSerialization.data(withJSONObject: json)) ?? beatData
        return (modData, halvedBpm)
    }

    nonisolated static func parseBeatResponse(_ data: Data) -> (bpm: Double?, beatCount: Int?, resolvedModel: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        let bpm: Double?
        if let v = json["bpm"] as? Double      { bpm = v }
        else if let v = json["bpm"] as? Int    { bpm = Double(v) }
        else                                    { bpm = nil }

        // The array wins over the declared count. They agree in practice, but
        // the grid is built from the array, so reporting anything else would
        // describe a chart that was never made.
        let beatCount: Int?
        if let beats = json["beats"] as? [Any]   { beatCount = beats.count }
        else if let v = json["beatCount"] as? Int { beatCount = v }
        else                                      { beatCount = nil }

        let resolvedModel = json["model"] as? String

        return (bpm, beatCount, resolvedModel)
    }

    /// Generates a 4/4 beat grid from beat.detection.json data.
    /// Returns (gridPayload, barCount) — gridPayload is empty on parse failure.
    nonisolated static func generateBeatGrid(
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
        let bpb          = max(1, beatsPerBar)
        let offset       = max(0, min(bpb - 1, barAlignmentOffset))
        var warnings: [String] = []

        if allBeatTimes.count < bpb {
            warnings.append("Not enough beats for a complete bar.")
        }

        // Pickup beats are those before the first full bar
        let pickupTimes = offset > 0 ? Array(allBeatTimes.prefix(offset)) : []
        let barBeatTimes = Array(allBeatTimes.dropFirst(offset))

        let pickupBeats: [[String: Any]] = pickupTimes.enumerated().map { idx, t in
            ["beat": idx + 1, "time": jsonDecimal(t, 3)]
        }

        // The final bar has no following downbeat to end at. Ending it on its
        // own last beat left it a beat short — and exactly zero seconds long
        // when a single beat was left over, so every chord failed the overlap
        // test and the bar rendered, and exported, as "N.C." with a chord
        // plainly sounding in it.
        let medianInterval: Double = {
            guard barBeatTimes.count > 1 else { return 0.5 }
            let gaps = zip(barBeatTimes.dropFirst(), barBeatTimes)
                .map { $0 - $1 }
                .filter { $0 > 0 }
                .sorted()
            guard !gaps.isEmpty else { return 0.5 }
            return gaps[gaps.count / 2]
        }()

        var bars: [[String: Any]] = []
        var i = 0
        while i < barBeatTimes.count {
            let slice    = barBeatTimes[i ..< min(i + bpb, barBeatTimes.count)]
            let barBeats = Array(slice)
            let barStartRaw = barBeats[0]
            let nextBarStartRaw: Double? = (i + bpb < barBeatTimes.count)
                ? barBeatTimes[i + bpb]
                : nil
            let beatEntries: [[String: Any]] = barBeats.enumerated().map { idx, t in
                ["beat": idx + 1, "time": jsonDecimal(t, 3)]
            }
            let barEndRaw: Double
            if let nextBarStartRaw {
                barEndRaw = nextBarStartRaw
            } else {
                // Carry the bar's own beat spacing one beat past its last beat.
                let last = barBeats.last ?? barStartRaw
                let spacing = barBeats.count > 1
                    ? (last - barStartRaw) / Double(barBeats.count - 1)
                    : medianInterval
                barEndRaw = last + max(spacing, 0.001)
            }
            bars.append([
                "bar":   i / bpb + 1,
                "start": jsonDecimal(barStartRaw, 3),
                "end":   jsonDecimal(barEndRaw, 3),
                "beats": beatEntries,
            ])
            i += bpb
        }

        let timeSig: String
        switch bpb {
        case 2: timeSig = "2/4"
        case 3: timeSig = "3/4"
        case 6: timeSig = "6/8"
        default: timeSig = "4/4"
        }

        let bpmJson: Any = bpm.map { jsonDecimal($0, 2) as NSObject } ?? NSNull()
        let payload: [String: Any] = [
            "bpm":                    bpmJson,
            "beatCount":              allBeatTimes.count,
            "estimatedTimeSignature": timeSig,
            "beatsPerBar":            bpb,
            "barAlignmentOffset":     offset,
            "pickupBeats":            pickupBeats,
            "bars":                   bars,
            "warnings":               warnings,
        ]
        return (payload, bars.count)
    }

    nonisolated static func parseChordResponse(
        _ data: Data
    ) -> (chordCount: Int?, previewChords: [CleanedChord]?, cleanedData: Data?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }

        // Prefer values from the normalised cleanedChords payload
        guard let cleaned = json["cleanedChords"] as? [String: Any] else {
            // Fallback for older / stub responses
            let count: Int?
            if let v = json["chordCount"] as? Int       { count = v }
            else if let ch = json["chords"] as? [Any]   { count = ch.count }
            else                                         { count = nil }
            return (count, nil, nil)
        }

        let chordCount = cleaned["chordCount"] as? Int

        // Parse first 10 chords for the UI preview
        let rawList = (cleaned["chords"] as? [[String: Any]]) ?? []
        let previewChords: [CleanedChord] = rawList.prefix(10).compactMap { entry in
            guard let start = entry["start"] as? Double,
                  let end   = entry["end"]   as? Double,
                  let raw   = entry["rawChord"]     as? String,
                  let disp  = entry["displayChord"] as? String else { return nil }
            return CleanedChord(start: round3(start), end: round3(end), rawChord: raw, displayChord: disp)
        }

        // Serialise the cleaned dict for writing to chord.cleaned.json,
        // rounding start/end to 3dp to eliminate floating-point artefacts.
        var mutableCleaned = cleaned
        if var chords = mutableCleaned["chords"] as? [[String: Any]] {
            chords = chords.map { chord in
                var c = chord
                if let s = c["start"] as? Double { c["start"] = jsonDecimal(s, 3) }
                if let e = c["end"]   as? Double { c["end"]   = jsonDecimal(e, 3) }
                return c
            }
            mutableCleaned["chords"] = chords
        }
        let cleanedData = try? JSONSerialization.data(
            withJSONObject: mutableCleaned,
            options: .prettyPrinted
        )

        return (chordCount, previewChords.isEmpty ? nil : previewChords, cleanedData)
    }

    // MARK: - URL cleanup

    /// Strips the `list` query parameter from youtu.be and youtube.com short-link URLs
    /// so --no-playlist doesn't fail on playlist-appended share links.
    nonisolated static func cleanYouTubeURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return raw
        }
        let isYouTube = components.host?.contains("youtu.be") == true
            || components.host?.contains("youtube.com") == true
        guard isYouTube, var items = components.queryItems, !items.isEmpty else {
            return raw
        }
        items.removeAll { $0.name == "list" }
        components.queryItems = items.isEmpty ? nil : items
        return components.url?.absoluteString ?? raw
    }
}
