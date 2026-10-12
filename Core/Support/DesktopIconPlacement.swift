import CoreGraphics

/// "Keep Desktop Icons Clear of the Taskbar": which desktop icons sit under the bar and where
/// each one goes instead.
///
/// Every rectangle and point is in Finder's desktop coordinates: points, origin at the top-left
/// of the main display, y growing down. An icon's `desktop position` is the centre of its image;
/// its name sits below it.
///
/// The bar's whole strip of the screen is kept clear (`reserved`), not just where the bar is
/// now: a column grows and shrinks as windows come and go, and icons just past its end would be
/// covered again and again.
///
/// Free spots follow Finder's own fill order (columns from the right, each from the top), on a
/// grid aligned to the screen's right edge, skipping any spot the bar covers or another icon
/// already holds. Icons are moved in that order too, so the result looks like Finder put them
/// there, just left of (or above) the bar.
enum DesktopIconPlacement {
    struct Icon: Equatable {
        let name: String
        let center: CGPoint
    }

    struct Move: Equatable {
        let name: String
        let center: CGPoint
    }

    struct Grid: Equatable {
        /// Distance between columns and between rows of icons.
        let columnStep: CGFloat
        let rowStep: CGFloat
        let iconSize: CGFloat

        /// Finder's default spacing for an icon size: 64pt icons sit 124pt apart across and 112pt
        /// down (measured on macOS 27 with the default grid spacing and 12pt text).
        init(iconSize: CGFloat) {
            self.iconSize = iconSize
            columnStep = iconSize + 60
            rowStep = iconSize + 48
        }

        /// Room an icon takes: its image plus the name below it.
        func footprint(at center: CGPoint) -> CGRect {
            CGRect(x: center.x - columnStep / 2, y: center.y - iconSize / 2,
                   width: columnStep, height: rowStep - 8)
        }
    }

    /// Moves for every icon whose footprint overlaps `bar`, inside `screen` (the display's
    /// usable area: below the menu bar). Icons that find no free spot stay where they are.
    static func moves(icons: [Icon], bar: CGRect, screen: CGRect, grid: Grid) -> [Move] {
        guard !bar.isEmpty, !screen.isEmpty else { return [] }
        let bar = reserved(bar: bar, screen: screen)
        let covered = icons.filter { grid.footprint(at: $0.center).intersects(bar) && screen.contains($0.center) }
        guard !covered.isEmpty else { return [] }
        let coveredNames = Set(covered.map(\.name))
        var taken = icons.filter { !coveredNames.contains($0.name) }.map(\.center)

        // Finder's order: rightmost column first, top to bottom within a column.
        let ordered = covered.sorted {
            $0.center.x != $1.center.x ? $0.center.x > $1.center.x : $0.center.y < $1.center.y
        }
        var result: [Move] = []
        var spots = freeSpots(bar: bar, screen: screen, grid: grid).makeIterator()
        for icon in ordered {
            var placed: CGPoint?
            while let spot = spots.next() {
                if taken.allSatisfy({ !isClose($0, spot, grid: grid) }) {
                    placed = spot
                    break
                }
            }
            guard let placed else { break }
            taken.append(placed)
            result.append(Move(name: icon.name, center: placed))
        }
        return result
    }

    /// The bar stretched along its length to the screen's edges: a full-height strip for a
    /// column, a full-width one for a bottom bar.
    static func reserved(bar: CGRect, screen: CGRect) -> CGRect {
        bar.height > bar.width
            ? CGRect(x: bar.minX, y: screen.minY, width: bar.width, height: screen.height)
            : CGRect(x: screen.minX, y: bar.minY, width: screen.width, height: bar.height)
    }

    /// Grid spots inside `screen` whose icon would be clear of `bar`, in Finder's fill order.
    static func freeSpots(bar: CGRect, screen: CGRect, grid: Grid) -> [CGPoint] {
        let bar = reserved(bar: bar, screen: screen)
        let firstX = screen.maxX - grid.columnStep / 2 - 10
        let firstY = screen.minY + grid.iconSize / 2 + 8
        var spots: [CGPoint] = []
        var x = firstX
        while x - grid.columnStep / 2 >= screen.minX {
            var y = firstY
            while y + grid.rowStep - grid.iconSize / 2 <= screen.maxY {
                let spot = CGPoint(x: x, y: y)
                if !grid.footprint(at: spot).intersects(bar) { spots.append(spot) }
                y += grid.rowStep
            }
            x -= grid.columnStep
        }
        return spots
    }

    /// Two icons this close would overlap.
    private static func isClose(_ a: CGPoint, _ b: CGPoint, grid: Grid) -> Bool {
        abs(a.x - b.x) < grid.columnStep * 0.9 && abs(a.y - b.y) < grid.rowStep * 0.9
    }
}
