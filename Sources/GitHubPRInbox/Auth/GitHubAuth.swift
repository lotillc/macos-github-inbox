import Foundation

struct GitHubAuthConfiguration: Equatable {
    static let clientIDEnvironmentKey = "GITHUB_APP_CLIENT_ID"
    static let appSlugEnvironmentKey = "GITHUB_APP_SLUG"
    static let expectedOwnersEnvironmentKey = "GITHUB_APP_EXPECTED_OWNERS"

    static let clientIDInfoKey = "GitHubAppClientID"
    static let appSlugInfoKey = "GitHubAppSlug"
    static let expectedOwnersInfoKey = "GitHubAppExpectedOwners"

    let clientID: String
    let appSlug: String
    let expectedOwners: [String]

    static func load(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> GitHubAuthConfiguration {
        func trimmed(_ value: String?) -> String {
            value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        func value(environmentKey: String, infoKey: String) -> String {
            let environmentValue = trimmed(processInfo.environment[environmentKey])
            if !environmentValue.isEmpty {
                return environmentValue
            }

            return trimmed(bundle.object(forInfoDictionaryKey: infoKey) as? String)
        }

        let expectedOwnersValue = value(
            environmentKey: Self.expectedOwnersEnvironmentKey,
            infoKey: Self.expectedOwnersInfoKey
        )

        return GitHubAuthConfiguration(
            clientID: value(environmentKey: Self.clientIDEnvironmentKey, infoKey: Self.clientIDInfoKey),
            appSlug: value(environmentKey: Self.appSlugEnvironmentKey, infoKey: Self.appSlugInfoKey),
            expectedOwners: expectedOwnersValue
                .split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    var missingConfigurationMessage: String? {
        var missingFields: [String] = []

        if clientID.isEmpty {
            missingFields.append("GitHub App client ID")
        }

        if appSlug.isEmpty {
            missingFields.append("GitHub App slug")
        }

        guard !missingFields.isEmpty else {
            return nil
        }

        return "Configure \(missingFields.joined(separator: " and ")) before signing in."
    }

    var appInstallationURL: URL? {
        guard !appSlug.isEmpty else {
            return nil
        }

        return URL(string: "https://github.com/apps/\(appSlug)/installations/new")
    }
}

struct GitHubDeviceAuthorization: Codable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let browserURL: URL
    let expiresAt: Date
    let interval: TimeInterval
}

struct GitHubCredential: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let accessTokenExpiresAt: Date?
    let refreshTokenExpiresAt: Date?
    let userID: Int
    let userLogin: String
    let authorizedOwners: [String]
    let accessibleRepositories: [String]
    let lastValidatedAt: Date?

    func updating(validation: GitHubAccessValidation) -> GitHubCredential {
        GitHubCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            userID: userID,
            userLogin: userLogin,
            authorizedOwners: validation.authorizedOwners,
            accessibleRepositories: validation.accessibleRepositories,
            lastValidatedAt: Date()
        )
    }
}

struct GitHubSessionSummary: Equatable {
    let user: GitHubUser
    let tokenExpiresAt: Date?
    let refreshTokenExpiresAt: Date?
    let authorizedOwners: [String]
    let accessibleRepositories: [String]
}

enum GitHubAuthenticationState: Equatable {
    case missingConfiguration(String)
    case signedOut
    case authorizing(GitHubDeviceAuthorization)
    case signedIn(GitHubSessionSummary)
    case refreshFailed(String)
    case ssoRequired([String], String)
    case installationMissing([String], String)

    var isAuthenticated: Bool {
        if case .signedIn = self {
            return true
        }

        return false
    }

