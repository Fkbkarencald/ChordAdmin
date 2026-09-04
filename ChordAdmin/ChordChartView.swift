import SwiftUI

// MARK: - Chord chart
//
// The main work surface: bars grouped into sections, four to a row, each bar
// split into chord segments whose widths are proportional to how long the chord
// actually sounds inside that bar. The selected bar carries a floating action
// popover, and S / M / R work while the chart itself holds focus.

struct ChordChartView: View {
    let bars: [ChordChartBarEntry]
    @ObservedObject var sectionStore: SectionStore
    let subdivisions: [Int: Int]
    @Binding var selectedBar: Int?
    let activeBar: Int?
    /// Only auto-scroll while the transport's Follow toggle is on and audio is playing.
    var followPlayhead: Bool = false
    let isPreviewing: Bool
    let changedBars: Set<Int>
    var onSeek: (Double) -> Void
    var onSubdivisionChange: (Int, Int) -> Void
    var onSplit: (Int) -> Void
    var onMerge: (Int) -> Void
    var onRename: (ChordSection) -> Void

    @FocusState private var chartHasFocus: Bool
    @State private var hoveredBar: Int?

    var body: some View {
        Group {
            if bars.isEmpty {
                EmptyStateView(
                    title: "No chord chart yet",
                    message: "Run an analysis on this song and the detected bars, chords and sections appear here.",
                    systemImage: "music.note.list"
                )
            } else {
                chart
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isPreviewing {
                HStack(spacing: 8) {
                    StatusPill(
                        text: "Live preview — not applied",
                        systemImage: "eye",
                        tint: .accentColor
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups) { group in
                            sectionGroup(group)
                                .zIndex(containsSelection(group.entries) ? 1 : 0)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    // Room for the action popover under the very last row.
                    .padding(.bottom, 96)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { scroll(proxy, to: activeBar, animated: false) }
                .onChange(of: activeBar) { _, bar in
                    guard followPlayhead else { return }
                    scroll(proxy, to: bar, animated: true)
                }
                // A bar selected from elsewhere — the waveform, or the keyboard —
                // has to be brought into view, or the selection is invisible.
                .onChange(of: selectedBar) { _, bar in
                    scroll(proxy, to: bar, animated: true)
                }
            }
        }
        .focusable()
        .focused($chartHasFocus)
        // A visible edge instead of the default ring around the whole scroll
        // view: the ring was switched off entirely, which left a keyboard user
        // no way to tell the chart had focus and was accepting arrows, S, M
        // and R — the shortcuts the inspector advertises.
        .focusEffectDisabled()
        .overlay(alignment: .top) {
            if chartHasFocus {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // Same reason the popover's edits are withheld while previewing.
        .onKeyPress("s") { isPreviewing ? .ignored : splitFromKeyboard() }
        .onKeyPress("m") { isPreviewing ? .ignored : mergeFromKeyboard() }
        .onKeyPress("r") { isPreviewing ? .ignored : renameFromKeyboard() }
        // Arrow keys move the selection so a whole song's sections can be worked
        // through without going back to the mouse; the chart also seeks as it goes.
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSelectionRow(down: false) }
        .onKeyPress(.downArrow) { moveSelectionRow(down: true) }
        .onKeyPress(.escape) {
            guard selectedBar != nil else { return .ignored }
            selectedBar = nil
            return .handled
        }
    }

    /// Moves the selected bar left or right through the chart.
    private func moveSelection(by delta: Int) -> KeyPress.Result {
        guard let bar = ChartNavigation.nextBar(from: selectedBar, playhead: activeBar,
                                     in: bars.map(\.bar), by: delta) else { return .ignored }
        select(bar: bar)
        return .handled
    }

    /// Moves the selected bar a visual row up or down.
    private func moveSelectionRow(down: Bool) -> KeyPress.Result {
        let grouped = groups.map { $0.entries.map(\.bar) }
        guard let bar = ChartNavigation.barARowAway(from: selectedBar, playhead: activeBar,
                                         sections: grouped, rowLength: Self.barsPerRow,
                                         down: down) else { return .ignored }
        select(bar: bar)
        return .handled
    }

    private func select(bar: Int) {
        guard let entry = bars.first(where: { $0.bar == bar }) else { return }
        selectedBar = bar
        onSeek(entry.start)
    }

    private func scroll(_ proxy: ScrollViewProxy, to bar: Int?, animated: Bool) {
        guard let bar else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(ChordChartBarAnchor(bar: bar), anchor: .center)
            }
        } else {
            proxy.scrollTo(ChordChartBarAnchor(bar: bar), anchor: .center)
        }
    }

    // MARK: Section group

    @ViewBuilder
    private func sectionGroup(_ group: ChordChartGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = group.header {
                sectionHeader(header, section: group.section, colourIndex: group.colourIndex)
            }
            ForEach(rows(of: group.entries)) { row in
                barRow(row)
                    .zIndex(containsSelection(row.entries) ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, section: ChordSection?, colourIndex: Int) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                // By first appearance, exactly as the waveform band does it.
                // Colouring by list position instead gave the same section two
                // different colours in two panes of one window, and the two
                // occurrences of a repeated chorus different colours from each
                // other — losing the very thing the palette is there to show.
                .fill(section == nil
                      ? SectionPalette.color(forSectionNamed: title, fallbackIndex: colourIndex)
                      : SectionPalette.color(forSectionNamed: title,
                                             among: sectionStore.sections.map(\.name)))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)

            if let section {
                Button {
                    onRename(section)
                } label: {
                    Text(title)
                        .scaledFont(size: 13, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help("Rename this section")
            } else {
                Text(title)
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(metaText(for: section))
                .scaledFont(size: 10.5, relativeTo: .caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private func metaText(for section: ChordSection?) -> String {
        guard let section else { return unassignedRangeText }
        var parts = ["Bars \(section.startBar)–\(section.endBar)"]
        let repeats = sectionStore.repeatCount(of: section)
        if repeats > 1 { parts.append("repeats ×\(repeats)") }
        return parts.joined(separator: " · ")
    }

    private var unassignedRangeText: String {
        let claimed = Set(sectionStore.sections.flatMap(\.bars))
        let loose = bars.map(\.bar).filter { !claimed.contains($0) }
        guard let first = loose.min(), let last = loose.max() else { return "" }
        return "Bars \(first)–\(last)"
    }

    // MARK: Rows and bars

    private func barRow(_ row: ChordChartRow) -> some View {
        HStack(spacing: 10) {
            ForEach(row.entries, id: \.bar) { entry in
                barCell(entry)
                    .zIndex(selectedBar == entry.bar ? 1 : 0)
            }
            // Keep the last row's bars the same width as every other row.
            ForEach(0..<max(0, ChordChartView.barsPerRow - row.entries.count), id: \.self) { _ in
                Color.clear.frame(height: 60).frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .topLeading) {
            if let bar = row.entries.first(where: { $0.bar == selectedBar })?.bar {
                barActions(for: bar)
                    .fixedSize()
                    .offset(y: 66)
                    .transition(.opacity)
            }
        }
    }

    private func barCell(_ entry: ChordChartBarEntry) -> some View {
        let isSelected = selectedBar == entry.bar
        let isActive = activeBar == entry.bar
        let isChanged = isPreviewing && changedBars.contains(entry.bar)
        let isHovered = hoveredBar == entry.bar
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        return ZStack(alignment: .topLeading) {
            shape.fill(barFill(isSelected: isSelected, isActive: isActive, isChanged: isChanged))

            ChordChartSegmentStrip(
                segments: segments(for: entry),
                // A chip always seeks and keeps the bar selected; only the bar's
                // own background toggles selection.
                onTap: { start in select(entry, seekingTo: start, allowDeselect: false) }
            )
            .padding(3)

            HStack(spacing: 3) {
                Text("\(entry.bar)")
                    .scaledFont(size: 10, weight: .bold, design: .monospaced, relativeTo: .caption2)
                    .foregroundStyle(.tertiary)
                // The playing bar and the selected bar differed only by border
                // hue, at the same weight. A shape says which is which without
                // relying on telling green from blue.
                if isActive {
                    Image(systemName: "play.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, 6)
            .padding(.top, 2)
            .allowsHitTesting(false)
        }
        .frame(minHeight: 60)
        .frame(maxWidth: .infinity)
        .overlay(barBorder(isSelected: isSelected, isActive: isActive, isChanged: isChanged))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 3)
                    .padding(-1.5)
                    .allowsHitTesting(false)
            } else if isHovered {
                shape.stroke(Color.primary.opacity(0.18), lineWidth: 1).allowsHitTesting(false)
            }
        }
        .contentShape(shape)
        .onTapGesture { select(entry, seekingTo: entry.start) }
        .onHover { hovering in
            if hovering {
                hoveredBar = entry.bar
            } else if hoveredBar == entry.bar {
                hoveredBar = nil
            }
        }
        // One element per bar rather than a loose run of numbers and chord
        // names. Without this the main work surface read as "1, C, 2, Am" with
        // nothing tying a chord to its bar, and no way to select one — which
        // also put split, merge, rename and subdivide out of reach, since they
        // all act on the selected bar.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: entry))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Selects this bar and moves the playhead to it")
        .accessibilityAction { select(entry, seekingTo: entry.start, allowDeselect: false) }
        .id(ChordChartBarAnchor(bar: entry.bar))
    }

    /// What a bar is called out loud: its number, its chords, its section, and
    /// the states the border alone used to carry.
    private func accessibilityLabel(for entry: ChordChartBarEntry) -> String {
        var parts = ["Bar \(entry.bar)"]

        let chords = segments(for: entry).map(\.label).filter { !$0.isEmpty }
        parts.append(chords.isEmpty ? "no chord" : chords.joined(separator: ", "))

        if let section = sectionStore.section(containing: entry.bar) {
            parts.append("in \(section.name)")
        }
        if let value = subdivisions[entry.bar], value != 4 {
            parts.append("subdivided into \(value)")
        }
        if activeBar == entry.bar { parts.append("now playing") }
        if isPreviewing && changedBars.contains(entry.bar) { parts.append("changed by the preview") }
        return parts.joined(separator: ", ")
    }

    private func barFill(isSelected: Bool, isActive: Bool, isChanged: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.08) }
        if isActive { return Color.green.opacity(0.12) }
        if isChanged { return Color.accentColor.opacity(0.05) }
        return Color.primary.opacity(0.05)
    }

    @ViewBuilder
    private func barBorder(isSelected: Bool, isActive: Bool, isChanged: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if isSelected {
            shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
        } else if isActive {
            shape.strokeBorder(Color.green, lineWidth: 1.5)
        } else if isChanged {
            shape.strokeBorder(
                Color.accentColor,
                style: StrokeStyle(lineWidth: 1.5, dash: [3.5, 2.5])
            )
        } else {
            shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }


    @ViewBuilder
    private func sectionActions(for bar: Int, section: ChordSection?) -> some View {
        if canSplit(bar) {
            ChordChartActionButton(title: "Split here", key: "S") { onSplit(bar) }
        }
        if canMerge(bar) {
            ChordChartActionButton(title: "Merge with previous", key: "M") { onMerge(bar) }
        }
        if let section {
            ChordChartActionButton(title: "Rename", key: "R") { onRename(section) }
        }
    }

    private func subdivideControl(for bar: Int) -> some View {
        HStack(spacing: 5) {
            Text("Subdivide")
                .scaledFont(size: 10, relativeTo: .caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.leading, 2)

            Picker("Subdivide", selection: subdivisionBinding(for: bar)) {
                Text("1").tag(1)
                Text("1/2").tag(2)
                Text("1/4").tag(4)
                Text("1/8").tag(8)
                Text("1/16").tag(16)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    // MARK: Action popover

    @ViewBuilder
    private func barActions(for bar: Int) -> some View {
        let section = sectionStore.section(containing: bar)
        // One row when the pane is wide enough, otherwise two — the action bar is
        // wider than a single bar cell, so a fixed one-line layout was clipped by
        // the scroll view at the window's own minimum width.
        Group {
            if isPreviewing {
                // The preview renumbers bars, so bar 9 on screen is not the bar 9
                // these edits would write to. Editing through the preview quietly
                // changed a different bar, and reverting the tuning left the
                // damage behind.
                Text("Apply or revert the timing change to edit bars")
                    .scaledFont(size: 11, relativeTo: .caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        sectionActions(for: bar, section: section)
                        Divider().frame(height: 16)
                        subdivideControl(for: bar)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) { sectionActions(for: bar, section: section) }
                        subdivideControl(for: bar)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    private func subdivisionBinding(for bar: Int) -> Binding<Int> {
        Binding(
            get: { subdivisions[bar] ?? 4 },
            set: { onSubdivisionChange(bar, $0) }
        )
    }

    // MARK: Interaction

    private func select(_ entry: ChordChartBarEntry, seekingTo start: Double, allowDeselect: Bool = true) {
        chartHasFocus = true
        onSeek(max(start, entry.start))
        if allowDeselect && selectedBar == entry.bar {
            selectedBar = nil
        } else {
            selectedBar = entry.bar
        }
    }

    /// Splitting only makes sense inside a section, and not on its first bar.
    private func canSplit(_ bar: Int) -> Bool {
        sectionStore.section(containing: bar) != nil && !sectionStore.isFirstBarOfSection(bar)
    }

    private func canMerge(_ bar: Int) -> Bool {
        guard let section = sectionStore.section(containing: bar) else { return false }
        return sectionStore.isFirstBarOfSection(bar) && !sectionStore.isFirstSection(section)
    }

    private func splitFromKeyboard() -> KeyPress.Result {
        guard let bar = selectedBar, canSplit(bar) else { return .ignored }
        onSplit(bar)
        return .handled
    }

    private func mergeFromKeyboard() -> KeyPress.Result {
        guard let bar = selectedBar, canMerge(bar) else { return .ignored }
        onMerge(bar)
        return .handled
    }

    private func renameFromKeyboard() -> KeyPress.Result {
        guard let bar = selectedBar, let section = sectionStore.section(containing: bar) else { return .ignored }
        onRename(section)
        return .handled
    }

    // MARK: Grouping

    private static let barsPerRow = 4

    private var groups: [ChordChartGroup] {
        guard !bars.isEmpty else { return [] }
        let sections = sectionStore.sections
        guard !sections.isEmpty else {
            return [ChordChartGroup(id: "flat", header: nil, section: nil, colourIndex: 0, entries: bars)]
        }

        var byNumber: [Int: ChordChartBarEntry] = [:]
        for entry in bars { byNumber[entry.bar] = entry }

        var claimed: Set<Int> = []
        var result: [ChordChartGroup] = []
        for (index, section) in sections.enumerated() {
            var entries: [ChordChartBarEntry] = []
            for number in section.bars.sorted() where !claimed.contains(number) {
                guard let entry = byNumber[number] else { continue }
                claimed.insert(number)
                entries.append(entry)
            }
            guard !entries.isEmpty else { continue }
            result.append(
                ChordChartGroup(
                    id: section.id,
                    header: section.name,
                    section: section,
                    colourIndex: index,
                    entries: entries
                )
            )
        }

        let loose = bars.filter { !claimed.contains($0.bar) }
        if !loose.isEmpty {
            result.append(
                ChordChartGroup(
                    id: "chord-chart-unassigned",
                    header: "Unassigned",
                    section: nil,
                    colourIndex: sections.count,
                    entries: loose
                )
            )
        }
        return result
    }

    private func rows(of entries: [ChordChartBarEntry]) -> [ChordChartRow] {
        stride(from: 0, to: entries.count, by: ChordChartView.barsPerRow).map { start in
            let end = min(start + ChordChartView.barsPerRow, entries.count)
            let slice = Array(entries[start..<end])
            return ChordChartRow(id: slice.first?.bar ?? start, entries: slice)
        }
    }

    private func containsSelection(_ entries: [ChordChartBarEntry]) -> Bool {
        guard let selectedBar else { return false }
        return entries.contains { $0.bar == selectedBar }
    }

    // MARK: Segment allocation

    /// Turn a bar's overlapping chord spans into the segments actually drawn.
    ///
    /// This is the allocation the previous build used and the mockup reflects:
    /// short overlaps are dropped, repeats are collapsed, and the bar's
    /// subdivision units are shared out in proportion to sounding time.
    private func segments(for entry: ChordChartBarEntry) -> [ChordChartSegment] {
        let subdivision = max(1, subdivisions[entry.bar] ?? 4)
        let duration = max(0, entry.end - entry.start)
        let minOverlap = max(0.05, duration / Double(subdivision) * 0.5)

        let kept = entry.chords
            .filter { $0.overlapSeconds >= minOverlap }
            .sorted { $0.start < $1.start }

        var distinct: [ChordChartChordEntry] = []
        for chord in kept where distinct.last?.displayChord != chord.displayChord {
            distinct.append(chord)
        }

        guard !distinct.isEmpty else {
            return [
                ChordChartSegment(
                    id: 0,
                    label: entry.primaryChord ?? "N.C.",
                    start: entry.start,
                    units: subdivision
                )
            ]
        }

        let units = ChordChartView.allocate(
            units: subdivision,
            weights: distinct.map { max(0, $0.overlapSeconds) }
        )
        return distinct.enumerated().map { index, chord in
            ChordChartSegment(
                id: index,
                label: chord.displayChord,
                start: chord.start,
                units: units[index]
            )
        }
    }

    /// Largest-remainder apportionment with a floor of one unit per segment.
    private static func allocate(units total: Int, weights: [Double]) -> [Int] {
        let count = weights.count
        guard count > 0 else { return [] }
        guard total > count else { return Array(repeating: 1, count: count) }

        let sum = weights.reduce(0, +)
        guard sum > 0 else {
            var even = Array(repeating: total / count, count: count)
            for index in 0..<(total % count) { even[index] += 1 }
            return even.map { max(1, $0) }
        }

        let exact = weights.map { Double(total) * $0 / sum }
        var result = exact.map { max(1, Int($0.rounded(.down))) }
        var assigned = result.reduce(0, +)
        guard assigned < total else { return result }

        let surplusOrder = (0..<count).sorted { lhs, rhs in
            let left = exact[lhs] - Double(result[lhs])
            let right = exact[rhs] - Double(result[rhs])
            if left == right { return lhs < rhs }
            return left > right
        }
        var cursor = 0
        while assigned < total {
            result[surplusOrder[cursor % count]] += 1
            assigned += 1
            cursor += 1
        }
        return result
    }
}

// MARK: - Private models

private struct ChordChartBarAnchor: Hashable {
    let bar: Int
}

private struct ChordChartGroup: Identifiable {
    let id: String
    let header: String?
    let section: ChordSection?
    let colourIndex: Int
    let entries: [ChordChartBarEntry]
}

private struct ChordChartRow: Identifiable {
    let id: Int
    let entries: [ChordChartBarEntry]
}

private struct ChordChartSegment: Identifiable {
    let id: Int
    let label: String
    let start: Double
    let units: Int
}

// MARK: - Private views

/// The chord chips inside one bar, laid out with widths proportional to each
/// chord's share of the bar's subdivision units.
private struct ChordChartSegmentStrip: View {
    let segments: [ChordChartSegment]
    let onTap: (Double) -> Void

    private let spacing: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let chipWidths = segmentWidths(in: proxy.size.width)
            HStack(spacing: spacing) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    chip(segment)
                        .frame(width: index < chipWidths.count ? chipWidths[index] : 0)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }

    private func chip(_ segment: ChordChartSegment) -> some View {
        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                Text(segment.label)
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .padding(.horizontal, 2)
            )
            .contentShape(Rectangle())
            .onTapGesture { onTap(segment.start) }
    }

    /// Integral widths that add up exactly to the space available.
    private func segmentWidths(in width: CGFloat) -> [CGFloat] {
        let count = segments.count
        guard count > 0 else { return [] }
        let available = max(0, width - spacing * CGFloat(count - 1))
        let totalUnits = CGFloat(max(1, segments.reduce(0) { $0 + max(1, $1.units) }))

        var result: [CGFloat] = []
        var unitsSoFar: CGFloat = 0
        var widthSoFar: CGFloat = 0
        for segment in segments {
            unitsSoFar += CGFloat(max(1, segment.units))
            let edge = (available * unitsSoFar / totalUnits).rounded()
            result.append(max(0, edge - widthSoFar))
            widthSoFar = edge
        }
        return result
    }
}

/// One button in the floating bar popover: label plus its shortcut chip.
private struct ChordChartActionButton: View {
    let title: String
    let key: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .scaledFont(size: 11, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(.primary)
                KeyCap(key: key)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.12 : 0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
