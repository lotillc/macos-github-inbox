import Foundation
import Testing
@testable import GitHubPRInbox

struct PullRequestStoreTests {
    @Test
    func sortsByRecentlyUpdatedDescending() {
        let now = Date(timeIntervalSince1970: 1_000)
        let older = PullRequestItem(
            id: "one",
            repositoryName: "acme/one",
            number: 1,
            title: "Older",
            url: URL(string: "https://example.com/one")!,
            createdAt: now.addingTimeInterval(-400),
            updatedAt: now.addingTimeInterval(-200),
            isDraft: false
        )
        let newer = PullRequestItem(
            id: "two",
            repositoryName: "acme/two",
            number: 2,
            title: "Newer",
            url: URL(string: "https://example.com/two")!,
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-10),
            isDraft: false
        )

        let snapshot = PullRequestStore.makeSnapshot(
            reviewRequests: [older, newer],
            authoredPullRequests: [],
            workflowFailures: [],
            sortOption: .recentlyUpdatedFirst
        )

        #expect(snapshot.reviewRequests.map(\.id) == ["two", "one"])
    }

    @Test
    func sortsByOldestCreationAscending() {
        let now = Date(timeIntervalSince1970: 1_000)
        let oldest = PullRequestItem(
            id: "one",
            repositoryName: "acme/one",
            number: 1,
            title: "Oldest",
            url: URL(string: "https://example.com/one")!,
            createdAt: now.addingTimeInterval(-400),
            updatedAt: now.addingTimeInterval(-20),
            isDraft: false
        )
        let newest = PullRequestItem(
            id: "two",
            repositoryName: "acme/two",
            number: 2,
            title: "Newest",
            url: URL(string: "https://example.com/two")!,
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-200),
            isDraft: false
        )

        let snapshot = PullRequestStore.makeSnapshot(
            reviewRequests: [newest, oldest],
            authoredPullRequests: [],
            workflowFailures: [],
            sortOption: .oldestFirst
        )

        #expect(snapshot.reviewRequests.map(\.id) == ["one", "two"])
    }

    @Test
    func deduplicatesWithinSectionByIdentifier() {
        let now = Date(timeIntervalSince1970: 1_000)
        let stale = PullRequestItem(
            id: "same",
            repositoryName: "acme/one",
            number: 1,
            title: "Stale",
            url: URL(string: "https://example.com/one")!,
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-90),
            isDraft: false
        )
        let fresh = PullRequestItem(
            id: "same",
            repositoryName: "acme/one",
            number: 1,
            title: "Fresh",
            url: URL(string: "https://example.com/one")!,
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-5),
            isDraft: false
        )

        let snapshot = PullRequestStore.makeSnapshot(
            reviewRequests: [stale, fresh],
            authoredPullRequests: [],
            workflowFailures: [],
            sortOption: .recentlyUpdatedFirst
        )

        #expect(snapshot.reviewRequests.count == 1)
        #expect(snapshot.reviewRequests.first?.title == "Fresh")
    }
}