    var guidanceText: String {
        switch self {
        case let .missingConfiguration(message):
            return message
        case .signedOut:
            return "Sign in with GitHub in Settings to load pull requests."
        case .authorizing:
            return "Finish GitHub sign-in in Settings."
        case .signedIn:
            return ""
        case let .refreshFailed(message):
            return message
        case let .ssoRequired(_, message):
            return message
        case let .installationMissing(_, message):
            return message
        }
    }
}

struct GitHubAccessValidation: Equatable {
    let authorizedOwners: [String]
    let accessibleRepositories: [String]
    let missingOwners: [String]
    let missingRepositories: [String]
}

enum GitHubAuthPollingResult: Equatable {
    case pending(GitHubDeviceAuthorization)
    case completed(GitHubCredential)
}

enum GitHubAuthError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case signedOut
    case pendingAuthorizationRequired
    case authorizationDenied(String)
    case authorizationExpired(String)
    case refreshFailed(String)
    case ssoRequired([String], String)
    case installationMissing([String], [String], String)
    case invalidResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case let .missingConfiguration(message),
             let .authorizationDenied(message),
             let .authorizationExpired(message),
             let .refreshFailed(message),
             let .ssoRequired(_, message),
             let .installationMissing(_, _, message),
             let .invalidResponse(message),
             let .network(message):
            return message
        case .signedOut:
            return "Sign in with GitHub in Settings."
        case .pendingAuthorizationRequired:
            return "Start GitHub sign-in before polling for completion."
        }
    }
}

