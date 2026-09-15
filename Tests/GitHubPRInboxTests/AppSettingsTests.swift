import Foundation
import Dispatch
import Testing
@testable import GitHubPRInbox

@MainActor
@Suite(.serialized)
struct AppSettingsTests {
    @Test
    func seedsGitHubAppPreferencesOnceFromBuildDefaults() throws {
        let suiteName = "com.github-pr-inbox.tests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let tokenStore = testTokenStore(account: "seed-once")
        defer { try? tokenStore.deleteCredential() }

        let firstSettings = AppSettings(
            userDefaults: userDefaults,
            tokenStore: tokenStore,
            buildDefaultConfiguration: GitHubAuthConfiguration(
                clientID: "Iv1.first",
                appSlug: "first-app",
                expectedOwners: ["acme", "other-org"]
            )
        )

        #expect(firstSettings.gitHubAppClientID == "Iv1.first")
        #expect(firstSettings.gitHubAppSlug == "first-app")
        #expect(firstSettings.gitHubAppExpectedOwner == "acme, other-org")
        #expect(firstSettings.gitHubAppConfiguration.expectedOwners == ["acme", "other-org"])

        let secondSettings = AppSettings(
            userDefaults: userDefaults,
            tokenStore: tokenStore,
            buildDefaultConfiguration: GitHubAuthConfiguration(
                clientID: "Iv1.second",
                appSlug: "second-app",
                expectedOwners: ["other-org"]
            )
        )

        #expect(secondSettings.gitHubAppClientID == "Iv1.first")
        #expect(secondSettings.gitHubAppSlug == "first-app")
        #expect(secondSettings.gitHubAppExpectedOwner == "acme, other-org")
        #expect(secondSettings.gitHubAppConfiguration.expectedOwners == ["acme", "other-org"])
    }

    @Test
    func preservesPreviouslySavedBlankRuntimeValuesInsteadOfReseeding() throws {
        let suiteName = "com.github-pr-inbox.tests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set("", forKey: "gitHubAppClientID")
        userDefaults.set("", forKey: "gitHubAppSlug")
        userDefaults.set("", forKey: "gitHubAppExpectedOwner")

        let tokenStore = testTokenStore(account: "blank-values")
        defer { try? tokenStore.deleteCredential() }
        let settings = AppSettings(
            userDefaults: userDefaults,
            tokenStore: tokenStore,
            buildDefaultConfiguration: GitHubAuthConfiguration(
                clientID: "Iv1.default",
                appSlug: "default-app",
                expectedOwners: ["acme"]
            )
        )

        #expect(settings.gitHubAppClientID.isEmpty)
        #expect(settings.gitHubAppSlug.isEmpty)
        #expect(settings.gitHubAppExpectedOwner.isEmpty)
    }

