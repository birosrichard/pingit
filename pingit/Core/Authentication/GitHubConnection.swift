import Foundation
import Observation

@MainActor
@Observable
final class GitHubConnection {
    private(set) var account: GitHubAccount?
    private(set) var isConnecting = false
    private(set) var hasSavedCredential = false
    private(set) var errorMessage: String?

    private let client: GitHubClient
    private let credentials: KeychainCredentialStore
    @ObservationIgnored private var hasRestored = false

    init(client: GitHubClient = GitHubClient(), credentials: KeychainCredentialStore = KeychainCredentialStore()) {
        self.client = client
        self.credentials = credentials
    }

    func restore() async {
        guard !hasRestored else { return }
        hasRestored = true
        await reconnectSavedAccount()
    }

    func reconnectSavedAccount() async {
        guard !isConnecting, account == nil else { return }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            guard let token = try credentials.load() else {
                hasSavedCredential = false
                return
            }
            hasSavedCredential = true
            let account = try await client.authenticatedAccount(token: token)
            try Task.checkCancellation()
            self.account = account
        } catch is CancellationError {
            // Retain the saved credential for an explicit retry after cancellation.
        } catch GitHubAPIError.invalidToken {
            do {
                try credentials.remove()
                hasSavedCredential = false
                errorMessage = GitHubAPIError.invalidToken.localizedDescription
            } catch {
                errorMessage = keychainError(error, fallback: "The saved token is invalid, but couldn’t be removed from Keychain. Unlock your keychain and disconnect.")
            }
        } catch let error as GitHubAPIError {
            // Offline and rate-limit failures do not invalidate the saved credential.
            errorMessage = error.localizedDescription
        } catch {
            hasSavedCredential = true
            errorMessage = keychainError(error, fallback: "Couldn’t read macOS Keychain. Unlock your keychain and retry, or disconnect to remove the saved token.")
        }
    }

    func connect(token input: String) async {
        guard !isConnecting, account == nil else { return }
        hasRestored = true
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let account = try await client.authenticatedAccount(token: token)
            try Task.checkCancellation()
            do {
                try credentials.save(token)
            } catch {
                errorMessage = keychainError(error, fallback: "Couldn’t save the token in macOS Keychain. Unlock your keychain and connect again.")
                return
            }
            hasSavedCredential = true
            self.account = account
        } catch is CancellationError {
            // A cancelled attempt must not save credentials or display an error.
        } catch let error as GitHubAPIError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = GitHubAPIError.unexpectedResponse.localizedDescription
        }
    }

    private func keychainError(_ error: Error, fallback: String) -> String {
        if let error = error as? KeychainCredentialStore.StorageError, error == .signingRequired {
            return "This build can’t access Keychain. Select a development team in Xcode with Keychain Sharing enabled, then rebuild."
        }
        return fallback
    }

    func disconnect() {
        guard !isConnecting else { return }
        do {
            try credentials.remove()
            account = nil
            hasSavedCredential = false
            errorMessage = nil
        } catch {
            errorMessage = keychainError(error, fallback: "Couldn’t remove the token from macOS Keychain. Unlock your keychain and disconnect again.")
        }
    }
}
