import Foundation

@MainActor
func runBeatAlignmentTests() {
    section("Detected downbeat alignment")

    func phaseData(_ positions: [Int], metre: Int = 4, alias: Bool = false,
                   suggested: Any? = nil, times: [Double]? = nil) -> Data {
        let beats = positions.enumerated().map { index, position -> [String: Any] in
            ["time": times?[index] ?? Double(index) * 0.5,
             alias ? "position" : "beatInBar": position]
        }
        var payload: [String: Any] = ["beats": beats, "beatsPerBar": metre]
        if let suggested { payload["suggestedPickupBeats"] = suggested }
        return try! JSONSerialization.data(withJSONObject: payload)
    }
    let twoPickup = phaseData([3, 4, 1, 2, 3, 4, 1, 2], suggested: 2)
    check(JobManager.inferredBeatAlignment(from: twoPickup) == 2,
          "detected beat positions identify two pickup beats")
    let noPickup = phaseData([1, 2, 3, 4, 1, 2, 3, 4])
    check(JobManager.inferredBeatAlignment(from: noPickup) == 0,
          "a detected first downbeat needs no pickup")
    let threeFour = phaseData([2, 3, 1, 2, 3, 1], metre: 3)
    check(JobManager.inferredBeatAlignment(from: threeFour, beatsPerBar: 3) == 2,
          "three-beat phase proposals use the requested metre")
    check(JobManager.inferredBeatAlignment(from: threeFour) == nil,
          "a proposal from another metre is refused")
    check(JobManager.inferredBeatAlignment(from: phaseData([4, 1, 2, 3, 4, 1], alias: true)) == 1,
          "the compatible position alias also identifies pickup")

    var job = AnalysisJob(id: "alignment", sourceUrl: "u", status: .completed, createdAt: Date())
    check(JobManager.resolvedBeatOffset(job: job, beatData: twoPickup) == 2,
          "a new job adopts a validated detected pickup")
    job.barAlignmentOffset = 1
    check(JobManager.resolvedBeatOffset(job: job, beatData: twoPickup) == 1,
          "an existing pickup choice wins over new detection")
    job.barAlignmentOffset = 0
    check(JobManager.resolvedBeatOffset(job: job, beatData: twoPickup) == 0,
          "an explicit legacy zero remains an explicit choice")
    job.barAlignmentOffset = 99
    check(JobManager.resolvedBeatOffset(job: job, beatData: twoPickup) == 3,
          "saved pickup values clamp to the current metre")
    job.barAlignmentOffset = nil
    job.beatsPerBarOverride = 3
    check(JobManager.resolvedBeatOffset(job: job, beatData: threeFour) == 2,
          "job metre overrides are shared by proposal resolution")

    check(JobManager.inferredBeatAlignment(from: makeBeatData()) == nil,
          "legacy beat-only payloads do not invent downbeat evidence")
    check(JobManager.inferredBeatAlignment(from: phaseData([3, 4, 1, 2])) == nil,
          "an incomplete first full bar is insufficient alignment evidence")
    check(JobManager.inferredBeatAlignment(from: phaseData([3, 4, 1, 3, 4, 1, 2, 3])) == nil,
          "a skipped beat phase invalidates the complete proposal")
    check(JobManager.inferredBeatAlignment(from: phaseData([3, 4, 1, 2, 3, 4], suggested: 1)) == nil,
          "conflicting suggested pickup metadata is refused")
    check(JobManager.inferredBeatAlignment(from: phaseData([1, 2, 3, 4], suggested: true)) == nil,
          "boolean pickup metadata is not interpreted as beat one")
    check(JobManager.inferredBeatAlignment(from: phaseData([1, 2, 3, 4],
          times: [0, 0.5, 0.5, 1.5])) == nil,
          "duplicate beat timestamps invalidate phase evidence")
    check(JobManager.inferredBeatAlignment(from: phaseData([1, 2, 3, 4],
          times: [0, 1, 0.5, 1.5])) == nil,
          "backwards beat timestamps invalidate phase evidence")
    check(JobManager.inferredBeatAlignment(from: phaseData([1, 2, 3, 4],
          times: [-0.5, 0, 0.5, 1])) == nil,
          "negative beat timestamps are refused")
    let invalidNumber = Data("{\"beats\":[{\"time\":NaN,\"beatInBar\":1}]}".utf8)
    check(JobManager.inferredBeatAlignment(from: invalidNumber) == nil,
          "nonfinite JSON timestamps cannot become an alignment")
    let contradictoryAlias = Data("{\"beats\":[{\"time\":0,\"beatInBar\":1,\"position\":2},{\"time\":1,\"beatInBar\":2},{\"time\":2,\"beatInBar\":3},{\"time\":3,\"beatInBar\":4}]}".utf8)
    check(JobManager.inferredBeatAlignment(from: contradictoryAlias) == nil,
          "conflicting phase aliases are refused")
    check(JobManager.inferredBeatAlignment(from: phaseData([1, 2, 3, 4]), beatsPerBar: 6) == nil,
          "unsupported compound-metre proposals fall back safely")

    section("Pickup across a replaced beat track")
    // The new track starts a beat later than the one the pickup was counted in.
    let shifted = phaseData([4, 1, 2, 3, 4, 1, 2, 3], times: (0..<8).map { 0.75 + Double($0) * 0.5 })
    check(JobManager.anchoredBeatOffset(barOneTime: 1.75, beatData: shifted, beatsPerBar: 4) == 2,
          "a manual bar 1 time maps onto whichever beat of the new track lands there")
    check(JobManager.anchoredBeatOffset(barOneTime: 1.5, beatData: shifted, beatsPerBar: 4) == nil,
          "a bar 1 time between beats of the new track is not forced onto either")
    check(JobManager.anchoredBeatOffset(barOneTime: 9.0, beatData: shifted, beatsPerBar: 4) == nil,
          "a bar 1 time outside the new track is not anchored")

    var detected = AnalysisJob(id: "replaced", sourceUrl: "u", status: .completed, createdAt: Date())
    detected.barAlignmentOffset = 2
    JobManager.resetAlignmentForNewBeats(&detected, previousBarOneTime: 1.0)
    check(detected.barAlignmentOffset == nil && detected.manualBarOneTime == nil
          && JobManager.resolvedBeatOffset(job: detected, beatData: shifted) == 1,
          "without a manual choice the new track's detected downbeat replaces the old count")

    var manual = AnalysisJob(id: "replaced-manual", sourceUrl: "u", status: .completed, createdAt: Date())
    manual.barAlignmentOffset = 3
    manual.pickupChosenManually = true
    JobManager.resetAlignmentForNewBeats(&manual, previousBarOneTime: 1.75)
    check(manual.barAlignmentOffset == nil && manual.manualBarOneTime == 1.75
          && JobManager.resolvedBeatOffset(job: manual, beatData: shifted) == 2,
          "a manual pickup keeps bar 1 at the same time on the new track")

    var unanchored = AnalysisJob(id: "replaced-unanchored", sourceUrl: "u", status: .completed, createdAt: Date())
    unanchored.barAlignmentOffset = 3
    unanchored.pickupChosenManually = true
    JobManager.resetAlignmentForNewBeats(&unanchored, previousBarOneTime: nil)
    check(unanchored.barAlignmentOffset == 3,
          "a manual pickup with no recoverable bar 1 time is left exactly as saved")
}
