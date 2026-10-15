import AppKit
@preconcurrency import ApplicationServices
import Foundation

/// Which window is in front: the frontmost app and the window focused inside it.
///
/// The snapshot's `.active` status can't answer this — AX keeps a focused window per app, so
/// every app with a window has one marked active. This pairs the frontmost app with its focused
/// window, re-read whenever the app changes, its focus moves, or a window comes or goes.
///
/// Apps AX can't see into (XQuartz: its X windows aren't AX windows, and NSWorkspace gives it
/// pid -1) fall back to the window server: the app's topmost on-screen window. Nothing notifies
/// focus moves inside such an app, so while one is in front it is re-read twice a second.
@MainActor
final class FrontWindowTracker {
    struct Front: Equatable {
        let pid: pid_t
        /// nil when the front app has no focused window (Finder on the desktop, a windowless app).
        let windowID: CGWindowID?
    }

    var onChange: ((Front?) -> Void)?

    private var observer: FrontmostWindowGeometryObserver?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var readGeneration: UInt64 = 0
    private var pollTimer: Timer?

    func start() {
        guard observer == nil else { return }
        let observer = FrontmostWindowGeometryObserver()
        observer.onEvent = { [weak self] event in
            if event != .geometryChanged { self?.refresh() }
        }
        self.observer = observer

        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                MainActor.assumeIsolated { self?.activate(pid: pid) }
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        ]
        activate(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    func stop() {
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens = []
        observer?.stop()
        observer = nil
        readGeneration &+= 1
        setPolling(false)
    }

    private func activate(pid: pid_t?) {
        observer?.activate(pid: pid)
        refresh()
    }

    /// Reads the front app's focused window off the main thread (cross-process calls) and
    /// reports it; a newer read supersedes an older one still in flight.
    private func refresh() {
        guard observer != nil else { return }
        readGeneration &+= 1
        let generation = readGeneration
        guard let app = NSWorkspace.shared.frontmostApplication else {
            setPolling(false)
            onChange?(nil)
            return
        }
        let pid = app.processIdentifier
        let name = app.localizedName
        Task.detached { [weak self] in
            let read = Self.read(pid: pid, name: name)
            await MainActor.run { [weak self] in
                guard let self, self.readGeneration == generation else { return }
                self.setPolling(read.fromWindowServer)
                self.onChange?(read.front)
            }
        }
    }

    private func setPolling(_ on: Bool) {
        if !on {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
    }

    nonisolated private static func read(pid: pid_t, name: String?) -> (front: Front, fromWindowServer: Bool) {
        if pid > 0 {
            let app = AXUIElementCreateApplication(pid)
            _ = AXUIElementSetMessagingTimeout(app, 0.1)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
            if result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (Front(pid: pid, windowID: AXWindowReader.cgWindowID(for: value as! AXUIElement)), false)
            }
            // No value = no focused window (Finder on the desktop); only a failed read falls back.
            if result == .noValue || result == .success { return (Front(pid: pid, windowID: nil), false) }
        }
        return (topWindow(pid: pid, name: name) ?? Front(pid: pid, windowID: nil), true)
    }

    /// The app's frontmost normal-layer window on screen, matched by pid, or by owner name when
    /// NSWorkspace has no real pid for it.
    nonisolated private static func topWindow(pid: pid_t, name: String?) -> Front? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for entry in list where (entry[kCGWindowLayer as String] as? Int) == 0 {
            guard let owner = (entry[kCGWindowOwnerPID as String] as? Int).map(pid_t.init),
                  let id = (entry[kCGWindowNumber as String] as? Int).map(CGWindowID.init) else { continue }
            if pid > 0 ? owner == pid : (name != nil && entry[kCGWindowOwnerName as String] as? String == name) {
                return Front(pid: owner, windowID: id)
            }
        }
        return nil
    }
}
