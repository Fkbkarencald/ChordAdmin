import Foundation
import Combine
import FirebaseFirestore

// MARK: - Export preview

/// One section as it will be written to TheStageBee.
struct ExportPreviewSection: Identifiable, Equatable {
    let index: Int
    let name: String
    let barCount: Int
    var id: Int { index }
}

/// Everything the confirmation sheet needs to show before anything is written,
/// plus the resolved payload it will write. Building this runs the translation
/// but performs no Firestore write, so the user always sees the real result
/// of an export before agreeing to it.
struct ExportPreview: Identifiable {
    let id = UUID()
    let songID: String
    /// The analysis this payload was built from. A queued re-analysis can start
    /// while the sheet is open and replace the song's job, and the export record
    /// must not then be stamped onto a run that wrote nothing.
    let jobID: String
    let songTitle: String
    let artist: String?
    let documentID: String

    let currentTempo: Int?
    let newTempo: Int?
    let currentSectionNames: [String]
    let newSections: [ExportPreviewSection]

    /// Firestore values to write, already validated.
    let sectionsPayload: Any
    let tempoPayload: Any

    var tempoChanged: Bool { currentTempo != newTempo }

    var summary: String {
        "\(newSections.count) sections"
            + (newTempo.map { ", \($0) BPM" } ?? "")
    }
}

// MARK: - StageBeeExportService

/// Translates a completed ChordAdmin job to TheStageBee's Song schema and writes
/// the result to the Firestore `songs` collection.
///
/// Export is a two-step flow: `prepare` runs the translation and returns a
/// preview of exactly what would change, and `commit` performs the write. The
/// previous build wrote to production Firestore straight from a toolbar button
/// with no preview, no confirmation and no record of what it replaced.
@MainActor
final class StageBeeExportService: ObservableObject {

    // MARK: - Nested types

    enum ExportState: Equatable {
        case idle
        case preparing
        case exporting
        case success(documentID: String)
        case failure(message: String)
    }

    enum ExportError: LocalizedError {
        case backendUnavailable(String)
        case backendRejected(String)
        case invalidResponse
        case firestoreError(String)
        case notSignedIn
        case identityMismatch(String)

        var errorDescription: String? {
            switch self {
            case .backendUnavailable(let m):  return "Backend unavailable: \(m)"
            case .backendRejected(let m):     return m
            case .invalidResponse:            return "Unexpected response from the backend"
            case .firestoreError(let m):      return "Firestore error: \(m)"
            case .notSignedIn:                return "Sign in to export to TheStageBee"
            case .identityMismatch(let m):    return m
            }
        }
    }

    // MARK: - State

    @Published var state: ExportState = .idle

    // MARK: - Private

    // One source of truth for the backend address, so the export and the
    // analysis can never end up pointing at different servers.
    private static var backendBase: String { JobManager.backendBaseUrl }
    private let db = Firestore.firestore()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    // MARK: - Public API

    func reset() { state = .idle }

    /// Runs the translation and returns what an export would change. Writes nothing.
    ///
    /// - Throws: `ExportError.identityMismatch` when the analysis was run for a
    ///   different song than the one being exported to — the guard that makes it
    ///   impossible to overwrite the wrong Firestore document.
    func prepare(
        job: AnalysisJob,
        jobFolder: URL,
        song: FirebaseSong,
        isSignedIn: Bool
    ) async throws -> ExportPreview {
        state = .preparing
        do {
            let preview = try await buildPreview(
                job: job, jobFolder: jobFolder, song: song, isSignedIn: isSignedIn
            )
            state = .idle
            return preview
        } catch {
            state = .failure(message: error.localizedDescription)
            throw error
        }
    }

    /// Writes a prepared preview to Firestore and returns what was recorded.
    @discardableResult
    func commit(_ preview: ExportPreview) async throws -> ExportRecord {
        state = .exporting
        do {
            try await db.collection("songs").document(preview.documentID).updateData([
                "sections": preview.sectionsPayload,
                "tempo": preview.tempoPayload,
            ])
            state = .success(documentID: preview.documentID)
            return ExportRecord(
                exportedAt: Date(),
                documentID: preview.documentID,
                songTitle: preview.songTitle,
                tempo: preview.newTempo,
                sectionCount: preview.newSections.count,
                previousTempo: preview.currentTempo,
                previousSectionCount: preview.currentSectionNames.count
            )
        } catch {
            let message = ExportError.firestoreError(error.localizedDescription).localizedDescription
            state = .failure(message: message)
            throw ExportError.firestoreError(error.localizedDescription)
        }
    }

