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
            let snapshot = try await db.collection("songs")
                .order(by: "title")
                .getDocuments()

            let result = decodeSongs(from: snapshot)
            songs = result.songs
            errorMessage = result.message
            print("Loaded \(result.songs.count) songs from Firestore songs collection.")
        } catch {
            if isPermissionDenied(error) {
                do {
                    let publicSnapshot = try await db.collection("publicSongs")
                        .order(by: "title")
                        .getDocuments()

                    let result = decodeSongs(from: publicSnapshot)
                    songs = result.songs

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
            message = "Loaded \(decodedSongs.count) songs; skipped \(decodeFailures.count) document(s) with unexpected fields."
        }

        return (decodedSongs, message)
    }

    private func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FirestoreErrorDomain &&
               nsError.code == FirestoreErrorCode.permissionDenied.rawValue
    }
}