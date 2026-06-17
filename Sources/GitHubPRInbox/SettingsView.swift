import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var model: InboxViewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager

    @State private var allowlistDraft = ""
    @State private var trackedWorkflowsDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
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
        .frame(minWidth: 620, minHeight: 560)
        .task {
            allowlistDraft = settings.allowlistText
            trackedWorkflowsDraft = settings.trackedWorkflowNamesText
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

            case let .ssoRequired(_, message):
                authMessage(message, tone: .warning)

                HStack(spacing: 10) {
                    Button("Open Org SSO") {
                        model.openSSOAuthorization()
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
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Watch")

            Text("One org or repo per line.")
                .font(.caption)
                .foregroundStyle(.secondary)

            editorCard(text: $allowlistDraft, minHeight: 120)

            HStack {
                let draftScopes = AllowlistParser.parseScopes(from: allowlistDraft)

                Text("\(draftScopes.count) scope\(draftScopes.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Apply") {
                    settings.allowlistText = allowlistDraft
                    Task {
                        await model.refreshAuthStatus()
                        await model.refresh()
                    }
                }
                .disabled(allowlistDraft == settings.allowlistText)
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
