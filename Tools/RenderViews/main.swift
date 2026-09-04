import AppKit
import SwiftUI

// Renders the real ChordAdmin views offscreen against realistic job data, so
// layout and runtime behaviour can be inspected without Xcode.

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                    ? CommandLine.arguments[1]
                    : FileManager.default.currentDirectoryPath)
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// MARK: - Fixtures

let jobsRoot = LocalFileStore.baseDirectory
try? FileManager.default.createDirectory(at: jobsRoot, withIntermediateDirectories: true)

func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: .prettyPrinted)
}

/// A believable 84-bar song: C-Am-F-G cycling, with a couple of two-chord bars.
func makeBars(count: Int) -> [[String: Any]] {
    let names = ["C", "Am", "F", "G"]
    let barLength = 1.76
    return (1...count).map { bar in
        let start = Double(bar - 1) * barLength
        let end = start + barLength
        let primary = names[(bar - 1) % names.count]
        var chords: [[String: Any]] = [[
            "displayChord": primary, "start": start, "end": end, "overlapSeconds": barLength,
        ]]
        // Every eighth bar gets a second chord, to exercise segment widths.
        if bar % 8 == 0 {
            chords = [
                ["displayChord": primary, "start": start, "end": start + barLength * 0.75,
                 "overlapSeconds": barLength * 0.75],
                ["displayChord": primary + "/E", "start": start + barLength * 0.75, "end": end,
                 "overlapSeconds": barLength * 0.25],
            ]
        }
        return ["bar": bar, "sourceBar": bar, "start": start, "end": end,
                "primaryChord": primary, "chords": chords]
    }
}

let barCount = 84
let performerBars = makeBars(count: barCount)
let jobID = "render-job-1"
let songID = "song-golden-hour"
let folder = jobsRoot.appendingPathComponent(jobID, isDirectory: true)
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let performerPath = folder.appendingPathComponent("chord.chart.performer.json").path
try! json(["bars": performerBars, "bpm": 136.4, "timeSignature": "4/4"]).write(to: URL(fileURLWithPath: performerPath))

let cleanedPath = folder.appendingPathComponent("chord.cleaned.json").path
let cleaned = performerBars.flatMap { bar -> [[String: Any]] in
    (bar["chords"] as! [[String: Any]]).map { chord in
        ["start": chord["start"]!, "end": chord["end"]!,
         "rawChord": (chord["displayChord"] as! String) + ":maj",
         "displayChord": chord["displayChord"]!]
    }
}
try! json(["chords": cleaned]).write(to: URL(fileURLWithPath: cleanedPath))

// Sections: Intro, Verse A, Chorus, Verse B, Chorus, Bridge, Outro.
let sectionSpec: [(String, Int, Int)] = [
    ("Intro", 1, 4), ("Verse A", 5, 20), ("Chorus", 21, 36), ("Verse B", 37, 52),
    ("Chorus", 53, 68), ("Bridge", 69, 76), ("Outro", 77, 84),
]
let sectionsPath = folder.appendingPathComponent("sections.json").path
try! json([
    "source": ["chordChartPerformerPath": performerPath],
    "sections": sectionSpec.enumerated().map { index, spec in
        ["id": "section-\(index + 1)", "name": spec.0, "startBar": spec.1, "endBar": spec.2,
         "bars": Array(spec.1...spec.2)]
    },
]).write(to: URL(fileURLWithPath: sectionsPath))