    // MARK: - Private helpers

    private func buildPreview(
        job: AnalysisJob,
        jobFolder: URL,
        song: FirebaseSong,
        isSignedIn: Bool
    ) async throws -> ExportPreview {

        guard isSignedIn else { throw ExportError.notSignedIn }

        guard let docID = song.id, !docID.isEmpty else {
            throw ExportError.firestoreError("This song has no Firestore document ID")
        }

        // The analysis must belong to the song being written to.
        if let jobSongID = job.songDocumentID, jobSongID != docID {
            throw ExportError.identityMismatch(
                "This analysis was run for “\(job.title ?? "another song")”, not “\(song.title)”."
            )
        }

        // 1 — Translate via the local backend ------------------------------------
        guard let url = URL(string: "\(Self.backendBase)/api/translate-to-stagebee") else {
            throw ExportError.backendUnavailable("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let subdivisions = job.subdivisionsByBar
        var requestBody: [String: Any] = ["jobFolderPath": jobFolder.path]
        if !subdivisions.isEmpty {
            requestBody["barSubdivisions"] = Dictionary(
                uniqueKeysWithValues: subdivisions.map { (String($0.key), $0.value) }
            )
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw ExportError.backendUnavailable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExportError.invalidResponse
        }
        guard http.statusCode == 200, json["status"] as? String == "success" else {
            let message = json["message"] as? String ?? "HTTP \(http.statusCode)"
            throw ExportError.backendRejected(message)
        }
        guard let songData = json["song"] as? [String: Any],
              let sections = songData["sections"],
              let tempo = songData["tempo"] else {
            throw ExportError.invalidResponse
        }
        // The sheet reports the tempo change, so a tempo it cannot read is a bad
        // payload — refuse it rather than showing "unchanged" and writing anyway.
        guard let tempoValue = (tempo as? NSNumber)?.intValue else {
            throw ExportError.backendRejected("The translation returned a tempo that is not a number")
        }

        // 2 — Describe what will change ------------------------------------------
        let newSections = Self.describeSections(sections)
        guard !newSections.isEmpty else {
            throw ExportError.backendRejected("The translation produced no sections")
        }

        return ExportPreview(
            songID: docID,
            jobID: job.id,
            songTitle: song.title,
            artist: song.artists?.first?.name,
            documentID: docID,
            currentTempo: song.tempo,
            newTempo: tempoValue,
            currentSectionNames: song.sections?.map { $0.displayName } ?? [],
            newSections: newSections,
            sectionsPayload: sections,
            // The validated integer, not the raw payload: the sheet promises
            // "136 BPM", and writing the backend's 136.4 back would make the
            // confirmation a lie about what was actually stored. The document's
            // own `tempo` is an Int, so this also keeps the field's type stable.
            tempoPayload: tempoValue
        )
    }

    /// Summarises the translated sections array for the confirmation sheet.
    ///
    /// TheStageBee's schema names a section `title` and nests its bars under
    /// `lines`, so reading `name` and a flat `bars` array described every export
    /// as "Section 1 · 0 bars" — a confirmation dialog that showed nothing of
    /// what was about to be written. The older keys stay as fallbacks.
    static func describeSections(_ sections: Any) -> [ExportPreviewSection] {
        guard let list = sections as? [[String: Any]] else { return [] }
        return list.enumerated().map { index, section in
            let name = (section["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (section["name"] as? String)
                ?? (section["label"] as? String)
                ?? "Section \(index + 1)"
            let inLines = (section["lines"] as? [[String: Any]])?.reduce(0) {
                $0 + (($1["bars"] as? [Any])?.count ?? 0)
            }
            let barCount = inLines
                ?? (section["bars"] as? [Any])?.count
                ?? (section["barCount"] as? Int)
                ?? 0
            return ExportPreviewSection(index: index, name: name, barCount: barCount)
        }
    }
}
