import Testing
@testable import GitHubPRInbox

struct AllowlistParserTests {
    @Test
    func parsesOrgsAndReposAndDeduplicates() {
        let scopes = AllowlistParser.parseScopes(
            from: """
            acme
            acme/backend
            org:acme
            repo:acme/backend
            """
        )

        #expect(scopes == [.org("acme"), .repo("acme/backend")])
    }

    @Test
    func ignoresInvalidRepoEntries() {
        let scopes = AllowlistParser.parseScopes(
            from: """
            repo:acme
            repo:acme/platform/api
            valid-org
            """
        )

        #expect(scopes == [.org("valid-org")])
    }
}
