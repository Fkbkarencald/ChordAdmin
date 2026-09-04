import SwiftUI

// MARK: - Focused actions

/// What the menu bar can do to the song currently open.
///
/// The window publishes this through the focused-scene value, so the menu and
/// its keyboard shortcuts stay in step with what is actually selected without
/// the App and the view sharing mutable state.
struct SongActions {
    var title: String?
    var canAnalyse = false
    var canCancel = false
    var canExport = false
    var canPlay = false
    var isPlaying = false

    var analyse: () -> Void = {}
    var cancel: () -> Void = {}
    var export: () -> Void = {}
    var togglePlayback: () -> Void = {}
    var selectNext: () -> Void = {}
    var selectPrevious: () -> Void = {}
    var revealJobFolder: (() -> Void)?
    var focusSearch: () -> Void = {}
    var refreshLibrary: () -> Void = {}
    var recheckEnvironment: () -> Void = {}
}

private struct SongActionsKey: FocusedValueKey {
    typealias Value = SongActions
}

extension FocusedValues {
    var songActions: SongActions? {
        get { self[SongActionsKey.self] }
        set { self[SongActionsKey.self] = newValue }
    }
}

// MARK: - Text size

/// The reader's chosen text size, persisted across launches.
///
/// SwiftUI can scale type against `dynamicTypeSize`, but macOS has no system
/// control that sets it — so without this the app's scalable fonts would never
/// actually scale for anyone.
enum TextSizeSetting {
    static let storageKey = "textSize"

    /// The multipliers offered, smallest first. Applied by the app itself:
    /// macOS has no Dynamic Type, so `dynamicTypeSize` and `@ScaledMetric` are
    /// inert here — measured, they return the base value at every size.
    static let steps: [CGFloat] = [0.85, 0.92, 1.0, 1.12, 1.25, 1.4]
    static let defaultRawValue = 2   // 1.0 — the sizes the app is designed at

    static func scale(for rawValue: Int) -> CGFloat {
        steps.indices.contains(rawValue) ? steps[rawValue] : 1
    }

    /// What to call the current setting in the menu.
    static func label(for rawValue: Int) -> String {
        let percent = Int((scale(for: rawValue) * 100).rounded())
        return percent == 100 ? "Default" : "\(percent)%"
    }

    static func larger(than rawValue: Int) -> Int { min(rawValue + 1, steps.count - 1) }
    static func smaller(than rawValue: Int) -> Int { max(rawValue - 1, 0) }
}

// MARK: - Menu

/// Menu-bar commands. Everything here is also reachable in the window; the menu
/// exists so the shortcuts are discoverable rather than hidden, which is what
/// went wrong with the previous build's undocumented s/m/r keys.
struct ChordAdminCommands: Commands {
    @FocusedValue(\.songActions) private var actions
    @AppStorage(TextSizeSetting.storageKey) private var textSize = TextSizeSetting.defaultRawValue

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandMenu("Song") {
            Button(actions?.canCancel == true ? "Cancel Analysis" : "Analyse") {
                if actions?.canCancel == true { actions?.cancel() } else { actions?.analyse() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(actions?.canAnalyse ?? false) && !(actions?.canCancel ?? false))

            Button("Export to TheStageBee…") { actions?.export() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!(actions?.canExport ?? false))

            Divider()

            Button(actions?.isPlaying == true ? "Pause" : "Play") { actions?.togglePlayback() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!(actions?.canPlay ?? false))

            Divider()

            Button("Next Song") { actions?.selectNext() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Song") { actions?.selectPrevious() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Divider()

            Button("Reveal Job Folder in Finder") { actions?.revealJobFolder?() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(actions?.revealJobFolder == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find Song…") { actions?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }

        // macOS has no system-wide text-size control the way iOS does, so the
        // app has to offer its own — otherwise every scalable font in it is
        // scalable in theory only.
        CommandGroup(after: .toolbar) {
            Button("Larger Text") { textSize = TextSizeSetting.larger(than: textSize) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(textSize >= TextSizeSetting.steps.count - 1)
            Button("Smaller Text") { textSize = TextSizeSetting.smaller(than: textSize) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(textSize <= 0)
            Button("Default Text Size") { textSize = TextSizeSetting.defaultRawValue }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(textSize == TextSizeSetting.defaultRawValue)

            Divider()

            Button("Reload Library") { actions?.refreshLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Check Tools and Backend") { actions?.recheckEnvironment() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}
