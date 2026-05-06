import Foundation

struct LocalFileStore {

    static let baseDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("ChordAdmin/jobs", isDirectory: true)
    }()

    static func createJobFolder(jobId: String) throws -> URL {
        let folder = baseDirectory.appendingPathComponent(jobId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func saveJob(_ job: AnalysisJob, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(job)
        try data.write(to: folder.appendingPathComponent("job.json"))
    }

    static func appendLog(_ text: String, to folder: URL) {
        guard let data = text.data(using: .utf8) else { return }
        let logURL = folder.appendingPathComponent("logs.txt")
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            }
        } else {
            try? data.write(to: logURL)
        }
    }

    static func saveSourceInfo(_ info: [String: String], to folder: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: info, options: .prettyPrinted)
        try data.write(to: folder.appendingPathComponent("source.info.json"))
    }
}
