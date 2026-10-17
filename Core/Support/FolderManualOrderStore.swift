import Foundation

/// The order the user dragged a folder's items into, for folders sorted Manually: folder path →
/// file names, front first. Read from the background queues that sort folder contents, so it is
/// lock-guarded rather than MainActor.
final class FolderManualOrderStore: @unchecked Sendable {
    static let shared = FolderManualOrderStore()

    private let lock = NSLock()
    private var orders: [String: [String]]
    private let defaults: UserDefaults
    private let key = "folderManualOrders"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        orders = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    func order(forFolder path: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return orders[FilePathNormalization.normalized(path)] ?? []
    }

    func setOrder(_ names: [String], forFolder path: String) {
        let folder = FilePathNormalization.normalized(path)
        lock.lock()
        guard orders[folder] != names else { lock.unlock(); return }
        orders[folder] = names
        let snapshot = orders
        lock.unlock()
        defaults.set(snapshot, forKey: key)
    }
}
