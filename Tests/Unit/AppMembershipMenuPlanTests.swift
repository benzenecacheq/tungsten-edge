import XCTest
@testable import macos_dock_cc_v2

final class AppMembershipMenuPlanTests: XCTestCase {

    func testStripPlainAppShowsKeepAndUncheckedMessaging() {
        let items = AppMembershipMenuPlan.items(surface: .strip, isKept: false, isMessaging: false)
        XCTAssertEqual(items, [.keep(isChecked: false), .messaging(isChecked: false)])
    }

    func testStripMessagingAppShowsKeepAndCheckedMessaging() {
        let items = AppMembershipMenuPlan.items(surface: .strip, isKept: true, isMessaging: true)
        XCTAssertEqual(items, [.keep(isChecked: true), .messaging(isChecked: true)])
    }

    func testDrawerPlainAppShowsOnlyKeep() {
        let items = AppMembershipMenuPlan.items(surface: .drawer, isKept: false, isMessaging: false)
        XCTAssertEqual(items, [.keep(isChecked: false)])
    }

    func testDrawerMessagingAppShowsKeepAndCheckedMessaging() {
        let items = AppMembershipMenuPlan.items(surface: .drawer, isKept: true, isMessaging: true)
        XCTAssertEqual(items, [.keep(isChecked: true), .messaging(isChecked: true)])
    }

    func testKeepCheckStateReflectsKept() {
        let unchecked = AppMembershipMenuPlan.items(surface: .strip, isKept: false, isMessaging: false)
        XCTAssertEqual(unchecked.first, .keep(isChecked: false))
        let checked = AppMembershipMenuPlan.items(surface: .strip, isKept: true, isMessaging: false)
        XCTAssertEqual(checked.first, .keep(isChecked: true))
    }

    func testKeepAlwaysPrecedesMessagingCommand() {
        let items = AppMembershipMenuPlan.items(surface: .strip, isKept: false, isMessaging: true)
        XCTAssertEqual(items.first, .keep(isChecked: false))
        XCTAssertEqual(items.last, .messaging(isChecked: true))
    }

    func testMessagingCheckStateReflectsMembership() {
        XCTAssertEqual(
            AppMembershipMenuPlan.items(surface: .strip, isKept: false, isMessaging: false).last,
            .messaging(isChecked: false)
        )
        XCTAssertEqual(
            AppMembershipMenuPlan.items(surface: .strip, isKept: false, isMessaging: true).last,
            .messaging(isChecked: true)
        )
    }
}
