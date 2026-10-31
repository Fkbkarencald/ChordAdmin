import Combine
import Foundation

@MainActor
protocol SongImportProcessingStore: AnyObject {
    func load(_ id: String) async throws -> SongImportRecord
    func markStep(_ step: SongImportProcessingStep, state: SongImportStepState,
                  error: String?, in record: SongImportRecord) async throws
    func queueRetry(_ record: SongImportRecord) async throws -> [SongImportProcessingStep]
    func beginProcessing(_ record: SongImportRecord, fresh: Bool) async throws
    func attachPayload(_ payload: Data, to record: SongImportRecord) async throws
}

/// Uses the same serial engine as library analyses. The Firestore record is the
/// durable review history; local job folders retain actual successful outputs.
@MainActor
final class SongImportProcessing: ObservableObject {
    @Published private(set) var activeIDs: Set<String> = []
    @Published var message: String?
    private var tasks: [String: Task<Void, Never>] = [:]

    func start(_ record: SongImportRecord, jobs: JobManager, store: any SongImportProcessingStore,
               retry: Bool = false, from stage: PipelineStage? = nil, fresh: Bool = false) {
        guard tasks[record.id] == nil else { return }
        tasks[record.id] = Task { [weak self] in
            await self?.process(record, jobs: jobs, store: store, retry: retry, from: stage, fresh: fresh)
            self?.tasks.removeValue(forKey: record.id)
        }
    }

    func cancelAll(jobs: JobManager) {
        for (id, task) in tasks {
            task.cancel()
            let workspaceID = "staging-" + id
            if jobs.isRunning(workspaceID) { jobs.cancelRun() }
            jobs.removeFromQueue(workspaceID)
        }
    }

    func process(_ record: SongImportRecord, jobs: JobManager,
                 store: any SongImportProcessingStore, retry: Bool = false,
                 from requestedStage: PipelineStage? = nil, fresh: Bool = false) async {
        guard !activeIDs.contains(record.id) else { return }
        activeIDs.insert(record.id)
        defer { activeIDs.remove(record.id) }
        do {
            let current = try await store.load(record.id)
            guard current.status == .staged else { throw SongImportWorkflowError.notReviewable }
            guard SongImportSource(url: current.source.url).stableIdentifier != nil else {
                throw SongImportWorkflowError.validationWarningsRemain
            }
            if retry, current.mediaStatus.contains(where: { $0.state == .failed }) {
                _ = try await store.queueRetry(current)
            }
            let savedJob = jobs.job(for: current.workspaceID)
            let firstFailure = requestedStage ?? savedJob?.stageReport.firstFailure?.stage
            if fresh {
                try await store.beginProcessing(current, fresh: true)
                jobs.start(current.ref, resumeIfPossible: false)
            } else if let firstFailure, savedJob != nil {
                try await store.beginProcessing(current, fresh: false)
                jobs.retry(from: firstFailure, for: current.ref)
            } else if savedJob?.isExportable != true {
                try await store.beginProcessing(current, fresh: false)
                jobs.start(current.ref, resumeIfPossible: true)
            }
            var lastStates: [SongImportProcessingStep: SongImportStepState] = [:]
            while true {
                try Task.checkCancellation()
                if let job = jobs.job(for: current.workspaceID) {
                    for progress in Self.progress(job) where lastStates[progress.step] != progress.state {
                        try await store.markStep(progress.step, state: progress.state,
                                                 error: progress.redactedError, in: current)
                        lastStates[progress.step] = progress.state
                    }
                }
                if !jobs.isRunning(current.workspaceID), jobs.queuePosition(of: current.workspaceID) == nil { break }
                try await Task.sleep(for: .milliseconds(150))
            }
            guard let job = jobs.job(for: current.workspaceID), job.isExportable else {
                let error = jobs.persistenceError ?? jobs.job(for: current.workspaceID)?.backendErrorMessage
                    ?? jobs.job(for: current.workspaceID)?.errorMessage ?? "Analysis paused. Resume it when ready."
                message = SongImportRedactor.redact(error)
                return
            }
            // Cleanup means the job and outputs are durably recorded, never
            // deletion of the audio or chart the owner is about to review.
            do {
                guard let folder = jobs.folder(for: current.workspaceID) else { throw SongImportWorkflowError.processingIncomplete }
                try Self.validateSavedOutputs(job, folder: folder)
                try await store.markStep(.cleanup, state: .succeeded, error: nil, in: current)
            } catch {
                try await store.markStep(.cleanup, state: .failed, error: error.localizedDescription, in: current)
                throw error
            }
            do {
                try await store.markStep(.translation, state: .running, error: nil, in: current)
                guard let folder = jobs.folder(for: current.workspaceID) else {
                    throw SongImportWorkflowError.processingIncomplete
                }
                let preview = try await StageBeeExportService().prepare(
                    job: job, jobFolder: folder, song: current.workspaceSong, isSignedIn: true)
                let payload = try SongImportPayload.data(sections: preview.sectionsPayload, tempo: preview.tempoPayload)
                try await store.attachPayload(payload, to: current)
            } catch {
                try await store.markStep(.translation, state: .failed, error: error.localizedDescription, in: current)
                throw error
            }
            message = "Analysis ready. Open the chart, edit it, then review publication."
        } catch {
            // A failed audit write cannot be mistaken for a fully staged run.
            // The job is still recoverable from its local folder on resume.
            if jobs.isRunning(record.workspaceID) { jobs.cancelRun() }
            jobs.removeFromQueue(record.workspaceID)
            message = SongImportRedactor.redact(error.localizedDescription)
        }
    }

    static func validateSavedOutputs(_ job: AnalysisJob, folder: URL) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("job.json")),
              let saved = try? decoder.decode(AnalysisJob.self, from: data),
              saved.id == job.id, saved.songDocumentID == job.songDocumentID,
              saved.chartsVersion == job.chartsVersion,
              [job.analysisWavPath, job.chordChartPerformerPath, job.sectionsPath].allSatisfy({ path in
                  path.map { FileManager.default.fileExists(atPath: $0) } == true
              }) else {
            throw JobError.backendRejected("The analysis or chart is not saved completely. Check disk space and resume the import before publication.")
        }
    }

    static func progress(_ job: AnalysisJob) -> [SongImportMediaStatus] {
        let groups: [(SongImportProcessingStep, [PipelineStage])] = [
            (.download, [.tools, .download]), (.conversion, [.convert]),
            (.analysis, [.metadata, .health] + PipelineStage.analysisStages),
        ]
        return groups.compactMap { step, stages in
            let values = stages.map { job.stageReport[$0].state }
            let failure = values.first(where: { $0.isFailure })
            let state: SongImportStepState
            if failure != nil { state = .failed }
            else if values.allSatisfy({ $0.isSuccessful }) { state = .succeeded }
            else if values.contains(.running) { state = .running }
            else { return nil }
            return SongImportMediaStatus(step: step, state: state, updatedAt: Date(),
                                         redactedError: failure?.message.map(SongImportRedactor.redact))
        }
    }
}

extension StageState {
    var isSuccessful: Bool {
        switch self {
        case .done, .warning: true
        default: false
        }
    }
}
