import AppKit
import SwiftUI

// MARK: - Inspector
//
// The right-hand column: four tabs over one scrolling body.
//
//   Bar       — everything about the selected bar, and the section actions anchored to it.
//   Tuning    — pending beat/bar settings, previewed live and applied explicitly.
//   Analysis  — the pipeline as a checklist, with retry / resume / cancel and the log.
//   Info      — the file, its audio health, the analysis stats and machine readiness.
//
// Nothing here edits chords directly: timing is corrected with Tuning, which is
// why the Bar tab says so rather than offering a chord field.

struct InspectorView: View {
    @Binding var tab: InspectorTab
    let item: LibraryItem?
    let job: AnalysisJob?
    let bars: [ChordChartBarEntry]
    @Binding var selectedBar: Int?
    @Binding var tuning: TuningDraft
    @ObservedObject var sectionStore: SectionStore
    @ObservedObject var jobManager: JobManager
    @ObservedObject var environment: EnvironmentStore
    let isSignedIn: Bool
    /// True while the chart is showing unapplied tuning.
    var isPreviewing: Bool = false
    var onApplyTuning: () -> Void
    var onRevertTuning: () -> Void
    var onSubdivisionChange: (Int, Int) -> Void
    var onSplit: (Int) -> Void
    var onMerge: (Int) -> Void
    var onRename: (ChordSection) -> Void
    var onRetryStage: (PipelineStage) -> Void
    var onCancelRun: () -> Void
    var onResume: () -> Void
    var onRedetectBeats: (Double?, Double?, Double?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector tab", selection: $tab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isPreviewing)
        .help(isPreviewing ? "Apply or revert the timing change to use the other tabs" : "")
        .accessibilityHint(isPreviewing ? "Unavailable until the timing change is applied or reverted" : "")
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 9)

            Divider()

            ScrollView {
                tabBody
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var tabBody: some View {
        switch tab {
        case .bar:
            InspectorBarTab(
                job: job,
                bars: bars,
                selectedBar: $selectedBar,
                sectionStore: sectionStore,
                subdivisions: job?.subdivisionsByBar ?? [:],
                isPreviewing: isPreviewing,
                onSubdivisionChange: onSubdivisionChange,
                onSplit: onSplit,
                onMerge: onMerge,
                onRename: onRename
            )
        case .tuning:
            InspectorTuningTab(
                job: job,
                tuning: $tuning,
                jobManager: jobManager,
                onApplyTuning: onApplyTuning,
                onRevertTuning: onRevertTuning,
                onRedetectBeats: onRedetectBeats
            )
        case .analysis:
            InspectorAnalysisTab(
                songID: item?.id,
                songTitle: item?.title ?? job?.title,
                job: job,
                jobManager: jobManager,
                environment: environment,
                onRetryStage: onRetryStage,
                onCancelRun: onCancelRun,
                onResume: onResume
            )
        case .info:
            InspectorInfoTab(
                songID: item?.id,
                job: job,
                jobManager: jobManager,
                environment: environment,
                isSignedIn: isSignedIn
            )
        }
    }
}

// MARK: - Bar tab

private struct InspectorBarTab: View {
    let job: AnalysisJob?
    let bars: [ChordChartBarEntry]
    @Binding var selectedBar: Int?
    @ObservedObject var sectionStore: SectionStore
    let subdivisions: [Int: Int]
    /// True while the chart shows unapplied tuning. The preview renumbers bars,
    /// so an edit keyed by the bar on screen would land on a different one.
    let isPreviewing: Bool
    var onSubdivisionChange: (Int, Int) -> Void
    var onSplit: (Int) -> Void
    var onMerge: (Int) -> Void
    var onRename: (ChordSection) -> Void

    @State private var confirmingAutoDetect = false
    @State private var confirmingMerge = false
    /// Read once per job rather than on every body pass — it parses a file.
    @State private var candidateCount = 0

    private var entry: ChordChartBarEntry? {
        guard let selectedBar else { return nil }
        return bars.first { $0.bar == selectedBar }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry {
                header(for: entry)
                chords(for: entry)
                subdivide(for: entry)
                sectionActions(for: entry.bar)
                InspectorHint("Click a bar to give the chart focus, then arrow keys move between bars and S / M / R act on the one selected. Esc clears the selection.")
                    .padding(.horizontal, 2)
            } else {
                EmptyStateView(
                    title: "No bar selected",
                    message: "Click a bar in the chart to see its chords, the section it belongs to and the actions for it.",
                    systemImage: "rectangle.dashed"
                )
                .padding(.vertical, 24)
            }
            allSections
        }
        // The candidates file appears mid-analysis, and the job id never changes,
        // so key on the path and the section list too.
        .task(id: "\(job?.id ?? "none")-\(job?.sectionCandidatesPath ?? "")-\(sectionStore.sections.count)") {
            candidateCount = job.map { sectionStore.candidateCount(for: $0) } ?? 0
        }
    }