actor GitHubAuthProvider {
    nonisolated let configuration: GitHubAuthConfiguration

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: URL
        let verificationURIComplete: URL?
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?
        let refreshTokenExpiresIn: Int?
        let tokenType: String?
        let error: String?
        let errorDescription: String?
        let interval: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case refreshTokenExpiresIn = "refresh_token_expires_in"
            case tokenType = "token_type"
            case error
            case errorDescription = "error_description"
            case interval
        }
    }

    private struct APIErrorResponse: Decodable {
        let message: String
    }

    private struct UserResponse: Decodable {
        let id: Int
        let login: String
    }

    private struct InstallationsResponse: Decodable {
        let installations: [Installation]
    }

    private struct Installation: Decodable {
        let id: Int
        let account: InstallationAccount
        let repositorySelection: String?

        enum CodingKeys: String, CodingKey {
            case id
            case account
            case repositorySelection = "repository_selection"
        }
    }

    private struct InstallationAccount: Decodable {
        let login: String
    }

    private struct InstallationRepositoriesResponse: Decodable {
        let repositories: [AccessibleRepository]
    }

    private struct AccessibleRepository: Decodable {
        let fullName: String

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }

    private let session: URLSession
    private let tokenStore: KeychainTokenStore
    private let decoder: JSONDecoder
    private var pendingAuthorization: GitHubDeviceAuthorization?

    init(
        configuration: GitHubAuthConfiguration = .load(),
        session: URLSession = .shared,
        tokenStore: KeychainTokenStore = .shared
    ) {
        self.configuration = configuration
        self.session = session
        self.tokenStore = tokenStore

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func currentCredential() throws -> GitHubCredential? {
        try tokenStore.loadCredential()
    }

    func pendingAuthorizationState() -> GitHubDeviceAuthorization? {
        pendingAuthorization
    }

    func startSignIn(expectedScopes: [RepositoryScope]) async throws -> GitHubDeviceAuthorization {
        try ensureConfigured()

        let url = URL(string: "https://github.com/login/device/code")!
        let request = try formRequest(
            url: url,
            parameters: ["client_id": configuration.clientID]
        )
        let data = try await send(request)
        let response = try decode(DeviceCodeResponse.self, from: data)

        let authorization = GitHubDeviceAuthorization(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURL: response.verificationURI,
            browserURL: response.verificationURIComplete ?? response.verificationURI,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            interval: TimeInterval(response.interval)
        )

        pendingAuthorization = authorization
        return authorization
    }

    func pollSignIn(expectedScopes: [RepositoryScope]) async throws -> GitHubAuthPollingResult {
        try ensureConfigured()

        guard var authorization = pendingAuthorization else {
            throw GitHubAuthError.pendingAuthorizationRequired
        }

        if authorization.expiresAt <= Date() {
            pendingAuthorization = nil
            throw GitHubAuthError.authorizationExpired("The GitHub sign-in code expired. Start again.")
        }

        let url = URL(string: "https://github.com/login/oauth/access_token")!
        let request = try formRequest(
            url: url,
            parameters: [
                "client_id": configuration.clientID,
                "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]
        )
        let data = try await send(request)
        let response = try decode(TokenResponse.self, from: data)

        if let error = response.error {
            switch error {
            case "authorization_pending":
                return .pending(authorization)
            case "slow_down":
                let newInterval = TimeInterval(response.interval ?? Int(authorization.interval) + 5)
                authorization = GitHubDeviceAuthorization(
                    deviceCode: authorization.deviceCode,
                    userCode: authorization.userCode,
                    verificationURL: authorization.verificationURL,
                    browserURL: authorization.browserURL,
                    expiresAt: authorization.expiresAt,
                    interval: newInterval
                )
                pendingAuthorization = authorization
                return .pending(authorization)
            case "access_denied":
                pendingAuthorization = nil
                throw GitHubAuthError.authorizationDenied("GitHub sign-in was canceled.")
            case "expired_token":
                pendingAuthorization = nil
                throw GitHubAuthError.authorizationExpired("The GitHub sign-in code expired. Start again.")
            default:
                throw GitHubAuthError.invalidResponse(response.errorDescription ?? "GitHub sign-in failed.")
            }
        }

        guard let accessToken = response.accessToken else {
            throw GitHubAuthError.invalidResponse("GitHub did not return an access token.")
        }

        let user = try await fetchCurrentUser(token: accessToken)
        var credential = GitHubCredential(
            accessToken: accessToken,
            refreshToken: response.refreshToken,
            accessTokenExpiresAt: response.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            refreshTokenExpiresAt: response.refreshTokenExpiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            userID: user.id,
            userLogin: user.login,
            authorizedOwners: [],
            accessibleRepositories: [],
            lastValidatedAt: nil
        )

        do {
            let validation = try await fetchAccessValidation(
                token: accessToken,
                expectedScopes: expectedScopes
            )
            credential = credential.updating(validation: validation)
            try tokenStore.saveCredential(credential)
            pendingAuthorization = nil
            return .completed(credential)
        } catch let error as GitHubAuthError {
            try tokenStore.saveCredential(credential)
            pendingAuthorization = nil
            throw error
        }
    }

    func refreshIfNeeded(expectedScopes: [RepositoryScope]) async throws -> GitHubCredential {
        try ensureConfigured()

        guard let credential = try tokenStore.loadCredential() else {
            throw GitHubAuthError.signedOut
        }

        let threshold = Date().addingTimeInterval(300)
        if let expiresAt = credential.accessTokenExpiresAt, expiresAt > threshold {
            return credential
        }

        if credential.accessTokenExpiresAt == nil {
            return credential
        }

        return try await refreshCredential(credential, expectedScopes: expectedScopes)
    }

    func forceRefresh(expectedScopes: [RepositoryScope]) async throws -> GitHubCredential {
        try ensureConfigured()

        guard let credential = try tokenStore.loadCredential() else {
            throw GitHubAuthError.signedOut
        }

        return try await refreshCredential(credential, expectedScopes: expectedScopes)
    }

    func validAccessToken(expectedScopes: [RepositoryScope]) async throws -> String {
        try await refreshIfNeeded(expectedScopes: expectedScopes).accessToken
    }

    func validateOrgAccess(expectedScopes: [RepositoryScope]) async throws -> GitHubSessionSummary {
        let credential = try await refreshIfNeeded(expectedScopes: expectedScopes)
        let validation = try await fetchAccessValidation(
            token: credential.accessToken,
            expectedScopes: expectedScopes
        )
        let updatedCredential = credential.updating(validation: validation)
        try tokenStore.saveCredential(updatedCredential)

        return GitHubSessionSummary(
            user: GitHubUser(login: updatedCredential.userLogin),
            tokenExpiresAt: updatedCredential.accessTokenExpiresAt,
            refreshTokenExpiresAt: updatedCredential.refreshTokenExpiresAt,
            authorizedOwners: updatedCredential.authorizedOwners,
            accessibleRepositories: updatedCredential.accessibleRepositories
        )
    }

    func signOut() throws {
        pendingAuthorization = nil
        try tokenStore.deleteCredential()
    }

    func cancelPendingAuthorization() {
        pendingAuthorization = nil
    }

    private func refreshCredential(
        _ credential: GitHubCredential,
        expectedScopes: [RepositoryScope]
    ) async throws -> GitHubCredential {
        guard let refreshToken = credential.refreshToken else {
            throw GitHubAuthError.refreshFailed("GitHub sign-in expired. Reconnect in Settings.")
        }

        if let refreshExpiry = credential.refreshTokenExpiresAt, refreshExpiry <= Date() {
            throw GitHubAuthError.refreshFailed("GitHub sign-in expired. Reconnect in Settings.")
        }

        let url = URL(string: "https://github.com/login/oauth/access_token")!
        let request = try formRequest(
            url: url,
            parameters: [
                "client_id": configuration.clientID,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ]
        )

        let data = try await send(request)
        let response = try decode(TokenResponse.self, from: data)

        if let error = response.error {
            switch error {
            case "bad_refresh_token", "incorrect_client_credentials":
                throw GitHubAuthError.refreshFailed("GitHub sign-in expired. Reconnect in Settings.")
            default:
                throw GitHubAuthError.refreshFailed(response.errorDescription ?? "Could not refresh the GitHub session.")
            }
        }

        guard let accessToken = response.accessToken else {
            throw GitHubAuthError.refreshFailed("GitHub did not return a refreshed access token.")
        }

        let user = try await fetchCurrentUser(token: accessToken)
        var updatedCredential = GitHubCredential(
            accessToken: accessToken,
            refreshToken: response.refreshToken ?? credential.refreshToken,
            accessTokenExpiresAt: response.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            refreshTokenExpiresAt: response.refreshTokenExpiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                ?? credential.refreshTokenExpiresAt,
            userID: user.id,
            userLogin: user.login,
            authorizedOwners: credential.authorizedOwners,
            accessibleRepositories: credential.accessibleRepositories,
            lastValidatedAt: credential.lastValidatedAt
        )

        do {
            let validation = try await fetchAccessValidation(
                token: accessToken,
                expectedScopes: expectedScopes
            )
            updatedCredential = updatedCredential.updating(validation: validation)
            try tokenStore.saveCredential(updatedCredential)
            return updatedCredential
        } catch let error as GitHubAuthError {
            try tokenStore.saveCredential(updatedCredential)
            throw error
        }
    }

    private func fetchCurrentUser(token: String) async throws -> UserResponse {
        let url = URL(string: "https://api.github.com/user")!
        let request = apiRequest(url: url, token: token)
        let data = try await send(request)
        return try decode(UserResponse.self, from: data)
    }

    private func fetchAccessValidation(
        token: String,
        expectedScopes: [RepositoryScope]
    ) async throws -> GitHubAccessValidation {
        let installations = try await fetchInstallations(token: token)
        let explicitRepositories = Set(expectedScopes.compactMap { scope -> String? in
            guard case let .repo(name) = scope else {
                return nil
            }

            return name.lowercased()
        })

        let expectedOwners = Set(
            configuration.expectedOwners.map { $0.lowercased() }
                + expectedScopes.map { scope in
                    switch scope {
                    case let .org(org):
                        return org.lowercased()
                    case let .repo(repo):
                        return repo.split(separator: "/", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
                    }
                }.filter { !$0.isEmpty }
        )

        let authorizedOwners = Set(installations.map { $0.account.login.lowercased() })
        var accessibleRepositories = Set<String>()

        for installation in installations {
            let owner = installation.account.login.lowercased()
            let ownerRepositories = explicitRepositories.filter { $0.hasPrefix("\(owner)/") }
            guard !ownerRepositories.isEmpty else {
                continue
            }

            if installation.repositorySelection?.lowercased() == "all" {
                accessibleRepositories.formUnion(ownerRepositories)
                continue
            }

            let repositories = try await fetchRepositories(
                forInstallationID: installation.id,
                token: token
            )
            accessibleRepositories.formUnion(repositories.map { $0.lowercased() })
        }

        let missingOwners = Array(expectedOwners.subtracting(authorizedOwners)).sorted()
        let missingRepositories = Array(explicitRepositories.subtracting(accessibleRepositories)).sorted()

        if !missingRepositories.isEmpty || !missingOwners.isEmpty {
            let ownerMessage = missingOwners.isEmpty
                ? nil
                : "Missing app access for: \(missingOwners.joined(separator: ", "))."
            let repositoryMessage = missingRepositories.isEmpty
                ? nil
                : "Missing repository access for: \(missingRepositories.joined(separator: ", "))."
            let message = [ownerMessage, repositoryMessage]
                .compactMap { $0 }
                .joined(separator: " ")
            throw GitHubAuthError.installationMissing(
                missingOwners,
                missingRepositories,
                message.isEmpty ? "The GitHub App is not installed for one or more watched owners or repositories." : message
            )
        }

        return GitHubAccessValidation(
            authorizedOwners: Array(authorizedOwners).sorted(),
            accessibleRepositories: Array(accessibleRepositories).sorted(),
            missingOwners: missingOwners,
            missingRepositories: missingRepositories
        )
    }

    private func fetchInstallations(token: String) async throws -> [Installation] {
        var page = 1
        var installations: [Installation] = []

        while true {
            var components = URLComponents(string: "https://api.github.com/user/installations")!
            components.queryItems = [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
            ]

            let request = apiRequest(url: components.url!, token: token)
            let data = try await send(request)
            let response = try decode(InstallationsResponse.self, from: data)
            installations.append(contentsOf: response.installations)

            if response.installations.count < 100 {
                break
            }

            page += 1
        }

        return installations
    }

    private func fetchRepositories(
        forInstallationID installationID: Int,
        token: String
    ) async throws -> [String] {
        var page = 1
        var repositories: [String] = []

        while true {
            var components = URLComponents(
                string: "https://api.github.com/user/installations/\(installationID)/repositories"
            )!
            components.queryItems = [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
            ]

            let request = apiRequest(url: components.url!, token: token)
            let data = try await send(request)
            let response = try decode(InstallationRepositoriesResponse.self, from: data)
            repositories.append(contentsOf: response.repositories.map(\.fullName))

            if response.repositories.count < 100 {
                break
            }

            page += 1
        }

        return repositories
    }

    private func ensureConfigured() throws {
        if let message = configuration.missingConfigurationMessage {
            throw GitHubAuthError.missingConfiguration(message)
        }
    }

    private func formRequest(url: URL, parameters: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = parameters
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func apiRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GitHubAuthError.invalidResponse("GitHub returned a non-HTTP response.")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, bodyData: data)
            }

            return data
        } catch let error as GitHubAuthError {
            throw error
        } catch {
            throw GitHubAuthError.network(error.localizedDescription)
        }
    }

    private func mapHTTPError(statusCode: Int, bodyData: Data) -> GitHubAuthError {
        let apiError = try? decoder.decode(APIErrorResponse.self, from: bodyData)
        let message = apiError?.message ?? String(decoding: bodyData, as: UTF8.self)
        let normalizedMessage = message.lowercased()

        switch statusCode {
        case 401:
            return .refreshFailed("GitHub sign-in expired. Reconnect in Settings.")
        case 403:
            if normalizedMessage.contains("saml") || normalizedMessage.contains("single sign-on") {
                return .ssoRequired([], "Your GitHub authorization needs SSO for one or more watched owners.")
            }

            return .installationMissing([], [], message.isEmpty ? "GitHub denied access to one or more watched owners or repositories." : message)
        default:
            return .invalidResponse("GitHub API error \(statusCode): \(message)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GitHubAuthError.invalidResponse("Could not decode GitHub's response: \(error.localizedDescription)")
        }
    }

    private func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
