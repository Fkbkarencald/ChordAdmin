import SwiftUI

/// A review surface alongside the September workspace, using its shared cards,
/// colours and text scaling. Charts are edited in the existing three panes.
struct SongImportReviewQueueView: View {
    @ObservedObject var store: SongImportFirestoreStore
    @ObservedObject var processing: SongImportProcessing
    let onProcess: (SongImportRecord, Bool) -> Void
    let onOpen: (SongImportRecord) -> Void
    let onPrepare: (SongImportRecord) -> Void
    let canPrepare: (SongImportRecord) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var title = ""
    @State private var artist = ""
    @State private var key = ""
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Song imports").scaledFont(size: 18, weight: .bold, relativeTo: .title2)
                    Text("Analyse a source, edit its chart, then review publication to TheStageBee.")
                        .scaledFont(size: 12, relativeTo: .caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reload") { Task { await store.reload() } }.disabled(store.isLoading)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let message = store.message ?? processing.message {
                Label(message, systemImage: "info.circle")
                    .scaledFont(size: 12, relativeTo: .caption)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            PanelCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    GroupLabel("New song")
                    TextField("YouTube video URL", text: $source).textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("Song title", text: $title)
                        TextField("Artist", text: $artist)
                        TextField("Key (optional)", text: $key).frame(maxWidth: 100)
                    }.textFieldStyle(.roundedBorder)
                    Button(creating ? "Staging…" : "Stage and analyse") { create() }
                        .buttonStyle(.borderedProminent)
                        .disabled(creating || source.isEmpty || title.isEmpty || artist.isEmpty)
                }.scaledFont(size: 12, relativeTo: .body)
            }
            Divider()
            if store.isLoading { ProgressView("Loading imports…") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.records.isEmpty, !store.isLoading {
                        Text("No staged imports. Add a source above to begin.")
                            .scaledFont(size: 13, relativeTo: .body).foregroundStyle(.secondary)
                    }
                    ForEach(store.records) { record in
                        SongImportReviewCard(record: record,
                            busy: processing.activeIDs.contains(record.id) || store.busyRecordID == record.id,
                            canPrepare: canPrepare(record),
                            onSave: { fields in try await store.update(record, fields: fields) },
                            onReject: { try await store.reject(record, reason: "Rejected by owner during review.") },
                            onProcess: { onProcess(record, record.mediaStatus.contains { $0.state == .failed }) },
                            onOpen: { onOpen(record) }, onPrepare: { onPrepare(record) },
                            onError: { store.message = SongImportRedactor.redact($0.localizedDescription) })
                    }
                }.padding(2)
            }
        }
        .padding(22).frame(minWidth: 720, idealWidth: 820, minHeight: 600, idealHeight: 760)
    }

    private func create() {
        creating = true
        store.message = nil
        processing.message = nil
        Task {
            defer { creating = false }
            do {
                let record = try await store.create(sourceURL: source, title: title, artist: artist, key: key)
                source = ""; title = ""; artist = ""; key = ""
                if record.duplicateCandidates.isEmpty { onProcess(record, false) }
                else { store.message = "Possible duplicate found. Review it before continuing." }
            } catch { store.message = SongImportRedactor.redact(error.localizedDescription) }
        }
    }
}

struct SongImportReviewCard: View {
    let record: SongImportRecord
    let busy: Bool
    let canPrepare: Bool
    let onSave: (SongImportFields) async throws -> Void
    let onReject: () async throws -> Void
    let onProcess: () -> Void
    let onOpen: () -> Void
    let onPrepare: () -> Void
    let onError: (Error) -> Void
    @State private var fields: SongImportFields
    @State private var saving = false
    @State private var confirmingReject = false

    init(record: SongImportRecord, busy: Bool, canPrepare: Bool,
         onSave: @escaping (SongImportFields) async throws -> Void,
         onReject: @escaping () async throws -> Void, onProcess: @escaping () -> Void,
         onOpen: @escaping () -> Void, onPrepare: @escaping () -> Void,
         onError: @escaping (Error) -> Void) {
        self.record = record; self.busy = busy; self.canPrepare = canPrepare
        self.onSave = onSave; self.onReject = onReject; self.onProcess = onProcess
        self.onOpen = onOpen; self.onPrepare = onPrepare; self.onError = onError
        _fields = State(initialValue: record.reviewFields)
    }

    private var dirty: Bool { fields != record.reviewFields }
    private var open: Bool { record.status == .staged }

    var body: some View {
        PanelCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(record.reviewFields.title).scaledFont(size: 14, weight: .semibold, relativeTo: .headline)
                    Spacer()
                    StatusPill(text: record.status.rawValue.capitalized,
                               systemImage: open ? "tray" : (record.status == .approved ? "checkmark.circle" : "xmark.circle"), tint: open ? .accentColor : .secondary)
                }
                Text(record.source.url).scaledFont(size: 11, design: .monospaced, relativeTo: .caption)
                    .foregroundStyle(.secondary).textSelection(.enabled)
                if open {
                    HStack {
                        TextField("Title", text: $fields.title)
                        TextField("Artist", text: $fields.artist)
                        TextField("Key", text: $fields.key).frame(maxWidth: 90)
                    }.textFieldStyle(.roundedBorder).disabled(busy || saving)
                    if dirty {
                        Button("Save metadata") { perform { try await onSave(fields) } }
                            .disabled(busy || saving)
                        Text("Save metadata before opening the chart or publication preview.")
                            .foregroundStyle(.secondary)
                    }
                }
                Text(record.mediaStatus.map { "\($0.step.displayName): \($0.state.rawValue)" }.joined(separator: " · "))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(record.mediaStatus.filter { $0.state == .failed }) { failed in
                    Label(failed.redactedError ?? "\(failed.step.displayName) failed. Resume this import to retry.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(record.validationWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if open, !record.duplicateCandidates.isEmpty {
                    Button("Recheck duplicates") { perform { try await onSave(fields) } }.disabled(busy || saving || dirty)
                }
                ForEach(record.duplicateCandidates) { duplicate in
                    Label("Possible duplicate: \(duplicate.title) — \(duplicate.artist)", systemImage: "doc.on.doc")
                        .foregroundStyle(.orange)
                }
                if open {
                    HStack {
                        Button(busy ? "Processing…" : "Analyse / Resume", action: onProcess)
                            .disabled(busy || saving || dirty || !record.duplicateCandidates.isEmpty)
                        Button("Open chart", action: onOpen).disabled(saving || dirty)
                        Button("Review publication…", action: onPrepare)
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || saving || dirty || !canPrepare || !record.duplicateCandidates.isEmpty)
                        Spacer()
                        Button("Reject", role: .destructive) { confirmingReject = true }.disabled(busy || saving)
                    }
                }
                DisclosureGroup("History (\(record.history.count))") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(record.history.reversed()) { event in
                            Text("\(event.occurredAt.formatted(date: .abbreviated, time: .shortened)) · \(event.actorName) · \(event.step?.displayName ?? "Review"): \(event.detail)")
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }.scaledFont(size: 11.5, relativeTo: .caption)
        }
        .onChange(of: record.reviewFields) { old, new in if fields == old { fields = new } }
        .confirmationDialog("Reject “\(record.reviewFields.title)”?", isPresented: $confirmingReject, titleVisibility: .visible) {
            Button("Reject import", role: .destructive) { perform(onReject) }
        } message: { Text("The import and its history remain recorded. It cannot be published or retried after rejection.") }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        saving = true
        Task {
            defer { saving = false }
            do { try await action() } catch { onError(error) }
        }
    }
}
