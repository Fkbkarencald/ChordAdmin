import Foundation

nonisolated struct ProcessResult: Sendable {
    let exitCode: Int32
    let output: String
}

/// Thread-safe handle so a task-cancellation handler can terminate a process
/// that was launched inside the continuation.
private nonisolated final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var resumed = false
    /// Set once the child has been made leader of its own process group, so a
    /// cancel can reach what it spawned as well as the child itself.
    private var groupLeader: pid_t?

    /// Adopts a process for later termination. Returns false when cancellation
    /// already happened, in which case the process must not be started.
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    /// Puts the child in its own process group. Best effort: it races the
    /// child's own exec, and the child may have set a group itself.
    func claimProcessGroup(_ pid: pid_t) {
        guard pid > 0, setpgid(pid, pid) == 0 else { return }
        lock.lock()
        groupLeader = pid
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        let group = groupLeader
        lock.unlock()
        // yt-dlp runs deno for its JS runtime, and terminating only the direct
        // child left that grandchild alive holding the output pipe open — which
        // is what used to wedge the run indefinitely. Signal the whole group
        // where we managed to create one.
        if let group { kill(-group, SIGTERM) }
        running?.terminate()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Guards against resuming the continuation twice.
    func claimResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}

/// Serialises every read of one pipe.
///
/// `readabilityHandler = nil` does not wait for a handler already running, so
/// the final drain could read the same descriptor at the same moment as an
/// in-flight handler — interleaving bytes and, since a chunk can now end
/// mid-character, mis-decoding the result. One lock per pipe removes the race,
/// and closing under the same lock means a read can never touch a closed
/// descriptor (or one the kernel has since handed to another file).
private nonisolated final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var closed = false

    init(_ handle: FileHandle) { self.handle = handle }

    /// Streams data to `ingest` as it arrives.
    func stream(_ ingest: @escaping @Sendable (Data) -> Void) {
        handle.readabilityHandler = { [weak self] fileHandle in
            guard let self else { return }
            self.lock.lock()
            let data = self.closed ? Data() : fileHandle.availableData
            self.lock.unlock()
            ingest(data)
        }
    }

    /// Stops streaming, takes whatever is already buffered without waiting for
    /// the pipe to close, and closes it.
    func finish() -> Data {
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return Data() }
        let remaining = ProcessRunner.drainWithoutBlocking(handle)
        closed = true
        try? handle.close()
        return remaining
    }
}

/// Accumulates subprocess output from the reader queues.
private nonisolated final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    /// Bytes left over from a chunk that ended mid-character.
    private var pending = Data()

    /// Decodes as much of `chunk` as forms whole characters and keeps the rest
    /// for the next one. Decoding each chunk on its own dropped it entirely
    /// whenever a read boundary split a multi-byte sequence — up to 64 KB of
    /// output gone from both the log and the text callers parse.
    func append(_ chunk: Data) -> String? {
        lock.lock()
        pending.append(chunk)
        let (decoded, rest) = Self.split(pending)
        pending = rest
        guard let decoded, !decoded.isEmpty else { lock.unlock(); return nil }
        text += decoded
        lock.unlock()
        return decoded
    }

    /// Flushes whatever is left once no more bytes are coming, so a truncated
    /// final sequence is shown rather than silently dropped.
    func finish() {
        lock.lock()
        if !pending.isEmpty {
            text += String(decoding: pending, as: UTF8.self)
            pending = Data()
        }
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    /// Splits `data` at the last complete UTF-8 character boundary.
    private static func split(_ data: Data) -> (String?, Data) {
        if let whole = String(data: data, encoding: .utf8) { return (whole, Data()) }
        // A continuation byte is 0b10xxxxxx; walk back to the lead byte that
        // starts the incomplete character. Four bytes is the longest sequence.
        var cut = data.count
        var steps = 0
        while cut > 0, steps < 4 {
            cut -= 1
            steps += 1
            let byte = data[data.startIndex + cut]
            if byte & 0xC0 != 0x80 {
                // `cut` is the lead byte of the trailing partial character.
                let head = data.prefix(cut)
                if let text = String(data: head, encoding: .utf8) {
                    return (text, Data(data.suffix(from: data.startIndex + cut)))
                }
                break
            }
        }
        // Not a boundary problem — replace what cannot be decoded rather than
        // discarding the chunk.
        return (String(decoding: data, as: UTF8.self), Data())
    }
}

nonisolated struct ProcessRunner {
    // nonisolated so this can be called without hopping to an actor executor,
    // even under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
    ///
    /// Honours task cancellation: cancelling the surrounding task terminates the
    /// subprocess and throws `CancellationError`, so a stuck download or
    /// conversion can be stopped from the UI instead of wedging the app.
    nonisolated static func run(
        executablePath: String,
        arguments: [String],
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let handle = ProcessHandle()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let buffer = OutputBuffer()

                let ingest: @Sendable (Data) -> Void = { data in
                    guard !data.isEmpty else { return }
                    if let text = buffer.append(data) { onOutput?(text) }
                }

                let outReader = PipeReader(outPipe.fileHandleForReading)
                let errReader = PipeReader(errPipe.fileHandleForReading)
                outReader.stream(ingest)
                errReader.stream(ingest)

                process.terminationHandler = { finished in
                    // Take what is already buffered without waiting for the pipe
                    // to close. `readDataToEndOfFile` waited for *every* writer
                    // to let go, and a grandchild that outlived the child it was
                    // spawned by never did — so the run hung for good.
                    ingest(outReader.finish())
                    ingest(errReader.finish())
                    buffer.finish()

                    guard handle.claimResume() else { return }
                    if handle.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(
                            returning: ProcessResult(exitCode: finished.terminationStatus, output: buffer.value)
                        )
                    }
                }

                guard handle.adopt(process) else {
                    if handle.claimResume() { continuation.resume(throwing: CancellationError()) }
                    return
                }

                do {
                    try process.run()
                    handle.claimProcessGroup(process.processIdentifier)
                } catch {
                    if handle.claimResume() { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Reads what is already in the pipe and stops at the first would-block.
    ///
    /// The blocking read this replaces waited on every writer, including
    /// processes the child had spawned and left behind.
    fileprivate static func drainWithoutBlocking(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { return Data() }
        defer { _ = fcntl(fd, F_SETFL, flags) }

        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                collected.append(contentsOf: chunk[0..<count])
                continue
            }
            // 0 is EOF; -1 with EAGAIN means nothing more is ready right now.
            if count == -1 && errno == EINTR { continue }
            break
        }
        return collected
    }
}
