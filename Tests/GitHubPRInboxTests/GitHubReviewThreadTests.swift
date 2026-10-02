import Foundation
import Testing
@testable import GitHubPRInbox

@Suite(.serialized)
struct GitHubReviewThreadTests {
    @Test(arguments: [false, true])
    func countsUnresolvedThreadsAcrossPages(secondPageFails: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThreadURLProtocol.self]
        ThreadURLProtocol.failSecondPage = secondPageFails
        let client = GitHubClient(session: URLSession(configuration: configuration), tokenProvider: { "test-token" })
        let item = PullRequestItem(
            id: "acme/app#7", repositoryName: "acme/app", number: 7, title: "Test",
            url: URL(string: "https://github.com/acme/app/pull/7")!,
            createdAt: .now, updatedAt: .now, isDraft: false
        )
        let snapshots = try await client.fetchCIStatusSnapshots(for: [item])
        #expect(snapshots[item.id]?.status == .ciPassed)
        #expect(snapshots[item.id]?.unresolvedThreadCount == (secondPageFails ? nil : 3))
    }
}

private final class ThreadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var failSecondPage = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let size = stream.read(&buffer, maxLength: buffer.count)
                if size <= 0 { break }
                body.append(contentsOf: buffer.prefix(size))
            }
        }
        let isSecondPage = String(decoding: body, as: UTF8.self).contains("ReviewThreads")
        let json: String
        if isSecondPage && Self.failSecondPage {
            json = "{\"errors\":[{\"message\":\"Unavailable\"}]}"
        } else if isSecondPage {
            json = #"{"data":{"repo":{"pr":{"reviewThreads":{"nodes":[{"isResolved":false},{"isResolved":true}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#
        } else {
            json = #"{"data":{"repo0":{"pr0_0":{"reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[]}},"reviewThreads":{"nodes":[{"isResolved":false},{"isResolved":true},{"isResolved":false}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
