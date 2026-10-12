import XCTest

final class CurrentDesktopFilterTests: XCTestCase {
    private func window(_ id: String, _ bundleID: String?, here: Bool) -> CurrentDesktopFilter.Card {
        .window(id: id, bundleID: bundleID, isOnCurrentDesktop: here)
    }

    func testWindowsOnOtherDesktopsAreDroppedAndOtherCardsKept() {
        let result = CurrentDesktopFilter.filter([
            window("w1", "a", here: true),
            window("w2", "a", here: false),
            .other(id: "app-b"),
            window("w3", "c", here: false),
            window("w4", nil, here: false)
        ], keptBundleIDs: [])
        XCTAssertEqual(result, [.card(id: "w1"), .card(id: "app-b")])
    }

    /// A kept app with every window elsewhere keeps one icon, where its first window card was.
    func testKeptAppWithAllWindowsElsewhereGetsOnePlaceholderInPlace() {
        let result = CurrentDesktopFilter.filter([
            window("w1", "x", here: true),
            window("w2", "kept", here: false),
            window("w3", "kept", here: false),
            window("w4", "y", here: true)
        ], keptBundleIDs: ["kept"])
        XCTAssertEqual(result, [.card(id: "w1"), .keptPlaceholder(bundleID: "kept"), .card(id: "w4")])
    }

    func testKeptAppWithAWindowHereShowsOnlyThatWindow() {
        let result = CurrentDesktopFilter.filter([
            window("w1", "kept", here: false),
            window("w2", "kept", here: true)
        ], keptBundleIDs: ["kept"])
        XCTAssertEqual(result, [.card(id: "w2")])
    }

    func testAppsRunningElsewhereHaveWindowsButNoneHere() {
        let result = CurrentDesktopFilter.appsRunningElsewhere(windows: [
            ("a", false), ("a", true),
            ("b", false), ("b", false),
            ("c", true)
        ])
        XCTAssertEqual(result, ["b"])
    }
}