    // MARK: All sections

    /// Whole-chart section actions. The previous build had a "Reset sections"
    /// button; the redesign needs somewhere for the bulk operations to live.
    @ViewBuilder
    private var allSections: some View {
        if !sectionStore.sections.isEmpty {
            PanelCard {
                GroupLabel("All sections")
                InfoRow(label: "Sections", value: "\(sectionStore.sections.count)")

                if job != nil {
                    let repeats = candidateCount
                    Button {
                        confirmingAutoDetect = true
                    } label: {
                        Label("Detect sections again", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .disabled(repeats == 0)
                    InspectorHint(repeats == 0
                                  ? "No repeating passages were detected in this chart."
                                  : "Rebuilds the split from the \(repeats) repeating passages found, replacing your current sections.")
                }

                Button(role: .destructive) {
                    confirmingMerge = true
                } label: {
                    Label("Merge into one section", systemImage: "arrow.triangle.merge")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(sectionStore.sections.count <= 1)
                .confirmationDialog("Replace the current sections?",
                                    isPresented: $confirmingAutoDetect, titleVisibility: .visible) {
                    Button("Detect again", role: .destructive) {
                        if let job { sectionStore.autoDetectSections(for: job) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every split you have made and every section you have renamed is replaced by the detected repeats. This cannot be undone.")
                }
                .confirmationDialog("Merge every section into one?",
                                    isPresented: $confirmingMerge, titleVisibility: .visible) {
                    Button("Merge", role: .destructive) { sectionStore.resetToSingle() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All \(sectionStore.sections.count) sections become a single section named Intro. Their names and boundaries cannot be recovered.")
                }
            }
        }
    }

    // MARK: Header

    private func header(for entry: ChordChartBarEntry) -> some View {
        PanelCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Bar \(entry.bar)")
                    .scaledFont(size: 15, weight: .bold, relativeTo: .body)
                Text("\(Format.time(entry.start)) – \(Format.time(entry.end))")
                    .scaledFont(size: 10.5, design: .monospaced, relativeTo: .caption2)
                    .foregroundStyle(.secondary)
            }

            if let section = sectionStore.section(containing: entry.bar) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(sectionColour(section))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(sectionSummary(section, bar: entry.bar))
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sectionSummary(_ section: ChordSection, bar: Int) -> String {
        guard let position = sectionStore.positionInSection(of: bar) else { return section.name }
        return "\(section.name) · bar \(position.index) of \(position.total)"
    }

    private func sectionColour(_ section: ChordSection) -> Color {
        SectionPalette.color(for: section, in: sectionStore.sections)
    }

    // MARK: Detected chords

    private func chords(for entry: ChordChartBarEntry) -> some View {
        PanelCard {
            GroupLabel("Detected chords")

            if entry.chords.isEmpty {
                Text(entry.primaryChord ?? "No chord detected in this bar")
                    .scaledFont(size: 12, weight: entry.primaryChord == nil ? .regular : .semibold, relativeTo: .footnote)
                    .foregroundStyle(entry.primaryChord == nil ? Color.secondary : Color.primary)
            } else {
                let duration = max(entry.end - entry.start, 0.0001)
                ForEach(Array(entry.chords.enumerated()), id: \.offset) { _, chord in
                    HStack(spacing: 8) {
                        Text(chord.displayChord)
                            .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                            .frame(width: 42, alignment: .leading)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        InspectorShareBar(fraction: chord.overlapSeconds / duration)
                        Text(String(format: "%.2fs", chord.overlapSeconds))
                            .scaledFont(size: 10.5, design: .monospaced, relativeTo: .caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            InspectorHint("Chords come from the analysis model — correct timing with Tuning, not by editing chords.")
        }
    }

    // MARK: Subdivision

    private func subdivide(for entry: ChordChartBarEntry) -> some View {
        PanelCard {
            GroupLabel("Subdivide this bar")
            Picker("Subdivision", selection: Binding(
                get: { subdivisions[entry.bar] ?? 4 },
                // Withheld while previewing: the preview renumbers bars, so this
                // would set the subdivision on a different bar than the one the
                // user is looking at, and reverting would not undo it.
                set: { if !isPreviewing { onSubdivisionChange(entry.bar, $0) } }
            )) {
                Text("1").tag(1)
                Text("1/2").tag(2)
                Text("1/4").tag(4)
                Text("1/8").tag(8)
                Text("1/16").tag(16)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            InspectorHint("Also used when exporting this bar to TheStageBee.")
        }
    }

    // MARK: Section actions

    private func sectionActions(for bar: Int) -> some View {
        let section = sectionStore.section(containing: bar)
        let canSplit = !isPreviewing && section != nil && !sectionStore.isFirstBarOfSection(bar)
        // The same rule the chart's own popover and the M key use. A looser one
        // here offered "Merge" — and advertised M — on bars where pressing M did
        // nothing, and where clicking the button folded away a whole section the
        // user had not selected.
        let canMerge = !isPreviewing && (section.map {
            sectionStore.isFirstBarOfSection(bar) && !sectionStore.isFirstSection($0)
        } ?? false)

        return PanelCard {
            GroupLabel("Section")

            InspectorActionButton(
                title: section.map { "Split “\($0.name)” at this bar" } ?? "Split at this bar",
                key: "S",
                isEnabled: canSplit
            ) {
                onSplit(bar)
            }
            .help(canSplit
                  ? "Start a new section at this bar"
                  : "This bar already starts its section")

            InspectorActionButton(
                title: "Merge with previous section",
                key: "M",
                isEnabled: canMerge
            ) {
                onMerge(bar)
            }
            .help({
                if canMerge { return "Fold this section into the one before it" }
                if let section, sectionStore.isFirstSection(section) {
                    return "This is the first section — there is nothing before it"
                }
                return "Select the first bar of a section to fold it into the one before"
            }())

            InspectorActionButton(
                title: section.map { "Rename “\($0.name)”" } ?? "Rename section",
                key: "R",
                isEnabled: section != nil && !isPreviewing
            ) {
                if let section { onRename(section) }
            }

            if let saveError = sectionStore.saveError {
                InspectorMonoBlock(text: "Sections not saved: \(saveError)", tint: .red)
            }
        }
    }
}

// MARK: - Tuning tab

private struct InspectorTuningTab: View {
    @Environment(\.chordAdminTextScale) private var textScale
    let job: AnalysisJob?
    @Binding var tuning: TuningDraft
    @ObservedObject var jobManager: JobManager
    var onApplyTuning: () -> Void
    var onRevertTuning: () -> Void
    var onRedetectBeats: (Double?, Double?, Double?) -> Void

    @State private var constrainBpm = false
    @State private var seedBpm: Double = 120
    @State private var stableTempo = false

    private var seedRangeText: String {
        String(format: "%.0f–%.0f BPM", seedBpm * 0.8, seedBpm * 1.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tempo
            barsGroup
            if tuning.isDirty { applyBar }
            redetect
        }
        .onAppear { syncSeedBpm() }
        .onChange(of: job?.id) { _, _ in syncSeedBpm() }
        .onChange(of: job?.bpm) { _, _ in syncSeedBpm() }
    }

    // MARK: Tempo

    private var tempo: some View {
        PanelCard {
            GroupLabel("Tempo")

            InfoRow(label: "Detected", value: "\(Format.bpm(job?.bpm)) BPM", valueIsMonospaced: true)

            HStack(spacing: 8) {
                Text("Override")
                    .scaledFont(size: 11, relativeTo: .caption)
                    .foregroundStyle(.secondary)
                    // Fixed at 60pt this broke to "Overrid" / "e".
                    .fixedSize()
                    .frame(minWidth: 60 * textScale, alignment: .leading)
                // Not the detected BPM as placeholder: the previous build did
                // that, and an override you had typed looked identical to one
                // you had not.
                TextField("Using detected", text: $tuning.manualBpmText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .scaledFont(size: 11.5, design: .monospaced, relativeTo: .caption)
                    .help("Type a BPM to override the detected tempo. Leave it empty to use the detected value.")
            }

            if tuning.hasInvalidManualBpm {
                Label("Enter a BPM between 10 and 500, or clear the field to use the detected tempo.",
                      systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: 10.5, relativeTo: .caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $tuning.halved) {
                HStack(spacing: 5) {
                    Text("Halve tempo").scaledFont(size: 12, relativeTo: .footnote)
                    Text("double-time fix")
                        .scaledFont(size: 10.5, relativeTo: .caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    // MARK: Bars

    private var barsGroup: some View {
        PanelCard {
            GroupLabel("Bars")

            HStack(spacing: 8) {
                Text("Pickup beats").scaledFont(size: 12, relativeTo: .footnote)
                Spacer(minLength: 6)
                Picker("Pickup beats", selection: $tuning.offset) {
                    // A pickup can only be shorter than a bar; the grid clamps
                    // anything larger, so do not offer it.
                    ForEach(0..<max(1, tuning.beatsPerBar), id: \.self) { beats in
                        Text("\(beats)").tag(beats)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 118)
            }

            HStack(spacing: 8) {
                Text("Beats per bar").scaledFont(size: 12, relativeTo: .footnote)
                Spacer(minLength: 6)
                Picker("Beats per bar", selection: $tuning.beatsPerBar) {
                    Text("2").tag(2)
                    Text("3").tag(3)
                    Text("4").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 96)
            }

            InspectorHint("Changes preview instantly in the chart — nothing is recomputed until you apply.")
        }
    }

    // MARK: Apply / Revert

    private var applyBar: some View {
        PanelCard {
            StatusPill(text: "Previewing — not applied", systemImage: "eye", tint: .accentColor)

            HStack(spacing: 8) {
                Button("Apply", action: onApplyTuning)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(tuning.hasInvalidManualBpm)
                Button("Revert", action: onRevertTuning)
                    .controlSize(.small)
            }

            InspectorHint("Apply rebuilds the chart from these settings. Revert puts the pending values back to what is on disk.")
        }
    }

    // MARK: Re-detect

    /// Re-detection needs a job whose audio is on disk, and nothing else running
    /// — including a re-detection of its own, which is not part of the pipeline.
    private var canRedetect: Bool {
        guard let job, job.hasAudio else { return false }
        return !jobManager.isBusy
    }

    private var redetectHint: String {
        guard let job else { return "Analyse this song first." }
        if !job.hasAudio {
            return "The audio for this song is not on disk yet — analyse it first."
        }
        if let songID = job.songDocumentID, jobManager.isRedetecting(songID) {
            return "Re-detecting…"
        }
        if jobManager.isBusy { return "Available once the current run has finished." }
        return "Runs beat detection again on the audio already downloaded — nothing is fetched from YouTube."
    }

    private func syncSeedBpm() {
        if let bpm = job?.bpm, bpm >= 40, bpm <= 300 {
            seedBpm = bpm.rounded()
        } else {
            seedBpm = 120
        }
    }

    private var redetect: some View {
        PanelCard {
            GroupLabel("Re-detect beats")

            Toggle(isOn: $constrainBpm) {
                Text("Constrain BPM range").scaledFont(size: 12, relativeTo: .footnote)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            if constrainBpm {
                VStack(alignment: .leading, spacing: 3) {
                    Stepper(value: $seedBpm, in: 40...300, step: 1) {
                        HStack(spacing: 6) {
                            Text("Seed")
                                .scaledFont(size: 11, relativeTo: .caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f", seedBpm))
                                .scaledFont(size: 11.5, weight: .medium, design: .monospaced, relativeTo: .caption)
                        }
                    }
                    .controlSize(.small)
                    Text("Detection is limited to \(seedRangeText) (±20%).")
                        .scaledFont(size: 10.5, relativeTo: .caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 20)
            }

            Toggle(isOn: $stableTempo) {
                HStack(spacing: 5) {
                    Text("Stable tempo").scaledFont(size: 12, relativeTo: .footnote)
                    Text("resists drift")
                        .scaledFont(size: 10.5, relativeTo: .caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Button {
                onRedetectBeats(
                    constrainBpm ? seedBpm * 0.8 : nil,
                    constrainBpm ? seedBpm * 1.2 : nil,
                    stableTempo ? 1000.0 : nil
                )
            } label: {
                Label("Re-detect beats & tempo", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(!canRedetect)

            // A failed re-detection used to leave the tab looking untouched, so
            // the user pressed the button again and again with no idea the
            // backend had gone away. The only trace was in the Analysis tab.
            if let failure = redetectFailure {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.red)
                    Text(failure)
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                InspectorHint(redetectHint)
            }
        }
    }

    /// Why the last re-detection failed, if it did and nothing has since
    /// succeeded. Read from the stage report, which is where it is recorded.
    private var redetectFailure: String? {
        guard let job, !jobManager.isBusy else { return nil }
        guard case .failed(let message) = job.stageReport[.beats].state else { return nil }
        return "Beat re-detection failed: \(message)"
    }
}

// MARK: - Analysis tab

private struct InspectorAnalysisTab: View {
    let songID: String?
    let songTitle: String?
    let job: AnalysisJob?
    @ObservedObject var jobManager: JobManager
    @ObservedObject var environment: EnvironmentStore
    var onRetryStage: (PipelineStage) -> Void
    var onCancelRun: () -> Void
    var onResume: () -> Void

    @State private var isLogExpanded = false
    @State private var didCopyLog = false

    private var isRunning: Bool {
        guard let songID else { return false }
        return jobManager.isRunning(songID)
    }

    private var log: String {
        guard let songID else { return "" }
        return jobManager.log(for: songID)
    }

    var body: some View {
        if let job {
            VStack(alignment: .leading, spacing: 10) {
                checklist(for: job)
                if job.status == .audioReady {
                    paused(job)
                } else if let failure = job.stageReport.firstFailure {
                    retry(failure)
                }
                if isRunning { cancel }
                logGroup
            }
        } else {
            EmptyStateView(
                title: "Not analysed yet",
                message: "Run an analysis to see each stage, how long it took and anything it flagged.",
                systemImage: "waveform"
            )
            .padding(.top, 40)
        }
    }

    // MARK: Checklist

    private func checklist(for job: AnalysisJob) -> some View {
        let report = job.stageReport
        let running = report.runningStage

        return PanelCard {
            GroupLabel(songTitle.map { "Pipeline — \($0)" } ?? "Pipeline")
            ForEach(report.records) { record in
                StageRow(record: record, isCurrent: record.stage == running)
            }
        }
    }

    // MARK: Retry

    private func retryHint(for stage: PipelineStage) -> String {
        if PipelineStage.audioStages.contains(stage) {
            return "Retrying starts again from this stage, so the audio is fetched again."
        }
        return "Finished stages are kept — retrying picks up here and reuses the audio already on disk."
    }

    private func retry(_ failure: StageRecord) -> some View {
        PanelCard {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 12, relativeTo: .footnote)
                    .foregroundStyle(.red)
                Text("\(failure.stage.title) failed")
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .subheadline)
            }

            if let message = failure.state.message {
                InspectorMonoBlock(text: message, tint: .red)
            }

            Button {
                onRetryStage(failure.stage)
            } label: {
                Label("Retry this stage", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(jobManager.isBusy)

            InspectorHint(retryHint(for: failure.stage))
        }
    }

    // MARK: Backend paused

    /// `.audioReady` has three causes and only one of them is the backend's.
    private func pausedExplanation(_ job: AnalysisJob) -> String {
        switch job.pauseCause {
        case .backendUnavailable:
            return "The analysis backend was unreachable, so beat and chord analysis never ran. Download, conversion and the health checks are done and will not be repeated."
        case .cancelled:
            return "You stopped this run. The audio and every finished stage are on disk, so resuming carries on from there."
        case .interrupted:
            return "The app closed before the analysis finished. The audio and every finished stage are on disk, so resuming carries on from there."
        }
    }

    private func paused(_ job: AnalysisJob) -> some View {
        PanelCard {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .scaledFont(size: 13, relativeTo: .subheadline)
                    .foregroundStyle(.orange)
                Text("Audio ready — analysis paused")
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(pausedExplanation(job))
                .scaledFont(size: 11.5, relativeTo: .caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Resume analysis", action: onResume)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(jobManager.isBusy)
                Button {
                    Task { await environment.refreshBackend() }
                } label: {
                    Label("Check backend", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                StatusPill(
                    text: backendStateText,
                    systemImage: "circle.fill",
                    tint: environment.backendAvailable == true ? .green : .red
                )
                Spacer(minLength: 4)
            }

            InspectorMonoBlock(
                text: "GET \(environment.backendURL)/health\n\(job.backendErrorMessage ?? backendDetailText)",
                tint: .secondary
            )
        }
    }

    private var backendStateText: String {
        switch environment.backendAvailable {
        case true?:  return "Backend online"
        case false?: return "Backend offline"
        default:     return "Backend not checked"
        }
    }

    private var backendDetailText: String {
        environment.backendAvailable == true
            ? "responding — resume when you are ready"
            : "not responding — start it with ../ChordAdminBackend/start.sh"
    }

    // MARK: Cancel

    private var cancel: some View {
        PanelCard {
            Button(role: .destructive, action: onCancelRun) {
                Label("Cancel analysis", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            InspectorHint("Keeps everything already downloaded — you can resume from the stage it stopped at.")
        }
    }

    // MARK: Log

    private var logGroup: some View {
        PanelCard {
            DisclosureGroup(isExpanded: $isLogExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    if log.isEmpty {
                        InspectorHint("Nothing logged for this song yet.")
                    } else {
                        ScrollView {
                            Text(log)
                                .scaledFont(size: 10, design: .monospaced, relativeTo: .caption2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                        .frame(height: 200)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )

                        HStack {
                            InspectorHint("Full yt-dlp / ffmpeg / backend output, per stage.")
                            Button(didCopyLog ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                _ = NSPasteboard.general.setString(log, forType: .string)
                                didCopyLog = true
                                // Re-arm shortly after, so the button stays usable
                                // on a finished job whose log no longer changes.
                                Task {
                                    try? await Task.sleep(for: .seconds(1.5))
                                    didCopyLog = false
                                }
                            }
                            .controlSize(.small)
                            .disabled(log.isEmpty)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Log")
                    .scaledFont(size: 11.5, weight: .medium, relativeTo: .caption)
            }
            .onChange(of: log) { _, _ in didCopyLog = false }
        }
    }
}

// MARK: - Info tab

private struct InspectorInfoTab: View {
    let songID: String?
    let job: AnalysisJob?
    @ObservedObject var jobManager: JobManager
    @ObservedObject var environment: EnvironmentStore
    let isSignedIn: Bool

    @State private var confirmingDelete = false
    @State private var storageRefresh = 0
    // Measured on demand rather than in body: each of these walks the whole
    // jobs directory, and body runs many times a second during playback.
    @State private var songBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0
    @State private var orphanCount = 0

    /// Older analyses for this song that hydration set aside.
    private var keptCount: Int {
        guard let songID else { return 0 }
        return jobManager.protectedFolders[songID]?.count ?? 0
    }

    private var jobFolder: URL? {
        guard let songID else { return nil }
        return jobManager.folder(for: songID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job {
                metadata(job)
                health(job)
                stats(job)
            }
            exportHistory
            readiness
            storage
            if !isSignedIn { readOnlyNote }
            if job == nil {
                InspectorHint("File details, audio health and analysis stats appear here once this song has been analysed.")
                    .padding(.horizontal, 2)
            }
        }
    }


    // MARK: Export history

    /// What the last export wrote and what it replaced. The export sheet promises
    /// "previous values are kept locally"; this is where they are kept.
    @ViewBuilder
    private var exportHistory: some View {
        if let export = job?.lastExport {
            PanelCard {
                GroupLabel("Last export")
                InfoRow(label: "When", value: Self.exportStamp(export.exportedAt))
                InfoRow(
                    label: "Wrote",
                    value: [export.tempo.map { "\($0) BPM" }, "\(export.sectionCount) sections"]
                        .compactMap { $0 }.joined(separator: " · ")
                )
                if export.previousTempo != nil || export.previousSectionCount != nil {
                    InfoRow(
                        label: "Replaced",
                        value: [export.previousTempo.map { "\($0) BPM" },
                                export.previousSectionCount.map { "\($0) sections" }]
                            .compactMap { $0 }.joined(separator: " · ")
                    )
                }
                InfoRow(label: "Document", value: export.documentID, valueIsMonospaced: true)

                if job?.hasUnexportedEdits == true {
                    Label("Edited since — export again to send the changes.",
                          systemImage: "pencil.circle.fill")
                        .scaledFont(size: 10.5, relativeTo: .caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func exportStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        formatter.timeStyle = .short
        let absolute = formatter.string(from: date)
        return "\(SongWorkState.relative(date)) · \(absolute)"
    }

    // MARK: Storage

    /// Downloaded audio and 44.1 kHz WAVs are the bulk of the app's disk use and
    /// nothing used to remove them, so the sizes and the cleanup live here.
    private var storage: some View {
        PanelCard {
            GroupLabel("Storage")

            InfoRow(label: "This song", value: Self.bytes(songBytes), valueIsMonospaced: true)
            InfoRow(label: "All analyses", value: Self.bytes(totalBytes), valueIsMonospaced: true)

            if orphanCount > 0 {
                InfoRow(
                    label: "Left over",
                    value: "\(orphanCount) folder\(orphanCount == 1 ? "" : "s")",
                    valueIsMonospaced: true
                )
                Button {
                    jobManager.deleteOrphanedFolders()
                    measureStorage()
                    storageRefresh += 1
                } label: {
                    Label("Remove leftover folders", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                InspectorHint("Folders from earlier runs that no song points at any more.")
            }

            // Held back rather than swept: an unsettled re-analysis can leave a
            // second complete chart on disk, and deleting it silently would be
            // the very data loss the protection exists to prevent. Saying so
            // beats hiding it, which made the space look unreclaimable.
            if keptCount > 0 {
                InfoRow(
                    label: "Kept for safety",
                    value: "\(keptCount) older analysis\(keptCount == 1 ? "" : "es")",
                    valueIsMonospaced: true
                )
                InspectorHint("An earlier chart for this song, from a re-analysis that never finished. It is released once a fresh analysis completes, or when you delete this song's analysis.")
            }

            if let folder = jobFolder {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                } label: {
                    Label("Reveal job folder in Finder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete this analysis", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(songID.map { jobManager.isRunning($0) || jobManager.isRedetecting($0) } ?? true)
                .confirmationDialog(
                    "Delete this analysis?",
                    isPresented: $confirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        if let songID { jobManager.deleteJob(songID: songID) }
                        measureStorage()
                        storageRefresh += 1
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes the downloaded audio, the chart and the sections for this song. "
                         + "The song in TheStageBee is not changed, and anything already exported stays there.")
                }
            }
        }
        .id(storageRefresh)
        // Re-measure whenever this song's analysis moves on: a finished run adds
        // tens of megabytes, and a stale figure is worse than none.
        .task(id: "\(songID ?? "none")-\(storageRefresh)-\(job?.status.rawValue ?? "")-\(job?.chordChartPerformerPath ?? "")") {
            measureStorage()
        }
    }

    /// Walks the job folders once, off the body evaluation path.
    private func measureStorage() {
        songBytes = songID.map { jobManager.storageUsed(songID: $0) } ?? 0
        totalBytes = jobManager.totalStorageUsed()
        orphanCount = jobManager.orphanedFolders().count
    }

    private static func bytes(_ count: Int64) -> String {
        guard count > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    // MARK: Metadata

    private func metadata(_ job: AnalysisJob) -> some View {
        PanelCard {
            GroupLabel("File")
            InfoRow(label: "Duration",
                    value: job.durationSeconds.map { Format.time($0, showTenths: false) } ?? "—",
                    valueIsMonospaced: true)
            InfoRow(label: "Sample rate",
                    value: job.sampleRate.map { "\($0.formatted()) Hz" } ?? "—",
                    valueIsMonospaced: true)
            InfoRow(label: "Channels", value: channelText(job.channels))
            InfoRow(label: "Codec", value: job.codecName ?? "—")
            InfoRow(label: "Bit rate",
                    value: job.bitRate.map { "\($0 / 1000) kbps" } ?? "—",
                    valueIsMonospaced: true)
            InfoRow(label: "File size", value: fileSizeText(job.fileSizeBytes), valueIsMonospaced: true)
        }
    }

    private func channelText(_ channels: Int?) -> String {
        switch channels {
        case 1?: return "Mono"
        case 2?: return "Stereo"
        case let count?: return "\(count) channels"
        default: return "—"
        }
    }

    private func fileSizeText(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Audio health

    private func health(_ job: AnalysisJob) -> some View {
        PanelCard {
            GroupLabel("Audio health")
            InfoRow(label: "Mean volume", value: decibelText(job.meanVolumeDb), valueIsMonospaced: true)
            InfoRow(label: "Peak volume", value: decibelText(job.maxVolumeDb), valueIsMonospaced: true)
            InfoRow(label: "Silent regions",
                    value: job.silenceRegionCount.map(String.init) ?? "—",
                    valueIsMonospaced: true)
            InfoRow(label: "Total silence",
                    value: job.totalSilenceDurationSeconds.map { Format.time($0) } ?? "—",
                    valueIsMonospaced: true)

            let warnings = job.audioHealthWarnings
            if warnings.isEmpty {
                InspectorHint("Nothing flagged — levels look usable for chord recognition.")
            } else {
                ForEach(warnings, id: \.self) { warning in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .scaledFont(size: 10, relativeTo: .caption2)
                        Text(warning)
                            .scaledFont(size: 10.5, relativeTo: .caption2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private func decibelText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f dB", value)
    }

    // MARK: Analysis stats

    private func stats(_ job: AnalysisJob) -> some View {
        PanelCard {
            GroupLabel("Analysis")
            InfoRow(label: "Beat model", value: job.resolvedBeatModel ?? job.requestedBeatModel ?? "—")
            if let requested = job.requestedBeatModel,
               let resolved = job.resolvedBeatModel,
               requested != resolved {
                // "auto" resolving to a concrete model is the normal path, not a
                // failure, so only an explicit request that was not honoured
                // deserves the stronger wording.
                InspectorHint(requested == "auto"
                              ? "Requested automatically; the backend chose \(resolved)."
                              : "Requested \(requested); the backend used \(resolved) instead.")
            }
            InfoRow(label: "Chord model", value: job.chordModel ?? "—")
            InfoRow(label: "Tempo", value: "\(Format.bpm(job.bpm)) BPM", valueIsMonospaced: true)
            InfoRow(label: "Time signature", value: job.estimatedTimeSignature ?? "—", valueIsMonospaced: true)
            InfoRow(label: "Beats", value: job.beatCount.map(String.init) ?? "—", valueIsMonospaced: true)
            InfoRow(label: "Bars",
                    value: (job.chordChartBarCount ?? job.barCount).map(String.init) ?? "—",
                    valueIsMonospaced: true)
            InfoRow(label: "Chords", value: job.chordCount.map(String.init) ?? "—", valueIsMonospaced: true)
            InfoRow(label: "Sections", value: job.sectionCount.map(String.init) ?? "—", valueIsMonospaced: true)
        }
    }

    // MARK: Environment readiness

    private var readiness: some View {
        PanelCard {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Environment check")
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .subheadline)
                Text("· runs at launch and before every job")
                    .scaledFont(size: 10.5, relativeTo: .caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let report = environment.tools {
                ForEach(Tool.allCases) { tool in
                    InspectorToolRow(tool: tool, status: report.status(for: tool))
                }
                ForEach(report.missing, id: \.id) { tool in
                    InspectorMonoBlock(text: tool.installHint)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                    Text("Checking tools…")
                        .scaledFont(size: 11.5, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                StatusPill(
                    text: backendText,
                    systemImage: "circle.fill",
                    tint: environment.backendAvailable == true ? .green : .red
                )
                Spacer(minLength: 4)
                Button {
                    Task { await environment.refresh() }
                } label: {
                    if environment.isChecking {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .disabled(environment.isChecking)
            }

            if let checked = environment.lastCheckedAt {
                InspectorHint("Last checked \(checked.formatted(date: .omitted, time: .shortened)) · \(environment.backendURL)")
            } else {
                InspectorHint(environment.backendURL)
            }
        }
    }

    private var backendText: String {
        switch environment.backendAvailable {
        case true?:  return "Backend online"
        case false?: return "Backend offline"
        default:     return "Backend not checked"
        }
    }

    // MARK: Signed out

    private var readOnlyNote: some View {
        PanelCard {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .scaledFont(size: 12, relativeTo: .footnote)
                    .foregroundStyle(.secondary)
                Text("Read-only")
                    .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
            }
            Text("You’re signed out. Analysis still works, but exporting to TheStageBee needs a signed-in account with write access.")
                .scaledFont(size: 11, relativeTo: .caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Small pieces
//
// Named with an `Inspector` prefix so they cannot collide with the atoms in
// DesignKit or with helpers in the other panes.

/// The proportional share one chord holds of a bar's duration.
private struct InspectorShareBar: View {
    let fraction: Double

    // Decorative: the same proportion is printed as a number beside it.
    var body: some View {
        bar.accessibilityHidden(true)
    }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: max(2, geometry.size.width * clamped))
            }
        }
        .frame(height: 7)
    }

    private var clamped: Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
}

/// Secondary explanatory copy under a control.
private struct InspectorHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .scaledFont(size: 10.5, relativeTo: .caption2)
            .foregroundStyle(.tertiary)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A monospaced block: an error from a stage, or a command to run.
private struct InspectorMonoBlock: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .scaledFont(size: 10.5, design: .monospaced, relativeTo: .caption2)
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(tint.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// Full-width action with its keyboard hint on the right.
private struct InspectorActionButton: View {
    let title: String
    let key: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .scaledFont(size: 11.5, relativeTo: .caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                KeyCap(key: key)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!isEnabled)
        // The key cap itself is hidden, so the shortcut is said here instead of
        // trailing the button's name as a stray letter.
        .accessibilityHint("Shortcut \(key.uppercased())")
    }
}

/// One line of the readiness panel: tick or cross, the tool, where it resolved.
private struct InspectorToolRow: View {
    let tool: Tool
    let status: ToolStatus?

    private var isAvailable: Bool { status?.isAvailable ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .scaledFont(size: 12, relativeTo: .footnote)
                    .foregroundStyle(isAvailable ? Color.green : Color.red)
                    .frame(width: 14)
                Text(tool.rawValue)
                    .scaledFont(size: 11.5, weight: .semibold, design: .monospaced, relativeTo: .caption)
                Spacer(minLength: 6)
                Text(trailing)
                    .scaledFont(size: 10, design: .monospaced, relativeTo: .caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(fullDescription)
            }
            if !isAvailable {
                Text("not found — \(tool.purpose)")
                    .scaledFont(size: 10.5, relativeTo: .caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
        }
    }

    /// The whole thing, for hover, since the row itself has to truncate.
    private var fullDescription: String {
        guard let status, let path = status.path else { return "Not found" }
        return [status.version, path].compactMap { $0 }.joined(separator: " · ")
    }

    /// Version and the directory it came from, which is what tells two installs apart.
    private var trailing: String {
        guard let status, let path = status.path else { return "" }
        let directory = (path as NSString).deletingLastPathComponent
        guard let version = status.version, !version.isEmpty else { return directory }
        return "\(version) · \(directory)"
    }
}
