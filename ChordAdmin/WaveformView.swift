import SwiftUI

// MARK: - Section colours

/// Stable colours for section bands and chart headers, so the same section
/// reads the same way in the waveform, the chart and the export sheet.
enum SectionPalette {
    private static let colors: [Color] = [
        Color(red: 0.04, green: 0.42, blue: 0.96),   // blue
        Color(red: 0.62, green: 0.31, blue: 0.84),   // purple
        Color(red: 0.96, green: 0.58, blue: 0.00),   // amber
        Color(red: 0.13, green: 0.66, blue: 0.45),   // green
        Color(red: 0.85, green: 0.30, blue: 0.45),   // rose
        Color(red: 0.20, green: 0.60, blue: 0.72),   // teal
    ]

    /// Intro/outro-style bookends stay neutral so the coloured bands read as
    /// the song's actual repeating material.
    private static func isNeutral(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("intro") || lowered.contains("outro") || lowered.contains("ending")
    }

    /// Assigns colours by order of first appearance across `names`, so repeats of
    /// a section share a colour but two different sections never collide — which
    /// a name hash could not guarantee (Verse A and Chorus hashed to the same hue).
    static func color(forSectionNamed name: String, among names: [String]) -> Color {
        guard !isNeutral(name) else { return .secondary }
        var order: [String] = []
        for candidate in names where !isNeutral(candidate) {
            if !order.contains(candidate) { order.append(candidate) }
        }
        let index = order.firstIndex(of: name) ?? 0
        return colors[index % colors.count]
    }

    /// Convenience for callers that already hold the sections.
    static func color(for section: ChordSection, in sections: [ChordSection]) -> Color {
        color(forSectionNamed: section.name, among: sections.map(\.name))
    }

    /// Kept for callers with only a name and a position.
    static func color(forSectionNamed name: String, fallbackIndex: Int) -> Color {
        guard !isNeutral(name) else { return .secondary }
        return colors[fallbackIndex % colors.count]
    }
}

// MARK: - Waveform

/// The audio overview: section band, bar grid, waveform, detected-chord lane
/// and playhead. Click or drag anywhere to scrub.
struct WaveformView: View {
    let samples: [Float]
    let duration: Double
    let currentTime: Double
    let bars: [ChordChartBarEntry]
    var sections: [ChordSection] = []
    var rawChords: [CleanedChord] = []
    let onSeek: (Double) -> Void

