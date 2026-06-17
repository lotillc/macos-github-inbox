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

struct KeychainTokenStore {
    static let shared = KeychainTokenStore(
        service: "com.github-pr-inbox.github-app-auth",
        account: "github-app-device-flow-credential"
    )

    let service: String
    let account: String

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
        let query = baseQuery as CFDictionary
        SecItemDelete(query)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
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
