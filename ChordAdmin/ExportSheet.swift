import AppKit
import SwiftUI

// MARK: - Export confirmation sheet
//
// The last thing standing between a local analysis and a write to production
// Firestore, so it shows the actual diff rather than a generic "are you sure".
// Everything on this sheet comes from the prepared `ExportPreview`, which is
// built by running the real translation — what is listed here is what will be
// written.

struct ExportSheet: View {
    let preview: ExportPreview
    let isExporting: Bool
    let errorMessage: String?
    var onCancel: () -> Void
    var onConfirm: () -> Void

    @Environment(\.chordAdminTextScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
            Divider()
            footer
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(isExporting)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Export to TheStageBee")
                .scaledFont(size: 15, weight: .bold, relativeTo: .body)
            Text("Updates the existing song document — only the sections and the tempo are written. "
                 + "Title, key, artists and links are not touched.")
                .scaledFont(size: 11.5, relativeTo: .caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Body

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            songRow
            overwriteBlock
            statusLine
            if let errorMessage, !errorMessage.isEmpty {
                errorBlock(errorMessage)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
    }

    /// The document this export will land on. The ID is shown because the whole
    /// point of the sheet is to make the target unmistakable.
    private var songRow: some View {
        PanelCard(padding: 10) {
            HStack(spacing: 10) {
                SongThumbnail(url: nil, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.songTitle)
                        .scaledFont(size: 12.5, weight: .semibold, relativeTo: .footnote)
                        .lineLimit(1)
                    if let artist = preview.artist, !artist.isEmpty {
                        Text(artist)
                            .scaledFont(size: 10.5, relativeTo: .caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                Text("songs/\(preview.documentID)")
                    .scaledFont(size: 10, design: .monospaced, relativeTo: .caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .trailing)
                    .help(preview.documentID)
            }
        }
    }

    private var overwriteBlock: some View {
        PanelCard(padding: 12) {
            GroupLabel("This will overwrite")
            tempoRow
            sectionsRow
        }
    }

    private var tempoRow: some View {
        HStack(spacing: 8) {
            fieldLabel("Tempo")

            if let newTempo = preview.newTempo {
                if preview.tempoChanged {
                    Text(preview.currentTempo.map { "\($0)" } ?? "—")
                        .scaledFont(size: 12, design: .monospaced, relativeTo: .footnote)
                        .foregroundStyle(.tertiary)
                        .strikethrough(true, color: .secondary)
                    Image(systemName: "arrow.right")
                        .scaledFont(size: 9, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("\(newTempo)")
                    .scaledFont(size: 12, weight: .bold, design: .monospaced, relativeTo: .footnote)
                Text("BPM")
                    .scaledFont(size: 11, relativeTo: .caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("unchanged")
                    .scaledFont(size: 12, relativeTo: .footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var sectionsRow: some View {
        let rows = ExportSheetChipLayout.rows(
            for: preview.newSections,
            maxWidth: ExportSheetChipLayout.areaWidth(scale: textScale),
            scale: textScale
        )
        let height = min(
            ExportSheetChipLayout.contentHeight(rowCount: rows.count, scale: textScale),
            ExportSheetChipLayout.maxAreaHeight * textScale
        )

        return HStack(alignment: .top, spacing: 8) {
            fieldLabel("Sections")

            VStack(alignment: .leading, spacing: 7) {
                Text(currentSectionsSummary)
                    .scaledFont(size: 11, relativeTo: .caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: ExportSheetChipLayout.spacing) {
                        ForEach(rows) { row in
                            HStack(spacing: ExportSheetChipLayout.spacing) {
                                ForEach(row.items) { item in
                                    ExportSheetSectionChip(item: item)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: height)
                .scrollBounceBehavior(.basedOnSize)
            }

            Spacer(minLength: 0)
        }
    }

    /// Both of these are true by construction — the preview only exists because
    /// the backend answered the translation request and the user was signed in
    /// when it was built — so the line reports what was actually verified.
    private var statusLine: some View {
        // Two lines rather than two truncations: at larger text sizes these did
        // not fit side by side, and "Backend reacha… localhost:50…" told the
        // user neither which backend nor that it was reachable.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                backendStatus
                accountStatus
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                backendStatus
                accountStatus
            }
        }
        .scaledFont(size: 11, relativeTo: .caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var backendStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text("Backend reachable")
            Text(backendHost)
                .scaledFont(size: 10.5, design: .monospaced, relativeTo: .caption2)
                .foregroundStyle(.tertiary)
        }
        .fixedSize()
    }

    private var accountStatus: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.crop.circle")
                .scaledFont(size: 11, relativeTo: .caption)
            Text("Signed in to TheStageBee")
        }
        .fixedSize()
    }

    private func errorBlock(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 11, relativeTo: .caption)
                .foregroundStyle(.red)
            Text(message)
                .scaledFont(size: 11.5, relativeTo: .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Previous values are kept locally.")
                .scaledFont(size: 10.5, relativeTo: .caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 12)

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(isExporting)

            Button(action: onConfirm) {
                HStack(spacing: 6) {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    }
                    Text(isExporting ? "Exporting…" : "Overwrite “\(preview.songTitle)”")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isExporting)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // MARK: - Derived copy

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 12, relativeTo: .footnote)
            .foregroundStyle(.secondary)
            // The column has to grow with the type and never break the word:
            // pinned to 64pt, "Sections" wrapped to "Section" / "s" at larger
            // text sizes, on the one screen where the user is confirming an
            // irreversible write.
            .fixedSize()
            .frame(minWidth: 64 * textScale, alignment: .leading)
    }

    private var currentSectionsSummary: String {
        let names = preview.currentSectionNames.filter { !$0.isEmpty }
        guard !names.isEmpty else { return "currently none" }
        return "currently \(names.count) — " + names.joined(separator: ", ")
    }

    private var backendHost: String {
        let base = JobManager.backendBaseUrl
        guard let url = URL(string: base), let host = url.host else { return base }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}

// MARK: - Section chips

private struct ExportSheetChipItem: Identifiable {
    let id: Int
    let name: String
    let detail: String
    let width: CGFloat
}

private struct ExportSheetChipRow: Identifiable {
    let id: Int
    let items: [ExportSheetChipItem]
}

/// Packs the section chips into rows.
///
/// The sheet is a fixed 560pt wide, so the space available to the chips is a
/// known constant and the rows can be measured up front rather than guessed at
/// with a geometry reader. Knowing the row count also gives the scroll view an
/// exact height, which is what keeps a long section list from pushing the
/// footer off the bottom of the sheet.
private enum ExportSheetChipLayout {
    static let spacing: CGFloat = 5
    static let maxAreaHeight: CGFloat = 104

    /// Every measurement here is taken at the size the chips are actually drawn,
    /// so the reader's text setting has to reach it. Measuring at a fixed 11pt
    /// while drawing at 15 packed more chips into a row than fit, and clipped
    /// them vertically against a height computed for smaller type.
    static func chipHeight(scale: CGFloat) -> CGFloat { (22 * scale).rounded() }

    /// 560 sheet − 22 padding each side − 12 card padding each side − the label
    /// column − 8 gap, less a little slack for the overlay scroller. Only the
    /// label column grows with the text; the sheet itself is a fixed width.
    static func areaWidth(scale: CGFloat) -> CGFloat {
        560 - 44 - 24 - max(64, 64 * scale) - 8 - 12
    }

    private static let horizontalPadding: CGFloat = 9
    private static let innerSpacing: CGFloat = 5

    static func rows(
        for sections: [ExportPreviewSection],
        maxWidth: CGFloat,
        scale: CGFloat
    ) -> [ExportSheetChipRow] {
        var rows: [ExportSheetChipRow] = []
        var current: [ExportSheetChipItem] = []
        var usedWidth: CGFloat = 0

        for (index, section) in sections.enumerated() {
            let detail = detailText(for: section, isFirst: index == 0)
            let item = ExportSheetChipItem(
                id: section.index,
                name: section.name,
                detail: detail,
                width: chipWidth(name: section.name, detail: detail, scale: scale)
            )
            let needed = current.isEmpty ? item.width : usedWidth + spacing + item.width

            if !current.isEmpty, needed > maxWidth {
                rows.append(ExportSheetChipRow(id: rows.count, items: current))
                current = [item]
                usedWidth = item.width
            } else {
                current.append(item)
                usedWidth = needed
            }
        }

        if !current.isEmpty {
            rows.append(ExportSheetChipRow(id: rows.count, items: current))
        }
        return rows
    }

    static func contentHeight(rowCount: Int, scale: CGFloat) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * chipHeight(scale: scale) + CGFloat(rowCount - 1) * spacing
    }

    /// The unit is spelled out once and then left implied, so the row reads as
    /// "Intro 4 bars · Verse A 16 · Chorus 16" rather than repeating "bars".
    private static func detailText(for section: ExportPreviewSection, isFirst: Bool) -> String {
        guard isFirst else { return "\(section.barCount)" }
        return section.barCount == 1 ? "1 bar" : "\(section.barCount) bars"
    }

    private static func chipWidth(name: String, detail: String, scale: CGFloat) -> CGFloat {
        horizontalPadding * 2
            + textWidth(name, font: .systemFont(ofSize: 11 * scale, weight: .medium))
            + innerSpacing
            + textWidth(detail, font: .systemFont(ofSize: 11 * scale, weight: .regular))
            + 2   // slack so a measured row never overflows the rendered one
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
}

private struct ExportSheetSectionChip: View {
    let item: ExportSheetChipItem

    @Environment(\.chordAdminTextScale) private var textScale

    var body: some View {
        HStack(spacing: 5) {
            Text(item.name)
                .scaledFont(size: 11, weight: .medium, relativeTo: .caption)
            Text(item.detail)
                .scaledFont(size: 11, relativeTo: .caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .frame(height: ExportSheetChipLayout.chipHeight(scale: textScale))
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}
