import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let allowlistText = "allowlistText"
        static let trackedWorkflowNamesText = "trackedWorkflowNamesText"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        static let sortOption = "sortOption"
        static let launchAtLoginRequested = "launchAtLoginRequested"
        static let gitHubAppClientID = "gitHubAppClientID"
        static let gitHubAppSlug = "gitHubAppSlug"
        static let gitHubAppExpectedOwner = "gitHubAppExpectedOwner"
    }

    @Published var allowlistText: String {
        didSet {
            userDefaults.set(allowlistText, forKey: Keys.allowlistText)
        }
    }

    @Published var trackedWorkflowNamesText: String {
        didSet {
            userDefaults.set(trackedWorkflowNamesText, forKey: Keys.trackedWorkflowNamesText)
        }
    }

    @Published var refreshIntervalMinutes: Int {
        didSet {
            let clamped = Self.supportedRefreshIntervals.contains(refreshIntervalMinutes)
                ? refreshIntervalMinutes
                : Self.defaultRefreshIntervalMinutes

            if refreshIntervalMinutes != clamped {
                refreshIntervalMinutes = clamped
                return
            }

            userDefaults.set(refreshIntervalMinutes, forKey: Keys.refreshIntervalMinutes)
        }
    }

    @Published var sortOption: PullRequestSortOption {
        didSet {
            userDefaults.set(sortOption.rawValue, forKey: Keys.sortOption)
        }
    }

    @Published var launchAtLoginRequested: Bool {
        didSet {
            userDefaults.set(launchAtLoginRequested, forKey: Keys.launchAtLoginRequested)
        }
    }

    @Published private(set) var gitHubAppClientID: String
    @Published private(set) var gitHubAppSlug: String
    @Published private(set) var gitHubAppExpectedOwner: String

    @Published private(set) var hasStoredCredentials: Bool

    static let defaultRefreshIntervalMinutes = 5
    static let supportedRefreshIntervals = [1, 5, 10, 15, 30, 60]

    private let userDefaults: UserDefaults
    private let tokenStore: KeychainTokenStore

    init(
        userDefaults: UserDefaults = .standard,
        tokenStore: KeychainTokenStore = .shared,
        buildDefaultConfiguration: GitHubAuthConfiguration = .load()
    ) {
        self.userDefaults = userDefaults
        self.tokenStore = tokenStore

        let storedRefreshInterval = userDefaults.integer(forKey: Keys.refreshIntervalMinutes)
        let refreshInterval = Self.supportedRefreshIntervals.contains(storedRefreshInterval)
            ? storedRefreshInterval
            : Self.defaultRefreshIntervalMinutes

        allowlistText = userDefaults.string(forKey: Keys.allowlistText) ?? ""
        trackedWorkflowNamesText = userDefaults.string(forKey: Keys.trackedWorkflowNamesText) ?? ""
        refreshIntervalMinutes = refreshInterval

        let storedSortOption = userDefaults.string(forKey: Keys.sortOption) ?? PullRequestSortOption.recentlyUpdatedFirst.rawValue
        sortOption = PullRequestSortOption(rawValue: storedSortOption) ?? .recentlyUpdatedFirst

        launchAtLoginRequested = userDefaults.bool(forKey: Keys.launchAtLoginRequested)
        gitHubAppClientID = Self.persistedValue(
            forKey: Keys.gitHubAppClientID,
            userDefaults: userDefaults,
            fallback: buildDefaultConfiguration.clientID
        )
        gitHubAppSlug = Self.persistedValue(
            forKey: Keys.gitHubAppSlug,
            userDefaults: userDefaults,
            fallback: buildDefaultConfiguration.appSlug
        )
        gitHubAppExpectedOwner = Self.persistedValue(
            forKey: Keys.gitHubAppExpectedOwner,
            userDefaults: userDefaults,
            fallback: buildDefaultConfiguration.expectedOwners.joined(separator: ", ")
        )
        hasStoredCredentials = tokenStore.hasCredentials()
    }

    var gitHubAppConfiguration: GitHubAuthConfiguration {
        GitHubAuthConfiguration(
            clientID: gitHubAppClientID,
            appSlug: gitHubAppSlug,
            expectedOwners: GitHubAuthConfiguration.expectedOwners(from: gitHubAppExpectedOwner)
        )
    }

    var scopes: [RepositoryScope] {
        AllowlistParser.parseScopes(from: allowlistText)
    }

    var trackedWorkflowNames: [String] {
        trackedWorkflowNamesText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var explicitRepositoryScopes: [String] {
        scopes.compactMap { scope in
            guard case let .repo(repoName) = scope else {
                return nil
            }

            return repoName
        }
    }

    func reloadCredentialPresence() {
        hasStoredCredentials = tokenStore.hasCredentials()
    }

    func saveGitHubAppConfiguration(
        clientID: String,
        appSlug: String,
        expectedOwner: String
    ) throws -> GitHubAuthConfiguration {
        let configuration = GitHubAuthConfiguration(
            clientID: clientID,
            appSlug: appSlug,
            expectedOwners: GitHubAuthConfiguration.expectedOwners(from: expectedOwner)
        )

        if let message = configuration.missingConfigurationMessage {
            throw GitHubAuthError.missingConfiguration(message)
        }

        gitHubAppClientID = configuration.clientID
        gitHubAppSlug = configuration.appSlug
        gitHubAppExpectedOwner = configuration.expectedOwners.joined(separator: ", ")
        userDefaults.set(gitHubAppClientID, forKey: Keys.gitHubAppClientID)
        userDefaults.set(gitHubAppSlug, forKey: Keys.gitHubAppSlug)
        userDefaults.set(gitHubAppExpectedOwner, forKey: Keys.gitHubAppExpectedOwner)
        return configuration
    }

    private static func persistedValue(
        forKey key: String,
        userDefaults: UserDefaults,
        fallback: String
    ) -> String {
        if let value = userDefaults.object(forKey: key) as? String {
            return value
        }

        userDefaults.set(fallback, forKey: key)
        return fallback
    }
}
