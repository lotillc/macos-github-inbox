import Testing
@testable import GitHubPRInbox

struct GitHubSearchQueryBuilderTests {
    @Test
    func buildsOneQueryPerScope() {
        let queries = GitHubSearchQueryBuilder.buildQueries(
            baseQualifier: "is:open is:pr author:@me",
            scopes: [
                .org("acme"),
                .repo("acme/backend"),
            ]
        )

        #expect(queries == [
            "is:open is:pr author:@me org:acme",
            "is:open is:pr author:@me repo:acme/backend",
        ])
    }

    @Test
    func usesUserQualifierForPersonalAccountScope() {
        let queries = GitHubSearchQueryBuilder.buildQueries(
            baseQualifier: "is:open is:pr",
            scopes: [.user("mona")]
        )

        #expect(queries == ["is:open is:pr user:mona"])
    }

    @Test
    func batchesExplicitRepositoriesUnderKnownOwnerIntoOneSearchStream() throws {
        let repositories = (1...120).map { "acme/repo-\($0)" }
        let plans = try GitHubSearchQueryBuilder.buildPlan(
            baseQualifier: "is:open is:pr review-requested:@me",
            scopes: repositories.map(RepositoryScope.repo),
            accessibleRepositoryNames: repositories,
            ownerScopes: [.org("acme")]
        )

        #expect(plans.count == 1)
        #expect(plans[0].query == "is:open is:pr review-requested:@me org:acme")
        #expect(plans[0].allowedRepositoryNames == Set(repositories))
        #expect(plans[0].fallbackQueries.count == 120)
    }

    @Test
    func keepsUnknownOwnerRepositoriesAsDirectSearches() throws {
        let plans = try GitHubSearchQueryBuilder.buildPlan(
            baseQualifier: "is:open is:pr",
            scopes: [.repo("unknown/one"), .repo("unknown/two")]
        )

        #expect(plans.map(\.query) == [
            "is:open is:pr repo:unknown/one",
            "is:open is:pr repo:unknown/two",
        ])
    }

    @Test
    func keepsKnownOwnerRepositoriesDirectWhenInventoryExceedsSearchScopeLimit() throws {
        let repositories = (1...4_001).map { "acme/repo-\($0)" }
        let plans = try GitHubSearchQueryBuilder.buildPlan(
            baseQualifier: "is:open is:pr",
            scopes: [.repo("acme/repo-4001")],
            accessibleRepositoryNames: repositories,
            ownerScopes: [.org("acme")]
        )

        #expect(plans.map(\.query) == ["is:open is:pr repo:acme/repo-4001"])
    }

    @Test
    func rejectsFullOwnerScopeWhenInventoryExceedsSearchScopeLimit() {
        let repositories = (1...4_001).map { "acme/repo-\($0)" }

        #expect(throws: GitHubSearchQueryPlanError.ownerSearchScopeTooLarge("acme")) {
            _ = try GitHubSearchQueryBuilder.buildPlan(
                baseQualifier: "is:open is:pr",
                scopes: [.org("acme")],
                accessibleRepositoryNames: repositories,
                ownerScopes: [.org("acme")]
            )
        }
    }
}
