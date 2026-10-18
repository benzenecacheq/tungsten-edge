import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The pinned folders below a side-edge bar: one capsule, a full-width row per folder (its cover
/// and its name, like the bar's own rows), between the bar and the drawer capsules.
///
/// A row opens its folder; right-click is the folder's menu. Files dropped on the middle of a
/// row move into that folder; a folder dropped on a row's top or bottom quarter is pinned there
/// (the same split the bar's folder tiles use). Dragging a row reorders the folders.
struct FolderCapsule: View {
    @EnvironmentObject var pinnedFolderStore: PinnedFolderStore
    @EnvironmentObject var folderCoverStore: PinnedFolderCoverStore
    @EnvironmentObject var settingsStore: AppSettingsStore
    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }

    let usesLiquidGlass: Bool
    /// Transparent room around the visible capsule: the shadow padding outside, half the capsule
    /// gap toward the drawer capsules.
    let edgePadding: EdgeInsets
    /// Opens (or closes) the folder's popup.
    let onOpen: (String) -> Void
    let onOpenInFinder: (String) -> Void
    let onAddFolder: () -> Void
    /// Files dropped on a row, to move into that folder.
    let onMoveFiles: ([URL], String) -> Void

    @State private var hoveredPath: String?
    @State private var draggedPath: String?
    @State private var dragDistance: CGFloat = 0
    @State private var dropTarget: FolderRowDropTarget?
    @State private var reorderClock = DrawerCapsuleStack.ReorderClock()

    private var scale: CGFloat { settingsStore.dockPanelHeight.scale }
    private var rowHeight: CGFloat { settingsStore.dockPanelHeight.metrics.capsuleWidth }
    private var cornerRadius: CGFloat { DockShape.panelCornerRadius * scale }
    private var backgroundLayers: (glass: Double, plate: Double) {
        TaskbarBackgroundOpacity.layers(for: settingsStore.taskbarBackgroundOpacity)
    }

    var body: some View {
        let paths = pinnedFolderStore.folderPaths
        VStack(spacing: 0) {
            ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                row(path, index: index, paths: paths)
            }
        }
        .background {
            ZStack {
                DockPanelBackdrop(theme: theme, cornerRadius: cornerRadius,
                                  usesLiquidGlass: usesLiquidGlass, matchesDockRefraction: true)
                    .opacity(backgroundLayers.glass)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .opacity(backgroundLayers.plate)
            }
        }
        .dockPanelRim(cornerRadius: cornerRadius, style: theme.panelRimStyle,
                      lineWidth: theme.panelRimLineWidth, usesLiquidGlass: usesLiquidGlass)
        .dockShadow(theme.stripShadow,
                    visible: DockLiquidGlassConfiguration.stripShadowVisible(
                        usesLiquidGlass: usesLiquidGlass,
                        usesSystemVariant: DockGlassPresentation.usesSystemVariant))
        .padding(edgePadding)
    }

    private func row(_ path: String, index: Int, paths: [String]) -> some View {
        let open = { if !isTapSuppressed { onOpen(path) } }
        return HStack(spacing: ChipPillMetrics.iconSpacing * scale) {
            PinnedFolderChip(
                path: path,
                cover: folderCoverStore.covers[path],
                sortOrder: pinnedFolderStore.sortOrder(for: path),
                onTap: open,
                onPreview: { onOpen(path) },
                onOpenInFinder: { onOpenInFinder(path) },
                onAddFolder: onAddFolder,
                onRemove: { pinnedFolderStore.remove(path) },
                onSetSortOrder: { pinnedFolderStore.setSortOrder($0, for: path) },
                isDropTarget: dropTarget == .into(path),
                scale: scale,
                hoverStyle: settingsStore.hoverStyle,
                isHovered: hoveredPath == path && draggedPath == nil
            )
            Text(FileManager.default.displayName(atPath: path))
                .font(.system(size: CGFloat(settingsStore.columnLabelFontSize), weight: .bold, design: .rounded))
                .foregroundStyle(theme.labelActive.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, PanelLayoutMetrics.columnInset * scale)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .nativeContextMenu {
            PinnedFolderChip.menu(sortOrder: pinnedFolderStore.sortOrder(for: path),
                                  onPreview: { onOpen(path) },
                                  onOpenInFinder: { onOpenInFinder(path) },
                                  onSetSortOrder: { pinnedFolderStore.setSortOrder($0, for: path) },
                                  onAddFolder: onAddFolder,
                                  onRemove: { pinnedFolderStore.remove(path) })
        }
        .help(path)
        .onHover { inside in
            if inside { hoveredPath = path } else if hoveredPath == path { hoveredPath = nil }
        }
        .overlay(alignment: dropTarget == .pin(before: index) ? .top : .bottom) {
            if dropTarget == .pin(before: index) || dropTarget == .pin(before: index + 1) {
                Capsule().fill(Color.accentColor).frame(height: 3).padding(.horizontal, 8 * scale)
            }
        }
        .onDrop(of: [UTType.fileURL], delegate: FolderRowDropDelegate(
            path: path, index: index, rowHeight: rowHeight, target: $dropTarget,
            onMove: { onMoveFiles($0, path) },
            onPin: { urls, at in
                for (offset, url) in urls.enumerated() { pinnedFolderStore.insert(url.path, at: at + offset) }
            }))
        .offset(y: offset(index: index, count: paths.count))
        .zIndex(draggedPath == path ? 1 : 0)
        .animation(draggedPath == path ? nil : .easeOut(duration: 0.15), value: offset(index: index, count: paths.count))
        .simultaneousGesture(reorderGesture(path))
    }

    // MARK: Reordering

    private var isTapSuppressed: Bool {
        draggedPath != nil || Date().timeIntervalSince(reorderClock.endedAt) < 0.3
    }

    private func dropIndex(from: Int, count: Int) -> Int {
        min(max(from + Int((dragDistance / rowHeight).rounded()), 0), count - 1)
    }

    /// The dragged row follows the pointer; the rows it passes step aside.
    private func offset(index: Int, count: Int) -> CGFloat {
        guard let draggedPath, let from = pinnedFolderStore.folderPaths.firstIndex(of: draggedPath) else { return 0 }
        if index == from { return dragDistance }
        let to = dropIndex(from: from, count: count)
        if from < to, (from + 1...to).contains(index) { return -rowHeight }
        if to < from, (to..<from).contains(index) { return rowHeight }
        return 0
    }

    private func reorderGesture(_ path: String) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard pinnedFolderStore.folderPaths.count > 1 else { return }
                draggedPath = path
                dragDistance = value.translation.height
            }
            .onEnded { _ in
                let paths = pinnedFolderStore.folderPaths
                guard draggedPath == path, let from = paths.firstIndex(of: path) else { return }
                let to = dropIndex(from: from, count: paths.count)
                reorderClock.endedAt = Date()
                withAnimation(.easeOut(duration: 0.2)) {
                    // `insert(at:)` counts in the order before the move.
                    if to != from { pinnedFolderStore.insert(path, at: to > from ? to + 1 : to) }
                    draggedPath = nil
                    dragDistance = 0
                }
            }
    }
}

