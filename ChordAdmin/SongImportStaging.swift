import Foundation

nonisolated enum SongImportStageStatus: String, Codable, CaseIterable, Sendable {
    case staged
    case approved
    case rejected
}

nonisolated enum SongImportProcessingStep: String, Codable, CaseIterable, Sendable {
    case download
    case conversion
    case analysis
    case cleanup
    case translation
    case publication

    var displayName: String {
        switch self {
        case .download: "Download"
        case .conversion: "Conversion"
        case .analysis: "Analysis"
        case .cleanup: "Cleanup"
        case .translation: "Translation"
        case .publication: "Publication"
        }
    }
}

nonisolated enum SongImportStepState: String, Codable, Sendable {
    case pending
    case running
    case succeeded
    case failed
    case skipped

    var isSuccessful: Bool { self == .succeeded || self == .skipped }
}

nonisolated enum SongImportHistoryOutcome: String, Codable, Sendable {
    case staged
    case edited
    case started
    case succeeded
    case failed
    case retryQueued
    case rejected
    case approved
}

nonisolated enum SongImportDuplicateReason: String, Codable, Sendable {
    case stableSourceIdentifier
    case normalizedTitleAndArtist
}

nonisolated struct SongImportSource: Codable, Equatable, Sendable {
    var provider: String
    var stableIdentifier: String?
    var url: String

    init(url: String, provider: String? = nil, stableIdentifier: String? = nil) {
        let detected = SongImportNormalizer.sourceIdentity(from: url)
        self.provider = (provider ?? detected.provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.stableIdentifier = (stableIdentifier ?? detected.stableIdentifier)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        if detected.provider == "youtube", let videoID = detected.stableIdentifier {
            var canonical = URLComponents()
            canonical.scheme = "https"
            canonical.host = "www.youtube.com"
            canonical.path = "/watch"
            canonical.queryItems = [URLQueryItem(name: "v", value: videoID)]
            self.url = canonical.string ?? url.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

nonisolated struct SongImportFields: Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var key: String
    var link: String

    init(title: String, artist: String, key: String = "", link: String) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.link = SongImportSource(url: link).url
    }
}

nonisolated struct SongImportDuplicateCandidate: Codable, Equatable, Identifiable, Sendable {
    var id: String { recordID }
    var recordID: String
    var title: String
    var artist: String
    var reason: SongImportDuplicateReason
}

nonisolated struct SongImportMediaStatus: Codable, Equatable, Identifiable, Sendable {
    var id: SongImportProcessingStep { step }
    var step: SongImportProcessingStep
    var state: SongImportStepState
    var updatedAt: Date
    var redactedError: String?
}

nonisolated struct SongImportHistoryEvent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var occurredAt: Date
    var actorID: String
    var actorName: String
    var step: SongImportProcessingStep?
    var outcome: SongImportHistoryOutcome
    var detail: String
}

nonisolated struct SongImportReviewer: Equatable, Sendable {
    var id: String
    var name: String
    var canReview: Bool
}

nonisolated enum SongImportAuthorization {
    static func canReview(
        profileIsAdmin: Bool,
        tokenAdmin: Bool,
        roles: [String]
    ) -> Bool {
        profileIsAdmin
            || tokenAdmin
            || roles.contains("chordAdmin")
            || roles.contains("songReviewer")
    }
}

nonisolated struct SongImportRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var source: SongImportSource
    var detectedFields: SongImportFields
    var reviewFields: SongImportFields
    var status: SongImportStageStatus
    var mediaStatus: [SongImportMediaStatus]
    var validationWarnings: [String]
    var duplicateCandidates: [SongImportDuplicateCandidate]
    var targetSongID: String?
    var publishedSongID: String?
    var publicationPayload: Data?
    var createdAt: Date
    var updatedAt: Date
    var history: [SongImportHistoryEvent]

    static func staged(
        id: String = UUID().uuidString,
        source: SongImportSource,
        detectedFields: SongImportFields,
        existing: [SongImportCandidate] = [],
        targetSongID: String? = nil,
        publicationPayload: Data? = nil,
        actor: SongImportReviewer,
        now: Date = Date()
    ) -> SongImportRecord {
        let warnings = SongImportValidator.warnings(for: detectedFields, source: source)
        let duplicates = SongImportDuplicateDetector.candidates(
            source: source,
            fields: detectedFields,
            among: existing,
            excludingRecordIDs: Set([targetSongID].compactMap { $0 })
        )
        let initialState: SongImportStepState = publicationPayload == nil ? .pending : .succeeded
        var mediaStatus = SongImportProcessingStep.allCases.map {
            SongImportMediaStatus(step: $0, state: .pending, updatedAt: now, redactedError: nil)
        }
        for index in mediaStatus.indices where mediaStatus[index].step != .publication {
            mediaStatus[index].state = initialState
        }
        return SongImportRecord(
            id: id,
            source: source,
            detectedFields: detectedFields,
            reviewFields: detectedFields,
            status: .staged,
            mediaStatus: mediaStatus,
            validationWarnings: warnings,
            duplicateCandidates: duplicates,
            targetSongID: targetSongID,
            publishedSongID: nil,
            publicationPayload: publicationPayload,
            createdAt: now,
            updatedAt: now,
            history: [SongImportHistoryEvent(
                id: UUID().uuidString,
                occurredAt: now,
                actorID: actor.id,
                actorName: actor.name,
                step: nil,
                outcome: .staged,
                detail: "Import staged for review."
            )]
        )
    }

    mutating func edit(
        fields: SongImportFields,
        existing: [SongImportCandidate] = [],
        reviewer: SongImportReviewer,
        now: Date = Date()
    ) throws {
        try requireReviewPermission(reviewer)
        guard status == .staged else { throw SongImportWorkflowError.notReviewable }
        reviewFields = fields
        validationWarnings = SongImportValidator.warnings(for: fields, source: source)
        duplicateCandidates = SongImportDuplicateDetector.candidates(
            source: source,
            fields: fields,
            among: existing,
            excludingRecordIDs: Set([id, targetSongID].compactMap { $0 })
        )
        updatedAt = now
        appendHistory(
            actor: reviewer,
            step: nil,
            outcome: .edited,
            detail: "Reviewed metadata updated.",
            now: now
        )
    }

    mutating func recordStep(
        _ step: SongImportProcessingStep,
        state: SongImportStepState,
        error: String? = nil,
        actor: SongImportReviewer,
        now: Date = Date()
    ) throws {
        try requireReviewPermission(actor)
        guard status == .staged else { throw SongImportWorkflowError.notReviewable }
        let redacted = error.map(SongImportRedactor.redact)
        if let index = mediaStatus.firstIndex(where: { $0.step == step }) {
            mediaStatus[index] = SongImportMediaStatus(
                step: step,
                state: state,
                updatedAt: now,
                redactedError: redacted
            )
        } else {
            mediaStatus.append(SongImportMediaStatus(
                step: step,
                state: state,
                updatedAt: now,
                redactedError: redacted
            ))
        }
        updatedAt = now
        appendHistory(
            actor: actor,
            step: step,
            outcome: state.historyOutcome,
            detail: redacted ?? state.rawValue,
            now: now
        )
    }

    mutating func beginProcessing(fresh: Bool, actor: SongImportReviewer) throws {
        try requireReviewPermission(actor)
        guard status == .staged else { throw SongImportWorkflowError.notReviewable }
        publicationPayload = nil
        for step in SongImportProcessingStep.allCases where step != .publication && (fresh || [.cleanup, .translation].contains(step)) {
            try recordStep(step, state: .pending, actor: actor)
        }
    }

    mutating func queueRetryOfFailedSteps(
        reviewer: SongImportReviewer,
        now: Date = Date()
    ) throws -> [SongImportProcessingStep] {
        try requireReviewPermission(reviewer)
        guard status == .staged else { throw SongImportWorkflowError.notReviewable }
        let failed = mediaStatus.filter { $0.state == .failed }.map(\.step)
        guard !failed.isEmpty else { throw SongImportWorkflowError.noFailedSteps }
        for step in failed {
            if let index = mediaStatus.firstIndex(where: { $0.step == step }) {
                mediaStatus[index].state = .pending
                mediaStatus[index].redactedError = nil
                mediaStatus[index].updatedAt = now
            }
            appendHistory(
                actor: reviewer,
                step: step,
                outcome: .retryQueued,
                detail: "Failed step queued for retry.",
                now: now
            )
        }
        updatedAt = now
        return failed
    }

    mutating func reject(
        reviewer: SongImportReviewer,
        reason: String,
        now: Date = Date()
    ) throws {
        try requireReviewPermission(reviewer)
        guard status == .staged else { throw SongImportWorkflowError.notReviewable }
        status = .rejected
        updatedAt = now
        appendHistory(
            actor: reviewer,
            step: nil,
            outcome: .rejected,
            detail: SongImportRedactor.redact(reason),
            now: now
        )
    }

    @discardableResult
    mutating func approve(
        expected: SongImportRecord? = nil,
        reviewer: SongImportReviewer,
        now: Date = Date()
    ) throws -> String {
        try requireReviewPermission(reviewer)
        if status == .approved, let publishedSongID { return publishedSongID }
        if let expected, updatedAt != expected.updatedAt || publicationPayload != expected.publicationPayload {
            throw SongImportWorkflowError.stalePreview
        }
        guard status == .staged else { throw SongImportWorkflowError.notReviewable }
        guard validationWarnings.isEmpty else {
            throw SongImportWorkflowError.validationWarningsRemain
        }
        guard duplicateCandidates.isEmpty else { throw SongImportWorkflowError.duplicatesRemain }
        guard publicationPayload != nil else {
            throw SongImportWorkflowError.publicationPayloadMissing
        }
        let blockingSteps = mediaStatus.filter {
            $0.step != .publication && !$0.state.isSuccessful
        }
        guard blockingSteps.isEmpty else { throw SongImportWorkflowError.processingIncomplete }

        let canonicalID = SongImportNormalizer.canonicalSongID(
            targetSongID: targetSongID,
            source: source,
            stagingID: id
        )
        status = .approved
        publishedSongID = canonicalID
        updatedAt = now
        if let index = mediaStatus.firstIndex(where: { $0.step == .publication }) {
            mediaStatus[index] = SongImportMediaStatus(
                step: .publication,
                state: .succeeded,
                updatedAt: now,
                redactedError: nil
            )
        }
        appendHistory(
            actor: reviewer,
            step: .publication,
            outcome: .approved,
            detail: "Approved as canonical song \(canonicalID).",
            now: now
        )
        return canonicalID
    }

    private func requireReviewPermission(_ reviewer: SongImportReviewer) throws {
        guard reviewer.canReview else { throw SongImportWorkflowError.permissionDenied }
    }

    private mutating func appendHistory(
        actor: SongImportReviewer,
        step: SongImportProcessingStep?,
        outcome: SongImportHistoryOutcome,
        detail: String,
        now: Date
    ) {
        history.append(SongImportHistoryEvent(
            id: UUID().uuidString,
            occurredAt: now,
            actorID: actor.id,
            actorName: actor.name,
            step: step,
            outcome: outcome,
            detail: detail
        ))
    }
}

