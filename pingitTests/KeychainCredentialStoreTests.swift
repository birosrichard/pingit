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
