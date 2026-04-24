import Testing
@testable import GitHubPRInbox

struct GitHubClientCITests {
    @Test
    func fallsBackToCombinedStatusWhenCheckRunsAreUnavailable() async {
        let client = GitHubClient(tokenProvider: { "test-token" })
        let combinedStatus = GitHubClient.CombinedStatusResponse(
            state: "success",
            statuses: [GitHubClient.CommitStatus(state: "success", context: "build", description: "passed")]
        )

        let snapshot = await client.mergeCIState(
            combinedStatus: combinedStatus,
            checkRuns: nil
        )

        #expect(snapshot.status == .ciPassed)
        #expect(snapshot.debugSummary.contains("combined=success"))
    }

    @Test
    func reportsInProgressWhenPendingCombinedStatusExistsWithoutCheckRuns() async {
        let client = GitHubClient(tokenProvider: { "test-token" })
        let combinedStatus = GitHubClient.CombinedStatusResponse(
            state: "pending",
            statuses: [GitHubClient.CommitStatus(state: "pending", context: "build", description: "running")]
        )

        let snapshot = await client.mergeCIState(
            combinedStatus: combinedStatus,
            checkRuns: nil
        )

        #expect(snapshot.status == .inProgress)
    }

    @Test
    func returnsReadyToMergeWhenCiPassedAndReviewApproved() async {
        let client = GitHubClient(tokenProvider: { "test-token" })
        let combinedStatus = GitHubClient.CombinedStatusResponse(
            state: "success",
            statuses: [GitHubClient.CommitStatus(state: "success", context: "build", description: "passed")]
        )
        let reviews = [
            GitHubClient.PullRequestReviewResponse(
                state: "APPROVED",
                user: GitHubClient.ReviewUser(login: "jane"),
                submittedAt: nil
            ),
        ]

        let snapshot = await client.mergeCIState(
            combinedStatus: combinedStatus,
            checkRuns: nil,
            reviews: reviews,
            isDraft: false
        )

        #expect(snapshot.status == .readyToMerge)
    }

    @Test
    func treatsAwaitingApprovalOnlyStatusAsCiPassedInsteadOfUnknown() async {
        let client = GitHubClient(tokenProvider: { "test-token" })
        let combinedStatus = GitHubClient.CombinedStatusResponse(
            state: "pending",
            statuses: [
                GitHubClient.CommitStatus(
                    state: "pending",
                    context: "required_reviewers",
                    description: "Awaiting approval"
                ),
            ]
        )

        let snapshot = await client.mergeCIState(
            combinedStatus: combinedStatus,
            checkRuns: nil,
            reviews: nil,
            isDraft: false
        )

        #expect(snapshot.status == .ciPassed)
    }

    @Test
    func treatsNeutralCombinedStatusAsCiPassedWhenNoChecksAreRunning() async {
        let client = GitHubClient(tokenProvider: { "test-token" })
        let combinedStatus = GitHubClient.CombinedStatusResponse(
            state: "neutral",
            statuses: []
        )

        let snapshot = await client.mergeCIState(
            combinedStatus: combinedStatus,
            checkRuns: nil,
            reviews: nil,
            isDraft: false
        )

        #expect(snapshot.status == .ciPassed)
    }

    @Test
    func surfacesMergeConflictsAsDedicatedStatus() async {
        let client = GitHubClient(tokenProvider: { "test-token" })
        let combinedStatus = GitHubClient.CombinedStatusResponse(
            state: "success",
            statuses: [GitHubClient.CommitStatus(state: "success", context: "build", description: "passed")]
        )

        let snapshot = await client.mergeCIState(
            combinedStatus: combinedStatus,
            checkRuns: nil,
            reviews: nil,
            isDraft: false,
            mergeable: "CONFLICTING",
            mergeStateStatus: "DIRTY"
        )

        #expect(snapshot.status == .conflicted)
        #expect(snapshot.debugSummary.contains("merge=conflicting/dirty"))
    }
}
