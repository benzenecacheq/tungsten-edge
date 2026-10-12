import Foundation

/// "Show only windows on this desktop": which live-zone cards a bar draws.
///
/// Like `StripDisplayFilter`, it runs **only after the shared order layer**: the order layer keeps
/// seeing every window, so cards on other desktops keep their places and come back there.
///
/// - A window card shows when its window is on a desktop showing right now (unknown = shown).
/// - Every other card (app-level fallback, kept placeholder) shows.
/// - A kept app whose windows are all on other desktops keeps its icon: a placeholder takes the
///   place of its first window card, drawn without a running dot (`appsRunningElsewhere`).
enum CurrentDesktopFilter {
    enum Card: Equatable {
        case window(id: String, bundleID: String?, isOnCurrentDesktop: Bool)
        case other(id: String)
    }

    enum Rendered: Equatable {
        case card(id: String)
        case keptPlaceholder(bundleID: String)
    }

    static func filter(_ cards: [Card], keptBundleIDs: Set<String>) -> [Rendered] {
        let shownBundleIDs = Set(cards.compactMap { card -> String? in
            guard case let .window(_, bundleID, true) = card else { return nil }
            return bundleID
        })
        var placed = Set<String>()
        var result: [Rendered] = []
        for card in cards {
            switch card {
            case let .other(id):
                result.append(.card(id: id))
            case let .window(id, _, true):
                result.append(.card(id: id))
            case let .window(_, bundleID?, false):
                if keptBundleIDs.contains(bundleID), !shownBundleIDs.contains(bundleID),
                   placed.insert(bundleID).inserted {
                    result.append(.keptPlaceholder(bundleID: bundleID))
                }
            case .window(_, nil, false):
                continue
            }
        }
        return result
    }

    /// Apps with windows, none of them on a desktop showing right now. Their pinned icons go
    /// without a running dot.
    static func appsRunningElsewhere(windows: [(bundleID: String, isOnCurrentDesktop: Bool)]) -> Set<String> {
        var withWindows = Set<String>()
        var here = Set<String>()
        for window in windows {
            withWindows.insert(window.bundleID)
            if window.isOnCurrentDesktop { here.insert(window.bundleID) }
        }
        return withWindows.subtracting(here)
    }
}
