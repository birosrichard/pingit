import Foundation
import Security
import Testing

@MainActor
struct KeychainCredentialStoreTests {
    @Test func storageReplacementAndRemoval() throws {
        let keychain = MockKeychain()
        let store = keychain.store
        #expect(try store.load() == nil)
        try store.save("first-test-token")
        #expect(try store.load() == "first-test-token")
        #expect(keychain.item?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(keychain.item?[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(keychain.item?[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(keychain.item?[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(keychain.item?[kSecAttrService as String] as? String == "dev.biros.pingit.tests")
        #expect(keychain.item?[kSecAttrAccount as String] as? String == "personal-access-token")
        #expect(keychain.lastQuery[kSecReturnData as String] as? Bool == true)
        #expect(keychain.lastQuery[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        try store.save("replacement-test-token")
        #expect(try store.load() == "replacement-test-token")
        #expect(keychain.updates == 1)
        try store.remove()
        #expect(try store.load() == nil)
        #expect(keychain.lastQuery[kSecAttrService as String] as? String == "dev.biros.pingit.tests")
        try store.remove() // Removing a missing item is idempotent.
    }

    @Test func keychainFailuresPropagate() {
        let keychain = MockKeychain()
        keychain.readStatus = errSecInteractionNotAllowed
        #expect(throws: KeychainCredentialStore.StorageError.unavailable) { try keychain.store.load() }
        keychain.addStatus = errSecAuthFailed
        #expect(throws: KeychainCredentialStore.StorageError.unavailable) { try keychain.store.save("test-token") }
        keychain.addStatus = errSecDuplicateItem
        keychain.updateStatus = errSecAuthFailed
        #expect(throws: KeychainCredentialStore.StorageError.unavailable) { try keychain.store.save("test-token") }
        keychain.deleteStatus = errSecAuthFailed
        #expect(throws: KeychainCredentialStore.StorageError.unavailable) { try keychain.store.remove() }
    }

    @Test func missingSigningEntitlementIsDistinct() {
        let keychain = MockKeychain()
        keychain.readStatus = errSecMissingEntitlement
        keychain.addStatus = errSecMissingEntitlement
        keychain.deleteStatus = errSecMissingEntitlement
        #expect(throws: KeychainCredentialStore.StorageError.signingRequired) { try keychain.store.load() }
        #expect(throws: KeychainCredentialStore.StorageError.signingRequired) { try keychain.store.save("test-token") }
        #expect(throws: KeychainCredentialStore.StorageError.signingRequired) { try keychain.store.remove() }
    }

    @Test(arguments: [Data(), Data([0xFF])]) func rejectsCorruptCredentials(data: Data) {
        let keychain = MockKeychain()
        keychain.item = [kSecValueData as String: data]
        #expect(throws: KeychainCredentialStore.StorageError.invalidData) { try keychain.store.load() }
    }
}

@MainActor
struct MultiTokenMigrationTests {
    @Test func migratesAndRepeatedMigrationDoesNotDuplicate() throws {
        let keychain = MockKeychain()
        try keychain.store.save("legacy-fixture")
        let metadata = GitHubConnectionMetadata()
        let migrated = try metadata.migrate(credentials: keychain.store)
        let row = try #require(migrated.connections.first)
        #expect(migrated.migrationComplete)
        #expect(try keychain.store.load() == nil)
        #expect(try keychain.store.load(account: row.storageAccount) == "legacy-fixture")
        let adds = keychain.adds
        #expect(try metadata.migrate(credentials: keychain.store).connections == migrated.connections)
        #expect(keychain.adds == adds)
        #expect(keychain.items.count == 1)
    }

    @Test(arguments: [false, true]) func interruptedMigrationRecovers(afterMetadataWrite: Bool) throws {
        let keychain = MockKeychain()
        try keychain.store.save("legacy-fixture")
        let metadata = GitHubConnectionMetadata()
        let row = GitHubTokenConnection(id: UUID(), account: nil, resourceOwner: "Legacy token")
        var pending = GitHubConnectionMetadata.Snapshot()
        pending.migrationID = row.id
        if afterMetadataWrite { pending.connections = [row] }
        try metadata.save(pending)
        try keychain.store.save("legacy-fixture", account: row.storageAccount)
        let recovered = try metadata.migrate(credentials: keychain.store)
        #expect(recovered.connections.map(\.id) == [row.id])
        #expect(recovered.migrationComplete)
        #expect(try keychain.store.load(account: row.storageAccount) == "legacy-fixture")
        #expect(keychain.items.count == 1)
    }

    @Test func interruptionAfterLegacyDeletionRetainsReplacement() throws {
        let keychain = MockKeychain()
        let metadata = GitHubConnectionMetadata()
        let row = GitHubTokenConnection(id: UUID(), account: nil, resourceOwner: "Legacy token")
        try keychain.store.save("legacy-fixture", account: row.storageAccount)
        var pending = GitHubConnectionMetadata.Snapshot()
        pending.migrationID = row.id
        pending.connections = [row]
        try metadata.save(pending)
        let recovered = try metadata.migrate(credentials: keychain.store)
        #expect(recovered.connections == [row])
        #expect(recovered.migrationComplete)
        #expect(try keychain.store.load(account: row.storageAccount) == "legacy-fixture")
    }

