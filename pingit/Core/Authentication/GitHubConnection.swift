import Foundation
import Observation

@MainActor
@Observable
final class GitHubConnection {
    let dashboard: PullRequestDashboard
    private(set) var connections: [GitHubTokenConnection] = []
    private(set) var isConnecting = false
    private(set) var hasSavedCredential = false
    private(set) var errorMessage: String?
    var account: GitHubAccount? { connections.compactMap(\.account).first }

    private let client: GitHubClient
    private let credentials: KeychainCredentialStore
    private let metadata: GitHubConnectionMetadata
    @ObservationIgnored private var hasRestored = false
    @ObservationIgnored private var snapshot = GitHubConnectionMetadata.Snapshot()
    @ObservationIgnored private var generation = UUID()

    init(client: GitHubClient = GitHubClient(), credentials: KeychainCredentialStore? = nil,
         metadata: GitHubConnectionMetadata? = nil) {
        let store = credentials ?? KeychainCredentialStore()
        self.client = client
        self.credentials = store
        self.metadata = metadata ?? GitHubConnectionMetadata(defaults: credentials == nil ? .standard : nil)
        dashboard = PullRequestDashboard(credentials: store, discovery: GitHubPullRequestDiscovery(client: client))
    }

    func restore() async {
        guard !hasRestored else { return }
        hasRestored = true
        await reconnectSavedAccount()
    }

    func reconnectSavedAccount() async {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            snapshot = try metadata.migrate(credentials: credentials)
            for reference in snapshot.pendingDeletions { try credentials.remove(account: reference) }
            snapshot.pendingDeletions = []
            try metadata.save(snapshot)
            connections = snapshot.connections
            hasSavedCredential = !connections.isEmpty
            let currentGeneration = generation
            // Validation is bounded to one request; discovery remains independently concurrent.
            for index in connections.indices {
                do {
                    guard let token = try credentials.load(account: connections[index].storageAccount) else {
                        throw GitHubAPIError.invalidToken
                    }
                    let validated = try await client.authenticatedAccount(token: token)
                    try Task.checkCancellation()
                    guard generation == currentGeneration else { return }
                    if let identity = connections.compactMap(\.account).first,
                       !Self.sameUser(identity, validated) { throw GitHubDiscoveryError.accountMismatch }
                    connections[index].account = validated
                    connections[index].validatedAt = Date()
                    connections[index].status = "Authenticated · owner unverified"
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == currentGeneration else { return }
                    connections[index].status = Self.message(error)
                    errorMessage = Self.message(error)
                }
            }
            snapshot.connections = connections
            try metadata.save(snapshot)
            updateDashboard(refresh: false)
        } catch {
            hasSavedCredential = true
            errorMessage = Self.message(error)
        }
    }

    func connect(token input: String, resourceOwner inputOwner: String = "", replacing id: UUID? = nil) async {
        guard !isConnecting else { return }
        hasRestored = true
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        let currentGeneration = generation
        let owner = inputOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let validated = try await client.authenticatedAccount(token: token)
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            if let identity = account, !Self.sameUser(identity, validated) {
                errorMessage = "This token belongs to another GitHub account. Add a token for @\(identity.login)."
                return
            }
            let label = owner.isEmpty ? validated.login : owner
            guard !connections.contains(where: {
                $0.id != id && $0.resourceOwner.caseInsensitiveCompare(label) == .orderedSame
            }) else {
                errorMessage = "A token for this resource owner already exists. Replace that connection instead."
                return
            }
            // Establish the migration ledger before adding any credentials.
            snapshot = try metadata.migrate(credentials: credentials)
            if let id, !connections.contains(where: { $0.id == id }) { return }
            let previous = connections.first(where: { $0.id == id })
            var row = GitHubTokenConnection(id: id ?? UUID(), account: validated, resourceOwner: label,
                                            validatedAt: Date(), status: "Authenticated · owner unverified")
            if previous != nil { row.credentialID = UUID() }
            do {
                try credentials.save(token, account: row.storageAccount)
                guard try credentials.load(account: row.storageAccount) == token else {
                    throw KeychainCredentialStore.StorageError.invalidData
                }
                var next = snapshot
                next.connections = connections.filter { $0.id != id } + [row]
                if let previous { next.pendingDeletions.append(previous.storageAccount) }
                try metadata.save(next)
                snapshot = next
            } catch {
                // A failed replacement never overwrites the previous credential.
                try? credentials.remove(account: row.storageAccount)
                errorMessage = "Couldn’t save the token in macOS Keychain or connection metadata. Unlock your keychain and retry."
                return
            }
            connections = snapshot.connections
            hasSavedCredential = true
            updateDashboard(refresh: previous != nil || connections.count > 1)
            cleanupCredentials()
        } catch is CancellationError {
            // A cancelled validation cannot save a credential.
        } catch { errorMessage = Self.message(error) }
    }

    func remove(_ id: UUID) {
        guard let row = connections.first(where: { $0.id == id }) else { return }
        do {
            // Record deletion intent first, so interrupted removal is retried on launch.
            var next = snapshot
            next.connections = connections.filter { $0.id != id }
            next.pendingDeletions.append(row.storageAccount)
            try metadata.save(next)
            do { try credentials.remove(account: row.storageAccount) }
            catch {
                try metadata.save(snapshot)
                throw error
            }
            generation = UUID()
            snapshot = next
            connections = next.connections
            hasSavedCredential = !connections.isEmpty
            errorMessage = nil
            updateDashboard(refresh: true)
            cleanupCredentials()
        } catch { errorMessage = Self.message(error) }
    }

    func disconnect() {
        guard !isConnecting else { return }
        for row in connections { remove(row.id) }
    }

    private func cleanupCredentials() {
        do {
            for reference in snapshot.pendingDeletions { try credentials.remove(account: reference) }
            snapshot.pendingDeletions = []
            try metadata.save(snapshot)
        } catch { errorMessage = "Connection updated; old credential cleanup needs a retry in Settings." }
    }

    private func updateDashboard(refresh: Bool) {
        dashboard.setConnections(connections, refresh: refresh)
    }

    private static func sameUser(_ lhs: GitHubAccount, _ rhs: GitHubAccount) -> Bool {
        if let left = lhs.id, let right = rhs.id { return left == right }
        return lhs.login.caseInsensitiveCompare(rhs.login) == .orderedSame
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? GitHubAPIError { return error.localizedDescription }
        if let error = error as? GitHubDiscoveryError { return error.localizedDescription }
        if let error = error as? KeychainCredentialStore.StorageError, error == .signingRequired {
            return "This build can’t access Keychain. In Xcode, enable Keychain Sharing and resolve Signing & Capabilities issues, then rebuild."
        }
        return "Couldn’t read or update macOS Keychain or connection metadata. Unlock your keychain and retry."
    }
}

// Only non-secret metadata is Codable. IDs never derive from credentials.
struct GitHubTokenConnection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var credentialID: UUID? = nil
    var account: GitHubAccount?
    var resourceOwner: String
    var validatedAt: Date?
    var status: String = "Not validated"
    var storageAccount: String { "connection-" + (credentialID ?? id).uuidString.lowercased() }
}

@MainActor
final class GitHubConnectionMetadata {
    struct Snapshot: Codable {
        var connections: [GitHubTokenConnection] = []
        var pendingDeletions: [String] = []
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
