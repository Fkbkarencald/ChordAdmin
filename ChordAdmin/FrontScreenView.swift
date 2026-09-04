import SwiftUI

// MARK: - Front screen
//
// The launch dashboard, shown whenever no song is selected. The old build
// dropped straight into an empty workspace, so the answer to "what should I
// work on?" lived only in the user's head. This answers it: what is half
// finished, what has never been analysed, what went out recently, and whether
// the machine is actually in a state to run anything.

struct FrontScreenView: View {
    let items: [LibraryItem]
    let isLoading: Bool
    /// Why the last library load did not work, if it did not. A failure and an
    /// empty library look identical otherwise, and the app told the user to
    /// check the analysis backend for what is really a Firestore problem.
    var libraryError: String?
    @ObservedObject var environment: EnvironmentStore
    @ObservedObject var authStore: AuthStore
    let queue: [SongRef]
    var onOpen: (LibraryItem) -> Void
    /// A from-scratch run. Goes through the same confirmation the toolbar does.
    var onAnalyse: (LibraryItem) -> Void
    /// Picks up where a stopped run left off, reusing audio already on disk.
    var onResume: (LibraryItem) -> Void
    var onAnalyseAll: ([LibraryItem]) -> Void
    var onExport: (LibraryItem) -> Void
    var onRecheckEnvironment: () -> Void
    var onReloadLibrary: () -> Void
    var onSignIn: () -> Void

    // MARK: Derived groups

    /// Work already started: edits waiting to go out first, then charts that
    /// need a look, then downloads whose analysis stopped short.
    private var continueItems: [LibraryItem] {
        let ranked: [(item: LibraryItem, rank: Int)] = items.compactMap { item -> (item: LibraryItem, rank: Int)? in
            switch item.state {
            case .edited:     return (item, 0)
            case .failed:     return (item, 1)
            case .analysed:   return (item, 2)
            case .audioReady: return (item, 3)
            default:          return nil
            }
        }
        // Stable: keep library order inside a rank.
        return ranked.enumerated()
            .sorted { lhs, rhs in
                lhs.element.rank == rhs.element.rank
                    ? lhs.offset < rhs.offset
                    : lhs.element.rank < rhs.element.rank
            }
            .prefix(2)
            .map { $0.element.item }
    }

    /// Uses the same rule as the sidebar's "New" chip so the two counts agree.
    private var newItems: [LibraryItem] {
        items.filter { LibraryFilter.new.matches($0.state) }
    }

    /// The songs "Analyse all" would actually queue.
    private var analysableNewItems: [LibraryItem] {
        newItems.filter { $0.ref != nil }
    }

    private var todoItems: [LibraryItem] {
        Array(newItems.prefix(5))
    }

    private var hiddenTodoCount: Int {
        max(0, newItems.count - todoItems.count)
    }

