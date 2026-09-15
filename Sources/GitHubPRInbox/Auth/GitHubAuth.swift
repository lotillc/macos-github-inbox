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

    init(clientID: String, appSlug: String, expectedOwners: [String]) {
        self.clientID = Self.trimmed(clientID)
        self.appSlug = Self.trimmed(appSlug)
        self.expectedOwners = expectedOwners
            .map(Self.trimmed)
            .filter { !$0.isEmpty }
    }

    static func load(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> GitHubAuthConfiguration {
        load(
            environment: processInfo.environment,
            infoDictionary: bundle.infoDictionary ?? [:]
        )
    }

    static func load(
        environment: [String: String],
        infoDictionary: [String: Any]
    ) -> GitHubAuthConfiguration {
        func value(environmentKey: String, infoKey: String) -> String {
            let environmentValue = defaultValue(environment[environmentKey])
            if !environmentValue.isEmpty {
                return environmentValue
            }

            return defaultValue(infoDictionary[infoKey] as? String)
        }

        let expectedOwnersValue = value(
            environmentKey: Self.expectedOwnersEnvironmentKey,
            infoKey: Self.expectedOwnersInfoKey
        )

        return GitHubAuthConfiguration(
            clientID: value(environmentKey: Self.clientIDEnvironmentKey, infoKey: Self.clientIDInfoKey),
            appSlug: value(environmentKey: Self.appSlugEnvironmentKey, infoKey: Self.appSlugInfoKey),
            expectedOwners: expectedOwners(from: expectedOwnersValue)
        )
    }

    static func expectedOwners(from value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { trimmed(String($0)) }
            .filter { !$0.isEmpty }
    }

    var missingConfigurationMessage: String? {
        var missingFields: [String] = []

        if clientID.isEmpty {
            missingFields.append("GitHub App client ID")
        }

        if appSlug.isEmpty {
            missingFields.append("GitHub App slug")
        }

        if !missingFields.isEmpty {
            return "Configure \(missingFields.joined(separator: " and ")) in Settings before signing in."
        }

        if clientID.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "GitHub App client ID cannot contain whitespace. Update it in Settings."
        }

        if !Self.isGitHubIdentifier(appSlug) {
            return "GitHub App slug may only contain letters, numbers, and hyphens. Update it in Settings."
        }

        if expectedOwners.contains(where: { !Self.isGitHubIdentifier($0) }) {
            return "Expected organization may only contain letters, numbers, and hyphens. Update it in Settings."
        }

        return nil
    }

    var appInstallationURL: URL? {
        guard missingConfigurationMessage == nil else {
            return nil
        }

        return URL(string: "https://github.com/apps/\(appSlug)/installations/new")
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func defaultValue(_ value: String?) -> String {
        let value = trimmed(value)
        if value.hasPrefix("$("), value.hasSuffix(")") {
            return ""
        }

        return value
    }

    private static func isGitHubIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9-]*$", options: .regularExpression) != nil
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
    /// The public GitHub App client ID that issued this credential. Credentials
    /// without provenance are deliberately not trusted after an upgrade.
    let appClientID: String?
    /// Identifies one authenticated account session. It prevents a stale async
    /// completion from writing into a replacement account's Keychain record.
    let sessionID: UUID
    /// Monotonically increases whenever GitHub rotates token material.
    let tokenRevision: UInt
    let accessToken: String
    let refreshToken: String?
    let accessTokenExpiresAt: Date?
    let refreshTokenExpiresAt: Date?
    let userID: Int
    let userLogin: String
    let authorizedOwners: [String]
    let accessibleRepositories: [String]
    /// Optional for backward-compatible decoding of credentials saved before
    /// installation account types were recorded.
    let organizationOwners: [String]?
    let lastValidatedAt: Date?

    init(
        appClientID: String? = nil,
        sessionID: UUID = UUID(),
        tokenRevision: UInt = 0,
        accessToken: String,
        refreshToken: String?,
        accessTokenExpiresAt: Date?,
        refreshTokenExpiresAt: Date?,
        userID: Int,
        userLogin: String,
        authorizedOwners: [String],
        accessibleRepositories: [String],
        organizationOwners: [String]? = nil,
        lastValidatedAt: Date?
    ) {
        self.appClientID = appClientID
        self.sessionID = sessionID
        self.tokenRevision = tokenRevision
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.userID = userID
        self.userLogin = userLogin
        self.authorizedOwners = authorizedOwners
        self.accessibleRepositories = accessibleRepositories
        self.organizationOwners = organizationOwners
        self.lastValidatedAt = lastValidatedAt
    }

    enum CodingKeys: String, CodingKey {
        case appClientID, sessionID, tokenRevision
        case accessToken, refreshToken, accessTokenExpiresAt, refreshTokenExpiresAt
        case userID, userLogin, authorizedOwners, accessibleRepositories, organizationOwners, lastValidatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            appClientID: try values.decodeIfPresent(String.self, forKey: .appClientID),
            sessionID: try values.decodeIfPresent(UUID.self, forKey: .sessionID) ?? UUID(),
            tokenRevision: try values.decodeIfPresent(UInt.self, forKey: .tokenRevision) ?? 0,
            accessToken: try values.decode(String.self, forKey: .accessToken),
            refreshToken: try values.decodeIfPresent(String.self, forKey: .refreshToken),
            accessTokenExpiresAt: try values.decodeIfPresent(Date.self, forKey: .accessTokenExpiresAt),
            refreshTokenExpiresAt: try values.decodeIfPresent(Date.self, forKey: .refreshTokenExpiresAt),
            userID: try values.decode(Int.self, forKey: .userID),
            userLogin: try values.decode(String.self, forKey: .userLogin),
            authorizedOwners: try values.decode([String].self, forKey: .authorizedOwners),
            accessibleRepositories: try values.decode([String].self, forKey: .accessibleRepositories),
            organizationOwners: try values.decodeIfPresent([String].self, forKey: .organizationOwners),
            lastValidatedAt: try values.decodeIfPresent(Date.self, forKey: .lastValidatedAt)
        )
    }

    func updating(validation: GitHubAccessValidation) -> GitHubCredential {
        GitHubCredential(
            appClientID: appClientID,
            sessionID: sessionID,
            tokenRevision: tokenRevision,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            userID: userID,
            userLogin: userLogin,
            authorizedOwners: validation.authorizedOwners,
            accessibleRepositories: validation.accessibleRepositories,
            organizationOwners: validation.organizationOwners,
            lastValidatedAt: Date()
        )
    }

    func replacingTokenMaterial(with credential: GitHubCredential) -> GitHubCredential {
        GitHubCredential(
            appClientID: credential.appClientID,
            sessionID: credential.sessionID,
            tokenRevision: credential.tokenRevision,
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            accessTokenExpiresAt: credential.accessTokenExpiresAt,
            refreshTokenExpiresAt: credential.refreshTokenExpiresAt,
            userID: userID,
            userLogin: userLogin,
            authorizedOwners: authorizedOwners,
            accessibleRepositories: accessibleRepositories,
            organizationOwners: organizationOwners,
            lastValidatedAt: lastValidatedAt
        )
    }

    func preservingNewerValidationMetadata(from credential: GitHubCredential) -> GitHubCredential {
        let candidateValidationDate = lastValidatedAt ?? .distantPast
        guard let currentValidationDate = credential.lastValidatedAt,
              currentValidationDate > candidateValidationDate
        else {
            return self
        }

        return GitHubCredential(
            appClientID: appClientID,
            sessionID: sessionID,
            tokenRevision: tokenRevision,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            userID: userID,
            userLogin: userLogin,
            authorizedOwners: credential.authorizedOwners,
            accessibleRepositories: credential.accessibleRepositories,
            organizationOwners: credential.organizationOwners,
            lastValidatedAt: credential.lastValidatedAt
        )
    }
}

