import Foundation
import UniformTypeIdentifiers

/// 固定文件夹弹窗/封面的排序方式（对齐原生 Stacks 的「排序方式」）。rawValue 落盘
/// （`PinnedFolderStore.sortOrders`，path → rawValue）。声明顺序即菜单显示顺序。
enum FolderSortOrder: String, CaseIterable {
    case name
    case dateAdded      // 默认：添加日期,最新在前（与旧版唯一排序口径一致）
    case dateModified   // 修改日期,最新在前
    case kind
    /// The order the user dragged the items into (`FolderManualOrderStore`); items not placed yet
    /// lead, newest added first.
    case manual

    static let `default`: FolderSortOrder = .dateAdded

    var menuTitle: String {
        switch self {
        case .name: return String(localized: "Name")
        case .dateAdded: return String(localized: "Date Added")
        case .dateModified: return String(localized: "Date Modified")
        case .kind: return String(localized: "Kind")
        case .manual: return String(localized: "Manual")
        }
    }
}

/// Whether a stored path is still there, told apart from "there but not readable": only `ENOENT` /
/// `ENOTDIR` mean gone. Anything else (`EPERM` from a privacy-protected folder such as the Desktop,
/// `EACCES`, I/O errors) must never delete a shelf reference.
enum FileReachability: Equatable {
    case exists, missing, inaccessible

    static func of(path: String) -> FileReachability {
        var info = stat()
        let result = lstat(path, &info)
        return classify(result: result, errorNumber: result == 0 ? 0 : errno)
    }

    static func classify(result: Int32, errorNumber: Int32) -> FileReachability {
        if result == 0 { return .exists }
        return errorNumber == ENOENT || errorNumber == ENOTDIR ? .missing : .inaccessible
    }
}

/// 固定文件夹/废纸篓内容读取与排序。`load` 走文件系统（调用方放后台队列）；
/// 排序与选封面是纯函数，进单测。枚举一律跳过隐藏文件。
enum FolderContentsLoader {
    struct Entry: Equatable {
        var url: URL
        var name: String
        var isDirectory: Bool
        var dateAdded: Date?
        var dateModified: Date?
        /// false = the path exists but this process may not read it (privacy permission).
        var isAccessible = true
    }

    static func load(directory: URL) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .addedToDirectoryDateKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(
                url: url,
                name: FileManager.default.displayName(atPath: url.path),
                isDirectory: values?.isDirectory ?? false,
                dateAdded: values?.addedToDirectoryDate,
                dateModified: values?.contentModificationDate
            )
        }
    }

    /// 加入日期降序（最新在前）；网络卷等场景 dateAdded 可能为 nil，用修改日期兜底；
    /// 同刻再按本地化文件名升序破平，保证排序稳定。
    static func sortedByDateAdded(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            let da = a.dateAdded ?? a.dateModified ?? .distantPast
            let db = b.dateAdded ?? b.dateModified ?? .distantPast
            if da != db { return da > db }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 按用户选的排序方式排（弹窗网格与封面共用口径）。全部稳定：末级都按本地化文件名破平。
    static func sorted(_ entries: [Entry], by order: FolderSortOrder) -> [Entry] {
        switch order {
        case .manual:
            guard let folder = entries.first?.url.deletingLastPathComponent().path else { return entries }
            return sortedManually(entries, order: FolderManualOrderStore.shared.order(forFolder: folder))
        case .dateAdded:
            return sortedByDateAdded(entries)
        case .name:
            return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateModified:
            return entries.sorted { a, b in
                let da = a.dateModified ?? a.dateAdded ?? .distantPast
                let db = b.dateModified ?? b.dateAdded ?? .distantPast
                if da != db { return da > db }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .kind:
            // 显式两级：组别数字 → 组内种类名 → 文件名。不用哨兵字符拼进字符串——
            // localizedStandardCompare 会忽略控制字符,"\0" 前缀保证不了文件夹恒在最前（单测抓到）。
            return entries.sorted { a, b in
                let ra = kindRank(for: a), rb = kindRank(for: b)
                if ra != rb { return ra < rb }
                let ka = kindName(for: a), kb = kindName(for: b)
                if ka != kb { return ka.localizedStandardCompare(kb) == .orderedAscending }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// `order` is file names, front first. Names not in it (added since the last drag) lead, newest
    /// added first; names in it that are gone are skipped.
    static func sortedManually(_ entries: [Entry], order: [String]) -> [Entry] {
        var rank: [String: Int] = [:]
        for (index, name) in order.enumerated() where rank[name] == nil { rank[name] = index }
        let unplaced = sortedByDateAdded(entries.filter { rank[$0.url.lastPathComponent] == nil })
        let placed = entries.compactMap { entry in rank[entry.url.lastPathComponent].map { (entry, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        return unplaced + placed
    }

    /// 种类排序的组别：文件夹(0) → 有扩展名的文件(1) → 无扩展名文件(2,殿后)。
    static func kindRank(for entry: Entry) -> Int {
        if entry.isDirectory { return 0 }
        return entry.url.pathExtension.isEmpty ? 2 : 1
    }

    /// 种类分组名：文件按 UTType 本地化描述分组（拿不到用扩展名兜底）。文件夹/无扩展名返回空串
    /// （它们各自成组,组别已由 kindRank 决定）。
    static func kindName(for entry: Entry) -> String {
        guard !entry.isDirectory else { return "" }
        let ext = entry.url.pathExtension.lowercased()
        guard !ext.isEmpty else { return "" }
        if let type = UTType(filenameExtension: ext), let desc = type.localizedDescription {
            return desc
        }
        return ext
    }

    /// How many items a folder chip's cover stacks, like a native Dock stack.
    static let coverStackLimit = 3

    /// The chip cover: the first items of the already-sorted listing, front first. Subfolders
    /// count, as on a native Dock stack.
    static func coverEntries(in sortedEntries: [Entry]) -> [Entry] {
        Array(sortedEntries.prefix(coverStackLimit))
    }

    /// 中转格：按给定路径列表构造条目（保持传入顺序 = 暂存序），确定不存在的跳过。
    /// Unreadable paths stay as `isAccessible == false` entries: without the folder's privacy
    /// permission an existing file looks the same as a deleted one to `fileExists`.
    static func entries(forPaths paths: [String]) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .addedToDirectoryDateKey, .contentModificationDateKey]
        return paths.compactMap { path in
            let reachability = FileReachability.of(path: path)
            guard reachability != .missing else { return nil }
            let url = URL(fileURLWithPath: path)
            guard reachability == .exists else {
                return Entry(url: url, name: url.lastPathComponent, isDirectory: false,
                             dateAdded: nil, dateModified: nil, isAccessible: false)
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(
                url: url,
                name: FileManager.default.displayName(atPath: path),
                isDirectory: values?.isDirectory ?? false,
                dateAdded: values?.addedToDirectoryDate,
                dateModified: values?.contentModificationDate
            )
        }
    }

    /// 弹窗「先载入后亮相」（散装感根因修复）：后台枚举 + 排序，最多等 `timeout`
    /// （本地文件夹一般 <20ms）。超时或读取失败返回 nil（网络卷等罕见场景），
    /// 调用方走原异步回填路径。超时后后台块继续跑完自然释放，结果不再被读取。
    static func preload(url: URL, timeout: TimeInterval, order: FolderSortOrder = .default) -> [Entry]? {
        final class Box { var entries: [Entry]? }
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        DispatchQueue.global(qos: .userInteractive).async {
            box.entries = (try? load(directory: url)).map { sorted($0, by: order) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.entries
    }
}
