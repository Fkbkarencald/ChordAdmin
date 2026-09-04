import Foundation
import Combine

// MARK: - Model

nonisolated struct ChordSection: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var startBar: Int
    var endBar: Int
    var bars: [Int]

    // Deliberately the synthesised memberwise equality, not identity: a rename
    // or a changed bar range IS a change. Comparing ids alone made every
    // content-only difference invisible, so reconciled sections were never
    // written back and the export shipped the pre-reconcile bar numbers.
}

nonisolated struct SectionsFile: Codable, Sendable {
    struct Source: Codable, Sendable {
        var chordChartPerformerPath: String?
        var sectionCandidatesPath: String?
        var chordChartDraftPath: String?   // kept for backward compat decoding
    }
    var source: Source
    var sections: [ChordSection]
}

// MARK: - Store (ObservableObject loaded per-job)

@MainActor
final class SectionStore: ObservableObject {
    @Published private(set) var sections: [ChordSection] = []
    /// Set when a save fails, so the UI can say so rather than losing edits silently.
    @Published private(set) var saveError: String?

    /// Called after any successful edit, so the job can record that it now has
    /// changes the last export does not include.
    var onEdit: (() -> Void)?

    private var filePath: String?
    private var performerPath: String?
    private var candidatesPath: String?
    private var loadedJobID: String?

    // MARK: Load / initialise

    /// Loads sections.json for `job`, building initial sections from the
    /// detected candidates only when no file exists yet.
    ///
    /// The previous build also discarded any saved file that held a single
    /// section spanning every bar, treating it as a leftover default — which
    /// silently threw away the work of a user who had merged everything back
    /// into one section.
    func load(for job: AnalysisJob, jobFolder: URL) {
        let path = jobFolder.appendingPathComponent("sections.json").path
        filePath       = path
        performerPath  = job.chordChartPerformerPath
        candidatesPath = job.sectionCandidatesPath
        loadedJobID    = job.id
        saveError      = nil

        let allBars = barsFrom(job: job)
        guard !allBars.isEmpty else { sections = []; return }

        if let existing = read(from: path), !existing.sections.isEmpty {
            sections = reconcile(existing.sections, with: allBars)
            // Reconciling only fixed the copy in memory. Export translates the
            // job folder on disk, so without writing the result back the export
            // shipped the pre-reconcile bar numbers — sections pointing at bars
            // a re-tune had removed, and new bars belonging to none.
            if sections != existing.sections { save(notify: false) }
            return
        }

        let candidates = loadCandidates(job: job)
        if !candidates.isEmpty {
            sections = buildSectionsFromCandidates(candidates, allBars: allBars)
        } else {
            sections = [ChordSection(
                id: "section-1", name: "Intro",
                startBar: allBars.first!, endBar: allBars.last!,
                bars: allBars
            )]
        }
        save(notify: false)
    }

    /// True when this store already holds the sections for `job`.
    func isLoaded(for job: AnalysisJob) -> Bool { loadedJobID == job.id }

    func unload() {
        sections = []
        filePath = nil
        loadedJobID = nil
        // Belongs to the song that was open, not the next one.
        saveError = nil
    }

    /// Drops bars that no longer exist and appends any new ones to the last
    /// section, so a re-alignment that changes the bar count cannot leave the
    /// chart with bars that belong to no section.
    private func reconcile(_ stored: [ChordSection], with allBars: [Int]) -> [ChordSection] {
        let valid = Set(allBars)
        var result: [ChordSection] = []
        for var section in stored {
            let bars = section.bars.filter { valid.contains($0) }.sorted()
            guard !bars.isEmpty else { continue }
            section.bars = bars
            section.startBar = bars.first!
            section.endBar = bars.last!
            result.append(section)
        }
        guard !result.isEmpty else {
            return [ChordSection(id: "section-1", name: "Intro",
                                 startBar: allBars.first!, endBar: allBars.last!, bars: allBars)]
        }
        let covered = Set(result.flatMap(\.bars))
        let missing = allBars.filter { !covered.contains($0) }.sorted()
        if !missing.isEmpty {
            var last = result[result.count - 1]
            last.bars = (last.bars + missing).sorted()
            last.endBar = last.bars.last!
            result[result.count - 1] = last
        }
        return result
    }

    // MARK: Mutations

    /// Replace all sections with a single section covering every bar.
    func resetToSingle() {
        let allBars = sections.flatMap { $0.bars }.sorted()
        guard !allBars.isEmpty else { return }
        sections = [ChordSection(
            id: "section-1", name: "Intro",
            startBar: allBars.first!, endBar: allBars.last!,
            bars: allBars
        )]
        save()
    }

