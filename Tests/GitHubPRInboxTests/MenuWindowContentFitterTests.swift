import AppKit
import SwiftUI
import Testing
@testable import GitHubPRInbox

@MainActor
struct MenuWindowContentFitterTests {
    @Test
    func contractsWindowWhenHostedContentShrinks() async {
        let model = MenuFitterFixtureModel(rowCount: 20)
        let hostingController = NSHostingController(rootView: MenuFitterFixture(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 240, height: 800))
        window.orderFront(nil)
        defer { window.close() }

        await settleWindowLayout()
        let expandedHeight = window.frame.height

        model.rowCount = 3
        await settleWindowLayout()
        let contractedHeight = window.frame.height

        #expect(expandedHeight > contractedHeight + 300)
        #expect(contractedHeight < 220)
    }

    @Test
    func ignoresStaleWindowContentFittingSize() async {
        let contentView = StaleFittingContentView()
        let fittingView = MenuWindowContentFittingView()
        fittingView.frame = NSRect(x: 0, y: 0, width: 240, height: 120)

        contentView.addSubview(fittingView)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 800), styleMask: [], backing: .buffered, defer: false)
        window.contentView = contentView
        window.orderFront(nil)
        defer { window.close() }

        fittingView.fitKey = "fit"
        await settleWindowLayout()

        #expect(window.frame.height < 220)
    }
}

@MainActor
private final class MenuFitterFixtureModel: ObservableObject {
    @Published var rowCount: Int

    init(rowCount: Int) {
        self.rowCount = rowCount
    }
}

private struct MenuFitterFixture: View {
    @ObservedObject var model: MenuFitterFixtureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<model.rowCount, id: \.self) { index in
                Text("Row \(index)")
                    .frame(height: 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(width: 240, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(MenuWindowContentFitter(fitKey: "\(model.rowCount)"))
    }
}

private final class StaleFittingContentView: NSView {
    override var fittingSize: NSSize {
        frame.size
    }
}

@MainActor
private func settleWindowLayout() async {
    for _ in 0..<6 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(30))
    }
}