// A job mid-way through: health warned, chords failed, so the checklist shows
// every kind of stage state at once.
var job = AnalysisJob(
    id: jobID, sourceUrl: "https://youtu.be/goldenhour", status: .completedWithWarnings,
    createdAt: Date().addingTimeInterval(-7200), title: "Golden Hour",
    songDocumentID: songID, songVideoID: "goldenhour"
)
job.analysisWavPath = folder.appendingPathComponent("analysis.wav").path
FileManager.default.createFile(atPath: job.analysisWavPath!, contents: Data([0x52, 0x49, 0x46, 0x46]))
job.chordChartPerformerPath = performerPath
job.chordChartDraftPath = performerPath
job.chordCleanedPath = cleanedPath
job.sectionsPath = sectionsPath
job.bpm = 136.4
job.beatCount = 336
job.barCount = barCount
job.chordChartBarCount = barCount
job.chordCount = 96
job.sectionCount = sectionSpec.count
job.estimatedTimeSignature = "4/4"
job.durationSeconds = 148.4
job.sampleRate = 44100
job.channels = 1
job.codecName = "pcm_s16le"
job.bitRate = 705600
job.fileSizeBytes = 26_312_400
job.meanVolumeDb = -38.2
job.maxVolumeDb = -0.3
job.silenceRegionCount = 3
job.totalSilenceDurationSeconds = 4.2
job.barAlignmentOffset = 2
job.requestedBeatModel = "auto"
job.resolvedBeatModel = "madmom"
job.chordModel = "chord-cnn-lstm"
job.analysisBackendAvailable = true
job.subdivisionsByBar = [14: 2]
job.lastEditedAt = Date().addingTimeInterval(-300)
job.lastExport = ExportRecord(
    exportedAt: Date().addingTimeInterval(-3600), documentID: songID, songTitle: "Golden Hour",
    tempo: 132, sectionCount: 3, previousTempo: 128, previousSectionCount: 3
)

var report = StageReport()
report.set(.tools, .done, elapsed: 0.2)
report.set(.download, .done, elapsed: 12)
report.set(.convert, .done, elapsed: 3)
report.set(.metadata, .done, elapsed: 0.4)
report.set(.health, .warning("Very quiet audio (-38 dB mean) — chords may be less reliable"), elapsed: 0.9)
report.set(.backend, .done, elapsed: 0.1)
report.set(.beats, .done, elapsed: 42)
report.set(.beatGrid, .done, elapsed: 0.3)
report.set(.chords, .failed("Backend error 500: chord model failed to load"), elapsed: 8)
report.set(.chart, .skipped("Needs recognised chords"))
report.set(.sections, .skipped("Needs a chart"))
job.stageReport = report
try! LocalFileStore.saveJob(job, to: folder)

// Songs, decoded so the property wrapper on `id` is exercised the real way.
func song(_ id: String, _ title: String, _ artist: String, link: String?, tempo: Int?) -> FirebaseSong {
    var dict: [String: Any] = ["id": id, "title": title, "tempo": tempo as Any,
                               "artists": [["name": artist]]]
    if let link { dict["link"] = link }
    return try! JSONDecoder().decode(FirebaseSong.self, from: json(dict))
}

let songs: [FirebaseSong] = [
    song(songID, "Golden Hour", "Mara Quinn", link: "https://youtu.be/goldenhour", tempo: 132),
    song("song-2", "Paper Lanterns", "The Hollow Suns", link: "https://youtu.be/paper", tempo: 118),
    song("song-3", "Undertow", "Vale", link: "https://youtu.be/undertow", tempo: 96),
    song("song-4", "Midnight Parade", "Junie West", link: "https://youtu.be/midnight", tempo: nil),
    song("song-5", "Wintering", "Aya Rowe", link: "https://youtu.be/winter", tempo: nil),
    song("song-6", "Meridian", "No Link Band", link: nil, tempo: nil),
    song("song-7", "Second Story", "The Hollow Suns", link: "https://youtu.be/second", tempo: nil),
]

// MARK: - Live stores

let jobManager = JobManager()
let sectionStore = SectionStore()
let environment = EnvironmentStore()
let authStore = AuthStore()
let audioPlayer = ChordAudioPlayer()
let waveformLoader = WaveformLoader()

await jobManager.hydrate()
sectionStore.load(for: job, jobFolder: folder)
await environment.refresh()

