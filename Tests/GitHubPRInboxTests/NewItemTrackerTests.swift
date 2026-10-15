import Foundation
import Testing
@testable import GitHubPRInbox

struct NewItemTrackerTests {
    @Test
    func initialSnapshotEstablishesBaselineWithoutNewIDs() {
        var tracker = NewItemTracker()

        tracker.detectArrivals(currentIDs: ["one", "two"], previousIDs: [])

        #expect(tracker.hasEstablishedBaseline)
        #expect(tracker.newIDs.isEmpty)
    }

    @Test
    func laterSnapshotMarksOnlyArrivals() {
        var tracker = NewItemTracker()
        tracker.detectArrivals(currentIDs: ["one", "two"], previousIDs: [])

        tracker.detectArrivals(currentIDs: ["one", "two", "three"], previousIDs: ["one", "two"])

        #expect(tracker.newIDs == ["three"])
    }

    @Test
    func resetSnapshotPreventsNextLoadedSnapshotFromMarkingEverythingNew() {
        var tracker = NewItemTracker()
        tracker.detectArrivals(currentIDs: ["one", "two"], previousIDs: [])
        tracker.detectArrivals(currentIDs: ["one", "two", "three"], previousIDs: ["one", "two"])

        tracker.reset()
        tracker.detectArrivals(currentIDs: ["one", "two", "three"], previousIDs: [])

        #expect(tracker.hasEstablishedBaseline)
        #expect(tracker.newIDs.isEmpty)
    }

    @Test
    func retainsUnseenArrivalsAcrossRefreshesAndDropsRemovedItems() {
        var tracker = NewItemTracker()
        tracker.detectArrivals(currentIDs: ["one"], previousIDs: [])
        tracker.detectArrivals(currentIDs: ["one", "two"], previousIDs: ["one"])
        tracker.detectArrivals(currentIDs: ["one", "two", "three"], previousIDs: ["one", "two"])
        #expect(tracker.newIDs == ["two", "three"])

        tracker.acknowledge(ids: ["two"])
        #expect(tracker.newIDs == ["three"])
        tracker.detectArrivals(currentIDs: ["one", "two"], previousIDs: ["one", "two", "three"])
        #expect(tracker.newIDs.isEmpty)
    }
    @Test
    func onlyAcknowledgesRowsThatEnterTheViewportAfterExpanding() {
        let frames = Dictionary(uniqueKeysWithValues: (0..<20).map { index in
            ("row-\(index)", CGRect(x: 0, y: index * 32, width: 600, height: 28))
        })
        let viewport = CGRect(x: 0, y: 0, width: 656, height: 320)
        let initiallyVisible = InboxRowVisibility.visibleIDs(frames: frames, viewport: viewport)
        #expect(initiallyVisible == Set((0..<10).map { "row-\($0)" }))
        let scrolled = frames.mapValues { $0.offsetBy(dx: 0, dy: -320) }
        #expect(InboxRowVisibility.visibleIDs(frames: scrolled, viewport: viewport) == Set((10..<20).map { "row-\($0)" }))
        #expect(InboxRowVisibility.visibleIDs(frames: frames, viewport: .zero).isEmpty)
    }

}
