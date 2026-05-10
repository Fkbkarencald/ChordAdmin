//
//  ContentView.swift
//  ChordAdmin
//
//  Created by Frankie Benjamin on 6/5/2026.
//

import SwiftUI
import AVFoundation
import Combine
import FirebaseAuth

struct ContentView: View {
    @StateObject private var jobManager = JobManager()
    @StateObject private var songStore = FirebaseSongStore()
    @StateObject private var authStore = AuthStore()

    var body: some View {
        NavigationStack {
            SongBrowserView(songStore: songStore, authStore: authStore, jobManager: jobManager)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: authStore.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                Task { await songStore.fetchSongs() }
            }
        }
    }
}

// MARK: - Page 1: Song browser

private struct SongBrowserView: View {
    @ObservedObject var songStore: FirebaseSongStore
    @ObservedObject var authStore: AuthStore
    @ObservedObject var jobManager: JobManager
    @State private var searchText: String = ""
    @State private var selectedSong: FirebaseSong? = nil

    private var filteredSongs: [FirebaseSong] {
        let youtubeSongs = songStore.songs.filter { youTubeVideoID(from: $0.link) != nil }
        guard !searchText.isEmpty else { return youtubeSongs }
        let q = searchText.lowercased()
        return youtubeSongs.filter { song in
            song.title.lowercased().contains(q) ||
            (song.artists?.first?.name.lowercased().contains(q) ?? false)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Text("ChordAdmin")
                    .font(.title2.bold())
                Spacer()
                AuthStatusView(authStore: authStore)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search songs…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.body)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Grid
            if songStore.isLoading {
                Spacer()
                ProgressView("Loading songs…")
                Spacer()
            } else if songStore.songs.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No songs found")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredSongs) { song in
                            NavigationLink(value: song) {
                                SongCard(song: song)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationDestination(for: FirebaseSong.self) { song in
            ProcessingView(song: song, jobManager: jobManager)
        }
        .task {
            if songStore.songs.isEmpty {
                await songStore.fetchSongs()
            }
        }
    }
}

// MARK: - Page 2: Processing

private struct ProcessingView: View {
    let song: FirebaseSong
    @ObservedObject var jobManager: JobManager
    @State private var urlInput: String
    @State private var logCollapsed: Bool = false

    init(song: FirebaseSong, jobManager: JobManager) {
        self.song = song
        self.jobManager = jobManager
        _urlInput = State(initialValue: song.link ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // URL input + Start button
            HStack {
                TextField("YouTube URL", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(jobManager.isRunning)

                Button("Start") {
                    Task { await jobManager.startJob(url: urlInput) }
                }
                .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty || jobManager.isRunning)
                .buttonStyle(.borderedProminent)
            }

            // Bento layout: left job info | chord chart | log
            HStack(alignment: .top, spacing: 12) {

                // Left pane – scrollable job details
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let job = jobManager.currentJob {

                            BentoSection(title: "Status") {
                                VStack(alignment: .leading, spacing: 6) {
                                    StatusBadge(status: job.status)
                                    if let errorMsg = job.errorMessage {
                                        Text(errorMsg)
                                            .foregroundColor(.red)
                                            .font(.callout)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }

                            let hasFiles = job.originalAudioPath != nil || job.analysisWavPath != nil
                                || job.metadataPath != nil || job.audioHealthPath != nil
                            if hasFiles {
                                BentoSection(title: "Files") {
                                    VStack(alignment: .leading, spacing: 3) {
                                        if let p = job.originalAudioPath { CompactFileRow(label: "Original audio", path: p, playable: true) }
                                        if let p = job.analysisWavPath   { CompactFileRow(label: "Analysis WAV",   path: p, playable: true) }
                                        if let p = job.metadataPath      { CompactFileRow(label: "Metadata JSON",  path: p) }
                                        if let p = job.audioHealthPath   { CompactFileRow(label: "Audio Health",   path: p) }

                                        Divider().padding(.vertical, 2)

                                        Button {
                                            let rp = job.originalAudioPath ?? job.analysisWavPath ?? job.metadataPath ?? job.audioHealthPath
                                            if let rp {
                                                NSWorkspace.shared.open(URL(fileURLWithPath: rp).deletingLastPathComponent())
                                            }
                                        } label: {
                                            Label("Reveal Folder", systemImage: "folder")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }

                            if job.metadataPath != nil {
                                BentoSection(title: "Metadata") {
                                    MetadataPanel(job: job)
                                }
                            }

                            if job.audioHealthPath != nil {
                                BentoSection(title: "Audio Health") {
                                    AudioHealthPanel(job: job)
                                }
                            }

                            if job.audioHealthPath != nil {
                                BentoSection(title: "Backend") {
                                    BackendPanel(job: job, jobManager: jobManager)
                                }
                            }

                        } else {
                            Text("No active job")
                                .foregroundColor(.secondary)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 32)
                        }
                    }
                    .padding(10)
                }
                .frame(width: 280)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.15))
                )

                // Middle pane – chord chart
                if let job = jobManager.currentJob,
                   job.chordChartPreview != nil || job.chordChartSimplePreview != nil || job.chordChartSimplePath != nil {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("CHORD CHART")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                                .kerning(0.5)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                        ChordChartModeSwitcher(job: job, jobManager: jobManager, song: song)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.gray.opacity(0.15))
                    )
                }

                // Right pane – log output
                ZStack(alignment: .topLeading) {
                    if !logCollapsed {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("Log")
                                    .font(.callout.weight(.semibold))
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(jobManager.logOutput, forType: .string)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .font(.caption)
                                }
                                .disabled(jobManager.logOutput.isEmpty)
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { logCollapsed = true }
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Collapse log")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)

                            Divider()

                            ScrollViewReader { proxy in
                                ScrollView {
                                    Text(jobManager.logOutput.isEmpty ? "(no output yet)" : jobManager.logOutput)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                        .id("bottom")
                                }
                                .onChange(of: jobManager.logOutput) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }

                    if logCollapsed {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { logCollapsed = false }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Text("Log")
                                    .font(.callout.weight(.semibold))
                                    .rotationEffect(.degrees(90))
                                    .fixedSize()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(.plain)
                        .help("Expand log")
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: logCollapsed ? 32 : .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.15))
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .navigationTitle(song.title)
        .navigationSubtitle(song.artists?.first?.name ?? "")
    }
}

// MARK: - Auth status view

private struct AuthStatusView: View {
    @ObservedObject var authStore: AuthStore