/// What a drag over the folder capsule would do on release.
enum FolderRowDropTarget: Equatable {
    /// Move the files into this folder.
    case into(String)
    /// Pin the dropped folders at this index.
    case pin(before: Int)
}

/// Files or folders from Finder over one row: the middle half moves them into the folder, the
/// top and bottom quarters pin folders before or after it. Only directories are pinned; a drop
/// on a quarter with no directory in it moves the files in.
private struct FolderRowDropDelegate: DropDelegate {
    let path: String
    let index: Int
    let rowHeight: CGFloat
    @Binding var target: FolderRowDropTarget?
    let onMove: ([URL]) -> Void
    let onPin: ([URL], Int) -> Void

    private func zone(_ info: DropInfo) -> FolderRowDropTarget {
        let y = info.location.y
        if y < rowHeight * 0.25 { return .pin(before: index) }
        if y > rowHeight * 0.75 { return .pin(before: index + 1) }
        return .into(path)
    }

    func dropEntered(info: DropInfo) { target = zone(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = zone(info)
        if target != next { target = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if target == zone(info) { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let landing = zone(info)
        target = nil
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [(Int, URL)] = []
        for (order, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = object as? URL {
                    lock.lock()
                    urls.append((order, url))
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let dropped = urls.sorted { $0.0 < $1.0 }.map(\.1)
            guard !dropped.isEmpty else { return }
            if case let .pin(before: at) = landing {
                let folders = dropped.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                if !folders.isEmpty {
                    onPin(folders, at)
                    return
                }
            }
            onMove(dropped)
        }
        return true
    }
}

/// The capsule panel's content: on a side edge with pinned folders, the folder capsule above the
/// drawer capsules; otherwise the drawer capsules alone.
struct CapsulePanelContent: View {
    @EnvironmentObject var pinnedFolderStore: PinnedFolderStore
    @EnvironmentObject var settingsStore: AppSettingsStore

    /// The drawer capsules; the flag says whether the folder capsule is above them.
    let drawers: (Bool) -> DrawerCapsuleStack
    let folders: (EdgeInsets) -> FolderCapsule

    var body: some View {
        let hasFolders = settingsStore.taskbarEdge.isVertical && !pinnedFolderStore.folderPaths.isEmpty
        if hasFolders {
            let outer = PanelCoordinator.shadowPadding
            VStack(spacing: 0) {
                folders(EdgeInsets(top: outer, leading: outer,
                                   bottom: settingsStore.panelLayoutMetrics.capsuleGap / 2, trailing: outer))
                drawers(true)
            }
        } else {
            drawers(false)
        }
    }
}