    private var exportedItems: [LibraryItem] {
        items.compactMap { item -> (LibraryItem, Date)? in
            guard let exportedAt = item.job?.lastExport?.exportedAt else { return nil }
            return (item, exportedAt)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(3)
        .map { $0.0 }
    }

    private var exportedCount: Int {
        items.filter { $0.job?.lastExport != nil }.count
    }

    /// Why "Analyse all" is unavailable, phrased as the thing to go and fix.
    private var blockedReason: String? {
        var reasons: [String] = []
        if environment.backendAvailable != true {
            reasons.append("the analysis backend at \(FrontScreenFormat.shortURL(environment.backendURL)) is not reachable")
        }
        if environment.tools == nil {
            reasons.append("the tool check has not finished")
        } else if !environment.missingTools.isEmpty {
            let names = environment.missingTools.map(\.rawValue).joined(separator: ", ")
            reasons.append("these tools are missing: \(names)")
        }
        guard !reasons.isEmpty else { return nil }
        return "Cannot analyse yet — " + reasons.joined(separator: ", and ") + "."
    }

    // MARK: Body

    var body: some View {
        Group {
            if items.isEmpty && isLoading {
                loadingState
            } else if items.isEmpty {
                emptyState
            } else {
                dashboard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading the library…")
                .scaledFont(size: 12, relativeTo: .footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            EmptyStateView(
                title: libraryError == nil ? "Nothing in the library yet" : "Could not load the library",
                message: {
                    if let libraryError { return libraryError }
                    return authStore.isSignedIn
                        ? "TheStageBee library loaded, but there are no songs in it yet."
                        : "Sign in with the account that owns TheStageBee library to load your songs."
                }(),
                systemImage: libraryError == nil ? "music.note.list" : "exclamationmark.triangle"
            )
            .frame(height: 120)

            if authStore.isSignedIn {
                Button("Reload library", action: onReloadLibrary)
                    .controlSize(.small)
                    .disabled(isLoading)
            } else {
                Button(action: onSignIn) {
                    Label("Sign in with Apple", systemImage: "applelogo")
                }
                .controlSize(.regular)
                .disabled(authStore.isSigningIn)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Below this the side column would squeeze the song cards, so the dashboard
    /// stacks instead. Measured rather than inferred from intrinsic sizes, which
    /// the adaptive card grid makes unreliable.
    private static let twoColumnMinimumWidth: CGFloat = 780

    private var dashboard: some View {
        GeometryReader { geo in
            ScrollView {
                Group {
                    if geo.size.width >= Self.twoColumnMinimumWidth {
                        HStack(alignment: .top, spacing: 24) {
                            mainColumn.frame(maxWidth: .infinity, alignment: .leading)
                            sideColumn.frame(width: 300)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 24) {
                            mainColumn
                            sideColumn
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
                .frame(maxWidth: 1080)
            }
        }
    }

    // MARK: Left column

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !queue.isEmpty {
                StatusPill(
                    text: queue.count == 1 ? "1 song queued for analysis"
                                           : "\(queue.count) songs queued for analysis",
                    systemImage: "clock",
                    tint: .accentColor
                )
            }

            if !continueItems.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    GroupLabel("Continue")
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(continueItems) { item in
                            FrontScreenContinueCard(
                                item: item,
                                onOpen: onOpen,
                                onAnalyse: onAnalyse,
                                onResume: onResume,
                                onExport: onExport
                            )
                        }
                        if continueItems.count == 1 {
                            // Keep a lone card at half width rather than letting
                            // it stretch across the pane.
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }

            if !newItems.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    todoHeader
                    todoGrid
                }
            }

            Text("Select a song on the left — or open one above — to see its chart. Analysis runs in the background as a queue, so you can keep editing one song while others analyse.")
                .scaledFont(size: 10.5, relativeTo: .caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Says plainly why "Analyse all N" can be smaller than the count beside it,
    /// rather than leaving two numbers to contradict each other.
    private var todoCaption: String {
        let total = newItems.count
        let unlinked = total - analysableNewItems.count
        let base = total == 1 ? "1 song not yet analysed" : "\(total) songs not yet analysed"
        guard unlinked > 0 else { return base }
        return base + (unlinked == 1 ? " · 1 has no YouTube link" : " · \(unlinked) have no YouTube link")
    }

    private var todoHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            GroupLabel("New in the library")
            Text(todoCaption)
                .scaledFont(size: 10.5, relativeTo: .caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button {
                onAnalyseAll(analysableNewItems)
            } label: {
                Label("Analyse all \(analysableNewItems.count)", systemImage: "clock.arrow.circlepath")
            }
            .controlSize(.small)
            .disabled(analysableNewItems.isEmpty || !(environment.tools?.allAvailable ?? false))
            .help(environment.isReady
                  ? "Queue every song that has not been analysed yet."
                  : (blockedReason ?? "The environment is not ready."))
        }
    }

    private var todoGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 12, alignment: .top)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(todoItems) { item in
                FrontScreenTodoCard(item: item, onOpen: onOpen, onAnalyse: onAnalyse, onResume: onResume)
            }
            if hiddenTodoCount > 0 {
                FrontScreenMoreTile(count: hiddenTodoCount)
            }
        }
    }

    // MARK: Right column

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                GroupLabel("Recently exported")
                PanelCard(padding: 13) {
                    if exportedItems.isEmpty {
                        Text("Nothing exported yet. A song appears here once its chart has gone to TheStageBee.")
                            .scaledFont(size: 11, relativeTo: .caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(exportedItems) { item in
                            FrontScreenExportedRow(item: item, onOpen: onOpen)
                        }
                        Text(exportedCount == 1 ? "1 exported song in the library"
                                                : "\(exportedCount) exported songs in the library")
                            .scaledFont(size: 10.5, relativeTo: .caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                GroupLabel("Environment")
                FrontScreenEnvironmentCard(
                    environment: environment,
                    authStore: authStore,
                    onRecheckEnvironment: onRecheckEnvironment,
                    onSignIn: onSignIn
                )
            }
        }
    }
}

// MARK: - Continue card

/// A large card for a song with work already in it. The status line names the
/// state in words and the buttons offer only the step that actually comes next.
private struct FrontScreenContinueCard: View {
    let item: LibraryItem
    var onOpen: (LibraryItem) -> Void
    var onAnalyse: (LibraryItem) -> Void
    var onResume: (LibraryItem) -> Void
    var onExport: (LibraryItem) -> Void

    var body: some View {
        PanelCard(padding: 14) {
            HStack(spacing: 11) {
                SongThumbnail(url: item.thumbnailURL, size: 52, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .scaledFont(size: 13.5, weight: .semibold, relativeTo: .subheadline)
                        .lineLimit(1)
                    Text(item.artist ?? "Unknown artist")
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Image(systemName: item.state.symbolName)
                    .scaledFont(size: 10, weight: .semibold, relativeTo: .caption2)
                Text(statusText)
                    .scaledFont(size: 11, relativeTo: .caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(item.state.tint)

            HStack(spacing: 8) {
                actions
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private var statusText: String {
        switch item.state {
        case .edited:
            if let count = item.job?.sectionCount, count > 0 {
                return "Edited since last export — \(count) section\(count == 1 ? "" : "s") ready"
            }
            return item.state.label
        case .audioReady:
            return "Audio already downloaded — analysis paused"
        default:
            return item.state.label
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .edited:
            Button("Open") { onOpen(item) }
            Button("Export to TheStageBee…") { onExport(item) }
                .buttonStyle(.borderedProminent)
                // The label truncates in a half-width card at narrow widths.
                .help("Review the changes, then update this song in TheStageBee")
        case .audioReady:
            // Genuinely resumes. Routing this through a from-scratch run
            // re-downloaded and re-converted the whole track, which is exactly
            // what the card above it says is unnecessary.
            Button("Resume analysis") { onResume(item) }
                .buttonStyle(.borderedProminent)
        case .failed:
            Button("See what failed") { onOpen(item) }
                .buttonStyle(.borderedProminent)
            Button("Try again") { onResume(item) }
        default:
            Button("Review sections") { onOpen(item) }
        }
    }
}

// MARK: - New-song card

private struct FrontScreenTodoCard: View {
    let item: LibraryItem
    var onOpen: (LibraryItem) -> Void
    var onAnalyse: (LibraryItem) -> Void
    var onResume: (LibraryItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            FrontScreenBanner(url: item.thumbnailURL)
            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                        .lineLimit(1)
                    Text(item.artist ?? "Unknown artist")
                        .scaledFont(size: 10.5, relativeTo: .caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Analyse") { onAnalyse(item) }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .disabled(item.ref == nil)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture { onOpen(item) }
        .help(item.ref == nil ? "This song has no usable YouTube link." : item.title)
        // As a bare tap gesture the only focusable control on the card was
        // "Analyse", so a keyboard user could start a whole re-run but never
        // just open the song. FrontScreenExportedRow is already a Button; this
        // makes the card reachable the same way.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), \(item.artist ?? "unknown artist")")
        .accessibilityAction(named: "Open") { onOpen(item) }
    }
}

/// The "+ N more" tile that closes the grid without pretending the list is short.
private struct FrontScreenMoreTile: View {
    let count: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 11)
            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            .foregroundStyle(.quaternary)
            .overlay(
                Text("+ \(count) more")
                    .scaledFont(size: 11.5, relativeTo: .caption)
                    .foregroundStyle(.secondary)
            )
            .frame(maxWidth: .infinity, minHeight: 140)
    }
}

/// The wide artwork strip on a new-song card. `SongThumbnail` is square by
/// design, so the grid uses the 16:9 YouTube still directly.
private struct FrontScreenBanner: View {
    let url: URL?
    var height: CGFloat = 88

    // Decorative artwork: the card's title is the identity.
    var body: some View {
        banner.accessibilityHidden(true)
    }

    private var banner: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
    }

    private var fallbackIcon: some View {
        Image(systemName: "music.note")
            .scaledFont(size: 20, relativeTo: .title3)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Recently exported

private struct FrontScreenExportedRow: View {
    let item: LibraryItem
    var onOpen: (LibraryItem) -> Void

    var body: some View {
        Button {
            onOpen(item)
        } label: {
            HStack(spacing: 9) {
                SongThumbnail(url: item.thumbnailURL, size: 28, cornerRadius: 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .scaledFont(size: 12, weight: .medium, relativeTo: .footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .scaledFont(size: 10, relativeTo: .caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 12, relativeTo: .footnote)
                    .foregroundStyle(.green)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        guard let export = item.job?.lastExport else { return item.state.label }
        let stamp = FrontScreenFormat.stamp(export.exportedAt)
        // The list is keyed on what was actually exported, so a song edited since
        // still belongs here — say so rather than hiding it.
        if case .edited = item.state { return "\(stamp) · edited since" }
        return stamp
    }
}

// MARK: - Environment

/// Backend, tools and account in one card, because all three have to be right
/// before a single song can be analysed or exported.
private struct FrontScreenEnvironmentCard: View {
    @ObservedObject var environment: EnvironmentStore
    @ObservedObject var authStore: AuthStore
    var onRecheckEnvironment: () -> Void
    var onSignIn: () -> Void

    var body: some View {
        PanelCard(padding: 13) {
            backendRow
            Divider().opacity(0.5)
            toolsSection
            Divider().opacity(0.5)
            accountSection
            footer
        }
    }

    // Backend

    private var backendRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "circle.fill")
                .scaledFont(size: 7, relativeTo: .caption2)
                .foregroundStyle(backendTint)
            Text(backendTitle)
                .scaledFont(size: 11.5, relativeTo: .caption)
            Text(FrontScreenFormat.shortURL(environment.backendURL))
                .scaledFont(size: 10, design: .monospaced, relativeTo: .caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var backendTitle: String {
        switch environment.backendAvailable {
        case .some(true):  return "Backend running"
        case .some(false): return "Backend not reachable"
        case .none:        return "Backend not checked"
        }
    }

    private var backendTint: Color {
        switch environment.backendAvailable {
        case .some(true):  return .green
        case .some(false): return .red
        case .none:        return .secondary
        }
    }

    // Tools

    @ViewBuilder
    private var toolsSection: some View {
        if let report = environment.tools {
            HStack(spacing: 7) {
                Image(systemName: report.allAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .scaledFont(size: 11, relativeTo: .caption)
                    .foregroundStyle(report.allAvailable ? Color.green : Color.orange)
                Text(report.allAvailable
                     ? "Tools ready"
                     : (report.missing.count == 1 ? "1 tool missing" : "\(report.missing.count) tools missing"))
                    .scaledFont(size: 11.5, relativeTo: .caption)
                Spacer(minLength: 0)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 6, alignment: .leading),
                          GridItem(.flexible(), spacing: 6, alignment: .leading)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(Tool.allCases) { tool in
                    let available = report.status(for: tool)?.isAvailable ?? false
                    HStack(spacing: 5) {
                        Image(systemName: available ? "checkmark" : "xmark")
                            .scaledFont(size: 9, weight: .bold, relativeTo: .caption2)
                            .foregroundStyle(available ? Color.green : Color.red)
                            .frame(width: 10)
                        Text(tool.rawValue)
                            .scaledFont(size: 10.5, relativeTo: .caption2)
                            .foregroundStyle(available ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    .help(available
                          ? (report.status(for: tool)?.path ?? tool.rawValue)
                          : "\(tool.rawValue) — \(tool.purpose). Install with: \(tool.installHint)")
                }
            }

            ForEach(report.missingDescriptions, id: \.self) { description in
                Text(description)
                    .scaledFont(size: 10, relativeTo: .caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 7) {
                Image(systemName: "wrench.and.screwdriver")
                    .scaledFont(size: 11, relativeTo: .caption)
                    .foregroundStyle(.secondary)
                Text(environment.isChecking ? "Checking tools…" : "Tools not checked yet")
                    .scaledFont(size: 11.5, relativeTo: .caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    // Account

    @ViewBuilder
    private var accountSection: some View {
        if authStore.isSignedIn {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle")
                    .scaledFont(size: 11, relativeTo: .caption)
                    .foregroundStyle(.secondary)
                Text(authStore.accountEmail ?? "Signed in")
                    .scaledFont(size: 11.5, relativeTo: .caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("Can export")
                    .scaledFont(size: 10, relativeTo: .caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.orange)
                    Text("Not signed in")
                        .scaledFont(size: 11.5, relativeTo: .caption)
                    Spacer(minLength: 0)
                }
                Text("Charts cannot be exported to TheStageBee until you sign in.")
                    .scaledFont(size: 10, relativeTo: .caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onSignIn) {
                    if authStore.isSigningIn {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("Signing in…")
                        }
                    } else {
                        Label("Sign in with Apple", systemImage: "applelogo")
                    }
                }
                .controlSize(.small)
                .disabled(authStore.isSigningIn)
            }
        }

        if let message = authStore.errorMessage {
            Text(message)
                .scaledFont(size: 10, relativeTo: .caption2)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if environment.isChecking {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text("Checking…")
                    .scaledFont(size: 10, relativeTo: .caption2)
                    .foregroundStyle(.tertiary)
            } else if let checkedAt = environment.lastCheckedAt {
                Text("Checked \(SongWorkState.relative(checkedAt))")
                    .scaledFont(size: 10, relativeTo: .caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button("Check again", action: onRecheckEnvironment)
                .controlSize(.small)
                .disabled(environment.isChecking)
        }
        .padding(.top, 1)
    }
}

// MARK: - Formatting

private enum FrontScreenFormat {

    /// "localhost:5051" — the scheme adds nothing in a status line.
    static func shortURL(_ urlString: String) -> String {
        var trimmed = urlString
        for prefix in ["https://", "http://"] where trimmed.hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count))
        }
        if trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        return trimmed
    }

    /// "today · 18:40", "yesterday · 18:40", "Mon · 21:12", "24 Aug · 10:05".
    static func stamp(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)

        if calendar.isDateInToday(date) { return "today · \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday · \(time)" }

        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0

        if days > 0 && days < 7 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) · \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) · \(time)"
    }
}