    var body: some View {
        if authStore.isSigningIn {
            ProgressView()
                .scaleEffect(0.7)
                .padding(.trailing, 4)
        } else if authStore.isSignedIn {
            HStack(spacing: 8) {
                if let email = authStore.user?.email {
                    Label(email, systemImage: "person.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Button("Sign Out") {
                    authStore.signOut()
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Button(action: { authStore.signInWithApple() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "apple.logo")
                        Text("Sign in with Apple")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)

                if let error = authStore.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Song browser

private func youTubeVideoID(from urlString: String?) -> String? {
    guard let urlString, let url = URL(string: urlString) else { return nil }
    if url.host?.contains("youtu.be") == true {
        return url.pathComponents.dropFirst().first
    }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    return components?.queryItems?.first(where: { $0.name == "v" })?.value
}

private struct SongCard: View {
    let song: FirebaseSong

    private var thumbnailURL: URL? {
        guard let videoID = youTubeVideoID(from: song.link) else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg")
    }

    private var hasManySection: Bool { (song.sections?.count ?? 0) > 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                if let thumbURL = thumbnailURL {
                    AsyncImage(url: thumbURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(16 / 9, contentMode: .fill)
                        case .failure:
                            thumbnailPlaceholder
                        case .empty:
                            Color.gray.opacity(0.15)
                                .overlay(ProgressView().scaleEffect(0.6))
                        @unknown default:
                            thumbnailPlaceholder
                        }
                    }
                    .frame(height: 90)
                    .clipped()
                    .overlay(sectionsBadge, alignment: .bottomTrailing)
                } else {
                    thumbnailPlaceholder
                        .frame(height: 90)
                        .overlay(sectionsBadge, alignment: .bottomTrailing)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    if let artist = song.artists?.first?.name, !artist.isEmpty {
                        Text(artist)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.15))
            )
    }

    @ViewBuilder private var sectionsBadge: some View {
        if hasManySection {
            Text("🎹")
                .font(.system(size: 14))
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(6)
        }
    }

    private var thumbnailPlaceholder: some View {
        Color.gray.opacity(0.12)
            .overlay(
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundColor(.secondary)
            )
    }
}

private struct BentoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .kerning(0.5)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.15))
        )
    }
}

// MARK: - Sub-views

private struct StatusBadge: View {
    let status: JobStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color(for: status).opacity(0.15))
            .foregroundColor(color(for: status))
            .clipShape(Capsule())
    }

    private func color(for status: JobStatus) -> Color {
        switch status {
        case .pending:               return .gray
        case .checkingTools:         return .blue
        case .downloading:           return .orange
        case .converting:            return .purple
        case .extractingMetadata:    return .teal
        case .analysingAudioHealth:      return .indigo
        case .checkingAnalysisBackend:   return .cyan
        case .detectingBeats:            return .mint
        case .generatingBeatGrid:        return .teal
        case .recognizingChords:             return .purple
        case .generatingChordChart:          return .pink
        case .generatingSimpleChart:         return .orange
        case .detectingSections:             return .brown
        case .completed:                     return .green
        case .completedWithWarnings:     return .yellow
        case .failed:                    return .red
        }
    }
}

private struct CompactFileRow: View {
    let label: String
    let path: String
    var playable: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.primary)
            Spacer()
            if playable {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Image(systemName: "play.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
    }
}

private struct PathRow: View {
    let label: String
    let path: String
    var playable: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.primary)
            Spacer()
            if playable {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Image(systemName: "play.circle").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "folder").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
    }
}

private struct MetadataPanel: View {
    let job: AnalysisJob

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
            if let v = job.durationSeconds {
                row("Duration", value: String(format: "%.2f s", v))
            }
            if let v = job.sampleRate {
                row("Sample rate", value: "\(v) Hz")
            }
            if let v = job.channels {
                row("Channels", value: "\(v)")
            }
            if let v = job.codecName {
                row("Codec", value: v)
            }
            if let v = job.bitRate {
                row("Bit rate", value: "\(v / 1000) kbps")
            }
            if let v = job.fileSizeBytes {
                row("File size", value: ByteCountFormatter.string(fromByteCount: v, countStyle: .file))
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundColor(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .fontWeight(.medium)
                .gridColumnAlignment(.leading)
        }
    }
}

private struct AudioHealthPanel: View {
    let job: AnalysisJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                if let v = job.meanVolumeDb {
                    row("Mean volume", value: String(format: "%.1f dB", v))
                }
                if let v = job.maxVolumeDb {
                    row("Max volume", value: String(format: "%.1f dB", v))
                }
                if let v = job.silenceRegionCount {
                    row("Silence regions", value: "\(v)")
                }
                if let v = job.totalSilenceDurationSeconds {
                    row("Total silence", value: String(format: "%.2f s", v))
                }
            }
            .font(.caption)

            // Warnings
            let warnings = derivedWarnings
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// Re-derives warnings from the job fields so the UI stays in sync without
    /// needing to store them separately in AnalysisJob.
    private var derivedWarnings: [String] {
        var warnings: [String] = []
        if let max = job.maxVolumeDb, max > -0.5 {
            warnings.append("Possible clipping or very hot master")
        }
        if let mean = job.meanVolumeDb, mean < -35 {
            warnings.append("Very quiet audio")
        }
        if let dur = job.durationSeconds, dur > 0,
           let sil = job.totalSilenceDurationSeconds, (sil / dur) > 0.2 {
            warnings.append("Large silent sections detected")
        }
        return warnings
    }

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundColor(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .fontWeight(.medium)
                .gridColumnAlignment(.leading)
        }
    }
}