    /// Spoken position: where the playhead is, and what is happening there.
    private var accessibilityValue: String {
        guard duration > 0 else { return "No audio loaded" }
        var parts = ["\(Format.time(currentTime, showTenths: false)) of \(Format.time(duration, showTenths: false))"]
        if let bar = bars.last(where: { $0.start <= currentTime }) {
            parts.append("bar \(bar.bar)")
            if let section = sections.first(where: { $0.bars.contains(bar.bar) }) {
                parts.append(section.name)
            }
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // The waveform, grid and chord lane do not move while audio
                // plays, but the playhead updates twenty times a second. Keeping
                // them in an equatable subview stops thousands of strokes being
                // re-drawn on every tick.
                EquatableView(content: WaveformLayers(
                    samples: samples,
                    duration: duration,
                    bars: bars,
                    sections: sections,
                    rawChords: rawChords
                ))

                Canvas { context, size in
                    WaveformGeometry.drawPlayhead(context, size: size,
                                                  currentTime: currentTime, duration: duration)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, geo.size.width > 0 else { return }
                        let time = Double(value.location.x / geo.size.width) * duration
                        onSeek(max(0, min(time, duration)))
                    }
            )
            // Everything here is drawn into a Canvas, so without this the whole
            // overview — sections, bar grid, chords, playhead — was absent from
            // the accessibility tree, and scrubbing was drag-only.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Audio overview")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Adjust to move the playhead")
            .accessibilityAdjustableAction { direction in
                guard duration > 0 else { return }
                // A bar at a time where there is a chart, otherwise five seconds.
                let step = bars.first.map { max(0.25, $0.end - $0.start) } ?? 5
                let target = currentTime + (direction == .increment ? step : -step)
                onSeek(max(0, min(target, duration)))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Static layers

/// Everything in the waveform that does not depend on the playhead.
private struct WaveformLayers: View, Equatable {
    let samples: [Float]
    let duration: Double
    let bars: [ChordChartBarEntry]
    let sections: [ChordSection]
    let rawChords: [CleanedChord]

    private let sectionBandHeight: CGFloat = WaveformGeometry.sectionBandHeight
    private let chordLaneFraction: CGFloat = WaveformGeometry.chordLaneFraction

    // Canvas labels are Font values on a Text, not view modifiers, so they
    // cannot use `.scaledFont`. Scaling the point size here gets them there.
    @ScaledMetric(relativeTo: .caption2) private var sectionLabelSize: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var barLabelSize: CGFloat = 8.5

    /// Compared on the things that change what is drawn. The arrays are large,
    /// so identity is taken from their shape rather than their contents.
    static func == (lhs: WaveformLayers, rhs: WaveformLayers) -> Bool {
        // Text size is part of what is drawn, so a change to it has to redraw.
        lhs.sectionLabelSize == rhs.sectionLabelSize
            && lhs.barLabelSize == rhs.barLabelSize
            && lhs.duration == rhs.duration
            && lhs.samples.count == rhs.samples.count
            && lhs.bars.count == rhs.bars.count
            && lhs.rawChords.count == rhs.rawChords.count
            && lhs.bars.first?.start == rhs.bars.first?.start
            && lhs.bars.last?.end == rhs.bars.last?.end
            && lhs.sections.map(\.id) == rhs.sections.map(\.id)
            && lhs.sections.map(\.name) == rhs.sections.map(\.name)
            && lhs.sections.map(\.bars) == rhs.sections.map(\.bars)
    }

    var body: some View {
        Canvas { context, size in
            let chordLaneHeight = size.height * chordLaneFraction
            let waveTop = sectionBandHeight
            let waveBottom = size.height - chordLaneHeight
            let waveHeight = max(1, waveBottom - waveTop)

            drawSectionBand(context, size: size)
            drawBarGrid(context, size: size, top: waveTop, bottom: waveBottom)
            drawWaveform(context, size: size, top: waveTop, height: waveHeight)
            drawChordLane(context, size: size, top: waveBottom, height: chordLaneHeight)
        }
    }

    // MARK: Layers

    private func drawSectionBand(_ context: GraphicsContext, size: CGSize) {
        guard !sections.isEmpty, !bars.isEmpty else { return }
        let barByNumber = Dictionary(bars.map { ($0.bar, $0) }, uniquingKeysWith: { first, _ in first })

        for section in sections {
            guard let first = section.bars.min().flatMap({ barByNumber[$0] }),
                  let last = section.bars.max().flatMap({ barByNumber[$0] }) else { continue }
            let x1 = xPos(first.start, width: size.width)
            let x2 = xPos(last.end, width: size.width)
            let width = max(1, x2 - x1)
            let color = SectionPalette.color(for: section, in: sections)

            context.fill(
                Path(roundedRect: CGRect(x: x1, y: 0, width: max(1, width - 1), height: sectionBandHeight),
                     cornerRadius: 2),
                with: .color(color.opacity(0.85))
            )
            guard width > 34 else { continue }
            let label = context.resolve(
                Text(section.name)
                    .font(.system(size: sectionLabelSize, weight: .semibold))
                    .foregroundStyle(Color.white)
            )
            context.draw(label, at: CGPoint(x: x1 + 5, y: sectionBandHeight / 2), anchor: .leading)
        }
    }

    private func drawBarGrid(_ context: GraphicsContext, size: CGSize, top: CGFloat, bottom: CGFloat) {
        guard !bars.isEmpty else { return }
        // Keep the grid readable: draw at most ~120 lines regardless of length.
        let stride = max(1, Int((Double(bars.count) / 120).rounded(.up)) * 4)
        for (index, bar) in bars.enumerated() where index % stride == 0 {
            let x = xPos(bar.start, width: size.width)
            let isStrong = index % (stride * 4) == 0
            var path = Path()
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x, y: bottom))
            context.stroke(
                path,
                with: .color(Color.secondary.opacity(isStrong ? 0.22 : 0.10)),
                lineWidth: 1
            )
            guard isStrong, x < size.width - 18 else { continue }
            let label = context.resolve(
                Text("\(bar.bar)")
                    .font(.system(size: barLabelSize, design: .monospaced))
                    .foregroundStyle(Color.secondary)
            )
            context.draw(label, at: CGPoint(x: x + 3, y: top + 3), anchor: .topLeading)
        }
    }

    private func drawWaveform(_ context: GraphicsContext, size: CGSize, top: CGFloat, height: CGFloat) {
        let midY = top + height / 2
        guard !samples.isEmpty else {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: midY))
            line.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(line, with: .color(Color.secondary.opacity(0.3)), lineWidth: 1)
            return
        }

