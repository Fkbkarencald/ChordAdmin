import XCTest
@testable import ChordAdmin

final class ChordOverlapLogicTests: XCTestCase {
    func testOverlappingChordsReturnsPositiveOverlapsOnly() {
        let chords: [[String: Any]] = [
            ["start": 0.0, "end": 1.0, "displayChord": "C"],
            ["start": 1.5, "end": 3.0, "displayChord": "G"],
            ["start": 4.0, "end": 5.0, "displayChord": "Am"],
        ]

        let overlaps = ChordOverlapLogic.overlappingChords(barStart: 0.0, barEnd: 2.0, chords: chords)
        XCTAssertEqual(overlaps.count, 2)
        XCTAssertEqual(overlaps[0].displayChord, "C")
        XCTAssertEqual(overlaps[1].displayChord, "G")
    }

    func testPrimaryChordChoosesLongestOverlap() {
        let overlaps = [
            ChordOverlapResult(displayChord: "C", start: 0.0, end: 0.4, overlapSeconds: 0.4),
            ChordOverlapResult(displayChord: "G", start: 0.4, end: 2.0, overlapSeconds: 1.6),
        ]
        XCTAssertEqual(ChordOverlapLogic.primaryChord(from: overlaps), "G")
    }

    func testNoOverlapReturnsEmpty() {
        let chords: [[String: Any]] = [
            ["start": 5.0, "end": 6.0, "displayChord": "D"],
        ]
        XCTAssertTrue(ChordOverlapLogic.overlappingChords(barStart: 0.0, barEnd: 2.0, chords: chords).isEmpty)
    }
}