    /// Split the section containing `bar` at that bar (bar becomes first bar of new section).
    func startNewSection(at bar: Int) {
        startNewSectionNoSave(at: bar)
        save()
    }

    func rename(section id: String, to name: String) {
        guard let idx = sections.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sections[idx].name = trimmed
        save()
    }

    /// Merge the section containing `bar` into the previous section.
    func mergeSectionWithPrevious(containing bar: Int) {
        guard let idx = sectionIndex(containing: bar), idx > 0 else { return }
        var prev = sections[idx - 1]
        let curr = sections[idx]
        prev.endBar = curr.endBar
        prev.bars   = prev.bars + curr.bars
        sections[idx - 1] = prev
        sections.remove(at: idx)
        save()
    }


    /// Rebuilds sections from the detected repeats for `job`, discarding the
    /// current split. Used by the inspector's "Detect sections again".
    func autoDetectSections(for job: AnalysisJob) {
        let candidates = loadCandidates(job: job)
        guard !candidates.isEmpty else { return }
        let allBars = sections.flatMap(\.bars).sorted()
        guard !allBars.isEmpty else { return }
        sections = buildSectionsFromCandidates(candidates, allBars: allBars)
        save()
    }

    /// How many repeats were detected, so the UI can say whether re-detecting
    /// would do anything.
    func candidateCount(for job: AnalysisJob) -> Int {
        loadCandidates(job: job).count
    }


    // MARK: Queries

    func section(containing bar: Int) -> ChordSection? {
        sections.first { $0.bars.contains(bar) }
    }

    func isFirstSection(_ section: ChordSection) -> Bool {
        sections.first?.id == section.id
    }

    func isFirstBarOfSection(_ bar: Int) -> Bool {
        sections.contains { $0.startBar == bar }
    }

    /// Position of `bar` within its section, e.g. "bar 10 of 16".
    func positionInSection(of bar: Int) -> (index: Int, total: Int)? {
        guard let section = section(containing: bar),
              let index = section.bars.sorted().firstIndex(of: bar) else { return nil }
        return (index + 1, section.bars.count)
    }

    /// How many later sections repeat this one's chord shape, for the
    /// "repeats ×2" hint in the chart. Compares bar counts and names.
    func repeatCount(of section: ChordSection) -> Int {
        sections.filter { $0.name == section.name }.count
    }

    // MARK: Private helpers

    private func startNewSectionNoSave(at bar: Int) {
        guard let idx = sectionIndex(containing: bar),
              sections[idx].startBar != bar else { return }
        var sec = sections[idx]
        guard let splitPoint = sec.bars.firstIndex(of: bar) else { return }
        let firstBars  = Array(sec.bars[..<splitPoint])
        let secondBars = Array(sec.bars[splitPoint...])
        guard !firstBars.isEmpty, !secondBars.isEmpty else { return }
        sec.bars   = firstBars
        sec.endBar = firstBars.last ?? sec.startBar
        let newSec = ChordSection(
            id:       nextSectionId(),
            name:     nextSectionName(),
            startBar: secondBars.first!,
            endBar:   secondBars.last!,
            bars:     secondBars
        )
        sections[idx] = sec
        sections.insert(newSec, at: idx + 1)
    }

    private func sectionIndex(containing bar: Int) -> Int? {
        sections.firstIndex { $0.bars.contains(bar) }
    }

    private func nextSectionId() -> String {
        "section-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private func nextSectionName() -> String {
        let existing = sections.compactMap { s -> Int? in
            guard s.name.hasPrefix("Section ") else { return nil }
            return Int(s.name.dropFirst("Section ".count))
        }
        let next = (existing.max() ?? 0) + 1
        return "Section \(next)"
    }

    /// Bar numbers from performer chart (preferred) or draft chart (fallback).
    private func barsFrom(job: AnalysisJob) -> [Int] {
        let performer = JobManager.loadBars(atPath: job.chordChartPerformerPath).map(\.bar).sorted()
        if !performer.isEmpty { return performer }
        return JobManager.loadBars(atPath: job.chordChartDraftPath).map(\.bar).sorted()
    }