nonisolated struct SongImportCandidate: Equatable, Sendable {
    var recordID: String
    var source: SongImportSource
    var fields: SongImportFields
}

nonisolated enum SongImportWorkflowError: LocalizedError, Equatable {
    case permissionDenied
    case notReviewable
    case noFailedSteps
    case validationWarningsRemain
    case publicationPayloadMissing
    case processingIncomplete
    case duplicatesRemain
    case stalePreview

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "You are not authorised to review song imports."
        case .notReviewable: "This import is no longer open for review."
        case .noFailedSteps: "This import has no failed processing steps to retry."
        case .validationWarningsRemain: "Resolve validation warnings before approval."
        case .publicationPayloadMissing: "The staged publication payload is missing."
        case .processingIncomplete: "Processing must finish before approval."
        case .duplicatesRemain: "This source may already exist. Open the existing song instead of publishing a duplicate."
        case .stalePreview: "This import changed while the preview was open. Prepare a fresh preview."
        }
    }
}

nonisolated enum SongImportValidator {
    static func warnings(for fields: SongImportFields, source: SongImportSource) -> [String] {
        var warnings: [String] = []
        if fields.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("A song title is required.")
        }
        if fields.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("An artist is required.")
        }
        let sourceURL = URL(string: source.url)
        let validScheme = sourceURL?.scheme == "http" || sourceURL?.scheme == "https"
        if !validScheme || sourceURL?.host?.isEmpty != false {
            warnings.append("The source URL must use HTTP or HTTPS.")
        }
        let canonicalURL = URL(string: fields.link)
        let validCanonicalScheme = canonicalURL?.scheme == "http" || canonicalURL?.scheme == "https"
        if !validCanonicalScheme || canonicalURL?.host?.isEmpty != false {
            warnings.append("A canonical song link using HTTP or HTTPS is required.")
        }
        if source.provider != "youtube" || source.stableIdentifier == nil {
            warnings.append("Use a YouTube video URL for analysis.")
        }
        let reviewedSource = SongImportSource(url: fields.link)
        if reviewedSource.provider != source.provider || reviewedSource.stableIdentifier != source.stableIdentifier {
            warnings.append("The reviewed link must refer to the original source video. Stage a new import to change the source.")
        }
        return warnings
    }
}

