import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// XQuartz windows (X11 clients, usually remote xterms) never appear in XQuartz's AX window list,
/// so the AX inventory sees an app with no windows. Two other sources do describe them:
///
/// - the window server lists every X window under XQuartz's pid, with its frame (and its title,
///   but only to apps holding Screen Recording permission — Tungsten Edge usually doesn't);
/// - XQuartz's own Window menu lists the same windows with their titles (after the last
///   separator), and choosing an item brings that window forward — restoring it when minimized —
///   just as the system Dock does.
///
/// The menu lists windows in creation order, which is window-ID order, so the n-th X window by ID
/// is the n-th window item in the menu. That pairing gives each card its title and lets a card for
/// one of several identical `user@host` xterms raise exactly that window.
enum XQuartzWindowRules {
    static let bundleIdentifier = "org.xquartz.X11"
    /// Extra X servers run from renamed copies of XQuartz.app (`~/bin/xdesk`: one server per
    /// desktop, since macOS 27 keeps each server's windows on the desktop it started on).
    static let copyBundleIdentifierPrefix = "org.xquartz.X11.display"

    static func isXQuartz(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == Self.bundleIdentifier
            || bundleIdentifier.hasPrefix(Self.copyBundleIdentifierPrefix)
    }
}

/// One XQuartz-owned layer-0 window as the window server lists it.
struct XQuartzCGWindow: Equatable, Sendable {
    let id: CGWindowID
    /// Empty without Screen Recording permission.
    let title: String
    let bounds: CGRect?
    let isOnScreen: Bool
    /// Belongs to some Space. XQuartz's own panels (Preferences, the Applications menu editor,
    /// menu-bar strips) belong to none while closed.
    let hasSpace: Bool
    /// Belongs to a Space a display is showing right now.
    let isInCurrentSpace: Bool
    /// In XQuartz's AX window list: one of its own AppKit panels, open. X windows never are.
    let isAppKitWindow: Bool
}

struct XQuartzWindow: Equatable, Sendable {
    let cgWindowID: CGWindowID
    let title: String
    let bounds: CGRect?
    let isMinimized: Bool
    /// Topmost on-screen X window: the focused one while XQuartz is frontmost.
    let isFront: Bool
    /// Position among the Window menu's window items.
    let menuIndex: Int
}

enum XQuartzWindowInventory {
    /// The window titles in XQuartz's Window menu: the items after its last separator
    /// (separators read back from AX as empty titles).
    static func windowTitles(fromWindowMenuItems items: [String]) -> [String] {
        guard let lastSeparator = items.lastIndex(of: "") else { return [] }
        return Array(items[items.index(after: lastSeparator)...])
    }

    /// The X windows to show, in creation (window-ID) order; nil when the two sources disagree
    /// and cannot be paired (a window opening or closing between the two reads).
    ///
    /// - Parameters:
    ///   - cgWindows: XQuartz's layer-0 windows, front to back as the window server lists them.
    ///   - menuTitles: the window titles from XQuartz's Window menu, in menu order.
    ///
    /// X windows are those with a Space that are not AppKit panels. When their count matches the
    /// menu's they pair by position. Otherwise, given window-server titles, each title's windows
    /// pair with that title's menu items in order. Minimized = in a Space that is showing, yet off
    /// screen; a window on another Space is merely off screen.
    static func windows(cgWindows: [XQuartzCGWindow], menuTitles: [String]) -> [XQuartzWindow]? {
        let xWindows = cgWindows
            .filter { $0.hasSpace && !$0.isAppKitWindow }
            .sorted { $0.id < $1.id }

        var paired: [(window: XQuartzCGWindow, title: String, menuIndex: Int)] = []
        if xWindows.count == menuTitles.count {
            paired = zip(xWindows, menuTitles.indices).map { ($0, menuTitles[$1], $1) }
        } else if xWindows.allSatisfy({ !$0.title.isEmpty }) {
            var unclaimed: [String: [Int]] = [:]
            for (index, title) in menuTitles.enumerated() { unclaimed[title, default: []].append(index) }
            for window in xWindows {
                guard var indices = unclaimed[window.title], !indices.isEmpty else { continue }
                paired.append((window, window.title, indices.removeFirst()))
                unclaimed[window.title] = indices
            }
        } else {
            return nil
        }

        let pairedIDs = Set(paired.map(\.window.id))
        let frontID = cgWindows.first { pairedIDs.contains($0.id) && $0.isOnScreen }?.id
        return paired.map { window, title, menuIndex in
            XQuartzWindow(
                cgWindowID: window.id,
                title: title,
                bounds: window.bounds,
                isMinimized: !window.isOnScreen && window.isInCurrentSpace,
                isFront: window.id == frontID,
                menuIndex: menuIndex
            )
        }
    }
}

