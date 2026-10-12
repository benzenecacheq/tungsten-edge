import AppKit
import OSLog

/// "Keep Desktop Icons Clear of the Taskbar": moves desktop icons out from under the bar.
///
/// macOS has no way to reserve part of the screen, so Finder puts new icons down the right edge,
/// under a right-edge bar. This asks Finder (AppleScript, the same Automation permission the
/// Trash uses) where its icons are and moves the covered ones to free spots beside the bar
/// (`DesktopIconPlacement`). It checks shortly after anything in ~/Desktop changes, and every
/// few seconds in case the bar moved or grew.
@MainActor
final class DesktopIconMover {
    private static let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "DesktopIcons")
    private static let pollInterval: TimeInterval = 10
    /// Finder places a new file's icon a moment after the file appears; look twice.
    private static let changeDelays: [TimeInterval] = [1, 3]

    /// The bar's frame in AppKit screen coordinates, nil while it is not showing.
    private let barFrame: () -> CGRect?
    /// Serial: one Finder conversation at a time. NSAppleScript is not safe to run concurrently.
    private let queue = DispatchQueue(label: "com.tungsten.edge.desktop-icons", qos: .utility)
    private var enabled = false
    private var pollTimer: Timer?
    private var desktopWatch: DispatchSourceFileSystemObject?
    private var lastError: Int?

    init(barFrame: @escaping () -> CGRect?) {
        self.barFrame = barFrame
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if value {
            startWatchingDesktop()
            pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.check() }
            }
            pollTimer?.tolerance = 2
            check()
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
            desktopWatch?.cancel()
            desktopWatch = nil
        }
    }

    private func startWatchingDesktop() {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return }
        let fd = open(desktop.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for delay in Self.changeDelays {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        MainActor.assumeIsolated { self?.check() }
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        desktopWatch = source
    }

    /// Reads the bar and its screen here, then talks to Finder off the main thread.
    private func check() {
        guard enabled, let bar = barFrame(), !bar.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(bar) }),
              let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        // Finder's desktop coordinates: origin at the main display's top-left, y down.
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        let barRect = flipped(bar)
        let screenRect = flipped(screen.visibleFrame)
        queue.async { [weak self] in
            let outcome = Self.clearIcons(bar: barRect, screen: screenRect)
            DispatchQueue.main.async { self?.report(outcome) }
        }
    }

    private enum Outcome {
        case moved(Int)
        case skipped(String)
        case failed(Int)
    }

    private func report(_ outcome: Outcome) {
        switch outcome {
        case let .moved(count):
            lastError = nil
            if count > 0 { Self.logger.info("moved \(count, privacy: .public) desktop icons clear of the taskbar") }
        case let .skipped(reason):
            lastError = nil
            Self.logger.debug("desktop icons: \(reason, privacy: .public)")
        case let .failed(code):
            // Log a failure once, not every poll (e.g. Automation permission denied: -1743).
            guard lastError != code else { return }
            lastError = code
            Self.logger.error("desktop icons: Finder error \(code, privacy: .public)")
        }
    }

    nonisolated private static func clearIcons(bar: CGRect, screen: CGRect) -> Outcome {
        let read = """
        tell application "Finder"
            set opts to icon view options of window of desktop
            set n to name of every item of desktop
            set p to desktop position of every item of desktop
            return {icon size of opts, (arrangement of opts) as text, n, p}
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: read)?.executeAndReturnError(&error),
              result.numberOfItems == 4 else {
            return .failed((error?[NSAppleScript.errorNumber] as? Int) ?? -1)
        }
        let iconSize = CGFloat(result.atIndex(1)?.int32Value ?? 64)
        let arrangement = result.atIndex(2)?.stringValue ?? ""
        // Finder rearranges sorted desktops itself; a position set there would not stick.
        guard arrangement == "not arranged" || arrangement == "snap to grid" else {
            return .skipped("desktop is sorted (\(arrangement))")
        }
        guard let names = result.atIndex(3), let positions = result.atIndex(4),
              names.numberOfItems == positions.numberOfItems else { return .failed(-2) }
        var icons: [DesktopIconPlacement.Icon] = []
        if names.numberOfItems > 0 {
            for index in 1...names.numberOfItems {
                guard let name = names.atIndex(index)?.stringValue,
                      let position = positions.atIndex(index), position.numberOfItems == 2,
                      let x = position.atIndex(1)?.int32Value, let y = position.atIndex(2)?.int32Value
                else { continue }
                icons.append(.init(name: name, center: CGPoint(x: CGFloat(x), y: CGFloat(y))))
            }
        }
        let moves = DesktopIconPlacement.moves(icons: icons, bar: bar, screen: screen,
                                               grid: .init(iconSize: iconSize))
        guard !moves.isEmpty else { return .moved(0) }
        let lines = moves.map { move in
            "set desktop position of item \"\(escaped(move.name))\" of desktop to {\(Int(move.center.x)), \(Int(move.center.y))}"
        }
        let write = "tell application \"Finder\"\n" + lines.joined(separator: "\n") + "\nend tell"
        guard NSAppleScript(source: write)?.executeAndReturnError(&error) != nil else {
            return .failed((error?[NSAppleScript.errorNumber] as? Int) ?? -1)
        }
        return .moved(moves.count)
    }

    nonisolated private static func escaped(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
