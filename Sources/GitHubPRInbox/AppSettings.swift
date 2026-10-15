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

/// Editable preferences stay local until Save changes is selected.
struct SettingsDraft: Equatable {
    var watchScopes: Set<RepositoryScope> = []
    var trackedWorkflows: String = ""
    var clientID: String = ""
    var appSlug: String = ""
    var expectedOwners: String = ""
    var refreshInterval: Int = 5
    var sortOption: PullRequestSortOption = .recentlyUpdatedFirst
    var launchAtLogin: Bool = false

    init() {}

    @MainActor
    init(settings: AppSettings) {
        watchScopes = Set(settings.scopes)
        trackedWorkflows = settings.trackedWorkflowNamesText
        clientID = settings.gitHubAppClientID
        appSlug = settings.gitHubAppSlug
        expectedOwners = settings.gitHubAppExpectedOwner
        refreshInterval = settings.refreshIntervalMinutes
        sortOption = settings.sortOption
        launchAtLogin = settings.launchAtLoginRequested
    }

    /// Incorporate externally saved preferences without discarding local edits.
    static func rebased(_ draft: Self, from previous: Self, onto current: Self) -> Self {
        var result = draft
        if draft.watchScopes == previous.watchScopes { result.watchScopes = current.watchScopes }
        if draft.trackedWorkflows == previous.trackedWorkflows { result.trackedWorkflows = current.trackedWorkflows }
        if draft.clientID == previous.clientID { result.clientID = current.clientID }
        if draft.appSlug == previous.appSlug { result.appSlug = current.appSlug }
        if draft.expectedOwners == previous.expectedOwners { result.expectedOwners = current.expectedOwners }
        if draft.refreshInterval == previous.refreshInterval { result.refreshInterval = current.refreshInterval }
        if draft.sortOption == previous.sortOption { result.sortOption = current.sortOption }
        if draft.launchAtLogin == previous.launchAtLogin { result.launchAtLogin = current.launchAtLogin }
        return result
    }

    static func preparedForSaving(_ draft: Self, from previous: Self, onto current: Self,
                                  excluding archivedRepositories: Set<String>, availableRepositories: Set<String> = []) -> Self {
        var result = rebased(draft, from: previous, onto: current)
        let archived = Set(archivedRepositories.map { $0.lowercased() })
            .subtracting(availableRepositories.map { $0.lowercased() })
        result.watchScopes = Set(result.watchScopes.filter { scope in
            guard case let .repo(repository) = scope else { return true }
            return !archived.contains(repository.lowercased())
        })
        return result
    }

}
