import Foundation

struct LocalFileStore {

    static let baseDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("ChordAdmin/jobs", isDirectory: true)
    }()

    private static let urlCacheFile: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("ChordAdmin/url_cache.json")
    }()

    private static let requiredCacheFiles = ["analysis.wav", "job.json"]

    // MARK: - Cache validation

    /// Whether a decoded job should be reused from the URL cache.
    static func isCachedJobValid(_ job: AnalysisJob) -> Bool {
        guard job.analysisPipelineVersion == AppConfig.analysisPipelineVersion else { return false }
        switch job.status {
        case .completed, .completedWithWarnings:
            return true
        default:
            return false
        }
    }

    /// Loads a validated cached job for `url`, evicting stale entries when needed.
    static func loadValidCachedJob(for url: String) -> (job: AnalysisJob, folder: URL)? {
        guard let folder = cachedJobFolder(for: url) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let jobURL = folder.appendingPathComponent("job.json")
        guard let data = try? Data(contentsOf: jobURL),
              let job = try? decoder.decode(AnalysisJob.self, from: data) else {
            evictURLCache(url: url)
            return nil
        }

        guard isCachedJobValid(job) else {
            evictURLCache(url: url)
            return nil
        }

        return (job, folder)
    }

    // MARK: - URL cache

    /// Returns the job folder URL for `url` if the folder contains required artefacts,
    /// or `nil` if there is no valid cache entry.
    static func cachedJobFolder(for url: String) -> URL? {
        guard let map = readURLCache(), let folderPath = map[url] else { return nil }
        let folder = URL(fileURLWithPath: folderPath)
        for name in requiredCacheFiles {
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) else {
                return nil
            }
        }
        return folder
    }

    /// Persists a `url → folderPath` mapping in the URL cache.
    static func saveURLCache(url: String, folderPath: String) {
        var map = readURLCache() ?? [:]
        map[url] = folderPath
        writeURLCache(map)
    }

    /// Removes a stale cache entry for `url`.
    static func evictURLCache(url: String) {
        guard var map = readURLCache() else { return }
        map.removeValue(forKey: url)
        writeURLCache(map)
    }

    private static func readURLCache() -> [String: String]? {
        guard let data = try? Data(contentsOf: urlCacheFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return obj
    }

    private static func writeURLCache(_ map: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: .prettyPrinted) else { return }
        try? FileManager.default.createDirectory(
            at: urlCacheFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: urlCacheFile)
    }

    static func createJobFolder(jobId: String) throws -> URL {
        let folder = baseDirectory.appendingPathComponent(jobId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func saveJob(_ job: AnalysisJob, to folder: URL) throws {
        var jobToSave = job
        if jobToSave.analysisPipelineVersion != AppConfig.analysisPipelineVersion {
            jobToSave.analysisPipelineVersion = AppConfig.analysisPipelineVersion
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(jobToSave)
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

    /// Returns the `sectionCount` from the cached job whose URL shares the same
    /// YouTube video ID as `url`. Handles format mismatches (youtu.be vs youtube.com).
    static func cachedSectionCount(for url: String) -> Int? {
        guard let targetID = YouTubeURLUtils.youTubeVideoID(from: url), let map = readURLCache() else { return nil }
        for (cacheUrl, folderPath) in map {
            guard YouTubeURLUtils.youTubeVideoID(from: cacheUrl) == targetID else { continue }
            let folder = URL(fileURLWithPath: folderPath)
            guard requiredCacheFiles.allSatisfy({
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("job.json")),
                  let job = try? decoder.decode(AnalysisJob.self, from: data),
                  isCachedJobValid(job) else { continue }
            return job.sectionCount
        }
        return nil
    }

    static func saveSourceInfo(_ info: [String: String], to folder: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: info, options: .prettyPrinted)
        try data.write(to: folder.appendingPathComponent("source.info.json"))
    }
}