private struct BackendPanel: View {
    let job: AnalysisJob
    @ObservedObject var jobManager: JobManager
    @State private var seedBpm: Double = 120
    @State private var useSeedBpm: Bool = false
    @State private var stableTempo: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Backend:")
                    .font(.callout.weight(.semibold))
                backendStatusLabel
            }

            if let errMsg = job.backendErrorMessage {
                Label(errMsg, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if job.analysisBackendAvailable == true {

                let hasStats = job.requestedBeatModel != nil || job.resolvedBeatModel != nil
                    || job.bpm != nil || job.beatCount != nil || job.barCount != nil || job.chordCount != nil
                if hasStats {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                        if let v = job.requestedBeatModel { row("Requested model",    value: v) }
                        if let v = job.resolvedBeatModel  { row("Resolved model",     value: v) }
                        if let v = job.chordModel         { row("Chord model",        value: v) }
                        if let v = job.bpm                { row("BPM",               value: String(format: "%.2f", v)) }
                        else if job.requestedBeatModel != nil { row("BPM",            value: "—") }
                        if let v = job.beatCount          { row("Beat count",         value: "\(v)") }
                        if let v = job.barCount           { row("Bar count",          value: "\(v)") }
                        if let v = job.estimatedTimeSignature { row("Time signature", value: v) }
                        if let v = job.chordCount         { row("Chord count",        value: "\(v)") }
                    }
                    .font(.caption)
                }

                if job.analysisBackendAvailable == true && job.analysisWavPath != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $useSeedBpm) {
                            Text("Constrain BPM range")
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)

                        if useSeedBpm {
                            HStack(spacing: 8) {
                                Text("Seed BPM:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Stepper(
                                    value: $seedBpm,
                                    in: 40...300,
                                    step: 1,
                                    label: {
                                        let lo = seedBpm * 0.8
                                        let hi = seedBpm * 1.2
                                        Text(String(format: "%.0f  (range: %.0f–%.0f)", seedBpm, lo, hi))
                                            .font(.system(.caption, design: .monospaced))
                                    }
                                )
                            }
                        }

                        Toggle(isOn: $stableTempo) {
                            Text("Stable tempo (high transition_lambda)")
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)
                        .help("Forces madmom to commit to one tempo throughout the track. Useful when it keeps drifting or detecting double/half-time.")

                        Button {
                            let minBpm = useSeedBpm ? seedBpm * 0.8 : nil
                            let maxBpm = useSeedBpm ? seedBpm * 1.2 : nil
                            let tl: Double? = stableTempo ? 1000 : nil
                            Task { await jobManager.redetectBeats(minBpm: minBpm, maxBpm: maxBpm, transitionLambda: tl) }
                        } label: {
                            Label("Redetect Beats & Tempo", systemImage: "waveform.and.magnifyingglass")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .disabled(jobManager.isRunning)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var backendStatusLabel: some View {
        if job.analysisBackendAvailable == true {
            Label("Available", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        } else if job.analysisBackendAvailable == false {
            Label("Unavailable", systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.caption)
        } else {
            Label("Checking…", systemImage: "arrow.clockwise")
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundColor(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .fontWeight(.medium)
                .gridColumnAlignment(.leading)
        }
    }
}

private struct ChordPreviewPanel: View {
    let chords: [CleanedChord]
    let totalCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let shown = min(chords.count, 10)
            let label = totalCount.map { "First \(shown) of \($0) chords" } ?? "First \(shown) chords"
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            ForEach(Array(chords.prefix(10).enumerated()), id: \.offset) { _, chord in
                HStack(spacing: 10) {
                    Text(String(format: "%.3f – %.3f", chord.start, chord.end))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Text(chord.displayChord)
                        .font(.caption.weight(.medium))
                    Spacer()
                    if chord.rawChord != chord.displayChord {
                        Text(chord.rawChord)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.gray.opacity(0.2))
        )
    }
}

private struct ChordChartPreviewPanel: View {
    let bars: [ChordChartBarEntry]
    let totalCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let shown = min(bars.count, 8)
            let label = totalCount.map { "First \(shown) of \($0) bars" } ?? "First \(shown) bars"
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            ForEach(Array(bars.prefix(8).enumerated()), id: \.offset) { _, bar in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Bar \(bar.bar)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 44, alignment: .leading)
                        Text(bar.primaryChord ?? "—")
                            .font(.caption.weight(.semibold))
                    }
                    ForEach(Array(bar.chords.enumerated()), id: \.offset) { _, chord in
                        HStack(spacing: 6) {
                            Text(String(format: "%.3f – %.3f", chord.start, chord.end))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 100, alignment: .leading)
                            Text(chord.displayChord)
                                .font(.caption2.weight(.medium))
                            Text(String(format: "(%.3fs)", chord.overlapSeconds))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 44)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.gray.opacity(0.2))
        )
    }
}

private struct ChordChartSimplePreviewPanel: View {
    let bars: [ChordChartSimpleBarEntry]
    let totalCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let shown = min(bars.count, 16)
            let label = totalCount.map { "First \(shown) of \($0) bars" } ?? "First \(shown) bars"
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            ForEach(Array(bars.prefix(16).enumerated()), id: \.offset) { _, bar in
                HStack(spacing: 6) {
                    Text("Bar \(bar.bar)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(bar.chord)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(String(format: "%.3f – %.3f", bar.start, bar.end))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.gray.opacity(0.2))
        )
    }
}

private struct SectionCandidatesPreviewPanel: View {
    let candidates: [SectionCandidate]
    let totalCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let shown = min(candidates.count, 5)
            let label = totalCount.map { "First \(shown) of \($0) candidates" } ?? "\(shown) candidates"
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            ForEach(Array(candidates.prefix(5).enumerated()), id: \.offset) { _, c in
                HStack(alignment: .top, spacing: 8) {
                    Text(c.label)
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .frame(width: 16, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bars \(c.startBar)\u{2013}\(c.endBar)  (\(c.barCount) bars, \(c.matchCount)\u{00d7})")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(c.barSignatures.joined(separator: " – "))
                            .font(.caption.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.gray.opacity(0.2))
        )
    }
}

// MARK: - Audio player

@MainActor
private final class ChordAudioPlayer: NSObject, ObservableObject {
    @Published var currentTime: Double = 0
    @Published var isPlaying: Bool = false
    @Published var duration: Double = 0
    @Published var isLoaded: Bool = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(path: String) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
        p.delegate = self
        p.prepareToPlay()
        player = p
        duration = p.duration
        currentTime = 0
        isLoaded = true
    }

    func togglePlayPause() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            stopTimer()
            isPlaying = false
        } else {
            p.play()
            startTimer()
            isPlaying = true
        }
    }

    func seek(to time: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(time, p.duration))
        currentTime = p.currentTime
    }

    func stop() {
        player?.stop()
        stopTimer()
        player = nil
        isPlaying = false
        isLoaded = false
        duration = 0
        currentTime = 0
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension ChordAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.stopTimer()
            self.currentTime = 0
            self.player?.currentTime = 0
        }
    }
}

// MARK: - Waveform loader

@MainActor
private final class WaveformLoader: ObservableObject {
    @Published var samples: [Float] = []
    private var loadedPath: String?

    func load(path: String) async {
        guard path != loadedPath else { return }
        loadedPath = path
        samples = []
        let capturedPath = path
        let result = await Task.detached(priority: .userInitiated) {
            WaveformLoader.extractSamples(from: capturedPath, targetCount: 1800)
        }.value
        guard capturedPath == loadedPath else { return }
        samples = result
    }