/// Live reads for `XQuartzWindowInventory`. Off the main thread: the Window menu read is AX,
/// bounded by a short messaging timeout so a stuck XQuartz cannot stall the caller.
enum XQuartzWindowReader {
    private static let messagingTimeout: Float = 0.25

    struct Reading: Equatable, Sendable {
        let pid: pid_t
        let bundleIdentifier: String
        let isHidden: Bool
        let windows: [XQuartzWindow]
    }

    struct Server: Equatable, Sendable {
        let pid: pid_t
        let bundleIdentifier: String
    }

    /// Every running XQuartz server process: XQuartz itself and any renamed copies. Found by
    /// executable rather than through LaunchServices, which lists XQuartz (started by launchd's
    /// startx) with pid -1 and may not list a copy started straight from its binary at all.
    static func runningServers() -> [Server] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var servers: [Server] = []
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(cString: path)
            guard executable.hasSuffix(".app/Contents/MacOS/X11.bin"),
                  let bundleID = bundleIdentifier(ofExecutable: executable),
                  XQuartzWindowRules.isXQuartz(bundleIdentifier: bundleID) else { continue }
            servers.append(Server(pid: pid, bundleIdentifier: bundleID))
        }
        return servers
    }

    private static func bundleIdentifier(ofExecutable executable: String) -> String? {
        let contents = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
        let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))
        return plist?["CFBundleIdentifier"] as? String
    }

    /// nil when the Window menu cannot be read (XQuartz busy, launching, or AX not granted):
    /// callers keep their previous reading rather than dropping every card.
    static func read(_ server: Server) -> Reading? {
        guard let items = windowMenuItems(pid: server.pid),
              let windows = windows(pid: server.pid, menuItems: items) else { return nil }
        let isHidden = NSRunningApplication(processIdentifier: server.pid)?.isHidden ?? false
        return Reading(pid: server.pid, bundleIdentifier: server.bundleIdentifier, isHidden: isHidden, windows: windows)
    }

    static func windows(pid: pid_t, menuItems: [MenuItem]) -> [XQuartzWindow]? {
        XQuartzWindowInventory.windows(
            cgWindows: cgWindows(pid: pid),
            menuTitles: XQuartzWindowInventory.windowTitles(fromWindowMenuItems: menuItems.map(\.title))
        )
    }

    static func cgWindows(pid: pid_t) -> [XQuartzCGWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let current = XQuartzSpaces.currentSpaceIDs()
        let appKitWindowIDs = axWindowIDs(pid: pid)
        return info.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let number = entry[kCGWindowNumber as String] as? Int else { return nil }
            let title = entry[kCGWindowName as String] as? String ?? ""
            let spaces = XQuartzSpaces.spaceIDs(forWindowNumber: number)
            let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0) }
            return XQuartzCGWindow(
                id: CGWindowID(number),
                title: title,
                bounds: bounds,
                isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool == true,
                hasSpace: !spaces.isEmpty,
                isInCurrentSpace: !current.isDisjoint(with: spaces),
                isAppKitWindow: appKitWindowIDs.contains(CGWindowID(number))
            )
        }
    }

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindowFn? = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY
    ).flatMap { dlsym($0, "_AXUIElementGetWindow") }.map { unsafeBitCast($0, to: GetWindowFn.self) }

    /// Window IDs of XQuartz's AX windows: its own AppKit panels while open.
    private static func axWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let getWindow, let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return Set(windows.compactMap { window in
            var id = CGWindowID(0)
            return getWindow(window, &id) == .success && id != 0 ? id : nil
        })
    }

    struct MenuItem {
        let title: String
        let commandKey: String?
        let element: AXUIElement
    }

    /// XQuartz's Window menu, item by item. Found by title, else as the menu just before Help
    /// (XQuartz's menu bar is Apple, XQuartz, Applications, Edit, Window, Help in every language).
    static func windowMenuItems(pid: pid_t) -> [MenuItem]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let bar = attribute(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }),
              let menus = attribute(bar, kAXChildrenAttribute) as? [AXUIElement],
              menus.count >= 2 else { return nil }
        let windowMenu = menus.first { attribute($0, kAXTitleAttribute) as? String == "Window" }
            ?? menus[menus.count - 2]
        guard let submenu = (attribute(windowMenu, kAXChildrenAttribute) as? [AXUIElement])?.first,
              let items = attribute(submenu, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        return items.map { item in
            MenuItem(
                title: attribute(item, kAXTitleAttribute) as? String ?? "",
                commandKey: attribute(item, kAXMenuItemCmdCharAttribute) as? String,
                element: item
            )
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

/// The two SkyLight reads the inventory needs, loaded here rather than borrowed from
/// `FullscreenIntentMonitor` because this file is also built into window-lab, which does not
/// include it. Same symbols and masks as `ManagedSpaceLayoutReader` / `WindowSpaceMembershipReader`.
private enum XQuartzSpaces {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> CFArray?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?

    private static let symbols: (cid: Int32, displays: CopyManagedDisplaySpacesFn, forWindows: CopySpacesForWindowsFn)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let cidSym = dlsym(handle, "SLSMainConnectionID"),
              let displaysSym = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let windowsSym = dlsym(handle, "SLSCopySpacesForWindows") else { return nil }
        return (
            unsafeBitCast(cidSym, to: MainConnectionIDFn.self)(),
            unsafeBitCast(displaysSym, to: CopyManagedDisplaySpacesFn.self),
            unsafeBitCast(windowsSym, to: CopySpacesForWindowsFn.self)
        )
    }()

    /// The Space each display is showing right now; empty when SkyLight cannot be read.
    static func currentSpaceIDs() -> Set<Int> {
        guard let symbols, let displays = symbols.displays(symbols.cid) as? [[String: Any]] else { return [] }
        return Set(displays.compactMap { display in
            (display["Current Space"] as? [String: Any]).flatMap { ($0["ManagedSpaceID"] as? Int) ?? ($0["id64"] as? Int) }
        })
    }

    /// Every Space the window belongs to (mask 0x7); empty when it belongs to none or cannot be read.
    static func spaceIDs(forWindowNumber number: Int) -> [Int] {
        guard number > 0, let symbols,
              let raw = symbols.forWindows(symbols.cid, 0x7, [NSNumber(value: number)] as CFArray) as? [NSNumber]
        else { return [] }
        return raw.map(\.intValue)
    }
}

/// Card actions for XQuartz windows, all through XQuartz's Window menu. Its items act only while
/// XQuartz is the active app, so every action activates it first.
enum XQuartzWindowActions {
    private static let activationWait: TimeInterval = 0.5

    static func perform(_ kind: PlatformActionRequest.ActionKind, record: WindowRecord) -> Bool {
        guard let cgWindowID = record.cgWindowID,
              let app = NSRunningApplication(processIdentifier: record.pid) else { return false }
        if !app.isActive {
            if app.isHidden { app.unhide() }
            app.activate(options: [.activateIgnoringOtherApps])
            let deadline = Date().addingTimeInterval(activationWait)
            while NSRunningApplication(processIdentifier: record.pid)?.isActive != true, Date() < deadline {
                usleep(20_000)
            }
        }
        guard let items = XQuartzWindowReader.windowMenuItems(pid: record.pid) else { return false }

        // Bring the window forward (also restores it when minimized); minimize and close then act
        // on the front window.
        guard let window = XQuartzWindowReader.windows(pid: record.pid, menuItems: items)?
                .first(where: { $0.cgWindowID == cgWindowID }),
              let separator = items.lastIndex(where: { $0.title.isEmpty }) else { return false }
        let windowItems = Array(items[items.index(after: separator)...])
        // Already minimized: nothing to minimize, and pressing ⌘M would take whichever window
        // has X focus instead.
        if kind == .minimizeWindow, window.isMinimized { return true }
        guard window.menuIndex < windowItems.count, press(windowItems[window.menuIndex]) else { return false }

        switch kind {
        case .activateWindow:
            return true
        case .minimizeWindow:
            return pressCommand("M", on: cgWindowID, pid: record.pid)
        case .closeWindow:
            return pressCommand("W", on: cgWindowID, pid: record.pid)
        case .hideApp, .quitApp, .newWindow:
            return false
        }
    }

    private static let frontWait: TimeInterval = 0.5

    /// The Window menu item with this ⌘ key (Minimize ⌘M, Close ⌘W). These act on the X-focused
    /// window, so only once the raised window is verifiably XQuartz's front window — otherwise
    /// they would minimize or close some other window, and nothing at all is better than that.
    private static func pressCommand(_ key: String, on cgWindowID: CGWindowID, pid: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(frontWait)
        while frontWindowID(pid: pid) != cgWindowID {
            guard Date() < deadline else { return false }
            usleep(25_000)
        }
        usleep(50_000)
        guard let item = XQuartzWindowReader.windowMenuItems(pid: pid)?
            .first(where: { $0.commandKey == key }) else { return false }
        return press(item)
    }

    /// XQuartz's topmost on-screen window (the window server lists front to back).
    private static func frontWindowID(pid: pid_t) -> CGWindowID? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return info.first {
            ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid && $0[kCGWindowLayer as String] as? Int == 0
        }.flatMap { ($0[kCGWindowNumber as String] as? Int).map(CGWindowID.init) }
    }

    private static func press(_ item: XQuartzWindowReader.MenuItem) -> Bool {
        AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
    }
}