    private func loadCandidates(job: AnalysisJob) -> [SectionCandidate] {
        guard let path = job.sectionCandidatesPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCands = json["candidates"] as? [[String: Any]] else { return [] }
        return rawCands.compactMap { c in
            guard let label = c["label"]      as? String,
                  let sb    = c["startBar"]   as? Int,
                  let eb    = c["endBar"]     as? Int,
                  let bc    = c["barCount"]   as? Int,
                  let mc    = c["matchCount"] as? Int else { return nil }
            let sigs = (c["barSignatures"] as? [String])
                    ?? (c["chords"]        as? [String])
                    ?? []
            let rawMatches = c["matches"] as? [[String: Any]] ?? []
            let matches: [SectionCandidateMatch] = rawMatches.compactMap { m in
                guard let msb = m["startBar"] as? Int,
                      let meb = m["endBar"]   as? Int else { return nil }
                return SectionCandidateMatch(startBar: msb, endBar: meb)
            }
            return SectionCandidate(label: label, startBar: sb, endBar: eb,
                                    barCount: bc, barSignatures: sigs,
                                    matchCount: mc, matches: matches)
        }
    }

    private func buildSectionsFromCandidates(
        _ candidates: [SectionCandidate],
        allBars: [Int]
    ) -> [ChordSection] {
        let allBarsSorted = allBars.sorted()

        // Select non-overlapping candidates: prefer 8-bar, then higher matchCount
        let sorted = candidates.sorted { a, b in
            if a.barCount   != b.barCount   { return a.barCount   > b.barCount   }
            if a.matchCount != b.matchCount { return a.matchCount > b.matchCount }
            return a.startBar < b.startBar
        }
        var accepted: [SectionCandidate] = []
        for cand in sorted {
            let overlaps = accepted.contains { a in
                cand.startBar <= a.endBar && cand.endBar >= a.startBar
            }
            if !overlaps { accepted.append(cand) }
        }
        let ordered = accepted.sorted { $0.startBar < $1.startBar }

        // Build section ranges from gaps + accepted candidates
        struct SecRange { var start: Int; var end: Int }
        var ranges: [SecRange] = []
        var cursor = allBarsSorted.first!
        for cand in ordered {
            let gapBars = allBarsSorted.filter { $0 >= cursor && $0 < cand.startBar }
            if !gapBars.isEmpty {
                ranges.append(SecRange(start: gapBars.first!, end: gapBars.last!))
            }
            let candBars = allBarsSorted.filter { $0 >= cand.startBar && $0 <= cand.endBar }
            if !candBars.isEmpty {
                ranges.append(SecRange(start: candBars.first!, end: candBars.last!))
            }
            cursor = allBarsSorted.first(where: { $0 > cand.endBar }) ?? (allBarsSorted.last! + 1)
        }
        let tailBars = allBarsSorted.filter { $0 >= cursor }
        if !tailBars.isEmpty { ranges.append(SecRange(start: tailBars.first!, end: tailBars.last!)) }
        if ranges.isEmpty    { ranges = [SecRange(start: allBarsSorted.first!, end: allBarsSorted.last!)] }

        // Assign names: Intro / Section A, B, C... / Outro or Ending
        let letters     = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var letterIndex = 0
        var result: [ChordSection] = []
        for (i, range) in ranges.enumerated() {
            let isFirst  = (i == 0)
            let isLast   = (i == ranges.count - 1)
            let bars     = allBarsSorted.filter { $0 >= range.start && $0 <= range.end }
            let barCount = bars.count
            let name: String
            if isFirst {
                name = "Intro"
            } else if isLast {
                name = barCount <= 4 ? "Outro" : "Ending"
            } else {
                if letterIndex < letters.count {
                    let letter = String(letters[letters.index(letters.startIndex, offsetBy: letterIndex)])
                    name = "Section \(letter)"
                } else {
                    name = "Section \(letterIndex + 1)"
                }
                letterIndex += 1
            }
            result.append(ChordSection(
                id: "section-\(i + 1)", name: name,
                startBar: range.start, endBar: range.end, bars: bars
            ))
        }
        return result
    }

    // MARK: Persistence

    private func read(from path: String) -> SectionsFile? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(SectionsFile.self, from: data)
    }

    func save(notify: Bool = true) {
        guard let path = filePath else { return }
        let file = SectionsFile(
            source: .init(
                chordChartPerformerPath: performerPath,
                sectionCandidatesPath:   candidatesPath,
                chordChartDraftPath:     nil
            ),
            sections: sections
        )
        do {
            let data = try JSONEncoder().encode(file)
            let object = try JSONSerialization.jsonObject(with: data)
            let pretty = try JSONSerialization.data(withJSONObject: object, options: .prettyPrinted)
            try pretty.write(to: URL(fileURLWithPath: path), options: .atomic)
            saveError = nil
            if notify { onEdit?() }
        } catch {
            // Surfaced in the inspector — the old build swallowed this entirely.
            saveError = error.localizedDescription
        }
    }
}