    func reset() {
        samples = []
        loadedPath = nil
    }

    nonisolated static func extractSamples(from path: String, targetCount: Int) -> [Float] {
        let url = URL(fileURLWithPath: path)
        guard let audioFile = try? AVAudioFile(forReading: url) else { return [] }
        let format = audioFile.processingFormat
        let totalFrames = Int64(audioFile.length)
        guard totalFrames > 0 else { return [] }
        let framesPerSample = max(1, Int(totalFrames) / targetCount)
        let chunkSize = AVAudioFrameCount(framesPerSample)
        let channelCount = Int(format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize),
              let channelData = buffer.floatChannelData else { return [] }
        var result: [Float] = []
        result.reserveCapacity(targetCount)
        while audioFile.framePosition < totalFrames {
            buffer.frameLength = 0
            do { try audioFile.read(into: buffer, frameCount: chunkSize) } catch { break }
            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0 else { break }
            var peak: Float = 0
            for j in 0..<framesRead {
                for ch in 0..<channelCount {
                    let v = abs(channelData[ch][j])
                    if v > peak { peak = v }
                }
            }
            result.append(peak)
        }
        return result
    }
}

// MARK: - Waveform view

private struct WaveformView: View {
    let samples: [Float]
    let duration: Double
    let currentTime: Double
    let bars: [ChordChartBarEntry]
    var rawChords: [CleanedChord] = []
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                // Background
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color.black.opacity(0.85)))

                // Alternating bar shading (faint grid reference)
                for (i, bar) in bars.enumerated() where i.isMultiple(of: 2) {
                    let x1 = xPos(bar.start, width: size.width)
                    let x2 = xPos(bar.end,   width: size.width)
                    ctx.fill(Path(CGRect(x: x1, y: 0, width: x2 - x1, height: size.height)),
                             with: .color(Color.white.opacity(0.04)))
                }

                // Bar boundary lines (faint grid reference)
                for bar in bars {
                    let x = xPos(bar.start, width: size.width)
                    var p = Path()
                    p.move(to:    CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(Color.white.opacity(0.10)), lineWidth: 1)
                }

                // Waveform bars
                if samples.isEmpty {
                    var line = Path()
                    line.move(to:    CGPoint(x: 0,          y: size.height / 2))
                    line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    ctx.stroke(line, with: .color(Color.gray.opacity(0.35)), lineWidth: 1)
                } else {
                    let midY = size.height / 2
                    let barW = size.width / CGFloat(samples.count)
                    for (i, sample) in samples.enumerated() {
                        let x   = CGFloat(i) * barW + barW * 0.5
                        let amp = CGFloat(sample) * midY * 0.88
                        var p = Path()
                        p.move(to:    CGPoint(x: x, y: midY - amp))
                        p.addLine(to: CGPoint(x: x, y: midY + amp))
                        ctx.stroke(p, with: .color(Color.accentColor.opacity(0.55)),
                                   lineWidth: max(1.0, barW - 0.5))
                    }
                }

                // Raw chord detection overlay
                // Alternating cyan/mint so adjacent chords are visually distinct
                let chordColors: [Color] = [.cyan, Color(red: 0.2, green: 0.9, blue: 0.6)]
                for (i, chord) in rawChords.enumerated() {
                    let x1 = xPos(chord.start, width: size.width)
                    let x2 = xPos(chord.end,   width: size.width)
                    let col = chordColors[i % chordColors.count]

                    // Tinted background strip behind each raw chord
                    ctx.fill(
                        Path(CGRect(x: x1, y: size.height * 0.62, width: max(1, x2 - x1), height: size.height * 0.38)),
                        with: .color(col.opacity(0.12))
                    )

                    // Left boundary tick
                    var tick = Path()
                    tick.move(to:    CGPoint(x: x1, y: size.height * 0.58))
                    tick.addLine(to: CGPoint(x: x1, y: size.height))
                    ctx.stroke(tick, with: .color(col.opacity(0.7)), lineWidth: 1)

                    // Label (displayChord, bottom band)
                    let labelX = x1 + 2
                    guard labelX < size.width - 1 else { continue }
                    let resolved = ctx.resolve(
                        Text(chord.displayChord)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(col)
                    )
                    ctx.draw(resolved, at: CGPoint(x: labelX, y: size.height * 0.62 + 2), anchor: .topLeading)
                }

                // Playhead
                if duration > 0, currentTime > 0 {
                    let x = xPos(currentTime, width: size.width)
                    var line = Path()
                    line.move(to:    CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(line, with: .color(.red), lineWidth: 2)
                    let tri = Path { p in
                        p.move(to:    CGPoint(x: x - 4, y: 0))
                        p.addLine(to: CGPoint(x: x + 4, y: 0))
                        p.addLine(to: CGPoint(x: x,     y: 7))
                        p.closeSubpath()
                    }
                    ctx.fill(tri, with: .color(.red))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        guard duration > 0 else { return }
                        let t = Double(val.location.x / geo.size.width) * duration
                        onSeek(max(0, min(t, duration)))
                    }
            )
        }
    }

    private func xPos(_ time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }
}

// MARK: - Chord chart mode switcher

private enum ChordDisplayMode: String, CaseIterable {
    case detailedBars         = "Detailed Bars"
    case chordProgression     = "Chord Progression"
    case performerProgression = "Performer Progression"
}

private struct ChordChartModeSwitcher: View {
    let job: AnalysisJob
    @ObservedObject var jobManager: JobManager
    let song: FirebaseSong
    @State private var localOffset: Int = 0
    @State private var loadedPerformerBars: [ChordChartBarEntry] = []
    @StateObject private var sectionStore = SectionStore()
    @State private var loadedDraftBars: [ChordChartBarEntry] = []
    @State private var selectedDraftBar: ChordChartBarEntry? = nil
    @State private var lastLoadedJobId: String = ""
    @StateObject private var audioPlayer = ChordAudioPlayer()
    @StateObject private var waveformLoader = WaveformLoader()
    @State private var waveZoom: CGFloat = 1.0
    @State private var waveFollowPlayhead: Bool = true
    @State private var loadedRawChords: [CleanedChord] = []
    // Export to TheStageBee
    @StateObject private var exportService = StageBeeExportService()
    @State private var barSubdivisions: [Int: Int] = [:]
    @State private var manualBpmText: String = ""
    @State private var manualBpmActive: Bool = false

    private var audioPath: String? { job.analysisWavPath ?? job.originalAudioPath }

