import Combine
import Foundation
import UserNotifications

@MainActor
final class InboxViewModel: ObservableObject {
    @Published private(set) var reviewRequests: [PullRequestItem] = []
    @Published private(set) var authoredPullRequests: [PullRequestItem] = []
    @Published private(set) var workflowFailures: [WorkflowFailureItem] = []
    @Published private(set) var currentUser: GitHubUser?
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var statusMessage: String?
    @Published private(set) var tokenStatusMessage: String?
    @Published private(set) var ciStatusesByPullRequestID: [String: PullRequestCIStatus] = [:]
    @Published private(set) var ciDebugSummariesByPullRequestID: [String: String] = [:]
    @Published private(set) var newlyAssignedPullRequestIDs = Set<String>()
    @Published private(set) var newlyAuthoredPullRequestIDs = Set<String>()
    @Published private(set) var newlyWorkflowFailureIDs = Set<String>()

    private let settings: AppSettings
    private let tokenStore: KeychainTokenStore
    private let notificationCenter = UNUserNotificationCenter.current()

    private var authoredSource: [PullRequestItem] = []
    private var reviewSource: [PullRequestItem] = []
    private var workflowFailureSource: [WorkflowFailureItem] = []
    private var timerCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var ciStatusCache: [String: (updatedAt: Date, snapshot: PullRequestStatusSnapshot)] = [:]
    private var notifiedWorkflowFailureIDs = Set<String>()
    private var activeWorkflowFailureAlertIDs = Set<String>()
    private var hasEstablishedWorkflowFailureBaseline = false
    private var notifiedCIFailureIDs = Set<String>()
    private var activeCIFailureAlertIDs = Set<String>()
    private var hasEstablishedCIFailureBaseline = false
    private var hasEstablishedReviewBaseline = false
    private var hasEstablishedAuthoredBaseline = false

    private let authoredQualifier = "is:open is:pr archived:false author:@me"
    private let reviewQualifier = "is:open is:pr archived:false review-requested:@me"

    init(
        settings: AppSettings,
        tokenStore: KeychainTokenStore = .shared
    ) {
        self.settings = settings
        self.tokenStore = tokenStore

        bindSettings()
        configureRefreshTimer(minutes: settings.refreshIntervalMinutes)

        Task {
            await refresh()
        }
    }

    var reviewRequestCount: Int {
        reviewRequests.count
    }

    var workflowFailureCount: Int {
        workflowFailures.count
    }

    var actionableInboxCount: Int {
        reviewRequests.count + workflowFailures.count
    }

    var totalTrackedPullRequestCount: Int {
        reviewRequests.count + authoredPullRequests.count
    }

    var hasWorkflowFailureAlert: Bool {
        !activeWorkflowFailureAlertIDs.isEmpty
    }

    var hasActiveAlert: Bool {
        !activeWorkflowFailureAlertIDs.isEmpty || !activeCIFailureAlertIDs.isEmpty
    }

    var hasConfigurationIssue: Bool {
        !settings.hasStoredToken || settings.scopes.isEmpty
    }

    func refresh() async {
        guard settings.hasStoredToken else {
            authoredSource = []
            reviewSource = []
            workflowFailureSource = []
            ciStatusCache = [:]
            ciStatusesByPullRequestID = [:]
            ciDebugSummariesByPullRequestID = [:]
            newlyAssignedPullRequestIDs = []
            newlyAuthoredPullRequestIDs = []
            newlyWorkflowFailureIDs = []
            activeCIFailureAlertIDs = []
            notifiedCIFailureIDs = []
            hasEstablishedCIFailureBaseline = false
            hasEstablishedReviewBaseline = false
            hasEstablishedAuthoredBaseline = false
            applySnapshot()
            statusMessage = "Add a GitHub PAT in Settings to load pull requests."
            return
        }

        let scopes = settings.scopes
        guard !scopes.isEmpty else {
            authoredSource = []
            reviewSource = []
            workflowFailureSource = []
            ciStatusCache = [:]
            ciStatusesByPullRequestID = [:]
            ciDebugSummariesByPullRequestID = [:]
            newlyAssignedPullRequestIDs = []
            newlyAuthoredPullRequestIDs = []
            newlyWorkflowFailureIDs = []
            activeCIFailureAlertIDs = []
            notifiedCIFailureIDs = []
            hasEstablishedCIFailureBaseline = false
            hasEstablishedReviewBaseline = false
            hasEstablishedAuthoredBaseline = false
            applySnapshot()
            statusMessage = "Add at least one org or repo in Settings."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let client = makeClient()
            let user = try await client.validateToken()
            async let reviewItems = client.fetchOpenPullRequests(filter: reviewQualifier, scopes: scopes)
            async let authoredItems = client.fetchOpenPullRequests(filter: authoredQualifier, scopes: scopes)
            async let trackedWorkflowFailures = client.fetchFailedWorkflowRuns(
                repositoryNames: settings.explicitRepositoryScopes,
                trackedWorkflowNames: settings.trackedWorkflowNames
            )

            currentUser = user
            reviewSource = try await reviewItems
            authoredSource = try await authoredItems
            workflowFailureSource = try await trackedWorkflowFailures
            applySnapshot()
            lastRefreshAt = Date()
            await updateWorkflowFailureAlerts()
            await refreshCIStatusesForVisibleItems()

            if reviewRequests.isEmpty && authoredPullRequests.isEmpty && self.workflowFailures.isEmpty {
                statusMessage = "No open PRs matched your current filters."
            } else {
                statusMessage = nil
            }
        } catch {
            authoredSource = []
            reviewSource = []
            workflowFailureSource = []
            applySnapshot()
            statusMessage = error.localizedDescription
        }
    }

