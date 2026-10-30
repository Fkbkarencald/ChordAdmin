import Foundation

// Local analyses remain separate from canonical song IDs until publication.
@MainActor
extension SongImportRecord {
    var workspaceID: String { "staging-" + id }

    var workspaceSong: FirebaseSong {
        FirebaseSong(id: workspaceID, storedTitle: reviewFields.title,
                     key: reviewFields.key, tempo: nil,
                     artists: [FirebaseSongArtist(name: reviewFields.artist, alternativeName: nil)],
                     link: source.url, sections: nil)
    }

    var ref: SongRef {
        SongRef(documentID: workspaceID, title: reviewFields.title,
                artist: reviewFields.artist, url: source.url)
    }
}