let hydrated = jobManager.job(for: songID)
print("hydrate: job for song = \(hydrated?.title ?? "nil"), stages = \(hydrated?.stageReport.records.count ?? 0)")
print("sections loaded: \(sectionStore.sections.count) — \(sectionStore.sections.map(\.name).joined(separator: ", "))")

let items = Library.items(songs: songs, jobManager: jobManager)
print("library states: " + items.map { "\($0.title)=\($0.state.label)" }.joined(separator: " | "))

let bars = JobManager.loadBars(atPath: performerPath)
let rawChords = JobManager.loadRawChords(atPath: cleanedPath)
print("bars loaded: \(bars.count), raw chords: \(rawChords.count)")

// MARK: - Rendering

// ImageRenderer does not lay out ScrollView or List content, so host each view
// in a real (never-shown) AppKit window and capture that instead.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let appearances: [(String, NSAppearance.Name)] = [("", .aqua), ("-dark", .darkAqua)]

/// Renders every view at this text scale instead of the default. Set
/// `CHORDADMIN_RENDER_SCALE=1.4` to sweep the whole app at the largest text
/// size and look for anything that clips — which is how the sidebar's truncated
/// empty state was found.
let renderScale: CGFloat = {
    guard let raw = ProcessInfo.processInfo.environment["CHORDADMIN_RENDER_SCALE"],
          let value = Double(raw) else { return 1 }
    return CGFloat(value)
}()

@MainActor
func render<V: View>(_ name: String, size: CGSize, @ViewBuilder _ view: () -> V) {
    for (suffix, appearanceName) in appearances {
        renderOnce(name + suffix, size: size, appearance: appearanceName, view)
    }
}

@MainActor
func renderOnce<V: View>(
    _ name: String,
    size: CGSize,
    appearance appearanceName: NSAppearance.Name,
    @ViewBuilder _ view: () -> V
) {
    let hosting = NSHostingView(rootView: AnyView(
        view()
            .chordAdminTextScale(renderScale)
            .background(Color(nsColor: .windowBackgroundColor))
    ))
    hosting.frame = CGRect(origin: .zero, size: size)
    hosting.appearance = NSAppearance(named: appearanceName)

    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.appearance = NSAppearance(named: appearanceName)
    window.contentView = hosting
    window.isReleasedWhenClosed = false
    hosting.layoutSubtreeIfNeeded()

    // Let SwiftUI settle (async layout, image placeholders, materials).
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    hosting.layoutSubtreeIfNeeded()

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        print("RENDER FAILED (no bitmap): \(name)")
        return
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("RENDER FAILED (no png): \(name)")
        return
    }
    try? png.write(to: outputDir.appendingPathComponent("\(name).png"))

    // Crude blank-page detector: a view that laid out to nothing is a bug worth
    // knowing about, not a picture worth looking at.
    let nonBlank = rep.pixelsWide > 0 && {
        var distinct = Set<UInt32>()
        for y in stride(from: 4, to: rep.pixelsHigh, by: 17) {
            for x in stride(from: 4, to: rep.pixelsWide, by: 17) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let packed = (UInt32(colour.redComponent * 255) << 16)
                    | (UInt32(colour.greenComponent * 255) << 8)
                    | UInt32(colour.blueComponent * 255)
                distinct.insert(packed)
                if distinct.count > 3 { return true }
            }
        }
        return false
    }()
    print("rendered \(name).png  \(Int(size.width))×\(Int(size.height))\(nonBlank ? "" : "   ⚠️ LOOKS BLANK")")
    window.contentView = nil
}

var filter: LibraryFilter = .all
var search = ""
var selection: String? = songID
var selectedBar: Int? = 14
var tuning = TuningDraft.from(job: job)
var inspectorTab: InspectorTab = .bar
var waveZoom: CGFloat = 1
var follow = true

func binding<T>(_ value: @escaping @autoclosure () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
    Binding(get: value, set: set)
}

