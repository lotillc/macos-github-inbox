import Foundation
import SwiftUI

enum PullRequestCIStatus: String, Codable, Equatable {
    case unknown
    case conflicted
    case ciPassed
    case readyToMerge
    case success
    case inProgress
    case failure

    var indicatorColor: Color {
        switch self {
        case .unknown:
            .secondary.opacity(0.45)
        case .conflicted:
            .orange
        case .ciPassed, .readyToMerge, .success:
            .green
        case .inProgress:
            .orange
        case .failure:
            .red
        }
    }

    var symbolName: String {
        switch self {
        case .unknown:
            "circle.dashed"
        case .conflicted:
            "arrow.triangle.branch"
        case .ciPassed:
            "circle.fill"
        case .readyToMerge, .success:
            "checkmark.circle.fill"
        case .inProgress:
            "clock.fill"
        case .failure:
            "xmark.octagon.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .unknown:
            "CI status unknown"
        case .conflicted:
            "Merge conflicts"
        case .ciPassed:
            "CI checks passed"
        case .readyToMerge:
            "Approved and ready to merge"
        case .success:
            "Approved and ready to merge"
        case .inProgress:
            "CI checks in progress"
        case .failure:
            "CI checks failed"
        }
    }
}

enum PullRequestSortOption: String, CaseIterable, Identifiable {
    case recentlyUpdatedFirst
    case oldestFirst
    case highestNumberFirst
    case lowestNumberFirst

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .recentlyUpdatedFirst:
            "Recently Updated First"
        case .oldestFirst:
            "Oldest First"
        case .highestNumberFirst:
            "PR Number ↓"
        case .lowestNumberFirst:
            "PR Number ↑"
        }
    }
}

enum RepositoryScope: Hashable, Identifiable {
    case org(String)
    case user(String)
    case repo(String)

    var id: String {
        qualifier
    }

    var qualifier: String {
        switch self {
        case let .org(org):
            "org:\(org)"
        case let .user(user):
            "user:\(user)"
        case let .repo(repo):
            "repo:\(repo)"
        }
    }

    var displayName: String {
        switch self {
        case let .org(org):
            org
        case let .user(user):
            user
        case let .repo(repo):
            repo
        }
    }
}

extension RepositoryScope {
    var ownerName: String {
        switch self {
        case let .org(org):
            return org
        case let .user(user):
            return user
        case let .repo(repo):
            return repo.split(separator: "/", maxSplits: 1).first.map(String.init) ?? repo
        }
    }
}

struct PullRequestItem: Identifiable, Hashable {
    let id: String
    let repositoryName: String
    let number: Int
    let title: String
    let url: URL
    let createdAt: Date
    let updatedAt: Date
    let isDraft: Bool
}

struct PullRequestStatusSnapshot: Equatable {
    let status: PullRequestCIStatus
    let debugSummary: String
    var unresolvedThreadCount: Int? = nil
    var hasKnownMergeability: Bool = false
}

struct WorkflowFailureItem: Identifiable, Hashable {
    let id: String
    let repositoryName: String
    let workflowName: String
    var runNumber: Int? = nil
    var displayTitle: String? = nil
    var headSHA: String? = nil
    let branchName: String?
    let url: URL
    let createdAt: Date
    let updatedAt: Date
}

extension WorkflowFailureItem {
    var runTitle: String {
        let number = runNumber.map { " #\($0)" } ?? ""
        let summary = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = summary.flatMap { $0.isEmpty || $0 == workflowName ? nil : $0 }
            ?? headSHA.map { String($0.prefix(7)) }
        return "\(workflowName)\(number)" + (identity.map { " · \($0)" } ?? "")
    }

    var detailDescription: String {
        "\(runTitle)\n\(repositoryName) · \(branchName ?? "Unknown branch")\nUpdated \(updatedAt.formatted())"
    }
}

struct InboxSnapshot {
    let reviewRequests: [PullRequestItem]
    let authoredPullRequests: [PullRequestItem]
    let workflowFailures: [WorkflowFailureItem]
}

struct NewItemTracker: Equatable {
    private(set) var hasEstablishedBaseline = false
    private(set) var newIDs = Set<String>()

    mutating func detectArrivals(currentIDs: Set<String>, previousIDs: Set<String>) {
        if hasEstablishedBaseline {
            newIDs = newIDs.union(currentIDs.subtracting(previousIDs)).intersection(currentIDs)
        } else {
            newIDs = []
            hasEstablishedBaseline = true
        }
    }

    mutating func acknowledge(ids: Set<String>) {
        newIDs.subtract(ids)
    }

    mutating func reset() {
        hasEstablishedBaseline = false
        newIDs = []
    }
}

