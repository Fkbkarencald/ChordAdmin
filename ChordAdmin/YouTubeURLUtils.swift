import Foundation

enum YouTubeURLUtils {
    /// Strips the `list` query parameter from youtu.be and youtube.com URLs so
    /// `--no-playlist` does not fail on playlist-appended share links.
    static func cleanYouTubeURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return raw
        }
        let isYouTube = components.host?.contains("youtu.be") == true
            || components.host?.contains("youtube.com") == true
        guard isYouTube, var items = components.queryItems, !items.isEmpty else {
            return raw
        }
        items.removeAll { $0.name == "list" }
        components.queryItems = items.isEmpty ? nil : items
        return components.url?.absoluteString ?? raw
    }

    /// Extracts the YouTube video ID from youtu.be or youtube.com/watch URLs.
    static func youTubeVideoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        if url.host?.contains("youtu.be") == true {
            return url.pathComponents.dropFirst().first
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first(where: { $0.name == "v" })?.value
    }
}
