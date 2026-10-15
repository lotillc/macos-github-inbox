import Foundation
import Testing
@testable import GitHubPRInbox

struct WorkflowRunIdentityTests {
    @Test
    func decodesRunIdentityWhileAcceptingMissingOptionalMetadata() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkflowIdentityURLProtocol.self]
        let client = GitHubClient(session: URLSession(configuration: configuration), tokenProvider: { "test-token" })
        let items = try await client.fetchFailedWorkflowRuns(repositoryNames: ["acme/app"], trackedWorkflowNames: ["CI/CD"])

        #expect(items.count == 2)
        #expect(items[0].runNumber == 42)
        #expect(items[0].displayTitle == "Fix deployment timeout")
        #expect(items[0].headSHA == "abcdef123456")
        #expect(items[0].runTitle == "CI/CD #42 · Fix deployment timeout")
        #expect(items[1].runNumber == nil)
        #expect(items[1].displayTitle == nil)
        #expect(items[1].headSHA == nil)
        #expect(items[1].runTitle == "CI/CD")
    }
}

private final class WorkflowIdentityURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let body = #"""
        {"workflow_runs": [
          {"id": 100, "name": "CI/CD", "run_number": 42,
           "display_title": "Fix deployment timeout", "head_sha": "abcdef123456",
           "head_branch": "main", "html_url": "https://github.com/acme/app/actions/runs/100",
           "status": "completed", "conclusion": "failure",
           "created_at": "2026-10-14T10:00:00Z", "updated_at": "2026-10-14T10:05:00Z"},
          {"id": 101, "name": "CI/CD", "head_branch": "main",
           "html_url": "https://github.com/acme/app/actions/runs/101",
           "status": "completed", "conclusion": "failure",
           "created_at": "2026-10-14T09:00:00Z", "updated_at": "2026-10-14T09:05:00Z"}
        ]}
        """#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
