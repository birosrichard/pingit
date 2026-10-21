import Foundation
import Security
import Testing

@MainActor
struct GitHubConnectionTests {
    @Test func connectsPersistsAndDisconnects() async throws {
        let keychain = MockKeychain()
        let http = MockHTTP()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.connect(token: "  test-token\n")
        #expect(connection.account?.login == "octocat")
        #expect(connection.hasSavedCredential)
        #expect(keychain.token == "test-token")
        #expect(!connection.isConnecting)
        #expect(connection.errorMessage == nil)
        connection.disconnect()
        #expect(connection.account == nil)
        #expect(!connection.hasSavedCredential)
        #expect(try keychain.store.load() == nil)
    }

    @Test func failedValidationNeverSaves() async {
        let keychain = MockKeychain()
        let http = MockHTTP(status: 401)
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.connect(token: "test-token")
        #expect(keychain.adds == 0)
        #expect(connection.account == nil)
        #expect(!connection.isConnecting)
        #expect(connection.errorMessage == GitHubAPIError.invalidToken.localizedDescription)
    }

    @Test func storageFailureDoesNotConnect() async {
        let keychain = MockKeychain()
        keychain.addStatus = errSecAuthFailed
        let http = MockHTTP()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.connect(token: "test-token")
        #expect(connection.account == nil)
        #expect(!connection.hasSavedCredential)
        #expect(connection.errorMessage?.contains("Couldn’t save") == true)
        #expect(!connection.isConnecting)
    }

    @Test func restoresExistingConnectionOnlyOnce() async throws {
        let keychain = MockKeychain()
        try keychain.store.save("test-token")
        let http = MockHTTP()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.restore()
        await connection.restore()
        #expect(connection.account?.login == "octocat")
        #expect(connection.hasSavedCredential)
        #expect(keychain.reads == 4)
        #expect(keychain.adds == 2)
        #expect(!connection.isConnecting)
    }

    @Test func restoreWithoutTokenDoesNotCallGitHub() async {
        let keychain = MockKeychain()
        let http = MockHTTP { _ in
            Issue.record("Missing credentials must not reach networking")
            throw URLError(.badURL)
        }
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.restore()
        #expect(connection.account == nil)
        #expect(!connection.hasSavedCredential)
        #expect(connection.errorMessage == nil)
    }

    @Test func expiredSavedTokenRemainsAvailableForReplacement() async throws {
        let keychain = MockKeychain()
        try keychain.store.save("expired-test-token")
        let http = MockHTTP(status: 401)
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.restore()
        #expect(connection.account == nil)
        #expect(connection.hasSavedCredential)
        #expect(keychain.token == "expired-test-token")
        #expect(connection.connections.count == 1)
        #expect(keychain.deletes == 1) // Only the verified legacy copy was removed.
        #expect(connection.errorMessage == GitHubAPIError.invalidToken.localizedDescription)
    }

    @Test func expiredTokenRemovalFailureAllowsDisconnectRetry() async throws {
        let keychain = MockKeychain()
        try keychain.store.save("expired-test-token")
        keychain.deleteStatus = errSecAuthFailed
        let http = MockHTTP(status: 401)
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.restore()
        #expect(connection.hasSavedCredential)
        #expect(connection.errorMessage != nil)
        keychain.deleteStatus = nil
        connection.disconnect()
        #expect(keychain.token == nil)
        #expect(connection.errorMessage == nil)
    }

    @Test func transientRestoreFailureRetainsTokenForRetry() async throws {
        let keychain = MockKeychain()
        try keychain.store.save("test-token")
        let attempts = RequestCounter()
        let http = MockHTTP { request in
            if attempts.next() == 1 { throw URLError(.notConnectedToInternet) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(MockHTTP.accountJSON.utf8))
        }
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.restore()
        #expect(connection.account == nil)
        #expect(connection.hasSavedCredential)
        #expect(keychain.token == "test-token")
        #expect(keychain.deletes == 1) // Legacy cleanup; scoped credential remains.
        #expect(connection.errorMessage == GitHubAPIError.networkUnavailable.localizedDescription)
        await connection.reconnectSavedAccount()
        #expect(connection.account?.login == "octocat")
        #expect(connection.errorMessage == nil)
    }

