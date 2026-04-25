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
}
