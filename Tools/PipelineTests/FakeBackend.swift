import Foundation
import Network

/// A stand-in for ChordAdminBackend, so the analysis pipeline can be driven
/// end to end without the real Python service, a network, or a real download.
///
/// It speaks just enough HTTP to answer the three endpoints the app calls, and
/// can be told to fail so the failure paths are exercised too.
final class FakeBackend: @unchecked Sendable {

    struct Behaviour {
        var healthStatus = 200
        /// Set to something else to stand in for a different service answering
        /// on the backend's port.
        var healthServiceName = "ChordAdminBackend"
        var beatsStatus = 200
        var chordsStatus = 200
        /// Beat times returned by /api/detect-beats.
        var beats: [Double] = (0..<64).map { Double($0) * 0.5 }
        var bpm: Double = 120
        /// Chords returned by /api/recognize-chords.
        var chords: [(String, Double, Double)] = {
            let names = ["C", "Am", "F", "G"]
            return (0..<16).map { (names[$0 % 4], Double($0) * 2.0, Double($0 + 1) * 2.0) }
        }()
        /// When set, /api/detect-beats answers 200 with no usable beats.
        var beatsEmpty = false
        /// The real backend reports a failed detection as `status: "error"` in
        /// the body at HTTP 200 — `jsonify(result)` with no status code set.
        var beatsReportsErrorAt200: String?

        // — Export translation —
        var translateStatus = 200
        var translateTempo: Any = 136
        /// TheStageBee's real shape: sections are keyed `title`, and their bars
        /// live inside `lines`. The tests read this the way the app must.
        var translateSections: [[String: Any]] = [
            FakeBackend.section(titled: "Intro", bars: 4),
            FakeBackend.section(titled: "Verse A", bars: 16),
            FakeBackend.section(titled: "Chorus", bars: 16),
        ]
        /// Answers with `status: "error"` even on a 200, as the real service does.
        var translateRejects = false
        /// Chord recognition puts its reason in `error`, not `message`.
        var chordsReportsErrorAt200: String?
        /// Holds the beat-detection reply back, so cancellation can be tested
        /// against a request that is genuinely in flight.
        var beatsDelay: TimeInterval = 0
    }

    /// One section in the translated payload, bars grouped four to a line.
    static func section(titled title: String, bars: Int) -> [String: Any] {
        let bar: [String: Any] = [
            "structure": "1fr",
            "timeSignature": [4, 4],
            "chords": [["chord": "C", "pause": false, "hit": false]],
        ]
        let lines = stride(from: 0, to: bars, by: 4).map { start -> [String: Any] in
            ["bars": Array(repeating: bar, count: min(4, bars - start))]
        }
        return [
            "title": title,
            "tempo": 136,
            "timeSignature": [4, 4],
            "structure": "1fr",
            "lines": lines,
        ]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-backend")
    private let lock = NSLock()
    private var behaviour: Behaviour
    private var recordedPaths: [String] = []

    private(set) var port: UInt16 = 0

    init(fixedPort: UInt16, behaviour: Behaviour = Behaviour()) throws {
        self.behaviour = behaviour
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: fixedPort) else { throw URLError(.badURL) }
        listener = try NWListener(using: parameters, on: port)
        self.port = fixedPort
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    /// Paths the app actually asked for, so a test can assert a stage was skipped.
    var requestedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedPaths
    }

    func update(_ change: (inout Behaviour) -> Void) {
        lock.lock()
        change(&behaviour)
        lock.unlock()
    }

    /// Starts listening and returns once a port has been assigned.
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.port = self.listener.port?.rawValue ?? self.port
                ready.signal()
            }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard port != 0 else { throw URLError(.cannotConnectToHost) }
    }

    func stop() { listener.cancel() }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, accumulated: Data())
    }

    /// Reads until the headers are complete and the declared body has arrived,
    /// which for the multipart uploads means several megabytes.
    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if error != nil {
                connection.cancel()
                return
            }

            guard let headerEnd = Self.range(of: Data("\r\n\r\n".utf8), in: buffer) else {
                if isComplete { connection.cancel() } else {
                    self.receiveRequest(connection, accumulated: buffer)
                }
                return
            }

            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let bodyReceived = buffer.count - headerEnd.upperBound
            let contentLength = Self.contentLength(in: head) ?? 0

            if bodyReceived < contentLength && !isComplete {
                self.receiveRequest(connection, accumulated: buffer)
                return
            }

            self.respond(to: head, on: connection)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

        lock.lock()
        recordedPaths.append(path)
        let current = behaviour
        lock.unlock()

        let status: Int
        let payload: [String: Any]

        switch path {
        case "/health":
            status = current.healthStatus
            // The shape the real service returns, including the name the app
            // uses to tell it apart from anything else on the same port.
            payload = ["status": "healthy",
                       "service": current.healthServiceName,
                       "version": "0.1.0"]
        case "/api/detect-beats":
            status = current.beatsStatus
            if let message = current.beatsReportsErrorAt200 {
                payload = ["status": "error", "message": message,
                           "details": "Supported models: madmom"]
            } else if status == 200 {
                payload = current.beatsEmpty
                    ? ["status": "success", "bpm": 0, "beats": [], "model": "madmom"]
                    : ["status": "success",
                       "bpm": current.bpm,
                       "beats": current.beats.map { ["time": $0, "confidence": NSNull()] },
                       "beatCount": current.beats.count,
                       "model": "madmom",
                       "warnings": [String]()]
            } else {
                payload = ["status": "error", "message": "chord model failed to load"]
            }
        case "/api/recognize-chords":
            status = current.chordsStatus
            if let reason = current.chordsReportsErrorAt200 {
                payload = ["status": "error", "error": reason, "chords": [Any](), "chordCount": 0]
            } else if status == 200 {
                payload = ["status": "success", "cleanedChords": [
                    "chordCount": current.chords.count,
                    "chords": current.chords.map {
                        ["displayChord": $0.0, "rawChord": $0.0 + ":maj",
                         "start": $0.1, "end": $0.2]
                    },
                ]]
            } else {
                payload = ["message": "recognition unavailable"]
            }
        case "/api/translate-to-stagebee":
            status = current.translateStatus
            if status == 200 && !current.translateRejects {
                payload = ["status": "success",
                           "song": ["sections": current.translateSections,
                                    "tempo": current.translateTempo]]
            } else {
                payload = ["status": "error", "message": "job folder is incomplete"]
            }
        default:
            status = 404
            payload = ["message": "no such endpoint"]
        }

        if path == "/api/detect-beats", current.beatsDelay > 0 {
            Thread.sleep(forTimeInterval: current.beatsDelay)
        }

        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n".utf8)
        response.append(Data("Content-Type: application/json\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Parsing helpers

    private static func contentLength(in head: String) -> Int? {
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func range(of needle: Data, in haystack: Data) -> Range<Int>? {
        guard haystack.count >= needle.count else { return nil }
        let bytes = [UInt8](haystack)
        let pattern = [UInt8](needle)
        for start in 0...(bytes.count - pattern.count) where Array(bytes[start..<start + pattern.count]) == pattern {
            return start..<(start + pattern.count)
        }
        return nil
    }
}
