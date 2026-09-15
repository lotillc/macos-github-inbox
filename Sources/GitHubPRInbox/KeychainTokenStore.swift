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

    func hasCredentials() -> Bool {
        (try? loadCredential()) != nil
    }

    private func save(data: Data) throws {
        let updatedAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.securityValue,
        ]

        // Refresh-token rotation must not delete the working token before its
        // replacement is safely committed. Update first, then create the item only
        // when this is the user's first sign-in.
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updatedAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var newItem = baseQuery
            newItem.merge(updatedAttributes) { _, replacement in replacement }

            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }
    }

    private func loadData() throws -> Data? {
        var query = baseQuery
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

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
