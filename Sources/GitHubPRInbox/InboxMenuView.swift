import AppKit
import SwiftUI

@MainActor
private enum PullRequestDateFormatter {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func relativeString(for date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: .now)
    }
}

struct InboxMenuView: View {
    private enum SelectableRow: Identifiable, Equatable {
        case pullRequest(PullRequestItem)
        case workflowFailure(WorkflowFailureItem)

        var id: String {
            switch self {
            case let .pullRequest(item):
                "pr:\(item.id)"
            case let .workflowFailure(item):
                "wf:\(item.id)"
            }
        }

        var url: URL {
            switch self {
            case let .pullRequest(item):
                item.url
            case let .workflowFailure(item):
                item.url
            }
        }
    }

    private enum InboxSection: String, CaseIterable, Identifiable {
        case reviewRequests
        case authoredPullRequests
        case workflowFailures

        var id: String { rawValue }

        var title: String {
            switch self {
            case .reviewRequests:
                "Assigned"
            case .authoredPullRequests:
                "Authored"
            case .workflowFailures:
                "Failures"
            }
        }
    }

    private static let defaultVisibleRowLimit = 10
    private static let loadMoreStep = 10
    private static let maxVisibleRowLimit = 30
    fileprivate static let rowHeight: CGFloat = 28
    private static let menuWidth: CGFloat = 580
    fileprivate static let workflowRepoColumnWidth: CGFloat = 180
    fileprivate static let workflowBranchColumnWidth: CGFloat = 132

    @ObservedObject var model: InboxViewModel
    @ObservedObject var settings: AppSettings
    let openSettings: () -> Void