    @Test
    func rejectsMissingOrMalformedRuntimeGitHubAppSettings() throws {
        let settings = makeSettings(account: "invalid-settings")

        #expect(throws: GitHubAuthError.self) {
            try settings.saveGitHubAppConfiguration(
                clientID: "",
                appSlug: "inbox-app",
                expectedOwner: "acme"
            )
        }
        #expect(throws: GitHubAuthError.self) {
            try settings.saveGitHubAppConfiguration(
                clientID: "Iv1.valid",
                appSlug: "not valid",
                expectedOwner: "acme"
            )
        }
    }

    @Test
    func changingGitHubAppIdentitySignsOutAndChangingOwnerPreservesSession() async throws {
        let tokenStore = testTokenStore(account: "configuration-change")
        defer { try? tokenStore.deleteCredential() }
        try tokenStore.saveCredential(
            GitHubCredential(
                accessToken: "ghu_test",
                refreshToken: "ghr_test",
                accessTokenExpiresAt: nil,
                refreshTokenExpiresAt: nil,
                userID: 7,
                userLogin: "mona",
                authorizedOwners: [],
                accessibleRepositories: [],
                lastValidatedAt: nil
            )
        )

        let settings = makeSettings(
            account: "configuration-change",
            tokenStore: tokenStore,
            configuration: GitHubAuthConfiguration(
                clientID: "Iv1.old",
                appSlug: "old-app",
                expectedOwners: ["acme"]
            )
        )
        let provider = GitHubAuthProvider(
            configuration: settings.gitHubAppConfiguration,
            session: makeSettingsMockSession { request in
                let url = try #require(request.url)
                #expect((url.host, url.path) == ("api.github.com", "/user/installations"))
                return settingsJSONResponse(
                    statusCode: 200,
                    body: """
                    {
                      "installations": [
                        { "id": 1, "account": { "login": "acme" }, "repository_selection": "all" },
                        { "id": 2, "account": { "login": "other-org" }, "repository_selection": "all" }
                      ]
                    }
                    """
                )
            },
            tokenStore: tokenStore
        )
        let model = InboxViewModel(settings: settings, authProvider: provider)

        try await model.saveGitHubAppConfiguration(
            clientID: "Iv1.new",
            appSlug: "new-app",
            expectedOwner: "acme"
        )

        #expect(try tokenStore.loadCredential() == nil)
        #expect(model.authState == .signedOut)
        #expect(model.appInstallURL?.absoluteString == "https://github.com/apps/new-app/installations/new")

        try tokenStore.saveCredential(testCredential())
        try await model.saveGitHubAppConfiguration(
            clientID: "Iv1.new",
            appSlug: "new-app",
            expectedOwner: "other-org"
        )

        #expect(try tokenStore.loadCredential() != nil)
        #expect(settings.gitHubAppConfiguration.expectedOwners == ["other-org"])
        #expect(model.ssoAuthorizationURLs.map(\.absoluteString) == ["https://github.com/orgs/other-org/sso"])
    }

    @Test
    func changingAppIdentityKeepsInFlightInboxRefreshFromRestoringData() async throws {
        let tokenStore = testTokenStore(account: "inbox-refresh-race")
        defer { try? tokenStore.deleteCredential() }
        let settings = makeSettings(
            account: "inbox-refresh-race",
            tokenStore: tokenStore,
            configuration: GitHubAuthConfiguration(
                clientID: "",
                appSlug: "",
                expectedOwners: []
            )
        )
        let inboxRequestsStarted = DispatchSemaphore(value: 0)
        let allowInboxResponses = DispatchSemaphore(value: 0)
        let session = makeDelayedSettingsMockSession { request, protocolInstance in
            guard let url = request.url else {
                protocolInstance.fail(with: NSError(domain: "SettingsMockURLProtocol", code: 7))
                return
            }
            switch (url.host, url.path) {
            case ("api.github.com", "/user/installations"):
                protocolInstance.respond(with: settingsJSONResponse(
                    statusCode: 200,
                    body: #"{ "installations": [{ "id": 1, "account": { "login": "acme" }, "repository_selection": "selected" }] }"#
                ))
            case ("api.github.com", "/user/installations/1/repositories"):
                protocolInstance.respond(with: settingsJSONResponse(
                    statusCode: 200,
                    body: #"{ "repositories": [{ "full_name": "acme/backend" }] }"#
                ))
            case ("api.github.com", "/user"):
                protocolInstance.respond(with: settingsJSONResponse(
                    statusCode: 200,
                    body: #"{ "id": 7, "login": "mona" }"#
                ))
            case ("api.github.com", "/search/issues"):
                inboxRequestsStarted.signal()
                let callbackProtocol = UncheckedSendableReference(protocolInstance)
                DispatchQueue.global().async {
                    guard allowInboxResponses.wait(timeout: .now() + 5) == .success else {
                        callbackProtocol.value.fail(with: NSError(domain: "SettingsMockURLProtocol", code: 9))
                        return
                    }
                    callbackProtocol.value.respond(with: settingsJSONResponse(
                        statusCode: 200,
                        body: #"{ "total_count": 0, "items": [] }"#
                    ))
                }
            default:
                protocolInstance.fail(with: NSError(
                    domain: "SettingsMockURLProtocol",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected request: \(url)"]
                ))
            }
        }
        let provider = GitHubAuthProvider(
            configuration: settings.gitHubAppConfiguration,
            session: session,
            tokenStore: tokenStore
        )
        let model = InboxViewModel(settings: settings, authProvider: provider, clientSession: session)
        guard await waitForMissingConfiguration(in: model, timeout: 2) else {
            Issue.record("The initial refresh did not finish with the intentionally missing configuration.")
            return
        }
        _ = try settings.saveGitHubAppConfiguration(
            clientID: "Iv1.old",
            appSlug: "old-app",
            expectedOwner: ""
        )
        try tokenStore.saveCredential(
            GitHubCredential(
                accessToken: "ghu_test",
                refreshToken: "ghr_test",
                accessTokenExpiresAt: nil,
                refreshTokenExpiresAt: nil,
                userID: 7,
                userLogin: "mona",
                authorizedOwners: [],
                accessibleRepositories: [],
                lastValidatedAt: nil
            )
        )
        settings.allowlistText = "acme/backend"

        let refresh = Task { await model.refresh() }
        let firstInboxRequest = await waitForSettingsSemaphore(inboxRequestsStarted, timeout: 2)
        let secondInboxRequest = await waitForSettingsSemaphore(inboxRequestsStarted, timeout: 2)
        guard firstInboxRequest == .success, secondInboxRequest == .success else {
            Issue.record("Refresh did not begin both successful inbox requests before the App change.")
            return
        }

        do {
            try await model.saveGitHubAppConfiguration(
                clientID: "Iv1.new",
                appSlug: "new-app",
                expectedOwner: ""
            )
        } catch {
            allowInboxResponses.signal()
            allowInboxResponses.signal()
            throw error
        }
        allowInboxResponses.signal()
        allowInboxResponses.signal()
        await refresh.value

        #expect(model.currentUser == nil)
        #expect(model.authState == .signedOut)
        #expect(model.reviewRequests.isEmpty)
        #expect(model.authoredPullRequests.isEmpty)
        #expect(model.workflowFailures.isEmpty)
    }

    @Test
    func ignoresUnexpandedBuildSettingPlaceholders() {
        let configuration = GitHubAuthConfiguration.load(
            environment: [:],
            infoDictionary: [
                "GitHubAppClientID": "$(GITHUB_APP_CLIENT_ID)",
                "GitHubAppSlug": "$(GITHUB_APP_SLUG)",
                "GitHubAppExpectedOwners": "$(GITHUB_APP_EXPECTED_OWNERS)",
            ]
        )

        #expect(configuration.clientID.isEmpty)
        #expect(configuration.appSlug.isEmpty)
        #expect(configuration.expectedOwners.isEmpty)
    }

    private func makeSettings(
        account: String,
        tokenStore: KeychainTokenStore? = nil,
        configuration: GitHubAuthConfiguration = GitHubAuthConfiguration(
            clientID: "Iv1.test",
            appSlug: "test-app",
            expectedOwners: ["acme"]
        )
    ) -> AppSettings {
        let suiteName = "com.github-pr-inbox.tests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return AppSettings(
            userDefaults: userDefaults,
            tokenStore: tokenStore ?? testTokenStore(account: account),
            buildDefaultConfiguration: configuration
        )
    }

    private func testTokenStore(account: String) -> KeychainTokenStore {
        KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: account
        )
    }

    private func testCredential() -> GitHubCredential {
        GitHubCredential(
            accessToken: "ghu_test",
            refreshToken: "ghr_test",
            accessTokenExpiresAt: Date().addingTimeInterval(60 * 60),
            refreshTokenExpiresAt: Date().addingTimeInterval(60 * 60 * 24),
            userID: 7,
            userLogin: "mona",
            authorizedOwners: [],
            accessibleRepositories: [],
            lastValidatedAt: nil
        )
    }
}

