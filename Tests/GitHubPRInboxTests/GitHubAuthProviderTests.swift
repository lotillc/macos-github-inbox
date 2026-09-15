import Foundation
import Dispatch
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
    func persistsRotatedCredentialWhenUserLookupAfterRefreshFails() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "refresh-persisted-before-user-lookup"
        )
        defer { try? store.deleteCredential() }
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
                return jsonResponse(statusCode: 500, body: #"{ "message": "temporary failure" }"#)
            default:
                throw NSError(domain: "MockURLProtocol", code: 7)
            }
        }
        let provider = testProvider(session: session, store: store)

        await #expect(throws: GitHubAuthError.self) {
            _ = try await provider.refreshIfNeeded(expectedScopes: [])
        }

        let storedCredential = try #require(try store.loadCredential())
        #expect(storedCredential.accessToken == "ghu_rotated")
        #expect(storedCredential.refreshToken == "ghr_rotated")
    }

    @Test
    func resumesPersistedDeviceTokenAfterTransientProfileFailure() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "pending-device-token"
        )
        defer {
            try? store.deleteCredential()
            try? store.deletePendingDeviceCredential()
        }
        try store.savePendingDeviceCredential(
            PendingGitHubDeviceCredential(
                accessToken: "ghu_issued",
                refreshToken: "ghr_issued",
                accessTokenExpiresAt: Date().addingTimeInterval(60 * 60),
                refreshTokenExpiresAt: Date().addingTimeInterval(60 * 60 * 24)
            )
        )

        let session = makeMockSession { request in
            let url = try #require(request.url)
            switch (url.host, url.path) {
            case ("api.github.com", "/user"):
                return jsonResponse(statusCode: 200, body: #"{ "id": 7, "login": "mona" }"#)
            case ("api.github.com", "/user/installations"):
                return jsonResponse(statusCode: 200, body: #"{ "installations": [] }"#)
            default:
                throw NSError(domain: "MockURLProtocol", code: 12)
            }
        }

        let credential = try await testProvider(session: session, store: store)
            .refreshIfNeeded(expectedScopes: [])

        #expect(credential.accessToken == "ghu_issued")
        #expect(try store.loadCredential()?.userLogin == "mona")
        #expect(try store.loadPendingDeviceCredential() == nil)
    }

    @Test
    func refreshesExpiredPendingDeviceTokenBeforeResolvingIt() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "expired-pending-device-token"
        )
        defer {
            try? store.deleteCredential()
            try? store.deletePendingDeviceCredential()
        }
        try store.savePendingDeviceCredential(
            PendingGitHubDeviceCredential(
                accessToken: "ghu_expired",
                refreshToken: "ghr_issued",
                accessTokenExpiresAt: Date().addingTimeInterval(-60),
                refreshTokenExpiresAt: Date().addingTimeInterval(60 * 60 * 24)
            )
        )

        let session = makeMockSession { request in
            let url = try #require(request.url)
            switch (url.host, url.path) {
            case ("github.com", "/login/oauth/access_token"):
                #expect(formBody(in: request).contains("refresh_token=ghr_issued"))
                return jsonResponse(
                    statusCode: 200,
                    body: #"{ "access_token": "ghu_refreshed", "refresh_token": "ghr_refreshed", "expires_in": 28800 }"#
                )
            case ("api.github.com", "/user"):
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_refreshed")
                return jsonResponse(statusCode: 200, body: #"{ "id": 7, "login": "mona" }"#)
            case ("api.github.com", "/user/installations"):
                return jsonResponse(statusCode: 200, body: #"{ "installations": [] }"#)
            default:
                throw NSError(domain: "MockURLProtocol", code: 15)
            }
        }

        let credential = try await testProvider(session: session, store: store)
            .refreshIfNeeded(expectedScopes: [])

        #expect(credential.accessToken == "ghu_refreshed")
        #expect(credential.refreshToken == "ghr_refreshed")
        #expect(try store.loadPendingDeviceCredential() == nil)
    }

    @Test
    func validationDoesNotOverwriteCredentialRotatedWhileItWasInFlight() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "validation-refresh-race"
        )
        defer { try? store.deleteCredential() }
        try store.saveCredential(testCredential())

        let validationStarted = DispatchSemaphore(value: 0)
        let allowValidation = DispatchSemaphore(value: 0)
        let installationRequests = LockedRequestCounter()
        let session = makeDelayedMockSession { request, protocolInstance in
            guard let url = request.url else {
                protocolInstance.fail(with: NSError(domain: "MockURLProtocol", code: 17))
                return
            }
            switch (url.host, url.path) {
            case ("api.github.com", "/user/installations"):
                installationRequests.increment()
                if installationRequests.value == 1 {
                    validationStarted.signal()
                    let delayedProtocol = DelayedProtocolReference(protocolInstance)
                    DispatchQueue.global().async {
                        guard allowValidation.wait(timeout: .now() + 5) == .success else {
                            delayedProtocol.value.fail(with: NSError(domain: "MockURLProtocol", code: 16))
                            return
                        }
                        delayedProtocol.value.respond(with: jsonResponse(statusCode: 200, body: #"{ "installations": [] }"#))
                    }
                    return
                }
                protocolInstance.respond(with: jsonResponse(statusCode: 200, body: #"{ "installations": [] }"#))
            case ("github.com", "/login/oauth/access_token"):
                protocolInstance.respond(with: jsonResponse(
                    statusCode: 200,
                    body: #"{ "access_token": "ghu_rotated", "refresh_token": "ghr_rotated", "expires_in": 28800 }"#
                ))
            case ("api.github.com", "/user"):
                protocolInstance.respond(with: jsonResponse(statusCode: 200, body: #"{ "id": 7, "login": "mona" }"#))
            default:
                protocolInstance.fail(with: NSError(domain: "MockURLProtocol", code: 17))
            }
        }
        let provider = testProvider(session: session, store: store)

        let validation = Task { try await provider.validateOrgAccess(expectedScopes: []) }
        #expect(await waitForSemaphore(validationStarted, timeout: 2) == .success)

        let refreshedCredential = try await provider.forceRefresh(expectedScopes: [])
        #expect(refreshedCredential.accessToken == "ghu_rotated")
        allowValidation.signal()
        _ = try await validation.value

        let storedCredential = try #require(try store.loadCredential())
        #expect(storedCredential.accessToken == "ghu_rotated")
        #expect(storedCredential.refreshToken == "ghr_rotated")
    }

    @Test
    func coalescesConcurrentPendingCredentialRefreshes() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "coalesced-pending-refresh"
        )
        defer {
            try? store.deleteCredential()
            try? store.deletePendingDeviceCredential()
        }
        try store.savePendingDeviceCredential(
            PendingGitHubDeviceCredential(
                accessToken: "ghu_expired",
                refreshToken: "ghr_previous",
                accessTokenExpiresAt: Date().addingTimeInterval(-60),
                refreshTokenExpiresAt: Date().addingTimeInterval(60 * 60)
            )
        )

        let refreshStarted = DispatchSemaphore(value: 0)
        let releaseRefresh = DispatchSemaphore(value: 0)
        let refreshRequests = LockedRequestCounter()
        let session = makeDelayedMockSession { request, protocolInstance in
            guard let url = request.url else {
                protocolInstance.fail(with: NSError(domain: "MockURLProtocol", code: 18))
                return
            }
            switch (url.host, url.path) {
            case ("github.com", "/login/oauth/access_token"):
                refreshRequests.increment()
                refreshStarted.signal()
                let delayedProtocol = DelayedProtocolReference(protocolInstance)
                DispatchQueue.global().async {
                    guard releaseRefresh.wait(timeout: .now() + 5) == .success else {
                        delayedProtocol.value.fail(with: NSError(domain: "MockURLProtocol", code: 19))
                        return
                    }
                    delayedProtocol.value.respond(with: jsonResponse(
                        statusCode: 200,
                        body: #"{ "access_token": "ghu_rotated", "refresh_token": "ghr_rotated", "expires_in": 28800 }"#
                    ))
                }
            case ("api.github.com", "/user"):
                protocolInstance.respond(with: jsonResponse(statusCode: 200, body: #"{ "id": 7, "login": "mona" }"#))
            case ("api.github.com", "/user/installations"):
                protocolInstance.respond(with: jsonResponse(statusCode: 200, body: #"{ "installations": [] }"#))
            default:
                protocolInstance.fail(with: NSError(domain: "MockURLProtocol", code: 20))
            }
        }
        let provider = testProvider(session: session, store: store)

        let first = Task { try await provider.refreshIfNeeded(expectedScopes: []) }
        #expect(await waitForSemaphore(refreshStarted, timeout: 2) == .success)
        let second = Task { try await provider.refreshIfNeeded(expectedScopes: []) }
        releaseRefresh.signal()

        #expect(try await first.value.accessToken == "ghu_rotated")
        #expect(try await second.value.accessToken == "ghu_rotated")
        #expect(refreshRequests.value == 1)
    }

    @Test
    func coalescesConcurrentRefreshesThatWouldReuseARotatingToken() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "coalesced-refresh"
        )
        defer { try? store.deleteCredential() }
        var credential = testCredential()
        credential = GitHubCredential(
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            accessTokenExpiresAt: Date().addingTimeInterval(-60),
            refreshTokenExpiresAt: credential.refreshTokenExpiresAt,
            userID: credential.userID,
            userLogin: credential.userLogin,
            authorizedOwners: [],
            accessibleRepositories: [],
            lastValidatedAt: nil
        )
        try store.saveCredential(credential)

        let refreshStarted = DispatchSemaphore(value: 0)
        let releaseRefresh = DispatchSemaphore(value: 0)
        let refreshRequests = LockedRequestCounter()
        let session = makeMockSession { request in
            let url = try #require(request.url)
            switch (url.host, url.path) {
            case ("github.com", "/login/oauth/access_token"):
                refreshRequests.increment()
                refreshStarted.signal()
                guard releaseRefresh.wait(timeout: .now() + 5) == .success else {
                    throw NSError(domain: "MockURLProtocol", code: 13)
                }
                return jsonResponse(statusCode: 200, body: #"{ "access_token": "ghu_rotated", "refresh_token": "ghr_rotated", "expires_in": 28800 }"#)
            case ("api.github.com", "/user"):
                return jsonResponse(statusCode: 200, body: #"{ "id": 7, "login": "mona" }"#)
            case ("api.github.com", "/user/installations"):
                return jsonResponse(statusCode: 200, body: #"{ "installations": [] }"#)
            default:
                throw NSError(domain: "MockURLProtocol", code: 14)
            }
        }
        let provider = testProvider(session: session, store: store)
        let first = Task { try await provider.forceRefresh(expectedScopes: []) }
        #expect(await waitForSemaphore(refreshStarted, timeout: 2) == .success)
        let second = Task { try await provider.forceRefresh(expectedScopes: []) }
        releaseRefresh.signal()

        #expect(try await first.value.accessToken == "ghu_rotated")
        #expect(try await second.value.accessToken == "ghu_rotated")
        #expect(refreshRequests.value == 1)
    }

    @Test
    func reportsClientHTTP429AsRetryableRateLimit() async throws {
        let session = makeMockSession { _ in
            jsonResponse(statusCode: 429, body: #"{ "message": "slow down" }"#, headers: ["Retry-After": "60"])
        }
        let client = GitHubClient(session: session, tokenProvider: { "ghu_test" })

        do {
            _ = try await client.validateToken()
        } catch let error as GitHubClientError {
            if case let .rateLimited(message) = error {
                #expect(message.contains("60 seconds"))
            } else {
                Issue.record("Expected retryable rate limit, received \(error).")
            }
        }
    }

    @Test
    func usesUpdatedRuntimeConfigurationForDeviceAuthorization() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "updated-runtime-configuration"
        )
        defer { try? store.deleteCredential() }

        let session = makeMockSession { request in
            let url = try #require(request.url)
            #expect((url.host, url.path) == ("github.com", "/login/device/code"))
            let body = formBody(in: request)
            #expect(body.contains("client_id=Iv1.runtime"))
            #expect(!body.contains("Iv1.initial"))
            #expect(!body.contains("client_secret"))
            return jsonResponse(
                statusCode: 200,
                body: """
                {
                  "device_code": "device-code-1",
                  "user_code": "ABCD-EFGH",
                  "verification_uri": "https://github.com/login/device",
                  "expires_in": 900,
                  "interval": 5
                }
                """
            )
        }
        let provider = GitHubAuthProvider(
            configuration: GitHubAuthConfiguration(
                clientID: "Iv1.initial",
                appSlug: "initial-app",
                expectedOwners: []
            ),
            session: session,
            tokenStore: store
        )

        await provider.updateConfiguration(
            GitHubAuthConfiguration(
                clientID: "Iv1.runtime",
                appSlug: "runtime-app",
                expectedOwners: ["acme"]
            )
        )
        let authorization = try await provider.startSignIn(expectedScopes: [])

        #expect(authorization.userCode == "ABCD-EFGH")
    }

    @Test
    func changingAppIdentityPreventsInFlightValidationFromRestoringCredential() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "configuration-change-race"
        )
        defer { try? store.deleteCredential() }
        try store.saveCredential(testCredential())

        let requestStarted = DispatchSemaphore(value: 0)
        let allowResponse = DispatchSemaphore(value: 0)
        let session = makeMockSession { request in
            let url = try #require(request.url)
            #expect((url.host, url.path) == ("api.github.com", "/user/installations"))
            requestStarted.signal()
            #expect(allowResponse.wait(timeout: .now() + 5) == .success)
            return jsonResponse(statusCode: 200, body: #"{ "installations": [] }"#)
        }
        let provider = GitHubAuthProvider(
            configuration: GitHubAuthConfiguration(
                clientID: "Iv1.old",
                appSlug: "old-app",
                expectedOwners: []
            ),
            session: session,
            tokenStore: store
        )

        let validation = Task {
            try await provider.validateOrgAccess(expectedScopes: [])
        }
        #expect(await waitForSemaphore(requestStarted, timeout: 2) == .success)

        do {
            try await provider.replaceConfigurationAndSignOut(
                GitHubAuthConfiguration(
                    clientID: "Iv1.new",
                    appSlug: "new-app",
                    expectedOwners: []
                )
            )
        } catch {
            allowResponse.signal()
            throw error
        }
        allowResponse.signal()

        do {
            _ = try await validation.value
            Issue.record("Expected in-flight validation to be invalidated by the configuration change.")
        } catch let error as GitHubAuthError {
            #expect(error == .configurationChanged)
        }

        #expect(try store.loadCredential() == nil)
    }

    @Test
    func signingOutPreventsInFlightValidationFromRestoringCredential() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "sign-out-race"
        )
        defer { try? store.deleteCredential() }
        try store.saveCredential(testCredential())

        let requestStarted = DispatchSemaphore(value: 0)
        let allowResponse = DispatchSemaphore(value: 0)
        let session = makeDelayedInstallationSession(
            requestStarted: requestStarted,
            allowResponse: allowResponse
        )
        let provider = testProvider(session: session, store: store)
        let validation = Task { try await provider.validateOrgAccess(expectedScopes: []) }
        #expect(await waitForSemaphore(requestStarted, timeout: 2) == .success)

        do {
            try await provider.signOut()
        } catch {
            allowResponse.signal()
            throw error
        }
        allowResponse.signal()

        do {
            _ = try await validation.value
            Issue.record("Expected in-flight validation to be invalidated by sign-out.")
        } catch let error as GitHubAuthError {
            #expect(error == .configurationChanged)
        }
        #expect(try store.loadCredential() == nil)
    }

    @Test
    func changingExpectedOwnersInvalidatesInFlightValidationWithoutSigningOut() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "expected-owner-race"
        )
        defer { try? store.deleteCredential() }
        let credential = testCredential()
        try store.saveCredential(credential)

        let requestStarted = DispatchSemaphore(value: 0)
        let allowResponse = DispatchSemaphore(value: 0)
        let session = makeDelayedInstallationSession(
            requestStarted: requestStarted,
            allowResponse: allowResponse
        )
        let provider = testProvider(session: session, store: store)
        let validation = Task { try await provider.validateOrgAccess(expectedScopes: []) }
        #expect(await waitForSemaphore(requestStarted, timeout: 2) == .success)

        await provider.updateConfiguration(
            GitHubAuthConfiguration(
                clientID: "Iv1.test",
                appSlug: "github-pr-inbox",
                expectedOwners: ["other-org"]
            )
        )
        allowResponse.signal()

        do {
            _ = try await validation.value
            Issue.record("Expected validation using the old organization configuration to be invalidated.")
        } catch let error as GitHubAuthError {
            #expect(error == .configurationChanged)
        }
        let storedCredential = try #require(try store.loadCredential())
        #expect(storedCredential.accessToken == credential.accessToken)
        #expect(storedCredential.refreshToken == credential.refreshToken)
        #expect(storedCredential.authorizedOwners == credential.authorizedOwners)
    }

    @Test
    func changingExpectedOwnersPreservesAnInFlightRotatedRefreshToken() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "expected-owner-refresh-race"
        )
        defer { try? store.deleteCredential() }
        let credential = GitHubCredential(
            accessToken: "ghu_expired",
            refreshToken: "ghr_old",
            accessTokenExpiresAt: Date().addingTimeInterval(-60),
            refreshTokenExpiresAt: Date().addingTimeInterval(60 * 60),
            userID: 7,
            userLogin: "mona",
            authorizedOwners: [],
            accessibleRepositories: [],
            lastValidatedAt: nil
        )
        try store.saveCredential(credential)

        let refreshStarted = DispatchSemaphore(value: 0)
        let allowRefresh = DispatchSemaphore(value: 0)
        let session = makeMockSession { request in
            let url = try #require(request.url)
            switch (url.host, url.path) {
            case ("github.com", "/login/oauth/access_token"):
                refreshStarted.signal()
                #expect(allowRefresh.wait(timeout: .now() + 5) == .success)
                return jsonResponse(
                    statusCode: 200,
                    body: #"{ "access_token": "ghu_rotated", "refresh_token": "ghr_rotated", "expires_in": 28800 }"#
                )
            case ("api.github.com", "/user"):
                return jsonResponse(statusCode: 200, body: #"{ "id": 7, "login": "mona" }"#)
            case ("api.github.com", "/user/installations"):
                return jsonResponse(
                    statusCode: 200,
                    body: #"{ "installations": [{ "id": 1, "account": { "login": "other-org", "type": "Organization" }, "repository_selection": "all" }] }"#
                )
            case ("api.github.com", "/user/installations/1/repositories"):
                return jsonResponse(statusCode: 200, body: #"{ "repositories": [] }"#)
            default:
                throw NSError(domain: "MockURLProtocol", code: 23)
            }
        }
        let provider = testProvider(session: session, store: store)
        let refresh = Task { try await provider.refreshIfNeeded(expectedScopes: []) }
        #expect(await waitForSemaphore(refreshStarted, timeout: 2) == .success)

        await provider.updateConfiguration(
            GitHubAuthConfiguration(
                clientID: "Iv1.test",
                appSlug: "github-pr-inbox",
                expectedOwners: ["other-org"]
            )
        )
        let newConfigurationValidation = Task {
            try await provider.validateOrgAccess(expectedScopes: [])
        }
        allowRefresh.signal()

        do {
            _ = try await refresh.value
            Issue.record("Expected old validation to be invalidated after an owner edit.")
        } catch let error as GitHubAuthError {
            #expect(error == .configurationChanged)
        }

        let storedCredential = try #require(try store.loadCredential())
        #expect(storedCredential.accessToken == "ghu_rotated")
        #expect(storedCredential.refreshToken == "ghr_rotated")
        let summary = try await newConfigurationValidation.value
        #expect(summary.user == GitHubUser(login: "mona"))
    }

    @Test
    func changingExpectedOwnersPropagatesAnUnrotatedRefreshFailure() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "expected-owner-refresh-failure"
        )
        defer { try? store.deleteCredential() }
        let credential = GitHubCredential(
            accessToken: "ghu_expired",
            refreshToken: "ghr_old",
            accessTokenExpiresAt: Date().addingTimeInterval(-60),
            refreshTokenExpiresAt: Date().addingTimeInterval(60 * 60),
            userID: 7,
            userLogin: "mona",
            authorizedOwners: [],
            accessibleRepositories: [],
            lastValidatedAt: nil
        )
        try store.saveCredential(credential)

        let refreshStarted = DispatchSemaphore(value: 0)
        let allowRefresh = DispatchSemaphore(value: 0)
        let session = makeMockSession { request in
            let url = try #require(request.url)
            guard (url.host, url.path) == ("github.com", "/login/oauth/access_token") else {
                throw NSError(domain: "MockURLProtocol", code: 24)
            }
            refreshStarted.signal()
            #expect(allowRefresh.wait(timeout: .now() + 5) == .success)
            return jsonResponse(statusCode: 503, body: #"{ "message": "temporary failure" }"#)
        }
        let provider = testProvider(session: session, store: store)
        let originalRefresh = Task { try await provider.refreshIfNeeded(expectedScopes: []) }
        #expect(await waitForSemaphore(refreshStarted, timeout: 2) == .success)

        await provider.updateConfiguration(
            GitHubAuthConfiguration(
                clientID: "Iv1.test",
                appSlug: "github-pr-inbox",
                expectedOwners: ["other-org"]
            )
        )
        let newConfigurationValidation = Task {
            try await provider.validateOrgAccess(expectedScopes: [])
        }
        allowRefresh.signal()

        func expectNetworkFailure<Value>(_ task: Task<Value, Error>) async {
            do {
                _ = try await task.value
                Issue.record("Expected the original refresh outage to propagate.")
            } catch let error as GitHubAuthError {
                if case .network = error {
                    return
                }
                Issue.record("Expected a retryable network error, got \(error).")
            } catch {
                Issue.record("Expected a GitHub authentication error, got \(error).")
            }
        }
        await expectNetworkFailure(originalRefresh)
        await expectNetworkFailure(newConfigurationValidation)

        let storedCredential = try #require(try store.loadCredential())
        #expect(storedCredential.accessToken == credential.accessToken)
        #expect(storedCredential.refreshToken == credential.refreshToken)
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
    func reportsRateLimitingSeparatelyFromMissingInstallation() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "rate-limited"
        )
        defer { try? store.deleteCredential() }
        try store.saveCredential(testCredential())

        let session = makeMockSession { request in
            let url = try #require(request.url)
            #expect((url.host, url.path) == ("api.github.com", "/user/installations"))
            return jsonResponse(
                statusCode: 403,
                body: #"{ "message": "API rate limit exceeded" }"#,
                headers: ["X-RateLimit-Remaining": "0"]
            )
        }
        let provider = testProvider(session: session, store: store)

        do {
            _ = try await provider.validateOrgAccess(expectedScopes: [.org("acme")])
            Issue.record("Expected GitHub rate limiting to be reported separately.")
        } catch let error as GitHubAuthError {
            switch error {
            case let .rateLimited(message):
                #expect(message.localizedCaseInsensitiveContains("rate limit"))
            default:
                Issue.record("Expected rateLimited, received \(error).")
            }
        }
    }

    @Test
    func reportsHTTP429AsRateLimited() async throws {
        let store = KeychainTokenStore(
            service: "com.github-pr-inbox.tests.\(UUID().uuidString)",
            account: "http-429-rate-limited"
        )
        defer { try? store.deleteCredential() }
        try store.saveCredential(testCredential())

        let session = makeMockSession { request in
            let url = try #require(request.url)
            #expect((url.host, url.path) == ("api.github.com", "/user/installations"))
            return jsonResponse(
                statusCode: 429,
                body: #"{ "message": "slow down" }"#,
                headers: ["Retry-After": "60"]
            )
        }
        let provider = testProvider(session: session, store: store)

        do {
            _ = try await provider.validateOrgAccess(expectedScopes: [.org("acme")])
            Issue.record("Expected HTTP 429 to be reported as rate limited.")
        } catch let error as GitHubAuthError {
            switch error {
            case let .rateLimited(message):
                #expect(message.contains("60 seconds"))
            default:
                Issue.record("Expected rateLimited, received \(error).")
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

    @Test
    func gitHubClientPreservesAuthenticationErrorsFromForcedRefresh() async throws {
        let session = makeMockSession { _ in
            jsonResponse(statusCode: 401, body: #"{ "message": "Bad credentials" }"#)
        }
        let client = GitHubClient(
            session: session,
            tokenProvider: { "stale-token" },
            refreshTokenProvider: {
                throw GitHubAuthError.ssoRequired(["acme"], "GitHub authorization needs SSO.")
            }
        )

        do {
            _ = try await client.validateToken()
            Issue.record("Expected the forced refresh error to propagate.")
        } catch let error as GitHubAuthError {
            #expect(error == .ssoRequired(["acme"], "GitHub authorization needs SSO."))
        }
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

private final class DelayedMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest, DelayedMockURLProtocol) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fail(with: NSError(domain: "DelayedMockURLProtocol", code: 0))
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

private struct DelayedProtocolReference<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private func makeDelayedMockSession(
    handler: @escaping (URLRequest, DelayedMockURLProtocol) -> Void
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.protocolClasses = [DelayedMockURLProtocol.self]
    DelayedMockURLProtocol.requestHandler = handler
    return URLSession(configuration: configuration)
}

private func jsonResponse(
    statusCode: Int,
    body: String,
    headers: [String: String] = [:]
) -> (HTTPURLResponse, Data) {
    let url = URL(string: "https://example.com")!
    var responseHeaders = ["Content-Type": "application/json"]
    responseHeaders.merge(headers) { _, new in new }
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: responseHeaders
    )!
    return (response, Data(body.utf8))
}

private func makeDelayedInstallationSession(
    requestStarted: DispatchSemaphore,
    allowResponse: DispatchSemaphore
) -> URLSession {
    makeMockSession { request in
        let url = try #require(request.url)
        guard (url.host, url.path) == ("api.github.com", "/user/installations") else {
            throw NSError(domain: "MockURLProtocol", code: 5)
        }
        requestStarted.signal()
        guard allowResponse.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "MockURLProtocol", code: 6)
        }
        return jsonResponse(statusCode: 200, body: #"{ "installations": [] }"#)
    }
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
        }
    }
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

private final class LockedRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}