/// A device-code exchange has succeeded, but the first profile/installation
/// lookup has not. This is intentionally a distinct Keychain record so it can
/// never be presented as an authenticated user session.
struct PendingGitHubDeviceCredential: Codable, Equatable {
    let appClientID: String?
    let sessionID: UUID
    let tokenRevision: UInt
    let accessToken: String
    let refreshToken: String?
    let accessTokenExpiresAt: Date?
    let refreshTokenExpiresAt: Date?

    init(
        appClientID: String? = nil,
        sessionID: UUID = UUID(),
        tokenRevision: UInt = 0,
        accessToken: String,
        refreshToken: String?,
        accessTokenExpiresAt: Date?,
        refreshTokenExpiresAt: Date?
    ) {
        self.appClientID = appClientID
        self.sessionID = sessionID
        self.tokenRevision = tokenRevision
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    enum CodingKeys: String, CodingKey {
        case appClientID, sessionID, tokenRevision
        case accessToken, refreshToken, accessTokenExpiresAt, refreshTokenExpiresAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            appClientID: try values.decodeIfPresent(String.self, forKey: .appClientID),
            sessionID: try values.decodeIfPresent(UUID.self, forKey: .sessionID) ?? UUID(),
            tokenRevision: try values.decodeIfPresent(UInt.self, forKey: .tokenRevision) ?? 0,
            accessToken: try values.decode(String.self, forKey: .accessToken),
            refreshToken: try values.decodeIfPresent(String.self, forKey: .refreshToken),
            accessTokenExpiresAt: try values.decodeIfPresent(Date.self, forKey: .accessTokenExpiresAt),
            refreshTokenExpiresAt: try values.decodeIfPresent(Date.self, forKey: .refreshTokenExpiresAt)
        )
    }
}

struct GitHubSessionSummary: Equatable {
    let user: GitHubUser
    let tokenExpiresAt: Date?
    let refreshTokenExpiresAt: Date?
    let authorizedOwners: [String]
    let accessibleRepositories: [String]
    let organizationOwners: [String]

    init(
        user: GitHubUser,
        tokenExpiresAt: Date?,
        refreshTokenExpiresAt: Date?,
        authorizedOwners: [String],
        accessibleRepositories: [String],
        organizationOwners: [String] = []
    ) {
        self.user = user
        self.tokenExpiresAt = tokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.authorizedOwners = authorizedOwners
        self.accessibleRepositories = accessibleRepositories
        self.organizationOwners = organizationOwners
    }
}

enum GitHubAuthenticationState: Equatable {
    case missingConfiguration(String)
    case signedOut
    case authorizing(GitHubDeviceAuthorization)
    case signedIn(GitHubSessionSummary)
    case refreshFailed(String)
    case rateLimited(String)
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
        case let .rateLimited(message):
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
    let organizationOwners: [String]
}

enum GitHubAuthPollingResult: Equatable {
    case pending(GitHubDeviceAuthorization)
    case completed(GitHubCredential)
}

enum GitHubAuthError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case signedOut
    case configurationChanged
    case pendingAuthorizationRequired
    case authorizationDenied(String)
    case authorizationExpired(String)
    case refreshFailed(String)
    case rateLimited(String)
    case ssoRequired([String], String)
    case installationMissing([String], [String], String)
    case archivedRepositories([String])
    case invalidResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case let .missingConfiguration(message),
             let .authorizationDenied(message),
             let .authorizationExpired(message),
             let .refreshFailed(message),
             let .rateLimited(message),
             let .ssoRequired(_, message),
             let .installationMissing(_, _, message),
             let .invalidResponse(message),
             let .network(message):
            return message
        case let .archivedRepositories(repositories):
            return "Stopped watching archived repositories: \(repositories.joined(separator: ", "))."
        case .signedOut:
            return "Sign in with GitHub in Settings."
        case .configurationChanged:
            return "GitHub App settings changed. Reconnect to GitHub."
        case .pendingAuthorizationRequired:
            return "Start GitHub sign-in before polling for completion."
        }
    }
}

