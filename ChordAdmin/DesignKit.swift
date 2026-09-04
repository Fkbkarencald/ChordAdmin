import SwiftUI

// MARK: - Shared atoms
//
// Small pieces used across the sidebar, workspace, inspector and sheets so the
// window reads as one surface rather than a stack of differently-styled panels.

/// Uppercase group heading, e.g. "DETECTED CHORDS".
struct GroupLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .scaledFont(size: 10, weight: .semibold, relativeTo: .caption2)
            .kerning(0.6)
            .foregroundStyle(.secondary)
    }
}

/// A bordered container used for inspector groups and dashboard cards.
struct PanelCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Label / value line used throughout the inspector.
struct InfoRow: View {
    let label: String
    let value: String
    var valueIsMonospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .scaledFont(size: 11, relativeTo: .caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(valueIsMonospaced
                      ? .system(size: 11, design: .monospaced)
                      : .system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Scalable type

/// How much larger than normal the reader wants text. 1.0 is the default.
///
/// macOS has no Dynamic Type: `@ScaledMetric` and `dynamicTypeSize` compile and
/// do precisely nothing here — measured, at every size including the
/// accessibility ones, they return the base value unchanged. So the scaling has
/// to be applied by the app itself, which is what this carries.
private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var chordAdminTextScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

/// A system font that grows with the reader's text-size setting.
///
/// `Font.system(size:)` is fixed — there is no `relativeTo:` on it — so every
/// size in this app was frozen no matter what the reader asked for. `style`
/// decides how strongly a given size responds: small print grows proportionally
/// more than headings, which is what keeps the hierarchy from spreading apart.
private struct ScaledSystemFont: ViewModifier {
    @Environment(\.chordAdminTextScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let style: Font.TextStyle

    func body(content: Content) -> some View {
        content.font(.system(size: TextScale.scaled(size, style: style, by: scale),
                             weight: weight, design: design))
    }
}

/// How a point size responds to the reader's text-size setting.
nonisolated enum TextScale {
    /// Smaller styles take more of the increase, so raising the setting lifts
    /// the least legible text furthest without turning headings into billboards.
    /// The emphases are chosen to compress the hierarchy without inverting it —
    /// `Tools/.render-output/type-scale.png` is what that looks like.
    static func emphasis(for style: Font.TextStyle) -> CGFloat {
        // Tuned against the app's real ladder: at 1.25 emphasis the 10.5pt hint
        // caught up with the 11pt line above it and the two became one size, so
        // the boost is smaller than it first looks. Half a point of separation
        // is all that gap ever had.
        switch style {
        case .caption2: return 1.15
        case .caption:  return 1.10
        case .footnote: return 1.05
        default:        return 1
        }
    }

    static func scaled(_ size: CGFloat, style: Font.TextStyle, by scale: CGFloat) -> CGFloat {
        guard scale != 1 else { return size }
        let grown = size * (1 + (scale - 1) * emphasis(for: style))
        // Half-points keep the metrics tidy and the layout predictable.
        return (grown * 2).rounded() / 2
    }
}

extension View {
    /// Drop-in replacement for `.font(.system(size:weight:design:))` that scales.
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo style: Font.TextStyle = .body
    ) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design, style: style))
    }

    /// Sets the text scale for everything below.
    func chordAdminTextScale(_ scale: CGFloat) -> some View {
        environment(\.chordAdminTextScale, scale)
    }
}

/// A keyboard hint chip, e.g. the S / M / R shown next to section actions.
///
/// Hidden from VoiceOver: read aloud it turned "Split “Verse A” at this bar"
/// into a name ending in a stray "S". The button it sits beside carries the
/// shortcut as a hint instead.
struct KeyCap: View {
    let key: String

    var body: some View {
        cap.accessibilityHidden(true)
    }

    private var cap: some View {
        Text(key.uppercased())
            .scaledFont(size: 9, weight: .bold, design: .rounded, relativeTo: .caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
            )
    }
}

/// Status pill used in the toolbar and dashboard.
struct StatusPill: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .scaledFont(size: 10, weight: .semibold, relativeTo: .caption2)
                    .accessibilityHidden(true)
            }
            Text(text)
                .scaledFont(size: 11, weight: .medium, relativeTo: .caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }
}

/// The per-stage icon in the pipeline checklist.
struct StageStateIcon: View {
    let state: StageState

    var body: some View {
        icon.accessibilityLabel(Self.spokenName(for: state))
    }

    /// Done, failed and warning differ only by symbol and colour, so without
    /// this they are indistinguishable to VoiceOver — and to a red-green
    /// colour-blind reader whenever the stage produced no message.
    static func spokenName(for state: StageState) -> String {
        switch state {
        case .pending:            return "Not started"
        case .running:            return "In progress"
        case .done:               return "Done"
        case .warning:            return "Finished with a warning"
        case .skipped:            return "Skipped"
        case .failed:             return "Failed"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 13, height: 13)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

/// One row of the pipeline checklist: icon, title, elapsed time, and any
/// message the stage produced.
///
/// Read as one element: piecemeal, an eleven-stage checklist was thirty-odd
/// VoiceOver stops with each state detached from the stage it belonged to.
struct StageRow: View {
    let record: StageRecord
    var isCurrent: Bool = false

    var body: some View {
        rowBody.accessibilityElement(children: .combine)
    }

    private var rowBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                StageStateIcon(state: record.state)
                    .scaledFont(size: 12, relativeTo: .footnote)
                    .frame(width: 14)
                Text(record.stage.title)
                    .scaledFont(size: 12, weight: isCurrent ? .semibold : .regular, relativeTo: .footnote)
                    .foregroundStyle(isPending ? .secondary : .primary)
                Spacer(minLength: 6)
                if let elapsed = record.elapsedText {
                    Text(elapsed)
                        .scaledFont(size: 10, design: .monospaced, relativeTo: .caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let message = record.state.message {
                Text(message)
                    .scaledFont(size: 10.5, relativeTo: .caption2)
                    .foregroundStyle(messageColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
        }
    }

    private var isPending: Bool {
        if case .pending = record.state { return true }
        return false
    }

    private var messageColor: Color {
        switch record.state {
        case .failed:  return .red
        case .warning: return .orange
        default:       return .secondary
        }
    }
}

/// Centred placeholder for empty panes.
struct EmptyStateView: View {
    let title: String
    var message: String?
    var systemImage: String = "music.note.list"

    // The measure has to grow with the type, or larger text simply wraps to
    // more lines in the same column and reads worse than it did before.
    @Environment(\.chordAdminTextScale) private var textScale

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .scaledFont(size: 26, relativeTo: .title3)
                .foregroundStyle(.tertiary)
            Text(title)
                .scaledFont(size: 13, weight: .medium, relativeTo: .subheadline)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .scaledFont(size: 11, relativeTo: .caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320 * textScale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Square artwork for a song, falling back to a tinted note when there is no
/// YouTube thumbnail.
struct SongThumbnail: View {
    let url: URL?
    var size: CGFloat = 34
    var cornerRadius: CGFloat = 5

    var body: some View {
        artwork.accessibilityHidden(true)
    }

    private var artwork: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        placeholder.overlay(ProgressView().controlSize(.small).scaleEffect(0.5))
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.4))  // Deliberately fixed: sized to its own frame.
                .foregroundStyle(.secondary)
        }
    }
}
