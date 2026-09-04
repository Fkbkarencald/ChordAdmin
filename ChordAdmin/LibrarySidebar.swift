import SwiftUI

// MARK: - Library sidebar
//
// The left column is the work dashboard: search, filter chips with live counts,
// a dense list where every song wears its own state, and a footer that answers
// "can this machine actually run a job right now?" without opening a panel.
//
// Songs with no YouTube link stay in the list, dimmed, rather than vanishing —
// the old grid hid them and left no way to notice a song was missing its link.

struct LibrarySidebar: View {
    let items: [LibraryItem]
    let counts: [LibraryFilter: Int]
    @Binding var filter: LibraryFilter
    @Binding var searchText: String
    @Binding var selection: String?
    let isLoading: Bool
    /// Why the last library load failed, if it did.
    var libraryError: String?
    @ObservedObject var environment: EnvironmentStore
    @ObservedObject var authStore: AuthStore
    let queue: [SongRef]
    var onRemoveFromQueue: (String) -> Void = { _ in }
    var onClearQueue: () -> Void = {}
    var onSignIn: () -> Void
    var onSignOut: () -> Void
    var onRecheckEnvironment: () -> Void

    /// Incremented by the Find command; each change moves focus to the field.
    var focusSearchToken: Int = 0

    @State private var showingQueue = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            filterChips
            songList
            footer
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 11, weight: .medium, relativeTo: .caption)
                .foregroundStyle(.secondary)
            TextField("Search songs", text: $searchText)
                .textFieldStyle(.plain)
                .scaledFont(size: 12, relativeTo: .footnote)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 6.5)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 6.5)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .onChange(of: focusSearchToken) { _, _ in searchFocused = true }
    }

    // MARK: Filters

    private var filterChips: some View {
        LibrarySidebarChipFlow(spacing: 5, lineSpacing: 5) {
            ForEach(LibraryFilter.allCases) { candidate in
                LibrarySidebarFilterChip(
                    title: candidate.title,
                    count: counts[candidate] ?? 0,
                    isSelected: candidate == filter
                ) {
                    filter = candidate
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: Song list

    private var songList: some View {
        List(selection: $selection) {
            ForEach(items) { item in
                LibrarySidebarSongRow(item: item)
                    .tag(item.id)
                    .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 30)
        // An overlay rather than a row: a sidebar List row clips its content to
        // one line however the width is proposed, so at larger text sizes the
        // message lost its ending ("Sign in to load TheStageBee…").
        .overlay(alignment: .top) {
            if items.isEmpty { placeholderRow }
        }
    }

    @ViewBuilder
    private var placeholderRow: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading songs…")
                    .scaledFont(size: 11.5, relativeTo: .caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
        } else {
            VStack(spacing: 4) {
                Text(emptyTitle)
                    .scaledFont(size: 11.5, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(emptyMessage)
                    .scaledFont(size: 10.5, relativeTo: .caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    // The width has to be proposed to the Text itself. With
                    // `maxWidth: .infinity` only on the VStack, the Text was
                    // offered unlimited width, decided it fit on one line, and
                    // was then clipped by the row — so at larger text sizes
                    // "Sign in to load TheStageBee library." lost its ending.
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .listRowSeparator(.hidden)
        }
    }

    private var emptyTitle: String {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? "No songs here"
            : "No matches"
    }

    private var emptyMessage: String {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Nothing in ‘\(filter.title)’ matches this search."
        }
        guard filter == .all else { return "Nothing is in ‘\(filter.title)’ yet." }
        if let libraryError { return libraryError }
        return authStore.isSignedIn
            ? "TheStageBee library loaded, but there are no songs in it yet."
            : "Sign in to load TheStageBee library."
    }

    // MARK: Queue

    private var queuePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting to be analysed")
                .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)

            ForEach(Array(queue.enumerated()), id: \.element.documentID) { position, song in
                HStack(spacing: 8) {
                    Text("\(position + 1)")
                        .scaledFont(size: 10, design: .monospaced, relativeTo: .caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title)
                            .scaledFont(size: 12, relativeTo: .footnote)
                            .lineLimit(1)
                        if let artist = song.artist {
                            Text(artist)
                                .scaledFont(size: 10, relativeTo: .caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        onRemoveFromQueue(song.documentID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Take “\(song.title)” out of the queue")
                }
            }

            Divider()
            Button("Clear the queue", role: .destructive) {
                onClearQueue()
                showingQueue = false
            }
            .controlSize(.small)
            Text("The song being analysed now is not affected.")
                .scaledFont(size: 10, relativeTo: .caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 260)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !queue.isEmpty {
                HStack {
                    // The queue is otherwise fire-and-forget: this is the only
                    // place a song can be taken back out of it.
                    Button {
                        showingQueue.toggle()
                    } label: {
                        StatusPill(
                            text: queue.count == 1 ? "1 queued" : "\(queue.count) queued",
                            systemImage: "clock",
                            tint: .accentColor
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Show the songs waiting to be analysed")
                    .popover(isPresented: $showingQueue, arrowEdge: .top) { queuePopover }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 7)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                environmentButton
                accountRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    /// Backend + tools. The whole block is one button so a failed check can be
    /// re-run from where it is reported, instead of hunting for a menu item.
    /// "Backend", qualified by whether it can actually be reached.
    private var backendStateLabel: String {
        guard let reachable = environment.backendAvailable else { return "Backend not checked" }
        return reachable ? "Backend ready" : "Backend unreachable"
    }

    private var environmentButton: some View {
        Button(action: onRecheckEnvironment) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(backendColour)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    // Says which state it is in. A coloured dot alone left a
                    // red-green colour-blind reader unable to tell a live
                    // backend from a dead one — and an unreachable backend is
                    // exactly why a run stalls at "audio ready".
                    Text(backendStateLabel)
                        .scaledFont(size: 11, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(.primary)
                    Text(backendDisplayURL)
                        .scaledFont(size: 10, design: .monospaced, relativeTo: .caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if environment.isChecking {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: toolsSymbol)
                        .scaledFont(size: 10, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(toolsTint)
                        .frame(width: 11)
                    Text(toolsHeadline)
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(missingToolCount > 0 ? Color.orange : Color.primary)
                        .fixedSize()
                    if !toolsDetail.isEmpty {
                        Text(toolsDetail)
                            .scaledFont(size: 11, relativeTo: .caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(environment.isChecking)
        .help(environmentHelp)
    }

    private var accountRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let email = accountEmail {
                    Image(systemName: "person.crop.circle")
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                    Text(email)
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(email)
                    Spacer(minLength: 6)
                    Button("Sign out", action: onSignOut)
                        .buttonStyle(.link)
                        .scaledFont(size: 11, relativeTo: .caption)
                } else if authStore.isSignedIn {
                    Image(systemName: "person.crop.circle")
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                    Text("Signed in")
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button("Sign out", action: onSignOut)
                        .buttonStyle(.link)
                        .scaledFont(size: 11, relativeTo: .caption)
                } else {
                    Button(action: onSignIn) {
                        HStack(spacing: 5) {
                            Image(systemName: "applelogo")
                                .scaledFont(size: 10, relativeTo: .caption2)
                            Text("Sign in with Apple")
                                .scaledFont(size: 11, relativeTo: .caption)
                        }
                    }
                    .controlSize(.small)
                    .disabled(authStore.isSigningIn)
                    .help("Signing in is needed to load the private catalogue and to export")
                    if authStore.isSigningIn {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                    }
                    Spacer(minLength: 0)
                }
            }
            // A rejected sign-in used to report itself only on the front screen,
            // which the user cannot see while a song is open — so the button they
            // just pressed simply went quiet.
            if let message = authStore.errorMessage {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .scaledFont(size: 10, relativeTo: .caption2)
                        .foregroundStyle(.red)
                    Text(message)
                        .scaledFont(size: 10, relativeTo: .caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Footer values

    private var accountEmail: String? {
        guard let email = authStore.accountEmail, !email.isEmpty else { return nil }
        return email
    }

    private var backendColour: Color {
        switch environment.backendAvailable {
        case .some(true):  return .green
        case .some(false): return .red
        case .none:        return .secondary
        }
    }

    /// "http://localhost:5051" reads as "localhost:5051" in a 264pt column.
    private var backendDisplayURL: String {
        var text = environment.backendURL
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private var missingToolCount: Int { environment.missingTools.count }

    private var toolsHeadline: String {
        guard environment.tools != nil else { return "Checking tools…" }
        if missingToolCount == 0 { return "Tools OK" }
        return missingToolCount == 1 ? "1 tool missing" : "\(missingToolCount) tools missing"
    }

    /// ffprobe ships with ffmpeg, so naming it separately just eats the line.
    private var toolsDetail: String {
        guard let report = environment.tools else { return "" }
        let names: [String] = missingToolCount == 0
            ? report.statuses.filter { $0.tool != .ffprobe }.map { $0.tool.rawValue }
            : report.missing.map { $0.rawValue }
        guard !names.isEmpty else { return "" }
        return "· " + names.joined(separator: " · ")
    }

    private var toolsSymbol: String {
        guard environment.tools != nil else { return "hourglass" }
        return missingToolCount == 0 ? "checkmark" : "exclamationmark.triangle.fill"
    }

    private var toolsTint: Color {
        guard environment.tools != nil else { return .secondary }
        return missingToolCount == 0 ? .green : .orange
    }

    private var environmentHelp: String {
        if environment.isChecking { return "Checking the backend and tools…" }
        if let checkedAt = environment.lastCheckedAt {
            return "Checked \(SongWorkState.relative(checkedAt)) — click to check again"
        }
        return "Check the backend and command-line tools again"
    }
}

// MARK: - Song row

/// One library row: artwork, title, a second line that switches between the
/// artist and the work state, and a trailing state icon.
private struct LibrarySidebarSongRow: View {
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 9) {
            SongThumbnail(url: item.thumbnailURL, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .scaledFont(size: 12.5, weight: .medium, relativeTo: .footnote)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(secondaryText)
                    .scaledFont(size: 10.5, relativeTo: .caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            statusIcon
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .opacity(isUnavailable ? 0.55 : 1)
        .help(helpText)
        // For an analysed, exported or new song the second line shows the
        // artist, so the trailing icon was the only thing carrying the work
        // state — and it reached VoiceOver only through a tooltip, which is
        // delayed and can be switched off.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [item.title, item.artist, item.state.label]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    /// The state wins the second line whenever it is something the user has to
    /// act on; otherwise the artist is more useful for finding the song.
    private var secondaryText: String {
        switch item.state {
        case .running, .queued, .failed, .audioReady, .edited:
            return item.state.label
        default:
            return item.artist ?? item.state.label
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = item.state { return true }
        return false
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.state {
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 15, height: 15)
        case .queued(let position):
            Text("\(position)")
                .scaledFont(size: 9, weight: .semibold, design: .rounded, relativeTo: .caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 15, height: 15)
                .overlay(
                    Circle().stroke(Color.secondary.opacity(0.45), lineWidth: 1)
                )
        default:
            Image(systemName: item.state.symbolName)
                .scaledFont(size: 12, relativeTo: .footnote)
                .foregroundStyle(item.state.tint)
                .frame(width: 15, height: 15)
        }
    }

    private var helpText: String {
        guard let artist = item.artist else { return item.state.label }
        return "\(artist) · \(item.state.label)"
    }
}

// MARK: - Filter chip

private struct LibrarySidebarFilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .scaledFont(size: 10.5, weight: .medium, relativeTo: .caption2)
                Text("\(count)")
                    .scaledFont(size: 10.5, weight: .medium, relativeTo: .caption2)
                    .monospacedDigit()
                    .opacity(0.65)
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, 9)
            .frame(minHeight: 21)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
            )
            .opacity(count == 0 && !isSelected ? 0.55 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show \(title.lowercased()) songs")
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "song" : "songs")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Wrapping chip row

/// Lays the filter chips out left to right, wrapping onto a second line when the
/// column is too narrow — the sidebar can be dragged between 232 and 340pt.
private struct LibrarySidebarChipFlow: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let arrangement = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? arrangement.width, height: arrangement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews: subviews, maxWidth: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let origin = arrangement.origins[index]
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(arrangement.sizes[index])
            )
        }
    }

    private func arrange(
        subviews: Subviews,
        maxWidth: CGFloat
    ) -> (origins: [CGPoint], sizes: [CGSize], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }

        return (origins, sizes, widest, y + lineHeight)
    }
}
