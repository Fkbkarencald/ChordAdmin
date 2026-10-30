import Foundation

/// Feeds a `SongForm` into the existing chart pipeline. The form decides where
/// bars and sections fall; the chart builders downstream work from bar times
/// and chord spans, so they take its variable-length bars unchanged.
extension JobManager {

    /// Where the music stops: the end of the file less any closing silence.
    nonisolated static func audioEnd(job: AnalysisJob) -> Double? {
        guard let duration = job.durationSeconds else { return nil }
        guard let path = job.audioHealthPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let regions = json["silenceRegions"] as? [[String: Any]] else { return duration }
        let closing = regions.first { region in
            ((region["end"] as? NSNumber)?.doubleValue ?? 0) >= duration - 0.05
        }
        return (closing?["start"] as? NSNumber)?.doubleValue ?? duration
    }

    /// A beat grid in `generateBeatGrid`'s shape, with the form's bar lengths.
    /// Each bar carries its own `beatCount`; `beatsPerBar` stays the meter.
    nonisolated static func formBeatGrid(_ form: SongForm.Result, bpm: Double?) -> [String: Any] {
        let firstBeat = form.bars.first?.startBeat ?? 0
        let pickup: [[String: Any]] = (0..<firstBeat).map { index in
            ["beat": index + 1, "time": jsonDecimal(form.beatEdges[index], 3)]
        }
        let bars: [[String: Any]] = form.bars.enumerated().map { index, bar in
            [
                "bar": index + 1,
                "start": jsonDecimal(bar.start, 3),
                "end": jsonDecimal(bar.end, 3),
                "beatCount": bar.beats,
                "beats": (0..<bar.beats).map { beat in
                    ["beat": beat + 1, "time": jsonDecimal(form.beatEdges[bar.startBeat + beat], 3)] as [String: Any]
                },
            ]
        }
        return [
            "bpm": bpm.map { jsonDecimal($0, 2) as NSObject } ?? NSNull(),
            "beatCount": form.beatEdges.count - 1,
            "estimatedTimeSignature": "\(form.meter)/4",
            "beatsPerBar": form.meter,
            "barAlignmentOffset": firstBeat % form.meter,
            "pickupBeats": pickup,
            "bars": bars,
            "warnings": [String](),
            "songForm": true,
        ]
    }

    /// The form's chords as spans on its beats, in `chord.cleaned.json`'s shape,
    /// so the chart shows exactly the chords the form laid out bar by bar.
    nonisolated static func formChords(_ form: SongForm.Result) -> [String: Any] {
        var spans: [[String: Any]] = []
        for bar in form.bars {
            var beat = bar.startBeat
            for chord in bar.chords {
                let start = form.beatEdges[beat], end = form.beatEdges[beat + chord.beats]
                if let last = spans.last, last["displayChord"] as? String == chord.name,
                   (last["end"] as? NSNumber)?.doubleValue == round3(start) {
                    spans[spans.count - 1]["end"] = jsonDecimal(end, 3)
                } else {
                    spans.append(["start": jsonDecimal(start, 3), "end": jsonDecimal(end, 3),
                                  "rawChord": chord.name, "displayChord": chord.name, "confidence": NSNull()])
                }
                beat += chord.beats
            }
        }
        return ["chords": spans, "chordCount": spans.count, "source": "songForm", "warnings": [String]()]
    }