render("sidebar", size: CGSize(width: 264, height: 700)) {
    LibrarySidebar(
        items: items, counts: Library.counts(for: items),
        filter: binding(filter, { filter = $0 }),
        searchText: binding(search, { search = $0 }),
        selection: binding(selection, { selection = $0 }),
        isLoading: false, environment: environment, authStore: authStore,
        queue: [SongRef(documentID: "song-2", title: "Paper Lanterns",
                        artist: "The Hollow Suns", url: "https://youtu.be/paper"),
                SongRef(documentID: "song-3", title: "Undertow",
                        artist: "Vale", url: "https://youtu.be/undertow")],
        onSignIn: {}, onSignOut: {}, onRecheckEnvironment: {}
    )
}

render("sidebar-noselection", size: CGSize(width: 264, height: 400)) {
    LibrarySidebar(
        items: items, counts: Library.counts(for: items),
        filter: binding(filter, { filter = $0 }),
        searchText: binding(search, { search = $0 }),
        selection: binding(nil as String?, { _ in }),
        isLoading: false, environment: environment, authStore: authStore,
        queue: [], onSignIn: {}, onSignOut: {}, onRecheckEnvironment: {}
    )
}

render("front-screen", size: CGSize(width: 880, height: 760)) {
    FrontScreenView(
        items: items, isLoading: false, environment: environment, authStore: authStore,
        queue: [], onOpen: { _ in }, onAnalyse: { _ in }, onResume: { _ in }, onAnalyseAll: { _ in },
        onExport: { _ in }, onRecheckEnvironment: {}, onReloadLibrary: {}, onSignIn: {}
    )
}

// Narrow, to prove the dashboard stacks instead of clipping.
render("front-screen-narrow", size: CGSize(width: 520, height: 760)) {
    FrontScreenView(
        items: items, isLoading: false, environment: environment, authStore: authStore,
        queue: [], onOpen: { _ in }, onAnalyse: { _ in }, onResume: { _ in }, onAnalyseAll: { _ in },
        onExport: { _ in }, onRecheckEnvironment: {}, onReloadLibrary: {}, onSignIn: {}
    )
}

render("chart", size: CGSize(width: 620, height: 560)) {
    ChordChartView(
        bars: bars, sectionStore: sectionStore, subdivisions: job.subdivisionsByBar,
        selectedBar: binding(selectedBar, { selectedBar = $0 }),
        activeBar: 10, followPlayhead: false, isPreviewing: false, changedBars: [],
        onSeek: { _ in }, onSubdivisionChange: { _, _ in },
        onSplit: { _ in }, onMerge: { _ in }, onRename: { _ in }
    )
}

// The narrow case that used to clip the action bar off-screen.
render("chart-narrow", size: CGSize(width: 470, height: 400)) {
    ChordChartView(
        bars: Array(bars.prefix(12)), sectionStore: sectionStore, subdivisions: [:],
        selectedBar: binding(selectedBar, { selectedBar = $0 }),
        activeBar: 10, followPlayhead: false, isPreviewing: false, changedBars: [],
        onSeek: { _ in }, onSubdivisionChange: { _, _ in },
        onSplit: { _ in }, onMerge: { _ in }, onRename: { _ in }
    )
}

render("waveform", size: CGSize(width: 760, height: 132)) {
    WaveformView(
        samples: (0..<600).map { Float(abs(sin(Double($0) / 14)) * 0.8) },
        duration: 148.4, currentTime: 15.8, bars: bars,
        sections: sectionStore.sections, rawChords: rawChords, onSeek: { _ in }
    )
}

let item = items.first { $0.id == songID }!