nonisolated enum SongImportDuplicateDetector {
    static func candidates(
        source: SongImportSource,
        fields: SongImportFields,
        among existing: [SongImportCandidate],
        excludingRecordIDs: Set<String> = []
    ) -> [SongImportDuplicateCandidate] {
        let normalizedTitle = SongImportNormalizer.normalized(fields.title)
        let normalizedArtist = SongImportNormalizer.normalized(fields.artist)
        return existing.compactMap { candidate in
            guard !excludingRecordIDs.contains(candidate.recordID) else { return nil }
            let stableSourceMatch = source.provider == candidate.source.provider
                && source.stableIdentifier != nil
                && source.stableIdentifier == candidate.source.stableIdentifier
            let metadataMatch = !normalizedTitle.isEmpty
                && !normalizedArtist.isEmpty
                && normalizedTitle == SongImportNormalizer.normalized(candidate.fields.title)
                && normalizedArtist == SongImportNormalizer.normalized(candidate.fields.artist)
            guard stableSourceMatch || metadataMatch else { return nil }
            return SongImportDuplicateCandidate(
                recordID: candidate.recordID,
                title: candidate.fields.title,
                artist: candidate.fields.artist,
                reason: stableSourceMatch ? .stableSourceIdentifier : .normalizedTitleAndArtist
            )
        }
    }
}

