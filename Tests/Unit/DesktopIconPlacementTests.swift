import CoreGraphics
import XCTest

final class DesktopIconPlacementTests: XCTestCase {
    /// A 4K display with a 300pt bar down the right edge, measured from the user's desktop.
    private let screen = CGRect(x: 0, y: 25, width: 3840, height: 2135)
    private let bar = CGRect(x: 3540, y: 600, width: 300, height: 900)
    private let grid = DesktopIconPlacement.Grid(iconSize: 64)

    private func icon(_ name: String, _ x: CGFloat, _ y: CGFloat) -> DesktopIconPlacement.Icon {
        .init(name: name, center: CGPoint(x: x, y: y))
    }

    func testIconsClearOfTheBarStay() {
        let icons = [icon("a", 178, 70), icon("b", 3400, 900)]
        XCTAssertEqual(DesktopIconPlacement.moves(icons: icons, bar: bar, screen: screen, grid: grid), [])
    }

    /// The bar's whole column is kept clear, above and below it too: it grows as windows open.
    /// Covered icons fill the next column left, top-down, in the order Finder had them.
    func testIconsInTheBarsColumnMoveToTheNextColumnInFinderOrder() {
        let icons = [icon("low", 3768, 730), icon("high", 3768, 598), icon("above", 3768, 70)]
        let moves = DesktopIconPlacement.moves(icons: icons, bar: bar, screen: screen, grid: grid)
        XCTAssertEqual(moves.map(\.name), ["above", "high", "low"])
        let column = DesktopIconPlacement.reserved(bar: bar, screen: screen)
        for move in moves {
            XCTAssertFalse(grid.footprint(at: move.center).intersects(column), "\(move.name) still in the bar's column")
        }
        // The 300pt bar covers the two right columns and touches the third; the fourth is free.
        let spots = DesktopIconPlacement.freeSpots(bar: bar, screen: screen, grid: grid)
        XCTAssertEqual(moves.map(\.center), Array(spots.prefix(3)))
        XCTAssertEqual(spots[0], CGPoint(x: 3768 - grid.columnStep * 3, y: 25 + 32 + 8))
        XCTAssertEqual(spots[1].y - spots[0].y, grid.rowStep)
    }

    func testMovesSkipSpotsOtherIconsHold() {
        // The bar runs the full height, so every spot in the right column is covered.
        let fullBar = CGRect(x: 3600, y: 25, width: 240, height: 2135)
        let spots = DesktopIconPlacement.freeSpots(bar: fullBar, screen: screen, grid: grid)
        let held = icon("held", spots[0].x, spots[0].y)
        let moves = DesktopIconPlacement.moves(icons: [held, icon("x", 3768, 70)], bar: fullBar,
                                               screen: screen, grid: grid)
        XCTAssertEqual(moves, [.init(name: "x", center: spots[1])])
    }

    func testFreeSpotsAvoidTheBarAndStayOnScreen() {
        let spots = DesktopIconPlacement.freeSpots(bar: bar, screen: screen, grid: grid)
        XCTAssertFalse(spots.isEmpty)
        for spot in spots {
            XCTAssertFalse(grid.footprint(at: spot).intersects(bar))
            XCTAssertTrue(screen.contains(grid.footprint(at: spot)))
        }
    }
}
