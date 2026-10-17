import AppKit
import Foundation
import os

/// Gives Windows programs running under CrossOver the bundle ID of the launcher CrossOver made
/// for them, so they can be pinned, kept and filed like any app.
///
/// A program started from its launcher (`~/Applications/CrossOver/Firefox.app`) keeps that
/// launcher's bundle ID. One started any other way — qBittorrent opened by a magnet link in a
/// CrossOver Firefox — registers as bare `qbittorrent.exe` with no bundle at all. CrossOver's
/// launchers don't name the .exe they run, so the match is by name: the exe's base name against
/// the launcher's menu name (`CXOriginalMenuName`), its bundle name, or its file name.
enum CrossOverLauncherIndex {
    static let bundleIDPrefix = "com.codeweavers.CrossOverHelper."

    /// The app's own bundle ID, or for a bundle-less CrossOver program its launcher's.
    static func bundleID(for app: NSRunningApplication) -> String? {
        if let own = app.bundleIdentifier, !own.isEmpty { return own }
        return launcherBundleID(processName: app.localizedName, executablePath: app.executableURL?.path)
    }

    /// `runningApplications(withBundleIdentifier:)`, plus the bundle-less CrossOver programs that
    /// resolve to that launcher.
    static func runningApplications(withBundleIdentifier bundleID: String) -> [NSRunningApplication] {
        let owned = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard bundleID.hasPrefix(bundleIDPrefix) else { return owned }
        let adopted = NSWorkspace.shared.runningApplications.filter {
            ($0.bundleIdentifier ?? "").isEmpty && !$0.isTerminated && self.bundleID(for: $0) == bundleID
        }
        return owned + adopted
    }

    static func launcherBundleID(processName: String?, executablePath: String?) -> String? {
        guard let key = programKey(processName: processName, executablePath: executablePath) else { return nil }
        return cache.lookup(key)
    }

    /// Lowercased exe base name, only for a Windows program (`*.exe`).
    static func programKey(processName: String?, executablePath: String?) -> String? {
        let candidates = [processName, executablePath.map { ($0 as NSString).lastPathComponent }]
        for case let name? in candidates where name.lowercased().hasSuffix(".exe") {
            let base = String(name.dropLast(4)).trimmingCharacters(in: .whitespaces).lowercased()
            if !base.isEmpty { return base }
        }
        return nil
    }

    /// Launcher names → bundle IDs, from the plists of the apps in `~/Applications/CrossOver`
    /// (one level of subfolders too). Names claimed by two launchers are dropped as ambiguous.
    static func index(launcherPlists: [[String: Any]]) -> [String: String] {
        var result: [String: String] = [:]
        var ambiguous: Set<String> = []
        for plist in launcherPlists {
            guard let id = plist["CFBundleIdentifier"] as? String, id.hasPrefix(bundleIDPrefix) else { continue }
            let names = Set(["CXOriginalMenuName", "CFBundleName", "fileName"]
                .compactMap { (plist[$0] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty })
            for name in names {
                if let existing = result[name], existing != id { ambiguous.insert(name) }
                result[name] = id
            }
        }
        for name in ambiguous { result.removeValue(forKey: name) }
        return result
    }

    private static let cache = Cache()

    /// Rebuilt on a miss at most every 30s, so a launcher made after startup is picked up.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: String] = [:]
        private var builtAt: Date?
        private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "crossover-launchers")

        func lookup(_ key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let hit = map[key] { return hit }
            if let builtAt, Date().timeIntervalSince(builtAt) < 30 { return nil }
            map = CrossOverLauncherIndex.index(launcherPlists: Self.readLaunchers())
            builtAt = Date()
            logger.info("indexed \(self.map.count) CrossOver launcher names; \(key, privacy: .public) -> \(self.map[key] ?? "none", privacy: .public)")
            return map[key]
        }

        private static func readLaunchers() -> [[String: Any]] {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/CrossOver", isDirectory: true)
            var apps: [URL] = []
            let top = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for url in top {
                if url.pathExtension == "app" {
                    apps.append(url)
                } else if let inner = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    apps += inner.filter { $0.pathExtension == "app" }
                }
            }
            return apps.compactMap { app in
                guard var plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
                    as? [String: Any] else { return nil }
                plist["fileName"] = app.deletingPathExtension().lastPathComponent
                return plist
            }
        }
    }
}
