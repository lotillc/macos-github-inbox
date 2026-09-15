import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error (\(status))."
        case .invalidData:
            "The token in Keychain could not be decoded."
        }
    }
}

enum KeychainTokenAccessibility: Equatable {
    /// Keeps credentials off backups and other devices. The menu-bar app only reads
    /// GitHub credentials while the signed-in macOS user has unlocked the device.
    case whenUnlockedThisDeviceOnly

    var securityValue: CFString {
        switch self {
        case .whenUnlockedThisDeviceOnly:
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}

struct KeychainTokenStore {
    static let shared = KeychainTokenStore(
        service: "com.github-pr-inbox.github-app-auth",
        account: "github-app-device-flow-credential"
    )

    /// The exact item used by releases before the GitHub App migration. Keep this
    /// narrowly scoped so a migration can never remove an unrelated credential.
    private static let legacyPersonalAccessTokenStore = KeychainTokenStore(
        service: "com.github-pr-inbox.token",
        account: "github-personal-access-token"
    )

    let service: String
    let account: String
    let accessibility: KeychainTokenAccessibility

    init(
        service: String,
        account: String,
        accessibility: KeychainTokenAccessibility = .whenUnlockedThisDeviceOnly
    ) {
        self.service = service
        self.account = account
        self.accessibility = accessibility
    }

    func saveCredential(_ credential: GitHubCredential) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedCredential = try encoder.encode(credential)
        try save(data: encodedCredential)
    }

    func loadCredential() throws -> GitHubCredential? {
        guard let data = try loadData() else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try decoder.decode(GitHubCredential.self, from: data)
        } catch {
            throw KeychainStoreError.invalidData
        }
    }

    func deleteCredential() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func savePendingDeviceCredential(_ credential: PendingGitHubDeviceCredential) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try save(data: try encoder.encode(credential), account: pendingDeviceCredentialAccount)
    }

    func loadPendingDeviceCredential() throws -> PendingGitHubDeviceCredential? {
        guard let data = try loadData(account: pendingDeviceCredentialAccount) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PendingGitHubDeviceCredential.self, from: data)
        } catch {
            throw KeychainStoreError.invalidData
        }
    }

    func deletePendingDeviceCredential() throws {
        try deleteItem(account: pendingDeviceCredentialAccount)
    }

    /// Removes only the former PAT item. It is safe to invoke repeatedly, and is
    /// deliberately a no-op for injected test/alternate credential stores.
    func deleteLegacyPersonalAccessToken() throws {
        guard service == Self.shared.service, account == Self.shared.account else {
            return
        }
        try Self.legacyPersonalAccessTokenStore.deleteItem(account: Self.legacyPersonalAccessTokenStore.account)
    }

    func hasCredentials() -> Bool {
        (try? loadCredential()) != nil
    }

    private var pendingDeviceCredentialAccount: String {
        "\(account).pending-device-token"
    }

    private func save(data: Data, account: String? = nil) throws {
        let query = query(account: account)
        let updatedAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.securityValue,
        ]

        // Refresh-token rotation must not delete the working token before its
        // replacement is safely committed. Update first, then create the item only
        // when this is the user's first sign-in.
        let updateStatus = SecItemUpdate(query as CFDictionary, updatedAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var newItem = query
            newItem.merge(updatedAttributes) { _, replacement in replacement }

            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }
    }

    private func loadData(account: String? = nil) throws -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainStoreError.invalidData
        }

        return data
    }

    private func deleteItem(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] { query(account: nil) }

    private func query(account: String?) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account ?? self.account,
        ]
    }
}