nonisolated enum SongImportNormalizer {
    static func sourceIdentity(from rawURL: String) -> (provider: String, stableIdentifier: String?) {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ("unknown", nil)
        }
        let host = (url.host ?? "").lowercased()
        if host == "youtu.be" {
            return ("youtube", url.pathComponents.dropFirst().first?.nonEmpty)
        }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            let queryVideoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "v" })?
                .value?
                .nonEmpty
            let pathComponents = url.pathComponents.filter { $0 != "/" }
            let pathVideoID = pathComponents.count >= 2
                && ["shorts", "embed", "live"].contains(pathComponents[0])
                ? pathComponents[1].nonEmpty
                : nil
            return ("youtube", queryVideoID ?? pathVideoID)
        }
        return (host.nonEmpty ?? "unknown", nil)
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    static func canonicalSongID(
        targetSongID: String?,
        source: SongImportSource,
        stagingID: String
    ) -> String {
        if let targetSongID = targetSongID?.nonEmpty { return targetSongID }
        if let stableID = source.stableIdentifier?.nonEmpty {
            return "\(source.provider)-\(sanitizedIdentifier(stableID))"
        }
        return "import-\(sanitizedIdentifier(stagingID))"
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        let value = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }
        let joined = String(value)
        return joined.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

nonisolated enum SongImportRedactor {
    static func redact(_ raw: String) -> String {
        var result = raw
        let patterns = [
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)\b(authorization|token|api[_ -]?key|password|secret|credential)\s*[:=]\s*[^\s,;]+"#,
            #"(?i)([?&](?:token|api_key|key|secret|password)=)[^&#\s]+"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            if pattern.hasPrefix("(?i)([?&]") {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: "$1<redacted>"
                )
            } else {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: "<redacted>"
                )
            }
        }
        return String(result.prefix(1_000))
    }
}

private extension SongImportStepState {
    nonisolated var historyOutcome: SongImportHistoryOutcome {
        switch self {
        case .pending, .running: .started
        case .succeeded, .skipped: .succeeded
        case .failed: .failed
        }
    }
}

private extension String {
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}

