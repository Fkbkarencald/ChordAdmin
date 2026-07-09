import XCTest
@testable import ChordAdmin

final class YouTubeURLUtilsTests: XCTestCase {
    func testCleanYouTubeURLRemovesListParameter() {
        let raw = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLtest"
        XCTAssertEqual(
            YouTubeURLUtils.cleanYouTubeURL(raw),
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
    }

    func testCleanYouTubeURLPreservesNonYouTubeURLs() {
        let raw = "https://example.com/watch?v=abc&list=xyz"
        XCTAssertEqual(YouTubeURLUtils.cleanYouTubeURL(raw), raw)
    }

    func testYouTubeVideoIDFromWatchURL() {
        XCTAssertEqual(
            YouTubeURLUtils.youTubeVideoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            "dQw4w9WgXcQ"
        )
    }

    func testYouTubeVideoIDFromShortURL() {
        XCTAssertEqual(
            YouTubeURLUtils.youTubeVideoID(from: "https://youtu.be/dQw4w9WgXcQ"),
            "dQw4w9WgXcQ"
        )
    }

    func testYouTubeVideoIDReturnsNilForInvalidURL() {
        XCTAssertNil(YouTubeURLUtils.youTubeVideoID(from: "not a url"))
    }
}
