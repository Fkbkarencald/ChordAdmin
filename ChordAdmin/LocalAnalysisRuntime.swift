import Combine
import Darwin
import Foundation

/// Immutable request snapshots are shared with non-main-actor upload helpers.
nonisolated final class BackendConnection: @unchecked Sendable {
    static let shared = BackendConnection()
    private let lock = NSLock()
    private var managedURL: String?
    private var token: String?
    var baseURL: String {
        if let override = ProcessInfo.processInfo.environment["CHORDADMIN_BACKEND_URL"], !override.isEmpty {
            return override.hasSuffix("/") ? String(override.dropLast()) : override
        }
        lock.lock(); defer { lock.unlock() }
        return managedURL ?? "http://127.0.0.1:5051"
    }
    func configure(url: String?, token: String?) {
        lock.lock(); defer { lock.unlock() }
        managedURL = url; self.token = token
    }
    func authorize(_ request: inout URLRequest) {
        lock.lock(); defer { lock.unlock() }
        guard let managedURL, let token,
              request.url?.absoluteString.hasPrefix(managedURL + "/") == true else { return }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    }
}

/// Owns exactly the child this app launched. Never scans for or kills services
/// by port/name; development overrides are checked but are never managed.
@MainActor
final class LocalAnalysisRuntime: ObservableObject {
    static let shared = LocalAnalysisRuntime()
    enum State: Equatable {
        case stopped, starting, ready, failed(String), external
    }
    @Published private(set) var state: State = .stopped
    @Published private(set) var lastFailure: String?
    private var process: Process?
    private var startup: Task<Bool, Never>?
    private var startupID: UUID?
    private var epoch = UUID()
    private var restartCount = 0
    private var shuttingDown = false
    private let executable: URL?
    private let dataRoot: URL
    private let externalURL: String?
    private var runDirectory: URL?
    private var logHandle: FileHandle?

    init(executable: URL? = nil, dataRoot: URL? = nil,
         externalURL: String? = ProcessInfo.processInfo.environment["CHORDADMIN_BACKEND_URL"]) {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ChordAdminAnalysis.app/Contents/MacOS/chordadmin-analysis")
        self.executable = executable ?? (FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil)
        self.dataRoot = dataRoot ?? LocalFileStore.supportDirectory.appendingPathComponent("analysis-runtime", isDirectory: true)
        self.externalURL = externalURL
    }

