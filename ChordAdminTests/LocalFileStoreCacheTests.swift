import XCTest
@testable import ChordAdmin

final class LocalFileStoreCacheTests: XCTestCase {
    func testCachedJobValidRequiresMatchingPipelineVersion() {
        var job = sampleCompletedJob()
        job.analysisPipelineVersion = AppConfig.analysisPipelineVersion
        XCTAssertTrue(LocalFileStore.isCachedJobValid(job))

        job.analysisPipelineVersion = AppConfig.analysisPipelineVersion - 1
        XCTAssertFalse(LocalFileStore.isCachedJobValid(job))

        job.analysisPipelineVersion = nil
        XCTAssertFalse(LocalFileStore.isCachedJobValid(job))
    }

    func testCachedJobValidRequiresCompletedStatus() {
        var job = sampleCompletedJob()
        job.analysisPipelineVersion = AppConfig.analysisPipelineVersion

        job.status = .failed
        XCTAssertFalse(LocalFileStore.isCachedJobValid(job))

        job.status = .completedWithWarnings
        XCTAssertTrue(LocalFileStore.isCachedJobValid(job))
    }

    private func sampleCompletedJob() -> AnalysisJob {
        AnalysisJob(
            id: "test",
            sourceUrl: "https://youtu.be/abc",
            status: .completed,
            createdAt: Date()
        )
    }
}
