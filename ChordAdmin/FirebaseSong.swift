import Foundation
import FirebaseFirestore

struct FirebaseSongArtist: Codable, Hashable {
    let name: String
    let alternativeName: String?
}

struct FirebaseSong: Identifiable, Codable, Hashable {
    @DocumentID var id: String?

    /// Optional on purpose. A required title meant one document with a missing
    /// or oddly-typed field failed to decode and vanished from the library
    /// entirely — the user concluded the song did not exist and made a
    /// duplicate. A song with no title is better shown as untitled.
    let storedTitle: String?
    let key: String?
    let tempo: Int?
    let artists: [FirebaseSongArtist]?
    let link: String?
    let sections: [FirebaseSongSection]?

    var title: String {
        guard let storedTitle, !storedTitle.isEmpty else { return "Untitled song" }
        return storedTitle
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case storedTitle = "title"
        case key, tempo, artists, link, sections
    }
}

struct FirebaseSongSection: Codable, Hashable {
    let id: String?
    let name: String?
    /// What this app actually writes. Reading only `name` made every section
    /// this app had exported read back as unnamed, so the sheet told the user
    /// they were overwriting nothing.
    let title: String?

    var displayName: String {
        let candidates = [title, name].compactMap { $0 }
        return candidates.first(where: { !$0.isEmpty }) ?? "Untitled section"
    }

    /// TheStageBee's editor numbers its sections (`"id": 79`). Reading `id` only
    /// as text made every such song fail to decode, so 166 of 391 songs were
    /// missing from the library and from search.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decodeIfPresent(String.self, forKey: .id) {
            id = text
        } else {
            id = (try? container.decodeIfPresent(Int.self, forKey: .id)).flatMap { $0 }.map(String.init)
        }
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
    }

    init(id: String?, name: String?, title: String?) {
        self.id = id
        self.name = name
        self.title = title
    }
}