    var label: String {
        switch state {
        case .stopped: "Local analysis stopped"
        case .starting: "Starting local analysis…"
        case .ready: "Local analysis ready"
        case .failed: "Local analysis needs attention"
        case .external: "External analysis service"
        }
    }
    var processID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }
    var logURL: URL? { runDirectory?.appendingPathComponent("runtime.log") }

    func ensureReady() async -> Bool {
        if let externalURL, !externalURL.isEmpty {
            state = .external
            return await JobManager.checkBackendHealth()
        }
        if state == .ready, process?.isRunning == true { return true }
        if let startup { return await startup.value }
        shuttingDown = false
        let id = UUID()
        let task = Task { await self.launch() }
        startupID = id
        startup = task
        let result = await task.value
        if startupID == id { startup = nil; startupID = nil }
        return result
    }

    private func launch() async -> Bool {
        guard let executable else {
            let message = "This build is missing its local analysis runtime. Use the packaged ChordAdmin app."
            state = .failed(message); lastFailure = message
            return false
        }
        state = .starting
        let launchID = UUID()
        epoch = launchID
        let instance = UUID().uuidString
        let token = UUID().uuidString + UUID().uuidString
        let directory = dataRoot.appendingPathComponent(instance, isDirectory: true)
        let readyFile = directory.appendingPathComponent("ready.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let cache = dataRoot.appendingPathComponent("cache", isDirectory: true)
            let temp = directory.appendingPathComponent("temp", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let log = directory.appendingPathComponent("runtime.log")
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: log)
            logHandle = handle
            runDirectory = directory
            let child = Process()
            child.executableURL = executable
            child.currentDirectoryURL = directory
            child.standardOutput = handle
            child.standardError = handle
            var env = ProcessInfo.processInfo.environment
            for key in ["PYTHONPATH", "PYTHONHOME", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"] { env.removeValue(forKey: key) }
            env["CHORDADMIN_RUNTIME_TOKEN"] = token
            env["CHORDADMIN_RUNTIME_INSTANCE"] = instance
            env["CHORDADMIN_PARENT_PID"] = String(getpid())
            env["CHORDADMIN_READY_FILE"] = readyFile.path
            env["CHORDADMIN_CACHE_DIR"] = cache.path
            env["CHORDADMIN_TEMP_DIR"] = temp.path
            env["CHORDADMIN_JOBS_ROOT"] = LocalFileStore.baseDirectory.path
            env["NUMBA_CACHE_DIR"] = cache.appendingPathComponent("numba").path
            env["MPLCONFIGDIR"] = cache.appendingPathComponent("matplotlib").path
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            env["PYTHONUNBUFFERED"] = "1"
            let bin = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Frameworks/bin").path
            env["PATH"] = bin + ":/usr/bin:/bin"
            child.environment = env
            child.terminationHandler = { [weak self] child in
                Task { @MainActor [weak self] in self?.didExit(epoch: launchID, status: child.terminationStatus) }
            }
            process = child
            try child.run()
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline, child.isRunning, epoch == launchID, !shuttingDown {
                try Task.checkCancellation()
                if let data = try? Data(contentsOf: readyFile),
                   let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   info["instance"] as? String == instance,
                   (info["pid"] as? NSNumber)?.int32Value == child.processIdentifier,
                   let port = info["port"] as? Int, (1...65535).contains(port) {
                    let url = "http://127.0.0.1:\(port)"
                    BackendConnection.shared.configure(url: url, token: token)
                    if await Self.checkManagedHealth(url: url, token: token, instance: instance) {
                        guard epoch == launchID, child.isRunning, !shuttingDown else { break }
                        state = .ready; lastFailure = nil
                        return true
                    }
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            throw RuntimeError.startup("Local analysis did not become ready. Its log is available from the analysis status panel.")
        } catch {
            guard epoch == launchID else { return false }
            let message = error is CancellationError ? "Local analysis startup was cancelled." : error.localizedDescription
            stopChild()
            state = .failed(message); lastFailure = message
            return false
        }
    }

    private enum RuntimeError: LocalizedError {
        case startup(String)
        var errorDescription: String? { switch self { case .startup(let message): message } }
    }

    private static func checkManagedHealth(url: String, token: String, instance: String) async -> Bool {
        guard let url = URL(string: url + "/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["service"] as? String == "ChordAdminBackend", body["instance"] as? String == instance,
                  let caps = body["capabilities"] as? [String: Any] else { return false }
            return ["beats", "chords", "translation"].allSatisfy { caps[$0] as? Bool == true }
        } catch { return false }
    }

    private func didExit(epoch exited: UUID, status: Int32) {
        guard exited == epoch, !shuttingDown, state == .ready else { return }
        process = nil
        startup = nil; startupID = nil
        try? logHandle?.close(); logHandle = nil
        BackendConnection.shared.configure(url: nil, token: nil)
        lastFailure = "Local analysis stopped unexpectedly (code \(status)). Downloaded audio is kept; resume the analysis after recovery."
        state = .failed(lastFailure!)
        if restartCount < 2 {
            restartCount += 1
            Task { _ = await ensureReady() }
        }
    }

    /// Explicit retry resets the crash-loop budget; refresh never kills a live service.
    func recover() async -> Bool {
        restartCount = 0
        return await ensureReady()
    }

    func shutdown() {
        shuttingDown = true
        epoch = UUID()
        startup?.cancel(); startup = nil
        stopChild()
        state = .stopped
    }

    private func stopChild() {
        let child = process
        let oldDirectory = runDirectory
        process = nil
        BackendConnection.shared.configure(url: nil, token: nil)
        if let child, child.isRunning {
            child.terminate()
            Task {
                try? await Task.sleep(for: .seconds(3))
                if child.isRunning {
                    kill(child.processIdentifier, SIGKILL)
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if !child.isRunning, let oldDirectory {
                    // Only transient uploads from this owned helper are removed.
                    // Original downloads, charts, cache and diagnostic logs stay.
                    try? FileManager.default.removeItem(at: oldDirectory.appendingPathComponent("temp"))
                    try? FileManager.default.removeItem(at: oldDirectory.appendingPathComponent("ready.json"))
                }
            }
        }
        try? logHandle?.close()
        logHandle = nil
    }
}
