import Foundation
import Security

@MainActor
struct KeychainCredentialStore {
    enum StorageError: Error, Equatable {
        case signingRequired
        case unavailable
        case invalidData
    }

    // Keep the Security calls replaceable so tests never touch a user's credentials.
    struct Operations {
        var read: (CFDictionary) -> (OSStatus, CFTypeRef?) = { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query, &result)
            return (status, result)
        }
        var add: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
        var update: (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) }
        var delete: (CFDictionary) -> OSStatus = { SecItemDelete($0) }
    }

    private let service: String
    private let operations: Operations

    init(
        service: String = (Bundle.main.bundleIdentifier ?? "dev.biros.pingit") + ".github",
        operations: Operations = Operations()
    ) {
        self.service = service
        self.operations = operations
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false
        ]
    }

    func load(account: String = "personal-access-token") throws -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = operations.read(query as CFDictionary)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw status == errSecMissingEntitlement ? StorageError.signingRequired : StorageError.unavailable
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw StorageError.invalidData
        }
        return token
    }

    func save(_ token: String, account: String = "personal-access-token") throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var item = query(account: account)
        item.merge(attributes) { _, new in new }
        var status = operations.add(item as CFDictionary)
        if status == errSecDuplicateItem {
            status = operations.update(query(account: account) as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw status == errSecMissingEntitlement ? StorageError.signingRequired : StorageError.unavailable
        }
    }

    func remove(account: String = "personal-access-token") throws {
        let status = operations.delete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw status == errSecMissingEntitlement ? StorageError.signingRequired : StorageError.unavailable
        }
    }
}
