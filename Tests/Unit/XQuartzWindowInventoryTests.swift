import CoreGraphics
import XCTest

final class XQuartzWindowInventoryTests: XCTestCase {
    private func cg(
        _ id: CGWindowID,
        _ title: String = "",
        onScreen: Bool = true,
        space: Bool = true,
        current: Bool = true,
        appKit: Bool = false,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    ) -> XQuartzCGWindow {
        XQuartzCGWindow(
            id: id,
            title: title,
            bounds: bounds,
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

    /// With titles, an untitled window (a pop-up) is left out rather than spoiling the pairing.
    func testTitledCountMismatchLeavesOutUntitledWindows() {
        let windows = XQuartzWindowInventory.windows(
            cgWindows: [cg(1, "user@a"), cg(2), cg(3, "user@b")],
            menuTitles: ["user@a", "user@b"]
        )
        XCTAssertEqual(windows?.map(\.cgWindowID), [1, 3])
        XCTAssertEqual(windows?.map(\.menuIndex), [0, 1])
    }

    /// Without titles, known pop-ups are left out before pairing by ID order.
    func testUntitledPairingSkipsKnownPopups() {
        let windows = XQuartzWindowInventory.windows(
            cgWindows: [cg(10), cg(11), cg(12)],
            menuTitles: ["user@pimail", "user@ghost"],
            popupIDs: [11]
        )
        XCTAssertEqual(windows?.map(\.cgWindowID), [10, 12])
        XCTAssertEqual(windows?.map(\.title), ["user@pimail", "user@ghost"])
    }

    /// xterm's Ctrl-click menu, as seen 2026-10-27: X says 225x417 inside a 2-pixel border at
    /// +1519+600; the window server has 229x421 at (1519, 630). The xterm (with its title bar)
    /// does not match.
    func testPopupClaimsTheWindowOfItsOuterSize() {
        let xterm = cg(27182, bounds: CGRect(x: 742, y: 418, width: 1081, height: 1432))
        let menu = cg(27184, bounds: CGRect(x: 1519, y: 630, width: 229, height: 421))
        let popup = XQuartzPopupFinder.Popup(frame: CGRect(x: 1519, y: 600, width: 225, height: 417), borderWidth: 2)
        XCTAssertEqual(XQuartzWindowInventory.popupIDs(xWindows: [xterm, menu], popups: [popup]), [27184])
    }

    func testPopupsEachClaimOneWindowNearestAcross() {
        let near = cg(2, bounds: CGRect(x: 500, y: 0, width: 50, height: 50))
        let far = cg(1, bounds: CGRect(x: 0, y: 0, width: 50, height: 50))
        let popup = XQuartzPopupFinder.Popup(frame: CGRect(x: 490, y: 0, width: 50, height: 50), borderWidth: 0)
        XCTAssertEqual(XQuartzWindowInventory.popupIDs(xWindows: [far, near], popups: [popup]), [2])
        XCTAssertEqual(XQuartzWindowInventory.popupIDs(xWindows: [far, near], popups: [popup, popup]), [1, 2])
    }

    /// From the X tree of 2026-10-27: quartz-wm's frame (unnamed, holding the xterm) is not a
    /// candidate; the xterm's Ctrl-click menu (unnamed, no children) is.
    func testTreeYieldsUnnamedChildlessTopLevels() {
        let tree = """

        xwininfo: Window id: 0xc0 (the root window) (has no name)

          Root window id: 0xc0 (the root window) (has no name)
          Parent window id: 0x0 (none)
             3 children:
             0x40003a (has no name): ()  1081x1432+742+388  +742+388
                2 children:
                0x40003b (has no name): ()  56x16+8+2  +750+390
                0x180000c "benzene@pimail": ("xterm" "XTerm")  1081x1410+0+22  +742+410
                   1 child:
                   0x1800018 (has no name): ()  1081x1410+0+0  +742+410
             0x1800035 (has no name): ()  225x417+1519+600  +1519+600
             0x400001 (has no name): ()  10x10+-5+-20  +-5+-20

        """
        let candidates = XQuartzPopupFinder.popupCandidates(fromTree: tree)
        XCTAssertEqual(candidates.map(\.id), ["0x1800035", "0x400001"])
        XCTAssertEqual(candidates.map(\.frame), [CGRect(x: 1519, y: 600, width: 225, height: 417),
                                                 CGRect(x: -5, y: -20, width: 10, height: 10)])
    }

    func testWindowInfoGivesBorderOnlyForOverrideRedirect() {
        let popup = """
          Border width: 2
          Map State: IsUnMapped
          Override Redirect State: yes
        """
        XCTAssertEqual(XQuartzPopupFinder.overrideRedirectBorder(fromWindowInfo: popup), 2)
        XCTAssertNil(XQuartzPopupFinder.overrideRedirectBorder(
            fromWindowInfo: popup.replacingOccurrences(of: "State: yes", with: "State: no")))
    }

    func testDisplayForEachServer() {
        XCTAssertEqual(XQuartzPopupFinder.display(forBundleIdentifier: "org.xquartz.X11"), ":0")
        XCTAssertEqual(XQuartzPopupFinder.display(forBundleIdentifier: "org.xquartz.X11.display3"), ":3")
        XCTAssertNil(XQuartzPopupFinder.display(forBundleIdentifier: "com.example"))
    }
}