    func saveToken(_ token: String) async {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedToken.isEmpty {
            do {
                try tokenStore.deleteToken()
                settings.reloadTokenPresence()
                tokenStatusMessage = "Removed the stored token."
                await refresh()
            } catch {
                tokenStatusMessage = error.localizedDescription
            }

            return
        }

        do {
            let validationClient = GitHubClient(tokenProvider: { trimmedToken })
            let user = try await validationClient.validateToken()
            try tokenStore.save(token: trimmedToken)
            settings.reloadTokenPresence()
            currentUser = user
            tokenStatusMessage = "Saved token for @\(user.login)."
            await refresh()
        } catch {
            tokenStatusMessage = error.localizedDescription
        }
    }

    func deleteToken() {
        do {
            try tokenStore.deleteToken()
            settings.reloadTokenPresence()
            tokenStatusMessage = "Removed the stored token."
            currentUser = nil
            authoredSource = []
            reviewSource = []
            workflowFailureSource = []
            ciStatusCache = [:]
            ciStatusesByPullRequestID = [:]
            ciDebugSummariesByPullRequestID = [:]
            newlyAssignedPullRequestIDs = []
            newlyAuthoredPullRequestIDs = []
            newlyWorkflowFailureIDs = []
            notifiedWorkflowFailureIDs = []
            activeWorkflowFailureAlertIDs = []
            hasEstablishedWorkflowFailureBaseline = false
            notifiedCIFailureIDs = []
            activeCIFailureAlertIDs = []
            hasEstablishedCIFailureBaseline = false
            hasEstablishedReviewBaseline = false
            hasEstablishedAuthoredBaseline = false
            applySnapshot()
            statusMessage = "Add a GitHub PAT in Settings to load pull requests."
        } catch {
            tokenStatusMessage = error.localizedDescription
        }
    }

    func loadStoredToken() -> String {
        (try? tokenStore.loadToken()) ?? ""
    }

    func ciStatus(for item: PullRequestItem) -> PullRequestCIStatus {
        ciStatusesByPullRequestID[item.id] ?? .unknown
    }

    func ciDebugSummary(for item: PullRequestItem) -> String? {
        ciDebugSummariesByPullRequestID[item.id]
    }

    func acknowledgeAlerts() {
        activeWorkflowFailureAlertIDs = []
        activeCIFailureAlertIDs = []
    }

    func acknowledgeSeenChanges() {
        newlyAssignedPullRequestIDs = []
        newlyAuthoredPullRequestIDs = []
        newlyWorkflowFailureIDs = []
    }

    func refreshCIStatuses(for items: [PullRequestItem]) async {
        guard settings.hasStoredToken else {
            return
        }

        let uncachedItems = items.filter { item in
            guard let cached = ciStatusCache[item.id] else {
                return true
            }

            return cached.updatedAt != item.updatedAt
        }

        guard !uncachedItems.isEmpty else {
            for item in items {
                if let cached = ciStatusCache[item.id] {
                    ciStatusesByPullRequestID[item.id] = cached.snapshot.status
                    ciDebugSummariesByPullRequestID[item.id] = cached.snapshot.debugSummary
                }
            }
            return
        }

        let client = makeClient()
        do {
            let snapshotsByItemID = try await client.fetchCIStatusSnapshots(for: uncachedItems)

            for item in uncachedItems {
                if let snapshot = snapshotsByItemID[item.id] {
                    ciStatusCache[item.id] = (updatedAt: item.updatedAt, snapshot: snapshot)
                    ciStatusesByPullRequestID[item.id] = snapshot.status
                    ciDebugSummariesByPullRequestID[item.id] = snapshot.debugSummary
                } else {
                    ciStatusesByPullRequestID[item.id] = .unknown
                    ciDebugSummariesByPullRequestID[item.id] = "error=No CI snapshot returned"
                }
            }
        } catch {
            for item in uncachedItems {
                ciStatusesByPullRequestID[item.id] = .unknown
                ciDebugSummariesByPullRequestID[item.id] = "error=\(error.localizedDescription)"
            }
        }

        for item in items {
            if let cached = ciStatusCache[item.id] {
                ciStatusesByPullRequestID[item.id] = cached.snapshot.status
                ciDebugSummariesByPullRequestID[item.id] = cached.snapshot.debugSummary
            }
        }

        await updateCIFailureAlerts(for: items)
    }

