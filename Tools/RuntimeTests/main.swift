import Darwin
import CoreGraphics
import Foundation

var failures = 0
func check(_ value: Bool, _ message: String) {
    print("\(value ? "✓" : "✗") \(message)")
    if !value { failures += 1 }
}
func waitUntil(_ predicate: @MainActor () -> Bool, seconds: Double = 30) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return false
}

let screen = CGRect(x: 0, y: 0, width: 1280, height: 720)
let oversized = CGRect(x: -100, y: -200, width: 1800, height: 1200)
check(screen.contains(ChordAdminAppDelegate.constrainedFrame(oversized, visible: screen)),
      "oversized restored windows keep their header within the visible screen")
let practical = CGRect(x: 10, y: 10, width: 1080, height: 640)
check(ChordAdminAppDelegate.constrainedFrame(practical, visible: screen) == practical,
      "a practical window retains its existing size and position")

let executable = URL(fileURLWithPath: CommandLine.arguments[1])
let root = FileManager.default.temporaryDirectory.appendingPathComponent("chordadmin-runtime-test-" + UUID().uuidString)
let runtime = LocalAnalysisRuntime(executable: executable, dataRoot: root, externalURL: nil)
async let first = runtime.ensureReady()
async let second = runtime.ensureReady()
let both = await (first, second)
check(both.0 && both.1, "concurrent startup requests become ready on one owned process")
guard let pid = runtime.processID else { exit(1) }
check(runtime.state == .ready, "readiness requires a matching instance and model capabilities")
let healthURL = URL(string: BackendConnection.shared.baseURL + "/health")!
let (_, denied) = try await URLSession.shared.data(from: healthURL)
check((denied as? HTTPURLResponse)?.statusCode == 403, "unauthenticated local requests are denied")
var request = URLRequest(url: healthURL)
BackendConnection.shared.authorize(&request)
let (_, allowed) = try await URLSession.shared.data(for: request)
check((allowed as? HTTPURLResponse)?.statusCode == 200, "the app can authenticate its private service")
var foreign = URLRequest(url: URL(string: "https://example.com/health")!)
BackendConnection.shared.authorize(&foreign)
check(foreign.value(forHTTPHeaderField: "Authorization") == nil, "the runtime secret is never attached to another destination")
var originRequest = request
originRequest.setValue("https://example.com", forHTTPHeaderField: "Origin")
let (_, originDenied) = try await URLSession.shared.data(for: originRequest)
check((originDenied as? HTTPURLResponse)?.statusCode == 403, "browser-origin requests are rejected")
var outside = URLRequest(url: URL(string: BackendConnection.shared.baseURL + "/api/translate-to-stagebee")!)
outside.httpMethod = "POST"
outside.setValue("application/json", forHTTPHeaderField: "Content-Type")
outside.httpBody = try JSONSerialization.data(withJSONObject: ["jobFolderPath": "/etc"])
BackendConnection.shared.authorize(&outside)
let (_, outsideDenied) = try await URLSession.shared.data(for: outside)
check((outsideDenied as? HTTPURLResponse)?.statusCode == 400, "translation cannot read folders outside app job storage")
kill(pid, SIGKILL)
let recovered = await waitUntil({ runtime.state == .ready && runtime.processID != nil && runtime.processID != pid })
check(recovered, "an unexpected helper exit is recovered without touching downloaded jobs")
if let secondPID = runtime.processID {
    kill(secondPID, SIGKILL)
    check(await waitUntil({ runtime.state == .ready && runtime.processID != nil && runtime.processID != secondPID }),
          "the bounded automatic recovery permits a second restart")
}
if let thirdPID = runtime.processID {
    kill(thirdPID, SIGKILL)
    let exhausted = await waitUntil({ if case .failed = runtime.state { return runtime.processID == nil }; return false })
    check(exhausted, "repeated crashes stop at the restart budget instead of looping")
    check(await runtime.recover(), "explicit recovery resets the crash budget")
}
let recoveredPID = runtime.processID
runtime.shutdown()
let stopped = await waitUntil({ recoveredPID.map { kill($0, 0) == -1 } ?? true }, seconds: 6)
check(stopped && runtime.state == .stopped, "shutdown terminates only the helper the app owns")
let startTask = Task { await runtime.ensureReady() }
try? await Task.sleep(for: .milliseconds(100))
let startupPID = runtime.processID
runtime.shutdown()
let startedAfterStop = await startTask.value
check(!startedAfterStop && runtime.state == .stopped, "shutdown during startup cannot restore a stale ready state")
let startupStopped = await waitUntil({ startupPID.map { kill($0, 0) == -1 } ?? true }, seconds: 6)
check(startupStopped, "cancelled startup leaves no helper behind")
let missing = LocalAnalysisRuntime(executable: root.appendingPathComponent("missing"), dataRoot: root, externalURL: nil)
let missingReady = await missing.ensureReady()
check(!missingReady && missing.lastFailure != nil, "a broken package reports a repairable failure")
print("Runtime lifecycle tests finished: \(failures) failures. No media was analysed.")
exit(failures == 0 ? 0 : 1)
