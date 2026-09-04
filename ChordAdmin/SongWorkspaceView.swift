import SwiftUI

/// The middle column: transport, waveform overview, and the chord chart.
///
/// The chart pane is always present — it shows a skeleton while a job runs
/// rather than appearing halfway through and reflowing the window, which is
/// what the old conditional three-pane layout did.
struct SongWorkspaceView: View {
    let item: LibraryItem
    let job: AnalysisJob?
    let bars: [ChordChartBarEntry]
    let rawChords: [CleanedChord]
    let changedBars: Set<Int>
    let isPreviewing: Bool

    @ObservedObject var jobManager: JobManager
    @ObservedObject var sectionStore: SectionStore
    @ObservedObject var audioPlayer: ChordAudioPlayer
    @ObservedObject var waveformLoader: WaveformLoader

    @Binding var selectedBar: Int?
    @Binding var waveZoom: CGFloat
    @Binding var followPlayhead: Bool

    var onStartAnalysis: () -> Void
    /// A from-scratch run, for when reusing what is on disk cannot help.
    var onReanalyse: () -> Void
    var onCancelRun: () -> Void
    var onSubdivisionChange: (Int, Int) -> Void
    var onSplit: (Int) -> Void
    var onMerge: (Int) -> Void
    var onRename: (ChordSection) -> Void
    var onShowStages: () -> Void
    /// Clears the rolled-back-re-analysis notice once the user has read it.
    var onDismissNotice: () -> Void

    /// Shown above the chart while the Tuning inspector is open, so the pickup
    /// can be chosen by looking at the audio rather than by trial and error.
    var pickup: PickupChoice?

    /// True while this song is being analysed. Trusts the job's own status as
    /// well as the manager, so a job recorded mid-run can never be presented as
    /// "not analysed yet".
    private var isRunning: Bool {
        jobManager.isRunning(item.id) || (job?.status.isRunning ?? false)
    }

    private var activeBar: Int? {
        bars.last(where: { $0.start <= audioPlayer.currentTime })?.bar
    }

    /// Clicking the waveform moves the playhead *and* selects the bar under it,
    /// so the chart scrolls there and the inspector follows. Without this the
    /// waveform could locate a moment in a long song but not take you to it.
    private func seekAndSelect(_ time: Double) {
        audioPlayer.seek(to: time)
        if let bar = bars.last(where: { $0.start <= time })?.bar {
            selectedBar = bar
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            transportBar
            Divider()
            // A failed section save was only ever shown inside the Bar tab, so
            // renames and merges could silently fail to reach disk and be lost
            // on the next reload with nothing said. It outranks a rollback
            // notice: it means work on screen is not saved.
            // Only when the store is actually holding this song's sections —
            // otherwise a failure carried a warning about lost work onto songs
            // it had nothing to do with.
            // Nothing at all is reaching disk — this outranks everything else,
            // because every other message assumes the work is being saved.
            if let failure = jobManager.persistenceError {
                noticeRow("This song's analysis is not being saved: \(failure) — anything you change now will be lost when the app closes.",
                          symbol: "externaldrive.trianglebadge.exclamationmark",
                          tint: .red, onDismiss: nil)
                Divider()
            } else if let failure = sectionStore.saveError,
                      job.map(sectionStore.isLoaded(for:)) == true {
                noticeRow("Sections could not be saved: \(failure) — your renames and splits are not on disk.",
                          symbol: "exclamationmark.triangle.fill", tint: .red, onDismiss: nil)
                Divider()
            } else if let notice = job?.notice, !notice.isEmpty {
                noticeRow(notice, symbol: "arrow.uturn.backward.circle.fill",
                          tint: .orange, onDismiss: onDismissNotice)
                Divider()
            }
            overview
            Divider()
            if let pickup, audioPlayer.isLoaded, !pickup.beatTimes.isEmpty {
                PickupChooserView(
                    samples: waveformLoader.samples,
                    duration: audioPlayer.duration,
                    beatTimes: pickup.beatTimes,
                    beatsPerBar: pickup.beatsPerBar,
                    selection: pickup.offset,
                    onApply: pickup.onApply,
                    onRevert: pickup.onRevert,
                    isDirty: pickup.isDirty,
                    canApply: pickup.canApply
                )
                Divider()
            }
            chartArea
        }
        .background(Color(nsColor: .textBackgroundColor))
        // A download and analysis run for minutes. Without this they passed in
        // total silence for a VoiceOver user, who had no way to tell whether
        // anything was still happening.
        .onChange(of: runningTitle) { _, title in
            guard isRunning, !title.isEmpty else { return }
            AccessibilityNotification.Announcement(title).post()
        }
        .onChange(of: statusKind) { previous, current in
            guard previous == .running, current != .running else { return }
            AccessibilityNotification.Announcement(completionAnnouncement).post()
        }
    }

    /// What to say when a run stops, in the terms the strip itself uses.
    private var completionAnnouncement: String {
        switch statusKind {
        case .failed:     return "Analysis failed. \(job?.errorMessage ?? "")"
        case .audioReady: return pausedTitle
        case .cancelled:  return "Analysis cancelled"
        default:          return "Analysis finished"
        }
    }

