import SwiftUI

/// The whole app: library on the left, the song being worked on in the middle,
/// and an inspector on the right.
///
/// Replaces the old two-page push navigation, where the browser and the
/// processing screen were separate destinations and job state was app-global.
/// A one-off message for something that went wrong where the layout has nowhere
/// to put it.
private struct ActionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ContentView: View {
    /// Only so the quit handler can reach the job manager this window owns.
    /// Optional because the render and test harnesses build the view directly.
    var appDelegate: ChordAdminAppDelegate?

    @AppStorage(TextSizeSetting.storageKey) private var textSize = TextSizeSetting.defaultRawValue

    @StateObject private var jobManager = JobManager()
    @StateObject private var songStore = FirebaseSongStore()
    @StateObject private var authStore = AuthStore()
    @StateObject private var environment = EnvironmentStore()
    @StateObject private var exportService = StageBeeExportService()
    @StateObject private var sectionStore = SectionStore()
    @StateObject private var audioPlayer = ChordAudioPlayer()
    @StateObject private var waveformLoader = WaveformLoader()

    // Library. Restored between launches so reopening the app puts the user
    // back where they were rather than on a blank front screen.
    @SceneStorage("selectedSongID") private var storedSelection: String = ""
    @SceneStorage("libraryFilter") private var storedFilter: String = LibraryFilter.all.rawValue
    @State private var selection: String?
    @State private var searchText = ""
    @State private var searchFocusToken = 0
    @State private var hasRestoredSelection = false

    // Workspace
    @State private var selectedBar: Int?
    @State private var waveZoom: CGFloat = 1
    @State private var followPlayhead = true
    @State private var loadedBars: [ChordChartBarEntry] = []
    @State private var rawChords: [CleanedChord] = []

    // Inspector
    @SceneStorage("inspectorVisible") private var showInspector: Bool = true
    @SceneStorage("inspectorTab") private var storedInspectorTab: String = InspectorTab.bar.rawValue
    @State private var tuning = TuningDraft()
    @State private var previewBars: [ChordChartBarEntry] = []
    @State private var previewRequest = 0
    /// Cached: reading these parses beat.detection.json, and body runs often.
    @State private var pickupBeatTimes: [Double] = []

    // Sheets
    @State private var exportPreview: ExportPreview?
    @State private var exportErrorMessage: String?
    /// An action that went wrong with nowhere in the layout to report it.
    @State private var actionAlert: ActionAlert?
    /// The song a re-analysis is waiting on confirmation for.
    @State private var reanalyseCandidate: LibraryItem?
    @State private var isPreparingExport = false
    @State private var renamingSection: ChordSection?
    @State private var renameText = ""

    /// Scene-storage only holds primitives, so the enums are bridged here.
    private var filter: Binding<LibraryFilter> {
        Binding(
            get: { LibraryFilter(rawValue: storedFilter) ?? .all },
            set: { storedFilter = $0.rawValue }
        )
    }

    private var inspectorTabBinding: Binding<InspectorTab> {
        Binding(
            get: { InspectorTab(rawValue: storedInspectorTab) ?? .bar },
            set: { storedInspectorTab = $0.rawValue }
        )
    }

    private var inspectorTab: InspectorTab {
        InspectorTab(rawValue: storedInspectorTab) ?? .bar
    }

    // MARK: - Derived

    private var items: [LibraryItem] {
        Library.items(songs: songStore.songs, jobManager: jobManager)
    }

    private var filteredItems: [LibraryItem] {
        Library.filter(items, by: filter.wrappedValue, search: searchText)
    }

    private var selectedItem: LibraryItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    private var selectedJob: AnalysisJob? {
        selection.flatMap { jobManager.job(for: $0) }
    }

    /// Bars the chart shows: the live tuning preview when one is pending,
    /// otherwise the bars written to disk.
    private var displayBars: [ChordChartBarEntry] {
        tuning.isDirty && !previewBars.isEmpty ? previewBars : loadedBars
    }

    /// Bars whose chords differ between the applied chart and the preview, so
    /// the user can see what a pending tuning change would actually do.
    private var changedBars: Set<Int> {
        guard tuning.isDirty, !previewBars.isEmpty else { return [] }
        let applied = Dictionary(loadedBars.map { ($0.bar, chordSignature($0)) },
                                 uniquingKeysWith: { first, _ in first })
        return Set(previewBars.compactMap { bar in
            applied[bar.bar] != chordSignature(bar) ? bar.bar : nil
        })
    }

