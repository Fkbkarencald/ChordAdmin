import Foundation
import Combine

/// Tracks whether the machine is actually ready to run a job: the command-line
/// tools and the local analysis backend.
///
/// The previous build only checked tools at the moment a job started, so a
/// missing tool showed up as a failed job with an orphan folder. This runs at
/// launch, can be re-checked on demand, and is shown in the library footer.
@MainActor
final class EnvironmentStore: ObservableObject {
    @Published private(set) var tools: ToolReport?
    @Published private(set) var backendAvailable: Bool?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?
    private var lifecycle: AnyCancellable?

    init() {
        lifecycle = LocalAnalysisRuntime.shared.$state.sink { [weak self] state in
            switch state {
            case .ready: self?.backendAvailable = true
            case .failed, .stopped: self?.backendAvailable = false
            case .starting: self?.backendAvailable = nil
            case .external: break
            }
        }
    }

    var isReady: Bool { (tools?.allAvailable ?? false) && backendAvailable == true }

    var backendURL: String { JobManager.backendBaseUrl }

    /// Tools needed before anything can be downloaded.
    var missingTools: [Tool] { tools?.missing ?? [] }

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        async let toolReport = try? ToolChecker.check()
        async let backend = LocalAnalysisRuntime.shared.ensureReady()

        let report = await toolReport
        backendAvailable = await backend
        // A cancelled probe learned nothing, so it must not overwrite a good
        // report with an empty one, nor claim the tools were just checked.
        guard let report else { return }
        tools = report
        lastCheckedAt = Date()
    }

    /// Re-checks only the backend — the common case while starting the Python
    /// service in another window.
    func refreshBackend() async {
        backendAvailable = await LocalAnalysisRuntime.shared.recover()
        lastCheckedAt = Date()
    }
}
