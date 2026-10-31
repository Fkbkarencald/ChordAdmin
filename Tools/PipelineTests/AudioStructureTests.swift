import Foundation

@MainActor
func runAudioStructureTests() {
    section("Audio-informed section boundaries")
    let bars: [[String: Any]] = (1...16).map { ["bar": $0, "start": Double($0 - 1) * 2, "end": Double($0) * 2] }
    let performer = try! JSONSerialization.data(withJSONObject: ["bars": bars])
    let audio: [String: Any] = ["status": "success", "version": 1, "method": "multiscale-audio-novelty",
                              "boundaries": [["bar": 1, "time": 0.0, "score": 1.0],
                                             ["bar": 9, "time": 16.0, "score": 0.8]]]
    let evidence = try! JSONSerialization.data(withJSONObject: audio)
    let original: [String: Any] = ["candidates": [["label": "A", "startBar": 1, "endBar": 4,
                                                  "barCount": 4, "matchCount": 4]]]
    let merged = JobManager.addingAudioBoundaries(evidence, to: original, performerData: performer)!
    check((merged["candidates"] as? [[String: Any]])?.count == 1, "audio evidence keeps chord repeats available")
    let sections = JobManager.sectionsFromAudioBoundaries(merged, allBars: Array(1...16))!
    check(sections.count == 2 && sections[0].bars == Array(1...8) && sections[1].bars == Array(9...16),
          "sustained audio change makes two sections instead of splitting each repeating chord loop")
    check(sections.map(\.name) == ["Section A", "Section B"], "acoustic evidence does not invent verse/chorus roles")
    let generated = JobManager.generateInitialSections(performerData: performer, candidatesPayload: merged,
                                                       performerPath: "chart", candidatesPath: "candidates")
    check(generated.sectionCount == 2, "initial analysis uses audio boundaries when present")
    let shiftedBars = bars.map { bar -> [String: Any] in
        var shifted = bar; shifted["start"] = (bar["start"] as! Double) + 0.5
        shifted["end"] = (bar["end"] as! Double) + 0.5; return shifted
    }
    let shifted = try! JSONSerialization.data(withJSONObject: ["bars": shiftedBars])
    let remapped = JobManager.addingAudioBoundaries(evidence, to: original, performerData: shifted)!
    check((remapped["audioBoundaries"] as? [[String: Any]])?.last?["bar"] as? Int == 9,
          "pickup correction re-snaps boundary times to the current chart")
    var broken = audio
    broken["version"] = 999
    check(JobManager.addingAudioBoundaries(try! JSONSerialization.data(withJSONObject: broken), to: original,
                                          performerData: performer) == nil, "unknown structure versions are refused")
    var repetition = audio
    repetition["version"] = 2
    repetition["method"] = "bar-repetition-novelty"
    let repetitionMerged = JobManager.addingAudioBoundaries(try! JSONSerialization.data(withJSONObject: repetition),
                                                            to: original, performerData: performer)
    check(repetitionMerged?["sectionMethod"] as? String == "bar-repetition-novelty"
          && repetitionMerged.flatMap { JobManager.sectionsFromAudioBoundaries($0, allBars: Array(1...16)) }?.count == 2,
          "repetition-aware structure responses become sections")
    repetition["boundaries"] = [["bar": 1, "time": 0.0, "score": 1.0, "label": "A"],
                                ["bar": 5, "time": 8.0, "score": 0.7, "label": "B"],
                                ["bar": 9, "time": 16.0, "score": 0.8, "label": "A"]]
    let labelled = JobManager.addingAudioBoundaries(try! JSONSerialization.data(withJSONObject: repetition),
                                                    to: original, performerData: performer)
    check(labelled.flatMap { JobManager.sectionsFromAudioBoundaries($0, allBars: Array(1...16)) }?.map(\.name)
          == ["Section A", "Section B", "Section A"],
          "repeated material keeps the backend's shared section letter")
    repetition["boundaries"] = [["bar": 1, "time": 0.0, "score": 1.0, "label": "A", "name": "Intro"],
                                ["bar": 5, "time": 8.0, "score": 0.7, "label": "B", "name": "Verse 1"],
                                ["bar": 9, "time": 16.0, "score": 0.8, "label": "B", "name": "Verse 2"]]
    let named = JobManager.addingAudioBoundaries(try! JSONSerialization.data(withJSONObject: repetition),
                                                 to: original, performerData: performer)
    check(named.flatMap { JobManager.sectionsFromAudioBoundaries($0, allBars: Array(1...16)) }?.map(\.name)
          == ["Intro", "Verse 1", "Verse 2"],
          "role names from the backend become the section names")
    repetition["boundaries"] = [["bar": 1, "time": 0.0, "score": 1.0, "label": "A"],
                                ["bar": 9, "time": 16.0, "score": 0.8]]
    let partial = JobManager.addingAudioBoundaries(try! JSONSerialization.data(withJSONObject: repetition),
                                                   to: original, performerData: performer)
    check(partial.flatMap { JobManager.sectionsFromAudioBoundaries($0, allBars: Array(1...16)) }?.map(\.name)
          == ["Section A", "Section B"],
          "a response missing any label falls back to sequential letters")
    repetition["method"] = "multiscale-audio-novelty"
    check(JobManager.addingAudioBoundaries(try! JSONSerialization.data(withJSONObject: repetition), to: original,
                                          performerData: performer) == nil,
          "a structure method reported under another version is refused")
    broken = audio; broken["boundaries"] = [["time": 16.0, "score": 0.8], ["time": 0.0, "score": 1.0]]
    check(JobManager.addingAudioBoundaries(try! JSONSerialization.data(withJSONObject: broken), to: original,
                                          performerData: performer) == nil, "out-of-order boundaries are refused")
    broken = audio; broken["boundaries"] = [["time": 0.0, "score": 1.1]]
    check(JobManager.addingAudioBoundaries(try! JSONSerialization.data(withJSONObject: broken), to: original,
                                          performerData: performer) == nil, "invalid boundary scores are refused")
    check(JobManager.sectionsFromAudioBoundaries(["sectionMethod": "multiscale-audio-novelty",
          "audioBoundaries": [["bar": 9]]], allBars: Array(1...16)) == nil, "partial section coverage is refused")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let chartPath = folder.appendingPathComponent("chart.json"), candidatePath = folder.appendingPathComponent("candidates.json")
    try! performer.write(to: chartPath)
    try! JSONSerialization.data(withJSONObject: merged).write(to: candidatePath)
    let stored = SectionsFile(source: .init(chordChartPerformerPath: chartPath.path, sectionCandidatesPath: candidatePath.path),
                              sections: [ChordSection(id: "mine", name: "Owner's verse", startBar: 1, endBar: 16, bars: Array(1...16))])
    let saved = try! JSONEncoder().encode(stored)
    let sectionsPath = folder.appendingPathComponent("sections.json"); try! saved.write(to: sectionsPath)
    var job = AnalysisJob(id: "audio-structure-fixture", sourceUrl: "https://youtu.be/fixture",
                          status: .completed, createdAt: Date())
    job.chordChartPerformerPath = chartPath.path; job.sectionCandidatesPath = candidatePath.path
    let store = SectionStore(); store.load(for: job, jobFolder: folder)
    check(store.sections.first?.name == "Owner's verse" && store.sections.count == 1,
          "loading new audio suggestions preserves the owner's saved section names and ranges")
    check((try? Data(contentsOf: sectionsPath)) == saved, "opening suggestions leaves saved section bytes untouched")
    store.autoDetectSections(for: job)
    check(store.sections.count == 2, "explicit section re-detection can apply acoustic boundaries")
}
