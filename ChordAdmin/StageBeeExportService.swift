import Foundation
import Combine
import FirebaseFirestore

// MARK: - StageBeeExportService

/// Translates a completed ChordAdmin job to TheStageBee's Song schema and writes
/// the result to the Firestore `songs` collection.
///
/// Usage:
///   ```swift
///   @StateObject private var exportService = StageBeeExportService()
///
///   try await exportService.export(
///       job: job,
///       jobFolder: jobManager.jobFolder!,
///       songTitle: "Amazing Grace",
///       songKey: "G"
///   )
///   ```
@MainActor
final class StageBeeExportService: ObservableObject {

    // MARK: - Nested types

    enum ExportState: Equatable {
        case idle
        case exporting
        case success(documentID: String)
        case failure(message: String)
    }

    enum ExportError: LocalizedError {
        case backendUnavailable(String)
        case backendRejected(String)
        case invalidResponse
        case firestoreError(String)

        var errorDescription: String? {
            switch self {
            case .backendUnavailable(let m):  return "Backend unavailable: \(m)"
            case .backendRejected(let m):     return m
            case .invalidResponse:            return "Unexpected response from backend"
            case .firestoreError(let m):      return "Firestore error: \(m)"
            }
        }
    }

    // MARK: - State

    @Published var state: ExportState = .idle

    // MARK: - Private

    private static let backendBase = "http://localhost:5001"
    private let db = Firestore.firestore()

    // MARK: - Public API

    /// Update an existing TheStageBee Song document with chord sections and tempo
    /// derived from the ChordAdmin analysis job.
    ///
    /// Only `sections` and `tempo` are changed — title, key, artists, link and all
    /// other fields on the existing document are left untouched.
    ///
    /// - Parameters:
    ///   - job:       The completed AnalysisJob.
    ///   - jobFolder: URL of the job folder.
    ///   - song:      The existing FirebaseSong whose Firestore document to update.
    ///
    /// - Returns: The Firestore document ID that was updated.
    @discardableResult
    func export(
        job: AnalysisJob,
        jobFolder: URL,
        song: FirebaseSong,
        barSubdivisions: [Int: Int] = [:]
    ) async throws -> String {
        state = .exporting

        do {
            let docID = try await _performExport(job: job, jobFolder: jobFolder, song: song, barSubdivisions: barSubdivisions)
            state = .success(documentID: docID)
            return docID
        } catch {
            state = .failure(message: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Private helpers

    private func _performExport(
        job: AnalysisJob,
        jobFolder: URL,
        song: FirebaseSong,
        barSubdivisions: [Int: Int] = [:]
    ) async throws -> String {

        guard let docID = song.id, !docID.isEmpty else {
            throw ExportError.firestoreError("Song has no Firestore document ID")
        }

        // 1 — Call Python backend for translation ---------------------------------
        guard let url = URL(string: "\(Self.backendBase)/api/translate-to-stagebee") else {
            throw ExportError.backendUnavailable("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // Convert [Int: Int] keys to String for JSON serialisation
        let barSubdivisionsStringKeys = Dictionary(uniqueKeysWithValues:
            barSubdivisions.map { (String($0.key), $0.value) }
        )
        var requestBody: [String: Any] = ["jobFolderPath": jobFolder.path]
        if !barSubdivisionsStringKeys.isEmpty {
            requestBody["barSubdivisions"] = barSubdivisionsStringKeys
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ExportError.backendUnavailable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ExportError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExportError.invalidResponse
        }

        guard http.statusCode == 200, json["status"] as? String == "success" else {
            let msg = json["message"] as? String ?? "HTTP \(http.statusCode)"
            throw ExportError.backendRejected(msg)
        }

        guard let songData = json["song"] as? [String: Any] else {
            throw ExportError.invalidResponse
        }

        // 2 — Extract only the fields we want to update ---------------------------
        // sections: full translated chord chart
        // tempo:    rounded BPM from beat analysis (already an Int in the payload)
        guard let sections = songData["sections"],
              let tempo = songData["tempo"] else {
            throw ExportError.invalidResponse
        }

        let updates: [String: Any] = [
            "sections": sections,
            "tempo": tempo,
        ]

        // 3 — Update existing Firestore document ----------------------------------
        do {
            try await db.collection("songs").document(docID).updateData(updates)
            return docID
        } catch {
            throw ExportError.firestoreError(error.localizedDescription)
        }
    }
}
