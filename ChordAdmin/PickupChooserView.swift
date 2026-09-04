import SwiftUI

/// Lets the user *see* where bar 1 would start for each possible pickup, rather
/// than trying offsets one at a time and waiting for a chart rebuild to find out.
///
/// Each row draws the same opening seconds of audio with the bar lines that
/// offset would produce; the right one is the row whose lines sit on the accents.
struct PickupChooserView: View {
    let samples: [Float]
    let duration: Double
    /// Beat times from the detector, already adjusted for halved tempo.
    let beatTimes: [Double]
    let beatsPerBar: Int
    @Binding var selection: Int
    var onApply: () -> Void
    var onRevert: () -> Void
    var isDirty: Bool
    /// False when the tuning draft holds a BPM that cannot be used.
    var canApply: Bool = true

    /// How much of the track to show. Long enough to hear the phrase start,
    /// short enough that individual bar lines are distinguishable.
    /// Where the visible slice starts. Detection often reports its first beat
    /// some way in; starting at zero then pushed every bar line off the end.
    private var windowStart: Double { beatTimes.first ?? 0 }

    private var windowEnd: Double {
        guard beatTimes.count > beatsPerBar else {
            return min(windowStart + 20, max(duration, windowStart + 1))
        }
        // Roughly six bars, clamped so a very slow or very fast song still reads.
        let barLength = beatTimes[min(beatsPerBar, beatTimes.count - 1)] - beatTimes[0]
        let span = min(max(barLength * 6, 8), 40)
        return min(windowStart + span, max(duration, windowStart + 1))
    }

    private var window: Double { max(0.001, windowEnd - windowStart) }

    private var options: [Int] { Array(0..<max(1, beatsPerBar)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Where does bar 1 start?")
                        .scaledFont(size: 13, weight: .semibold, relativeTo: .subheadline)
                    Spacer(minLength: 8)
                    if isDirty {
                        Button("Revert", action: onRevert)
                            .controlSize(.small)
                        Button("Apply", action: onApply)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canApply)
                            .help(canApply
                                  ? "Rebuild the chart with this pickup"
                                  : "Fix the BPM override first")
                    }
                }
                // Its own line: competing with the buttons for one row truncated
                // it at ordinary window widths.
                Text("Bar lines over \(Int(window.rounded())) seconds of the opening. Pick the row whose lines land on the beat.")
                    .scaledFont(size: 10.5, relativeTo: .caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(options, id: \.self) { offset in
                // A Button, not a tap gesture: these rows were the only way to
                // choose a pickup by looking at the audio, and a keyboard or
                // VoiceOver user could not reach them at all.
                Button {
                    selection = offset
                } label: {
                    PickupRow(
                        offset: offset,
                        isSelected: offset == selection,
                        samples: samples,
                        duration: duration,
                        windowStart: windowStart,
                        window: window,
                        barLineTimes: barLineTimes(for: offset)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.optionLabel(offset))
                .accessibilityHint("Starts bar 1 after this many beats")
                .accessibilityAddTraits(offset == selection ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Spoken name for a pickup option, matching the row's own text.
    static func optionLabel(_ offset: Int) -> String {
        switch offset {
        case 0:  return "No pickup"
        case 1:  return "1 beat"
        default: return "\(offset) beats"
        }
    }

    /// The downbeats this offset would produce, within the visible window.
    private func barLineTimes(for offset: Int) -> [Double] {
        guard beatsPerBar > 0, beatTimes.count > offset else { return [] }
        return stride(from: offset, to: beatTimes.count, by: beatsPerBar)
            .map { beatTimes[$0] }
            .filter { $0 >= windowStart && $0 <= windowEnd }
    }
}

// MARK: - One candidate

private struct PickupRow: View {
    @Environment(\.chordAdminTextScale) private var textScale
    let offset: Int
    let isSelected: Bool
    let samples: [Float]
    let duration: Double
    let windowStart: Double
    let window: Double
    let barLineTimes: [Double]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .scaledFont(size: 13, relativeTo: .subheadline)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

            Text(PickupChooserView.optionLabel(offset))
                .scaledFont(size: 12, weight: isSelected ? .semibold : .regular, relativeTo: .footnote)
                .fixedSize()
                .frame(minWidth: 74 * textScale, alignment: .leading)

            Canvas { context, size in
                draw(context, size: size)
            }
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.07) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.10),
                        lineWidth: isSelected ? 1.5 : 1)
        )
    }

    private func draw(_ context: GraphicsContext, size: CGSize) {
        guard window > 0 else { return }

        // Only the visible slice of the whole-track sample array is drawn.
        let total = max(duration, 0.001)
        let first = min(samples.count - 1, max(0, Int(Double(samples.count) * (windowStart / total))))
        let count = max(1, Int(Double(samples.count) * (window / total)))
        let slice = samples.isEmpty ? [] : Array(samples[first..<min(samples.count, first + count)])

        if !slice.isEmpty {
            let columnWidth = size.width / CGFloat(slice.count)
            let midY = size.height / 2
            for (index, sample) in slice.enumerated() {
                let x = CGFloat(index) * columnWidth + columnWidth / 2
                let amplitude = max(0.5, CGFloat(sample) * midY * 0.85)
                var path = Path()
                path.move(to: CGPoint(x: x, y: midY - amplitude))
                path.addLine(to: CGPoint(x: x, y: midY + amplitude))
                context.stroke(
                    path,
                    with: .color(Color.accentColor.opacity(isSelected ? 0.45 : 0.28)),
                    lineWidth: max(0.7, columnWidth - 0.3)
                )
            }
        }

        for time in barLineTimes {
            let x = CGFloat((time - windowStart) / window) * size.width
            guard x <= size.width else { continue }
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                line,
                with: .color(isSelected ? Color.accentColor : Color.secondary.opacity(0.65)),
                lineWidth: isSelected ? 1.6 : 1.1
            )
        }
    }
}
