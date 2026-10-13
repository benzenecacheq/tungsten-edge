import Foundation
import os

/// One drawer: a capsule beside the bar and the popup it opens. The original drawer
/// (`DrawerStore.defaultDrawerID`) can be renamed and moved but not deleted.
struct NamedDrawer: Codable, Equatable, Identifiable {
    let id: String
    /// Empty for the original drawer until the user names it: it then reads "Drawer".
    var name: String
}

@MainActor
final class DrawerStore: ObservableObject {
    /// Every filed app, whichever drawer holds it. The strip keeps reading this alone: an app in
    /// any drawer is off the bar.
    @Published private(set) var bundleIDs: [String] = []
    /// The drawers in capsule order (dragged by the user); never empty, always holds the original.
    @Published private(set) var drawers: [NamedDrawer] = [NamedDrawer(id: DrawerStore.defaultDrawerID, name: "")]
    /// Which drawer each filed app sits in. Absent = the original drawer, so apps filed before
    /// named drawers existed stay where they were.
    @Published private(set) var assignments: [String: String] = [:]
    /// The drawer the popup shows and a drop files into: the capsule last clicked, or hovered
    /// during a drag. Not persisted.
    @Published private(set) var activeDrawerID: String = DrawerStore.defaultDrawerID

    static let defaultDrawerID = "default"

    private let key = "drawerBundleIDs"
    private let drawersKey = "namedDrawers"
    private let assignmentsKey = "drawerAssignments"
    private static let legacyFavoriteKey = "launchFavoriteBundleIDs"
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "drawer-store")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var ids = defaults.stringArray(forKey: key) ?? []

        // 迁移：并入旧 launchFavoriteBundleIDs 后删旧 key（空数组也删，不留残 key）
        if let favorites = defaults.stringArray(forKey: Self.legacyFavoriteKey) {
            defaults.removeObject(forKey: Self.legacyFavoriteKey)
            for fav in favorites where !fav.isEmpty && !ids.contains(fav) {
                ids.append(fav)
            }
            if !favorites.isEmpty {
                logger.info("merged \(favorites.count) entries from launchFavoriteBundleIDs into drawerBundleIDs")
            }
        }

        bundleIDs = ids
        if let stored = defaults.stringArray(forKey: key), stored != ids {
            persist()
        } else if defaults.stringArray(forKey: key) == nil && !ids.isEmpty {
            persist()
        }

        if let data = defaults.data(forKey: drawersKey),
           let stored = try? JSONDecoder().decode([NamedDrawer].self, from: data) {
            drawers = Self.normalized(stored)
        }
        let known = Set(drawers.map(\.id))
        assignments = (defaults.dictionary(forKey: assignmentsKey) as? [String: String] ?? [:])
            .filter { ids.contains($0.key) && known.contains($0.value) && $0.value != Self.defaultDrawerID }
    }

    func contains(_ id: String) -> Bool { bundleIDs.contains(id) }

    /// Files `id` into the active drawer (or moves it there).
    func add(_ id: String) {
        add(id, to: activeDrawerID)
    }

    func add(_ id: String, to drawer: String) {
        guard !id.isEmpty else { return }
        let target = drawers.contains { $0.id == drawer } ? drawer : Self.defaultDrawerID
        if drawerID(of: id) != target || !bundleIDs.contains(id) {
            setAssignment(target, for: id)
        }
        guard !bundleIDs.contains(id) else { return }
        bundleIDs.append(id)
        persist()
    }

    func remove(_ id: String) {
        bundleIDs.removeAll { $0 == id }
        persist()
        setAssignment(nil, for: id)
    }

    // MARK: Named drawers

    func drawerID(of bundleID: String) -> String {
        assignments[bundleID] ?? Self.defaultDrawerID
    }

    /// `ids` (any order the caller keeps) narrowed to the apps filed in `drawerID`.
    func members(_ ids: [String], inDrawer drawerID: String) -> [String] {
        ids.filter { self.drawerID(of: $0) == drawerID }
    }

    func displayName(of drawerID: String) -> String {
        let name = drawers.first { $0.id == drawerID }?.name ?? ""
        return name.isEmpty ? String(localized: "Drawer") : name
    }

    func setActiveDrawer(_ drawerID: String) {
        let target = drawers.contains { $0.id == drawerID } ? drawerID : Self.defaultDrawerID
        if activeDrawerID != target { activeDrawerID = target }
    }

    /// Adds a drawer after the others and returns its id.
    @discardableResult
    func createDrawer(named name: String) -> String {
        let id = UUID().uuidString
        drawers.append(NamedDrawer(id: id, name: Self.trimmed(name)))
        persistDrawers()
        return id
    }

    /// Moves a drawer to `index` in capsule order (clamped).
    func moveDrawer(_ drawerID: String, to index: Int) {
        guard let from = drawers.firstIndex(where: { $0.id == drawerID }) else { return }
        let to = min(max(index, 0), drawers.count - 1)
        guard from != to else { return }
        var next = drawers
        next.insert(next.remove(at: from), at: to)
        drawers = next
        persistDrawers()
    }

    func renameDrawer(_ drawerID: String, to name: String) {
        guard let index = drawers.firstIndex(where: { $0.id == drawerID }) else { return }
        let next = Self.trimmed(name)
        guard drawers[index].name != next else { return }
        drawers[index].name = next
        persistDrawers()
    }

    /// Deletes a named drawer; its apps move to the original drawer, never back onto the bar.
    func deleteDrawer(_ drawerID: String) {
        guard drawerID != Self.defaultDrawerID,
              let index = drawers.firstIndex(where: { $0.id == drawerID }) else { return }
        drawers.remove(at: index)
        assignments = assignments.filter { $0.value != drawerID }
        if activeDrawerID == drawerID { activeDrawerID = Self.defaultDrawerID }
        persistDrawers()
        persistAssignments()
    }

    // MARK: Persistence

    private func setAssignment(_ drawerID: String?, for bundleID: String) {
        let value = drawerID == Self.defaultDrawerID ? nil : drawerID
        guard assignments[bundleID] != value else { return }
        assignments[bundleID] = value
        persistAssignments()
    }

    private func persist() {
        defaults.set(bundleIDs, forKey: key)
    }

    private func persistDrawers() {
        if let data = try? JSONEncoder().encode(drawers) { defaults.set(data, forKey: drawersKey) }
    }

    private func persistAssignments() {
        defaults.set(assignments, forKey: assignmentsKey)
    }

    /// Stored order with duplicate ids dropped; the original drawer is put first if missing.
    private static func normalized(_ stored: [NamedDrawer]) -> [NamedDrawer] {
        var seen: Set<String> = []
        let unique = stored.filter { seen.insert($0.id).inserted }
        return seen.contains(defaultDrawerID) ? unique : [NamedDrawer(id: defaultDrawerID, name: "")] + unique
    }

    private static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
