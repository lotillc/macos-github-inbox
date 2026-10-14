import Combine
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var model: InboxViewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager

    @State private var draft = SettingsDraft()
    @State private var savedDraft = SettingsDraft()
    @State private var hasLoadedDrafts = false
    @State private var isGitHubAppExpanded = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if settings.gitHubAppConfiguration.missingConfigurationMessage != nil {
                    gitHubAppSection
                    Divider()
                }
                accountSection
                    .disabled(hasChangedGitHubAppConfiguration)
                if hasChangedGitHubAppConfiguration {
                    Text("Save GitHub App changes before connecting to GitHub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                watchSection
                Divider()
                alertsSection
                Divider()
                appSection
                if settings.gitHubAppConfiguration.missingConfigurationMessage == nil {
                    Divider()
                    gitHubAppSection
                }
            }
            .padding(24)
            .disabled(isSaving)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) { saveControls }
        .frame(minWidth: 620, minHeight: 700)
        .task {
            if !hasLoadedDrafts { reloadDrafts() }
        }
        .onChange(of: SettingsDraft(settings: settings)) { _, current in
            guard hasLoadedDrafts, !isSaving else { return }
            draft = SettingsDraft.rebased(draft, from: savedDraft, onto: current)
            savedDraft = current
        }
        .onReceive(model.$removedArchivedRepositoryNames) { names in
            reconcileArchivedScopes(names)
        }
        .onChange(of: model.availableRepositoryNames) { _, _ in
            reconcileArchivedScopes(model.removedArchivedRepositoryNames)
        }
    }

    private func reconcileArchivedScopes(_ names: Set<String>) {
        let currentlyArchived = Set(names.map { $0.lowercased() })
            .subtracting(model.availableRepositoryNames.map { $0.lowercased() })
        draft.watchScopes = Set(draft.watchScopes.filter { scope in
            guard case let .repo(repository) = scope else { return true }
            return !currentlyArchived.contains(repository.lowercased())
        })
    }

    private var gitHubAppSection: some View {
        DisclosureGroup(isExpanded: $isGitHubAppExpanded) {
            gitHubAppFields.padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("GitHub App")
                Text(settings.gitHubAppConfiguration.missingConfigurationMessage == nil
                     ? "Configured: \(settings.gitHubAppSlug)" : "Required before signing in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gitHubAppFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter the public Client ID and slug for your organization’s GitHub App. Do not enter a PAT, client secret, or private key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            twoColumnRow(label: "Client ID") {
                TextField("Iv1…", text: $draft.clientID)
                    .accessibilityLabel("GitHub App Client ID")
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            twoColumnRow(label: "App slug") {
                TextField("your-github-app", text: $draft.appSlug)
                    .accessibilityLabel("GitHub App slug")
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            twoColumnRow(label: "Expected orgs") {
                TextField("Optional organization logins, comma-separated", text: $draft.expectedOwners)
                    .accessibilityLabel("Expected organizations")
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            Text("Changing the Client ID or app slug signs out the current GitHub session and requires reconnecting.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.appInstallURL != nil {
                Button("Open App Install Page") {
                    model.openAppInstallationPage()
                }
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
                            await model.refreshAuthStatus(forceValidation: true)
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
                            await model.refreshAuthStatus(forceValidation: true)
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
                            await model.refreshAuthStatus(forceValidation: true)
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

            if pickerRepositoryNames.isEmpty && draft.watchScopes.isEmpty {
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
                        draft.watchScopes = Set(draft.watchScopes.filter { scope in
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
                Text("\(draft.watchScopes.count) watch scope\(draft.watchScopes.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Refresh Repositories") {
                    Task {
                        await model.refreshAuthStatus(forceValidation: true)
                    }
                }
                .disabled(!settings.hasStoredCredentials)
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
        let ownersFromScopes = draft.watchScopes.map(\.ownerName)
        return canonicalNames(model.availableRepositoryOwners + ownersFromRepositories + ownersFromScopes)
    }

    private var pickerRepositoryNames: [String] {
        let selectedRepositories = draft.watchScopes.compactMap { scope -> String? in
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
        draft.watchScopes.contains { scope in
            guard case let .repo(selectedRepository) = scope else {
                return false
            }
            return selectedRepository.caseInsensitiveCompare(repository) == .orderedSame
        }
    }

    private func setRepositoryScope(_ repository: String, selected: Bool) {
        draft.watchScopes = Set(draft.watchScopes.filter { scope in
            guard case let .repo(selectedRepository) = scope else {
                return true
            }
            return selectedRepository.caseInsensitiveCompare(repository) != .orderedSame
        })
        if selected {
            draft.watchScopes.insert(.repo(repository))
        }
    }

    private func hasOrganizationScope(_ organization: String) -> Bool {
        draft.watchScopes.contains { scope in
            guard case let .org(selectedOrganization) = scope else {
                return false
            }
            return selectedOrganization.caseInsensitiveCompare(organization) == .orderedSame
        }
    }

    private func hasUserScope(_ user: String) -> Bool {
        draft.watchScopes.contains { scope in
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
        draft.watchScopes = Set(draft.watchScopes.filter { scope in
            guard case let .org(selectedOrganization) = scope else {
                return true
            }
            return selectedOrganization.caseInsensitiveCompare(organization) != .orderedSame
        })
        if selected {
            draft.watchScopes.insert(.org(organization))
        }
    }

    private func setUserScope(_ user: String, selected: Bool) {
        draft.watchScopes = Set(draft.watchScopes.filter { scope in
            guard case let .user(selectedUser) = scope else {
                return true
            }
            return selectedUser.caseInsensitiveCompare(user) != .orderedSame
        })
        if selected {
            draft.watchScopes.insert(.user(user))
        }
    }

    private func setOwnerScope(_ owner: String, selected: Bool) {
        guard selected else {
            draft.watchScopes = Set(draft.watchScopes.filter { scope in
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
        draft.watchScopes.reduce(into: 0) { count, scope in
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

            editorCard(text: $draft.trackedWorkflows, minHeight: 90)
                .accessibilityLabel("Tracked workflow names")
                .help("Enter one workflow name per line")

            HStack {
                let trackedWorkflowCount = draft.trackedWorkflows
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .count

                Text("\(trackedWorkflowCount) workflow\(trackedWorkflowCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
        }
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("App")

            twoColumnRow(label: "Refresh") {
                Picker("Refresh", selection: $draft.refreshInterval) {
                    ForEach(AppSettings.supportedRefreshIntervals, id: \.self) { interval in
                        Text("\(interval) min").tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120, alignment: .leading)
                .accessibilityLabel("Refresh interval")
            }

            twoColumnRow(label: "Sort") {
                Picker("Sort", selection: $draft.sortOption) {
                    ForEach(PullRequestSortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .leading)
                .accessibilityLabel("Default PR sort")
            }

            Toggle("Launch at login", isOn: $draft.launchAtLogin)

            Button("Refresh Now") {
                Task { await model.refresh() }
            }
            .help("Refresh using saved settings. Save changes to apply edits.")
        }
    }

    private var hasChangedGitHubAppConfiguration: Bool {
        draft.clientID != savedDraft.clientID || draft.appSlug != savedDraft.appSlug
            || draft.expectedOwners != savedDraft.expectedOwners
    }

    private var hasChanges: Bool { hasLoadedDrafts && draft != savedDraft }

    private var saveControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let saveError {
                        Text(saveError).foregroundStyle(.red)
                    } else {
                        Text(hasChanges ? "Unsaved changes" : (saveMessage ?? "Changes take effect when you save."))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Revert changes", action: reloadDrafts)
                    .disabled(!hasChanges || isSaving)
                Button(isSaving ? "Saving…" : "Save changes") {
                    Task { await saveChanges() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasChanges || isSaving)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .padding(.top, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func reloadDrafts() {
        savedDraft = SettingsDraft(settings: settings)
        draft = savedDraft
        hasLoadedDrafts = true
        isGitHubAppExpanded = settings.gitHubAppConfiguration.missingConfigurationMessage != nil
        saveError = nil
        saveMessage = nil
    }

    private func saveChanges() async {
        guard hasChanges, !isSaving else { return }
        isSaving = true
        defer {
            let current = SettingsDraft(settings: settings)
            draft = SettingsDraft.rebased(draft, from: savedDraft, onto: current)
            savedDraft = current
            isSaving = false
        }
        saveError = nil
        saveMessage = nil
        var proposed = draft
        let baseline = savedDraft
        do {
            // Validate and save app identity before applying any other preferences.
            if hasChangedGitHubAppConfiguration {
                try await model.saveGitHubAppConfiguration(
                    clientID: proposed.clientID, appSlug: proposed.appSlug, expectedOwner: proposed.expectedOwners
                )
            }
            proposed = SettingsDraft.preparedForSaving(proposed, from: baseline,
                onto: SettingsDraft(settings: settings), excluding: model.removedArchivedRepositoryNames,
                availableRepositories: Set(model.availableRepositoryNames))
            settings.allowlistText = proposed.watchScopes.map(\.qualifier).sorted().joined(separator: "\n")
            settings.trackedWorkflowNamesText = proposed.trackedWorkflows
            settings.refreshIntervalMinutes = proposed.refreshInterval
            settings.sortOption = proposed.sortOption

            var launchError: String?
            if proposed.launchAtLogin != settings.launchAtLoginRequested {
                if await launchAtLoginManager.setEnabled(proposed.launchAtLogin) {
                    settings.launchAtLoginRequested = proposed.launchAtLogin
                } else {
                    launchError = launchAtLoginManager.lastErrorMessage ?? "Could not update launch at login."
                }
            }
            reloadDrafts()
            if let launchError {
                draft.launchAtLogin = proposed.launchAtLogin
                saveError = "Other settings saved. Launch at login: \(launchError)"
            } else {
                saveMessage = "Changes saved."
            }
            await model.refreshAuthStatus(forceValidation: true)
            await model.refresh()
        } catch {
            saveError = error.localizedDescription
            isGitHubAppExpanded = true
        }
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
