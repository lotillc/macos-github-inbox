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

    @Published private(set) var hasStoredToken: Bool

    static let defaultRefreshIntervalMinutes = 5
    static let supportedRefreshIntervals = [1, 5, 10, 15, 30, 60]

    private let userDefaults: UserDefaults
    private let tokenStore: KeychainTokenStore

    init(
        userDefaults: UserDefaults = .standard,
        tokenStore: KeychainTokenStore = .shared
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
        hasStoredToken = tokenStore.hasToken()
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

    func reloadTokenPresence() {
        hasStoredToken = tokenStore.hasToken()
    }
}
