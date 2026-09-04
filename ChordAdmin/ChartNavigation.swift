import Foundation

// MARK: - Keyboard navigation
//
// Where each arrow key lands, kept apart from the view so the rules can be
// tested directly. Rows are chunked within a section rather than across the
// whole chart, which is what makes the vertical case more than an offset.

nonisolated enum ChartNavigation {

    /// Where a left/right arrow should land: the next bar in reading order.
    static func nextBar(from selected: Int?, playhead: Int?, in bars: [Int], by delta: Int) -> Int? {
        guard !bars.isEmpty else { return nil }
        guard let selected, let index = bars.firstIndex(of: selected) else {
            // Nothing selected yet: start from the playhead, or the first bar.
            return bars[playhead.flatMap { bars.firstIndex(of: $0) } ?? 0]
        }
        let next = min(max(0, index + delta), bars.count - 1)
        return next == index ? nil : bars[next]
    }

    /// Where an up/down arrow should land.
    ///
    /// Each section starts its own rows, so the grid is ragged and a fixed ±4
    /// through the flat list drifts by every section's remainder. This walks the
    /// same grouping the layout draws, and always moves exactly one row: a
    /// column that overhangs a short row lands on that row's last bar rather
    /// than skipping past it.
    static func barARowAway(
        from selected: Int?, playhead: Int?, sections: [[Int]], rowLength: Int, down: Bool
    ) -> Int? {
        guard rowLength > 0 else { return nil }
        let flat = sections.flatMap { $0 }
        guard !flat.isEmpty else { return nil }
        guard let groupIndex = sections.firstIndex(where: { $0.contains(selected ?? .min) }),
              let withinGroup = sections[groupIndex].firstIndex(of: selected ?? .min) else {
            // Nothing selected, or a selection that no longer exists: start from
            // the playing bar, or the top of the chart.
            return flat[playhead.flatMap { flat.firstIndex(of: $0) } ?? 0]
        }

        let group = sections[groupIndex]
        let column = withinGroup % rowLength
        let rowStart = withinGroup - column
        let targetRowStart = rowStart + (down ? rowLength : -rowLength)

        if targetRowStart >= 0 && targetRowStart < group.count {
            // The row exists in this section; clamp the column to its width.
            return group[min(targetRowStart + column, group.count - 1)]
        }

        // Off the end of this section: continue into the neighbouring one,
        // keeping the column where that row is wide enough.
        let neighbour = groupIndex + (down ? 1 : -1)
        guard sections.indices.contains(neighbour), !sections[neighbour].isEmpty else { return nil }
        let target = sections[neighbour]
        // Down enters at the first row, up enters at the last.
        let entryRowStart = down ? 0 : ((target.count - 1) / rowLength) * rowLength
        return target[min(entryRowStart + column, target.count - 1)]
    }
}
