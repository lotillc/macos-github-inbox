import Combine
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var model: InboxViewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager

    @State private var watchScopeDraft = Set<RepositoryScope>()
    @State private var trackedWorkflowsDraft = ""
    @State private var gitHubAppClientIDDraft = ""
    @State private var gitHubAppSlugDraft = ""
    @State private var gitHubAppExpectedOwnerDraft = ""
    @State private var gitHubAppConfigurationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                gitHubAppSection
                Divider()
                accountSection
                Divider()
                watchSection
                Divider()
                alertsSection
                Divider()
                appSection
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 620, minHeight: 700)
        .task {
            watchScopeDraft = Set(settings.scopes)
            trackedWorkflowsDraft = settings.trackedWorkflowNamesText
            gitHubAppClientIDDraft = settings.gitHubAppClientID
            gitHubAppSlugDraft = settings.gitHubAppSlug
            gitHubAppExpectedOwnerDraft = settings.gitHubAppExpectedOwner
        }
        .onReceive(model.$removedArchivedRepositoryNames) { archivedRepositories in
            guard !archivedRepositories.isEmpty else {
                return
            }

            watchScopeDraft = Set(watchScopeDraft.filter { scope in
                guard case let .repo(repository) = scope else {
                    return true
                }

                return !archivedRepositories.contains(repository.lowercased())
            })
        }
    }

    private var gitHubAppSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("GitHub App")

            Text("Enter the public Client ID and slug for your organization’s GitHub App. Do not enter a PAT, client secret, or private key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            twoColumnRow(label: "Client ID") {
                TextField("Iv1…", text: $gitHubAppClientIDDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            twoColumnRow(label: "App slug") {
                TextField("your-github-app", text: $gitHubAppSlugDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            twoColumnRow(label: "Expected orgs") {
                TextField("Optional organization logins, comma-separated", text: $gitHubAppExpectedOwnerDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            Text("Changing the Client ID or app slug signs out the current GitHub session and requires reconnecting.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Save GitHub App") {
                    Task {
                        do {
                            try await model.saveGitHubAppConfiguration(
                                clientID: gitHubAppClientIDDraft,
                                appSlug: gitHubAppSlugDraft,
                                expectedOwner: gitHubAppExpectedOwnerDraft
                            )
                            gitHubAppClientIDDraft = settings.gitHubAppClientID
                            gitHubAppSlugDraft = settings.gitHubAppSlug
                            gitHubAppExpectedOwnerDraft = settings.gitHubAppExpectedOwner
                            gitHubAppConfigurationError = nil
                        } catch {
                            gitHubAppConfigurationError = error.localizedDescription
                        }
                    }
                }
                .disabled(!hasChangedGitHubAppConfiguration)

                if model.appInstallURL != nil {
                    Button("Open App Install Page") {
                        model.openAppInstallationPage()
                    }
                }
            }

            if let gitHubAppConfigurationError {
                authMessage(gitHubAppConfigurationError, tone: .warning)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.title2.weight(.semibold))

            Text("Choose what to watch, manage GitHub sign-in, and control refresh behavior.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Account")

            switch model.authState {
            case let .missingConfiguration(message):
                authMessage(message, tone: .warning)

            case .signedOut:
                Text("Sign in with the installed GitHub App to load pull requests and workflow failures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Sign In with GitHub") {
                        Task {
                            await model.beginSignIn()
                        }
                    }

                    Spacer()

                    Text(settings.hasStoredCredentials ? "Stored session" : "No session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case let .authorizing(authorization):
                Text("Finish sign-in in your browser, then return here while the app waits for authorization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Verification Code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(authorization.userCode)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Text("Open \(authorization.verificationURL.absoluteString) and enter the code if GitHub does not auto-fill it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("Open GitHub Verification Page") {
                        model.openGitHubVerificationPage()
                    }

                    Button("Cancel", role: .destructive) {
                        model.cancelSignIn()
                    }

                    Spacer()

                    Text(settings.hasStoredCredentials ? "Stored session" : "No session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case let .signedIn(summary):
                VStack(alignment: .leading, spacing: 6) {
                    Text("@\(summary.user.login)")
                        .font(.headline)

                    if let tokenExpiresAt = summary.tokenExpiresAt {
                        Text("Access token expires \(tokenExpiresAt.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !summary.authorizedOwners.isEmpty {
                        Text("Authorized owners: \(summary.authorizedOwners.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button("Reconnect") {
                        Task {
                            await model.beginSignIn()
                        }
                    }

                    Button("Refresh Auth Status") {
                        Task {
                            await model.refreshAuthStatus()
                        }
                    }

                    Button("Sign Out", role: .destructive) {
                        model.signOut()
                    }

                    Spacer()

                    Text(settings.hasStoredCredentials ? "Keychain" : "No session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case let .refreshFailed(message):
                authMessage(message, tone: .warning)

                HStack(spacing: 10) {
                    Button("Reconnect") {
                        Task {
                            await model.beginSignIn()
                        }
                    }

                    Button("Sign Out", role: .destructive) {
                        model.signOut()
                    }
                }

            case let .rateLimited(message):
                authMessage(message, tone: .warning)

                HStack(spacing: 10) {
                    Button("Retry Auth Check") {
                        Task {
                            await model.refreshAuthStatus()
                        }
                    }

                    Button("Sign Out", role: .destructive) {
                        model.signOut()
                    }
                }

            case let .ssoRequired(_, message):
                authMessage(message, tone: .warning)

                Text("Complete organization SSO in your browser, then reconnect. If the organization is still unavailable, revoke this GitHub App authorization on GitHub and reconnect so GitHub can issue an SSO-authorized token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Open Org SSO") {
                        model.openSSOAuthorization()
                    }

                    Button("Manage App Authorization") {
                        model.openGitHubAppAuthorizations()
                    }

                    Button("Reconnect After SSO") {
                        Task {
                            await model.beginSignIn()
                        }
                    }

                    Button("Sign Out", role: .destructive) {
                        model.signOut()
                    }
                }

            case let .installationMissing(_, message):
                authMessage(message, tone: .warning)

                HStack(spacing: 10) {
                    if model.appInstallURL != nil {
                        Button("Open App Install Page") {
                            model.openAppInstallationPage()
                        }
                    }

                    Button("Retry Auth Check") {
                        Task {
                            await model.refreshAuthStatus()
                        }
                    }

                    Button("Reconnect") {
                        Task {
                            await model.beginSignIn()
                        }
                    }

                    Button("Sign Out", role: .destructive) {
                        model.signOut()
                    }
                }
            }

            if let authStatusMessage = model.authStatusMessage {
                Text(authStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var watchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Watch")

            Text("Choose repositories that are available to both your GitHub account and the installed GitHub App.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if pickerRepositoryNames.isEmpty && watchScopeDraft.isEmpty {
                authMessage("Sign in, then refresh auth status to load repositories for this picker.", tone: .neutral)
            } else {
                HStack(spacing: 10) {
                    Button("Select All Available") {
                        for owner in model.availableOrganizationOwners {
                            setOrganizationScope(owner, selected: true)
                            for repository in pickerRepositoryNames where RepositoryScope.repo(repository).ownerName.caseInsensitiveCompare(owner) == .orderedSame {
                                setRepositoryScope(repository, selected: false)
                            }
                        }
                        for owner in model.availablePersonalAccountOwners {
                            setUserScope(owner, selected: true)
                            for repository in pickerRepositoryNames where RepositoryScope.repo(repository).ownerName.caseInsensitiveCompare(owner) == .orderedSame {
                                setRepositoryScope(repository, selected: false)
                            }
                        }
                    }

                    Button("Clear Repository Selections") {
                        watchScopeDraft = Set(watchScopeDraft.filter { scope in
                            if case .org = scope {
                                return true
                            }
                            if case .user = scope {
                                return true
                            }
                            return false
                        })
                    }

                    Spacer()

                    Text(selectedRepositoryCount == 1 ? "1 repository selected" : "\(selectedRepositoryCount) repositories selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                repositoryPicker
            }

            HStack {
                Text("\(watchScopeDraft.count) watch scope\(watchScopeDraft.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Refresh Repositories") {
                    Task {
                        await model.refreshAuthStatus()
                    }
                }
                .disabled(!settings.hasStoredCredentials)

                Button("Apply") {
                    settings.allowlistText = watchScopeDraft
                        .map(\.qualifier)
                        .sorted()
                        .joined(separator: "\n")
                    Task {
                        await model.refreshAuthStatus()
                        await model.refresh()
                    }
                }
                .disabled(watchScopeDraft == Set(settings.scopes))
            }
        }
    }

    private var repositoryPicker: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(repositoryOwners, id: \.self) { owner in
                    let repositories = pickerRepositoryNames.filter {
                        RepositoryScope.repo($0).ownerName.caseInsensitiveCompare(owner) == .orderedSame
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if isAvailableOwner(owner) || hasOwnerScope(owner) {
                            Toggle(
                                isAvailableOwner(owner)
                                    ? "Watch all repositories in \(owner)"
                                    : "Watch all repositories in \(owner) (no longer available)",
                            isOn: Binding(
                                    get: { hasOwnerScope(owner) },
                                    set: { isWatchingAll in
                                        if isWatchingAll {
                                            setOwnerScope(owner, selected: true)
                                            for repository in repositories {
                                                setRepositoryScope(repository, selected: false)
                                            }
                                        } else {
                                            setOwnerScope(owner, selected: false)
                                        }
                                    }
                                )
                            )
                            .font(.subheadline.weight(.semibold))
                        }

                        if hasOwnerScope(owner) {
                            Text("GitHub will limit results to repositories this user token can access.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(repositories, id: \.self) { repository in
                                Toggle(
                                    isRepositoryAvailable(repository)
                                        ? repository
                                        : "\(repository) (no longer available)",
                                    isOn: Binding(
                                        get: { hasRepositoryScope(repository) },
                                        set: { isSelected in
                                            setRepositoryScope(repository, selected: isSelected)
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)
                                .padding(.leading, 20)
                            }
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(minHeight: 160, maxHeight: 280)
    }

    private var repositoryOwners: [String] {
        let ownersFromRepositories = pickerRepositoryNames.map { RepositoryScope.repo($0).ownerName }
        let ownersFromScopes = watchScopeDraft.map(\.ownerName)
        return canonicalNames(model.availableRepositoryOwners + ownersFromRepositories + ownersFromScopes)
    }

    private var pickerRepositoryNames: [String] {
        let selectedRepositories = watchScopeDraft.compactMap { scope -> String? in
            guard case let .repo(repository) = scope else {
                return nil
            }
            return repository
        }
        return canonicalNames(selectedRepositories + model.availableRepositoryNames)
    }

    private func isRepositoryAvailable(_ repository: String) -> Bool {
        model.availableRepositoryNames.contains {
            $0.caseInsensitiveCompare(repository) == .orderedSame
        }
    }

    private func isOrganizationOwner(_ owner: String) -> Bool {
        model.availableOrganizationOwners.contains {
            $0.caseInsensitiveCompare(owner) == .orderedSame
        }
    }

    private func isPersonalAccountOwner(_ owner: String) -> Bool {
        model.availablePersonalAccountOwners.contains {
            $0.caseInsensitiveCompare(owner) == .orderedSame
        }
    }

    private func isAvailableOwner(_ owner: String) -> Bool {
        isOrganizationOwner(owner) || isPersonalAccountOwner(owner)
    }

    private func canonicalNames(_ names: [String]) -> [String] {
        var canonicalNamesByIdentifier = [String: String]()
        for name in names where !name.isEmpty {
            canonicalNamesByIdentifier[name.lowercased()] = name
        }
        return canonicalNamesByIdentifier.values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func hasRepositoryScope(_ repository: String) -> Bool {
        watchScopeDraft.contains { scope in
            guard case let .repo(selectedRepository) = scope else {
                return false
            }
            return selectedRepository.caseInsensitiveCompare(repository) == .orderedSame
        }
    }

    private func setRepositoryScope(_ repository: String, selected: Bool) {
        watchScopeDraft = Set(watchScopeDraft.filter { scope in
            guard case let .repo(selectedRepository) = scope else {
                return true
            }
            return selectedRepository.caseInsensitiveCompare(repository) != .orderedSame
        })
        if selected {
            watchScopeDraft.insert(.repo(repository))
        }
    }

    private func hasOrganizationScope(_ organization: String) -> Bool {
        watchScopeDraft.contains { scope in
            guard case let .org(selectedOrganization) = scope else {
                return false
            }
            return selectedOrganization.caseInsensitiveCompare(organization) == .orderedSame
        }
    }

    private func hasUserScope(_ user: String) -> Bool {
        watchScopeDraft.contains { scope in
            guard case let .user(selectedUser) = scope else {
                return false
            }
            return selectedUser.caseInsensitiveCompare(user) == .orderedSame
        }
    }

    private func hasOwnerScope(_ owner: String) -> Bool {
        hasOrganizationScope(owner) || hasUserScope(owner)
    }

    private func setOrganizationScope(_ organization: String, selected: Bool) {
        watchScopeDraft = Set(watchScopeDraft.filter { scope in
            guard case let .org(selectedOrganization) = scope else {
                return true
            }
            return selectedOrganization.caseInsensitiveCompare(organization) != .orderedSame
        })
        if selected {
            watchScopeDraft.insert(.org(organization))
        }
    }

    private func setUserScope(_ user: String, selected: Bool) {
        watchScopeDraft = Set(watchScopeDraft.filter { scope in
            guard case let .user(selectedUser) = scope else {
                return true
            }
            return selectedUser.caseInsensitiveCompare(user) != .orderedSame
        })
        if selected {
            watchScopeDraft.insert(.user(user))
        }
    }

    private func setOwnerScope(_ owner: String, selected: Bool) {
        guard selected else {
            watchScopeDraft = Set(watchScopeDraft.filter { scope in
                switch scope {
                case let .org(selectedOwner), let .user(selectedOwner):
                    return selectedOwner.caseInsensitiveCompare(owner) != .orderedSame
                case .repo:
                    return true
                }
            })
            return
        }

        if isOrganizationOwner(owner) || hasOrganizationScope(owner) {
            setOrganizationScope(owner, selected: true)
        } else {
            setUserScope(owner, selected: true)
        }
    }

    private var selectedRepositoryCount: Int {
        watchScopeDraft.reduce(into: 0) { count, scope in
            if case .repo = scope {
                count += 1
            }
        }
    }

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Alerts")

            Text("Track workflow names. Alerts fire only for new failures after baseline.")
                .font(.caption)
                .foregroundStyle(.secondary)

            editorCard(text: $trackedWorkflowsDraft, minHeight: 90)

            HStack {
                let trackedWorkflowCount = trackedWorkflowsDraft
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .count

                Text("\(trackedWorkflowCount) workflow\(trackedWorkflowCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Apply") {
                    settings.trackedWorkflowNamesText = trackedWorkflowsDraft
                    Task {
                        await model.refresh()
                    }
                }
                .disabled(trackedWorkflowsDraft == settings.trackedWorkflowNamesText)
            }
        }
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("App")

            twoColumnRow(label: "Refresh") {
                Picker("Refresh", selection: $settings.refreshIntervalMinutes) {
                    ForEach(AppSettings.supportedRefreshIntervals, id: \.self) { interval in
                        Text("\(interval) min").tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120, alignment: .leading)
            }

            twoColumnRow(label: "Sort") {
                Picker("Sort", selection: Binding(
                    get: { settings.sortOption },
                    set: { settings.sortOption = $0 }
                )) {
                    ForEach(PullRequestSortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .leading)
            }

            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { settings.launchAtLoginRequested },
                    set: { newValue in
                        settings.launchAtLoginRequested = newValue

                        Task {
                            let success = await launchAtLoginManager.setEnabled(newValue)
                            if !success {
                                settings.launchAtLoginRequested = !newValue
                            }
                        }
                    }
                )
            )

            if let launchAtLoginError = launchAtLoginManager.lastErrorMessage {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Refresh Now") {
                Task {
                    await model.refresh()
                }
            }
        }
    }

    private var hasChangedGitHubAppConfiguration: Bool {
        gitHubAppClientIDDraft != settings.gitHubAppClientID
            || gitHubAppSlugDraft != settings.gitHubAppSlug
            || gitHubAppExpectedOwnerDraft != settings.gitHubAppExpectedOwner
    }

    private enum AuthMessageTone {
        case warning
        case neutral
    }

    private func authMessage(_ message: String, tone: AuthMessageTone) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(tone == .warning ? Color.yellow : Color.accentColor)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    private func editorCard(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .frame(minHeight: minHeight)
            .background(.quaternary.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func twoColumnRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)

            content()
        }
        .font(.caption)
    }
}