    /// The form's sections against the performer chart's bar numbers, matched
    /// by time so a chart that starts after a pre-intro still lines up.
    nonisolated static func sectionsFromForm(_ form: SongForm.Result, performerData: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: performerData) as? [String: Any],
              let rawBars = json["bars"] as? [[String: Any]] else { return nil }
        let bars: [(number: Int, start: Double)] = rawBars.compactMap { bar in
            guard let number = bar["bar"] as? Int, let start = (bar["start"] as? NSNumber)?.doubleValue else { return nil }
            return (number, start)
        }
        var sections: [[String: Any]] = []
        for section in form.sections {
            let (from, to) = (form.beatEdges[section.startBeat], form.beatEdges[section.endBeat])
            let numbers = bars.filter { $0.start >= from - 0.05 && $0.start < to - 0.05 }.map(\.number)
            guard let first = numbers.first, let last = numbers.last else { continue }
            sections.append(["id": "section-\(sections.count + 1)", "name": section.name,
                             "startBar": first, "endBar": last, "bars": numbers])
        }
        return sections.isEmpty ? nil : ["source": ["songForm": true], "sections": sections]
    }

    nonisolated static func loadForm(job: AnalysisJob) -> SongForm.Result? {
        guard let path = job.songFormPath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(SongForm.Result.self, from: data)
    }

    /// Runs the form analysis and swaps its grid and chords in for the uniform
    /// ones before the chart is built. Leaves everything as it was when there
    /// is no usable form.
    nonisolated static func applyForm(job: inout AnalysisJob, folder: URL, beatData: Data, cleanedData: Data,
                                      vocals: [SongForm.VocalSpan]? = nil) -> (gridPath: String, gridData: Data,
                                                             cleanedPath: String, cleanedData: Data)? {
        let settings = gridSettings(for: job, beatData: beatData)
        let meter = job.beatsPerBarOverride ?? 4
        // The detected (or chosen) pickup still decides which beat is a downbeat.
        let pickup = resolvedBeatOffset(job: job, beatData: settings.beatData)
        guard let form = SongForm.analyse(beatData: settings.beatData, cleanedChordData: cleanedData,
                                          audioEnd: audioEnd(job: job), meter: meter, downbeat: pickup,
                                          vocals: vocals),
              let formData = try? JSONEncoder().encode(form),
              let gridData = try? JSONSerialization.data(withJSONObject: formBeatGrid(form, bpm: settings.bpm),
                                                         options: .prettyPrinted),
              let chordData = try? JSONSerialization.data(withJSONObject: formChords(form), options: .prettyPrinted)
        else { return nil }
        let formURL = folder.appendingPathComponent("song.form.json")
        let gridURL = folder.appendingPathComponent("beat.grid.json")
        let chordURL = folder.appendingPathComponent("chord.form.json")
        do {
            try formData.write(to: formURL, options: .atomic)
            try gridData.write(to: gridURL, options: .atomic)
            try chordData.write(to: chordURL, options: .atomic)
        } catch {
            return nil
        }
        job.songFormPath = formURL.path
        job.songKey = form.key
        job.beatGridPath = gridURL.path
        job.barCount = form.bars.count
        job.barAlignmentOffset = (form.bars.first?.startBeat ?? pickup) % meter
        return (gridURL.path, gridData, chordURL.path, chordData)
    }
}

extension JobManager {

    /// Reads the form again now that vocal timing has arrived, and rebuilds the
    /// chart when that moves any section or bar. Nil when the vocals change
    /// nothing, or there is no form to refine.
    nonisolated static func reapplyForm(job: inout AnalysisJob, folder: URL,
                                        vocals: [SongForm.VocalSpan]) throws -> (form: SongForm.Result, performerData: Data)? {
        guard let previous = loadForm(job: job),
              let beatPath = job.beatDetectionPath,
              let beatData = try? Data(contentsOf: URL(fileURLWithPath: beatPath)),
              let cleanedPath = job.chordCleanedPath,
              let cleanedData = try? Data(contentsOf: URL(fileURLWithPath: cleanedPath)) else { return nil }
        var trial = job
        guard let formed = applyForm(job: &trial, folder: folder, beatData: beatData, cleanedData: cleanedData,
                                     vocals: vocals),
              let form = loadForm(job: trial), form.sections != previous.sections else { return nil }
        job = trial
        try buildCharts(job: &job, folder: folder, gridPath: formed.gridPath, gridData: formed.gridData,
                        cleanedPath: formed.cleanedPath, cleanedData: formed.cleanedData)
        guard let performerPath = job.chordChartPerformerPath,
              let performerData = try? Data(contentsOf: URL(fileURLWithPath: performerPath)) else { return nil }
        return (form, performerData)
    }
}

extension StageBeeExportService {

    /// The translator writes every bar in the song's meter. Bars the form made
    /// longer or shorter get their own time signature and chord spacing here.
    /// Skipped unless the chart still has exactly the form's bars, and per bar
    /// unless it still has the form's chords — an edited bar keeps its edit.
    nonisolated static func applyingFormMeter(to sections: Any, form: SongForm.Result) -> Any {
        guard var list = sections as? [[String: Any]] else { return sections }
        let formBars = form.bars
        let total = list.reduce(0) { sum, section in
            sum + ((section["lines"] as? [[String: Any]]) ?? []).reduce(0) { $0 + (($1["bars"] as? [Any])?.count ?? 0) }
        }
        guard total == formBars.count else { return sections }
        var index = 0
        for s in list.indices {
            guard var lines = list[s]["lines"] as? [[String: Any]] else { continue }
            for l in lines.indices {
                guard var bars = lines[l]["bars"] as? [[String: Any]] else { continue }
                for b in bars.indices {
                    let formBar = formBars[index]
                    index += 1
                    guard formBar.beats != form.meter else { continue }
                    bars[b]["timeSignature"] = [formBar.beats, 4]
                    if (bars[b]["chords"] as? [Any])?.count == formBar.chords.count {
                        bars[b]["structure"] = formBar.structure
                    }
                }
                lines[l]["bars"] = bars
            }
            list[s]["lines"] = lines
        }
        return list
    }
}
