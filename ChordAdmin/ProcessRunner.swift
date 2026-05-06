import Foundation

struct ProcessResult: Sendable {
    let exitCode: Int32
    let output: String
}

struct ProcessRunner {
    // nonisolated so this can be called without hopping to an actor executor,
    // even under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
    nonisolated static func run(
        executablePath: String,
        arguments: [String],
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let lock = NSLock()
            var accumulated = ""

            func ingest(_ data: Data) {
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                lock.withLock { accumulated += text }
                onOutput?(text)
            }

            outPipe.fileHandleForReading.readabilityHandler = { ingest($0.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { ingest($0.availableData) }

            process.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Drain any final bytes
                ingest(outPipe.fileHandleForReading.readDataToEndOfFile())
                ingest(errPipe.fileHandleForReading.readDataToEndOfFile())
                let finalOutput = lock.withLock { accumulated }
                continuation.resume(returning: ProcessResult(exitCode: p.terminationStatus, output: finalOutput))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