    private func applyManualBpm() {
        guard let bpm = Double(manualBpmText.trimmingCharacters(in: .whitespaces)),
              bpm > 10, bpm < 500 else { return }
        manualBpmActive = true
        Task { await jobManager.setManualBpm(bpm) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if audioPlayer.isLoaded {
                // Playback controls
                HStack(spacing: 12) {
                    Button { audioPlayer.togglePlayPause() } label: {
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)

                    Text(timeString(audioPlayer.currentTime) + " / " + timeString(audioPlayer.duration))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .trailing)

                    Spacer()
                }
            }

            if audioPath != nil {
                VStack(alignment: .leading, spacing: 4) {
                    // Waveform zoom toolbar
                    HStack(spacing: 6) {
                        Button {
                            waveZoom = max(1, waveZoom / 1.5)
                        } label: {
                            Image(systemName: "minus.magnifyingglass").font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .disabled(waveZoom <= 1.01)

                        Text(waveZoom < 1.05 ? "Fit" : String(format: "%.1f×", waveZoom))
                            .font(.system(.caption2, design: .monospaced))
                            .frame(width: 40)

                        Button {
                            waveZoom = min(32, waveZoom * 1.5)
                        } label: {
                            Image(systemName: "plus.magnifyingglass").font(.caption)
                        }
                        .buttonStyle(.bordered)

                        if waveZoom > 1.05 {
                            Button("Fit") { waveZoom = 1 }
                                .buttonStyle(.bordered)
                                .font(.caption2)
                        }

                        Spacer()

                        Toggle(isOn: $waveFollowPlayhead) {
                            Label("Follow", systemImage: "scope")
                                .font(.caption2)
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                    }

                    // Waveform canvas inside horizontal scroll
                    GeometryReader { geo in
                        let contentWidth = geo.size.width * max(1, waveZoom)
                        let playheadX = audioPlayer.duration > 0
                            ? CGFloat(audioPlayer.currentTime / audioPlayer.duration) * contentWidth
                            : CGFloat(0)
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal, showsIndicators: true) {
                                ZStack(alignment: .topLeading) {
                                    WaveformView(
                                        samples: waveformLoader.samples,
                                        duration: audioPlayer.duration,
                                        currentTime: audioPlayer.currentTime,
                                        bars: loadedPerformerBars.isEmpty ? loadedDraftBars : loadedPerformerBars,
                                        rawChords: loadedRawChords,
                                        onSeek: { t in audioPlayer.seek(to: t) }
                                    )
                                    .frame(width: contentWidth, height: geo.size.height)
                                    // Invisible marker at playhead x so ScrollViewReader can track it
                                    HStack(spacing: 0) {
                                        Color.clear.frame(width: max(0, playheadX), height: 1)
                                        Color.clear
                                            .frame(width: 1, height: geo.size.height)
                                            .id("wavePlayhead")
                                    }
                                }
                            }
                            .onChange(of: audioPlayer.currentTime) {
                                guard waveFollowPlayhead, audioPlayer.isPlaying, waveZoom > 1.01 else { return }
                                proxy.scrollTo("wavePlayhead", anchor: .center)
                            }
                        }
                    }
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            // Bar alignment row
            HStack(spacing: 6) {
                Text("Bar Offset")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ForEach(0..<4, id: \.self) { i in
                    Button("\(i)") {
                        guard !jobManager.isRunning else { return }
                        localOffset = i
                        Task { await jobManager.regenerateCharts(offset: i) }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                    .foregroundColor(localOffset == i ? .accentColor : .primary)
                    .background(localOffset == i ? Color.accentColor.opacity(0.12) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .disabled(jobManager.isRunning)
                }

                Divider().frame(height: 16)

                let isHalved = job.tempoHalved == true
                Button(isHalved ? "½ BPM ✓" : "½ BPM") {
                    guard !jobManager.isRunning else { return }
                    Task { await jobManager.halveTempo(!isHalved) }
                }
                .buttonStyle(.bordered)
                .font(.caption2)
                .foregroundColor(isHalved ? .accentColor : .primary)
                .background(isHalved ? Color.accentColor.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .help(isHalved ? "Restore full tempo" : "Halve detected tempo (use when BPM is double the true value)")
                .disabled(jobManager.isRunning)

                Divider().frame(height: 16)

                // Beats-per-bar override — useful for 6/8 songs where madmom detects 3 beats/bar
                let currentBpb = job.beatsPerBarOverride ?? 4
                ForEach([2, 3, 4], id: \.self) { n in
                    Button("\(n)/bar") {
                        guard !jobManager.isRunning else { return }
                        Task { await jobManager.setBeatsPerBar(n) }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                    .foregroundColor(currentBpb == n ? .accentColor : .primary)
                    .background(currentBpb == n ? Color.accentColor.opacity(0.12) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .help(n == 3 ? "3 beats/bar — use when madmom detects 6/8 as 3/4" : "\(n) beats per bar")
                    .disabled(jobManager.isRunning)
                }

                Divider().frame(height: 16)

                // Manual BPM override
                Text("BPM:").font(.caption2).foregroundColor(.secondary)
                TextField(
                    String(format: "%.0f", job.bpm ?? 0),
                    text: $manualBpmText
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 46)
                .onSubmit {
                    applyManualBpm()
                }
                if manualBpmActive {
                    Button("×") {
                        manualBpmText = ""
                        manualBpmActive = false
                        Task { await jobManager.setManualBpm(nil) }
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .help("Clear manual BPM — revert to detected value")
                }

                Spacer()

                // Export to TheStageBee (only when performer chart + sections exist)
                if job.chordChartPerformerPath != nil && job.sectionsPath != nil {
                    Divider().frame(height: 16)
                    Button {
                        guard let folder = jobManager.jobFolder else { return }
                        Task {
                            try? await exportService.export(
                                job: job,
                                jobFolder: folder,
                                song: song,
                                barSubdivisions: barSubdivisions
                            )
                        }
                    } label: {
                        switch exportService.state {
                        case .exporting:
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.6)
                                Text("Exporting…")
                            }
                        case .success:
                            Label("Exported", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        case .failure(let msg):
                            Label(msg, systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                        default:
                            Label("Export to StageBee", systemImage: "arrow.up.circle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                    .disabled(exportService.state == .exporting)
                    .help("Update chord chart and tempo on the TheStageBee song")
                }
            }

            ChordProgressionView(
                bars: loadedPerformerBars,
                fallbackBars: loadedDraftBars,
                totalBarCount: job.chordChartBarCount,
                selectedBar: $selectedDraftBar,
                sectionStore: sectionStore,
                activeBar: {
                    let bars = loadedPerformerBars.isEmpty ? loadedDraftBars : loadedPerformerBars
                    return bars.last(where: { $0.start <= audioPlayer.currentTime })
                }(),
                onSeek: { bar, seekTime in
                    audioPlayer.seek(to: seekTime)
                    selectedDraftBar = bar
                },
                barSubdivisions: $barSubdivisions
            )
            .frame(maxHeight: .infinity)
        }
        .task(id: "\(job.id)-\(job.chartsVersion ?? 0)") {
            let isNewJob = job.id != lastLoadedJobId
            if isNewJob {
                audioPlayer.stop()
                waveformLoader.reset()
                loadedPerformerBars = []
                loadedDraftBars = []
                loadedRawChords = []
                localOffset = job.barAlignmentOffset ?? 0
                manualBpmActive = job.manualBpm != nil
                manualBpmText = job.manualBpm.map { String(format: "%.0f", $0) } ?? ""
                selectedDraftBar = nil
                waveZoom = 1
                lastLoadedJobId = job.id
            }

            // Load performer chart (primary display bars for waveform)
            if let path = job.chordChartPerformerPath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawBars = json["bars"] as? [[String: Any]] {
                var bars: [ChordChartBarEntry] = []
                for bar in rawBars {
                    guard let barNum = bar["bar"] as? Int,
                          let start  = (bar["start"] as? NSNumber).map({ $0.doubleValue }),
                          let end    = (bar["end"]   as? NSNumber).map({ $0.doubleValue }) else { continue }
                    let primary = bar["primaryChord"] as? String
                    let rawChords = bar["chords"] as? [[String: Any]] ?? []
                    var chordEntries: [ChordChartChordEntry] = []
                    for c in rawChords {
                        guard let dc   = c["displayChord"] as? String,
                              let cs   = (c["start"] as? NSNumber).map({ $0.doubleValue }),
                              let ce   = (c["end"]   as? NSNumber).map({ $0.doubleValue }),
                              let ovlp = (c["overlapSeconds"] as? NSNumber).map({ $0.doubleValue }) else { continue }
                        chordEntries.append(ChordChartChordEntry(displayChord: dc, start: cs, end: ce, overlapSeconds: ovlp))
                    }
                    bars.append(ChordChartBarEntry(bar: barNum, start: start, end: end, primaryChord: primary, chords: chordEntries))
                }
                loadedPerformerBars = bars
            }

            // Load draft chart
            if let path = job.chordChartDraftPath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawBars = json["bars"] as? [[String: Any]] {
                var bars: [ChordChartBarEntry] = []
                for bar in rawBars {
                    guard let barNum = bar["bar"] as? Int,
                          let start  = (bar["start"] as? NSNumber).map({ $0.doubleValue }),
                          let end    = (bar["end"]   as? NSNumber).map({ $0.doubleValue }) else { continue }
                    let primary = bar["primaryChord"] as? String
                    let rawChords = bar["chords"] as? [[String: Any]] ?? []
                    var chordEntries: [ChordChartChordEntry] = []
                    for c in rawChords {
                        guard let dc   = c["displayChord"] as? String,
                              let cs   = (c["start"] as? NSNumber).map({ $0.doubleValue }),
                              let ce   = (c["end"]   as? NSNumber).map({ $0.doubleValue }),
                              let ovlp = (c["overlapSeconds"] as? NSNumber).map({ $0.doubleValue }) else { continue }
                        chordEntries.append(ChordChartChordEntry(displayChord: dc, start: cs, end: ce, overlapSeconds: ovlp))
                    }
                    bars.append(ChordChartBarEntry(bar: barNum, start: start, end: end, primaryChord: primary, chords: chordEntries))
                }
                loadedDraftBars = bars
            }

            // Load raw chord detections
            if let path = job.chordCleanedPath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawList = json["chords"] as? [[String: Any]] {
                loadedRawChords = rawList.compactMap { entry in
                    guard let start = (entry["start"] as? NSNumber).map({ $0.doubleValue }),
                          let end   = (entry["end"]   as? NSNumber).map({ $0.doubleValue }),
                          let raw   = entry["rawChord"]     as? String,
                          let disp  = entry["displayChord"] as? String else { return nil }
                    return CleanedChord(start: start, end: end, rawChord: raw, displayChord: disp)
                }
            }

            // Load / refresh sections (after draft bars are ready)
            if let folder = jobManager.jobFolder, isNewJob || sectionStore.sections.isEmpty {
                sectionStore.load(for: job, jobFolder: folder)
            }

            if let ap = audioPath {
                if isNewJob { audioPlayer.load(path: ap) }
                await waveformLoader.load(path: ap)
            }
        }
    }

    private func timeString(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct ChordProgressionView: View {
    let bars: [ChordChartBarEntry]
    var fallbackBars: [ChordChartBarEntry] = []

    let totalBarCount: Int?
    @Binding var selectedBar: ChordChartBarEntry?
    @ObservedObject var sectionStore: SectionStore
    var activeBar: ChordChartBarEntry? = nil
    var onSeek: ((ChordChartBarEntry, Double) -> Void)? = nil

    @Binding var barSubdivisions: [Int: Int]
    @State private var renamingSection: ChordSection? = nil
    @State private var renameText: String = ""
    @State private var keyMonitor: Any? = nil

    private func subdivision(for barNum: Int) -> Int { barSubdivisions[barNum] ?? 4 }

    private var effectiveBars: [ChordChartBarEntry] {
        if !bars.isEmpty { return bars }
        return fallbackBars
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Fixed subdivide + reset toolbar
            HStack(spacing: 6) {
                Text("Subdivide")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(selectedBar == nil ? .secondary.opacity(0.5) : .secondary)
                let subBinding = Binding<Int>(
                    get: { selectedBar.map { subdivision(for: $0.bar) } ?? 4 },
                    set: { if let bar = selectedBar { barSubdivisions[bar.bar] = $0 } }
                )
                Picker("", selection: subBinding) {
                    Text("1").tag(1)
                    Text("1/2").tag(2)
                    Text("1/4").tag(4)
                    Text("1/8").tag(8)
                    Text("1/16").tag(16)
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                .disabled(selectedBar == nil)
                Spacer()
                if sectionStore.sections.count > 1 {
                    Button("Reset sections") {
                        sectionStore.resetToSingle()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

        ScrollViewReader { proxy in
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let display = effectiveBars
                if display.isEmpty {
                    Text("No chord chart available.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(8)
                } else if sectionStore.sections.isEmpty {
                    // Fallback flat layout while sections are loading
                    barGrid(bars: display)
                        .padding(8)
                } else {
                    // Sectioned layout
                    let barByNum = Dictionary(uniqueKeysWithValues: display.map { ($0.bar, $0) })
                    ForEach(sectionStore.sections) { section in
                        let sectionBars = section.bars.compactMap { barByNum[$0] }
                        VStack(alignment: .leading, spacing: 6) {
                            // Section header
                            SectionHeaderView(
                                section: section,
                                isRenaming: renamingSection?.id == section.id,
                                renameText: $renameText,
                                onCommitRename: {
                                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                                    if !trimmed.isEmpty {
                                        sectionStore.rename(section: section.id, to: trimmed)
                                    }
                                    renamingSection = nil
                                },
                                onCancelRename: { renamingSection = nil }
                            )
                            barGrid(bars: sectionBars)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                        Divider().padding(.horizontal, 8)
                    }

                    // Selected bar detail + section controls
                    if let sel = selectedBar {
                        selectedBarPanel(sel: sel, sectionStore: sectionStore)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }

                    Color.clear.frame(height: 8)
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.2)))
            .onChange(of: activeBar?.bar) {
                if let n = activeBar?.bar {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(n, anchor: .center)
                    }
                }
            }
            } // ScrollView
        } // ScrollViewReader
        } // VStack
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard renamingSection == nil else { return event }
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                    return event
                }
                switch event.charactersIgnoringModifiers {
                case "s":
                    if let bar = selectedBar { sectionStore.startNewSection(at: bar.bar) }
                    return nil
                case "m":
                    if let bar = selectedBar { sectionStore.mergeSectionWithPrevious(containing: bar.bar) }
                    return nil
                case "r":
                    if let bar = selectedBar {
                        renamingSection = sectionStore.section(containing: bar.bar)
                    }
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
        .sheet(item: $renamingSection) { section in
            RenameSheetView(
                sectionName: section.name,
                onSave: { newName in
                    sectionStore.rename(section: section.id, to: newName)
                    renamingSection = nil
                },
                onCancel: { renamingSection = nil }
            )
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func barGrid(bars: [ChordChartBarEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: bars.count, by: 4)), id: \.self) { rowStart in
                let rowEnd  = min(rowStart + 4, bars.count)
                let rowBars = Array(bars[rowStart..<rowEnd])
                HStack(spacing: 6) {
                    ForEach(rowBars, id: \.bar) { bar in
                        let isThisBarSelected = selectedBar?.bar == bar.bar
                        ProgressionBarCell(
                            bar: bar,
                            isSelected: isThisBarSelected,
                            isActive: activeBar?.bar == bar.bar,
                            subdivisions: subdivision(for: bar.bar),
                            onTap: { seekTime in
                                if isThisBarSelected {
                                    selectedBar = nil
                                } else {
                                    selectedBar = bar
                                    onSeek?(bar, seekTime)
                                }
                            }
                        )
                        .id(bar.bar)
                    }
                    if rowBars.count < 4 {
                        ForEach(0..<(4 - rowBars.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectedBarPanel(sel: ChordChartBarEntry, sectionStore: SectionStore) -> some View {
        let selSub = subdivision(for: sel.bar)
        let barDuration = max(0.001, sel.end - sel.start)
        let minOverlapForSub = max(0.05, barDuration / Double(selSub) * 0.5)
        let currentSection = sectionStore.section(containing: sel.bar)
        let isFirst = currentSection.map { sectionStore.isFirstSection($0) } ?? true
        let isFirstBar = currentSection?.startBar == sel.bar

        VStack(alignment: .leading, spacing: 8) {
            // Bar info
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bar \(sel.bar)").fontWeight(.semibold)
                    Text(String(format: "%.3f – %.3f s", sel.start, sel.end))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Chord tokens
            let visibleChords = sel.chords
                .filter { $0.overlapSeconds >= minOverlapForSub }
                .sorted { $0.start < $1.start }
            if !visibleChords.isEmpty {
                HStack(spacing: 6) {
                    ForEach(visibleChords, id: \.start) { c in
                        Text("\(c.displayChord) · \(String(format: "%.2fs", c.overlapSeconds))")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.gray.opacity(0.2), lineWidth: 1))
                    }
                    Spacer()
                }
            }

            // Section controls
            Divider()
            HStack(spacing: 8) {
                if !isFirstBar {
                    Button("Start section here") {
                        sectionStore.startNewSection(at: sel.bar)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                }

                if let sec = currentSection {
                    Button("Rename section") {
                        renamingSection = sec
                        renameText = sec.name
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                }

                if !isFirst && isFirstBar {
                    Button("Merge with previous") {
                        sectionStore.mergeSectionWithPrevious(containing: sel.bar)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                }

                Spacer()
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.2), lineWidth: 1))
    }
}

private struct SectionHeaderView: View {
    let section: ChordSection
    let isRenaming: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(section.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.primary)
            Text("·")
                .foregroundColor(.secondary)
            Text("Bars \(section.startBar)–\(section.endBar)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

private struct RenameSheetView: View {
    @State private var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(sectionName: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _text = State(initialValue: sectionName)
        self.onSave   = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Section")
                .font(.headline)
            TextField("Section name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { if !text.trimmingCharacters(in: .whitespaces).isEmpty { onSave(text) } }
            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}

private struct ProgressionBarCell: View {
    let bar: ChordChartBarEntry
    let isSelected: Bool
    var isActive: Bool = false
    var subdivisions: Int = 4
    let onTap: (Double) -> Void  // seekTime = tapped chord's start

    // Meaningful chord segments paired with their beat-fraction.
    private var segments: [(entry: ChordChartChordEntry, fraction: Int)] {
        let barDuration = max(0.001, bar.end - bar.start)
        let minOverlap = max(0.05, barDuration / Double(subdivisions) * 0.5)
        let filtered = bar.chords
            .filter { $0.overlapSeconds >= minOverlap }
            .sorted { $0.start < $1.start }
        var deduped: [ChordChartChordEntry] = []
        for chord in filtered {
            if deduped.last?.displayChord != chord.displayChord { deduped.append(chord) }
        }
        if deduped.isEmpty {
            let label = bar.primaryChord ?? "N.C."
            let syn = ChordChartChordEntry(displayChord: label, start: bar.start,
                                           end: bar.end, overlapSeconds: bar.end - bar.start)
            deduped = [syn]
        }
        return Array(zip(deduped, allocateFractions(deduped)))
    }

    // Distribute `subdivisions` units across chords proportionally by overlapSeconds,
    // minimum 1 unit each, remainders filled by largest fractional surplus.
    private func allocateFractions(_ chords: [ChordChartChordEntry]) -> [Int] {
        guard chords.count > 1 else { return [subdivisions] }
        let total = chords.reduce(0.0) { $0 + $1.overlapSeconds }
        guard total > 0 else { return Array(repeating: 1, count: chords.count) }
        let raw = chords.map { ($0.overlapSeconds / total) * Double(subdivisions) }
        var bases = raw.map { max(1, Int($0)) }
        var used = bases.reduce(0, +)
        if used > subdivisions { return bases }
        let remainders = raw.enumerated()
            .map { (i: $0.offset, r: $0.element - Double(max(1, Int($0.element)))) }
            .sorted { $0.r > $1.r }
        var ri = 0
        while used < subdivisions {
            bases[remainders[ri % remainders.count].i] += 1
            used += 1
            ri += 1
        }
        return bases
    }

    var body: some View {
        GeometryReader { geo in
            let segs = segments
            let spacing: CGFloat = 3
            let gaps = spacing * CGFloat(max(0, segs.count - 1))
            let totalFr = CGFloat(max(1, segs.reduce(0) { $0 + $1.fraction }))
            let unitW = (geo.size.width - gaps) / totalFr
            HStack(spacing: spacing) {
                ForEach(Array(segs.enumerated()), id: \.offset) { idx, seg in
                    Button {
                        onTap(max(seg.entry.start, bar.start))
                    } label: {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isActive ? Color.green.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                            Text(seg.entry.displayChord)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .padding(.horizontal, 5)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if idx == 0 {
                                Text("\(bar.bar)")
                                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 6)
                                    .padding(.top, 5)
                            }
                        }
                        .frame(width: unitW * CGFloat(seg.fraction), height: geo.size.height)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58)
        .background(barBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(barBorder, lineWidth: isSelected ? 1.5 : 1)
        )
        .shadow(color: isSelected ? Color.accentColor.opacity(0.2) : .clear, radius: 5)
    }

    private var barBg: Color {
        if isSelected { return Color.accentColor.opacity(0.08) }
        if isActive   { return Color.green.opacity(0.07) }
        return Color(NSColor.controlBackgroundColor).opacity(0.5)
    }

    private var barBorder: Color {
        if isSelected { return .accentColor }
        if isActive   { return Color.green }
        return Color.gray.opacity(0.2)
    }
}

private struct ChordCell: View {
    let barNumber: Int
    let chord: String
    let isSelected: Bool
    var isActive: Bool = false
    var accentColor: Color = .accentColor
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text("\(barNumber)")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(labelColor)
                Text(chord)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(chordColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(bgColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: isActive ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var bgColor: Color {
        if isSelected { return accentColor }
        if isActive   { return Color.green.opacity(0.18) }
        return Color(NSColor.controlBackgroundColor)
    }

    private var borderColor: Color {
        if isSelected { return accentColor }
        if isActive   { return Color.green }
        return Color.gray.opacity(0.25)
    }

    private var labelColor: Color {
        isSelected ? Color.white.opacity(0.75) : .secondary
    }

    private var chordColor: Color {
        isSelected ? .white : .primary
    }
}

// MARK: - Performer progression view

private struct PerformerProgressionView: View {
    let preIntroBars: [PerformerChartBarEntry]
    let bars: [PerformerChartBarEntry]
    let currentTime: Double
    @Binding var selectedBar: PerformerChartBarEntry?
    let onSeek: (PerformerChartBarEntry) -> Void

    @State private var preIntroExpanded: Bool = false

    private var activeBar: PerformerChartBarEntry? {
        guard currentTime > 0 else { return nil }
        return bars.last(where: { $0.start <= currentTime })
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                if bars.isEmpty {
                    Text("No performer chart available yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    // Pre-intro disclosure group
                    if !preIntroBars.isEmpty {
                        DisclosureGroup(
                            isExpanded: $preIntroExpanded,
                            content: {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(stride(from: 0, to: preIntroBars.count, by: 4)), id: \.self) { rowStart in
                                        let rowEnd  = min(rowStart + 4, preIntroBars.count)
                                        let rowBars = Array(preIntroBars[rowStart..<rowEnd])
                                        HStack(spacing: 6) {
                                            ForEach(rowBars.indices, id: \.self) { idx in
                                                ChordCell(
                                                    barNumber: rowBars[idx].sourceBar,
                                                    chord: rowBars[idx].primaryChord ?? "N.C.",
                                                    isSelected: false,
                                                    isActive: false,
                                                    accentColor: .gray,
                                                    onTap: { onSeek(rowBars[idx]) }
                                                )
                                            }
                                            if rowBars.count < 4 {
                                                ForEach(0..<(4 - rowBars.count), id: \.self) { _ in
                                                    Color.clear.frame(maxWidth: .infinity)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            },
                            label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "music.note")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("Pre-intro")
                                        .font(.caption.weight(.medium))
                                        .foregroundColor(.secondary)
                                    Text("(\(preIntroBars.count) bar\(preIntroBars.count == 1 ? "" : "s"))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        )
                        .padding(6)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    // Main bars grid
                    ForEach(Array(stride(from: 0, to: bars.count, by: 4)), id: \.self) { rowStart in
                        let rowEnd  = min(rowStart + 4, bars.count)
                        let rowBars = Array(bars[rowStart..<rowEnd])
                        HStack(spacing: 6) {
                            ForEach(rowBars.indices, id: \.self) { idx in
                                let bar = rowBars[idx]
                                ChordCell(
                                    barNumber: bar.bar,
                                    chord: bar.primaryChord ?? "N.C.",
                                    isSelected: selectedBar?.bar == bar.bar,
                                    isActive: activeBar?.bar == bar.bar,
                                    accentColor: .accentColor,
                                    onTap: {
                                        selectedBar = (selectedBar?.bar == bar.bar) ? nil : bar
                                        onSeek(bar)
                                    }
                                )
                                .id(bar.bar)
                            }
                            if rowBars.count < 4 {
                                ForEach(0..<(4 - rowBars.count), id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }

                    // Selected bar detail strip
                    if let sel = selectedBar {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Bar \(sel.bar)").fontWeight(.semibold)
                                if sel.bar != sel.sourceBar {
                                    Text("(source bar \(sel.sourceBar))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(String(format: "%.3f \u{2013} %.3f s", sel.start, sel.end))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text("\(bars.count) bar\(bars.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.2))
            )
            .onChange(of: activeBar?.bar) {
                if let n = activeBar?.bar {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(n, anchor: .center)
                    }
                }
            }
        }
    }
}