    private func bindSettings() {
        settings.$sortOption
            .sink { [weak self] _ in
                self?.applySnapshot()
            }
            .store(in: &cancellables)

        settings.$refreshIntervalMinutes
            .removeDuplicates()
            .sink { [weak self] minutes in
                self?.configureRefreshTimer(minutes: minutes)
            }
            .store(in: &cancellables)
    }

    private func configureRefreshTimer(minutes: Int) {
        timerCancellable = Timer.publish(
            every: TimeInterval(minutes * 60),
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            Task {
                await self?.refresh()
            }
        }
    }

    private func applySnapshot() {
        let previousReviewIDs = Set(reviewRequests.map(\.id))
        let previousAuthoredIDs = Set(authoredPullRequests.map(\.id))
        let previousWorkflowFailureIDs = Set(workflowFailures.map(\.id))

        let snapshot = PullRequestStore.makeSnapshot(
            reviewRequests: reviewSource,
            authoredPullRequests: authoredSource,
            workflowFailures: workflowFailureSource,
            sortOption: settings.sortOption
        )

        reviewRequests = snapshot.reviewRequests
        authoredPullRequests = snapshot.authoredPullRequests
        workflowFailures = snapshot.workflowFailures

        let currentReviewIDs = Set(snapshot.reviewRequests.map(\.id))
        let currentAuthoredIDs = Set(snapshot.authoredPullRequests.map(\.id))
        let currentWorkflowIDs = Set(snapshot.workflowFailures.map(\.id))

        if hasEstablishedReviewBaseline {
            newlyAssignedPullRequestIDs = currentReviewIDs.subtracting(previousReviewIDs)
        } else {
            newlyAssignedPullRequestIDs = []
            hasEstablishedReviewBaseline = true
        }

        if hasEstablishedAuthoredBaseline {
            newlyAuthoredPullRequestIDs = currentAuthoredIDs.subtracting(previousAuthoredIDs)
        } else {
            newlyAuthoredPullRequestIDs = []
            hasEstablishedAuthoredBaseline = true
        }

        if hasEstablishedWorkflowFailureBaseline {
            newlyWorkflowFailureIDs = currentWorkflowIDs.subtracting(previousWorkflowFailureIDs)
        } else {
            newlyWorkflowFailureIDs = []
        }
    }

    private func makeClient() -> GitHubClient {
        GitHubClient { [tokenStore] in
            try tokenStore.loadToken()
        }
    }

    private func refreshCIStatusesForVisibleItems() async {
        let currentVisibleItems = Array(reviewRequests.prefix(24)) + Array(authoredPullRequests.prefix(24))
        await refreshCIStatuses(for: currentVisibleItems)
    }

    private func updateWorkflowFailureAlerts() async {
        let currentFailureIDs = Set(workflowFailures.map(\.id))
        activeWorkflowFailureAlertIDs = activeWorkflowFailureAlertIDs.intersection(currentFailureIDs)

        if !hasEstablishedWorkflowFailureBaseline {
            notifiedWorkflowFailureIDs.formUnion(currentFailureIDs)
            hasEstablishedWorkflowFailureBaseline = true
            return
        }

        let newFailures = workflowFailures.filter { !notifiedWorkflowFailureIDs.contains($0.id) }
        guard !newFailures.isEmpty else {
            return
        }

        let newFailureIDs = Set(newFailures.map(\.id))
        activeWorkflowFailureAlertIDs.formUnion(newFailureIDs)
        notifiedWorkflowFailureIDs.formUnion(newFailureIDs)

        for failure in newFailures {
            await deliverNotification(
                identifier: "workflow-\(failure.id)",
                title: "Workflow Failed",
                body: "\(failure.workflowName) failed in \(failure.repositoryName)"
            )
        }
    }

    private func updateCIFailureAlerts(for items: [PullRequestItem]) async {
        let currentFailureIDs = Set(
            items
                .filter { ciStatusesByPullRequestID[$0.id] == .failure }
                .map(\.id)
        )
        activeCIFailureAlertIDs = activeCIFailureAlertIDs.intersection(currentFailureIDs)

        if !hasEstablishedCIFailureBaseline {
            notifiedCIFailureIDs.formUnion(currentFailureIDs)
            hasEstablishedCIFailureBaseline = true
            return
        }

        let newFailureItems = items.filter {
            ciStatusesByPullRequestID[$0.id] == .failure && !notifiedCIFailureIDs.contains($0.id)
        }
        guard !newFailureItems.isEmpty else {
            return
        }

        let newFailureIDs = Set(newFailureItems.map(\.id))
        activeCIFailureAlertIDs.formUnion(newFailureIDs)
        notifiedCIFailureIDs.formUnion(newFailureIDs)

        for item in newFailureItems {
            await deliverNotification(
                identifier: "ci-\(item.id)",
                title: "CI Failed",
                body: "\(item.repositoryName) #\(item.number) failed checks"
            )
        }
    }

    private func deliverNotification(identifier: String, title: String, body: String) async {
        let granted = try? await notificationCenter.requestAuthorization(options: [.badge, .sound, .alert])
        guard granted == true else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        try? await notificationCenter.add(request)
    }
}
