import Foundation
import Security
import Testing

@MainActor
struct GitHubConnectionTests {
    @Test func connectsPersistsAndDisconnects() async throws {
        let keychain = MockKeychain()
        let http = MockHTTP()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
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
        await connection.restore()
        await connection.restore()
        #expect(connection.account?.login == "octocat")
        #expect(connection.hasSavedCredential)
        #expect(keychain.reads == 1)
        #expect(keychain.adds == 1)
        #expect(!connection.isConnecting)
    }

    @Test func restoreWithoutTokenDoesNotCallGitHub() async {
        let keychain = MockKeychain()
        let http = MockHTTP { _ in
            Issue.record("Missing credentials must not reach networking")
            throw URLError(.badURL)
        }
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        await connection.restore()
        #expect(connection.account == nil)
        #expect(!connection.hasSavedCredential)
        #expect(connection.errorMessage == nil)
    }

    @Test func expiredSavedTokenIsRemoved() async throws {
        let keychain = MockKeychain()
        try keychain.store.save("expired-test-token")
        let http = MockHTTP(status: 401)
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        await connection.restore()
        #expect(connection.account == nil)
        #expect(!connection.hasSavedCredential)
        #expect(keychain.token == nil)
        #expect(keychain.deletes == 1)
        #expect(connection.errorMessage == GitHubAPIError.invalidToken.localizedDescription)
    }

    @Test func expiredTokenRemovalFailureAllowsDisconnectRetry() async throws {
        let keychain = MockKeychain()
        try keychain.store.save("expired-test-token")
        keychain.deleteStatus = errSecAuthFailed
        let http = MockHTTP(status: 401)
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        await connection.restore()
        #expect(connection.hasSavedCredential)
        #expect(connection.errorMessage?.contains("couldn’t be removed") == true)
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
        await connection.restore()
        #expect(connection.account == nil)
        #expect(connection.hasSavedCredential)
        #expect(keychain.token == "test-token")
        #expect(keychain.deletes == 0)
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
        await connection.restore()
        #expect(connection.account == nil)
        #expect(connection.hasSavedCredential)
        #expect(keychain.token == "test-token")
        #expect(keychain.deletes == 0)
        #expect(connection.errorMessage != nil)
    }

    @Test func keychainReadFailureIsRecoverable() async {
        let keychain = MockKeychain()
        keychain.readStatus = errSecInteractionNotAllowed
        let http = MockHTTP()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
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
        await connection.restore()
        #expect(connection.errorMessage?.contains("Signing & Capabilities") == true)
        #expect(connection.account == nil)
    }

    @Test func failedDisconnectPreservesAccountUntilRemovalSucceeds() async {
        let keychain = MockKeychain()
        let http = MockHTTP()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
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
