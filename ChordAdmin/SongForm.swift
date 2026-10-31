import Foundation

/// A song's form, read from its chords on the detected beats.
///
/// Bars are an output here, not an input (docs/section-signatures-design-2026-10-30.md).
/// The fixed 4/4 grid the rest of the pipeline starts from hides the form: one
/// 6/4 bar shifts every later bar line, so no later passage matches an earlier
/// one bar for bar. Instead, every beat gets a chord; passages that repeat are
/// found on that beat timeline; sections are cut where repeats begin and refined
/// by musical rules (repeats line up, phrases are whole, heads match); and only
/// then is each section divided into bars, with an odd-length bar where its
/// chord changes need one, landing in the same place in every repeat.
nonisolated enum SongForm {

    // MARK: - Harmony

    nonisolated enum Quality: String, Codable, Sendable {
        case major, minor, diminished, augmented, sus2, sus4
    }

    /// A chord reduced to what decides whether two passages are the same music:
    /// root and triad quality. Colours (7, maj7, add9) and bass notes are left
    /// out so they can never stop two verses from matching.
    nonisolated struct Harmony: Hashable, Sendable {
        var root: Int
        var quality: Quality

        var isMajorLike: Bool { quality == .major || quality == .sus2 || quality == .sus4 }
    }

    nonisolated static let pitchClasses: [String: Int] = [
        "C": 0, "B#": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "Fb": 4,
        "F": 5, "E#": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9,
        "A#": 10, "Bb": 10, "B": 11, "Cb": 11,
    ]

    /// Reads a display chord ("Em", "F#m7", "Asus4", "Ab/b7"). Nil for no chord.
    nonisolated static func harmony(_ name: String) -> Harmony? {
        let symbol = name.split(separator: "/").first.map(String.init) ?? name
        guard let letter = symbol.first, "ABCDEFG".contains(letter) else { return nil }
        var root = String(letter)
        var rest = Substring(symbol.dropFirst())
        if let accidental = rest.first, accidental == "#" || accidental == "b" {
            root.append(accidental)
            rest = rest.dropFirst()
        }
        guard let pitch = pitchClasses[root] else { return nil }
        let q = String(rest)
        let quality: Quality
        if q.hasPrefix("maj") { quality = .major }
        else if q.hasPrefix("m7b5") || q.hasPrefix("hdim") || q.hasPrefix("dim") || q.hasPrefix("°") { quality = .diminished }
        else if q.hasPrefix("min") || q.hasPrefix("m") { quality = .minor }
        else if q.hasPrefix("aug") || q.hasPrefix("+") { quality = .augmented }
        else if q.contains("sus2") { quality = .sus2 }
        else if q.contains("sus") { quality = .sus4 }
        else { quality = .major }
        return Harmony(root: pitch, quality: quality)
    }

    /// 1 for the same chord, partial credit for the same root, 0 otherwise.
    /// No chord never matches anything, so two silences are not a repeat.
    nonisolated static func similarity(_ a: Harmony?, _ b: Harmony?) -> Double {
        guard let a, let b else { return 0 }
        if a == b { return 1 }
        guard a.root == b.root else { return 0 }
        let pair: Set<Quality> = [a.quality, b.quality]
        if pair.isSubset(of: [.major, .sus2, .sus4]) || pair.isSubset(of: [.minor, .sus2, .sus4]) { return 0.75 }
        return 0.5
    }

    nonisolated static let matchThreshold = 0.75

    // MARK: - Beat timeline

    nonisolated struct ChordSpan: Sendable {
        var name: String
        var start: Double
        var end: Double
    }

    nonisolated struct Timeline: Sendable {
        /// Beat boundaries: beat `i` runs from `edges[i]` to `edges[i + 1]`.
        var edges: [Double]
        var harmony: [Harmony?]
        /// The display chord sounding on each beat, nil where nothing is.
        var names: [String?]
        var count: Int { harmony.count }
    }

    /// One chord per beat: whichever chord covers most of it.
    ///
    /// Beats are extrapolated past the last detected one while the audio is
    /// still sounding, so a final chord left ringing can fill out its bar.
    nonisolated static func timeline(beatTimes: [Double], chords: [ChordSpan], audioEnd: Double?) -> Timeline {
        let beats = beatTimes.filter(\.isFinite).sorted()
        guard beats.count >= 2 else { return Timeline(edges: beats, harmony: [], names: []) }
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        let interval = gaps.isEmpty ? 0.5 : gaps[gaps.count / 2]
        var starts = beats
        if let audioEnd {
            while let last = starts.last, last + interval + interval / 2 <= audioEnd {
                starts.append(last + interval)
            }
        }
        let edges = starts + [starts.last! + interval]
        var sorted = chords.filter { harmony($0.name) != nil }.sorted { $0.start < $1.start }
        // A chord heard only after the music has stopped is the last chord's
        // ring-out misread, not a new final chord.
        if sorted.count >= 2, sorted[sorted.count - 1].start - sorted[sorted.count - 2].end >= interval * 1.5 {
            sorted.removeLast()
        }
        var names: [String?] = []
        var cursor = 0
        for index in starts.indices {
            let (a, b) = (edges[index], edges[index + 1])
            while cursor < sorted.count, sorted[cursor].end <= a { cursor += 1 }
            var overlap: [String: Double] = [:]
            var k = cursor
            while k < sorted.count, sorted[k].start < b {
                let o = min(b, sorted[k].end) - max(a, sorted[k].start)
                if o > 0 { overlap[sorted[k].name, default: 0] += o }
                k += 1
            }
            let best = overlap.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
            if let best, best.value >= (b - a) * 0.3, harmony(best.key) != nil {
                names.append(best.key)
            } else {
                names.append(nil)
            }
        }
        // A lone beat of another chord between two beats of the same chord is
        // recognition jitter, not a change of harmony.
        for i in names.indices.dropFirst().dropLast() where names[i] != names[i - 1] && names[i - 1] == names[i + 1] {
            names[i] = names[i - 1]
        }
        return Timeline(edges: edges, harmony: names.map { $0.flatMap(harmony) }, names: names)
    }

    // MARK: - Key

    nonisolated static let majorKeyNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    nonisolated static let minorKeyNames = ["Cm", "C#m", "Dm", "Ebm", "Em", "Fm", "F#m", "Gm", "G#m", "Am", "Bbm", "Bm"]
    nonisolated static let sharpKeyNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    nonisolated static let flatKeyNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    nonisolated enum Spelling: Sendable { case conventional, sharps, flats }

    nonisolated struct Key: Equatable, Sendable {
        var tonic: Int
        var minor: Bool
        /// Whose spelling the name follows: a chart written in C#, F# and G#
        /// is in C#, not D♭.
        var spelling: Spelling = .conventional
        var name: String {
            switch spelling {
            case .conventional: return minor ? minorKeyNames[tonic] : majorKeyNames[tonic]
            case .sharps: return sharpKeyNames[tonic] + (minor ? "m" : "")
            case .flats: return flatKeyNames[tonic] + (minor ? "m" : "")
            }
        }
        /// The accidental the key's chords are written with: flats in Ab,
        /// sharps in E, nil in C and Am, where the detector's spelling stands.
        var accidental: Character? {
            if name.contains("#") { return "#" }
            if name.dropFirst().hasPrefix("b") { return "b" }
            let major = minor ? (tonic + 3) % 12 : tonic
            switch (major * 7) % 12 {
            case 1...6: return "#"
            case 7...11: return "b"
            default: return nil
            }
        }
        func isTonicChord(_ h: Harmony?) -> Bool {
            guard let h, h.root == tonic else { return false }
            return minor ? h.quality == .minor : h.isMajorLike
        }
        func isDominant(_ h: Harmony?) -> Bool {
            guard let h else { return false }
            return h.root == (tonic + 7) % 12 && h.isMajorLike
        }
    }

    /// How well a chord belongs to a key: the tonic most, then the dominant and
    /// subdominant, then the other diatonic chords. Chords outside it count against.
    nonisolated static func fit(_ h: Harmony, tonic: Int, minor: Bool) -> Double {
        let degree = (h.root - tonic + 12) % 12
        if minor {
            switch degree {
            case 0: return h.quality == .minor ? 3 : -1
            case 2: return h.quality == .diminished ? 0.5 : -1
            case 3: return h.isMajorLike ? 1.5 : -1
            case 5: return h.quality == .minor ? 2 : -1
            case 7: return h.isMajorLike ? 2.5 : h.quality == .minor ? 1 : -1
            case 8, 10: return h.isMajorLike ? 1.5 : -1
            default: return -1
            }
        }
        switch degree {
        case 0: return h.isMajorLike ? 3 : -1
        case 2: return h.quality == .minor ? 1 : -1
        case 4: return h.quality == .minor ? 0.7 : -1
        case 5: return h.isMajorLike ? 2 : -1
        case 7: return h.isMajorLike ? 2.5 : -1
        case 9: return h.quality == .minor ? 1.5 : -1
        case 11: return h.quality == .diminished ? 0.5 : -1
        default: return -1
        }
    }

    /// The key whose chords the song spends its beats on, with the opening and
    /// final chords as tiebreakers. A minor key must beat its relative major
    /// clearly: the major reading is the conventional default for this music.
    nonisolated static func estimateKey(_ harmony: [Harmony?]) -> Key {
        let present = harmony.compactMap { $0 }
        guard let first = present.first, let last = present.last else { return Key(tonic: 0, minor: false) }
        var beats: [Harmony: Double] = [:]
        for h in present { beats[h, default: 0] += 1 }
        let bonus = Double(present.count) * 0.06
        func score(_ key: Key) -> Double {
            var total = beats.reduce(0) { $0 + $1.value * fit($1.key, tonic: key.tonic, minor: key.minor) }
            if key.isTonicChord(first) { total += bonus }
            if key.isTonicChord(last) { total += bonus }
            return total
        }
        let keys = (0..<12).flatMap { [Key(tonic: $0, minor: false), Key(tonic: $0, minor: true)] }
        let best = keys.max { score($0) < score($1) }!
        if best.minor {
            let relative = Key(tonic: (best.tonic + 3) % 12, minor: false)
            if score(relative) * 1.08 >= score(best) { return relative }
        }
        return best
    }

    // MARK: - Repeats

    /// Beats `start..<end` match beats `start + lag..<end + lag`.
    nonisolated struct Run: Equatable, Sendable {
        var start: Int
        var end: Int
        var lag: Int
        var length: Int { end - start }
    }

    /// Every stretch that the music repeats `lag` beats later, for every lag.
    ///
    /// A run tolerates up to two mismatched beats in any eight, so recognition
    /// jitter (a chord detected a beat late) does not break a repeat, but a
    /// genuinely different bar does. A run must contain chord changes: two long
    /// holds of the same chord are not a repeated passage.
    nonisolated static func runs(_ h: [Harmony?], in range: Range<Int>, minLag: Int, minLength: Int) -> [Run] {
        let lo = range.lowerBound, hi = range.upperBound
        guard hi - lo > minLag else { return [] }
        var found: [Run] = []
        for lag in minLag..<(hi - lo) {
            var i = lo
            while i + lag < hi {
                guard similarity(h[i], h[i + lag]) >= matchThreshold else { i += 1; continue }
                var j = i, lastMatch = i, misses = 0
                var recent: [Bool] = []
                while j + lag < hi {
                    let miss = similarity(h[j], h[j + lag]) < matchThreshold
                    recent.append(miss)
                    if miss { misses += 1 }
                    if recent.count > 8, recent.removeFirst() { misses -= 1 }
                    if misses > 2 { break }
                    if !miss { lastMatch = j }
                    j += 1
                }
                let end = lastMatch + 1
                if end - i >= minLength, changes(h, i..<end) >= 3 {
                    found.append(Run(start: i, end: end, lag: lag))
                }
                i = max(end, i + 1)
            }
        }
        return found
    }

    /// One repeat seen through recognition jitter also matches a beat either
    /// side of its true lag. Keep the longest of each such family, so it counts
    /// as evidence once, at its own position.
    nonisolated static func distinct(_ runs: [Run]) -> [Run] {
        var kept: [Run] = []
        for run in runs.sorted(by: { $0.length != $1.length ? $0.length > $1.length : $0.lag < $1.lag }) {
            let duplicate = kept.contains { k in
                guard abs(k.lag - run.lag) <= 2 else { return false }
                let overlap = min(k.end, run.end) - max(k.start, run.start)
                return overlap * 2 >= min(k.length, run.length)
            }
            if !duplicate { kept.append(run) }
        }
        return kept
    }

    /// How many beats two passages stay the same from their starts, with the
    /// same jitter tolerance as a run.
    nonisolated static func matchedPrefix(_ h: [Harmony?], _ a: Range<Int>, _ b: Range<Int>) -> Int {
        let span = min(a.count, b.count)
        var lastMatch = -1, misses = 0
        var recent: [Bool] = []
        for k in 0..<span {
            let miss = similarity(h[a.lowerBound + k], h[b.lowerBound + k]) < matchThreshold
            recent.append(miss)
            if miss { misses += 1 }
            if recent.count > 8, recent.removeFirst() { misses -= 1 }
            if misses > 2 { break }
            if !miss { lastMatch = k }
        }
        return lastMatch + 1
    }

    nonisolated static func changes(_ h: [Harmony?], _ range: Range<Int>) -> Int {
        var count = 0
        var previous: Harmony?
        for i in range {
            if let current = h[i] {
                if let previous, previous != current { count += 1 }
                previous = current
            }
        }
        return count
    }

    // MARK: - Sections

    nonisolated struct Section: Codable, Equatable, Sendable {
        var name: String
        var letter: String
        var startBeat: Int
        var endBeat: Int
        var bars: [Bar]
    }

    nonisolated struct Bar: Codable, Equatable, Sendable {
        var startBeat: Int
        var beats: Int
        var start: Double
        var end: Double
        var chords: [BarChord]
        /// TheStageBee's grid string for the chords' relative lengths ("1fr 2fr").
        var structure: String
    }

    nonisolated struct BarChord: Codable, Equatable, Sendable {
        var name: String
        var beats: Int
    }

    nonisolated struct Result: Codable, Equatable, Sendable {
        var version: Int = 1
        var key: String
        var meter: Int
        var sections: [Section]
        /// Beat boundaries the bars refer to, including any extrapolated past the
        /// last detected beat.
        var beatEdges: [Double]

        var bars: [Bar] { sections.flatMap(\.bars) }
    }

    /// How much each rule counts. Tuned against charts corrected by hand
    /// (`Tools/PipelineTests/Fixtures/song-form-*`); change them only with
    /// every one of those fixtures still passing.
    nonisolated struct Weights: Codable, Equatable, Sendable {
        /// Each section must earn its place.
        var section = 1.5
        /// Reward per unit of boundary evidence.
        var evidence = 0.5
        /// A section ending on V (half cadence), or on neither I nor V.
        var dominantCadence = 0.4
        var noCadence = 1.0
        /// Repeats opening unlike the first occurrence, or misplaced so they do.
        var head = 8.0
        /// Per beat of a section beyond what it shares with its repeats.
        var tail = 0.15
        /// Two nearly identical lines either side of a boundary.
        var contrast = 2.0
        /// A boundary in the middle of a held chord.
        var midHold = 0.75
        var layout = 1.0
        /// Evidence: singing starting or stopping; adjacent repeats; the start
        /// and end of a one-off repeat; a repeat's start lent across a hold.
        // Measured on the seven corrected songs: singing gaps inside sections
        // (a chorus line left to the band) make vocal edges weak evidence;
        // above 1 they cost more boundaries than they find.
        var vocal = 1.0
        /// A section start from the trained structure model (All-In-One),
        /// lent to the chord changes near it. It hears the arrangement, which
        /// the chords alone cannot, but often lands a beat or two off.
        // Measured on the eight corrected songs, the model's starts on bar
        // lines, with the search only allowed to remove them, cut boundary
        // errors from 82 to 62; as evidence in the free search, only to 78.
        var model = 4.0
        /// How far, in beats, a model start may be moved onto a chord change.
        var modelReach = 4
        var periodic = 6.0
        var repeatStart = 3.0
        var repeatEnd = 1.0
        var spread = 0.8

        nonisolated static let standard = Weights()
    }

    /// Minimum length of a section-sized repeat. Shorter periods are the lines
    /// inside a section (a chorus whose lines repeat), never sections themselves.
    nonisolated static let minPeriod = 24
    nonisolated static let phrase = 16
    nonisolated static let minSection = 12

    /// Places where a section may begin, weighted by how directly the repeats
    /// imply one. Adjacent repeats (Verse 1, Verse 2) fix their own length: the
    /// lag between them. Elsewhere a repeat's start is a strong boundary and its
    /// end a weak one, since repeats often run on into the next section.
    ///
    /// Inside a run of identical lines (verse line, verse line, verse line) a
    /// one-off repeat starting mid-run says nothing: the same line came just
    /// before it. There only section-sized periodic repeats count.
    nonisolated static func candidates(_ runs: [Run], weights: Weights = .standard) -> [Int: Double] {
        let loops = lineLoops(runs)
        func insideLoop(_ beat: Int) -> Bool { loops.contains { $0.lowerBound < beat && beat < $0.upperBound } }
        var weight: [Int: Double] = [:]
        for run in runs {
            if run.lag >= minPeriod, run.length + 4 >= run.lag {
                let units = (run.length + 4) / run.lag + 1
                for k in 0...units { weight[run.start + k * run.lag, default: 0] += weights.periodic }
            } else if run.lag >= minPeriod, run.length >= minPeriod {
                for (beat, w) in [(run.start, weights.repeatStart), (run.start + run.lag, weights.repeatStart),
                                  (run.end, weights.repeatEnd), (run.end + run.lag, weights.repeatEnd)]
                where !insideLoop(beat) {
                    weight[beat, default: 0] += w
                }
            }
        }
        return weight
    }

    /// Spans that loop a short line (period under a section's length). A
    /// boundary inside one would split a section between its own lines.
    nonisolated static func lineLoops(_ runs: [Run]) -> [Range<Int>] {
        runs.filter { $0.lag < minPeriod && $0.length >= $0.lag }.map { $0.start..<($0.end + $0.lag) }
    }

    nonisolated struct Plan {
        var boundaries: [Int]
        var letters: [Int]
    }

    /// Groups sections whose openings are the same music. Lengths may differ —
    /// one chorus can carry an extra tag — but not wildly, or a short prelude
    /// that quotes the verse would join the verses.
    nonisolated static func letters(_ h: [Harmony?], _ bounds: [Int]) -> [Int] {
        let count = bounds.count - 1
        var parent = Array(0..<count)
        func find(_ x: Int) -> Int { parent[x] == x ? x : find(parent[x]) }
        for a in 0..<count {
            for b in (a + 1)..<max(a + 1, count) where headMatch(h, bounds[a]..<bounds[a + 1], bounds[b]..<bounds[b + 1]) >= 0.8 {
                parent[find(b)] = find(a)
            }
        }
        var ids: [Int: Int] = [:]
        return (0..<count).map { i in
            let root = find(i)
            if let id = ids[root] { return id }
            ids[root] = ids.count
            return ids[root]!
        }
    }

    nonisolated static func transposed(_ h: Harmony?, by shift: Int) -> Harmony? {
        h.map { Harmony(root: (($0.root + shift) % 12 + 12) % 12, quality: $0.quality) }
    }

    /// Sections that repeat an earlier one in another key — a last chorus a
    /// half-step up — take its letter.
    nonisolated static func transposedLetters(_ h: [Harmony?], bounds: [Int], letters: [Int]) -> [Int] {
        var counts: [Int: Int] = [:]
        for l in letters { counts[l, default: 0] += 1 }
        let ranges = (0..<(bounds.count - 1)).map { bounds[$0]..<bounds[$0 + 1] }
        var result = letters
        for i in ranges.indices where counts[letters[i]] == 1 {
            var best: (match: Double, letter: Int)?
            for j in ranges.indices where j != i && counts[letters[j], default: 0] > 1 {
                for shift in 1..<12 {
                    let m = headMatch(h, ranges[j], ranges[i], shift: shift)
                    if m >= 0.8, m > (best?.match ?? 0) { best = (m, letters[j]) }
                }
            }
            if let best { result[i] = best.letter }
        }
        return result
    }

    nonisolated static func headMatch(_ h: [Harmony?], _ a: Range<Int>, _ b: Range<Int>, shift: Int = 0) -> Double {
        // Section-sized passages only: a four-bar prelude that quotes the verse
        // is not a verse. Lengths may otherwise differ freely — a chorus that
        // still carries the instrumental after it must match the others, or
        // nothing would ever separate the two.
        let shorter = min(a.count, b.count)
        guard shorter >= minPeriod else { return 0 }
        // Nor is a long vamp on one chord a repeat of another one.
        guard changes(h, a.lowerBound..<(a.lowerBound + min(shorter, 32))) >= 2,
              changes(h, b.lowerBound..<(b.lowerBound + min(shorter, 32))) >= 2 else { return 0 }
        let span = min(shorter, 32)
        var total = 0.0
        for k in 0..<span { total += similarity(h[a.lowerBound + k], transposed(h[b.lowerBound + k], by: -shift)) }
        return total / Double(span)
    }

    /// How far a section's length is from whole phrases. One or two odd bars
    /// (a 6/4 that adds two beats) are allowed for almost nothing, and the
    /// charge is capped: a verse with a two-bar turnaround is unusual, not
    /// wrong. Past sixteen bars a section is almost certainly two.
    nonisolated static func phraseCost(_ length: Int) -> Double {
        if length < minSection { return 10 }
        let nearest = max(phrase, Int((Double(length) / Double(phrase)).rounded()) * phrase)
        let d = abs(length - nearest)
        let shape = d == 0 ? 0 : d <= 2 ? 0.5 : min(3, Double(d) * 0.75)
        return shape + Double(max(0, length - 4 * phrase)) * 0.1
    }

    /// Lower is better. Every rule from the design, as one number, so moving a
    /// boundary can be judged against all of them at once.
    nonisolated static func cost(_ h: [Harmony?], key: Key, bounds: [Int], evidence: [Int: Double],
                                 layouts: LayoutCache? = nil, weights w: Weights = .standard) -> (Double, [Int]) {
        let letters = letters(h, bounds)
        let ranges = (0..<(bounds.count - 1)).map { bounds[$0]..<bounds[$0 + 1] }
        var total = 0.0
        var first: [Int: Range<Int>] = [:]
        for i in ranges.indices {
            let range = ranges[i]
            // Every section must earn its place.
            total += w.section
            total += phraseCost(range.count)
            // A section starting off the downbeat puts every chord change in
            // the middle of a bar; its bars can't be laid out cleanly.
            if let layouts { total += layouts.cost(range) * w.layout }
            // Music after the part a section shares with its repeats is a
            // section of its own (an instrumental after a chorus), unless it
            // is short enough to be a tag.
            let siblings = ranges.indices.filter { $0 != i && letters[$0] == letters[i] }
            if !siblings.isEmpty {
                let shared = siblings.map { matchedPrefix(h, range, ranges[$0]) }.max() ?? 0
                total += Double(max(0, range.count - shared - phrase)) * w.tail
            }
            // A section ends on a cadence: the tonic, or a half cadence on V.
            let last = (range.lowerBound..<range.upperBound).last { h[$0] != nil }.flatMap { h[$0] }
            // A full cadence on the tonic closes a section more surely than a
            // half cadence on V.
            total += key.isTonicChord(last) ? 0 : key.isDominant(last) ? w.dominantCadence : w.noCadence
            if let reference = first[letters[i]] {
                // Repeats begin the way the first one did.
                total += (1 - headMatch(h, reference, range)) * w.head
            } else {
                // A section that would open like an earlier one if it started a
                // bar or two later (or earlier) is that section, misplaced. Its
                // own letter must not hide the misalignment.
                var gain = 0.0
                for reference in first.values {
                    let current = headMatch(h, reference, range)
                    for shift in stride(from: -8, through: 8, by: 2) where shift != 0 {
                        let moved = (range.lowerBound + shift)..<range.upperBound
                        guard moved.lowerBound >= 0, moved.count > 0 else { continue }
                        let m = headMatch(h, reference, moved)
                        if m >= 0.85 { gain = max(gain, m - current) }
                    }
                }
                total += gain * w.head
                first[letters[i]] = range
            }
            if i > 0 {
                total -= (evidence[bounds[i]] ?? 0) * w.evidence
                // Sections divide contrasting lines. A boundary between two lines
                // that are nearly the same music splits a section from its own tag.
                let b = bounds[i]
                // Sections usually start on a new chord; one starting mid-hold
                // (Verse 2 on Verse 1's held Em) needs evidence to stand.
                if h[b] != nil, h[b] == h[b - 1] { total += w.midHold }
                if b - phrase >= 0, b + phrase <= h.count {
                    let alike = (0..<phrase).reduce(0.0) { $0 + similarity(h[b - phrase + $1], h[b + $1]) } / Double(phrase)
                    total += alike * w.contrast
                }
            }
        }
        return (total, letters)
    }

    /// Every piece of boundary evidence: repeats (spread across a held chord
    /// at their start) and vocal entries and exits.
    nonisolated static func evidence(_ h: [Harmony?], span: Range<Int>, meter: Int, sung: [Bool]?,
                                     runs allRuns: [Run], model: [Int] = [],
                                     weights: Weights = .standard) -> [Int: Double] {
        var evidence = candidates(allRuns, weights: weights)
        // A repeat that begins on a held chord could begin anywhere in it: the
        // chord matches on both sides. Lend the evidence to each bar line in
        // the hold, and let cadence, vocals and phrase length choose.
        for (beat, weight) in evidence where weight >= 3 && span.contains(beat) && h[beat] != nil {
            var (lo, hi) = (beat, beat)
            while lo - 1 >= span.lowerBound, h[lo - 1] == h[beat] { lo -= 1 }
            while hi + 1 < span.upperBound, h[hi + 1] == h[beat] { hi += 1 }
            for other in stride(from: beat - meter * ((beat - lo) / meter), through: hi, by: meter) where other != beat {
                evidence[other] = max(evidence[other] ?? 0, weight * weights.spread)
            }
        }
        // Where singing starts or stops, a section usually does too. Singing
        // often enters a bar early, on a pickup into the section's downbeat
        // (Beautiful Day's verses come in on the B before the E), so an entry
        // also supports the next bar line; cadence and repeats choose between them.
        if let sung {
            for beat in span.dropFirst() where beat < sung.count && sung[beat] != sung[beat - 1] {
                evidence[beat, default: 0] += weights.vocal
                if sung[beat], span.contains(beat + meter) {
                    evidence[beat + meter, default: 0] += weights.vocal
                }
            }
        }
        // A model start goes to the nearest chord change within reach (a
        // section almost always opens on one), else stays on its own beat.
        for beat in model where span.contains(beat) && beat > span.lowerBound {
            let near = (max(span.lowerBound + 1, beat - weights.modelReach)...min(span.upperBound - 1, beat + weights.modelReach))
                .filter { h[$0] != nil && h[$0] != h[$0 - 1] }
            let target = near.min { abs($0 - beat) < abs($1 - beat) } ?? beat
            evidence[target, default: 0] += weights.model
        }
        return evidence
    }

    nonisolated static func plan(_ t: Timeline, key: Key, span: Range<Int>, meter: Int, sung: [Bool]? = nil,
                                 model: [Int] = [], weights: Weights = .standard) -> Plan {
        let h = t.harmony
        let layouts = LayoutCache(h: h, meter: meter)
        let allRuns = distinct(runs(h, in: span, minLag: phrase, minLength: phrase))
        let evidence = evidence(h, span: span, meter: meter, sung: sung, runs: allRuns, model: model, weights: weights)
        let loops = lineLoops(allRuns)

        // Start from the strong evidence only, the strongest candidate in each
        // neighbourhood; weaker candidates may still be inserted below.
        var picked: [Int] = []
        for beat in evidence.keys.sorted() where span.contains(beat) && beat > span.lowerBound + minSection / 2 {
            guard (evidence[beat] ?? 0) >= 3 else { continue }
            if loops.contains(where: { $0.lowerBound < beat && beat < $0.upperBound }) && (evidence[beat] ?? 0) < 6 { continue }
            if let last = picked.last, beat - last < minSection {
                if (evidence[beat] ?? 0) > (evidence[last] ?? 0) { picked[picked.count - 1] = beat }
                continue
            }
            picked.append(beat)
        }
        if let last = picked.last, span.upperBound - last < minSection { picked.removeLast() }
        // With the model, its starts are the boundaries, on the nearest bar
        // line; the search below may only take away the ones it can't justify.
        let modelLed = !model.isEmpty
        if modelLed {
            picked = []
            for beat in model {
                let bar = span.lowerBound + Int((Double(beat - span.lowerBound) / Double(meter)).rounded()) * meter
                guard bar > span.lowerBound, span.upperBound - bar >= meter,
                      bar - (picked.last ?? span.lowerBound) >= meter else { continue }
                picked.append(bar)
            }
        }
        var bounds = [span.lowerBound] + picked + [span.upperBound]

        // Where a boundary may move: chord changes and repeat starts nearby.
        let changeBeats = Set(span.filter { $0 > span.lowerBound && h[$0] != nil && h[$0] != h[$0 - 1] })
        let movable = changeBeats.union(evidence.keys.filter { span.contains($0) })

        // Steepest descent: every round tries every move and takes the best.
        // Taking the first improvement instead wanders into poor layouts, since
        // a single move that helps locally can block the coordinated one needed.
        var best = cost(h, key: key, bounds: bounds, evidence: evidence, layouts: layouts, weights: weights).0
        let seeds = evidence.keys.filter { span.contains($0) }.sorted()
        for _ in 0..<40 {
            var trials: [[Int]] = []
            // Move one boundary nearby.
            for i in 1..<(bounds.count - 1) where !modelLed {
                for beat in (bounds[i] - 12)...(bounds[i] + 12) where movable.contains(beat) && beat != bounds[i] {
                    guard beat - bounds[i - 1] >= minSection, bounds[i + 1] - beat >= minSection else { continue }
                    var trial = bounds
                    trial[i] = beat
                    trials.append(trial)
                }
            }
            // Shift a run of neighbouring boundaries together: two choruses that
            // both start a bar early only line up when both move.
            for a in 1..<max(1, bounds.count - 2) where !modelLed {
                for b in (a + 1)..<(bounds.count - 1) {
                    for delta in -12...12 where delta != 0 {
                        guard bounds[a] + delta - bounds[a - 1] >= minSection,
                              bounds[b + 1] - (bounds[b] + delta) >= minSection,
                              (a...b).allSatisfy({ movable.contains(bounds[$0] + delta) }) else { continue }
                        var trial = bounds
                        for k in a...b { trial[k] += delta }
                        trials.append(trial)
                    }
                }
            }
            // Drop a boundary.
            for i in 1..<max(1, bounds.count - 1) {
                var trial = bounds
                trial.remove(at: i)
                trials.append(trial)
            }
            // Add one near weaker evidence.
            for seed in seeds where !bounds.contains(seed) && !modelLed {
                guard let slot = bounds.firstIndex(where: { $0 > seed }), slot > 0 else { continue }
                for beat in (seed - 12)...(seed + 12) where movable.contains(beat) {
                    guard beat - bounds[slot - 1] >= minSection, bounds[slot] - beat >= minSection else { continue }
                    var trial = bounds
                    trial.insert(beat, at: slot)
                    trials.append(trial)
                }
            }
            var winner: [Int]?
            for trial in trials {
                let c = cost(h, key: key, bounds: trial, evidence: evidence, layouts: layouts, weights: weights).0
                if c < best - 1e-9 { best = c; winner = trial }
            }
            guard let winner else { break }
            bounds = winner
        }

        // A long passage that repeats nowhere may still be two phrases — an
        // intro then a prelude — when its harmonic rhythm changes halfway.
        var letters = cost(h, key: key, bounds: bounds, evidence: evidence, layouts: layouts, weights: weights).1
        var i = 0
        while i < bounds.count - 1 {
            let range = bounds[i]..<bounds[i + 1]
            let unique = letters.filter { $0 == letters[i] }.count == 1
            if unique, range.count >= 2 * phrase {
                // At the chord change where the rhythm changes most.
                let split = ((range.lowerBound + phrase)...max(range.lowerBound + phrase, range.upperBound - phrase))
                    .filter { h[$0] != nil && h[$0] != h[$0 - 1] }
                    .map { ($0, rhythmRatio(h, before: range.lowerBound..<$0, after: $0..<range.upperBound)) }
                    .filter { $0.1 >= 1.5 }
                    .max { $0.1 < $1.1 }?.0
                if let split {
                    bounds.insert(split, at: i + 1)
                    letters = cost(h, key: key, bounds: bounds, evidence: evidence, layouts: layouts, weights: weights).1
                    continue
                }
            }
            i += 1
        }
        return Plan(boundaries: bounds, letters: letters)
    }

    /// How many times faster the chords change in one passage than the other.
    nonisolated static func rhythmRatio(_ h: [Harmony?], before: Range<Int>, after: Range<Int>) -> Double {
        func rate(_ r: Range<Int>) -> Double { Double(changes(h, r) + 1) / Double(max(1, r.count)) }
        let a = rate(before), b = rate(after)
        return max(a, b) / min(a, b)
    }

    // MARK: - Names

    /// Roles from the pattern of repeats. The first repeated passage is the
    /// verse; the other passage that repeats most is the chorus. What happens
    /// once is an intro (and prelude) before them, an outro after, and an
    /// instrumental between, unless it is sung.
    nonisolated static func names(letters: [Int], sung: [Bool]? = nil) -> [String] {
        var counts: [Int: Int] = [:]
        for l in letters { counts[l, default: 0] += 1 }
        let repeated = letters.filter { counts[$0, default: 0] > 1 }
        let verse = repeated.first
        var chorus: Int?
        for l in repeated where l != verse {
            if chorus == nil || counts[l, default: 0] > counts[chorus!, default: 0] { chorus = l }
        }
        let firstRepeat = letters.firstIndex { counts[$0, default: 0] > 1 }
        let lastRepeat = letters.lastIndex { counts[$0, default: 0] > 1 }
        var roles: [String] = []
        for (i, l) in letters.enumerated() {
            // A verse or chorus played without singing is an instrumental.
            if (l == verse || l == chorus), sung?[i] == false { roles.append("Instrumental"); continue }
            if l == verse { roles.append("Verse"); continue }
            if l == chorus { roles.append("Chorus"); continue }
            if counts[l, default: 0] > 1 {
                let precedesChorus = letters.indices.filter { letters[$0] == l }
                    .allSatisfy { $0 + 1 < letters.count && letters[$0 + 1] == chorus }
                roles.append(precedesChorus ? "Pre-Chorus" : "Bridge")
                continue
            }
            if let firstRepeat, i < firstRepeat {
                roles.append(i == firstRepeat - 1 && i > 0 ? "Prelude" : "Intro")
            } else if let lastRepeat, i > lastRepeat {
                roles.append("Outro")
            } else if firstRepeat == nil {
                roles.append(i == 0 ? "Intro" : i == letters.count - 1 ? "Outro" : "Section")
            } else {
                roles.append(sung?[i] == true ? "Bridge" : "Instrumental")
            }
        }
        var totals: [String: Int] = [:]
        for r in roles { totals[r, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return roles.map { r in
            seen[r, default: 0] += 1
            return totals[r, default: 0] > 1 ? "\(r) \(seen[r]!)" : r
        }
    }

    // MARK: - Bars

    /// Bar lengths for one section. Bars are the meter long unless the chord
    /// changes need otherwise; a two-beat-longer bar belongs at the end of a
    /// phrase (a held chord before the next line), almost never first. Chords
    /// should change on a downbeat, or on the half bar — but a long chord that
    /// starts on the half bar and holds across the bar line means the bar lines
    /// are out of step with the music, and costs as much as an off-beat change.
    /// `changes` maps each change's offset to how many beats the new chord lasts.
    nonisolated static func layout(changes: [Int: Int], length: Int, meter: Int) -> [Int] {
        layoutWithCost(changes: changes, length: length, meter: meter).sizes
    }

    nonisolated static func layoutWithCost(changes: [Int: Int], length: Int, meter: Int) -> (sizes: [Int], cost: Double) {
        // A beat more or less than the meter is allowed too, but dearly: it is
        // usually a boundary a beat out, and should rarely survive the search.
        let sizes = Set([meter, meter + 2, meter - 2, meter + 1, meter - 1].filter { $0 >= 2 })
        let maxBars = length / 2 + 1
        var dp = [[Double]](repeating: [Double](repeating: .infinity, count: maxBars + 1), count: length + 1)
        var from = [[Int]](repeating: [Int](repeating: -1, count: maxBars + 1), count: length + 1)
        dp[0][0] = 0
        for p in 0..<length {
            for k in 0..<maxBars where dp[p][k].isFinite {
                for n in sizes where p + n <= length {
                    let last = p + n == length
                    var c = 0.0
                    if n == meter + 2 { c += k == 0 ? 4 : (last || (k + 1) % 4 == 0) ? 1 : 2.5 }
                    if n == meter - 2 { c += k == 0 ? 4 : last ? 1.5 : 3 }
                    if abs(n - meter) == 1 { c += 6 }
                    for offset in 1..<n {
                        guard let held = changes[p + offset] else { continue }
                        c += offset % 2 == 1 ? 1 : held >= meter ? 0.6 : 0.3
                    }
                    if dp[p][k] + c < dp[p + n][k + 1] {
                        dp[p + n][k + 1] = dp[p][k] + c
                        from[p + n][k + 1] = n
                    }
                }
            }
        }
        guard let k = dp[length].indices.min(by: { dp[length][$0] < dp[length][$1] }), dp[length][k].isFinite else {
            return (Array(repeating: meter, count: length / meter) + (length % meter > 0 ? [length % meter] : []), 50)
        }
        var sizesOut: [Int] = []
        var (p, bars) = (length, k)
        while p > 0 {
            let n = from[p][bars]
            sizesOut.append(n)
            p -= n
            bars -= 1
        }
        return (sizesOut.reversed(), dp[length][k])
    }

    nonisolated static func changeOffsets(_ h: [Harmony?], _ range: Range<Int>) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for beat in range.dropFirst() where h[beat] != nil && h[beat] != h[beat - 1] {
            var end = beat + 1
            while end < range.upperBound, h[end] == nil || h[end] == h[beat] { end += 1 }
            result[beat - range.lowerBound] = end - beat
        }
        return result
    }

    /// Layout costs by section range, shared across the search: the same
    /// candidate section comes up in thousands of trial layouts.
    nonisolated final class LayoutCache {
        let h: [Harmony?]
        let meter: Int
        var costs: [Int: Double] = [:]
        init(h: [Harmony?], meter: Int) { self.h = h; self.meter = meter }
        func cost(_ range: Range<Int>) -> Double {
            let id = range.lowerBound * 100_000 + range.upperBound
            if let known = costs[id] { return known }
            let c = SongForm.layoutWithCost(changes: SongForm.changeOffsets(h, range), length: range.count, meter: meter).cost
            costs[id] = c
            return c
        }
    }

    /// The chords of one bar. A beat with no chord continues the one before;
    /// a three-and-one split in four is evened to two and two, the common
    /// recognition error of a change a beat early or late.
    nonisolated static func barChords(_ names: [String?], before: String?) -> [BarChord] {
        var chords: [BarChord] = []
        var current = before
        for name in names {
            if let name { current = name }
            let label = current ?? "N.C."
            if let last = chords.last, last.name == label {
                chords[chords.count - 1].beats += 1
            } else {
                chords.append(BarChord(name: label, beats: 1))
            }
        }
        if names.count == 4, chords.count == 2, Set(chords.map(\.beats)) == [1, 3] {
            chords[0].beats = 2
            chords[1].beats = 2
        }
        return chords
    }

    nonisolated static func structure(_ chords: [BarChord]) -> String {
        guard chords.count > 1 else { return "1fr" }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let divisor = chords.map(\.beats).reduce(0, gcd)
        return chords.map { "\($0.beats / max(1, divisor))fr" }.joined(separator: " ")
    }

    // MARK: - Analysis

    /// The full analysis. `downbeat` is the index of a beat known to start a
    /// bar (the detected or chosen pickup); bar 1 is the first such beat at or
    /// after the first chord, and anything before it is a pickup. `sung` is
    /// optional vocal evidence per beat.
    /// Singing from `start` until the next span begins, from vocal analysis.
    nonisolated struct VocalSpan: Sendable {
        var start: Double
        var sung: Bool
    }

    /// A section the trained structure model found: where it starts and what
    /// the model calls it (verse, chorus, solo, ...).
    nonisolated struct ModelSection: Sendable, Equatable {
        var start: Double
        var label: String
    }

    nonisolated static func analyse(beatTimes: [Double], chords: [ChordSpan], audioEnd: Double?,
                                    meter: Int = 4, downbeat: Int = 0, vocals: [VocalSpan]? = nil,
                                    model: [ModelSection]? = nil, weights: Weights = .standard) -> Result? {
        let t = timeline(beatTimes: beatTimes, chords: chords, audioEnd: audioEnd)
        guard let firstChord = t.harmony.firstIndex(where: { $0 != nil }),
              let lastChord = t.harmony.lastIndex(where: { $0 != nil }) else { return nil }
        let phase = ((downbeat % meter) + meter) % meter
        let first = firstChord + ((phase - firstChord % meter) % meter + meter) % meter
        // A final chord may ring on for up to a bar after it is last detected.
        let end = min(t.count, lastChord + 1 + meter)
        guard first < end else { return nil }
        let span = first..<end
        guard span.count >= 2 * phrase else { return nil }
        var key = estimateKey(Array(t.harmony[span]))
        var sharps = 0, flats = 0
        for name in t.names[span].compactMap({ $0 }) where name.count > 1 {
            let accidental = name[name.index(after: name.startIndex)]
            if accidental == "#" { sharps += 1 } else if accidental == "b" { flats += 1 }
        }
        key.spelling = sharps > flats ? .sharps : flats > sharps ? .flats : .conventional
        let spelt = key.accidental.map { accidental in t.names.map { $0.map { respelled($0, accidental: accidental) } } } ?? t.names
        let sortedVocals = (vocals ?? []).sorted { $0.start < $1.start }
        let sungBeats: [Bool]? = sortedVocals.isEmpty ? nil : (0..<t.count).map { beat in
            let middle = (t.edges[beat] + t.edges[beat + 1]) / 2
            return sortedVocals.last { $0.start <= middle }?.sung ?? false
        }
        // The model's starts, where its label changes (it splits a long
        // section into same-label pieces), on the nearest beat.
        let modelBeats: [Int] = zip(model ?? [], (model ?? []).dropFirst()).compactMap { previous, section in
            guard previous.label != section.label else { return nil }
            return (0..<t.count).min { abs(t.edges[$0] - section.start) < abs(t.edges[$1] - section.start) }
        }
        var plan = plan(t, key: key, span: span, meter: meter, sung: sungBeats, model: modelBeats, weights: weights)
        plan.letters = transposedLetters(t.harmony, bounds: plan.boundaries, letters: plan.letters)
        let sung: [Bool]? = sungBeats.map { beats in
            (0..<(plan.boundaries.count - 1)).map { i in
                let r = plan.boundaries[i]..<plan.boundaries[i + 1]
                return r.filter { $0 < beats.count && beats[$0] }.count * 2 > r.count
            }
        }
        let sectionNames = names(letters: plan.letters, sung: sung)

        var sections: [Section] = []
        var previous: String?
        for i in 0..<(plan.boundaries.count - 1) {
            let range = plan.boundaries[i]..<plan.boundaries[i + 1]
            var bars: [Bar] = []
            var p = range.lowerBound
            for n in layout(changes: changeOffsets(t.harmony, range), length: range.count, meter: meter) {
                let chords = barChords(Array(spelt[p..<(p + n)]), before: previous)
                previous = chords.last?.name
                bars.append(Bar(startBeat: p, beats: n, start: t.edges[p], end: t.edges[p + n],
                                chords: chords, structure: structure(chords)))
                p += n
            }
            sections.append(Section(name: sectionNames[i], letter: letterName(plan.letters[i]),
                                    startBeat: range.lowerBound, endBeat: range.upperBound, bars: bars))
        }
        return Result(key: key.name, meter: meter, sections: sections, beatEdges: t.edges)
    }

    /// A chord name with its root and bass note written in the key's
    /// accidental: C# becomes Db in A♭. A bass given as a degree ("/b3") stays.
    nonisolated static func respelled(_ name: String, accidental: Character) -> String {
        let names = accidental == "#" ? sharpKeyNames : flatKeyNames
        func note(_ part: Substring) -> String {
            guard let letter = part.first, "ABCDEFG".contains(letter) else { return String(part) }
            var root = String(letter)
            if let next = part.dropFirst().first, next == "#" || next == "b" { root.append(next) }
            guard let pitch = pitchClasses[root] else { return String(part) }
            return names[pitch] + part.dropFirst(root.count)
        }
        return name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(note).joined(separator: "/")
    }

    nonisolated static func letterName(_ index: Int) -> String {
        index < 26 ? String(UnicodeScalar(65 + index)!) : "Z\(index)"
    }

    /// Reads the job's own files: detected beats and cleaned chords.
    nonisolated static func analyse(beatData: Data, cleanedChordData: Data, audioEnd: Double?,
                                    meter: Int = 4, downbeat: Int = 0, vocals: [VocalSpan]? = nil,
                                    model: [ModelSection]? = nil, weights: Weights = .standard) -> Result? {
        guard let beatJSON = try? JSONSerialization.jsonObject(with: beatData) as? [String: Any],
              let rawBeats = beatJSON["beats"] as? [[String: Any]],
              let chordJSON = try? JSONSerialization.jsonObject(with: cleanedChordData) as? [String: Any],
              let rawChords = chordJSON["chords"] as? [[String: Any]] else { return nil }
        let beats = rawBeats.compactMap { ($0["time"] as? NSNumber)?.doubleValue }
        let chords: [ChordSpan] = rawChords.compactMap { c in
            guard let name = c["displayChord"] as? String,
                  let start = (c["start"] as? NSNumber)?.doubleValue,
                  let end = (c["end"] as? NSNumber)?.doubleValue, end > start else { return nil }
            return ChordSpan(name: name, start: start, end: end)
        }
        return analyse(beatTimes: beats, chords: chords, audioEnd: audioEnd, meter: meter, downbeat: downbeat,
                       vocals: vocals, model: model, weights: weights)
    }

    /// The model's sections (start, end and label) from the backend's
    /// structure response (`modelSegments`) or a saved model run (`segments`),
    /// without its "start" and "end" markers; nil when there are none.
    nonisolated static func modelSections(from data: Data) -> [ModelSection]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = (json["modelSegments"] ?? json["segments"]) as? [[String: Any]] else { return nil }
        let sections: [ModelSection] = segments.compactMap { segment in
            guard let start = (segment["start"] as? NSNumber)?.doubleValue, let label = segment["label"] as? String,
                  label != "start", label != "end" else { return nil }
            return ModelSection(start: start, label: label)
        }
        return sections.isEmpty ? nil : sections
    }

    /// Sung and unsung spans from the backend's structure response, when its
    /// vocal analysis ran; nil otherwise.
    /// Per-bar activity (`barVocals`) where the backend sends it; otherwise the
    /// sung flag of each of its coarse sections.
    nonisolated static func vocals(fromStructure data: Data) -> [VocalSpan]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let bars = json["barVocals"] as? [[String: Any]], !bars.isEmpty {
            var spans: [VocalSpan] = []
            for bar in bars {
                guard let start = (bar["start"] as? NSNumber)?.doubleValue, let sung = bar["sung"] as? Bool else { return nil }
                if spans.last?.sung != sung { spans.append(VocalSpan(start: start, sung: sung)) }
            }
            return spans
        }
        guard let boundaries = json["boundaries"] as? [[String: Any]], !boundaries.isEmpty else { return nil }
        let spans: [VocalSpan] = boundaries.compactMap { b in
            guard let time = (b["time"] as? NSNumber)?.doubleValue, let sung = b["sung"] as? Bool else { return nil }
            return VocalSpan(start: time, sung: sung)
        }
        return spans.count == boundaries.count ? spans : nil
    }
}
