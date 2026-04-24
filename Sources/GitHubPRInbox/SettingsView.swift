import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var model: InboxViewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager

    @State private var tokenText = ""
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
        .frame(minWidth: 600, minHeight: 520)
        .task {
            tokenText = model.loadStoredToken()
            allowlistDraft = settings.allowlistText
            trackedWorkflowsDraft = settings.trackedWorkflowNamesText
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.title2.weight(.semibold))

            Text("Minimal controls for what to watch, how often to refresh, and when to alert.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Account")

            SecureField("GitHub fine-grained PAT", text: $tokenText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button("Save") {
                    Task {
                        await model.saveToken(tokenText)
                    }
                }

                Button("Remove", role: .destructive) {
                    model.deleteToken()
                    tokenText = ""
                }

                Spacer()

                Text(settings.hasStoredToken ? "Keychain" : "No token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let tokenStatusMessage = model.tokenStatusMessage {
                Text(tokenStatusMessage)
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
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            content()

            Spacer()
        }
        .font(.subheadline)
    }
}
