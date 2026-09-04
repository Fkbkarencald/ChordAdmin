import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class FirebaseSongStore: ObservableObject {
    @Published var songs: [FirebaseSong] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let db = Firestore.firestore()

    func fetchSongs() async {
        isLoading = true
        errorMessage = nil

        do {
            // Deliberately unordered: Firestore excludes documents that lack the
            // ordering field, so ordering by title here silently hid every song
            // with no title — they never even reached the client to be counted.
            let snapshot = try await db.collection("songs").getDocuments()

            let result = decodeSongs(from: snapshot)
            songs = Self.sorted(result.songs)
            errorMessage = result.message
            print("Loaded \(result.songs.count) songs from Firestore songs collection.")
        } catch {
            if isPermissionDenied(error) {
                do {
                    let publicSnapshot = try await db.collection("publicSongs").getDocuments()

                    let result = decodeSongs(from: publicSnapshot)
                    songs = Self.sorted(result.songs)

                    let fallbackMessage: String
                    if let decodeMessage = result.message {
                        fallbackMessage = "No permission for songs; loaded publicSongs instead. \(decodeMessage)"
                    } else {
                        fallbackMessage = "No permission for songs; loaded publicSongs instead."
                    }
                    errorMessage = fallbackMessage
                    print("Loaded \(result.songs.count) songs from Firestore publicSongs collection (fallback).")
                } catch {
                    songs = []
                    errorMessage = error.localizedDescription
                    print("Firestore publicSongs fallback failed: \(error.localizedDescription)")
                }
            } else {
                songs = []
                errorMessage = error.localizedDescription
                print("Firestore songs load failed: \(error.localizedDescription)")
            }
        }

        isLoading = false
    }

    private func decodeSongs(from snapshot: QuerySnapshot) -> (songs: [FirebaseSong], message: String?) {
        var decodedSongs: [FirebaseSong] = []
        var decodeFailures: [String] = []

        for document in snapshot.documents {
            do {
                decodedSongs.append(try document.data(as: FirebaseSong.self))
            } catch {
                decodeFailures.append(document.documentID)
            }
        }

        let message: String?
        if decodeFailures.isEmpty {
            message = nil
        } else {
            // Name them. The IDs were already collected and then thrown away,
            // leaving the user told that songs were skipped but not which — so
            // there was no way to go and fix the documents.
            let named = decodeFailures.prefix(5).joined(separator: ", ")
            let rest = decodeFailures.count > 5 ? " and \(decodeFailures.count - 5) more" : ""
            message = "Loaded \(decodedSongs.count) songs. Skipped \(decodeFailures.count) "
                + (decodeFailures.count == 1 ? "document" : "documents")
                + " that could not be read: \(named)\(rest)."
        }

        return (decodedSongs, message)
    }

    /// Title order, the way the list used to be sorted server-side, but without
    /// dropping the songs that have no title.
    private static func sorted(_ songs: [FirebaseSong]) -> [FirebaseSong] {
        songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FirestoreErrorDomain &&
               nsError.code == FirestoreErrorCode.permissionDenied.rawValue
    }
}