for tab in InspectorTab.allCases {
    inspectorTab = tab
    render("inspector-\(tab.rawValue)", size: CGSize(width: 300, height: tab == .info ? 1500 : 720)) {
        InspectorView(
            tab: binding(inspectorTab, { inspectorTab = $0 }),
            item: item, job: hydrated ?? job, bars: bars,
            selectedBar: binding(selectedBar, { selectedBar = $0 }),
            tuning: binding(tuning, { tuning = $0 }),
            sectionStore: sectionStore, jobManager: jobManager, environment: environment,
            isSignedIn: false,
            onApplyTuning: {}, onRevertTuning: {}, onSubdivisionChange: { _, _ in },
            onSplit: { _ in }, onMerge: { _ in }, onRename: { _ in },
            onRetryStage: { _ in }, onCancelRun: {}, onResume: {}, onRedetectBeats: { _, _, _ in }
        )
    }
}

render("workspace", size: CGSize(width: 760, height: 700)) {
    SongWorkspaceView(
        item: item, job: hydrated ?? job, bars: bars, rawChords: rawChords,
        changedBars: [], isPreviewing: false,
        jobManager: jobManager, sectionStore: sectionStore,
        audioPlayer: audioPlayer, waveformLoader: waveformLoader,
        selectedBar: binding(selectedBar, { selectedBar = $0 }),
        waveZoom: binding(waveZoom, { waveZoom = $0 }),
        followPlayhead: binding(follow, { follow = $0 }),
        onStartAnalysis: {}, onReanalyse: {}, onCancelRun: {}, onSubdivisionChange: { _, _ in },
        onSplit: { _ in }, onMerge: { _ in }, onRename: { _ in }, onShowStages: {}, onDismissNotice: {}
    )
}

// The pickup chooser: four candidate bar-line grids over the opening seconds.
// Synthetic beats at 136.4 BPM so the lines are evenly spaced and comparable.
let previewBeats: [Double] = (0..<80).map { 0.31 + Double($0) * (60.0 / 136.4) }
var pickupOffset = 2

render("pickup-chooser", size: CGSize(width: 720, height: 260)) {
    PickupChooserView(
        samples: (0..<2000).map { Float(abs(sin(Double($0) / 9)) * 0.75) },
        duration: 148.4,
        beatTimes: previewBeats,
        beatsPerBar: 4,
        selection: binding(pickupOffset, { pickupOffset = $0 }),
        onApply: {}, onRevert: {}, isDirty: true
    )
}

// The workspace with the pickup chooser open, to check it does not squeeze the
// chart out of the pane.
render("workspace-tuning", size: CGSize(width: 820, height: 720)) {
    SongWorkspaceView(
        item: item, job: hydrated ?? job, bars: bars, rawChords: rawChords,
        changedBars: [6, 8], isPreviewing: true,
        jobManager: jobManager, sectionStore: sectionStore,
        audioPlayer: audioPlayer, waveformLoader: waveformLoader,
        selectedBar: binding(selectedBar, { selectedBar = $0 }),
        waveZoom: binding(waveZoom, { waveZoom = $0 }),
        followPlayhead: binding(follow, { follow = $0 }),
        onStartAnalysis: {}, onReanalyse: {}, onCancelRun: {}, onSubdivisionChange: { _, _ in },
        onSplit: { _ in }, onMerge: { _ in }, onRename: { _ in }, onShowStages: {}, onDismissNotice: {},
        pickup: PickupChoice(
            beatTimes: previewBeats, beatsPerBar: 4,
            offset: binding(pickupOffset, { pickupOffset = $0 }),
            isDirty: true, canApply: true, onApply: {}, onRevert: {}
        )
    )
}

// A running job: skeleton chart, stage strip and cancel.
var runningJob = job
runningJob.status = .downloading
var runningReport = StageReport()
runningReport.set(.tools, .done, elapsed: 0.2)
runningReport.set(.download, .running)
runningJob.stageReport = runningReport
runningJob.chordChartPerformerPath = nil
runningJob.chordChartDraftPath = nil

