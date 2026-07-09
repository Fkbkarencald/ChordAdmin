import XCTest
@testable import ChordAdmin

final class BeatGridGeneratorTests: XCTestCase {
    func testBeatsPerBarFromTimeSignature() {
        XCTAssertEqual(BeatGridGenerator.beatsPerBar(fromTimeSignature: "4/4"), 4)
        XCTAssertEqual(BeatGridGenerator.beatsPerBar(fromTimeSignature: "3/4"), 3)
        XCTAssertEqual(BeatGridGenerator.beatsPerBar(fromTimeSignature: "6/8"), 6)
        XCTAssertEqual(BeatGridGenerator.beatsPerBar(fromTimeSignature: nil), 4)
        XCTAssertEqual(BeatGridGenerator.beatsPerBar(fromTimeSignature: "invalid"), 4)
    }

    func testEffectiveBeatsPerBarUsesOverride() throws {
        let beatData = try sampleBeatData(timeSignature: "3/4")
        XCTAssertEqual(BeatGridGenerator.effectiveBeatsPerBar(override: 4, beatData: beatData), 4)
        XCTAssertEqual(BeatGridGenerator.effectiveBeatsPerBar(override: nil, beatData: beatData), 3)
    }

    func testGenerateBeatGridGroupsFourBeatsPerBarByDefault() throws {
        let beatData = try sampleBeatData(beats: [0.0, 0.5, 1.0, 1.5, 2.0, 2.5])
        let (payload, barCount) = BeatGridGenerator.generateBeatGrid(from: beatData, bpm: 120, beatsPerBar: 4)

        XCTAssertEqual(barCount, 2)
        XCTAssertEqual(payload["estimatedTimeSignature"] as? String, "4/4")
        XCTAssertEqual(payload["beatsPerBar"] as? Int, 4)

        let bars = payload["bars"] as? [[String: Any]] ?? []
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0]["bar"] as? Int, 1)
        XCTAssertEqual(bars[1]["bar"] as? Int, 2)
    }

    func testGenerateBeatGridSupportsThreeFour() throws {
        let beatData = try sampleBeatData(beats: [0.0, 0.5, 1.0, 1.5, 2.0], timeSignature: "3/4")
        let beatsPerBar = BeatGridGenerator.effectiveBeatsPerBar(override: nil, beatData: beatData)
        let (_, barCount) = BeatGridGenerator.generateBeatGrid(from: beatData, bpm: 120, beatsPerBar: beatsPerBar)

        XCTAssertEqual(beatsPerBar, 3)
        XCTAssertEqual(barCount, 2)
    }

    private func sampleBeatData(beats: [Double] = [0.0, 0.5, 1.0, 1.5], timeSignature: String? = nil) throws -> Data {
        var json: [String: Any] = [
            "bpm": 120,
            "beats": beats.map { ["time": $0] },
        ]
        if let timeSignature { json["timeSignature"] = timeSignature }
        return try JSONSerialization.data(withJSONObject: json)
    }
}
