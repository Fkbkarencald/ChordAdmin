import XCTest
@testable import ChordAdmin

final class ToolCheckerTests: XCTestCase {
    func testSearchLocationsIncludesCommonDirectories() {
        let locations = ToolChecker.searchLocations(for: "ffmpeg")
        XCTAssertTrue(locations.contains("/opt/homebrew/bin/ffmpeg"))
        XCTAssertTrue(locations.contains("/usr/local/bin/ffmpeg"))
        XCTAssertTrue(locations.contains("/usr/bin/ffmpeg"))
    }

    func testResolveToolReturnsFirstSearchLocationWhenNotFound() {
        let resolved = ToolChecker.resolveTool("definitely-not-a-real-binary-name-12345")
        XCTAssertEqual(resolved, "/opt/homebrew/bin/definitely-not-a-real-binary-name-12345")
    }

    func testResolveToolFindsSystemBinary() {
        let resolved = ToolChecker.resolveTool("echo")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved))
        XCTAssertTrue(resolved.hasSuffix("/echo"))
    }
}