private final class SettingsMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "SettingsMockURLProtocol", code: 0))
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

private func makeSettingsMockSession(
    handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.protocolClasses = [SettingsMockURLProtocol.self]
    SettingsMockURLProtocol.requestHandler = handler
    return URLSession(configuration: configuration)
}

private final class DelayedSettingsMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest, DelayedSettingsMockURLProtocol) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fail(with: NSError(domain: "DelayedSettingsMockURLProtocol", code: 0))
            return
        }

        handler(request, self)
    }

    override func stopLoading() {}

    func respond(with responseAndData: (HTTPURLResponse, Data)) {
        client?.urlProtocol(self, didReceive: responseAndData.0, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseAndData.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(with error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}

private struct UncheckedSendableReference<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private func makeDelayedSettingsMockSession(
    handler: @escaping (URLRequest, DelayedSettingsMockURLProtocol) -> Void
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.protocolClasses = [DelayedSettingsMockURLProtocol.self]
    DelayedSettingsMockURLProtocol.requestHandler = handler
    return URLSession(configuration: configuration)
}

private func settingsJSONResponse(statusCode: Int, body: String) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: URL(string: "https://example.com")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(body.utf8))
}

private func waitForSettingsSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
        }
    }
}

@MainActor
private func waitForMissingConfiguration(
    in model: InboxViewModel,
    timeout: TimeInterval
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if case .missingConfiguration = model.authState {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return false
}