    @Test(arguments: [403, 429, 500]) func serverFailurePreservesSavedToken(status: Int) async throws {
        let keychain = MockKeychain()
        try keychain.store.save("test-token")
        let http = MockHTTP(status: status)
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.restore()
        #expect(connection.account == nil)
        #expect(connection.hasSavedCredential)
        #expect(keychain.token == "test-token")
        #expect(keychain.deletes == 1) // Legacy cleanup; scoped credential remains.
        #expect(connection.errorMessage != nil)
    }

    @Test func keychainReadFailureIsRecoverable() async {
        let keychain = MockKeychain()
        keychain.readStatus = errSecInteractionNotAllowed
        let http = MockHTTP()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.restore()
        #expect(connection.hasSavedCredential)
        #expect(!connection.isConnecting)
        #expect(connection.errorMessage?.contains("Couldn’t read") == true)
        keychain.readStatus = nil
        await connection.reconnectSavedAccount()
        #expect(!connection.hasSavedCredential)
        #expect(connection.errorMessage == nil)
    }

    @Test func missingSigningEntitlementExplainsHowToFixTheBuild() async {
        let keychain = MockKeychain()
        keychain.readStatus = errSecMissingEntitlement
        let http = MockHTTP()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.restore()
        #expect(connection.errorMessage?.contains("Signing & Capabilities") == true)
        #expect(connection.account == nil)
    }

    @Test func failedDisconnectPreservesAccountUntilRemovalSucceeds() async {
        let keychain = MockKeychain()
        let http = MockHTTP()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.connect(token: "test-token")
        keychain.deleteStatus = errSecAuthFailed
        connection.disconnect()
        #expect(connection.account?.login == "octocat")
        #expect(connection.hasSavedCredential)
        #expect(keychain.token != nil)
        #expect(connection.errorMessage?.contains("Couldn’t remove") == true)
        keychain.deleteStatus = nil
        connection.disconnect()
        #expect(connection.account == nil)
        #expect(keychain.token == nil)
    }

