import Foundation

enum GitHubSearchQueryBuilder {
    static func buildQueries(baseQualifier: String, scopes: [RepositoryScope]) -> [String] {
        scopes.map { scope in
            "\(baseQualifier) \(scope.qualifier)"
        }
    }
}
