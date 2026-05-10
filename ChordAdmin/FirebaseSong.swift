import Foundation
import FirebaseFirestore

struct FirebaseSongArtist: Codable, Hashable {
    let name: String
    let alternativeName: String?
}

struct FirebaseSong: Identifiable, Codable, Hashable {
    @DocumentID var id: String?

    let title: String
    let key: String?
    let tempo: Int?
    let artists: [FirebaseSongArtist]?
    let link: String?
    let sections: [FirebaseSongSection]?
}

struct FirebaseSongSection: Codable, Hashable {
    let id: String?
    let name: String?
}