import SwiftUI

// MARK: - Work state

/// Where a song stands in the pick → analyse → edit → export loop.
///
/// The old grid showed only a thumbnail and an unexplained piano badge, so the
/// only way to find the next song to work on was to remember or open each one.
enum SongWorkState: Equatable {
    /// No usable YouTube link, so nothing can be analysed. Shown, not hidden.
    case unavailable
    case new
    case queued(position: Int)
    case running(stage: PipelineStage?, stageIndex: Int)
    /// Audio downloaded, analysis still to run (usually the backend was down).
    case audioReady
    case failed(stage: PipelineStage?)
    case analysed
    case edited
    case exported(at: Date)

    var label: String {
        switch self {
        case .unavailable:               return "No YouTube link"
        case .new:                       return "Not analysed"
        case .queued(let position):      return position == 1 ? "Queued · next" : "Queued"
        case .running(let stage, let index):
            guard let stage else { return "Analysing" }
            return "\(stage.title) · stage \(index) of \(PipelineStage.allCases.count)"
        case .audioReady:                return "Audio ready — analysis paused"
        case .failed(let stage):
            return stage.map { "Failed at \($0.title.lowercased())" } ?? "Failed"
        case .analysed:                  return "Analysed — sections need review"
        case .edited:                    return "Edited since last export"
        case .exported(let date):        return "Exported \(Self.relative(date))"
        }
    }

    var symbolName: String {
        switch self {
        case .unavailable: return "link.badge.plus"
        case .new:         return "circle.dashed"
        case .queued:      return "clock"
        case .running:     return "arrow.triangle.2.circlepath"
        case .audioReady:  return "exclamationmark.triangle.fill"
        case .failed:      return "xmark.circle.fill"
        case .analysed:    return "circle.fill"
        case .edited:      return "pencil.circle.fill"
        case .exported:    return "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .unavailable: return .secondary
        case .new:         return .secondary
        case .queued:      return .secondary
        case .running:     return .accentColor
        case .audioReady:  return .orange
        case .failed:      return .red
        case .analysed:    return .accentColor
        case .edited:      return .orange
        case .exported:    return .green
        }
    }

    var isBusy: Bool {
        switch self {
        case .running, .queued: return true
        default: return false
        }
    }

    /// Whether the song can start an analysis right now.
    var canAnalyse: Bool {
        switch self {
        case .unavailable, .running, .queued: return false
        default: return true
        }
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Filters

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, new, analysed, edited, exported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:      return "All"
        case .new:      return "New"
        case .analysed: return "Analysed"
        case .edited:   return "Edited"
        case .exported: return "Exported"
        }
    }

    func matches(_ state: SongWorkState) -> Bool {
        switch self {
        case .all:
            return true
        case .new:
            switch state {
            case .new, .unavailable, .queued, .failed, .audioReady: return true
            default: return false
            }
        case .analysed:
            if case .analysed = state { return true }
            if case .running = state { return true }
            return false
        case .edited:
            if case .edited = state { return true }
            return false
        case .exported:
            if case .exported = state { return true }
            return false
        }
    }
}

// MARK: - Library item

struct LibraryItem: Identifiable {
    let song: FirebaseSong
    let job: AnalysisJob?
    let state: SongWorkState

    var id: String { song.id ?? song.title }
    var title: String { song.title }
    var artist: String? {
        let name = song.artists?.first?.name
        return (name?.isEmpty == false) ? name : nil
    }

    /// A reference the pipeline can act on, or nil when the song has no
    /// document ID or no YouTube link.
    var ref: SongRef? {
        guard let documentID = song.id, !documentID.isEmpty,
              let link = song.link, SongRef.youTubeVideoID(from: link) != nil else { return nil }
        return SongRef(documentID: documentID, title: song.title, artist: artist, url: link)
    }

    var thumbnailURL: URL? {
        guard let videoID = SongRef.youTubeVideoID(from: song.link) else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg")
    }
}

// MARK: - Derivation

enum Library {

    /// Builds the library rows, pairing every song with the job that was run
    /// for it. Songs without a YouTube link stay in the list, dimmed, instead of
    /// being silently filtered out.
    @MainActor
    static func items(songs: [FirebaseSong], jobManager: JobManager) -> [LibraryItem] {
        songs.map { song in
            let job = song.id.flatMap { jobManager.job(for: $0) }
            return LibraryItem(
                song: song,
                job: job,
                state: state(for: song, job: job, jobManager: jobManager)
            )
        }
    }

    @MainActor
    static func state(for song: FirebaseSong, job: AnalysisJob?, jobManager: JobManager) -> SongWorkState {
        guard let songID = song.id, !songID.isEmpty,
              SongRef.youTubeVideoID(from: song.link) != nil else { return .unavailable }

        if jobManager.isRunning(songID) {
            let report = job?.stageReport
            let stage = report?.runningStage
            let index = stage.flatMap { PipelineStage.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 1
            return .running(stage: stage, stageIndex: index)
        }
        if let position = jobManager.queuePosition(of: songID) {
            return .queued(position: position)
        }
        guard let job else { return .new }

        switch job.status {
        case .failed:
            return .failed(stage: job.stageReport.firstFailure?.stage)
        case .cancelled:
            return job.hasAudio ? .audioReady : .new
        case .audioReady:
            return .audioReady
        default:
            break
        }

        if let export = job.lastExport {
            return job.hasUnexportedEdits ? .edited : .exported(at: export.exportedAt)
        }
        if job.hasChart { return .analysed }
        if job.hasAudio { return .audioReady }
        return .new
    }

    static func counts(for items: [LibraryItem]) -> [LibraryFilter: Int] {
        var result: [LibraryFilter: Int] = [:]
        for filter in LibraryFilter.allCases {
            result[filter] = items.filter { filter.matches($0.state) }.count
        }
        return result
    }

    static func filter(_ items: [LibraryItem], by filter: LibraryFilter, search: String) -> [LibraryItem] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            guard filter.matches(item.state) else { return false }
            guard !query.isEmpty else { return true }
            return item.title.lowercased().contains(query)
                || (item.artist?.lowercased().contains(query) ?? false)
        }
    }
}
