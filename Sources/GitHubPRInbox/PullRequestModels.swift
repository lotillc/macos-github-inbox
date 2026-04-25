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

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .recentlyUpdatedFirst:
            "Recently Updated First"
        case .oldestFirst:
            "Oldest First"
        }
    }
}

enum RepositoryScope: Hashable, Identifiable {
    case org(String)
    case repo(String)

    var id: String {
        qualifier
    }

    var qualifier: String {
        switch self {
        case let .org(org):
            "org:\(org)"
        case let .repo(repo):
            "repo:\(repo)"
        }
    }

    var displayName: String {
        switch self {
        case let .org(org):
            org
        case let .repo(repo):
            repo
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
}

struct WorkflowFailureItem: Identifiable, Hashable {
    let id: String
    let repositoryName: String
    let workflowName: String
    let branchName: String?
    let url: URL
    let createdAt: Date
    let updatedAt: Date
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
            newIDs = currentIDs.subtracting(previousIDs)
        } else {
            newIDs = []
            hasEstablishedBaseline = true
        }
    }

    mutating func clearNewIDs() {
        newIDs = []
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

        return uniqueByID.values.sorted { lhs, rhs in
            switch sortOption {
            case .recentlyUpdatedFirst:
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.createdAt > rhs.createdAt
                }

                return lhs.updatedAt > rhs.updatedAt
            case .oldestFirst:
                if lhs.createdAt == rhs.createdAt {
                    return lhs.updatedAt < rhs.updatedAt
                }

                return lhs.createdAt < rhs.createdAt
            }
        }
    }
}
