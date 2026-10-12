import CoreGraphics
import XCTest

final class XQuartzWindowInventoryTests: XCTestCase {
    private func cg(
        _ id: CGWindowID,
        _ title: String = "",
        onScreen: Bool = true,
        space: Bool = true,
        current: Bool = true,
        appKit: Bool = false
    ) -> XQuartzCGWindow {
        XQuartzCGWindow(
            id: id,
            title: title,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            isOnScreen: onScreen,
            hasSpace: space,
            isInCurrentSpace: current,
            isAppKitWindow: appKit
        )
    }

    func testWindowTitlesAreTheItemsAfterTheLastSeparator() {
        let items = ["Close", "Minimize", "", "Bring All to Front", "", "user@a", "user@b", "user@a"]
        XCTAssertEqual(XQuartzWindowInventory.windowTitles(fromWindowMenuItems: items), ["user@a", "user@b", "user@a"])
        XCTAssertEqual(XQuartzWindowInventory.windowTitles(fromWindowMenuItems: ["Bring All to Front", ""]), [])
        XCTAssertEqual(XQuartzWindowInventory.windowTitles(fromWindowMenuItems: ["Close"]), [])
    }

    /// Without Screen Recording the window server gives no titles: X windows pair with the menu by
    /// ID order, skipping XQuartz's closed panels (no Space) and open panels (in AX).
    func testUntitledWindowsPairWithMenuItemsByIDOrder() {
        let windows = XQuartzWindowInventory.windows(
            cgWindows: [cg(40), cg(12), cg(5, space: false), cg(30, appKit: true), cg(20)],
            menuTitles: ["user@a", "user@a", "user@b"]
        )
        XCTAssertEqual(windows?.map(\.cgWindowID), [12, 20, 40])
        XCTAssertEqual(windows?.map(\.title), ["user@a", "user@a", "user@b"])
        XCTAssertEqual(windows?.map(\.menuIndex), [0, 1, 2])
    }

    func testUntitledCountMismatchIsUnknownRatherThanMispaired() {
        XCTAssertNil(XQuartzWindowInventory.windows(cgWindows: [cg(1), cg(2)], menuTitles: ["user@a"]))
    }

    /// With titles, a count mismatch still pairs each title's windows with that title's items in order.
    func testTitledCountMismatchPairsByTitleOccurrence() {
        let windows = XQuartzWindowInventory.windows(
            cgWindows: [cg(9, "user@b"), cg(3, "user@a"), cg(7, "user@a"), cg(8, "user@new")],
            menuTitles: ["user@a", "user@b", "user@a"]
        )
        XCTAssertEqual(windows?.map(\.cgWindowID), [3, 7, 9])
        XCTAssertEqual(windows?.map(\.menuIndex), [0, 2, 1])
    }

    func testFrontAndMinimizedStates() {
        let windows = XQuartzWindowInventory.windows(
            cgWindows: [
                cg(30, appKit: true),
                cg(2, onScreen: false, current: true),
                cg(3, onScreen: true),
                cg(1, onScreen: true),
                cg(4, onScreen: false, current: false)
            ],
            menuTitles: ["a", "b", "c", "d"]
        )
        XCTAssertEqual(windows?.map(\.isFront), [false, false, true, false])
        // Off screen in a showing Space = minimized; off screen elsewhere = another Space.
        XCTAssertEqual(windows?.map(\.isMinimized), [false, true, false, false])
    }
}
