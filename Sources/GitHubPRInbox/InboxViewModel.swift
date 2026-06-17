import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class InboxViewModel: ObservableObject {
    @Published private(set) var reviewRequests: [PullRequestItem] = []
    @Published private(set) var authoredPullRequests: [PullRequestItem] = []
    @Published private(set) var workflowFailures: [WorkflowFailureItem] = []
    @Published private(set) var currentUser: GitHubUser?
    @Published private(set) var authState: GitHubAuthenticationState = .signedOut
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var statusMessage: String?
    @Published private(set) var authStatusMessage: String?
    @Published private(set) var ciStatusesByPullRequestID: [String: PullRequestCIStatus] = [:]
    @Published private(set) var ciDebugSummariesByPullRequestID: [String: String] = [:]
    @Published private(set) var newlyAssignedPullRequestIDs = Set<String>()
    @Published private(set) var newlyAuthoredPullRequestIDs = Set<String>()
    @Published private(set) var newlyWorkflowFailureIDs = Set<String>()

    private let settings: AppSettings
    private let authProvider: GitHubAuthProvider
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
    private var assignedPullRequestNewItemTracker = NewItemTracker()
    private var authoredPullRequestNewItemTracker = NewItemTracker()
    private var workflowFailureNewItemTracker = NewItemTracker()
    private var signInTask: Task<Void, Never>?

    private let authoredQualifier = "is:open is:pr archived:false author:@me"
    private let reviewQualifier = "is:open is:pr archived:false review-requested:@me"

    init(
        settings: AppSettings,
        authProvider: GitHubAuthProvider = GitHubAuthProvider()
    ) {
        self.settings = settings
        self.authProvider = authProvider

        bindSettings()
        configureRefreshTimer(minutes: settings.refreshIntervalMinutes)

        Task {
            await refresh()
        }
    }

    deinit {
        signInTask?.cancel()
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
        settings.scopes.isEmpty || !authState.isAuthenticated
    }

    var appInstallURL: URL? {
        authProvider.configuration.appInstallationURL
    }

    func refresh() async {
        await refreshAuthStatus()

        guard authState.isAuthenticated else {
            clearLoadedData(resetStatus: false)
            statusMessage = authState.guidanceText
            return
        }

        let scopes = settings.scopes
        guard !scopes.isEmpty else {
            clearLoadedData(resetStatus: false)
            statusMessage = "Add at least one org or repo in Settings."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let client = makeClient(scopes: scopes)
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

            if reviewRequests.isEmpty && authoredPullRequests.isEmpty && workflowFailures.isEmpty {
                statusMessage = "No open PRs matched your current filters."
            } else {
                statusMessage = nil
            }
        } catch {
            clearLoadedData(resetStatus: true)
            mapRefreshError(error)
            statusMessage = error.localizedDescription
        }
    }

    func beginSignIn() async {
        signInTask?.cancel()
        authStatusMessage = nil

        do {
            let authorization = try await authProvider.startSignIn(expectedScopes: settings.scopes)
            authState = .authorizing(authorization)
            copyVerificationCodeToPasteboard(authorization.userCode)
            NSWorkspace.shared.open(authorization.browserURL)
            authStatusMessage = "Verification code copied to the clipboard."

            signInTask = Task { [weak self] in
                await self?.completePendingAuthPoll()
            }
        } catch {
            mapAuthError(error)
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil

        Task {
            await authProvider.cancelPendingAuthorization()
            await refreshAuthStatus()
            authStatusMessage = "Canceled GitHub sign-in."
        }
    }

    func completePendingAuthPoll() async {
        while !Task.isCancelled {
            do {
                let result = try await authProvider.pollSignIn(expectedScopes: settings.scopes)

                switch result {
                case let .pending(authorization):
                    authState = .authorizing(authorization)
                    try await Task.sleep(nanoseconds: UInt64(max(authorization.interval, 1) * 1_000_000_000))
                case let .completed(credential):
                    signInTask = nil
                    settings.reloadCredentialPresence()
                    currentUser = GitHubUser(login: credential.userLogin)
                    authStatusMessage = "Signed in as @\(credential.userLogin)."
                    await refreshAuthStatus()
                    await refresh()
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                signInTask = nil
                mapAuthError(error)
                return
            }
        }
    }

    func signOut() {
        signInTask?.cancel()
        signInTask = nil

        Task {
            do {
                try await authProvider.signOut()
                settings.reloadCredentialPresence()
                currentUser = nil
                authState = .signedOut
                authStatusMessage = "Signed out of GitHub."
                statusMessage = "Sign in with GitHub in Settings to load pull requests."
                clearLoadedData(resetStatus: true)
            } catch {
                authStatusMessage = error.localizedDescription
            }
        }
    }

    func refreshAuthStatus() async {
        settings.reloadCredentialPresence()

        if let configurationMessage = authProvider.configuration.missingConfigurationMessage {
            authState = .missingConfiguration(configurationMessage)
            currentUser = nil
            return
        }

        if let pendingAuthorization = await authProvider.pendingAuthorizationState() {
            authState = .authorizing(pendingAuthorization)
            return
        }

        do {
            guard let credential = try await authProvider.currentCredential() else {
                authState = .signedOut
                currentUser = nil
                return
            }

            currentUser = GitHubUser(login: credential.userLogin)

            if settings.scopes.isEmpty {
                authState = .signedIn(
                    GitHubSessionSummary(
                        user: GitHubUser(login: credential.userLogin),
                        tokenExpiresAt: credential.accessTokenExpiresAt,
                        refreshTokenExpiresAt: credential.refreshTokenExpiresAt,
                        authorizedOwners: credential.authorizedOwners,
                        accessibleRepositories: credential.accessibleRepositories
                    )
                )
                return
            }

            let summary = try await authProvider.validateOrgAccess(expectedScopes: settings.scopes)
            currentUser = summary.user
            authState = .signedIn(summary)
        } catch {
            mapAuthError(error)
        }
    }

    func openGitHubVerificationPage() {
        guard case let .authorizing(authorization) = authState else {
            return
        }

        copyVerificationCodeToPasteboard(authorization.userCode)
        NSWorkspace.shared.open(authorization.browserURL)
        authStatusMessage = "Verification code copied to the clipboard."
    }

    func openSSOAuthorization() {
        let owners = ssoOwnerList()
        for owner in owners {
            guard let url = URL(string: "https://github.com/orgs/\(owner)/sso") else {
                continue
            }

            NSWorkspace.shared.open(url)
        }
    }

    func openAppInstallationPage() {
        guard let url = appInstallURL else {
            return
        }

        NSWorkspace.shared.open(url)
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
        assignedPullRequestNewItemTracker.clearNewIDs()
        authoredPullRequestNewItemTracker.clearNewIDs()
        workflowFailureNewItemTracker.clearNewIDs()
        syncNewItemIDs()
    }

    func refreshCIStatuses(for items: [PullRequestItem]) async {
        guard authState.isAuthenticated else {
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

        let client = makeClient(scopes: settings.scopes)
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
            .dropFirst()
            .sink { [weak self] _ in
                self?.applySnapshot(newItemTracking: .preserve)
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

    private enum NewItemTrackingMode {
        case detectArrivals
        case preserve
        case reset
    }

    private func applySnapshot() {
        applySnapshot(newItemTracking: .detectArrivals)
    }

    private func applySnapshot(newItemTracking: NewItemTrackingMode) {
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

        switch newItemTracking {
        case .detectArrivals:
            assignedPullRequestNewItemTracker.detectArrivals(
                currentIDs: currentReviewIDs,
                previousIDs: previousReviewIDs
            )
            authoredPullRequestNewItemTracker.detectArrivals(
                currentIDs: currentAuthoredIDs,
                previousIDs: previousAuthoredIDs
            )
            workflowFailureNewItemTracker.detectArrivals(
                currentIDs: currentWorkflowIDs,
                previousIDs: previousWorkflowFailureIDs
            )
            syncNewItemIDs()
        case .preserve:
            break
        case .reset:
            resetNewItemTrackers()
            syncNewItemIDs()
        }
    }

    private func resetNewItemTrackers() {
        assignedPullRequestNewItemTracker.reset()
        authoredPullRequestNewItemTracker.reset()
        workflowFailureNewItemTracker.reset()
    }

    private func syncNewItemIDs() {
        newlyAssignedPullRequestIDs = assignedPullRequestNewItemTracker.newIDs
        newlyAuthoredPullRequestIDs = authoredPullRequestNewItemTracker.newIDs
        newlyWorkflowFailureIDs = workflowFailureNewItemTracker.newIDs
    }

    private func makeClient(scopes: [RepositoryScope]) -> GitHubClient {
        GitHubClient(authProvider: authProvider, scopes: scopes)
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
        let notificationCenter = UNUserNotificationCenter.current()
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

    private func clearLoadedData(resetStatus: Bool) {
        authoredSource = []
        reviewSource = []
        workflowFailureSource = []
        ciStatusCache = [:]
        ciStatusesByPullRequestID = [:]
        ciDebugSummariesByPullRequestID = [:]
        activeCIFailureAlertIDs = []
        notifiedCIFailureIDs = []
        hasEstablishedCIFailureBaseline = false

        if resetStatus {
            notifiedWorkflowFailureIDs = []
            activeWorkflowFailureAlertIDs = []
            hasEstablishedWorkflowFailureBaseline = false
        }

        applySnapshot(newItemTracking: .reset)
    }

    private func copyVerificationCodeToPasteboard(_ code: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
    }

    private func mapAuthError(_ error: Error) {
        switch error {
        case let authError as GitHubAuthError:
            switch authError {
            case let .missingConfiguration(message):
                authState = .missingConfiguration(message)
            case .signedOut:
                authState = .signedOut
                currentUser = nil
            case .pendingAuthorizationRequired:
                authState = .signedOut
            case let .authorizationDenied(message),
                 let .authorizationExpired(message),
                 let .refreshFailed(message):
                authState = .refreshFailed(message)
            case let .ssoRequired(owners, message):
                authState = .ssoRequired(owners.isEmpty ? watchedOwners() : owners, message)
            case let .installationMissing(owners, repositories, message):
                let identifiers = owners.isEmpty ? repositories : owners
                authState = .installationMissing(identifiers, message)
            case let .invalidResponse(message),
                 let .network(message):
                authState = .refreshFailed(message)
            }
            authStatusMessage = error.localizedDescription
        default:
            authState = .refreshFailed(error.localizedDescription)
            authStatusMessage = error.localizedDescription
        }
    }

    private func mapRefreshError(_ error: Error) {
        if let clientError = error as? GitHubClientError {
            switch clientError {
            case let .unauthorized(message):
                let owners = watchedOwners()
                if message.lowercased().contains("sso") || message.lowercased().contains("single sign-on") {
                    authState = .ssoRequired(owners, message)
                } else {
                    authState = .refreshFailed(message)
                }
            case let .configuration(message):
                authState = .refreshFailed(message)
            case let .invalidResponse(message),
                 let .network(message):
                authStatusMessage = message
            case .missingToken:
                authState = .signedOut
            }
            return
        }

        mapAuthError(error)
    }

    private func watchedOwners() -> [String] {
        Array(Set(settings.scopes.map { $0.ownerName.lowercased() })).sorted()
    }

    private func ssoOwnerList() -> [String] {
        switch authState {
        case let .ssoRequired(owners, _):
            return owners.isEmpty ? watchedOwners() : owners
        default:
            return watchedOwners()
        }
    }
}