        let columnWidth = size.width / CGFloat(samples.count)
        let lineWidth = max(0.8, columnWidth - 0.4)
        for (index, sample) in samples.enumerated() {
            let x = CGFloat(index) * columnWidth + columnWidth * 0.5
            let amplitude = max(0.5, CGFloat(sample) * (height / 2) * 0.9)
            var path = Path()
            path.move(to: CGPoint(x: x, y: midY - amplitude))
            path.addLine(to: CGPoint(x: x, y: midY + amplitude))
            context.stroke(path, with: .color(Color.accentColor.opacity(0.55)), lineWidth: lineWidth)
        }
    }

    private func drawChordLane(_ context: GraphicsContext, size: CGSize, top: CGFloat, height: CGFloat) {
        guard !rawChords.isEmpty, height > 6 else { return }
        // One label per chord gets unreadable on a long track; skip labels that
        // cannot fit rather than overprinting them.
        for (index, chord) in rawChords.enumerated() {
            let x1 = xPos(chord.start, width: size.width)
            let x2 = xPos(chord.end, width: size.width)
            let width = max(1, x2 - x1)
            let tint: Color = index.isMultiple(of: 2)
                ? Color.accentColor
                : Color(red: 0.13, green: 0.66, blue: 0.45)

            context.fill(
                Path(CGRect(x: x1, y: top, width: width, height: height)),
                with: .color(tint.opacity(0.10))
            )
            var tick = Path()
            tick.move(to: CGPoint(x: x1, y: top))
            tick.addLine(to: CGPoint(x: x1, y: top + height))
            context.stroke(tick, with: .color(tint.opacity(0.45)), lineWidth: 1)

            guard width > 22, x1 < size.width - 8 else { continue }
            let label = context.resolve(
                Text(chord.displayChord)
                    .font(.system(size: barLabelSize, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.75))
            )
            context.draw(label, at: CGPoint(x: x1 + 3, y: top + height / 2), anchor: .leading)
        }
    }

    private func xPos(_ time: Double, width: CGFloat) -> CGFloat {
        WaveformGeometry.xPos(time, duration: duration, width: width)
    }
}

// MARK: - Shared geometry

enum WaveformGeometry {
    static let sectionBandHeight: CGFloat = 16
    static let chordLaneFraction: CGFloat = 0.17

    static func xPos(_ time: Double, duration: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    static func drawPlayhead(
        _ context: GraphicsContext,
        size: CGSize,
        currentTime: Double,
        duration: Double
    ) {
        guard duration > 0 else { return }
        let x = xPos(currentTime, duration: duration, width: size.width)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(.red), lineWidth: 1.5)

        let cap = Path { path in
            path.move(to: CGPoint(x: x - 4.5, y: 0))
            path.addLine(to: CGPoint(x: x + 4.5, y: 0))
            path.addLine(to: CGPoint(x: x, y: 7))
            path.closeSubpath()
        }
        context.fill(cap, with: .color(.red))
    }
}
