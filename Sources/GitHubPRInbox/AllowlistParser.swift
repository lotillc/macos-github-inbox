import Foundation

enum AllowlistParser {
    static func parseScopes(from text: String) -> [RepositoryScope] {
        let separators = CharacterSet(charactersIn: ",\n")
        let rawTokens = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var scopes: [RepositoryScope] = []

        for token in rawTokens {
            let normalized = token.lowercased()
            if normalized.hasPrefix("org:") {
                let org = String(token.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !org.isEmpty else {
                    continue
                }

                let scope = RepositoryScope.org(org)
                if seen.insert(scope.qualifier).inserted {
                    scopes.append(scope)
                }
                continue
            }

            if normalized.hasPrefix("repo:") {
                let repo = String(token.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard isRepoScope(repo) else {
                    continue
                }

                let scope = RepositoryScope.repo(repo)
                if seen.insert(scope.qualifier).inserted {
                    scopes.append(scope)
                }
                continue
            }

            if isRepoScope(token) {
                let scope = RepositoryScope.repo(token)
                if seen.insert(scope.qualifier).inserted {
                    scopes.append(scope)
                }
            } else {
                let scope = RepositoryScope.org(token)
                if seen.insert(scope.qualifier).inserted {
                    scopes.append(scope)
                }
            }
        }

        return scopes
    }

    private static func isRepoScope(_ token: String) -> Bool {
        let pieces = token.split(separator: "/", omittingEmptySubsequences: false)
        return pieces.count == 2 && pieces.allSatisfy { !$0.isEmpty }
    }
}