    // MARK: - Transport

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button(action: audioPlayer.togglePlayPause) {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .scaledFont(size: 12, weight: .bold, relativeTo: .footnote)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(audioPlayer.isLoaded ? Color.accentColor : Color.secondary))
            }
            .buttonStyle(.plain)
            .disabled(!audioPlayer.isLoaded)
            .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")
            // Deliberately no bare-space shortcut: an unmodified key equivalent
            // is swallowed before text fields see it, which is how the previous
            // build's s/m/r monitor broke typing in the URL and BPM fields.
            .help("Play or pause")

            Text("\(Format.time(audioPlayer.currentTime)) / \(Format.time(audioPlayer.duration))")
                .scaledFont(size: 12, design: .monospaced, relativeTo: .footnote)
                .foregroundStyle(.secondary)
                .frame(minWidth: 108, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)

            // Only a separator when there is something to separate.
            if !statPills.isEmpty {
                Divider().frame(height: 18)
            }

            ForEach(statPills, id: \.self) { pill in
                Text(pill)
                    .scaledFont(size: 11, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(Capsule())
            }

            Spacer(minLength: 8)

            if audioPlayer.isLoaded {
                zoomControls
            }
        }
        .padding(.horizontal, 14)
        // minHeight, not height: pinned to an exact height this clipped rather
        // than grew when the text inside it got bigger.
        .frame(minHeight: 46)
    }

    private var statPills: [String] {
        guard let job else { return [] }
        var pills: [String] = []
        if let bpm = job.bpm {
            let detected = job.manualBpm == nil ? " detected" : " manual"
            pills.append("\(Format.bpm(job.manualBpm ?? bpm)) BPM\(detected)")
        }
        if let signature = job.estimatedTimeSignature { pills.append(signature) }
        if !bars.isEmpty { pills.append("\(bars.count) bars") }
        if !sectionStore.sections.isEmpty { pills.append("\(sectionStore.sections.count) sections") }
        return pills
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button { waveZoom = max(1, waveZoom / 1.5) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(waveZoom <= 1.01)
            .accessibilityLabel("Zoom out")
            .help("Zoom the waveform out")

            Text(waveZoom < 1.05 ? "Fit" : String(format: "%.1f×", waveZoom))
                .scaledFont(size: 11, relativeTo: .caption)
                .foregroundStyle(.secondary)
                .frame(width: 30)

            Button { waveZoom = min(32, waveZoom * 1.5) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Zoom in")
            .help("Zoom the waveform in")

            Toggle(isOn: $followPlayhead) {
                Label("Follow", systemImage: "scope")
                    .scaledFont(size: 11, relativeTo: .caption)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Keep the playhead centred while playing")
        }
    }

    /// A rolled-back re-analysis leaves the *previous* chart on screen, which
    /// without this reads as the new run having quietly done nothing.
    private func noticeRow(
        _ text: String, symbol: String, tint: Color, onDismiss: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .scaledFont(size: 11, relativeTo: .caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let onDismiss {
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
                    .scaledFont(size: 11, relativeTo: .caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10))
    }

    // MARK: - Overview strip

    @ViewBuilder
    private var overview: some View {
        if audioPlayer.isLoaded {
            waveform
        } else {
            statusStrip
        }
    }

    private var waveform: some View {
        GeometryReader { geo in
            let contentWidth = geo.size.width * max(1, waveZoom)
            let playheadX = audioPlayer.duration > 0
                ? CGFloat(audioPlayer.currentTime / audioPlayer.duration) * contentWidth
                : 0

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: waveZoom > 1.01) {
                    ZStack(alignment: .topLeading) {
                        WaveformView(
                            samples: waveformLoader.samples,
                            duration: audioPlayer.duration,
                            currentTime: audioPlayer.currentTime,
                            bars: bars,
                            sections: sectionStore.sections,
                            rawChords: rawChords,
                            onSeek: seekAndSelect
                        )
                        .frame(width: contentWidth, height: geo.size.height)

                        // Invisible marker the scroll view can centre on.
                        HStack(spacing: 0) {
                            Color.clear.frame(width: max(0, playheadX), height: 1)
                            Color.clear
                                .frame(width: 1, height: geo.size.height)
                                .id("playhead")
                        }
                    }
                }
                .onChange(of: audioPlayer.currentTime) {
                    guard followPlayhead, audioPlayer.isPlaying, waveZoom > 1.01 else { return }
                    proxy.scrollTo("playhead", anchor: .center)
                }
            }
        }
        .frame(height: 132)
    }

    /// Shown instead of the waveform when there is no audio to draw yet.
    private var statusStrip: some View {
        HStack(spacing: 14) {
            switch statusKind {
            case .running:
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(runningTitle)
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                    Text(progressSummary)
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show stages", action: onShowStages)
                Button("Cancel", role: .destructive, action: onCancelRun)

            case .audioReady:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pausedTitle)
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                    Text(pausedDetail)
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Resume analysis", action: onStartAnalysis)
                    .buttonStyle(.borderedProminent)

            case .audioMissing:
                Image(systemName: "waveform.slash")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Audio unavailable")
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                    Text("The chart is here, but the analysis audio could not be opened, so there is no waveform or playback.")
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Re-analyse", action: onReanalyse)

            case .cancelled:
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Analysis cancelled")
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                    Text("The download had not finished, so starting again begins from the beginning.")
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Analyse", action: onReanalyse)
                    .buttonStyle(.borderedProminent)

            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(failureTitle)
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                    if let message = job?.errorMessage {
                        Text(message)
                            .scaledFont(size: 11, relativeTo: .caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button("See what failed", action: onShowStages)

            case .notAnalysed:
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Not analysed yet")
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                    Text(item.ref == nil
                         ? "This song has no YouTube link, so there is nothing to analyse."
                         : "Download the audio and detect beats, chords and sections.")
                        .scaledFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Analyse", action: onStartAnalysis)
                    .buttonStyle(.borderedProminent)
                    .disabled(item.ref == nil)
            }
        }
        .padding(.horizontal, 18)
        // The waveform this replaces is a fixed-height canvas, so 132 is the
        // resting height — but the strip holds three lines of text, and pinning
        // it exactly clipped them rather than letting the row grow.
        .frame(minHeight: 132)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private enum StatusKind: Equatable { case running, audioReady, failed, cancelled, audioMissing, notAnalysed }

    private var statusKind: StatusKind {
        if isRunning { return .running }
        switch job?.status {
        case .audioReady:            return .audioReady
        case .cancelled:             return .cancelled
        case .failed:                return .failed
        case .none:                  return .notAnalysed
        default:
            // Reaching here means the job finished but its audio would not load,
            // so the waveform could not be shown. Saying "analysis paused" would
            // send the user to re-run analysis it has already done.
            return job?.hasChart == true ? .audioMissing : .notAnalysed
        }
    }

    /// `.audioReady` has three causes — an unreachable backend, a cancel, or an
    /// interrupted quit — and only one of them is the backend's fault.
    private var pausedTitle: String {
        switch job?.pauseCause {
        case .backendUnavailable: return "Audio ready — analysis paused"
        case .cancelled:          return "Audio ready — analysis cancelled"
        default:                  return "Audio ready — analysis unfinished"
        }
    }

    private var pausedDetail: String {
        switch job?.pauseCause {
        case .backendUnavailable(let message):
            return "\(message) Nothing needs downloading again."
        case .cancelled:
            return "You stopped the run. The audio is on disk, so resuming picks up where it left off."
        default:
            return "The app closed before the analysis finished. The audio is on disk, so resuming picks up where it left off."
        }
    }

    private var runningTitle: String {
        guard let stage = job?.stageReport.runningStage else { return "Analysing…" }
        return stage.title
    }

    private var completedStages: Int {
        job?.stageReport.completedCount ?? 0
    }

    private var progressSummary: String {
        let total = PipelineStage.allCases.count
        let done = completedStages
        guard done > 0 else { return "The chart fills in as analysis completes" }
        return "\(done) of \(total) stages done · the chart fills in as analysis completes"
    }

    private var failureTitle: String {
        guard let stage = job?.stageReport.firstFailure?.stage else { return "Analysis failed" }
        return "Failed at \(stage.title.lowercased())"
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartArea: some View {
        if bars.isEmpty && isRunning {
            SkeletonChart()
        } else {
            ChordChartView(
                bars: bars,
                sectionStore: sectionStore,
                subdivisions: job?.subdivisionsByBar ?? [:],
                selectedBar: $selectedBar,
                activeBar: activeBar,
                followPlayhead: followPlayhead && audioPlayer.isPlaying,
                isPreviewing: isPreviewing,
                changedBars: changedBars,
                onSeek: { audioPlayer.seek(to: $0) },
                onSubdivisionChange: onSubdivisionChange,
                onSplit: onSplit,
                onMerge: onMerge,
                onRename: onRename
            )
        }
    }
}

// MARK: - Skeleton

/// Everything the pickup chooser needs, bundled so the workspace's parameter
/// list does not grow another six entries.
struct PickupChoice {
    var beatTimes: [Double]
    var beatsPerBar: Int
    var offset: Binding<Int>
    var isDirty: Bool
    var canApply: Bool = true
    var onApply: () -> Void
    var onRevert: () -> Void
}

/// Placeholder bars shown while a job runs, so the layout does not jump when
/// the real chart arrives.
private struct SkeletonChart: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<2, id: \.self) { group in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: group == 0 ? 120 : 160, height: 12)
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 10) {
                            ForEach(0..<4, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.08))
                                    .frame(height: 60)
                            }
                        }
                    }
                }
                .opacity(group == 0 ? 0.9 : 0.45)
            }

            Text("The chart fills in as analysis completes.")
                .scaledFont(size: 11, relativeTo: .caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
