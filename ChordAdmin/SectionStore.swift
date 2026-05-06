import Foundation
import Combine

// MARK: - Model

struct ChordSection: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var startBar: Int
    var endBar: Int
    var bars: [Int]

    static func == (lhs: ChordSection, rhs: ChordSection) -> Bool { lhs.id == rhs.id }
}

struct SectionsFile: Codable, Sendable {
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

    private var filePath: String?
    private var performerPath: String?
    private var candidatesPath: String?

    // MARK: Load / initialise

    /// Load sections.json for `job`.
    /// If sections.json doesn't exist, or only has one default section covering all bars,
    /// generate initial sections from section.candidates.json.
    func load(for job: AnalysisJob, jobFolder: URL) {
        let path = jobFolder.appendingPathComponent("sections.json").path
        filePath       = path
        performerPath  = job.chordChartPerformerPath
        candidatesPath = job.sectionCandidatesPath

        // Read all bar numbers (performer first, draft fallback)
        let allBars = barsFrom(job: job)
        guard !allBars.isEmpty else { sections = []; return }

        // Try to load existing sections.json
        if let existing = read(from: path) {
            // Use existing unless it's a single-section default covering all bars
            let isDefaultSingle = existing.sections.count == 1
                && Set(existing.sections[0].bars) == Set(allBars)
            if !isDefaultSingle {
                sections = existing.sections
                return
            }
        }

        // Generate from candidates if available
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
        save()
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
        sections[idx].name = name
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

    /// Apply a single candidate: splits sections at startBar and the bar just after endBar,
    /// then names the resulting section "Section [label]".
    func applyCandidate(_ candidate: SectionCandidate) {
        let allBarsSet = Set(sections.flatMap { $0.bars })
        startNewSectionNoSave(at: candidate.startBar)
        if let nextBar = allBarsSet.filter({ $0 > candidate.endBar }).min() {
            startNewSectionNoSave(at: nextBar)
        }
        if let idx = sections.firstIndex(where: { $0.startBar == candidate.startBar }) {
            sections[idx].name = "Section \(candidate.label)"
        }
        save()
    }

    /// Apply all non-overlapping candidates (prefer 8-bar, then higher matchCount).
    func applyAllNonOverlapping(_ candidates: [SectionCandidate]) {
        guard !candidates.isEmpty else { return }

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
        guard !accepted.isEmpty else { return }

        let allBarsSet = Set(sections.flatMap { $0.bars })
        var splitPoints = Set<Int>()
        for cand in accepted {
            splitPoints.insert(cand.startBar)
            if let nextBar = allBarsSet.filter({ $0 > cand.endBar }).min() {
                splitPoints.insert(nextBar)
            }
        }
        for bar in splitPoints.sorted() { startNewSectionNoSave(at: bar) }
        for cand in accepted {
            if let idx = sections.firstIndex(where: { $0.startBar == cand.startBar }) {
                sections[idx].name = "Section \(cand.label)"
            }
        }
        save()
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

    // MARK: Private helpers

    private func startNewSectionNoSave(at bar: Int) {
        guard let idx = sectionIndex(containing: bar),
              sections[idx].startBar != bar else { return }
        var sec = sections[idx]
        guard let splitPoint = sec.bars.firstIndex(of: bar) else { return }
        let firstBars  = Array(sec.bars[..<splitPoint])
        let secondBars = Array(sec.bars[splitPoint...])
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
        if let path = job.chordChartPerformerPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawBars = json["bars"] as? [[String: Any]] {
            let bars = rawBars.compactMap { $0["bar"] as? Int }.sorted()
            if !bars.isEmpty { return bars }
        }
        if let path = job.chordChartDraftPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawBars = json["bars"] as? [[String: Any]] {
            return rawBars.compactMap { $0["bar"] as? Int }.sorted()
        }
        return []
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

    func save() {
        guard let path = filePath else { return }
        let file = SectionsFile(
            source: .init(
                chordChartPerformerPath: performerPath,
                sectionCandidatesPath:   candidatesPath,
                chordChartDraftPath:     nil
            ),
            sections: sections
        )
        guard let data = try? JSONEncoder().encode(file) else { return }
        if let obj    = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            try? pretty.write(to: URL(fileURLWithPath: path))
        }
    }
}
