import Foundation
import Testing
@testable import GitHubPRInbox

@Suite(.serialized)
struct GitHubAuthProviderTests {
    @Test
    func keychainCredentialRoundTrips() throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "credential-round-trip"
        )
        defer {
            try? store.deleteCredential()
        }

        let credential = GitHubCredential(
            accessToken: "ghu_test",
            refreshToken: "ghr_test",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            refreshTokenExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            userID: 42,
            userLogin: "mona",
            authorizedOwners: ["acme"],
            accessibleRepositories: ["acme/backend"],
            lastValidatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        try store.saveCredential(credential)
        let loadedCredential = try store.loadCredential()

        #expect(loadedCredential == credential)
        #expect(store.hasCredentials())
        #expect(store.accessibility == .whenUnlockedThisDeviceOnly)
    }

    @Test
    func completesDeviceFlowAndStoresValidatedCredential() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "device-flow"
        )
        defer {
            try? store.deleteCredential()
        }

        var pollCount = 0
        let session = makeMockSession { request in
            let url = try #require(request.url)

            switch (url.host, url.path) {
            case ("github.com", "/login/device/code"):
                let body = formBody(in: request)
                #expect(body.contains("client_id=Iv1.test"))
                #expect(!body.contains("client_secret"))
                return jsonResponse(
                    statusCode: 200,
                    body: """
                    {
                      "device_code": "device-code-1",
                      "user_code": "ABCD-EFGH",
                      "verification_uri": "https://github.com/login/device",
                      "verification_uri_complete": "https://github.com/login/device?user_code=ABCD-EFGH",
                      "expires_in": 900,
                      "interval": 1
                    }
                    """
                )
            case ("github.com", "/login/oauth/access_token"):
                let body = formBody(in: request)
                #expect(body.contains("client_id=Iv1.test"))
                #expect(body.contains("grant_type=urn:ietf:params:oauth:grant-type:device_code"))
                #expect(!body.contains("client_secret"))
                pollCount += 1
                if pollCount == 1 {
                    return jsonResponse(
                        statusCode: 200,
                        body: """
                        {
                          "error": "authorization_pending",
                          "error_description": "waiting"
                        }
                        """
                    )
                }

                return jsonResponse(
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "ghu_live",
                      "refresh_token": "ghr_live",
                      "expires_in": 28800,
                      "refresh_token_expires_in": 15897600,
                      "token_type": "bearer"
                    }
                    """
                )
            case ("api.github.com", "/user"):
                return jsonResponse(
                    statusCode: 200,
                    body: """
                    {
                      "id": 7,
                      "login": "mona"
                    }
                    """
                )
            case ("api.github.com", "/user/installations"):
                return jsonResponse(
                    statusCode: 200,
                    body: """
                    {
                      "installations": [
                        {
                          "id": 1,
                          "account": { "login": "acme" },
                          "repository_selection": "selected"
                        }
                      ]
                    }
                    """
                )
            case ("api.github.com", "/user/installations/1/repositories"):
                return jsonResponse(
                    statusCode: 200,
                    body: """
                    {
                      "repositories": [
                        { "full_name": "acme/backend" }
                      ]
                    }
                    """
                )
            default:
                Issue.record("Unexpected request: \(request)")
                throw NSError(domain: "MockURLProtocol", code: 1)
            }
        }

        let provider = GitHubAuthProvider(
            configuration: GitHubAuthConfiguration(
                clientID: "Iv1.test",
                appSlug: "github-pr-inbox",
                expectedOwners: []
            ),
            session: session,
            tokenStore: store
        )

        let authorization = try await provider.startSignIn(expectedScopes: [.repo("acme/backend")])
        #expect(authorization.userCode == "ABCD-EFGH")

        let firstPoll = try await provider.pollSignIn(expectedScopes: [.repo("acme/backend")])
        if case let .pending(pendingAuthorization) = firstPoll {
            #expect(pendingAuthorization.userCode == "ABCD-EFGH")
        } else {
            Issue.record("Expected the first poll to remain pending.")
        }

        let secondPoll = try await provider.pollSignIn(expectedScopes: [.repo("acme/backend")])
        if case let .completed(credential) = secondPoll {
            #expect(credential.userLogin == "mona")
            #expect(credential.accessibleRepositories == ["acme/backend"])
            #expect(credential.authorizedOwners == ["acme"])
        } else {
            Issue.record("Expected the second poll to complete the device flow.")
        }

        let storedCredential = try await provider.currentCredential()
        #expect(storedCredential?.userLogin == "mona")
        #expect(storedCredential?.refreshToken == "ghr_live")
    }

    @Test
    func refreshesExpiringDeviceFlowTokenWithoutClientSecretAndRotatesCredential() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "refresh-token"
        )
        defer {
            try? store.deleteCredential()
        }

        try store.saveCredential(
            GitHubCredential(
                accessToken: "ghu_expired",
                refreshToken: "ghr_previous",
                accessTokenExpiresAt: Date().addingTimeInterval(-60),
                refreshTokenExpiresAt: Date().addingTimeInterval(60 * 60),
                userID: 7,
                userLogin: "mona",
                authorizedOwners: [],
                accessibleRepositories: [],
                lastValidatedAt: nil
            )
        )

        let session = makeMockSession { request in
            let url = try #require(request.url)

            switch (url.host, url.path) {
            case ("github.com", "/login/oauth/access_token"):
                let body = formBody(in: request)
                #expect(body.contains("client_id=Iv1.test"))
                #expect(body.contains("refresh_token=ghr_previous"))
                #expect(body.contains("grant_type=refresh_token"))
                #expect(!body.contains("client_secret"))
                return jsonResponse(
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "ghu_rotated",
                      "refresh_token": "ghr_rotated",
                      "expires_in": 28800,
                      "refresh_token_expires_in": 15897600,
                      "token_type": "bearer"
                    }
                    """
                )
            case ("api.github.com", "/user"):
                return jsonResponse(statusCode: 200, body: "{ \"id\": 7, \"login\": \"mona\" }")
            case ("api.github.com", "/user/installations"):
                return jsonResponse(statusCode: 200, body: "{ \"installations\": [] }")
            default:
                Issue.record("Unexpected request: \(request)")
                throw NSError(domain: "MockURLProtocol", code: 3)
            }
        }

        let provider = GitHubAuthProvider(
            configuration: GitHubAuthConfiguration(
                clientID: "Iv1.test",
                appSlug: "github-pr-inbox",
                expectedOwners: []
            ),
            session: session,
            tokenStore: store
        )

        let credential = try await provider.refreshIfNeeded(expectedScopes: [])
        let storedCredential = try await provider.currentCredential()

        #expect(credential.accessToken == "ghu_rotated")
        #expect(credential.refreshToken == "ghr_rotated")
        #expect(storedCredential?.accessToken == credential.accessToken)
        #expect(storedCredential?.refreshToken == credential.refreshToken)
    }

    @Test
    func reportsSAMLSSORequirementSeparatelyFromOtherAuthorizationFailures() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "sso-required"
        )
        defer {
            try? store.deleteCredential()
        }
        try store.saveCredential(testCredential())

        let session = makeMockSession { request in
            let url = try #require(request.url)
            #expect((url.host, url.path) == ("api.github.com", "/user/installations"))
            return jsonResponse(statusCode: 403, body: "{ \"message\": \"Resource protected by organization SAML enforcement\" }")
        }
        let provider = testProvider(session: session, store: store)

        do {
            _ = try await provider.validateOrgAccess(expectedScopes: [.org("acme")])
            Issue.record("Expected SAML SSO to require reauthorization.")
        } catch let error as GitHubAuthError {
            switch error {
            case let .ssoRequired(owners, message):
                #expect(owners.isEmpty)
                #expect(message.localizedCaseInsensitiveContains("SSO"))
            default:
                Issue.record("Expected ssoRequired, received \(error).")
            }
        }
    }

    @Test
    func reportsMissingSelectedRepositorySeparatelyFromSSO() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "missing-repository"
        )
        defer {
            try? store.deleteCredential()
        }
        try store.saveCredential(testCredential())

        let session = makeMockSession { request in
            let url = try #require(request.url)

            switch (url.host, url.path) {
            case ("api.github.com", "/user/installations"):
                return jsonResponse(
                    statusCode: 200,
                    body: """
                    {
                      "installations": [
                        {
                          "id": 1,
                          "account": { "login": "acme" },
                          "repository_selection": "selected"
                        }
                      ]
                    }
                    """
                )
            case ("api.github.com", "/user/installations/1/repositories"):
                return jsonResponse(
                    statusCode: 200,
                    body: "{ \"repositories\": [{ \"full_name\": \"acme/other\" }] }"
                )
            default:
                Issue.record("Unexpected request: \(request)")
                throw NSError(domain: "MockURLProtocol", code: 4)
            }
        }
        let provider = testProvider(session: session, store: store)

        do {
            _ = try await provider.validateOrgAccess(expectedScopes: [.repo("acme/backend")])
            Issue.record("Expected selected-repository access failure.")
        } catch let error as GitHubAuthError {
            switch error {
            case let .installationMissing(owners, repositories, _):
                #expect(owners.isEmpty)
                #expect(repositories == ["acme/backend"])
            default:
                Issue.record("Expected installationMissing, received \(error).")
            }
        }
    }

    @Test
    func gitHubClientRetriesAfterUnauthorizedResponse() async throws {
        let session = makeMockSession { request in
            let authorizationHeader = request.value(forHTTPHeaderField: "Authorization")

            switch authorizationHeader {
            case "Bearer stale-token":
                return jsonResponse(
                    statusCode: 401,
                    body: """
                    {
                      "message": "Bad credentials"
                    }
                    """
                )
            case "Bearer fresh-token":
                return jsonResponse(
                    statusCode: 200,
                    body: """
                    {
                      "login": "mona"
                    }
                    """
                )
            default:
                Issue.record("Unexpected authorization header: \(String(describing: authorizationHeader))")
                throw NSError(domain: "MockURLProtocol", code: 2)
            }
        }

        let refreshTracker = RefreshTracker()
        let client = GitHubClient(
            session: session,
            tokenProvider: { "stale-token" },
            refreshTokenProvider: { @Sendable in
                await refreshTracker.markRefreshed()
                return "fresh-token"
            }
        )

        let user = try await client.validateToken()

        #expect(await refreshTracker.didRefresh())
        #expect(user == GitHubUser(login: "mona"))
    }
}

