import SwiftUI

struct SidebarFixture: View {
    @State private var selection: String? = "layout-1"
    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    @StateObject private var environment = EnvironmentStore()
    @StateObject private var auth = AuthStore()
    private var items: [LibraryItem] {
        (1...221).map { number in
            LibraryItem(song: FirebaseSong(id: "layout-\(number)", storedTitle: "Fixture Song \(String(format: "%03d", number))",
                key: nil, tempo: nil, artists: [FirebaseSongArtist(name: "Local Layout Test", alternativeName: nil)], link: nil, sections: nil),
                job: nil, state: .new)
        }
    }
    var body: some View {
        NavigationSplitView {
            LibrarySidebar(items: Library.filter(items, by: filter, search: search), counts: Library.counts(for: items),
                filter: $filter, searchText: $search, selection: $selection, isLoading: false,
                environment: environment, authStore: auth, queue: [], onSignIn: {}, onSignOut: {}, onRecheckEnvironment: {})
                .navigationSplitViewColumnWidth(min: 232, ideal: 264, max: 340)
        } detail: {
            VStack(spacing: 12) {
                Text("Sidebar layout test").font(.title)
                Text("\(Library.filter(items, by: filter, search: search).count) shown · Selected: \(selection ?? "none")")
                Text("Synthetic catalogue only. No account, media or production data is used.").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

@main
struct SidebarTestApp: App {
    var body: some Scene {
        WindowGroup("ChordAdmin Sidebar Test") { SidebarFixture() }
            .defaultSize(width: 1080, height: 640)
    }
}