actor GitHubAuthProvider {
    private struct AuthenticationContext {
        let configuration: GitHubAuthConfiguration
        let generation: UInt
    }

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
        let type: String?
    }

    private struct InstallationRepositoriesResponse: Decodable {
        let repositories: [AccessibleRepository]
    }

    private struct AccessibleRepository: Decodable {
        let fullName: String
        let archived: Bool?

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
            case archived
        }
    }

    private let session: URLSession
    private let tokenStore: KeychainTokenStore
    private let decoder: JSONDecoder
    private var configuration: GitHubAuthConfiguration
    private var configurationGeneration: UInt = 0
    private var pendingAuthorization: GitHubDeviceAuthorization?
    private var pendingAuthorizationAttempt: UInt?
    private var nextPendingAuthorizationAttempt: UInt = 0
    private var refreshTask: Task<GitHubCredential, Error>?
    private var refreshTaskGeneration: UInt?
    private var refreshTaskConfiguration: GitHubAuthConfiguration?
    private var refreshTaskSessionID: UUID?
    private var refreshTaskNonce: UInt?
    private var nextRefreshTaskNonce: UInt = 0
    private var pendingRefreshTask: Task<PendingGitHubDeviceCredential, Error>?
    private var pendingRefreshTaskGeneration: UInt?
    private var pendingRefreshTaskSessionID: UUID?
    private var pendingRefreshTaskNonce: UInt?
    private var nextPendingRefreshTaskNonce: UInt = 0
    private var pendingResolutionTask: Task<GitHubCredential, Error>?
    private var pendingResolutionSessionID: UUID?
    private var pendingResolutionConfiguration: GitHubAuthConfiguration?
    private var pendingResolutionForceRefresh: Bool?
    private var pendingResolutionTaskNonce: UInt?
    private var nextPendingResolutionTaskNonce: UInt = 0

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

        // PATs are no longer supported. Retry this idempotent cleanup on every
        // launch until Keychain accepts it (for example after the device unlocks).
        try? tokenStore.deleteLegacyPersonalAccessToken()
    }

    func currentCredential() throws -> GitHubCredential? {
        if try loadPendingCredentialBoundToCurrentApp() != nil {
            return nil
        }
        return try loadActiveCredentialBoundToCurrentApp()
    }

    func updateConfiguration(_ configuration: GitHubAuthConfiguration) {
        guard configuration != self.configuration else {
            return
        }

        // A refresh-token grant may rotate its refresh token.  Changing only
        // the desired owner list must not cancel that in-flight grant: GitHub
        // may already have consumed the old refresh token.  An app identity
        // change is different; its token requests must never be persisted.
        if isDifferentAppIdentity(configuration, self.configuration) {
            configurationGeneration &+= 1
            refreshTask?.cancel()
            refreshTask = nil
            refreshTaskGeneration = nil
            refreshTaskConfiguration = nil
            refreshTaskSessionID = nil
            refreshTaskNonce = nil
            pendingRefreshTask?.cancel()
            pendingRefreshTask = nil
            pendingRefreshTaskGeneration = nil
            pendingRefreshTaskSessionID = nil
            pendingRefreshTaskNonce = nil
            pendingResolutionTask?.cancel()
            pendingResolutionTask = nil
            pendingResolutionSessionID = nil
            pendingResolutionConfiguration = nil
            pendingResolutionForceRefresh = nil
            pendingResolutionTaskNonce = nil
            pendingAuthorization = nil
            pendingAuthorizationAttempt = nil
            try? tokenStore.deletePendingDeviceCredential()
        }
        self.configuration = configuration
    }

    func replaceConfigurationAndSignOut(_ configuration: GitHubAuthConfiguration) throws {
        configurationGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskGeneration = nil
        refreshTaskConfiguration = nil
        refreshTaskSessionID = nil
        refreshTaskNonce = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        pendingRefreshTaskGeneration = nil
        pendingRefreshTaskSessionID = nil
        pendingRefreshTaskNonce = nil
        pendingResolutionTask?.cancel()
        pendingResolutionTask = nil
        pendingResolutionSessionID = nil
        pendingResolutionConfiguration = nil
        pendingResolutionForceRefresh = nil
        pendingResolutionTaskNonce = nil
        pendingAuthorization = nil
        pendingAuthorizationAttempt = nil
        try tokenStore.deleteCredential()
        try tokenStore.deletePendingDeviceCredential()
        try tokenStore.deleteLegacyPersonalAccessToken()
        self.configuration = configuration
    }

    func pendingAuthorizationState() -> GitHubDeviceAuthorization? {
        pendingAuthorization
    }

    func startSignIn(expectedScopes: [RepositoryScope]) async throws -> GitHubDeviceAuthorization {
        let context = try configuredContext()
        let configuration = context.configuration
        // This nonce has a different lifetime from the active credential. It
        // lets a canceled or superseded device-code request fail safely while
        // preserving an existing account session and its token rotation.
        nextPendingAuthorizationAttempt &+= 1
        let authorizationAttempt = nextPendingAuthorizationAttempt
        pendingAuthorizationAttempt = authorizationAttempt
        pendingAuthorization = nil

        let url = URL(string: "https://github.com/login/device/code")!
        let request = try formRequest(
            url: url,
            parameters: ["client_id": configuration.clientID]
        )
        let data = try await send(request)
        let response = try decode(DeviceCodeResponse.self, from: data)
        try ensureCurrent(context)
        try ensurePendingAuthorizationCurrent(authorizationAttempt)

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
        let context = try configuredContext()
        let configuration = context.configuration

        guard var authorization = pendingAuthorization,
              let authorizationAttempt = pendingAuthorizationAttempt
        else {
            throw GitHubAuthError.pendingAuthorizationRequired
        }

        if authorization.expiresAt <= Date() {
            pendingAuthorization = nil
            pendingAuthorizationAttempt = nil
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
        try ensureCurrent(context)
        try ensurePendingAuthorizationCurrent(authorizationAttempt)

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
                pendingAuthorizationAttempt = nil
                throw GitHubAuthError.authorizationDenied("GitHub sign-in was canceled.")
            case "expired_token":
                pendingAuthorization = nil
                pendingAuthorizationAttempt = nil
                throw GitHubAuthError.authorizationExpired("The GitHub sign-in code expired. Start again.")
            default:
                throw GitHubAuthError.invalidResponse(response.errorDescription ?? "GitHub sign-in failed.")
            }
        }

        guard let accessToken = response.accessToken else {
            throw GitHubAuthError.invalidResponse("GitHub did not return an access token.")
        }

        let pendingCredential = PendingGitHubDeviceCredential(
            appClientID: configuration.clientID,
            accessToken: accessToken,
            refreshToken: response.refreshToken,
            accessTokenExpiresAt: response.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            refreshTokenExpiresAt: response.refreshTokenExpiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
        // Owner policy can change while GitHub processes the device-code
        // exchange. Commit and resolve with that latest policy, while the
        // app-identity generation still prevents a changed App from using it.
        let resolutionContext = try configuredContext()
        guard resolutionContext.configuration.clientID == configuration.clientID else {
            throw GitHubAuthError.configurationChanged
        }
        try beginPendingCredential(pendingCredential, context: resolutionContext)
        pendingAuthorization = nil
        pendingAuthorizationAttempt = nil
        let credential = try await resolvePendingDeviceCredential(
            pendingCredential,
            expectedScopes: expectedScopes,
            configuration: resolutionContext.configuration,
            context: resolutionContext,
            forceRefresh: false
        )
        return .completed(credential)
    }

    func refreshIfNeeded(expectedScopes: [RepositoryScope]) async throws -> GitHubCredential {
        let context = try configuredContext()
        let configuration = context.configuration

        if let pendingCredential = try loadPendingCredentialBoundToCurrentApp() {
            do {
                return try await resolvePendingDeviceCredential(
                    pendingCredential,
                    expectedScopes: expectedScopes,
                    configuration: configuration,
                    context: context,
                    forceRefresh: false
                )
            } catch let error as GitHubAuthError where isTerminalPendingDeviceCredentialError(error) {
                // A newly issued token can still be revoked before its first
                // profile lookup. Do not let that stale pending record shadow a
                // usable previous session forever.
                try deletePendingCredentialIfCurrent(pendingCredential, context: context)
            }
        }

        guard let credential = try loadActiveCredentialBoundToCurrentApp() else {
            throw GitHubAuthError.signedOut
        }

        let threshold = Date().addingTimeInterval(300)
        if let expiresAt = credential.accessTokenExpiresAt, expiresAt > threshold {
            return credential
        }

        if credential.accessTokenExpiresAt == nil {
            return credential
        }

        return try await refreshCredential(
            credential,
            expectedScopes: expectedScopes,
            configuration: configuration,
            context: context
        )
    }

    func forceRefresh(expectedScopes: [RepositoryScope]) async throws -> GitHubCredential {
        let context = try configuredContext()
        let configuration = context.configuration

        if let pendingCredential = try loadPendingCredentialBoundToCurrentApp() {
            do {
                return try await resolvePendingDeviceCredential(
                    pendingCredential,
                    expectedScopes: expectedScopes,
                    configuration: configuration,
                    context: context,
                    forceRefresh: true
                )
            } catch let error as GitHubAuthError where isTerminalPendingDeviceCredentialError(error) {
                try deletePendingCredentialIfCurrent(pendingCredential, context: context)
            }
        }

        guard let credential = try loadActiveCredentialBoundToCurrentApp() else {
            throw GitHubAuthError.signedOut
        }

        return try await refreshCredential(
            credential,
            expectedScopes: expectedScopes,
            configuration: configuration,
            context: context
        )
    }

    func validAccessToken(expectedScopes: [RepositoryScope]) async throws -> String {
        try await refreshIfNeeded(expectedScopes: expectedScopes).accessToken
    }

    func validateOrgAccess(expectedScopes: [RepositoryScope]) async throws -> GitHubSessionSummary {
        let context = try configuredContext()
        let configuration = context.configuration
        let credential = try await refreshIfNeeded(expectedScopes: expectedScopes)
        try ensureValidationCurrent(context)
        let validation = try await fetchAccessValidation(
            token: credential.accessToken,
            expectedScopes: expectedScopes,
            configuration: configuration
        )
        let updatedCredential = try saveValidation(
            validation,
            for: credential,
            context: context
        )

        return GitHubSessionSummary(
            user: GitHubUser(login: updatedCredential.userLogin),
            tokenExpiresAt: updatedCredential.accessTokenExpiresAt,
            refreshTokenExpiresAt: updatedCredential.refreshTokenExpiresAt,
            authorizedOwners: updatedCredential.authorizedOwners,
            accessibleRepositories: updatedCredential.accessibleRepositories,
            organizationOwners: validation.organizationOwners
        )
    }

    func signOut() throws {
        configurationGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskGeneration = nil
        refreshTaskConfiguration = nil
        refreshTaskSessionID = nil
        refreshTaskNonce = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        pendingRefreshTaskGeneration = nil
        pendingRefreshTaskSessionID = nil
        pendingRefreshTaskNonce = nil
        pendingResolutionTask?.cancel()
        pendingResolutionTask = nil
        pendingResolutionSessionID = nil
        pendingResolutionConfiguration = nil
        pendingResolutionForceRefresh = nil
        pendingResolutionTaskNonce = nil
        pendingAuthorization = nil
        pendingAuthorizationAttempt = nil
        try tokenStore.deleteCredential()
        try tokenStore.deletePendingDeviceCredential()
        try tokenStore.deleteLegacyPersonalAccessToken()
    }

    func cancelPendingAuthorization() {
        // Canceling a replacement device flow must not invalidate the existing
        // account session or abort its rotating-token grant. A reconnect may
        // fail or be canceled, in which case that session remains usable.
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        pendingRefreshTaskGeneration = nil
        pendingRefreshTaskSessionID = nil
        pendingRefreshTaskNonce = nil
        pendingResolutionTask?.cancel()
        pendingResolutionTask = nil
        pendingResolutionSessionID = nil
        pendingResolutionConfiguration = nil
        pendingResolutionForceRefresh = nil
        pendingResolutionTaskNonce = nil
        pendingAuthorization = nil
        pendingAuthorizationAttempt = nil
        try? tokenStore.deletePendingDeviceCredential()
    }

    private func loadActiveCredentialBoundToCurrentApp() throws -> GitHubCredential? {
        guard let credential = try tokenStore.loadCredential() else {
            return nil
        }
        guard credential.appClientID == configuration.clientID else {
            throw GitHubAuthError.configurationChanged
        }
        return credential
    }

    private func ensurePendingAuthorizationCurrent(_ attempt: UInt) throws {
        guard pendingAuthorizationAttempt == attempt else {
            throw GitHubAuthError.configurationChanged
        }
    }

    private func loadPendingCredentialBoundToCurrentApp() throws -> PendingGitHubDeviceCredential? {
        guard let credential = try tokenStore.loadPendingDeviceCredential() else {
            return nil
        }
        guard credential.appClientID == configuration.clientID else {
            throw GitHubAuthError.configurationChanged
        }
        return credential
    }

    private func commitActiveCredential(
        _ candidate: GitHubCredential,
        context: AuthenticationContext
    ) throws -> GitHubCredential {
        try ensureCurrent(context)
        guard candidate.appClientID == context.configuration.clientID else {
            throw GitHubAuthError.configurationChanged
        }
        guard let current = try tokenStore.loadCredential() else {
            try tokenStore.saveCredential(candidate)
            return candidate
        }
        guard current.appClientID == context.configuration.clientID,
              current.sessionID == candidate.sessionID
        else {
            throw GitHubAuthError.configurationChanged
        }

        let credential: GitHubCredential
        if current.tokenRevision > candidate.tokenRevision {
            credential = candidate.replacingTokenMaterial(with: current)
        } else {
            // A forced refresh can begin before a validation request but finish
            // after it. Keep the latest access inventory while publishing the
            // newer OAuth token material.
            credential = candidate.preservingNewerValidationMetadata(from: current)
        }
        try tokenStore.saveCredential(credential)
        return credential
    }

    private func commitPendingCredential(
        _ candidate: PendingGitHubDeviceCredential,
        context: AuthenticationContext
    ) throws -> PendingGitHubDeviceCredential {
        try ensureCurrent(context)
        guard candidate.appClientID == context.configuration.clientID,
              let current = try tokenStore.loadPendingDeviceCredential(),
              current.appClientID == context.configuration.clientID,
              current.sessionID == candidate.sessionID
        else {
            throw GitHubAuthError.configurationChanged
        }
        guard current.tokenRevision <= candidate.tokenRevision else {
            return current
        }
        try tokenStore.savePendingDeviceCredential(candidate)
        return candidate
    }

    private func beginPendingCredential(
        _ candidate: PendingGitHubDeviceCredential,
        context: AuthenticationContext
    ) throws {
        try ensureCurrent(context)
        guard candidate.appClientID == context.configuration.clientID else {
            throw GitHubAuthError.configurationChanged
        }
        // A completed newer device code supersedes any unfinished pending
        // session. Its token must not share a refresh task with that session.
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        pendingRefreshTaskGeneration = nil
        pendingRefreshTaskSessionID = nil
        pendingRefreshTaskNonce = nil
        pendingResolutionTask?.cancel()
        pendingResolutionTask = nil
        pendingResolutionSessionID = nil
        pendingResolutionConfiguration = nil
        pendingResolutionForceRefresh = nil
        pendingResolutionTaskNonce = nil
        try tokenStore.savePendingDeviceCredential(candidate)
    }

    private func deletePendingCredentialIfCurrent(
        _ candidate: PendingGitHubDeviceCredential,
        context: AuthenticationContext
    ) throws {
        try ensureCurrent(context)
        guard let current = try tokenStore.loadPendingDeviceCredential(),
              current.appClientID == context.configuration.clientID,
              current.sessionID == candidate.sessionID,
              current.tokenRevision == candidate.tokenRevision
        else {
            return
        }
        try tokenStore.deletePendingDeviceCredential()
    }

    private func currentPendingCredential(
        _ candidate: PendingGitHubDeviceCredential,
        context: AuthenticationContext
    ) throws -> PendingGitHubDeviceCredential {
        try ensureCurrent(context)
        guard candidate.appClientID == context.configuration.clientID,
              let current = try tokenStore.loadPendingDeviceCredential(),
              current.appClientID == context.configuration.clientID,
              current.sessionID == candidate.sessionID
        else {
            throw GitHubAuthError.configurationChanged
        }
        return current
    }

    private func promotePendingCredential(
        _ credential: GitHubCredential,
        pendingCredential: PendingGitHubDeviceCredential,
        context: AuthenticationContext
    ) throws -> GitHubCredential {
        try ensureCurrent(context)
        guard credential.appClientID == context.configuration.clientID,
              credential.sessionID == pendingCredential.sessionID,
              let currentPending = try tokenStore.loadPendingDeviceCredential(),
              currentPending.appClientID == context.configuration.clientID,
              currentPending.sessionID == pendingCredential.sessionID
        else {
            throw GitHubAuthError.configurationChanged
        }
        // A new device-code login replaces the active account session. An old
        // refresh task may continue only long enough to receive GitHub's
        // rotated-token response, but it must never be reused for this session.
        if refreshTaskSessionID != credential.sessionID {
            refreshTask = nil
            refreshTaskGeneration = nil
            refreshTaskConfiguration = nil
            refreshTaskSessionID = nil
            refreshTaskNonce = nil
        }
        try tokenStore.saveCredential(credential)
        try tokenStore.deletePendingDeviceCredential()
        return credential
    }

    private func refreshCredential(
        _ credential: GitHubCredential,
        expectedScopes: [RepositoryScope],
        configuration: GitHubAuthConfiguration,
        context: AuthenticationContext
    ) async throws -> GitHubCredential {
        if let refreshTask,
           refreshTaskGeneration == context.generation,
           refreshTaskSessionID == credential.sessionID {
            if refreshTaskConfiguration == context.configuration {
                return try await refreshTask.value
            }

            // Let the old configuration finish persisting any rotated token
            // before validating under the new owner policy. Starting a second
            // OAuth refresh here could reuse a refresh token that GitHub has
            // already consumed.
            let taskNonce = refreshTaskNonce
            let refreshResult: Result<GitHubCredential, Error>
            do {
                refreshResult = .success(try await refreshTask.value)
            } catch {
                refreshResult = .failure(error)
            }
            if refreshTaskGeneration == context.generation, refreshTaskNonce == taskNonce {
                self.refreshTask = nil
                refreshTaskGeneration = nil
                refreshTaskConfiguration = nil
                refreshTaskSessionID = nil
                refreshTaskNonce = nil
            }
            try ensureCurrent(context)
            guard let currentCredential = try loadActiveCredentialBoundToCurrentApp() else {
                throw GitHubAuthError.signedOut
            }
            switch refreshResult {
            case let .success(refreshedCredential):
                return refreshedCredential
            case let .failure(error):
                let accessTokenChanged = currentCredential.accessToken != credential.accessToken
                let refreshTokenChanged = currentCredential.refreshToken != credential.refreshToken
                let hasUsableAccessToken = currentCredential.accessTokenExpiresAt.map {
                    $0 > Date().addingTimeInterval(300)
                } ?? false
                guard accessTokenChanged || refreshTokenChanged || hasUsableAccessToken else {
                    throw error
                }
                return currentCredential
            }
        }

        let task = Task { [self] in
            try await performRefreshCredential(
                credential,
                expectedScopes: expectedScopes,
                configuration: configuration,
                context: context
            )
        }
        refreshTask = task
        refreshTaskGeneration = context.generation
        refreshTaskConfiguration = context.configuration
        refreshTaskSessionID = credential.sessionID
        nextRefreshTaskNonce &+= 1
        let taskNonce = nextRefreshTaskNonce
        refreshTaskNonce = taskNonce
        do {
            let refreshedCredential = try await task.value
            if refreshTaskGeneration == context.generation, refreshTaskNonce == taskNonce {
                refreshTask = nil
                refreshTaskGeneration = nil
                refreshTaskConfiguration = nil
                refreshTaskSessionID = nil
                refreshTaskNonce = nil
            }
            return refreshedCredential
        } catch {
            if refreshTaskGeneration == context.generation, refreshTaskNonce == taskNonce {
                refreshTask = nil
                refreshTaskGeneration = nil
                refreshTaskConfiguration = nil
                refreshTaskSessionID = nil
                refreshTaskNonce = nil
            }
            throw error
        }
    }

    private func performRefreshCredential(
        _ credential: GitHubCredential,
        expectedScopes: [RepositoryScope],
        configuration: GitHubAuthConfiguration,
        context: AuthenticationContext
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

        try ensureCurrent(context)
        var updatedCredential = GitHubCredential(
            appClientID: credential.appClientID,
            sessionID: credential.sessionID,
            tokenRevision: credential.tokenRevision &+ 1,
            accessToken: accessToken,
            refreshToken: response.refreshToken ?? credential.refreshToken,
            accessTokenExpiresAt: response.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            refreshTokenExpiresAt: response.refreshTokenExpiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                ?? credential.refreshTokenExpiresAt,
            userID: credential.userID,
            userLogin: credential.userLogin,
            authorizedOwners: credential.authorizedOwners,
            accessibleRepositories: credential.accessibleRepositories,
            organizationOwners: credential.organizationOwners,
            lastValidatedAt: credential.lastValidatedAt
        )
        updatedCredential = try commitActiveCredential(updatedCredential, context: context)

        let user = try await fetchCurrentUser(token: accessToken)
        try ensureCurrent(context)
        updatedCredential = GitHubCredential(
            appClientID: updatedCredential.appClientID,
            sessionID: updatedCredential.sessionID,
            tokenRevision: updatedCredential.tokenRevision,
            accessToken: updatedCredential.accessToken,
            refreshToken: updatedCredential.refreshToken,
            accessTokenExpiresAt: updatedCredential.accessTokenExpiresAt,
            refreshTokenExpiresAt: updatedCredential.refreshTokenExpiresAt,
            userID: user.id,
            userLogin: user.login,
            authorizedOwners: updatedCredential.authorizedOwners,
            accessibleRepositories: updatedCredential.accessibleRepositories,
            organizationOwners: updatedCredential.organizationOwners,
            lastValidatedAt: updatedCredential.lastValidatedAt
        )

        do {
            try ensureValidationCurrent(context)
            let validation = try await fetchAccessValidation(
                token: accessToken,
                expectedScopes: expectedScopes,
                configuration: configuration
            )
            updatedCredential = updatedCredential.updating(validation: validation)
            try ensureValidationCurrent(context)
            return try commitActiveCredential(updatedCredential, context: context)
        } catch let error as GitHubAuthError {
            _ = try commitActiveCredential(updatedCredential, context: context)
            throw error
        }
    }

    private func resolvePendingDeviceCredential(
        _ pendingCredential: PendingGitHubDeviceCredential,
        expectedScopes: [RepositoryScope],
        configuration: GitHubAuthConfiguration,
        context: AuthenticationContext,
        forceRefresh: Bool
    ) async throws -> GitHubCredential {
        let pendingCredential = try currentPendingCredential(
            pendingCredential,
            context: context
        )

        if let pendingResolutionTask,
           pendingResolutionSessionID == pendingCredential.sessionID
        {
            let canJoin = pendingResolutionConfiguration == configuration
                && (pendingResolutionForceRefresh == true || !forceRefresh)
            if canJoin {
                return try await pendingResolutionTask.value
            }

            // A policy edit must not inherit an old task's configurationChanged
            // result. Likewise, a force request waits for a non-forced task to
            // finish promotion before it force-refreshes the active session.
            let taskNonce = pendingResolutionTaskNonce
            let result = await pendingResolutionTask.result
            if let taskNonce {
                clearPendingResolutionTask(
                    for: pendingCredential.sessionID,
                    nonce: taskNonce
                )
            }
            switch result {
            case let .success(credential):
                if forceRefresh {
                    return try await refreshCredential(
                        credential,
                        expectedScopes: expectedScopes,
                        configuration: configuration,
                        context: context
                    )
                }
                return credential
            case .failure:
                // The old task was for a distinct request context. Re-evaluate
                // the durable pending record and resolve it under this one.
                return try await resolvePendingDeviceCredential(
                    pendingCredential,
                    expectedScopes: expectedScopes,
                    configuration: configuration,
                    context: context,
                    forceRefresh: forceRefresh
                )
            }
        }

        let task = Task { [self] in
            try await performPendingDeviceCredentialResolution(
                pendingCredential,
                expectedScopes: expectedScopes,
                configuration: configuration,
                context: context,
                forceRefresh: forceRefresh
            )
        }
        pendingResolutionTask = task
        pendingResolutionSessionID = pendingCredential.sessionID
        pendingResolutionConfiguration = configuration
        pendingResolutionForceRefresh = forceRefresh
        nextPendingResolutionTaskNonce &+= 1
        let taskNonce = nextPendingResolutionTaskNonce
        pendingResolutionTaskNonce = taskNonce
        do {
            let credential = try await task.value
            clearPendingResolutionTask(for: pendingCredential.sessionID, nonce: taskNonce)
            return credential
        } catch {
            clearPendingResolutionTask(for: pendingCredential.sessionID, nonce: taskNonce)
            throw error
        }
    }

    private func performPendingDeviceCredentialResolution(
        _ pendingCredential: PendingGitHubDeviceCredential,
        expectedScopes: [RepositoryScope],
        configuration: GitHubAuthConfiguration,
        context: AuthenticationContext,
        forceRefresh: Bool
    ) async throws -> GitHubCredential {
        let pendingCredential = try await refreshedPendingDeviceCredentialIfNeeded(
            pendingCredential,
            configuration: configuration,
            context: context,
            forceRefresh: forceRefresh
        )
        let user = try await fetchCurrentUser(token: pendingCredential.accessToken)
        try ensureCurrent(context)
        var credential = GitHubCredential(
            appClientID: pendingCredential.appClientID,
            sessionID: pendingCredential.sessionID,
            tokenRevision: pendingCredential.tokenRevision,
            accessToken: pendingCredential.accessToken,
            refreshToken: pendingCredential.refreshToken,
            accessTokenExpiresAt: pendingCredential.accessTokenExpiresAt,
            refreshTokenExpiresAt: pendingCredential.refreshTokenExpiresAt,
            userID: user.id,
            userLogin: user.login,
            authorizedOwners: [],
            accessibleRepositories: [],
            organizationOwners: [],
            lastValidatedAt: nil
        )

        do {
            try ensureValidationCurrent(context)
            let validation = try await fetchAccessValidation(
                token: credential.accessToken,
                expectedScopes: expectedScopes,
                configuration: configuration
            )
            credential = credential.updating(validation: validation)
            try ensureValidationCurrent(context)
            return try promotePendingCredential(
                credential,
                pendingCredential: pendingCredential,
                context: context
            )
        } catch let error as GitHubAuthError {
            // The durable pending record allows a later auth check to resume a
            // transient profile/installation failure without consuming a new code.
            throw error
        }
    }

    private func clearPendingResolutionTask(for sessionID: UUID, nonce: UInt) {
        guard pendingResolutionSessionID == sessionID,
              pendingResolutionTaskNonce == nonce
        else {
            return
        }
        pendingResolutionTask = nil
        pendingResolutionSessionID = nil
        pendingResolutionConfiguration = nil
        pendingResolutionForceRefresh = nil
        pendingResolutionTaskNonce = nil
    }

    private func isTerminalPendingDeviceCredentialError(_ error: GitHubAuthError) -> Bool {
        if case .refreshFailed = error {
            return true
        }
        return false
    }

    private func refreshedPendingDeviceCredentialIfNeeded(
        _ credential: PendingGitHubDeviceCredential,
        configuration: GitHubAuthConfiguration,
        context: AuthenticationContext,
        forceRefresh: Bool
    ) async throws -> PendingGitHubDeviceCredential {
        let threshold = Date().addingTimeInterval(300)
        guard forceRefresh || (credential.accessTokenExpiresAt != nil && credential.accessTokenExpiresAt! <= threshold) else {
            return credential
        }

        if let pendingRefreshTask,
           pendingRefreshTaskGeneration == context.generation,
           pendingRefreshTaskSessionID == credential.sessionID {
            return try await pendingRefreshTask.value
        }

        let task = Task { [self] in
            try await performPendingCredentialRefresh(
                credential,
                configuration: configuration,
                context: context
            )
        }
        pendingRefreshTask = task
        pendingRefreshTaskGeneration = context.generation
        pendingRefreshTaskSessionID = credential.sessionID
        nextPendingRefreshTaskNonce &+= 1
        let taskNonce = nextPendingRefreshTaskNonce
        pendingRefreshTaskNonce = taskNonce

        do {
            let refreshedCredential = try await task.value
            clearPendingRefreshTaskIfCurrent(context: context, nonce: taskNonce)
            return refreshedCredential
        } catch {
            clearPendingRefreshTaskIfCurrent(context: context, nonce: taskNonce)
            throw error
        }
    }

    private func performPendingCredentialRefresh(
        _ credential: PendingGitHubDeviceCredential,
        configuration: GitHubAuthConfiguration,
        context: AuthenticationContext
    ) async throws -> PendingGitHubDeviceCredential {

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

        try ensureCurrent(context)
        let refreshedCredential = PendingGitHubDeviceCredential(
            appClientID: credential.appClientID,
            sessionID: credential.sessionID,
            tokenRevision: credential.tokenRevision &+ 1,
            accessToken: accessToken,
            refreshToken: response.refreshToken ?? credential.refreshToken,
            accessTokenExpiresAt: response.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            refreshTokenExpiresAt: response.refreshTokenExpiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                ?? credential.refreshTokenExpiresAt
        )
        return try commitPendingCredential(refreshedCredential, context: context)
    }

    private func clearPendingRefreshTaskIfCurrent(
        context: AuthenticationContext,
        nonce: UInt
    ) {
        guard pendingRefreshTaskGeneration == context.generation, pendingRefreshTaskNonce == nonce else {
            return
        }

        pendingRefreshTask = nil
        pendingRefreshTaskGeneration = nil
        pendingRefreshTaskSessionID = nil
        pendingRefreshTaskNonce = nil
    }

    private func saveValidation(
        _ validation: GitHubAccessValidation,
        for credential: GitHubCredential,
        context: AuthenticationContext
    ) throws -> GitHubCredential {
        try ensureValidationCurrent(context)

        // Validation can suspend while another request refreshes an expired
        // token. Preserve that rotated token and refresh-token pair, while
        // applying the validation inventory gathered by this request.
        guard let currentCredential = try loadActiveCredentialBoundToCurrentApp(),
              currentCredential.sessionID == credential.sessionID
        else {
            throw GitHubAuthError.configurationChanged
        }
        return try commitActiveCredential(
            currentCredential.updating(validation: validation),
            context: context
        )
    }

    private func fetchCurrentUser(token: String) async throws -> UserResponse {
        let url = URL(string: "https://api.github.com/user")!
        let request = apiRequest(url: url, token: token)
        let data = try await send(request)
        return try decode(UserResponse.self, from: data)
    }

    private func fetchAccessValidation(
        token: String,
        expectedScopes: [RepositoryScope],
        configuration: GitHubAuthConfiguration
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
                    case let .user(user):
                        return user.lowercased()
                    case let .repo(repo):
                        return repo.split(separator: "/", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
                    }
                }.filter { !$0.isEmpty }
        )

        let authorizedOwners = Set(installations.map { $0.account.login.lowercased() })
        let organizationOwners = Set(
            installations.compactMap { installation -> String? in
                guard installation.account.type?.caseInsensitiveCompare("Organization") == .orderedSame else {
                    return nil
                }
                return installation.account.login.lowercased()
            }
        )
        var accessibleRepositories = Set<String>()
        var archivedRepositories = Set<String>()

        for installation in installations {
            let repositories: [AccessibleRepository]
            do {
                repositories = try await fetchRepositories(
                    forInstallationID: installation.id,
                    token: token
                )
            } catch let error as GitHubAuthError {
                if case let .ssoRequired(_, message) = error {
                    throw GitHubAuthError.ssoRequired([installation.account.login], message)
                }
                throw error
            }
            accessibleRepositories.formUnion(
                repositories
                    .filter { $0.archived != true }
                    .map { $0.fullName.lowercased() }
            )
            archivedRepositories.formUnion(
                repositories
                    .filter { $0.archived == true }
                    .map { $0.fullName.lowercased() }
            )
        }

        let missingOwners = Array(expectedOwners.subtracting(authorizedOwners)).sorted()
        let selectedArchivedRepositories = Array(explicitRepositories.intersection(archivedRepositories)).sorted()
        if !selectedArchivedRepositories.isEmpty {
            throw GitHubAuthError.archivedRepositories(selectedArchivedRepositories)
        }
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
            missingRepositories: missingRepositories,
            organizationOwners: Array(organizationOwners).sorted()
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
    ) async throws -> [AccessibleRepository] {
        var page = 1
        var repositories: [AccessibleRepository] = []

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
            repositories.append(contentsOf: response.repositories)

            if response.repositories.count < 100 {
                break
            }

            page += 1
        }

        return repositories
    }

    private func configuredContext() throws -> AuthenticationContext {
        if let message = configuration.missingConfigurationMessage {
            throw GitHubAuthError.missingConfiguration(message)
        }

        return AuthenticationContext(
            configuration: configuration,
            generation: configurationGeneration
        )
    }

    private func ensureCurrent(_ context: AuthenticationContext) throws {
        guard context.generation == configurationGeneration else {
            throw GitHubAuthError.configurationChanged
        }
    }

    private func ensureValidationCurrent(_ context: AuthenticationContext) throws {
        try ensureCurrent(context)
        guard context.configuration == configuration else {
            throw GitHubAuthError.configurationChanged
        }
    }

    private func isDifferentAppIdentity(
        _ lhs: GitHubAuthConfiguration,
        _ rhs: GitHubAuthConfiguration
    ) -> Bool {
        lhs.clientID != rhs.clientID || lhs.appSlug != rhs.appSlug
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
                let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, header in
                    result[String(describing: header.key).lowercased()] = String(describing: header.value)
                }
                throw mapHTTPError(
                    statusCode: httpResponse.statusCode,
                    bodyData: data,
                    headers: headers
                )
            }

            return data
        } catch let error as GitHubAuthError {
            throw error
        } catch {
            throw GitHubAuthError.network(error.localizedDescription)
        }
    }

    private func mapHTTPError(
        statusCode: Int,
        bodyData: Data,
        headers: [String: String]
    ) -> GitHubAuthError {
        let apiError = try? decoder.decode(APIErrorResponse.self, from: bodyData)
        let message = apiError?.message ?? String(decoding: bodyData, as: UTF8.self)
        let normalizedMessage = message.lowercased()

        switch statusCode {
        case 401:
            return .refreshFailed("GitHub sign-in expired. Reconnect in Settings.")
        case 403, 429:
            if statusCode == 429 || isRateLimited(headers: headers, normalizedMessage: normalizedMessage) {
                return .rateLimited(rateLimitMessage(headers: headers))
            }
            if normalizedMessage.contains("saml") || normalizedMessage.contains("single sign-on") {
                return .ssoRequired([], "Your GitHub authorization needs SSO for one or more watched owners.")
            }

            return .installationMissing([], [], message.isEmpty ? "GitHub denied access to one or more watched owners or repositories." : message)
        case 500...599:
            return .network("GitHub API error \(statusCode): \(message)")
        default:
            return .invalidResponse("GitHub API error \(statusCode): \(message)")
        }
    }

    private func isRateLimited(headers: [String: String], normalizedMessage: String) -> Bool {
        if normalizedMessage.contains("rate limit") {
            return true
        }

        return headerValue("x-ratelimit-remaining", in: headers) == "0"
            || headerValue("retry-after", in: headers) != nil
    }

    private func rateLimitMessage(headers: [String: String]) -> String {
        if let retryAfter = headerValue("retry-after", in: headers) {
            return "GitHub rate limit reached. Try again in \(retryAfter) seconds."
        }

        guard let resetValue = headerValue("x-ratelimit-reset", in: headers),
              let resetTimestamp = TimeInterval(resetValue)
        else {
            return "GitHub rate limit reached. Try again shortly."
        }

        let resetDate = Date(timeIntervalSince1970: resetTimestamp)
        return "GitHub rate limit reached. Try again after \(resetDate.formatted(date: .omitted, time: .shortened))."
    }

    private func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers[name.lowercased()]
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