    /// The settings the preview actually depends on. `manualBpmText` is excluded
    /// deliberately: it changes on every keystroke, while the parsed value it
    /// resolves to usually does not.
    private var previewKey: String {
        [
            String(tuning.offset),
            String(tuning.beatsPerBar),
            String(tuning.halved),
            tuning.manualBpm.map { String(format: "%.2f", $0) } ?? "-",
            String(tuning.isDirty),
        ].joined(separator: "|")
    }

    private func chordSignature(_ bar: ChordChartBarEntry) -> String {
        bar.chords.map(\.displayChord).joined(separator: "-") + "|" + (bar.primaryChord ?? "")
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(
                items: filteredItems,
                counts: Library.counts(for: items),
                filter: filter,
                searchText: $searchText,
                selection: $selection,
                isLoading: songStore.isLoading,
                libraryError: songStore.errorMessage,
                environment: environment,
                authStore: authStore,
                queue: jobManager.queue,
                onRemoveFromQueue: { jobManager.removeFromQueue($0) },
                onClearQueue: { jobManager.clearQueue() },
                onSignIn: { authStore.signInWithApple() },
                onSignOut: { authStore.signOut() },
                onRecheckEnvironment: { Task { await environment.refresh() } },
                focusSearchToken: searchFocusToken
            )
            .navigationSplitViewColumnWidth(min: 232, ideal: 264, max: 340)
        } detail: {
            detail
                .inspector(isPresented: $showInspector) {
                    InspectorView(
                        tab: inspectorTabBinding,
                        item: selectedItem,
                        job: selectedJob,
                        bars: displayBars,
                        selectedBar: $selectedBar,
                        tuning: $tuning,
                        sectionStore: sectionStore,
                        jobManager: jobManager,
                        environment: environment,
                        isSignedIn: authStore.isSignedIn,
                        isPreviewing: tuning.isDirty && !previewBars.isEmpty,
                        onApplyTuning: applyTuning,
                        onRevertTuning: { tuning.revert() },
                        onSubdivisionChange: setSubdivision,
                        onSplit: splitSection,
                        onMerge: mergeSection,
                        onRename: beginRename,
                        onRetryStage: retryStage,
                        onCancelRun: { jobManager.cancelRun() },
                        onResume: startAnalysis,
                        onRedetectBeats: redetectBeats
                    )
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                }
        }
        .frame(minWidth: 1080, minHeight: 640)
        .toolbar { toolbarContent }
        .sheet(item: $exportPreview) { preview in
            ExportSheet(
                preview: preview,
                isExporting: exportService.state == .exporting,
                errorMessage: exportErrorMessage,
                onCancel: {
                    exportPreview = nil
                    exportErrorMessage = nil
                    exportService.reset()
                },
                onConfirm: confirmExport
            )
        }
        .sheet(item: $renamingSection) { section in
            RenameSectionSheet(
                name: $renameText,
                onCancel: { renamingSection = nil },
                onSave: {
                    sectionStore.rename(section: section.id, to: renameText)
                    renamingSection = nil
                }
            )
        }
        // An export that fails before the sheet opens (backend down, signed out,
        // job/song mismatch) has nowhere else to surface, so it gets an alert.
        .chordAdminTextScale(TextSizeSetting.scale(for: textSize))
        .alert(
            "Could not prepare the export",
            isPresented: Binding(
                get: { exportPreview == nil && exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("OK") { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .confirmationDialog(
            reanalyseTitle,
            isPresented: Binding(
                get: { reanalyseCandidate != nil },
                set: { if !$0 { reanalyseCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Analyse Again", role: .destructive) {
                if let item = reanalyseCandidate { analyse(item) }
                reanalyseCandidate = nil
            }
            Button("Cancel", role: .cancel) { reanalyseCandidate = nil }
        } message: {
            Text(reanalyseMessage)
        }
        .alert(
            actionAlert?.title ?? "",
            isPresented: Binding(
                get: { actionAlert != nil },
                set: { if !$0 { actionAlert = nil } }
            )
        ) {
            Button("OK") { actionAlert = nil }
        } message: {
            Text(actionAlert?.message ?? "")
        }
        .task {
            appDelegate?.jobManager = jobManager
            await jobManager.hydrate()
            await environment.refresh()
            if songStore.songs.isEmpty { await songStore.fetchSongs() }
            restoreSelectionIfPossible()
        }
        .onChange(of: songStore.songs.count) { _, _ in
            // The library arrives asynchronously (and again after signing in),
            // so a one-shot restore in .task usually ran too early.
            restoreSelectionIfPossible()
        }
        .onChange(of: selection) { _, newValue in
            storedSelection = newValue ?? ""
        }
        .onChange(of: authStore.isSignedIn) { _, isSignedIn in
            if isSignedIn { Task { await songStore.fetchSongs() } }
        }
        .task(id: workspaceKey) { await loadWorkspace() }
        .onChange(of: previewKey) { _, _ in refreshPreview() }
        // Keyed on the same signals as the workspace: re-detection rewrites
        // beat.detection.json in place, so the path alone never changes.
        .task(id: "\(workspaceKey)-\(tuning.halved)-\(selectedJob?.beatCount ?? 0)-\(selectedJob?.bpm ?? 0)") {
            pickupBeatTimes = selection.map {
                jobManager.beatTimes(songID: $0, halved: tuning.halved)
            } ?? []
        }
        .focusedSceneValue(\.songActions, songActions)
    }

    // MARK: - Panes

    @ViewBuilder
    private var detail: some View {
        if let item = selectedItem {
            SongWorkspaceView(
                item: item,
                job: selectedJob,
                bars: displayBars,
                rawChords: rawChords,
                changedBars: changedBars,
                isPreviewing: tuning.isDirty && !previewBars.isEmpty,
                jobManager: jobManager,
                sectionStore: sectionStore,
                audioPlayer: audioPlayer,
                waveformLoader: waveformLoader,
                selectedBar: $selectedBar,
                waveZoom: $waveZoom,
                followPlayhead: $followPlayhead,
                onStartAnalysis: startAnalysis,
                onReanalyse: { if let item = selectedItem { confirmReanalyse(item) } },
                onCancelRun: { jobManager.cancelRun() },
                onSubdivisionChange: setSubdivision,
                onSplit: splitSection,
                onMerge: mergeSection,
                onRename: beginRename,
                onShowStages: { storedInspectorTab = InspectorTab.analysis.rawValue; showInspector = true },
                onDismissNotice: { if let songID = selection { jobManager.clearNotice(songID: songID) } },
                pickup: pickupChoice
            )
        } else {
            FrontScreenView(
                items: items,
                isLoading: songStore.isLoading,
                libraryError: songStore.errorMessage,
                environment: environment,
                authStore: authStore,
                queue: jobManager.queue,
                onOpen: { selection = $0.id },
                onAnalyse: confirmReanalyse,
                onResume: { item in
                    guard let ref = item.ref else { return }
                    jobManager.start(ref, resumeIfPossible: true)
                },
                onAnalyseAll: analyseAll,
                onExport: { item in
                    selection = item.id
                    beginExport(for: item)
                },
                onRecheckEnvironment: { Task { await environment.refresh() } },
                onReloadLibrary: { Task { await songStore.fetchSongs() } },
                onSignIn: { authStore.signInWithApple() }
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let item = selectedItem {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .scaledFont(size: 13, weight: .semibold, relativeTo: .subheadline)
                    Text(subtitle(for: item))
                        .scaledFont(size: 10.5, relativeTo: .caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let item = selectedItem {
                if jobManager.isRunning(item.id) {
                    Button(role: .destructive) {
                        jobManager.cancelRun()
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                    .help("Stop this analysis. Finished stages and downloaded audio are kept.")
                } else if item.job != nil {
                    Button {
                        confirmReanalyse(item)
                    } label: {
                        Label("Re-analyse", systemImage: "arrow.clockwise")
                    }
                    .help(jobManager.isBusy
                          ? "Queue a fresh analysis — it starts when the current run finishes"
                          : "Run the analysis again from the start")
                }

                if let job = item.job, job.hasUnexportedEdits {
                    StatusPill(text: "Edited since last export", systemImage: "pencil", tint: .orange)
                }

                if let job = item.job, job.isExportable {
                    Button {
                        beginExport(for: item)
                    } label: {
                        if isPreparingExport {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Export to TheStageBee…", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparingExport || !authStore.isSignedIn)
                    .help(authStore.isSignedIn
                          ? "Review the changes, then update this song in TheStageBee"
                          : "Sign in to export to TheStageBee")
                }
            }

            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            // Every other toolbar button explains itself; this one said only
            // "Inspector" whether it would open or close, and never said which.
            .help(showInspector ? "Hide the inspector" : "Show the inspector")
            .accessibilityAddTraits(showInspector ? .isSelected : [])
        }
    }

    private func subtitle(for item: LibraryItem) -> String {
        var parts: [String] = []
        if let artist = item.artist { parts.append(artist) }
        if let duration = item.job?.durationSeconds {
            parts.append(Format.time(duration, showTenths: false))
        }
        parts.append(item.state.label)
        return parts.joined(separator: " · ")
    }

    // MARK: - Workspace loading

    /// Everything that means "the files behind this workspace changed".
    ///
    /// Deliberately narrow: `chartsVersion` is bumped wherever the chart files
    /// are written, including by a retry or resume that keeps the same job id
    /// and paths. Watching the status or the stage report instead re-fired this
    /// a dozen times per run, and each reload cleared the selected bar and threw
    /// away whatever the user had typed into the tuning fields.
    private var workspaceKey: String {
        let job = selectedJob
        return [
            selection ?? "none",
            job?.id ?? "nojob",
            String(job?.chartsVersion ?? 0),
            job?.chordChartPerformerPath ?? "",
            // Audio appears partway through a run, and a run that stops at
            // "audio ready" changes nothing else — without this the transport
            // stayed dead for a file the app had just finished downloading.
            job?.analysisWavPath ?? job?.originalAudioPath ?? "",
        ].joined(separator: "|")
    }

    private func loadWorkspace() async {
        guard let item = selectedItem, let songID = item.song.id else {
            resetWorkspace()
            tuning = TuningDraft()
            return
        }

        if let ref = item.ref {
            jobManager.adoptLegacyJobIfNeeded(for: ref)
        }

        guard let job = jobManager.job(for: songID) else {
            resetWorkspace()
            tuning = TuningDraft()
            return
        }

        selectedBar = nil
        tuning = TuningDraft.from(job: job)
        previewBars = []

        let performer = JobManager.loadBars(atPath: job.chordChartPerformerPath)
        loadedBars = performer.isEmpty
            ? JobManager.loadBars(atPath: job.chordChartDraftPath)
            : performer
        rawChords = JobManager.loadRawChords(atPath: job.chordCleanedPath)

        if let folder = jobManager.folder(for: songID) {
            sectionStore.onEdit = { [weak jobManager] in
                jobManager?.noteEdit(songID: songID)
            }
            sectionStore.load(for: job, jobFolder: folder)
        }

        if let audioPath = job.analysisWavPath ?? job.originalAudioPath,
           FileManager.default.fileExists(atPath: audioPath) {
            audioPlayer.load(path: audioPath)
            await waveformLoader.load(path: audioPath)
        } else {
            audioPlayer.stop()
            waveformLoader.reset()
        }
    }

    /// Reopens the song the user was last on, once it is actually in the list.
    private func restoreSelectionIfPossible() {
        guard selection == nil, !storedSelection.isEmpty, !hasRestoredSelection else { return }
        guard items.contains(where: { $0.id == storedSelection }) else { return }
        hasRestoredSelection = true
        selection = storedSelection
    }

    private func resetWorkspace() {
        audioPlayer.stop()
        waveformLoader.reset()
        sectionStore.unload()
        loadedBars = []
        rawChords = []
        previewBars = []
    }

    /// Recomputes the in-memory chart for the pending tuning values. The work
    /// happens off the main actor, so a stale result from a superseded request
    /// is discarded rather than flashing an older preview.
    private func refreshPreview() {
        // Bump first: a superseded request must be invalidated even when the new
        // state is "no preview", or a stale result can land afterwards.
        previewRequest += 1
        let request = previewRequest
        guard let songID = selection, tuning.isDirty else {
            previewBars = []
            return
        }
        let draft = tuning
        Task {
            let bars = await jobManager.previewBars(
                songID: songID,
                offset: draft.offset,
                beatsPerBar: draft.beatsPerBar,
                halved: draft.halved,
                manualBpm: draft.manualBpm
            )
            guard request == previewRequest else { return }
            previewBars = bars
        }
    }

    /// Only offered while the Tuning tab is open — it is a tuning control, and
    /// it would otherwise take room from the chart during ordinary editing.
    private var pickupChoice: PickupChoice? {
        guard showInspector, inspectorTab == .tuning,
              selection != nil,
              selectedJob?.beatDetectionPath != nil else { return nil }
        return PickupChoice(
            beatTimes: pickupBeatTimes,
            beatsPerBar: tuning.beatsPerBar,
            offset: $tuning.offset,
            isDirty: tuning.isDirty,
            canApply: !tuning.hasInvalidManualBpm,
            onApply: applyTuning,
            onRevert: { tuning.revert() }
        )
    }

    // MARK: - Menu actions

    /// What the menu bar may do right now. Mirrors the toolbar exactly, so a
    /// shortcut can never do something the window does not offer.
    private var songActions: SongActions {
        let item = selectedItem
        let job = selectedJob
        let isRunning = item.map { jobManager.isRunning($0.id) } ?? false

        return SongActions(
            title: item?.title,
            canAnalyse: item?.ref != nil && !isRunning
                && item.map { jobManager.queuePosition(of: $0.id) == nil } ?? false,
            canCancel: isRunning,
            canExport: (job?.isExportable ?? false) && authStore.isSignedIn && !isPreparingExport,
            canPlay: audioPlayer.isLoaded,
            isPlaying: audioPlayer.isPlaying,
            analyse: { if let item { confirmReanalyse(item) } },
            cancel: { jobManager.cancelRun() },
            export: { if let item { beginExport(for: item) } },
            togglePlayback: { audioPlayer.togglePlayPause() },
            selectNext: { step(by: 1) },
            selectPrevious: { step(by: -1) },
            revealJobFolder: jobFolderToReveal.map { folder in
                { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            },
            focusSearch: { searchFocusToken += 1 },
            refreshLibrary: { Task { await songStore.fetchSongs() } },
            recheckEnvironment: { Task { await environment.refresh() } }
        )
    }

    private var jobFolderToReveal: URL? {
        selection.flatMap { jobManager.folder(for: $0) }
    }

    /// Moves the selection through the visible list, so a whole session can be
    /// worked without going back to the mouse.
    private func step(by offset: Int) {
        let list = filteredItems
        guard !list.isEmpty else { return }
        guard let current = selection, let index = list.firstIndex(where: { $0.id == current }) else {
            selection = list.first?.id
            return
        }
        let next = index + offset
        guard list.indices.contains(next) else { return }
        selection = list[next].id
    }

    // MARK: - Actions

    /// Re-analysis rebuilds the chart from scratch and re-detects sections, so
    /// it asks first whenever there is work it would replace. A song with only an
    /// untouched auto-analysis has nothing to lose and starts straight away.
    /// Split out of the modifier: inlining these pushed the body past what the
    /// type-checker will attempt in one expression.
    private var reanalyseTitle: String {
        guard let item = reanalyseCandidate else { return "" }
        return "Analyse “\(item.title)” again from the start?"
    }

    private var reanalyseMessage: String {
        guard let item = reanalyseCandidate else { return "" }
        let losses = Format.list(reanalysisLosses(for: item))
        return "The chord chart is rebuilt from scratch, which replaces "
            + losses
            + ". Your pickup, metre, BPM and per-bar subdivisions are kept."
    }

    private func confirmReanalyse(_ item: LibraryItem) {
        if reanalysisLosses(for: item).isEmpty {
            analyse(item)
        } else {
            reanalyseCandidate = item
        }
    }

    /// What a re-analysis would discard, in the user's words. Tuning, per-bar
    /// subdivisions and the export record are carried across, so they are not
    /// listed — only what genuinely cannot survive a rebuilt chart.
    private func reanalysisLosses(for item: LibraryItem) -> [String] {
        guard let job = item.job, job.hasChart else { return [] }
        var losses: [String] = []
        let sections = sectionStore.isLoaded(for: job) ? sectionStore.sections.count : (job.sectionCount ?? 0)
        if sections > 0 {
            losses.append(sections == 1
                          ? "its section, including any name you gave it"
                          : "its \(sections) sections, including their names and where you split them")
        }
        if job.lastExport != nil {
            losses.append("the chart currently matching what you exported")
        }
        return losses
    }

    private func analyse(_ item: LibraryItem) {
        guard let ref = item.ref else { return }
        jobManager.start(ref, resumeIfPossible: false)
    }

    private func analyseAll(_ items: [LibraryItem]) {
        jobManager.enqueue(items.compactMap(\.ref))
    }

    private func startAnalysis() {
        guard let ref = selectedItem?.ref else { return }
        jobManager.start(ref, resumeIfPossible: true)
    }

    private func retryStage(_ stage: PipelineStage) {
        guard let ref = selectedItem?.ref else { return }
        jobManager.retry(from: stage, for: ref)
    }

    private func redetectBeats(minBpm: Double?, maxBpm: Double?, transitionLambda: Double?) {
        guard let songID = selection else { return }
        Task {
            await jobManager.redetectBeats(
                songID: songID, minBpm: minBpm, maxBpm: maxBpm, transitionLambda: transitionLambda
            )
        }
    }

    private func applyTuning() {
        guard let songID = selection else { return }
        let draft = tuning
        Task {
            let applied = await jobManager.regenerateCharts(
                songID: songID,
                offset: draft.offset,
                beatsPerBar: draft.beatsPerBar,
                halved: draft.halved,
                manualBpm: .some(draft.manualBpm)
            )
            previewBars = []
            guard applied else {
                // The files the rebuild needs are missing, so the chart on
                // screen is unchanged — leave the edit pending and say why.
                actionAlert = ActionAlert(
                    title: "Could not apply the timing change",
                    message: "This analysis is missing the beat data the chart is rebuilt from, so the timing change was not applied. Re-analysing the song will rebuild it."
                )
                return
            }
            tuning.markApplied()
        }
    }

    private func setSubdivision(bar: Int, value: Int) {
        guard let songID = selection, let job = jobManager.job(for: songID) else { return }
        var subdivisions = job.subdivisionsByBar
        if value == 4 { subdivisions.removeValue(forKey: bar) } else { subdivisions[bar] = value }
        jobManager.setSubdivisions(subdivisions, songID: songID)
    }

    private func splitSection(at bar: Int) {
        sectionStore.startNewSection(at: bar)
    }

    private func mergeSection(at bar: Int) {
        sectionStore.mergeSectionWithPrevious(containing: bar)
    }

    private func beginRename(_ section: ChordSection) {
        renameText = section.name
        renamingSection = section
    }

    private func beginExport(for item: LibraryItem) {
        guard let job = item.job,
              let songID = item.song.id,
              let folder = jobManager.folder(for: songID) else { return }
        exportErrorMessage = nil
        isPreparingExport = true
        Task {
            defer { isPreparingExport = false }
            do {
                exportPreview = try await exportService.prepare(
                    job: job, jobFolder: folder, song: item.song, isSignedIn: authStore.isSignedIn
                )
            } catch {
                exportErrorMessage = error.localizedDescription
                exportPreview = nil
            }
        }
    }

    private func confirmExport() {
        guard let preview = exportPreview else { return }
        Task {
            do {
                let record = try await exportService.commit(preview)
                let recorded = jobManager.recordExport(record, songID: preview.songID, jobID: preview.jobID)
                if !recorded {
                    // The write happened; only the local record could not be
                    // filed. Saying so beats silently showing "never exported".
                    actionAlert = ActionAlert(
                        title: "Exported, but not recorded here",
                        message: "The export was written to TheStageBee. This song has been re-analysed since the sheet was opened, though, so the export is not recorded against the analysis now on screen."
                    )
                }
                exportPreview = nil
                exportErrorMessage = nil
                await songStore.fetchSongs()
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Rename sheet

struct RenameSectionSheet: View {
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename section")
                .font(.headline)
            TextField("Section name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave()
    }
}
