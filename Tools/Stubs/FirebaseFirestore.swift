// Typecheck-only stub of FirebaseFirestore. Not part of the app target.
import Foundation

public let FirestoreErrorDomain: String = "FIRFirestoreErrorDomain"

public enum FirestoreErrorCode: Int, Sendable {
    case ok = 0
    case cancelled = 1
    case unknown = 2
    case permissionDenied = 7
    case unavailable = 14
    case notFound = 5
}

@propertyWrapper
public struct DocumentID<Value>: Sendable, Codable, Hashable
where Value: Codable & Hashable & Sendable {
    public var wrappedValue: Value?

    public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        self.wrappedValue = try? Value(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try wrappedValue?.encode(to: encoder)
    }
}

public final class DocumentSnapshot: NSObject, @unchecked Sendable {
    public var documentID: String { "" }
    public var exists: Bool { true }
    public func data() -> [String: Any]? { nil }
    public func data<T: Decodable>(as type: T.Type) throws -> T {
        throw NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.notFound.rawValue)
    }
}

public final class QueryDocumentSnapshot: NSObject, @unchecked Sendable {
    public var documentID: String { "" }
    public func data() -> [String: Any] { [:] }
    public func data<T: Decodable>(as type: T.Type) throws -> T {
        throw NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.notFound.rawValue)
    }
}

public final class QuerySnapshot: NSObject, @unchecked Sendable {
    public var documents: [QueryDocumentSnapshot] { [] }
    public var count: Int { 0 }
    public var isEmpty: Bool { true }
}

public final class DocumentReference: NSObject, @unchecked Sendable {
    public var documentID: String { "" }
    public func updateData(_ fields: [String: Any]) async throws {}
    public func setData(_ documentData: [String: Any], merge: Bool = false) async throws {}
    public func getDocument() async throws -> DocumentSnapshot { DocumentSnapshot() }
    public func delete() async throws {}
}

public class Query: NSObject, @unchecked Sendable {
    public func order(by field: String, descending: Bool = false) -> Query { self }
    public func limit(to limit: Int) -> Query { self }
    public func whereField(_ field: String, isEqualTo value: Any) -> Query { self }
    public func getDocuments() async throws -> QuerySnapshot { QuerySnapshot() }
}

public final class CollectionReference: Query, @unchecked Sendable {
    public func document(_ documentPath: String) -> DocumentReference { DocumentReference() }
    public func addDocument(data: [String: Any]) async throws -> DocumentReference {
        DocumentReference()
    }
}

public final class Firestore: NSObject, @unchecked Sendable {
    public static func firestore() -> Firestore { Firestore() }
    public func collection(_ collectionPath: String) -> CollectionReference { CollectionReference() }
    public func document(_ documentPath: String) -> DocumentReference { DocumentReference() }
}