render("workspace-running", size: CGSize(width: 760, height: 560)) {
    SongWorkspaceView(
        item: item, job: runningJob, bars: [], rawChords: [],
        changedBars: [], isPreviewing: false,
        jobManager: jobManager, sectionStore: sectionStore,
        audioPlayer: audioPlayer, waveformLoader: waveformLoader,
        selectedBar: binding(nil as Int?, { _ in }),
        waveZoom: binding(waveZoom, { waveZoom = $0 }),
        followPlayhead: binding(follow, { follow = $0 }),
        onStartAnalysis: {}, onReanalyse: {}, onCancelRun: {}, onSubdivisionChange: { _, _ in },
        onSplit: { _ in }, onMerge: { _ in }, onRename: { _ in }, onShowStages: {}, onDismissNotice: {}
    )
}

// A song that has never been analysed.
let freshItem = LibraryItem(song: songs[1], job: nil, state: .new)
render("workspace-fresh", size: CGSize(width: 760, height: 420)) {
    SongWorkspaceView(
        item: freshItem, job: nil, bars: [], rawChords: [],
        changedBars: [], isPreviewing: false,
        jobManager: jobManager, sectionStore: sectionStore,
        audioPlayer: audioPlayer, waveformLoader: waveformLoader,
        selectedBar: binding(nil as Int?, { _ in }),
        waveZoom: binding(waveZoom, { waveZoom = $0 }),
        followPlayhead: binding(follow, { follow = $0 }),
        onStartAnalysis: {}, onReanalyse: {}, onCancelRun: {}, onSubdivisionChange: { _, _ in },
        onSplit: { _ in }, onMerge: { _ in }, onRename: { _ in }, onShowStages: {}, onDismissNotice: {}
    )
}

// A rolled-back re-analysis explaining itself, above the chart it restored.
render("workspace-notice", size: CGSize(width: 760, height: 420)) {
    var restored = job
    restored.notice = "Re-analysis cancelled — the previous chart was kept."
    return SongWorkspaceView(
        item: item, job: restored, bars: Array(bars.prefix(8)), rawChords: [],
        changedBars: [], isPreviewing: false,
        jobManager: jobManager, sectionStore: sectionStore,
        audioPlayer: audioPlayer, waveformLoader: waveformLoader,
        selectedBar: binding(nil as Int?, { _ in }),
        waveZoom: binding(waveZoom, { waveZoom = $0 }),
        followPlayhead: binding(follow, { follow = $0 }),
        onStartAnalysis: {}, onReanalyse: {}, onCancelRun: {}, onSubdivisionChange: { _, _ in },
        onSplit: { _ in }, onMerge: { _ in }, onRename: { _ in }, onShowStages: {}, onDismissNotice: {}
    )
}

// The same chart at the largest text size. Every font in the app is now scaled
// rather than fixed, so this is the proof it grows instead of clipping.
render("chart-large-text", size: CGSize(width: 620, height: 420)) {
    ChordChartView(
        bars: Array(bars.prefix(8)), sectionStore: sectionStore, subdivisions: [:],
        selectedBar: binding(nil as Int?, { _ in }),
        activeBar: nil, followPlayhead: false, isPreviewing: false, changedBars: [],
        onSeek: { _ in }, onSubdivisionChange: { _, _ in },
        onSplit: { _ in }, onMerge: { _ in }, onRename: { _ in }
    )
    .chordAdminTextScale(TextSizeSetting.scale(for: TextSizeSetting.steps.count - 1))
}

// The join itself: ContentView reads the stored setting through @AppStorage and
// applies it. Rendering the real ContentView at two settings is what proves the
// one line wiring the menu to the fonts actually does something — everything
// else only tested the halves either side of it.
for (label, step) in [("contentview-scale-small", 0), ("contentview-scale-large", 5)] {
    UserDefaults.standard.set(step, forKey: TextSizeSetting.storageKey)
    render(label, size: CGSize(width: 900, height: 520)) {
        ContentView()
    }
}
UserDefaults.standard.removeObject(forKey: TextSizeSetting.storageKey)

