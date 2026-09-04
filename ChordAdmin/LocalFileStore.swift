import Foundation

struct LocalFileStore {

    /// Root for job folders and the URL cache.
    ///
    /// `CHORDADMIN_JOBS_DIR` redirects it, so tests and the render harness can
    /// work against a throwaway directory instead of the real
    /// `~/Library/Application Support/ChordAdmin` data.
    static let supportDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["CHORDADMIN_JOBS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("ChordAdmin", isDirectory: true)
    }()

    static let baseDirectory: URL = supportDirectory.appendingPathComponent("jobs", isDirectory: true)

    static func createJobFolder(jobId: String) throws -> URL {
        let folder = baseDirectory.appendingPathComponent(jobId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Storage

    /// Bytes used by one job folder.
    static func folderSize(at folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Bytes used by every job folder. Downloaded audio and 44.1 kHz WAVs are
    /// large and nothing ever removed them, so the app now reports the total.
    static func totalJobsSize() -> Int64 {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }
        return folders.reduce(0) { $0 + folderSize(at: $1) }
    }

    /// Comparable form of a folder path. Directory URLs can carry a trailing
    /// slash and /tmp and /var are symlinks, so raw `path` comparisons can call a
    /// live folder orphaned — which would offer the user its deletion.
    ///
    /// `nonisolated` because it is pure path arithmetic and the download stage
    /// needs it off the main actor.
    nonisolated static func comparablePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Removes a job folder.
    @discardableResult
    static func deleteJobFolder(at folder: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: folder)
            return true
        } catch {
            return false
        }
    }

    /// Job folders on disk that no live job points at — left behind by
    /// re-analysing a song, which writes a new folder each time.
    static func orphanedFolders(keeping liveFolders: Set<String>) -> [URL] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        let live = Set(liveFolders.map { comparablePath(URL(fileURLWithPath: $0)) })
        return folders.filter { folder in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue && !live.contains(comparablePath(folder))
        }
    }

    static func saveJob(_ job: AnalysisJob, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(job)
        try data.write(to: folder.appendingPathComponent("job.json"), options: .atomic)
    }

    /// Serialises log appends off the caller's thread.
    ///
    /// Every yt-dlp progress line and every ffmpeg stats line went through here,
    /// and the caller is on the main actor — so a download hitched the UI with
    /// an open/seek/write/close per chunk. One queue keeps the ordering while
    /// keeping the work off the main thread.
    private static let logQueue = DispatchQueue(label: "chordadmin.logs", qos: .utility)

    static func appendLog(_ text: String, to folder: URL) {
        guard let data = text.data(using: .utf8) else { return }
        let logURL = folder.appendingPathComponent("logs.txt")
        logQueue.async {
            if FileManager.default.fileExists(atPath: logURL.path) {
                guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
                defer { try? handle.close() }
                // The throwing variants: the non-throwing ones raise an ObjC
                // exception on a full disk instead of returning an error, which
                // would take the app down rather than losing a log line.
                guard (try? handle.seekToEnd()) != nil else { return }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// Waits for queued log writes to reach disk. For tests and for quitting.
    static func flushLogs() {
        logQueue.sync {}
    }

    static func saveSourceInfo(_ info: [String: String], to folder: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: info, options: .prettyPrinted)
        try data.write(to: folder.appendingPathComponent("source.info.json"), options: .atomic)
    }
}
