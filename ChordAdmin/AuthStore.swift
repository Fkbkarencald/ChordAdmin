//
//  AuthStore.swift
//  ChordAdmin
//

import Foundation
import Combine
import AuthenticationServices
import FirebaseAuth
import CryptoKit

@MainActor
final class AuthStore: NSObject, ObservableObject {
    @Published var user: FirebaseAuth.User?
    @Published var isSigningIn = false
    @Published var errorMessage: String?

    private var currentNonce: String?
    private var authListener: AuthStateDidChangeListenerHandle?

    override init() {
        super.init()
        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
            }
        }
    }

    deinit {
        if let listener = authListener {
            Auth.auth().removeStateDidChangeListener(listener)
        }
    }

    var isSignedIn: Bool { user != nil }

    func signInWithApple() {
        let nonce = randomNonceString()
        currentNonce = nonce
        isSigningIn = true
        errorMessage = nil

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func signOut() {
        do {
            try Auth.auth().signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Nonce helpers

    private func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        return randomBytes.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AuthStore: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard
            let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let appleIDToken = appleIDCredential.identityToken,
            let idTokenString = String(data: appleIDToken, encoding: .utf8)
        else {
            Task { @MainActor in self.isSigningIn = false }
            return
        }

        Task { @MainActor in
            guard let nonce = self.currentNonce else {
                self.isSigningIn = false
                return
            }
            let credential = OAuthProvider.credential(
                withProviderID: "apple.com",
                idToken: idTokenString,
                rawNonce: nonce
            )
            do {
                let result = try await Auth.auth().signIn(with: credential)
                self.user = result.user
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isSigningIn = false
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            if (error as? ASAuthorizationError)?.code != .canceled {
                self.errorMessage = error.localizedDescription
            }
            self.isSigningIn = false
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AuthStore: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        // presentationAnchor is called on the main thread per Apple documentation
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows[0]
        }
    }
}
