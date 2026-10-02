import Foundation
import Testing
@testable import GitHubPRInbox

struct InboxListFilterTests {
    private func pullRequest(number: Int = 7748, title: String = "Fix Café refresh") -> PullRequestItem {
        PullRequestItem(id: "acme/app#\(number)", repositoryName: "acme/app", number: number,
                        title: title, url: URL(string: "https://github.com/acme/app/pull/\(number)")!,
                        createdAt: .now, updatedAt: .now, isDraft: false)
    }

    @Test(arguments: ["7748", "#7748", "7,748", "  #7748  ", "CAFÉ", "cafe", "ACME/APP", "refresh"])
    func searchesTitleNumberAndRepository(query: String) {
        #expect(InboxListFilter(searchText: query).matches(pullRequest()))
    }

    @Test
    func combinesRepositoryAndSearchWithoutMatchingPartialNumbers() {
        #expect(!InboxListFilter(searchText: "774", repository: "acme/app").matches(pullRequest()))
        #expect(!InboxListFilter(searchText: "refresh", repository: "other/app").matches(pullRequest()))
        #expect(InboxListFilter(searchText: " \n ", repository: "acme/app").matches(pullRequest()))
    }

    @Test
    func searchesWorkflowNamesAndBranches() {
        let item = WorkflowFailureItem(id: "run", repositoryName: "acme/app", workflowName: "Deploy Production",
                                       branchName: "release/october", url: URL(string: "https://example.com")!,
                                       createdAt: .now, updatedAt: .now)
        #expect(InboxListFilter(searchText: "PRODUCTION").matches(item))
        #expect(InboxListFilter(searchText: "october", needsAttentionOnly: true).matches(item))
        #expect(!InboxListFilter(repository: "other/app").matches(item))
    }

    @Test
    func keepsKnownFailuresWhenThreadCountsAreUnavailable() {
        let filter = InboxListFilter(needsAttentionOnly: true)
        #expect(filter.includes(status: PullRequestStatusSnapshot(status: .failure, debugSummary: "")))
        #expect(filter.includes(status: PullRequestStatusSnapshot(status: .conflicted, debugSummary: "")))
        #expect(filter.includes(status: PullRequestStatusSnapshot(status: .ciPassed, debugSummary: "", unresolvedThreadCount: 2)))
        #expect(!filter.includes(status: PullRequestStatusSnapshot(status: .readyToMerge, debugSummary: "", unresolvedThreadCount: 0)))
        #expect(!filter.includes(status: nil))
        #expect(!filter.includes(status: PullRequestStatusSnapshot(status: .unknown, debugSummary: "")))
        #expect(InboxListFilter().includes(status: nil))
    }

    @Test
    func distinguishesIncompleteStatusFromKnownCleanStatus() {
        #expect(PullRequestStatusSnapshot(status: .ciPassed, debugSummary: "").hasIncompleteAttentionStatus)
        #expect(PullRequestStatusSnapshot(status: .unknown, debugSummary: "", unresolvedThreadCount: 0).hasIncompleteAttentionStatus)
        #expect(!PullRequestStatusSnapshot(status: .ciPassed, debugSummary: "", unresolvedThreadCount: 0).hasIncompleteAttentionStatus)
    }
}