    @Test func missingLegacyIsAnEmptySuccessfulMigration() throws {
        let keychain = MockKeychain()
        let snapshot = try GitHubConnectionMetadata().migrate(credentials: keychain.store)
        #expect(snapshot.connections.isEmpty && snapshot.migrationComplete)
        #expect(keychain.adds == 0 && keychain.deletes == 0)
    }

    @Test func writeFailurePreservesLegacyAndRetryUsesSameID() throws {
        let keychain = MockKeychain()
        try keychain.store.save("legacy-fixture")
        keychain.addStatus = errSecAuthFailed
        let metadata = GitHubConnectionMetadata()
        #expect(throws: KeychainCredentialStore.StorageError.unavailable) {
            try metadata.migrate(credentials: keychain.store)
        }
        let pendingID = try #require(metadata.load().migrationID)
        #expect(try keychain.store.load() == "legacy-fixture")
        #expect(keychain.deletes == 0)
        keychain.addStatus = nil
        #expect(try metadata.migrate(credentials: keychain.store).connections.first?.id == pendingID)
    }

    @Test func inaccessibleLegacyIsNotAnEmptySuccess() throws {
        let keychain = MockKeychain()
        try keychain.store.save("legacy-fixture")
        keychain.readStatus = errSecInteractionNotAllowed
        let metadata = GitHubConnectionMetadata()
        #expect(throws: KeychainCredentialStore.StorageError.unavailable) {
            try metadata.migrate(credentials: keychain.store)
        }
        #expect(try !metadata.load().migrationComplete)
        #expect(keychain.deletes == 0 && keychain.items.count == 1)
    }

    @Test func collisionNeverOverwritesOrDeletesEitherCredential() throws {
        let keychain = MockKeychain()
        let metadata = GitHubConnectionMetadata()
        let row = GitHubTokenConnection(id: UUID(), account: nil, resourceOwner: "Legacy token")
        var pending = GitHubConnectionMetadata.Snapshot()
        pending.migrationID = row.id
        try metadata.save(pending)
        try keychain.store.save("legacy-fixture")
        try keychain.store.save("other-fixture", account: row.storageAccount)
        #expect(throws: KeychainCredentialStore.StorageError.invalidData) {
            try metadata.migrate(credentials: keychain.store)
        }
        #expect(try keychain.store.load() == "legacy-fixture")
        #expect(try keychain.store.load(account: row.storageAccount) == "other-fixture")
        #expect(keychain.deletes == 0)
    }

    @Test func legacyDeleteFailureIsRetryableWithoutRewritingReplacement() throws {
        let keychain = MockKeychain()
        try keychain.store.save("legacy-fixture")
        keychain.deleteStatus = errSecAuthFailed
        let metadata = GitHubConnectionMetadata()
        #expect(throws: KeychainCredentialStore.StorageError.unavailable) {
            try metadata.migrate(credentials: keychain.store)
        }
        #expect(keychain.items.count == 2)
        let writes = keychain.adds
        keychain.deleteStatus = nil
        let recovered = try metadata.migrate(credentials: keychain.store)
        #expect(recovered.migrationComplete && recovered.connections.count == 1)
        #expect(keychain.adds == writes && keychain.items.count == 1)
    }

    @Test func metadataSurvivesNewStoreAndCorruptionDoesNotEraseCredentials() throws {
        let name = "pingit-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = MockKeychain()
        try keychain.store.save("legacy-fixture")
        let metadata = GitHubConnectionMetadata(defaults: defaults)
        let migrated = try metadata.migrate(credentials: keychain.store)
        #expect(try GitHubConnectionMetadata(defaults: defaults).load().connections == migrated.connections)
        defaults.set(Data("broken".utf8), forKey: "github.connections.v1")
        #expect(throws: (any Error).self) { try metadata.migrate(credentials: keychain.store) }
        #expect(keychain.items.count == 1)
    }
}

extension MultiTokenMigrationTests {
    @Test func verificationReadFailureRetainsLegacyAndRecovers() throws {
        let keychain = MockKeychain()
        try keychain.store.save("legacy-fixture")
        keychain.readFailureAt = 3
        let metadata = GitHubConnectionMetadata()
        #expect(throws: KeychainCredentialStore.StorageError.unavailable) {
            try metadata.migrate(credentials: keychain.store)
        }
        #expect(keychain.deletes == 0 && keychain.items.count == 2)
        #expect(try keychain.store.load() == "legacy-fixture")
        let recovered = try metadata.migrate(credentials: keychain.store)
        #expect(recovered.migrationComplete && recovered.connections.count == 1)
        #expect(keychain.items.count == 1)
    }
}

extension MultiTokenMigrationTests {
    @Test func inconsistentMetadataCannotDeleteActiveCredential() throws {
        let metadata = GitHubConnectionMetadata()
        let row = GitHubTokenConnection(id: UUID(), account: nil, resourceOwner: "personal")
        var snapshot = GitHubConnectionMetadata.Snapshot()
        snapshot.connections = [row, row]
        #expect(throws: KeychainCredentialStore.StorageError.invalidData) { try metadata.save(snapshot) }
        snapshot.connections = [row]
        snapshot.pendingDeletions = [row.storageAccount]
        #expect(throws: KeychainCredentialStore.StorageError.invalidData) { try metadata.save(snapshot) }
        #expect(try metadata.load().connections.isEmpty)
    }
}