    @Test(arguments: [false, true]) func inFlightAttemptAndCancellation(cancel: Bool) async {
        let keychain = MockKeychain()
        let gate = DispatchSemaphore(value: 0)
        let (requests, continuation) = AsyncStream<Void>.makeStream()
        let http = MockHTTP { request in
            continuation.yield(())
            guard gate.wait(timeout: .now() + 5) == .success else {
                throw URLError(.timedOut)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(MockHTTP.accountJSON.utf8))
        }
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        let attempt = Task { await connection.connect(token: "test-token") }
        for await _ in requests { break }
        #expect(connection.isConnecting)
        await connection.connect(token: "duplicate-test-token")
        await connection.restore()
        connection.disconnect()
        #expect(keychain.adds == 0)
        #expect(keychain.deletes == 0)
        if cancel { attempt.cancel() }
        gate.signal()
        await attempt.value
        #expect(!connection.isConnecting)
        #expect(connection.errorMessage == nil)
        #expect(keychain.adds == (cancel ? 0 : 1))
        #expect(connection.account?.login == (cancel ? nil : "octocat"))
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

@MainActor
struct MultiTokenAuthenticationTests {
    @Test func twoScopesSameUserAndIndependentRemoval() async throws {
        let keychain = MockKeychain()
        let http = MockHTTP()
        let metadata = GitHubConnectionMetadata()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store, metadata: metadata)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.connect(token: "personal-fixture", resourceOwner: "octocat")
        await connection.connect(token: "organization-fixture", resourceOwner: "apify")
        #expect(connection.connections.count == 2)
        #expect(Set(connection.connections.compactMap { $0.account?.login }) == ["octocat"])
        let personal = try #require(connection.connections.first)
        let organization = try #require(connection.connections.last)
        #expect(personal.id != organization.id)
        #expect(try keychain.store.load(account: personal.storageAccount) == "personal-fixture")
        #expect(try keychain.store.load(account: organization.storageAccount) == "organization-fixture")
        #expect(try keychain.store.load() == nil)
        connection.remove(organization.id)
        #expect(connection.connections == [personal])
        #expect(try keychain.store.load(account: organization.storageAccount) == nil)
        #expect(try keychain.store.load(account: personal.storageAccount) == "personal-fixture")
        let restarted = GitHubConnection(client: http.client, credentials: keychain.store, metadata: metadata)
        await restarted.restore()
        #expect(restarted.connections.map(\.id) == [personal.id])
        #expect(restarted.account?.login == "octocat")
    }

    @Test(arguments: [false, true]) func rejectsAnotherIdentity(withIDs: Bool) async {
        let keychain = MockKeychain()
        let http = MockHTTP { request in
            let other = request.value(forHTTPHeaderField: "Authorization") == "Bearer other-fixture"
            let body = withIDs
                ? "{\"id\":\(other ? 2 : 1),\"login\":\"same-login\",\"avatar_url\":\"https://avatars.githubusercontent.com/u/1\"}"
                : "{\"login\":\"\(other ? "another-user" : "octocat")\",\"avatar_url\":\"https://avatars.githubusercontent.com/u/1\"}"
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.connect(token: "personal-fixture", resourceOwner: "personal")
        await connection.connect(token: "other-fixture", resourceOwner: "apify")
        #expect(connection.connections.count == 1)
        #expect(keychain.items.count == 1)
        #expect(connection.errorMessage?.contains("another GitHub account") == true)
    }

    @Test func duplicateOwnerAndDuplicateCredentialAreRejected() async {
        let keychain = MockKeychain()
        let http = MockHTTP()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.connect(token: "personal-fixture", resourceOwner: "Apify")
        await connection.connect(token: "another-fixture", resourceOwner: " apify ")
        #expect(connection.errorMessage?.contains("resource owner already exists") == true)
        await connection.connect(token: "personal-fixture", resourceOwner: "different-label")
        #expect(connection.errorMessage?.contains("already connected") == true)
        #expect(connection.connections.count == 1)
        #expect(keychain.items.count == 1)
    }

    @Test func replacementKeepsStableIDAndChangesCredentialReference() async throws {
        let keychain = MockKeychain()
        let http = MockHTTP()
        let metadata = GitHubConnectionMetadata()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store, metadata: metadata)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.connect(token: "old-fixture", resourceOwner: "apify")
        let original = try #require(connection.connections.first)
        await connection.connect(token: "new-fixture", resourceOwner: "apify", replacing: original.id)
        let replaced = try #require(connection.connections.first)
        #expect(replaced.id == original.id)
        #expect(replaced.storageAccount != original.storageAccount)
        #expect(try keychain.store.load(account: original.storageAccount) == nil)
        #expect(try keychain.store.load(account: replaced.storageAccount) == "new-fixture")
        let snapshot = try metadata.load()
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!encoded.contains("old-fixture") && !encoded.contains("new-fixture"))
        #expect(snapshot.connections == [replaced])
    }

    @Test func failedReplacementPreservesOldCredential() async throws {
        let keychain = MockKeychain()
        let http = MockHTTP()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.connect(token: "old-fixture", resourceOwner: "apify")
        let original = try #require(connection.connections.first)
        keychain.addStatus = errSecAuthFailed
        await connection.connect(token: "new-fixture", resourceOwner: "apify", replacing: original.id)
        #expect(connection.connections == [original])
        #expect(try keychain.store.load(account: original.storageAccount) == "old-fixture")
        #expect(connection.errorMessage != nil)
    }

    @Test func invalidSecondTokenDoesNotAffectExistingConnection() async {
        let keychain = MockKeychain()
        let validHTTP = MockHTTP()
        let metadata = GitHubConnectionMetadata()
        let original = GitHubConnection(client: validHTTP.client, credentials: keychain.store, metadata: metadata)
        await original.connect(token: "personal-fixture")
        let invalidHTTP = MockHTTP(status: 401)
        let connection = GitHubConnection(client: invalidHTTP.client, credentials: keychain.store, metadata: metadata)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.restore()
        await connection.connect(token: "invalid-fixture", resourceOwner: "apify")
        #expect(connection.connections.count == 1)
        #expect(keychain.items.count == 1)
        #expect(connection.errorMessage == GitHubAPIError.invalidToken.localizedDescription)
    }

    @Test func emptyAndValidationStates() async {
        let keychain = MockKeychain()
        let http = MockHTTP(status: 401)
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        #expect(connection.connections.isEmpty && !connection.isConnecting)
        await connection.connect(token: "invalid-fixture", resourceOwner: "apify")
        #expect(!connection.isConnecting && connection.errorMessage != nil)
        #expect(connection.connections.isEmpty && keychain.items.isEmpty)
    }
}