    @State private var selectedSection: InboxSection = .reviewRequests
    @State private var visibleRowLimitBySection: [InboxSection: Int] = [:]
    @State private var highlightedRowIDBySection: [InboxSection: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let statusMessage = model.statusMessage {
                statusBanner(statusMessage)
            }

            if model.hasConfigurationIssue {
                onboardingSection
            } else {
                sectionPicker
                contentArea
            }
        }
        .padding(12)
        .frame(width: Self.menuWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(MenuWindowContentFitter(fitKey: menuSizingKey))
        .background(
            KeyboardEventBridge(
                onLeftArrow: selectPreviousSection,
                onRightArrow: selectNextSection,
                onUpArrow: moveHighlightUp,
                onDownArrow: moveHighlightDown,
                onReturn: openHighlightedRow,
                onRefresh: refreshNow,
                onSectionOne: { selectedSection = .reviewRequests },
                onSectionTwo: { selectedSection = .authoredPullRequests },
                onSectionThree: { selectedSection = .workflowFailures }
            )
        )
        .task(id: visibleCITaskKey) {
            await model.refreshCIStatuses(for: visiblePullRequestsForCurrentSection())
        }
        .onAppear {
            ensureHighlightedRowIsValid()
        }
        .onChange(of: selectedSection) { _, _ in
            ensureHighlightedRowIsValid()
        }
        .onChange(of: model.reviewRequests) { _, _ in
            ensureHighlightedRowIsValid()
        }
        .onChange(of: model.authoredPullRequests) { _, _ in
            ensureHighlightedRowIsValid()
        }
        .onChange(of: model.workflowFailures) { _, _ in
            ensureHighlightedRowIsValid()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                if let currentUser = model.currentUser {
                    Text("@\(currentUser.login)")
                }

                if let lastRefreshAt = model.lastRefreshAt, !model.hasConfigurationIssue {
                    Text(PullRequestDateFormatter.relativeString(for: lastRefreshAt))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 10) {
                Button {
                    Task {
                        await model.refresh()
                    }
                } label: {
                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh now")

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Open settings")

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(InboxSection.allCases) { section in
                sectionButton(for: section)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func sectionButton(for section: InboxSection) -> some View {
        let isSelected = selectedSection == section

        return HStack(spacing: 5) {
            Text(section.title)
            Text(sectionCount(for: section))
                .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture {
            selectedSection = section
        }
    }

    private var onboardingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finish Setup")
                .font(.subheadline.weight(.semibold))

            if !settings.hasStoredToken {
                Text("Add a fine-grained GitHub PAT in Settings.")
                    .foregroundStyle(.secondary)
            }

            if settings.scopes.isEmpty {
                Text("Add at least one org or repo to watch.")
                    .foregroundStyle(.secondary)
            }

            Button("Open Settings") {
                openSettings()
            }
        }
        .font(.caption)
        .padding(12)
        .background(.quaternary.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var contentArea: some View {
        let workflowItems = prioritizedWorkflowFailures(model.workflowFailures)
        let sectionContent = currentSectionContent()
        let currentCount = selectedSection == .workflowFailures ? workflowItems.count : sectionContent.items.count
        let visibleCount = visibleItemCount(for: currentCount)
        let visiblePullRequests = Array(sectionContent.items.prefix(visibleCount))
        let visibleWorkflowFailures = Array(workflowItems.prefix(visibleCount))

        return VStack(alignment: .leading, spacing: 8) {
            if currentCount == 0 {
                Text(sectionContent.emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                listContent(selectableRows: selectableRows(
                    pullRequests: visiblePullRequests,
                    workflowFailures: visibleWorkflowFailures
                ))
            }

            if currentCount > visibleCount {
                Button(loadMoreTitle(visibleCount: visibleCount, totalCount: currentCount)) {
                    loadMore()
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
            }

            if visibleCount > Self.defaultVisibleRowLimit {
                Button("Show Less") {
                    resetVisibleRowLimit()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func listContent(selectableRows: [SelectableRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(selectableRows) { row in
                Button {
                    open(row)
                } label: {
                    switch row {
                    case let .pullRequest(item):
                        PullRequestRow(
                            item: item,
                            ciStatus: model.ciStatus(for: item),
                            debugSummary: model.ciDebugSummary(for: item),
                            isHighlighted: highlightedRowID == row.id,
                            isNew: selectedSection == .reviewRequests
                                ? model.newlyAssignedPullRequestIDs.contains(item.id)
                                : model.newlyAuthoredPullRequestIDs.contains(item.id)
                        )
                    case let .workflowFailure(item):
                        WorkflowFailureRow(
                            item: item,
                            isHighlighted: highlightedRowID == row.id,
                            isNew: model.newlyWorkflowFailureIDs.contains(item.id)
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func currentSectionContent() -> (
        items: [PullRequestItem],
        emptyText: String
    ) {
        switch selectedSection {
        case .reviewRequests:
            (
                items: sortedPullRequests(model.reviewRequests),
                emptyText: "No assigned PRs."
            )
        case .authoredPullRequests:
            (
                items: sortedPullRequests(model.authoredPullRequests),
                emptyText: "No authored PRs."
            )
        case .workflowFailures:
            (
                items: [],
                emptyText: "No failed actions."
            )
        }
    }

    private func sectionCount(for section: InboxSection) -> String {
        switch section {
        case .reviewRequests:
            "\(model.reviewRequests.count)"
        case .authoredPullRequests:
            "\(model.authoredPullRequests.count)"
        case .workflowFailures:
            "\(model.workflowFailures.count)"
        }
    }

    private func currentVisibleRowLimit() -> Int {
        min(
            visibleRowLimitBySection[selectedSection, default: Self.defaultVisibleRowLimit],
            Self.maxVisibleRowLimit
        )
    }

    private func visibleItemCount(for totalCount: Int) -> Int {
        min(totalCount, currentVisibleRowLimit())
    }

    private func loadMore() {
        let currentLimit = currentVisibleRowLimit()
        visibleRowLimitBySection[selectedSection] = min(currentLimit + Self.loadMoreStep, Self.maxVisibleRowLimit)
    }

    private func resetVisibleRowLimit() {
        visibleRowLimitBySection[selectedSection] = Self.defaultVisibleRowLimit
    }

    private func loadMoreTitle(visibleCount: Int, totalCount: Int) -> String {
        let nextCount = min(
            visibleCount + Self.loadMoreStep,
            min(totalCount, Self.maxVisibleRowLimit)
        )
        return "Load More (\(nextCount))"
    }

    private var visibleCITaskKey: String {
        let ids = visiblePullRequestsForCurrentSection().map(\.id).joined(separator: ",")
        return "\(selectedSection.rawValue)|\(ids)"
    }

    private var menuSizingKey: String {
        let rows = currentSelectableRows().map(\.id).joined(separator: ",")
        return [
            selectedSection.rawValue,
            rows,
            "\(model.hasConfigurationIssue)",
            model.statusMessage ?? "",
            "\(currentVisibleRowLimit())",
            "\(settings.hasStoredToken)",
            "\(settings.scopes.count)",
        ].joined(separator: "|")
    }

    private var highlightedRowID: String? {
        highlightedRowIDBySection[selectedSection]
    }

    private func selectableRows(
        pullRequests: [PullRequestItem],
        workflowFailures: [WorkflowFailureItem]
    ) -> [SelectableRow] {
        switch selectedSection {
        case .reviewRequests, .authoredPullRequests:
            return pullRequests.map(SelectableRow.pullRequest)
        case .workflowFailures:
            return workflowFailures.map(SelectableRow.workflowFailure)
        }
    }

    private func currentSelectableRows() -> [SelectableRow] {
        let workflowItems = prioritizedWorkflowFailures(model.workflowFailures)
        let sectionContent = currentSectionContent()
        let visibleCount = visibleItemCount(
            for: selectedSection == .workflowFailures ? workflowItems.count : sectionContent.items.count
        )

        return selectableRows(
            pullRequests: Array(sectionContent.items.prefix(visibleCount)),
            workflowFailures: Array(workflowItems.prefix(visibleCount))
        )
    }

    private func ensureHighlightedRowIsValid() {
        let rows = currentSelectableRows()
        guard !rows.isEmpty else {
            highlightedRowIDBySection[selectedSection] = nil
            return
        }

        if let highlightedRowID, rows.contains(where: { $0.id == highlightedRowID }) {
            return
        }

        highlightedRowIDBySection[selectedSection] = rows.first?.id
    }

    private func moveHighlightDown() {
        let rows = currentSelectableRows()
        guard !rows.isEmpty else { return }

        guard let highlightedRowID,
              let currentIndex = rows.firstIndex(where: { $0.id == highlightedRowID })
        else {
            highlightedRowIDBySection[selectedSection] = rows.first?.id
            return
        }

        let nextIndex = min(currentIndex + 1, rows.count - 1)
        highlightedRowIDBySection[selectedSection] = rows[nextIndex].id
    }

    private func moveHighlightUp() {
        let rows = currentSelectableRows()
        guard !rows.isEmpty else { return }

        guard let highlightedRowID,
              let currentIndex = rows.firstIndex(where: { $0.id == highlightedRowID })
        else {
            highlightedRowIDBySection[selectedSection] = rows.first?.id
            return
        }

        let previousIndex = max(currentIndex - 1, 0)
        highlightedRowIDBySection[selectedSection] = rows[previousIndex].id
    }

    private func openHighlightedRow() {
        let rows = currentSelectableRows()
        guard let highlightedRowID,
              let row = rows.first(where: { $0.id == highlightedRowID })
        else { return }

        open(row)
    }

    private func open(_ row: SelectableRow) {
        NSWorkspace.shared.open(row.url)
    }

    private func refreshNow() {
        Task {
            await model.refresh()
        }
    }

    private func selectPreviousSection() {
        guard let currentIndex = InboxSection.allCases.firstIndex(of: selectedSection) else {
            return
        }

        let previousIndex = max(currentIndex - 1, 0)
        selectedSection = InboxSection.allCases[previousIndex]
    }

    private func selectNextSection() {
        guard let currentIndex = InboxSection.allCases.firstIndex(of: selectedSection) else {
            return
        }

        let nextIndex = min(currentIndex + 1, InboxSection.allCases.count - 1)
        selectedSection = InboxSection.allCases[nextIndex]
    }

    private func visiblePullRequestsForCurrentSection() -> [PullRequestItem] {
        let visibleLimit = currentVisibleRowLimit()
        switch selectedSection {
        case .reviewRequests:
            return Array(sortedPullRequests(model.reviewRequests).prefix(visibleLimit))
        case .authoredPullRequests:
            return Array(sortedPullRequests(model.authoredPullRequests).prefix(visibleLimit))
        case .workflowFailures:
            return []
        }
    }

    private func sortedPullRequests(_ items: [PullRequestItem]) -> [PullRequestItem] {
        items.sorted { lhs, rhs in
            if settings.sortOption == .oldestFirst {
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt < rhs.updatedAt
                }
            } else {
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
            }

            return lhs.number > rhs.number
        }
    }

    private func prioritizedWorkflowFailures(_ items: [WorkflowFailureItem]) -> [WorkflowFailureItem] {
        items.sorted { lhs, rhs in
            let lhsIsNew = model.newlyWorkflowFailureIDs.contains(lhs.id)
            let rhsIsNew = model.newlyWorkflowFailureIDs.contains(rhs.id)

            if lhsIsNew != rhsIsNew {
                return lhsIsNew
            }

            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }

            return lhs.workflowName < rhs.workflowName
        }
    }

    private func isMarkedNew(_ item: PullRequestItem) -> Bool {
        switch selectedSection {
        case .reviewRequests:
            return model.newlyAssignedPullRequestIDs.contains(item.id)
        case .authoredPullRequests:
            return model.newlyAuthoredPullRequestIDs.contains(item.id)
        case .workflowFailures:
            return false
        }
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct PullRequestRow: View {
    let item: PullRequestItem
    let ciStatus: PullRequestCIStatus
    let debugSummary: String?
    let isHighlighted: Bool
    let isNew: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ciStatus.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ciStatus.indicatorColor)
                .frame(width: 14, alignment: .center)

            Text(item.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            RepoPill(text: item.repositoryName)

            if item.isDraft {
                Text("Draft")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if isNew {
                NewPill()
            }

            Text("#\(item.number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(PullRequestDateFormatter.relativeString(for: item.updatedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: InboxMenuView.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundStyle)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .help(helpText)
    }

    private var helpText: String {
        if let debugSummary, !debugSummary.isEmpty {
            return "\(ciStatus.accessibilityLabel)\n\(debugSummary)"
        }

        return ciStatus.accessibilityLabel
    }

    private var backgroundStyle: some ShapeStyle {
        isHighlighted ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.background.opacity(0.35))
    }
}

private struct WorkflowFailureRow: View {
    let item: WorkflowFailureItem
    let isHighlighted: Bool
    let isNew: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .padding(.horizontal, 3)

            Text(item.workflowName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            RepoPill(text: item.repositoryName, width: InboxMenuView.workflowRepoColumnWidth)

            if let branchName = item.branchName, !branchName.isEmpty {
                Text(branchName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: InboxMenuView.workflowBranchColumnWidth, alignment: .leading)
            }

            if isNew {
                NewPill()
            }

            Text(PullRequestDateFormatter.relativeString(for: item.updatedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: InboxMenuView.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundStyle)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private var backgroundStyle: some ShapeStyle {
        isHighlighted ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.background.opacity(0.35))
    }
}

private struct RepoPill: View {
    let text: String
    var width: CGFloat?

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.8))
            .clipShape(Capsule())
    }
}

private struct NewPill: View {
    var body: some View {
        Text("New")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(Capsule())
    }
}

struct MenuWindowContentFitter: NSViewRepresentable {
    let fitKey: String

    func makeNSView(context: Context) -> MenuWindowContentFittingView {
        let view = MenuWindowContentFittingView()
        view.fitKey = fitKey
        return view
    }

    func updateNSView(_ nsView: MenuWindowContentFittingView, context: Context) {
        nsView.fitKey = fitKey
    }
}

final class MenuWindowContentFittingView: NSView {
    var fitKey = "" {
        didSet {
            if oldValue != fitKey {
                scheduleWindowFit()
            }
        }
    }

    private var hasScheduledWindowFit = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleWindowFit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)

        guard abs(oldSize.width - newSize.width) > 0.5
            || abs(oldSize.height - newSize.height) > 0.5
        else {
            return
        }

        scheduleWindowFit()
    }

    private func scheduleWindowFit() {
        guard !hasScheduledWindowFit else {
            return
        }

        hasScheduledWindowFit = true
        DispatchQueue.main.async { [weak self] in
            self?.fitWindowToTargetSize()
        }
    }

    private func fitWindowToTargetSize() {
        hasScheduledWindowFit = false

        guard let window,
              let targetContentSize = measuredTargetContentSize()
        else {
            return
        }

        let targetFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize)).size
        let currentFrame = window.frame
        guard abs(currentFrame.width - targetFrameSize.width) > 0.5
            || abs(currentFrame.height - targetFrameSize.height) > 0.5
        else {
            return
        }

        window.contentMinSize = NSSize(width: 1, height: 1)
        window.minSize = NSSize(width: 1, height: 1)

        let targetFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetFrameSize.height,
            width: targetFrameSize.width,
            height: targetFrameSize.height
        )
        window.setFrame(targetFrame, display: true)
    }

    private func measuredTargetContentSize() -> NSSize? {
        layoutSubtreeIfNeeded()

        let measuredSize = bounds.size
        guard measuredSize.width > 0, measuredSize.height > 0 else {
            return nil
        }

        return NSSize(width: ceil(measuredSize.width), height: ceil(measuredSize.height))
    }
}

private struct KeyboardEventBridge: NSViewRepresentable {
    let onLeftArrow: () -> Void
    let onRightArrow: () -> Void
    let onUpArrow: () -> Void
    let onDownArrow: () -> Void
    let onReturn: () -> Void
    let onRefresh: () -> Void
    let onSectionOne: () -> Void
    let onSectionTwo: () -> Void
    let onSectionThree: () -> Void

    func makeNSView(context: Context) -> KeyHandlingView {
        let view = KeyHandlingView()
        view.onLeftArrow = onLeftArrow
        view.onRightArrow = onRightArrow
        view.onUpArrow = onUpArrow
        view.onDownArrow = onDownArrow
        view.onReturn = onReturn
        view.onRefresh = onRefresh
        view.onSectionOne = onSectionOne
        view.onSectionTwo = onSectionTwo
        view.onSectionThree = onSectionThree
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyHandlingView, context: Context) {
        nsView.onLeftArrow = onLeftArrow
        nsView.onRightArrow = onRightArrow
        nsView.onUpArrow = onUpArrow
        nsView.onDownArrow = onDownArrow
        nsView.onReturn = onReturn
        nsView.onRefresh = onRefresh
        nsView.onSectionOne = onSectionOne
        nsView.onSectionTwo = onSectionTwo
        nsView.onSectionThree = onSectionThree
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class KeyHandlingView: NSView {
    var onLeftArrow: (() -> Void)?
    var onRightArrow: (() -> Void)?
    var onUpArrow: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onReturn: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onSectionOne: (() -> Void)?
    var onSectionTwo: (() -> Void)?
    var onSectionThree: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if let characters = event.charactersIgnoringModifiers?.lowercased() {
            switch characters {
            case "j":
                onDownArrow?()
                return
            case "k":
                onUpArrow?()
                return
            case "r":
                onRefresh?()
                return
            case "1":
                onSectionOne?()
                return
            case "2":
                onSectionTwo?()
                return
            case "3":
                onSectionThree?()
                return
            default:
                break
            }
        }

        switch event.keyCode {
        case 123:
            onLeftArrow?()
        case 124:
            onRightArrow?()
        case 125:
            onDownArrow?()
        case 126:
            onUpArrow?()
        case 36, 76:
            onReturn?()
        default:
            super.keyDown(with: event)
        }
    }
}
