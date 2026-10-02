import Foundation
import Dispatch
import Testing
@testable import GitHubPRInbox

@Suite(.serialized)
struct GitHubStatusBatchTests {
    private func items(_ count: Int) -> [PullRequestItem] {
        (1...count).map { number in
            PullRequestItem(id: "acme/app#\(number)", repositoryName: "acme/app", number: number,
                            title: "Test", url: URL(string: "https://github.com/acme/app/pull/\(number)")!,
                            createdAt: .now, updatedAt: .now, isDraft: false)
        }
    }

    private func client(mode: StatusBatchRecorder.Mode) -> (GitHubClient, StatusBatchRecorder) {
        let recorder = StatusBatchRecorder(mode: mode)
        StatusBatchURLProtocol.recorder = recorder
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusBatchURLProtocol.self]
        return (GitHubClient(session: URLSession(configuration: configuration), tokenProvider: { "test-token" }), recorder)
    }

    @Test
    func chunksTheWholeQueueIntoBoundedGraphQLRequests() async throws {
        let (client, recorder) = client(mode: .success)
        let snapshots = try await client.fetchCIStatusSnapshots(for: items(55))
        #expect(snapshots.count == 55)
        #expect(recorder.batchCounts == [20, 20, 15])
        #expect(recorder.headRequests == 0)
    }

    @Test
    func boundsFallbackConcurrencyAndTotalWorkAfterGraphQLFailure() async throws {
        let (client, recorder) = client(mode: .fallback)
        let snapshots = try await client.fetchCIStatusSnapshots(for: items(200))
        #expect(snapshots.count == 20)
        #expect(recorder.batchCounts == [20])
        #expect(recorder.headRequests == 20)
        #expect(recorder.maximumActiveRequests <= 12) // Four PRs, at most three REST checks each.
        #expect(recorder.maximumActiveHeads <= 4)
    }

    @Test(arguments: [StatusBatchRecorder.Mode.rateLimited, .graphRateLimited])
    private func doesNotAmplifyRateLimitErrorsWithRestFallback(mode: StatusBatchRecorder.Mode) async {
        let (client, recorder) = client(mode: mode)
        do {
            _ = try await client.fetchCIStatusSnapshots(for: items(200))
            Issue.record("Expected rate limiting.")
        } catch let error as GitHubClientError {
            guard case .rateLimited = error else {
                Issue.record("Expected a rate-limit error, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(recorder.batchCounts == [20])
        #expect(recorder.headRequests == 0)
    }
    @Test
    func preservesASuccessfulResponseUsingTheLastQuotaPoint() async throws {
        let (client, recorder) = client(mode: .successLastQuota)
        let snapshots = try await client.fetchCIStatusSnapshots(for: items(1))
        #expect(snapshots.count == 1)
        #expect(recorder.headRequests == 0)
    }

}

private final class StatusBatchRecorder: @unchecked Sendable {
    enum Mode: Sendable { case success, fallback, rateLimited, graphRateLimited, successLastQuota }
    let mode: Mode
    private let lock = NSLock()
    private var batches: [Int] = []
    private var heads = 0
    private var active = 0
    private var activeHeads = 0
    private var maxActive = 0
    private var maxHeads = 0
    init(mode: Mode) { self.mode = mode }
    var batchCounts: [Int] { lock.withLock { batches } }
    var headRequests: Int { lock.withLock { heads } }
    var maximumActiveRequests: Int { lock.withLock { maxActive } }
    var maximumActiveHeads: Int { lock.withLock { maxHeads } }
    func begin(isHead: Bool, batchCount: Int?) {
        lock.withLock {
            if let batchCount { batches.append(batchCount) }
            active += 1
            maxActive = max(maxActive, active)
            if isHead {
                heads += 1
                activeHeads += 1
                maxHeads = max(maxHeads, activeHeads)
            }
        }
    }
    func end(isHead: Bool) {
        lock.withLock {
            active -= 1
            if isHead { activeHeads -= 1 }
        }
    }
}

private final class StatusBatchURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: StatusBatchRecorder!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let recorder = Self.recorder!
        let url = request.url!
        let isGraphQL = url.path == "/graphql"
        let isHead = url.path.contains("/pulls/") && !url.path.hasSuffix("/reviews")
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
        let count = String(decoding: body, as: UTF8.self).components(separatedBy: "pullRequest(number:").count - 1
        recorder.begin(isHead: isHead, batchCount: isGraphQL ? count : nil)
        let json: String
        var statusCode = 200
        var headers: [String: String] = [:]
        if isGraphQL {
            switch recorder.mode {
            case .success, .successLastQuota:
                if recorder.mode == .successLastQuota { headers = ["X-RateLimit-Remaining": "0"] }
                let node = #"{"reviewDecision":"APPROVED","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[]}},"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}"#
                json = "{\"data\":{\"repo0\":{" + (0..<count).map { "\"pr0_\($0)\":\(node)" }.joined(separator: ",") + "}}}"
            case .fallback:
                json = #"{"errors":[{"message":"GraphQL unavailable"}]}"#
            case .graphRateLimited:
                headers = ["X-RateLimit-Remaining": "0"]
                json = #"{"errors":[{"message":"API rate limit exceeded"}]}"#
            case .rateLimited:
                statusCode = 403
                headers = ["X-RateLimit-Remaining": "0"]
                json = #"{"message":"API rate limit exceeded"}"#
            }
        } else if isHead {
            json = #"{"head":{"sha":"test"}}"#
        } else if url.path.hasSuffix("/status") {
            json = #"{"state":"success","statuses":[]}"#
        } else if url.path.hasSuffix("/check-runs") {
            json = #"{"check_runs":[]}"#
        } else {
            json = "[]"
        }
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
        let data = Data(json.utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) {
            recorder.end(isHead: isHead)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
