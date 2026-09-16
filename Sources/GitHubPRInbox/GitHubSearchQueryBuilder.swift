import Foundation

enum GitHubSearchQueryPlanError: LocalizedError, Equatable {
    case ownerSearchScopeTooLarge(String)

    var errorDescription: String? {
        switch self {
        case let .ownerSearchScopeTooLarge(owner):
            return "GitHub Search can search at most 4,000 repositories for \(owner). Select repositories individually to load a complete inbox."
        }
    }
}

struct GitHubSearchQueryPlan: Equatable {
    let query: String
    /// When non-nil, retain only these repositories from the wider owner query.
    /// The same set provides an exact repository-scoped fallback if Search caps
    /// that owner query at 1,000 results.
    let allowedRepositoryNames: Set<String>?

    var fallbackQueries: [String] {
        guard let allowedRepositoryNames else { return [] }
        return allowedRepositoryNames.sorted().map { "repo:\($0)" }
    }
}

enum GitHubSearchQueryBuilder {
    static func buildQueries(baseQualifier: String, scopes: [RepositoryScope]) -> [String] {
        (try? buildPlan(baseQualifier: baseQualifier, scopes: scopes).map(\.query)) ?? []
    }

    static func buildPlan(
        baseQualifier: String,
        scopes: [RepositoryScope],
        accessibleRepositoryNames: [String] = [],
        ownerScopes: [RepositoryScope] = []
    ) throws -> [GitHubSearchQueryPlan] {
        let ownerScopeByOwner = Dictionary(
            uniqueKeysWithValues: ownerScopes.compactMap { scope -> (String, RepositoryScope)? in
                switch scope {
                case let .org(owner), let .user(owner):
                    return (owner.lowercased(), scope)
                case .repo:
                    return nil
                }
            }
        )
        let accessibleByOwner = Dictionary(grouping: accessibleRepositoryNames) { repository in
            repository.split(separator: "/", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        }
        var explicitRepositoriesByOwner = [String: Set<String>]()
        var directScopes = [RepositoryScope]()
        var selectedOwnerScopes = Set<String>()

        for scope in scopes {
            switch scope {
            case let .repo(repository):
                let owner = repository.split(separator: "/", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
                let accessibleCount = accessibleByOwner[owner]?.count ?? 0
                guard !owner.isEmpty, ownerScopeByOwner[owner] != nil, accessibleCount <= 4_000 else {
                    directScopes.append(scope)
                    continue
                }
                explicitRepositoriesByOwner[owner, default: []].insert(repository.lowercased())
            case let .org(owner), let .user(owner):
                selectedOwnerScopes.insert(owner.lowercased())
                directScopes.append(scope)
            }
        }

        var plans = try directScopes.flatMap { scope -> [GitHubSearchQueryPlan] in
            let allowedRepositories: Set<String>?
            switch scope {
            case .repo:
                allowedRepositories = nil
            default:
                let ownerRepositories = Set(accessibleByOwner[scope.ownerName.lowercased()] ?? [])
                if ownerRepositories.count > 4_000 {
                    throw GitHubSearchQueryPlanError.ownerSearchScopeTooLarge(scope.ownerName)
                }
                // An owner scope supplied by the validated inventory proves
                // that this set is complete. Its being empty means GitHub did
                // not authorize any non-archived repositories for the owner,
                // not that the owner-wide search is unrestricted.
                allowedRepositories = ownerScopeByOwner[scope.ownerName.lowercased()] == nil
                    ? nil
                    : ownerRepositories
            }
            return [GitHubSearchQueryPlan(
                query: "\(baseQualifier) \(scope.qualifier)",
                allowedRepositoryNames: allowedRepositories
            )]
        }

        for (owner, repositories) in explicitRepositoriesByOwner where !selectedOwnerScopes.contains(owner) {
            guard let ownerScope = ownerScopeByOwner[owner] else { continue }
            plans.append(
                GitHubSearchQueryPlan(
                    query: "\(baseQualifier) \(ownerScope.qualifier)",
                    allowedRepositoryNames: repositories
                )
            )
        }

        return plans
    }
}
