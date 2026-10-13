import XCTest

@MainActor
final class NamedDrawerStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "test-named-drawers-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testAppsFiledBeforeNamedDrawersStayInTheFirstDrawer() {
        let defaults = makeDefaults()
        defaults.set(["a", "b"], forKey: "drawerBundleIDs")
        let store = DrawerStore(defaults: defaults)
        XCTAssertEqual(store.drawers.map(\.id), [DrawerStore.defaultDrawerID])
        XCTAssertEqual(store.members(["a", "b"], inDrawer: DrawerStore.defaultDrawerID), ["a", "b"])
        XCTAssertEqual(store.displayName(of: DrawerStore.defaultDrawerID), "Drawer")
    }

    func testAddFilesIntoTheActiveDrawerAndPersists() {
        let defaults = makeDefaults()
        let store = DrawerStore(defaults: defaults)
        let work = store.createDrawer(named: "  Work ")
        store.add("a")
        store.setActiveDrawer(work)
        store.add("b")

        let reloaded = DrawerStore(defaults: defaults)
        XCTAssertEqual(reloaded.bundleIDs, ["a", "b"])
        XCTAssertEqual(reloaded.drawers.map(\.name), ["", "Work"])
        XCTAssertEqual(reloaded.drawerID(of: "a"), DrawerStore.defaultDrawerID)
        XCTAssertEqual(reloaded.drawerID(of: "b"), work)
        XCTAssertEqual(reloaded.activeDrawerID, DrawerStore.defaultDrawerID, "the active drawer is not persisted")
    }

    func testRemoveForgetsTheDrawer() {
        let store = DrawerStore(defaults: makeDefaults())
        let work = store.createDrawer(named: "Work")
        store.add("b", to: work)
        store.remove("b")
        XCTAssertFalse(store.contains("b"))
        store.add("b")
        XCTAssertEqual(store.drawerID(of: "b"), DrawerStore.defaultDrawerID)
    }

    func testDeletingADrawerMovesItsAppsToTheFirstDrawer() {
        let store = DrawerStore(defaults: makeDefaults())
        let work = store.createDrawer(named: "Work")
        store.add("b", to: work)
        store.setActiveDrawer(work)
        store.deleteDrawer(work)
        XCTAssertEqual(store.drawers.map(\.id), [DrawerStore.defaultDrawerID])
        XCTAssertTrue(store.contains("b"), "deleting a drawer never puts its apps back on the bar")
        XCTAssertEqual(store.drawerID(of: "b"), DrawerStore.defaultDrawerID)
        XCTAssertEqual(store.activeDrawerID, DrawerStore.defaultDrawerID)

        store.deleteDrawer(DrawerStore.defaultDrawerID)
        XCTAssertEqual(store.drawers.count, 1, "the first drawer cannot be deleted")
    }

    func testRenameAndUnknownDrawerFallsBackToTheFirst() {
        let store = DrawerStore(defaults: makeDefaults())
        store.renameDrawer(DrawerStore.defaultDrawerID, to: "Misc")
        XCTAssertEqual(store.displayName(of: DrawerStore.defaultDrawerID), "Misc")
        store.add("a", to: "gone")
        XCTAssertEqual(store.drawerID(of: "a"), DrawerStore.defaultDrawerID)
        store.setActiveDrawer("gone")
        XCTAssertEqual(store.activeDrawerID, DrawerStore.defaultDrawerID)
    }

    func testMoveDrawerReordersAndPersists() {
        let defaults = makeDefaults()
        let store = DrawerStore(defaults: defaults)
        let work = store.createDrawer(named: "Work")
        let games = store.createDrawer(named: "Games")
        store.moveDrawer(DrawerStore.defaultDrawerID, to: 99)
        XCTAssertEqual(store.drawers.map(\.id), [work, games, DrawerStore.defaultDrawerID])
        store.moveDrawer(games, to: 0)
        XCTAssertEqual(DrawerStore(defaults: defaults).drawers.map(\.id),
                       [games, work, DrawerStore.defaultDrawerID], "order survives a relaunch")
    }
}
