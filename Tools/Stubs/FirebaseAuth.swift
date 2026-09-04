// Typecheck-only stub of FirebaseAuth. Not part of the app target.
import Foundation

public final class User: NSObject, @unchecked Sendable {
    public var uid: String { "" }
    public var email: String? { nil }
    public var displayName: String? { nil }
}

public protocol AuthCredential: AnyObject, Sendable {}

public final class OAuthCredential: NSObject, AuthCredential, @unchecked Sendable {}

public enum OAuthProvider {
    public static func credential(
        withProviderID providerID: String,
        idToken: String,
        rawNonce: String?
    ) -> OAuthCredential {
        OAuthCredential()
    }
}

public final class AuthDataResult: NSObject, @unchecked Sendable {
    public var user: User { User() }
}

public final class AuthStateDidChangeListenerHandle: NSObject, @unchecked Sendable {}

public final class Auth: NSObject, @unchecked Sendable {
    public static func auth() -> Auth { Auth() }
    public var currentUser: User? { nil }

    @discardableResult
    public func addStateDidChangeListener(
        _ listener: @escaping @Sendable (Auth, User?) -> Void
    ) -> AuthStateDidChangeListenerHandle {
        AuthStateDidChangeListenerHandle()
    }

    public func removeStateDidChangeListener(_ listenerHandle: AuthStateDidChangeListenerHandle) {}

    public func signIn(with credential: AuthCredential) async throws -> AuthDataResult {
        AuthDataResult()
    }

    public func signOut() throws {}
}
