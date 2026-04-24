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
        service: "com.github-pr-inbox.token",
        account: "github-personal-access-token"
    )

    let service: String
    let account: String

    func save(token: String) throws {
        let encodedToken = Data(token.utf8)

        let query = baseQuery as CFDictionary
        SecItemDelete(query)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: encodedToken,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func loadToken() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return ""
        default:
            throw KeychainStoreError.unexpectedStatus(status)
        }

        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }

        return token
    }

    func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func hasToken() -> Bool {
        ((try? loadToken().isEmpty) == false)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
