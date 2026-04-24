import Foundation

struct GitHubUser: Equatable {
    let login: String
}

enum GitHubClientError: LocalizedError {
    case missingToken
    case configuration(String)
    case unauthorized(String)
    case invalidResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "Add a GitHub personal access token in Settings."
        case let .configuration(message):
            message
        case let .unauthorized(message):
            message
        case let .invalidResponse(message):
            message
        case let .network(message):
            message
        }
    }
}

actor GitHubClient {
    private struct GraphQLRequestBody: Encodable {
        let query: String
    }

    private struct GraphQLResponseEnvelope: Decodable {
        let data: [String: GraphQLRepositoryNode]?
        let errors: [GraphQLErrorNode]?
    }

    private struct GraphQLErrorNode: Decodable {
        let message: String
    }

    private struct GraphQLRepositoryNode: Decodable {
        let rawPullRequests: [String: GraphQLPullRequestNode]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            rawPullRequests = try container.decode([String: GraphQLPullRequestNode].self)
        }
    }

    private struct GraphQLPullRequestNode: Decodable {
        let reviewDecision: String?
        let mergeable: String?
        let mergeStateStatus: String?
        let statusCheckRollup: GraphQLStatusCheckRollup?
    }

    private struct GraphQLStatusCheckRollup: Decodable {
        let state: String?
        let contexts: GraphQLStatusContextConnection
    }

    private struct GraphQLStatusContextConnection: Decodable {
        let nodes: [GraphQLStatusContextNode?]
    }

    private enum GraphQLStatusContextNode: Decodable {
        case checkRun(GraphQLCheckRunNode)
        case statusContext(GraphQLCommitStatusNode)
        case unknown

        private enum CodingKeys: String, CodingKey {
            case typeName = "__typename"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let typeName = try container.decode(String.self, forKey: .typeName)

            switch typeName {
            case "CheckRun":
                self = .checkRun(try GraphQLCheckRunNode(from: decoder))
            case "StatusContext":
                self = .statusContext(try GraphQLCommitStatusNode(from: decoder))
            default:
                self = .unknown
            }
        }
    }

    private struct GraphQLCheckRunNode: Decodable {
        let status: String
        let conclusion: String?
    }

    private struct GraphQLCommitStatusNode: Decodable {
        let state: String
        let context: String?
        let description: String?
    }

    struct APIErrorResponse: Decodable {
        let message: String
    }

    struct UserResponse: Decodable {
        let login: String
    }

    private struct SearchResponse: Decodable {
        let items: [SearchItem]
    }

    private struct SearchItem: Decodable {
        let number: Int
        let title: String
        let htmlURL: URL
        let repositoryURL: URL
        let createdAt: Date
        let updatedAt: Date
        let draft: Bool?

        enum CodingKeys: String, CodingKey {
            case number
            case title
            case htmlURL = "html_url"
            case repositoryURL = "repository_url"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case draft
        }
    }

    struct PullRequestDetailResponse: Decodable {
        let head: HeadRef

        struct HeadRef: Decodable {
            let sha: String
        }
    }

    struct CombinedStatusResponse: Decodable {
        let state: String
        let statuses: [CommitStatus]
    }

    struct CommitStatus: Decodable {
        let state: String
        let context: String?
        let description: String?
    }

    struct CheckRunsResponse: Decodable {
        let checkRuns: [CheckRun]

        enum CodingKeys: String, CodingKey {
            case checkRuns = "check_runs"
        }
    }

    struct CheckRun: Decodable {
        let status: String
        let conclusion: String?
    }

    struct PullRequestReviewResponse: Decodable {
        let state: String
        let user: ReviewUser?
        let submittedAt: Date?

        enum CodingKeys: String, CodingKey {
            case state
            case user
            case submittedAt = "submitted_at"
        }
    }

    struct ReviewUser: Decodable {
        let login: String
    }

    private struct WorkflowRunsResponse: Decodable {
        let workflowRuns: [WorkflowRun]

        enum CodingKeys: String, CodingKey {
            case workflowRuns = "workflow_runs"
        }
    }

    private struct WorkflowRun: Decodable {
        let id: Int
        let name: String?
        let htmlURL: URL
        let headBranch: String?
        let status: String
        let conclusion: String?
        let createdAt: Date
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case htmlURL = "html_url"
            case headBranch = "head_branch"
            case status
            case conclusion
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    private let session: URLSession
    private let tokenProvider: @Sendable () throws -> String
    private let decoder: JSONDecoder

    private enum PullRequestReviewGateState {
        case awaitingApproval
        case approved
        case changesRequested
    }

    init(
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () throws -> String
    ) {
        self.session = session
        self.tokenProvider = tokenProvider

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func validateToken() async throws -> GitHubUser {
        let url = URL(string: "https://api.github.com/user")!
        let data = try await requestData(url: url)
        let user = try decode(UserResponse.self, from: data)
        return GitHubUser(login: user.login)
    }

    func fetchOpenPullRequests(
        filter: String,
        scopes: [RepositoryScope]
    ) async throws -> [PullRequestItem] {
        guard !scopes.isEmpty else {
            throw GitHubClientError.configuration("Add at least one org or repo in Settings.")
        }

        let queries = GitHubSearchQueryBuilder.buildQueries(baseQualifier: filter, scopes: scopes)
        var itemsByID: [String: PullRequestItem] = [:]

        for query in queries {
            let responseItems = try await fetchAllPages(for: query)
            for item in responseItems {
                itemsByID[item.id] = item
            }
        }

        return Array(itemsByID.values)
    }

    func fetchCIStatusSnapshot(for item: PullRequestItem) async throws -> PullRequestStatusSnapshot {
        let repositoryComponents = item.repositoryName.split(separator: "/", maxSplits: 1).map(String.init)
        guard repositoryComponents.count == 2 else {
            throw GitHubClientError.invalidResponse("Could not determine owner/repo for \(item.repositoryName).")
        }

        let owner = repositoryComponents[0]
        let repo = repositoryComponents[1]
        let headSHA = try await fetchHeadSHA(owner: owner, repo: repo, number: item.number)

        async let combinedStatus: CombinedStatusResponse? = try? await fetchCombinedStatus(
            owner: owner,
            repo: repo,
            ref: headSHA
        )
        async let checkRuns: CheckRunsResponse? = try? await fetchCheckRuns(
            owner: owner,
            repo: repo,
            ref: headSHA
        )
        async let reviews: [PullRequestReviewResponse]? = try? await fetchPullRequestReviews(
            owner: owner,
            repo: repo,
            number: item.number
        )

        return await mergeCIState(
            combinedStatus: combinedStatus,
            checkRuns: checkRuns,
            reviews: reviews,
            isDraft: item.isDraft,
            repositoryName: item.repositoryName
        )
    }

    func fetchCIStatusSnapshots(for items: [PullRequestItem]) async throws -> [String: PullRequestStatusSnapshot] {
        guard !items.isEmpty else {
            return [:]
        }

        do {
            return try await fetchCIStatusSnapshotsGraphQL(for: items)
        } catch {
            var snapshots: [String: PullRequestStatusSnapshot] = [:]

            await withTaskGroup(of: (String, PullRequestStatusSnapshot?).self) { group in
                for item in items {
                    group.addTask {
                        let snapshot = try? await self.fetchCIStatusSnapshot(for: item)
                        return (item.id, snapshot)
                    }
                }

                for await (itemID, snapshot) in group {
                    if let snapshot {
                        snapshots[itemID] = snapshot
                    }
                }
            }

            if snapshots.isEmpty {
                throw error
            }

            return snapshots
        }
    }

    func fetchFailedWorkflowRuns(
        repositoryNames: [String],
        trackedWorkflowNames: [String]
    ) async throws -> [WorkflowFailureItem] {
        guard !trackedWorkflowNames.isEmpty else {
            return []
        }

        let trackedNames = Set(trackedWorkflowNames.map { $0.lowercased() })
        var failures: [WorkflowFailureItem] = []

        for repositoryName in repositoryNames {
            let components = repositoryName.split(separator: "/", maxSplits: 1).map(String.init)
            guard components.count == 2 else {
                continue
            }

            let owner = components[0]
            let repo = components[1]
            let url = try makeWorkflowRunsURL(owner: owner, repo: repo)
            let data = try await requestData(url: url)
            let response = try decode(WorkflowRunsResponse.self, from: data)

            for run in response.workflowRuns {
                guard run.status == "completed", run.conclusion == "failure" else {
                    continue
                }

                let workflowName = (run.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard trackedNames.contains(workflowName.lowercased()) else {
                    continue
                }

                failures.append(
                    WorkflowFailureItem(
                        id: "\(repositoryName)#workflow-run-\(run.id)",
                        repositoryName: repositoryName,
                        workflowName: workflowName,
                        branchName: run.headBranch,
                        url: run.htmlURL,
                        createdAt: run.createdAt,
                        updatedAt: run.updatedAt
                    )
                )
            }
        }

        return failures
    }

    private func fetchAllPages(for query: String) async throws -> [PullRequestItem] {
        var page = 1
        var allItems: [PullRequestItem] = []

        while true {
            let url = try makeSearchURL(query: query, page: page)
            let data = try await requestData(url: url)
            let response = try decode(SearchResponse.self, from: data)
            let items = try response.items.map(convertSearchItem)
            allItems.append(contentsOf: items)

            if response.items.count < 100 {
                break
            }

            page += 1
        }

        return allItems
    }

    private func fetchCIStatusSnapshotsGraphQL(for items: [PullRequestItem]) async throws -> [String: PullRequestStatusSnapshot] {
        let request = try makeBatchedCIQuery(for: items)
        let data = try await requestGraphQLData(query: request.query)
        let envelope = try decode(GraphQLResponseEnvelope.self, from: data)

        if let errors = envelope.errors, !errors.isEmpty {
            let message = errors.map(\.message).joined(separator: "; ")
            throw GitHubClientError.invalidResponse("GitHub GraphQL error: \(message)")
        }

        guard let dataNodes = envelope.data else {
            throw GitHubClientError.invalidResponse("GitHub GraphQL returned no data.")
        }

        var snapshots: [String: PullRequestStatusSnapshot] = [:]

        for item in items {
            let repositoryAlias = request.repositoryAliasByItemID[item.id]!
            let pullRequestAlias = request.pullRequestAliasByItemID[item.id]!

            let pullRequestNode = dataNodes[repositoryAlias]?.rawPullRequests[pullRequestAlias]
            let reviewDecision = pullRequestNode?.reviewDecision
            let mergeable = pullRequestNode?.mergeable
            let mergeStateStatus = pullRequestNode?.mergeStateStatus
            let rollup = pullRequestNode?.statusCheckRollup

            let commitStatuses = rollup?.contexts.nodes.compactMap { node -> CommitStatus? in
                guard let node else {
                    return nil
                }

                switch node {
                case let .statusContext(statusNode):
                    return CommitStatus(
                        state: statusNode.state.lowercased(),
                        context: statusNode.context,
                        description: statusNode.description
                    )
                case .checkRun, .unknown:
                    return nil
                }
            } ?? []

            let checkRuns = rollup?.contexts.nodes.compactMap { node -> CheckRun? in
                guard let node else {
                    return nil
                }

                switch node {
                case let .checkRun(checkNode):
                    return CheckRun(
                        status: checkNode.status.lowercased(),
                        conclusion: checkNode.conclusion?.lowercased()
                    )
                case .statusContext, .unknown:
                    return nil
                }
            } ?? []

            let snapshot = mergeCIState(
                combinedStatus: rollup.map {
                    CombinedStatusResponse(
                        state: ($0.state ?? "none").lowercased(),
                        statuses: commitStatuses
                    )
                },
                checkRuns: CheckRunsResponse(checkRuns: checkRuns),
                reviews: nil,
                isDraft: item.isDraft,
                repositoryName: item.repositoryName,
                reviewDecision: reviewDecision,
                mergeable: mergeable,
                mergeStateStatus: mergeStateStatus
            )
            snapshots[item.id] = snapshot
        }

        return snapshots
    }

    private func requestGraphQLData(query: String) async throws -> Data {
        let token = try tokenProvider()
        guard !token.isEmpty else {
            throw GitHubClientError.missingToken
        }

        let body = try JSONEncoder().encode(GraphQLRequestBody(query: query))
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GitHubClientError.invalidResponse("GitHub returned a non-HTTP GraphQL response.")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, bodyData: data)
            }

            return data
        } catch let error as GitHubClientError {
            throw error
        } catch {
            throw GitHubClientError.network(error.localizedDescription)
        }
    }

    private func requestData(url: URL) async throws -> Data {
        let token = try tokenProvider()
        guard !token.isEmpty else {
            throw GitHubClientError.missingToken
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GitHubClientError.invalidResponse("GitHub returned a non-HTTP response.")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, bodyData: data)
            }

            return data
        } catch let error as GitHubClientError {
            throw error
        } catch {
            throw GitHubClientError.network(error.localizedDescription)
        }
    }

    private func makeBatchedCIQuery(for items: [PullRequestItem]) throws -> (
        query: String,
        repositoryAliasByItemID: [String: String],
        pullRequestAliasByItemID: [String: String]
    ) {
        var groupedItems: [String: [PullRequestItem]] = [:]
        for item in items {
            groupedItems[item.repositoryName, default: []].append(item)
        }

        let sortedRepositories = groupedItems.keys.sorted()
        var repositoryAliasByItemID: [String: String] = [:]
        var pullRequestAliasByItemID: [String: String] = [:]
        var repositoryBlocks: [String] = []

        for (repositoryIndex, repositoryName) in sortedRepositories.enumerated() {
            let components = repositoryName.split(separator: "/", maxSplits: 1).map(String.init)
            guard components.count == 2 else {
                throw GitHubClientError.configuration("Could not build a GraphQL repository query for \(repositoryName).")
            }

            let owner = components[0]
            let repo = components[1]
            let repositoryAlias = "repo\(repositoryIndex)"
            let itemsForRepo = groupedItems[repositoryName]?.sorted { $0.number < $1.number } ?? []

            var pullRequestBlocks: [String] = []
            for (pullIndex, item) in itemsForRepo.enumerated() {
                let pullRequestAlias = "pr\(repositoryIndex)_\(pullIndex)"
                repositoryAliasByItemID[item.id] = repositoryAlias
                pullRequestAliasByItemID[item.id] = pullRequestAlias
                pullRequestBlocks.append("""
                \(pullRequestAlias): pullRequest(number: \(item.number)) {
                  reviewDecision
                  mergeable
                  mergeStateStatus
                  statusCheckRollup {
                    state
                    contexts(first: 50) {
                      nodes {
                        __typename
                        ... on CheckRun {
                          status
                          conclusion
                        }
                        ... on StatusContext {
                          state
                          context
                          description
                        }
                      }
                    }
                  }
                }
                """)
            }

            repositoryBlocks.append("""
            \(repositoryAlias): repository(owner: "\(escapeGraphQLString(owner))", name: "\(escapeGraphQLString(repo))") {
              \(pullRequestBlocks.joined(separator: "\n"))
            }
            """)
        }

        return (
            query: """
            query BatchedPullRequestStatuses {
              \(repositoryBlocks.joined(separator: "\n"))
            }
            """,
            repositoryAliasByItemID: repositoryAliasByItemID,
            pullRequestAliasByItemID: pullRequestAliasByItemID
        )
    }

    private func escapeGraphQLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func fetchHeadSHA(owner: String, repo: String, number: Int) async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)")!
        let data = try await requestData(url: url)
        let response = try decode(PullRequestDetailResponse.self, from: data)
        return response.head.sha
    }

    private func fetchCombinedStatus(owner: String, repo: String, ref: String) async throws -> CombinedStatusResponse {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits/\(ref)/status")!
        let data = try await requestData(url: url)
        return try decode(CombinedStatusResponse.self, from: data)
    }

    private func fetchCheckRuns(owner: String, repo: String, ref: String) async throws -> CheckRunsResponse {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits/\(ref)/check-runs")!
        let data = try await requestData(url: url)
        return try decode(CheckRunsResponse.self, from: data)
    }

    private func fetchPullRequestReviews(owner: String, repo: String, number: Int) async throws -> [PullRequestReviewResponse] {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)/reviews")!
        let data = try await requestData(url: url)
        return try decode([PullRequestReviewResponse].self, from: data)
    }

    func mergeCIState(
        combinedStatus: CombinedStatusResponse?,
        checkRuns: CheckRunsResponse?,
        reviews: [PullRequestReviewResponse]? = nil,
        isDraft: Bool = false,
        repositoryName: String? = nil,
        reviewDecision: String? = nil,
        mergeable: String? = nil,
        mergeStateStatus: String? = nil
    ) -> PullRequestStatusSnapshot {
        let failingConclusions = Set(["action_required", "cancelled", "failure", "timed_out"])
        let inProgressStatuses = Set(["queued", "in_progress", "pending", "requested", "waiting"])
        let rawStatuses = combinedStatus?.statuses ?? []
        let filteredStatuses = rawStatuses.filter { !isReviewGateStatus($0) }
        let reviewGateState = effectiveReviewGateState(
            from: reviews,
            isDraft: isDraft,
            reviewDecision: reviewDecision
        )
        let reviewText = debugReviewGateState(reviewGateState)
        let combinedText = "combined=\(combinedStatus?.state ?? "none")/\(rawStatuses.count)"
        let checksText = "checks=\(checkRuns?.checkRuns.count ?? 0)"
        let filteredText = "filtered=\(filteredStatuses.count)"
        let repoText = repositoryName.map { "repo=\($0)" }
        let mergeText = "merge=\(mergeable?.lowercased() ?? "none")/\(mergeStateStatus?.lowercased() ?? "none")"

        if isMergeConflicted(mergeable: mergeable, mergeStateStatus: mergeStateStatus) {
            return PullRequestStatusSnapshot(
                status: .conflicted,
                debugSummary: [repoText, combinedText, checksText, filteredText, reviewText, mergeText]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }

        if checkRuns?.checkRuns.contains(where: { run in
            if let conclusion = run.conclusion {
                return failingConclusions.contains(conclusion)
            }

            return false
        }) == true {
            return PullRequestStatusSnapshot(
                status: .failure,
                debugSummary: [repoText, combinedText, checksText, filteredText, reviewText, mergeText]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }

        if combinedStatus?.state == "failure" || combinedStatus?.state == "error" {
            return PullRequestStatusSnapshot(
                status: .failure,
                debugSummary: [repoText, combinedText, checksText, filteredText, reviewText, mergeText]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }

        if checkRuns?.checkRuns.contains(where: { inProgressStatuses.contains($0.status) }) == true {
            return PullRequestStatusSnapshot(
                status: .inProgress,
                debugSummary: [repoText, combinedText, checksText, filteredText, reviewText, mergeText]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }

        if filteredStatuses.contains(where: { $0.state == "pending" }) {
            return PullRequestStatusSnapshot(
                status: .inProgress,
                debugSummary: [repoText, combinedText, checksText, filteredText, reviewText, mergeText]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }

        let hasReadableCIState = !(checkRuns?.checkRuns.isEmpty ?? true) || combinedStatus != nil
        if hasReadableCIState {
            let status: PullRequestCIStatus
            switch reviewGateState {
            case .approved:
                status = .readyToMerge
            case .awaitingApproval, .changesRequested:
                status = .ciPassed
            }

            return PullRequestStatusSnapshot(
                status: status,
                debugSummary: [repoText, combinedText, checksText, filteredText, reviewText, mergeText]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }

        return PullRequestStatusSnapshot(
            status: .unknown,
            debugSummary: [repoText, combinedText, checksText, filteredText, reviewText, mergeText]
                .compactMap { $0 }
                .joined(separator: " ")
        )
    }

    private func isMergeConflicted(mergeable: String?, mergeStateStatus: String?) -> Bool {
        switch mergeable?.uppercased() {
        case "CONFLICTING":
            return true
        default:
            break
        }

        switch mergeStateStatus?.uppercased() {
        case "DIRTY":
            return true
        default:
            return false
        }
    }

    private func isReviewGateStatus(_ status: CommitStatus) -> Bool {
        let haystack = [
            status.context?.lowercased(),
            status.description?.lowercased(),
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        guard !haystack.isEmpty else {
            return false
        }

        let reviewGateTerms = [
            "awaiting approval",
            "awaiting review",
            "review required",
            "changes requested",
            "approved review",
            "approval",
        ]

        return reviewGateTerms.contains(where: { haystack.contains($0) })
    }

    private func effectiveReviewGateState(
        from reviews: [PullRequestReviewResponse]?,
        isDraft: Bool,
        reviewDecision: String? = nil
    ) -> PullRequestReviewGateState {
        if isDraft {
            return .awaitingApproval
        }

        if let reviewDecision {
            switch reviewDecision.uppercased() {
            case "APPROVED":
                return .approved
            case "CHANGES_REQUESTED":
                return .changesRequested
            case "REVIEW_REQUIRED":
                return .awaitingApproval
            default:
                break
            }
        }

        guard let reviews else {
            return .awaitingApproval
        }

        var latestStateByReviewer: [String: String] = [:]

        for review in reviews {
            guard let login = review.user?.login.lowercased() else {
                continue
            }

            switch review.state {
            case "APPROVED", "CHANGES_REQUESTED":
                latestStateByReviewer[login] = review.state
            case "DISMISSED":
                latestStateByReviewer.removeValue(forKey: login)
            default:
                continue
            }
        }

        if latestStateByReviewer.values.contains("CHANGES_REQUESTED") {
            return .changesRequested
        }

        if latestStateByReviewer.values.contains("APPROVED") {
            return .approved
        }

        return .awaitingApproval
    }

    private func debugReviewGateState(_ state: PullRequestReviewGateState) -> String {
        switch state {
        case .awaitingApproval:
            "reviews=awaiting"
        case .approved:
            "reviews=approved"
        case .changesRequested:
            "reviews=changes_requested"
        }
    }

    private func mapHTTPError(statusCode: Int, bodyData: Data) -> GitHubClientError {
        let apiError = try? decoder.decode(APIErrorResponse.self, from: bodyData)
        let message = apiError?.message ?? String(decoding: bodyData, as: UTF8.self)

        switch statusCode {
        case 401:
            return .unauthorized("Your GitHub token is invalid or revoked.")
        case 403:
            let normalizedMessage = message.lowercased()
            if normalizedMessage.contains("saml") || normalizedMessage.contains("single sign-on") {
                return .unauthorized("Your token needs SSO authorization for one or more selected repositories.")
            }

            if normalizedMessage.contains("rate limit") {
                return .unauthorized("GitHub rate limited this token. Wait a bit and refresh again.")
            }

            return .unauthorized(message.isEmpty ? "GitHub denied access to one or more selected repositories." : message)
        default:
            return .invalidResponse("GitHub API error \(statusCode): \(message)")
        }
    }

    private func convertSearchItem(_ item: SearchItem) throws -> PullRequestItem {
        let pathComponents = item.repositoryURL.pathComponents.suffix(2)
        guard pathComponents.count == 2 else {
            throw GitHubClientError.invalidResponse("Could not determine the repository name for \(item.htmlURL.absoluteString).")
        }

        let repositoryName = pathComponents.joined(separator: "/")

        return PullRequestItem(
            id: item.htmlURL.absoluteString,
            repositoryName: repositoryName,
            number: item.number,
            title: item.title,
            url: item.htmlURL,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            isDraft: item.draft ?? false
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GitHubClientError.invalidResponse("Could not decode GitHub's response: \(error.localizedDescription)")
        }
    }

    private func makeSearchURL(query: String, page: Int) throws -> URL {
        var components = URLComponents(string: "https://api.github.com/search/issues")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: String(page)),
        ]

        guard let url = components?.url else {
            throw GitHubClientError.configuration("Could not build the GitHub search URL.")
        }

        return url
    }

    private func makeWorkflowRunsURL(owner: String, repo: String) throws -> URL {
        var components = URLComponents(string: "https://api.github.com/repos/\(owner)/\(repo)/actions/runs")
        components?.queryItems = [
            URLQueryItem(name: "status", value: "failure"),
            URLQueryItem(name: "per_page", value: "50"),
        ]

        guard let url = components?.url else {
            throw GitHubClientError.configuration("Could not build the GitHub Actions runs URL.")
        }

        return url
    }
}