extension MultiTokenAuthenticationTests {
    @Test func expiredLegacyTokenCanBeExplicitlyReplaced() async throws {
        let keychain = MockKeychain()
        try keychain.store.save("expired-fixture")
        let invalidHTTP = MockHTTP(status: 401)
        let metadata = GitHubConnectionMetadata()
        let old = GitHubConnection(client: invalidHTTP.client, credentials: keychain.store, metadata: metadata)
        await old.restore()
        let row = try #require(old.connections.first)
        let validHTTP = MockHTTP { request in
            let status = request.value(forHTTPHeaderField: "Authorization") == "Bearer expired-fixture" ? 401 : 200
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(MockHTTP.accountJSON.utf8))
        }
        let connection = GitHubConnection(client: validHTTP.client, credentials: keychain.store, metadata: metadata)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.restore()
        #expect(connection.account == nil)
        await connection.connect(token: "replacement-fixture", resourceOwner: "apify", replacing: row.id)
        #expect(connection.connections.count == 1)
        #expect(connection.connections.first?.id == row.id)
        #expect(connection.account?.login == "octocat")
        #expect(connection.errorMessage == nil)
        #expect(keychain.items.count == 1)
    }

    @Test func realClientContextsKeepAuthorizationSeparateAndPartialFailureVisible() async throws {
        let keychain = MockKeychain()
        let http = MockHTTP { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            #expect(authorization == "Bearer personal-fixture" || authorization == "Bearer organization-fixture")
            let status: Int
            let body: String
            if request.url?.path == "/user" {
                status = 200
                body = MockHTTP.accountJSON
            } else if authorization == "Bearer organization-fixture" {
                status = 403
                body = #"{"message":"Resource not accessible by personal access token"}"#
            } else {
                status = 200
                body = #"{"data":{"viewer":{"login":"octocat"},"search":{"issueCount":0,"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#
            }
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.connect(token: "personal-fixture", resourceOwner: "personal")
        await connection.connect(token: "organization-fixture", resourceOwner: "apify")
        let deadline = ContinuousClock.now + .seconds(5)
        while connection.dashboard.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!connection.dashboard.isLoading)
        #expect(connection.connections.count == 2)
        let personal = try #require(connection.connections.first)
        let organization = try #require(connection.connections.last)
        #expect(connection.dashboard.sources[personal.id]?.authored.phase == .loaded)
        #expect(connection.dashboard.sources[organization.id]?.authored.phase == .failed)
        #expect(connection.dashboard.authored.errorMessage?.contains("apify: GitHub denied access") == true)
        #expect(connection.dashboard.authored.result?.coverageLimitations == [.tokenVisibility])
    }
}

extension MultiTokenAuthenticationTests {
    @Test func uncertainMetadataWriteKeepsBothCredentialsForRecovery() async throws {
        let name = "pingit-tests-" + UUID().uuidString
        let defaults = try #require(FailingSyncDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = MockKeychain()
        let http = MockHTTP()
        let metadata = GitHubConnectionMetadata(defaults: defaults)
        let connection = GitHubConnection(client: http.client, credentials: keychain.store, metadata: metadata)
        defer { connection.dashboard.setConnections([], refresh: false) }
        await connection.connect(token: "old-fixture", resourceOwner: "apify")
        let row = try #require(connection.connections.first)
        defaults.failSync = true
        await connection.connect(token: "new-fixture", resourceOwner: "apify", replacing: row.id)
        #expect(connection.errorMessage != nil)
        #expect(keychain.items.count == 2)
        #expect(try keychain.store.load(account: row.storageAccount) == "old-fixture")
        defaults.failSync = false
        let restarted = GitHubConnection(client: http.client, credentials: keychain.store, metadata: metadata)
        await restarted.restore()
        let recovered = try #require(restarted.connections.first)
        #expect(recovered.id == row.id)
        #expect(try keychain.store.load(account: recovered.storageAccount) == "new-fixture")
        #expect(keychain.items.count == 1)
        #expect(restarted.errorMessage == nil)
    }
}

// Used only on the main actor; model the ambiguous failure after UserDefaults.set succeeds.
private final class FailingSyncDefaults: UserDefaults {
    var failSync = false
    override func synchronize() -> Bool { failSync ? false : super.synchronize() }
}