enum PullRequestStore {
    static func makeSnapshot(
        reviewRequests: [PullRequestItem],
        authoredPullRequests: [PullRequestItem],
        workflowFailures: [WorkflowFailureItem],
        sortOption: PullRequestSortOption
    ) -> InboxSnapshot {
        InboxSnapshot(
            reviewRequests: sortAndDeduplicate(reviewRequests, sortOption: sortOption),
            authoredPullRequests: sortAndDeduplicate(authoredPullRequests, sortOption: sortOption),
            workflowFailures: workflowFailures.sorted { lhs, rhs in
                lhs.updatedAt > rhs.updatedAt
            }
        )
    }

    private static func sortAndDeduplicate(
        _ items: [PullRequestItem],
        sortOption: PullRequestSortOption
    ) -> [PullRequestItem] {
        var uniqueByID: [String: PullRequestItem] = [:]

        for item in items {
            if let existing = uniqueByID[item.id] {
                if item.updatedAt > existing.updatedAt {
                    uniqueByID[item.id] = item
                }
            } else {
                uniqueByID[item.id] = item
            }
        }

        return sorted(Array(uniqueByID.values), sortOption: sortOption)
    }

    static func sorted(_ items: [PullRequestItem], sortOption: PullRequestSortOption) -> [PullRequestItem] {
        items.sorted { lhs, rhs in
            switch sortOption {
            case .recentlyUpdatedFirst:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            case .oldestFirst:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            case .highestNumberFirst:
                if lhs.number != rhs.number { return lhs.number > rhs.number }
            case .lowestNumberFirst:
                if lhs.number != rhs.number { return lhs.number < rhs.number }
            }
            return lhs.id < rhs.id
        }
    }
}

struct InboxListFilter: Equatable {
    var searchText = ""
    var repository = ""
    var needsAttentionOnly = false

    func matches(_ item: PullRequestItem) -> Bool {
        guard repository.isEmpty || item.repositoryName == repository else { return false }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let numberQuery = query.hasPrefix("#") ? String(query.dropFirst()) : query
        return item.title.localizedStandardContains(query)
            || item.repositoryName.localizedStandardContains(query)
            || Int(numberQuery.replacingOccurrences(of: ",", with: "")) == item.number
    }

    func matches(_ item: WorkflowFailureItem) -> Bool {
        guard repository.isEmpty || item.repositoryName == repository else { return false }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || item.runTitle.localizedStandardContains(query)
            || item.repositoryName.localizedStandardContains(query)
            || item.branchName?.localizedStandardContains(query) == true
    }

    func includes(status: PullRequestStatusSnapshot?) -> Bool {
        !needsAttentionOnly || status?.needsAttention == true
    }
}

extension PullRequestStatusSnapshot {
    var needsAttention: Bool {
        status == .failure || status == .conflicted || (unresolvedThreadCount ?? 0) > 0
    }

    var hasIncompleteAttentionStatus: Bool {
        status == .unknown || unresolvedThreadCount == nil || !hasKnownMergeability
    }
}

/// A loaded row is only seen once some of it has entered the scroll viewport.
enum InboxRowVisibility {
    static func visibleIDs(frames: [String: CGRect], viewport: CGRect) -> Set<String> {
        guard viewport.width > 0, viewport.height > 0 else { return [] }
        return Set(frames.compactMap { id, frame in
            let overlap = frame.intersection(viewport)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0 ? id : nil
        })
    }
}

struct InboxStatusNotice: Equatable {
    enum Tone { case warning, information }
    let message: String
    var tone: Tone = .warning
    var recoveryAction: InboxRecoveryAction? = nil

    static func failure(_ error: Error) -> Self {
        let requiresSettings: Bool
        if let clientError = error as? GitHubClientError, case .configuration = clientError {
            requiresSettings = true
        } else {
            requiresSettings = false
        }
        return Self(message: error.localizedDescription, recoveryAction: requiresSettings ? .settings : nil)
    }
}

enum InboxRecoveryAction: String {
    case retry = "Retry"
    case settings = "Open Settings"
    case reconnect = "Reconnect"
    case sso = "Open SSO"
    case install = "Install GitHub App"
    case continueSignIn = "Continue Sign-in"

    static func action(for state: GitHubAuthenticationState, informational: Bool) -> Self {
        if informational { return .settings }
        switch state {
        case .missingConfiguration: return .settings
        case .signedOut, .refreshFailed: return .reconnect
        case .authorizing: return .continueSignIn
        case .ssoRequired: return .sso
        case .installationMissing: return .install
        case .signedIn, .rateLimited: return .retry
        }
    }
}