// The type scale at every offered size. Small print grows proportionally more
// than headings, so the check is that the hierarchy holds rather than spreading.
render("type-scale", size: CGSize(width: 900, height: 320)) {
    HStack(alignment: .top, spacing: 18) {
        ForEach(Array(TextSizeSetting.steps.indices), id: \.self) { index in
            VStack(alignment: .leading, spacing: 5) {
                Text(TextSizeSetting.label(for: index))
                    .scaledFont(size: 9, weight: .bold, design: .monospaced, relativeTo: .caption2)
                    .foregroundStyle(.tertiary)
                Text("Chorus")
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .subheadline)
                Text("Bars 21–36")
                    .scaledFont(size: 11, relativeTo: .caption)
                    .foregroundStyle(.secondary)
                Text("Am")
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .body)
                Text("136 BPM")
                    .scaledFont(size: 12, relativeTo: .footnote)
                Text("preview only")
                    .scaledFont(size: 10.5, relativeTo: .caption2)
                    .foregroundStyle(.tertiary)
            }
            .chordAdminTextScale(TextSizeSetting.scale(for: index))
            .frame(width: 130, alignment: .leading)
        }
    }
    .padding(14)
}

// The tuning preview: banner plus dashed "changed" bars.
render("chart-previewing", size: CGSize(width: 620, height: 380)) {
    ChordChartView(
        bars: Array(bars.prefix(12)), sectionStore: sectionStore, subdivisions: [:],
        selectedBar: binding(nil as Int?, { _ in }),
        activeBar: nil, followPlayhead: false, isPreviewing: true, changedBars: [6, 8, 11],
        onSeek: { _ in }, onSubdivisionChange: { _, _ in },
        onSplit: { _ in }, onMerge: { _ in }, onRename: { _ in }
    )
}

// An empty library.
render("front-screen-empty", size: CGSize(width: 700, height: 380)) {
    FrontScreenView(
        items: [], isLoading: false, environment: environment, authStore: authStore,
        queue: [], onOpen: { _ in }, onAnalyse: { _ in }, onResume: { _ in }, onAnalyseAll: { _ in },
        onExport: { _ in }, onRecheckEnvironment: {}, onReloadLibrary: {}, onSignIn: {}
    )
}

// A library that failed to load, which must not read as an empty one.
render("front-screen-library-error", size: CGSize(width: 700, height: 380)) {
    FrontScreenView(
        items: [], isLoading: false,
        libraryError: "Missing or insufficient permissions.",
        environment: environment, authStore: authStore,
        queue: [], onOpen: { _ in }, onAnalyse: { _ in }, onResume: { _ in }, onAnalyseAll: { _ in },
        onExport: { _ in }, onRecheckEnvironment: {}, onReloadLibrary: {}, onSignIn: {}
    )
}

let exportPreview = ExportPreview(
    songID: songID,
        jobID: "render-job", songTitle: "Golden Hour", artist: "Mara Quinn", documentID: "9fKzR2vXqLmNp",
    currentTempo: 132, newTempo: 136,
    currentSectionNames: ["Intro", "Verse", "Chorus"],
    newSections: sectionSpec.enumerated().map { index, spec in
        ExportPreviewSection(index: index, name: spec.0, barCount: spec.2 - spec.1 + 1)
    },
    sectionsPayload: [], tempoPayload: 136
)

render("export-sheet", size: CGSize(width: 560, height: 520)) {
    ExportSheet(preview: exportPreview, isExporting: false, errorMessage: nil,
                onCancel: {}, onConfirm: {})
}

render("export-sheet-error", size: CGSize(width: 560, height: 560)) {
    ExportSheet(preview: exportPreview, isExporting: false,
                errorMessage: "Firestore error: Missing or insufficient permissions.",
                onCancel: {}, onConfirm: {})
}

print("done")
