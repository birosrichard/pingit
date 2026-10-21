import Foundation
import Observation

@MainActor
@Observable
final class GitHubConnection {
    let dashboard: PullRequestDashboard
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
        dashboard = PullRequestDashboard(credentials: credentials, discovery: GitHubPullRequestDiscovery(client: client))
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
            dashboard.setAccount(account)
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
            dashboard.setAccount(account)
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
            return "This build can’t access Keychain. In Xcode, enable Keychain Sharing and resolve Signing & Capabilities issues, then rebuild."
        }
        return fallback
    }

    func disconnect() {
        guard !isConnecting else { return }
        do {
            try credentials.remove()
            account = nil
            dashboard.setAccount(nil)
            hasSavedCredential = false
            errorMessage = nil
        } catch {
            errorMessage = keychainError(error, fallback: "Couldn’t remove the token from macOS Keychain. Unlock your keychain and disconnect again.")
        }
    }
}

// Only non-secret metadata is Codable. IDs never derive from credentials.
struct GitHubTokenConnection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var account: GitHubAccount?
    var resourceOwner: String
    var validatedAt: Date?
    var status: String = "Not validated"
    var storageAccount: String { "connection-" + id.uuidString.lowercased() }
}

@MainActor
final class GitHubConnectionMetadata {
    struct Snapshot: Codable {
        var connections: [GitHubTokenConnection] = []
        var migrationID: UUID?
        var migrationComplete = false
    }
    private let defaults: UserDefaults?
    private var memory = Snapshot()
    private let key = "github.connections.v1"

    init(defaults: UserDefaults? = nil) { self.defaults = defaults }

    func migrate(credentials: KeychainCredentialStore) throws -> Snapshot {
        var snapshot = try load()
        guard !snapshot.migrationComplete else { return snapshot }
        guard let legacy = try credentials.load() else {
            snapshot.migrationComplete = true
            try save(snapshot)
            return snapshot
        }
        let id = snapshot.migrationID ?? UUID()
        snapshot.migrationID = id
        try save(snapshot)
        let row = GitHubTokenConnection(id: id, account: nil, resourceOwner: "Legacy token")
        let existing = try credentials.load(account: row.storageAccount)
        if existing == nil { try credentials.save(legacy, account: row.storageAccount) }
        guard try credentials.load(account: row.storageAccount) == legacy else {
            throw KeychainCredentialStore.StorageError.invalidData
        }
        if !snapshot.connections.contains(where: { $0.id == id }) {
            snapshot.connections.append(row)
        }
        try save(snapshot)
        try credentials.remove()
        snapshot.migrationComplete = true
        try save(snapshot)
        return snapshot
    }

    func load() throws -> Snapshot {
        guard let defaults, let data = defaults.data(forKey: key) else { return memory }
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(_ snapshot: Snapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        if let defaults {
            defaults.set(data, forKey: key)
            // Verify the metadata before a migration is allowed to delete credentials.
            guard defaults.data(forKey: key) == data else { throw KeychainCredentialStore.StorageError.unavailable }
        }
        memory = snapshot
    }
}
