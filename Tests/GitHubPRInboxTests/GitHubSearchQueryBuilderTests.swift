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
}
