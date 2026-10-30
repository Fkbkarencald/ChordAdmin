import Combine
import FirebaseAuth
import FirebaseFirestore
import Foundation

@MainActor
final class SongImportFirestoreStore: ObservableObject, SongImportProcessingStore {
    @Published private(set) var records: [SongImportRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var busyRecordID: String?
    @Published var message: String?
    private let db = Firestore.firestore()
    private let collection = "songImportStaging"
    private var generation = 0

    enum StoreError: LocalizedError {
        case permissionDenied, missing, invalidResult, existingSong
        case invalidInput(String)
        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Sign in with your TheStageBee administrator account to review imports."
            case .missing: "The staged import no longer exists."
            case .invalidResult: "The import transaction returned no result. Reload before trying again."
            case .existingSong: "A song already exists for this source. Open that song instead of creating another."
            case .invalidInput(let message): message
            }
        }
    }

    func reset() {
        generation += 1
        records = []
        isLoading = false
        message = nil
    }

    func reload() async {
        let request = generation
        isLoading = true
        defer { if request == generation { isLoading = false } }
        do {
            _ = try await reviewer()
            let snapshot = try await db.collection(collection).getDocuments()
            let loaded = try snapshot.documents.map { try $0.data(as: SongImportRecord.self) }
            guard request == generation else { return }
            records = loaded.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            guard request == generation else { return }
            records = []
            message = SongImportRedactor.redact(error.localizedDescription)
        }
    }

    func load(_ id: String) async throws -> SongImportRecord {
        _ = try await reviewer()
        let snapshot = try await db.collection(collection).document(id).getDocument()
        guard snapshot.exists else { throw StoreError.missing }
        return try snapshot.data(as: SongImportRecord.self)
    }

    func create(sourceURL: String, title: String, artist: String, key: String) async throws -> SongImportRecord {
        let request = generation
        let actor = try await reviewer()
        let source = SongImportSource(url: sourceURL)
        let fields = SongImportFields(title: title, artist: artist, key: key, link: sourceURL)
        let record = SongImportRecord.staged(source: source, detectedFields: fields,
                                            existing: try await candidates(), actor: actor)
        guard record.validationWarnings.isEmpty else { throw StoreError.invalidInput(record.validationWarnings.joined(separator: " ")) }
        try await db.collection(collection).document(record.id).setData(Firestore.Encoder().encode(record))
        if request == generation { upsert(record) }
        return record
    }

    func update(_ record: SongImportRecord, fields: SongImportFields) async throws {
        let existing = try await candidates()
        try await mutate(record.id) { draft, actor in
            guard draft.updatedAt == record.updatedAt else { throw SongImportWorkflowError.stalePreview }
            try draft.edit(fields: fields, existing: existing, reviewer: actor)
        }
    }

    func reject(_ record: SongImportRecord, reason: String) async throws {
        try await mutate(record.id) { draft, actor in
            try draft.reject(reviewer: actor, reason: reason)
        }
    }

    func markStep(_ step: SongImportProcessingStep, state: SongImportStepState,
                  error: String? = nil, in record: SongImportRecord) async throws {
        try await mutate(record.id) { draft, actor in
            guard draft.mediaStatus.first(where: { $0.step == step })?.state != state else { return }
            try draft.recordStep(step, state: state, error: error, actor: actor)
        }
    }

    func queueRetry(_ record: SongImportRecord) async throws -> [SongImportProcessingStep] {
        var retried: [SongImportProcessingStep] = []
        try await mutate(record.id) { draft, actor in
            retried = try draft.queueRetryOfFailedSteps(reviewer: actor)
        }
        return retried
    }

    /// Storing translation is separate from publishing. The preview takes the
    /// returned revision; any later edit invalidates approval of that preview.
    func beginProcessing(_ record: SongImportRecord, fresh: Bool) async throws {
        try await mutate(record.id) { draft, actor in try draft.beginProcessing(fresh: fresh, actor: actor) }
    }

    func attachPayload(_ payload: Data, to record: SongImportRecord) async throws {
        _ = try SongImportPayload.validate(payload)
        try await mutate(record.id) { draft, actor in
            draft.publicationPayload = payload
            try draft.recordStep(.translation, state: .succeeded, actor: actor)
        }
    }

    func prepare(_ record: SongImportRecord, payload: Data) async throws -> SongImportRecord {
        _ = try SongImportPayload.validate(payload)
        let existing = try await candidates()
        return try await mutate(record.id) { draft, actor in
            guard draft.updatedAt == record.updatedAt else { throw SongImportWorkflowError.stalePreview }
            try draft.edit(fields: draft.reviewFields, existing: existing, reviewer: actor)
            draft.publicationPayload = payload
            try draft.recordStep(.translation, state: .succeeded, actor: actor)
        }
    }

    func approve(_ record: SongImportRecord) async throws -> String {
        let actor = try await reviewer()
        let existing = try await candidates()
        busyRecordID = record.id
        defer { busyRecordID = nil }
        let reference = db.collection(collection).document(record.id)
        let db = db
        let result = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let snapshot = try transaction.getDocument(reference)
                guard snapshot.exists else { throw StoreError.missing }
                var current = try snapshot.data(as: SongImportRecord.self)
                if current.status == .approved, let id = current.publishedSongID { return id }
                guard current.updatedAt == record.updatedAt,
                      current.publicationPayload == record.publicationPayload else {
                    throw SongImportWorkflowError.stalePreview
                }
                // Refresh duplicates immediately before approval. The canonical
                // target is also read inside this transaction to prevent races.
                current.duplicateCandidates = SongImportDuplicateDetector.candidates(
                    source: current.source, fields: current.reviewFields, among: existing,
                    excludingRecordIDs: Set([current.id, current.targetSongID].compactMap { $0 }))
                let id = try current.approve(expected: record, reviewer: actor)
                guard let data = current.publicationPayload else { throw SongImportWorkflowError.publicationPayloadMissing }
                var song = try SongImportPayload.validate(data)
                let songRef = db.collection("songs").document(id)
                let target = try transaction.getDocument(songRef)
                if current.targetSongID == nil {
                    guard !target.exists else { throw StoreError.existingSong }
                    song["title"] = current.reviewFields.title
                    song["artists"] = [["name": current.reviewFields.artist]]
                    song["key"] = current.reviewFields.key
                    song["link"] = current.reviewFields.link
                    song["createdBy"] = actor.id
                    song["createdAt"] = FieldValue.serverTimestamp()
                    song["timeSignature"] = SongImportPayload.timeSignature(song)
                    var source: [String: Any] = ["provider": current.source.provider, "stagingRecordID": current.id]
                    if let stable = current.source.stableIdentifier { source["stableIdentifier"] = stable }
                    song["importSource"] = source
                } else {
                    guard target.exists else { throw StoreError.missing }
                }
                song["updatedAt"] = FieldValue.serverTimestamp()
                transaction.setData(song, forDocument: songRef, merge: current.targetSongID != nil)
                transaction.setData(try Firestore.Encoder().encode(current), forDocument: reference)
                return id
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }
        guard let id = result as? String else { throw StoreError.invalidResult }
        if let published = try? await load(record.id) {
            upsert(published)
        } else if var published = records.first(where: { $0.id == record.id }) {
            published.status = .approved
            published.publishedSongID = id
            upsert(published)
        }
        return id
    }

    private func reviewer() async throws -> SongImportReviewer {
        guard let user = Auth.auth().currentUser else { throw StoreError.permissionDenied }
        let profile = try await db.collection("users").document(user.uid).getDocument()
        guard profile.data()?["isAdmin"] as? Bool == true else { throw StoreError.permissionDenied }
        return SongImportReviewer(id: user.uid, name: user.displayName ?? user.email ?? "Administrator", canReview: true)
    }

    @discardableResult
    private func mutate(_ id: String, operation: @escaping (inout SongImportRecord, SongImportReviewer) throws -> Void) async throws -> SongImportRecord {
        let actor = try await reviewer()
        let request = generation
        let reference = db.collection(collection).document(id)
        let result = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let snapshot = try transaction.getDocument(reference)
                guard snapshot.exists else { throw StoreError.missing }
                var current = try snapshot.data(as: SongImportRecord.self)
                try operation(&current, actor)
                transaction.setData(try Firestore.Encoder().encode(current), forDocument: reference)
                return try Firestore.Encoder().encode(current)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }
        guard let data = result as? [String: Any] else { throw StoreError.invalidResult }
        let record = try Firestore.Decoder().decode(SongImportRecord.self, from: data)
        if request == generation { upsert(record) }
        return record
    }

    private func upsert(_ record: SongImportRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
        records.sort { $0.updatedAt > $1.updatedAt }
    }

    private func candidates() async throws -> [SongImportCandidate] {
        async let staged = db.collection(collection).getDocuments()
        async let songs = db.collection("songs").getDocuments()
        let (stageSnapshot, songSnapshot) = try await (staged, songs)
        var result = try stageSnapshot.documents.map { try $0.data(as: SongImportRecord.self) }
            .filter { $0.status == .staged }.map {
                SongImportCandidate(recordID: $0.id, source: $0.source, fields: $0.reviewFields)
            }
        result += try songSnapshot.documents.map { document in
            let song = try document.data(as: FirebaseSong.self)
            return SongImportCandidate(recordID: document.documentID, source: SongImportSource(url: song.link ?? ""),
                                       fields: SongImportFields(title: song.title, artist: song.artists?.first?.name ?? "",
                                                                key: song.key ?? "", link: song.link ?? ""))
        }
        return result
    }
}
