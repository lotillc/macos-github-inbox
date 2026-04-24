import SwiftUI

@main
struct GitHubPRInboxApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var launchAtLoginManager: LaunchAtLoginManager
    @StateObject private var inboxViewModel: InboxViewModel
    @State private var settingsWindowController: SettingsWindowController?

    init() {
        let settings = AppSettings()
        let launchAtLoginManager = LaunchAtLoginManager()
        let inboxViewModel = InboxViewModel(settings: settings)

        _settings = StateObject(wrappedValue: settings)
        _launchAtLoginManager = StateObject(wrappedValue: launchAtLoginManager)
        _inboxViewModel = StateObject(wrappedValue: inboxViewModel)
    }

    var body: some Scene {
        MenuBarExtra {
            InboxMenuView(
                model: inboxViewModel,
                settings: settings,
                openSettings: showSettingsWindow
            )
            .onAppear {
                inboxViewModel.acknowledgeAlerts()
                inboxViewModel.acknowledgeSeenChanges()
            }
        } label: {
            MenuBarStatusIcon(
                count: inboxViewModel.actionableInboxCount,
                showsWarning: inboxViewModel.hasActiveAlert || (inboxViewModel.statusMessage != nil && !inboxViewModel.hasConfigurationIssue)
            )
        }
        .menuBarExtraStyle(.window)
    }

    private func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                model: inboxViewModel,
                settings: settings,
                launchAtLoginManager: launchAtLoginManager
            )
        }

        settingsWindowController?.show()
    }
}

private struct MenuBarStatusIcon: View {
    let count: Int
    let showsWarning: Bool

    private var badgeText: String? {
        if showsWarning {
            return "!"
        }

        guard count > 0 else {
            return nil
        }

        if count > 99 {
            return "99+"
        }

        return "\(count)"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: showsWarning ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(showsWarning ? Color.red : Color.primary)
                .frame(width: 16, height: 16)

            if let badgeText {
                Text(badgeText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, badgeText.count > 2 ? 5 : 4)
                    .frame(height: 14)
                    .background(Color.red)
                    .clipShape(Capsule())
            }
        }
        .frame(minWidth: 30, minHeight: 18, alignment: .leading)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if showsWarning {
            return "GitHub PR Inbox warning"
        }

        if count > 0 {
            return "GitHub PR Inbox, \(count) open items"
        }

        return "GitHub PR Inbox"
    }
}
