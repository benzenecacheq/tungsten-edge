import AppKit
import QuickLookThumbnailing

/// A pinned folder chip's cover: the first items of the folder's current sort, stacked like a
/// native Dock stack (front first). Enumeration runs on a background queue; each folder carries
/// a generation counter and an async Quick Look result publishes only while it is unchanged, so
/// a stale thumbnail cannot overwrite a fresh cover. `@Published` is written on the MainActor only.
struct FolderCover: Equatable {
    struct Layer: Equatable {
        var image: NSImage
        /// A real Quick Look thumbnail (drawn at its own aspect with a hairline) rather than an
        /// icon, which carries its own transparent margin.
        var isThumbnail: Bool
    }
    /// Front first; never empty (an empty folder shows its own icon).
    var layers: [Layer]
}

@MainActor
final class PinnedFolderCoverStore: ObservableObject {
    /// path → cover. Per layer: Quick Look thumbnail → the item's icon; an empty folder shows its own icon.
    @Published private(set) var covers: [String: FolderCover] = [:]

    private struct CacheEntry {
        let order: FolderSortOrder
        let entries: [FolderContentsLoader.Entry]
    }
    /// 后台主动预读并缓存的文件夹完整内容，专供弹窗零延迟提取。热缓存优先，不带 @Published 避免全局不必要重绘。
    private var cache: [String: CacheEntry] = [:]

    private var watchers: [String: DirectoryWatcher] = [:]
    private var generations: [String: Int] = [:]
    /// One counter for all folders, never reset: a per-folder count restarts at 1 when a folder
    /// is unpinned and pinned again, and a callback from before would pass the check.
    private var lastGeneration = 0
    /// coverFilePath|modDate → 缩略图；封面文件没变就不再生成。
    private let thumbnailCache = NSCache<NSString, NSImage>()
    /// 逐文件夹排序方式（AppDelegate 注入,读 PinnedFolderStore）：封面 = 当前排序下最前的几项,
    /// 与弹窗网格同口径（原生 Stacks 同款：改排序,chip 封面跟着换）。
    private let sortOrderProvider: (String) -> FolderSortOrder
    /// `PinnedFolderStore.isUnopenedSeed`: such a folder shows its plain icon and is not read or
    /// watched until the user opens it (reading Downloads raises the system's access prompt).
    private let isUnopenedSeed: (String) -> Bool

    init(sortOrderProvider: @escaping (String) -> FolderSortOrder = { _ in .default },
         isUnopenedSeed: @escaping (String) -> Bool = { _ in false }) {
        self.sortOrderProvider = sortOrderProvider
        self.isUnopenedSeed = isUnopenedSeed
    }

    /// 提取命中且排序一致的热缓存。如果为 nil，调用方应执行同步的 preload 兜底。
    func cachedEntries(for path: String, order: FolderSortOrder) -> [FolderContentsLoader.Entry]? {
        guard let entry = cache[path], entry.order == order else { return nil }
        return entry.entries
    }

    /// 与 PinnedFolderStore.folderPaths 对账：多退少补 watcher，全量刷新一次封面。
    func sync(paths: [String]) {
        let wanted = Set(paths)
        for gone in Array(watchers.keys) where !wanted.contains(gone) {
            watchers[gone]?.stop()
            watchers[gone] = nil
            covers[gone] = nil
            cache[gone] = nil
            generations[gone] = nil
        }
        for path in paths {
            if isUnopenedSeed(path) {
                covers[path] = FolderCover(layers: [.init(image: Self.icon(forPath: path), isThumbnail: false)])
                continue
            }
            if watchers[path] == nil {
                // DirectoryWatcher 回调已在主线程；Task 包一层过 MainActor 隔离。
                watchers[path] = DirectoryWatcher(path: path) { [weak self] in
                    Task { @MainActor [weak self] in self?.refresh(path: path) }
                }
            }
            refresh(path: path)
        }
    }

    private func refresh(path: String) {
        lastGeneration += 1
        let generation = lastGeneration
        generations[path] = generation
        let folderURL = URL(fileURLWithPath: path)
        let order = sortOrderProvider(path)   // MainActor 上读定,后台块用值

        Task.detached(priority: .utility) { [weak self] in
            let entries = (try? FolderContentsLoader.load(directory: folderURL)) ?? []
            let sortedEntries = FolderContentsLoader.sorted(entries, by: order)
            let stack = FolderContentsLoader.coverEntries(in: sortedEntries)
            await MainActor.run { [weak self] in
                guard let self, self.generations[path] == generation else { return }
                self.cache[path] = CacheEntry(order: order, entries: sortedEntries)
                self.publishCover(path: path, stack: stack, generation: generation)
            }
        }
    }

    /// Re-reads one pinned folder's cover (its Manual order changed). Not pinned or not read yet = nothing.
    func refreshCover(path: String) {
        guard watchers[path] != nil else { return }
        refresh(path: path)
    }

    private func publishCover(path: String, stack: [FolderContentsLoader.Entry], generation: Int) {
        guard !stack.isEmpty else {
            covers[path] = FolderCover(layers: [.init(image: Self.icon(forPath: path), isThumbnail: false)])
            return
        }
        var pending: [(index: Int, url: URL, cacheKey: String)] = []
        let layers = stack.enumerated().map { index, entry -> FolderCover.Layer in
            // Folders (and bundles) keep their icon, as on a native stack.
            guard !entry.isDirectory else {
                return .init(image: Self.icon(forPath: entry.url.path), isThumbnail: false)
            }
            let cacheKey = "\(entry.url.path)|\(entry.dateModified?.timeIntervalSince1970 ?? 0)"
            if let cached = thumbnailCache.object(forKey: cacheKey as NSString) {
                return .init(image: cached, isThumbnail: true)
            }
            // The file's icon stands in until its Quick Look thumbnail arrives.
            pending.append((index, entry.url, cacheKey))
            return .init(image: Self.icon(forPath: entry.url.path), isThumbnail: false)
        }
        covers[path] = FolderCover(layers: layers)

        for (index, url, cacheKey) in pending {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 64, height: 64),
                scale: 2,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                guard let cgImage = representation?.cgImage else { return }  // keep the icon on failure
                let image = NSImage(cgImage: cgImage, size: .zero)
                Task { @MainActor [weak self] in
                    guard let self, self.generations[path] == generation,
                          var cover = self.covers[path], cover.layers.indices.contains(index) else { return }
                    self.thumbnailCache.setObject(image, forKey: cacheKey as NSString)
                    cover.layers[index] = .init(image: image, isThumbnail: true)
                    self.covers[path] = cover
                }
            }
        }
    }

    /// NSWorkspace 图标是共享缓存对象，必须 `.copy()` 再改 size（AppMenuFragments 同款惯例）。
    static func icon(forPath path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        guard let copy = icon.copy() as? NSImage else { return icon }
        copy.size = NSSize(width: 64, height: 64)
        return copy
    }
}