private func testCredential() -> GitHubCredential {
    GitHubCredential(
        accessToken: "ghu_current",
        refreshToken: "ghr_current",
        accessTokenExpiresAt: Date().addingTimeInterval(60 * 60),
        refreshTokenExpiresAt: Date().addingTimeInterval(60 * 60 * 24),
        userID: 7,
        userLogin: "mona",
        authorizedOwners: [],
        accessibleRepositories: [],
        lastValidatedAt: nil
    )
}

private func testProvider(session: URLSession, store: KeychainTokenStore) -> GitHubAuthProvider {
    GitHubAuthProvider(
        configuration: GitHubAuthConfiguration(
            clientID: "Iv1.test",
            appSlug: "github-pr-inbox",
            expectedOwners: []
        ),
        session: session,
        tokenStore: store
    )
}

private func formBody(in request: URLRequest) -> String {
    if let body = request.httpBody {
        return String(decoding: body, as: UTF8.self)
    }

    guard let stream = request.httpBodyStream else {
        return ""
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let byteCount = stream.read(&buffer, maxLength: buffer.count)
        guard byteCount > 0 else {
            break
        }

        data.append(buffer, count: byteCount)
    }

    return String(decoding: data, as: UTF8.self)
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: 0))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeMockSession(
    handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    MockURLProtocol.requestHandler = handler
    return URLSession(configuration: configuration)
}

private func jsonResponse(statusCode: Int, body: String) -> (HTTPURLResponse, Data) {
    let url = URL(string: "https://example.com")!
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(body.utf8))
}

private actor RefreshTracker {
    private var refreshed = false

    func markRefreshed() {
        refreshed = true
    }

    func didRefresh() -> Bool {
        refreshed
    }
}
