import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drawer Capsules

/// One capsule per named drawer, in a row after a bottom bar or a column below a side bar.
/// Each capsule keeps the full shadow padding on its outer sides and half the capsule gap on the
/// sides it shares with a neighbour, so the stack lines up with `capsuleSlotFrame`.
struct DrawerCapsuleStack: View {
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var settingsStore: AppSettingsStore

    var onRequestMenu: (NSEvent, NSView, String) -> Void = { _, _, _ in }
    let usesLiquidGlass: Bool
    /// The capsule's drawer was toggled (the expand cell, or a cell with no app).
    let action: (String) -> Void
    let onPrimaryAction: () -> Void
    /// The pointer entered (true) or left (false) a capsule.
    var onHoverChanged: (String, Bool) -> Void = { _, _ in }

    /// The capsule being dragged to a new place, and how far along the stack it has moved.
    @State private var draggedID: String?
    @State private var dragDistance: CGFloat = 0
    /// When the last reorder drag ended: the mouse-up that ends it must not also count as a click.
    @State private var reorderClock = ReorderClock()

    final class ReorderClock { var endedAt = Date.distantPast }

    var body: some View {
        // Not `AnyLayout`: the app still runs on macOS 12.
        if settingsStore.taskbarEdge.isVertical {
            VStack(spacing: 0) { capsules(vertical: true) }
        } else {
            HStack(spacing: 0) { capsules(vertical: false) }
        }
    }

    /// Distance from one capsule to the next along the stack.
    private var pitch: CGFloat {
        let metrics = settingsStore.panelLayoutMetrics
        return metrics.capsuleWidth + metrics.capsuleGap
    }

    /// Where the dragged capsule would land now.
    private func dropIndex(from: Int, count: Int) -> Int {
        min(max(from + Int((dragDistance / pitch).rounded()), 0), count - 1)
    }

    /// The dragged capsule follows the pointer; the ones it passes step aside.
    private func offset(index: Int, drawers: [NamedDrawer]) -> CGFloat {
        guard let draggedID, let from = drawers.firstIndex(where: { $0.id == draggedID }) else { return 0 }
        if index == from { return dragDistance }
        let to = dropIndex(from: from, count: drawers.count)
        if from < to, (from + 1...to).contains(index) { return -pitch }
        if to < from, (to..<from).contains(index) { return pitch }
        return 0
    }

    /// Drag a capsule along the stack to reorder the drawers. Simultaneous, so a click on an
    /// app or the open button still works; a click never moves far enough to start a drag.
    private func reorderGesture(_ drawerID: String, vertical: Bool) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard drawerStore.drawers.count > 1 else { return }
                if draggedID == nil { onHoverChanged(drawerID, false) }
                draggedID = drawerID
                // Global coordinates grow down the screen, as the stack's order does.
                dragDistance = vertical ? value.translation.height : value.translation.width
            }
            .onEnded { _ in
                let drawers = drawerStore.drawers
                guard draggedID == drawerID, let from = drawers.firstIndex(where: { $0.id == drawerID }) else { return }
                let to = dropIndex(from: from, count: drawers.count)
                reorderClock.endedAt = Date()
                withAnimation(.easeOut(duration: 0.2)) {
                    drawerStore.moveDrawer(drawerID, to: to)
                    draggedID = nil
                    dragDistance = 0
                }
            }
    }

    private func capsules(vertical: Bool) -> some View {
        let drawers = drawerStore.drawers
        return ForEach(Array(drawers.enumerated()), id: \.element.id) { index, drawer in
            DrawerCapsuleButton(
                drawerID: drawer.id,
                isRow: vertical,
                edgePadding: padding(index: index, count: drawers.count, vertical: vertical),
                onRequestTaskbarMenu: { event, view in onRequestMenu(event, view, drawer.id) },
                usesLiquidGlass: usesLiquidGlass,
                action: { action(drawer.id) },
                onPrimaryAction: onPrimaryAction,
                onHoverChanged: { onHoverChanged(drawer.id, $0) },
                isTapSuppressed: { [reorderClock] in
                    draggedID != nil || Date().timeIntervalSince(reorderClock.endedAt) < 0.3
                }
            )
            .offset(x: vertical ? 0 : offset(index: index, drawers: drawers),
                    y: vertical ? offset(index: index, drawers: drawers) : 0)
            .zIndex(draggedID == drawer.id ? 1 : 0)
            .animation(draggedID == drawer.id ? nil : .easeOut(duration: 0.15),
                       value: offset(index: index, drawers: drawers))
            .simultaneousGesture(reorderGesture(drawer.id, vertical: vertical))
        }
    }

    private func padding(index: Int, count: Int, vertical: Bool) -> EdgeInsets {
        let outer = PanelCoordinator.shadowPadding
        let inner = settingsStore.panelLayoutMetrics.capsuleGap / 2
        let leading = index == 0 ? outer : inner
        let trailing = index == count - 1 ? outer : inner
        return vertical
            ? EdgeInsets(top: leading, leading: outer, bottom: trailing, trailing: outer)
            : EdgeInsets(top: outer, leading: leading, bottom: outer, trailing: trailing)
    }
}

// MARK: - Drawer Capsule Button

struct DrawerCapsuleButton: View {
    @Environment(\.isPanelHeightResizing) private var isPanelHeightResizing
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var runningApplicationStore: RunningApplicationStore
    @EnvironmentObject var drawerOrderStore: DrawerOrderStore
    @EnvironmentObject var settingsStore: AppSettingsStore
    /// 拖卡进抽屉的投放反馈：手指压在投放区时胶囊放大 + 高亮描边。
    @EnvironmentObject var dragController: DragController
    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }
    /// The named drawer this capsule shows and opens.
    let drawerID: String
    /// Below a side bar the capsule is a row as wide as the bar: as many full-size icons as fit,
    /// each clickable, then a button that opens the whole drawer. Otherwise the 2 × 2 preview.
    let isRow: Bool
    /// Transparent room around the visible capsule (`DrawerCapsuleStack.padding`).
    let edgePadding: EdgeInsets
    /// 右键胶囊 → 弹钨极菜单。胶囊是设置的**主要后路入口**：它恒在、位置固定、尺寸等于面板高度，
    /// 而且是钨极自己的部件（不属于任何 app），不像任务条底板那样只剩几条缝可点。
    var onRequestTaskbarMenu: (NSEvent, NSView) -> Void = { _, _ in }
    /// 底板走不走原生 Liquid Glass。**显式传入、无默认值**（同 `scale` / `hoverStyle`）——
    /// 胶囊是另一棵长期存活的 hosting 根视图，漏传就会出现「条是玻璃、紧挨着的胶囊还是
    /// 毛玻璃」这种一眼可见的不一致。
    let usesLiquidGlass: Bool
    /// Toggles the full drawer: the bottom-trailing cell, and any cell that holds no app.
    let action: () -> Void
    /// An app cell dispatched an "open" (launch / unhide): an open drawer closes, exactly as
    /// after a tap inside it. No default — an omission would leave the drawer open.
    let onPrimaryAction: () -> Void
    /// The pointer entered (true) or left (false) the capsule: its drawer's name shows meanwhile.
    var onHoverChanged: (Bool) -> Void = { _ in }
    /// True while (or just after) the capsule is dragged to reorder: a click then does nothing.
    var isTapSuppressed: () -> Bool = { false }

    /// Cells are numbered row-major, 0...3; the last one is the expand cell.
    @State private var hoveredCell: Int?
    /// Press feedback per cell: a pure view-level signal, never fed to planner / frontmost.
    @State private var pressedCell: Int?
    /// Which page of the drawer the capsule shows; per capsule, so per screen.
    @StateObject private var pager = DrawerCapsulePager()

    private var iconSize: CGFloat { DrawerCapsulePreviewMetrics.iconSize * dockScale }

    /// Every visible drawer app in the order the open drawer reads (`DrawerView.visibleMembers`):
    /// drawer order alone, never regrouped by running state, or the capsule pages disagree with
    /// the drawer.
    private var memberIDs: [String] {
        let placements = AppMembershipProjection.drawerMembers(drawerIDs: drawerStore.bundleIDs)
        return AppMembershipProjection.visibleDrawerIDs(
            drawerIDs: drawerStore.members(drawerOrderStore.reconciled(members: placements), inDrawer: drawerID),
            keptIDs: keptAppStore.bundleIDs,
            runningIDs: runningApplicationStore.runningBundleIDs
        )
    }

    private var capsuleSide: CGFloat { settingsStore.dockPanelHeight.metrics.capsuleWidth }

    /// 胶囊是**另一棵**长期存活的 NSHostingView 根视图，必须自己观察同一个 store，
    /// 否则换档时任务条变了、胶囊里的四宫格还停在旧尺寸。
    private var dockScale: CGFloat { settingsStore.dockPanelHeight.scale }

    /// While a card is dragged, hover gives way to the drop feedback (the drag wins).
    private var hoverEnabled: Bool { !isPanelHeightResizing && dragController.draggingPayload == nil }

    private var backgroundLayers: (glass: Double, plate: Double) {
        TaskbarBackgroundOpacity.layers(for: settingsStore.taskbarBackgroundOpacity)
    }

    var body: some View {
        let ids = memberIDs
        let pageCount = DrawerCapsulePaging.pageCount(memberCount: ids.count)
        let page = DrawerCapsulePaging.clampedPage(pager.page, pageCount: pageCount)
        // Clicks, hover and press follow the page nearest to what is on screen, which differs from
        // the resting page while a trackpad gesture holds the capsule on its neighbour.
        let hitPage = DrawerCapsulePaging.hitPage(page: pager.page, drag: pager.drag, pageCount: pageCount)
        let apps = DrawerCapsulePaging.apps(page: hitPage, members: ids)
        return ZStack {
            DockPanelBackdrop(theme: theme,
                              cornerRadius: DockShape.panelCornerRadius * dockScale,
                              usesLiquidGlass: usesLiquidGlass,
                              matchesDockRefraction: true)
                .opacity(backgroundLayers.glass)   // same setting as the bar
            RoundedRectangle(cornerRadius: DockShape.panelCornerRadius * dockScale, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .opacity(backgroundLayers.plate)

            // Hover and press feedback move only the cell under the pointer; the outer frame
            // (backdrop + rim) stays still.
            if isRow {
                rowPreview(ids: ids)
            } else if ids.isEmpty {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 20 * dockScale, weight: .medium))
                    .foregroundStyle(theme.capsuleGlyph.color)
                    .cellFeedback(hovered: hoverEnabled && hoveredCell != nil, pressed: pressedCell != nil)
            } else {
                pagedPreview(ids: ids, pageCount: pageCount, page: page, hitPage: hitPage)
            }
        }
        .dockPanelRim(cornerRadius: DockShape.panelCornerRadius * dockScale,
                      style: theme.panelRimStyle,
                      lineWidth: theme.panelRimLineWidth,
                      usesLiquidGlass: usesLiquidGlass)
        // 拖卡悬到胶囊上：**微微发光 + 极轻微放大**（去掉原来生硬的白圈描边,owner 2026-06-21）。
        .scaleEffect(isDropTarget ? 1.04 : 1.0)
        .dockGlow(theme.capsuleStashGlow, radius: 5, active: isDropTarget)
        .animation(.easeInOut(duration: DrawerAnimation.duration), value: isDropTarget)
        .dockShadow(theme.stripShadow,
                    visible: DockLiquidGlassConfiguration.stripShadowVisible(
                        usesLiquidGlass: usesLiquidGlass,
                        usesSystemVariant: DockGlassPresentation.usesSystemVariant))
        .padding(edgePadding)
        // The hit cells split the whole padded frame into quadrants, so each target is as large
        // as the capsule allows and reaches the screen edge.
        .overlay(isRow ? AnyView(rowHits(ids: ids)) : AnyView(hitGrid(apps: apps)))
        // Takes scroll events only (see `DrawerCapsuleScrollView.hitTest`); clicks fall through.
        .overlay(DrawerCapsuleScrollReceiver(enabled: !isRow && hoverEnabled && pageCount > 1) { event in
            switch event {
            case .step(let direction): pager.step(direction, pageCount: pageCount)
            case .drag(let points): pager.drag(points: points, side: capsuleSide)
            case .dragEnded: pager.endDrag(pageCount: pageCount)
            }
        })
        // The three slots are worth their fixed places: once the pointer has left, the capsule
        // goes back to the first page.
        .onChange(of: hoveredCell == nil) { away in
            pager.pointerAway = away
            onHoverChanged(!away)
        }
        // MenuHostNSView takes only right / Control-clicks and lets left clicks through to the
        // cells above, so a right click anywhere on the capsule is the Tungsten menu — the
        // settings fallback entry keeps the whole capsule.
        .overlay(NativeMenuHost(popUpHandler: onRequestTaskbarMenu))
    }

    /// A drag would file into this capsule's drawer: the pointer is over a drop zone and this
    /// drawer is the one a drop goes to.
    private var isDropTarget: Bool {
        dragController.isOverStashZone && drawerStore.activeDrawerID == drawerID
    }

    // MARK: Row

    /// The row's cell pitch: a bare icon card's slot, as on the bar.
    private var rowSlot: CGFloat { ChipPillMetrics.bareIconSlot * dockScale }
    /// Space before the first icon: centres a slot across the capsule's height.
    private var rowInset: CGFloat { (capsuleSide - rowSlot) / 2 }
    private var rowWidth: CGFloat { settingsStore.panelLayoutMetrics.columnWidth }

    /// The apps the row shows: as many as fit, leaving the last slot to the open-drawer button.
    private func rowApps(_ ids: [String]) -> [String] {
        let slots = Int((rowWidth - 2 * rowInset) / rowSlot)
        return Array(ids.prefix(max(slots - 1, 0)))
    }

    private func rowPreview(ids: [String]) -> some View {
        let apps = rowApps(ids)
        let expandCell = apps.count
        return HStack(spacing: 0) {
            ForEach(Array(apps.enumerated()), id: \.element) { index, id in
                DrawerCapsuleAppIcon(bundleID: id,
                                     size: ChipPillMetrics.bareIconVisibleSlot * dockScale,
                                     bounceHeight: DrawerCapsulePreviewMetrics.bounceHeight * dockScale,
                                     isLaunching: runtime.launchingBundleIDs.contains(id))
                    .cellFeedback(hovered: hoverEnabled && hoveredCell == index, pressed: pressedCell == index)
                    .frame(width: rowSlot, height: rowSlot)
            }
            Spacer(minLength: 0)
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 18 * dockScale, weight: .medium))
                .foregroundStyle(theme.capsuleGlyph.color)
                .cellFeedback(hovered: hoverEnabled && hoveredCell == expandCell,
                              pressed: pressedCell == expandCell)
                .frame(width: rowSlot, height: rowSlot)
        }
        .padding(.horizontal, rowInset)
        .frame(width: rowWidth, height: capsuleSide)
    }

    /// One cell per shown app, reaching across the whole padded height; the rest of the row
    /// (the gap and the button at its end) opens the drawer.
    private func rowHits(ids: [String]) -> some View {
        let apps = rowApps(ids)
        return HStack(spacing: 0) {
            ForEach(Array(apps.enumerated()), id: \.element) { index, id in
                hitCell(index, bundleID: id)
                    .frame(width: rowSlot + (index == 0 ? edgePadding.leading + rowInset : 0))
            }
            hitCell(apps.count, bundleID: nil)
        }
    }

    // MARK: Preview

    /// Every app is one icon that lives through the whole scroll and is posed by the position
    /// (`DrawerCapsulePaging.pose`): turning forward, the mini icons grow and travel onto the three
    /// app cells, replacing the apps there, and the next ones grow into the mini grid. Nothing is
    /// clipped and nothing fades.
    private func pagedPreview(ids: [String], pageCount: Int, page: Int, hitPage: Int) -> some View {
        let side = capsuleSide
        let position = DrawerCapsulePaging.displayedPosition(page: page, drag: pager.drag, pageCount: pageCount)
        let hitApps = DrawerCapsulePaging.apps(page: hitPage, members: ids).count
        let expandActive = { (cell: Int?) in cell.map { $0 >= hitApps } == true }
        let appSlots = DrawerCapsulePreviewMetrics.appSlots
        // Past the last app the expand cell stays empty (no glyph) and still opens the drawer.
        return ZStack {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                // Press goes to the icons the click page holds: an app cell dips its own app, the
                // expand cell (or an app-less cell) the whole mini grid. Hover follows the same
                // split but is resolved by `DrawerCapsuleFlow`, against what is on screen.
                let slot = index - hitPage * appSlots
                let isApp = (0..<appSlots).contains(slot)
                let isMini = (appSlots..<DrawerCapsulePreviewMetrics.limit).contains(slot)
                DrawerCapsuleAppIcon(bundleID: id,
                                     size: iconSize,
                                     bounceHeight: DrawerCapsulePreviewMetrics.bounceHeight * dockScale,
                                     isLaunching: isApp && runtime.launchingBundleIDs.contains(id))
                    .chipPressScale(isApp ? pressedCell == slot : isMini && expandActive(pressedCell))
                    .modifier(DrawerCapsuleFlow(index: index, position: position, side: side, unit: dockScale,
                                                hoveredCell: hoverEnabled ? hoveredCell : nil,
                                                memberCount: ids.count))
            }
        }
        .frame(width: side, height: side)
    }

    // MARK: Hit cells

    private func hitGrid(apps: [String]) -> some View {
        let columns = DrawerCapsulePreviewMetrics.columns
        return VStack(spacing: 0) {
            ForEach(0..<columns, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        hitCell(index, bundleID: index < apps.count ? apps[index] : nil)
                    }
                }
            }
        }
    }

    private func hitCell(_ index: Int, bundleID: String?) -> some View {
        let isLaunching = bundleID.map { runtime.launchingBundleIDs.contains($0) } ?? false
        // Mid-turn an app slot shows the leaving and the arriving page at once, whatever the
        // arriving page holds there (an app or nothing): a click then would be a guess. Gated by
        // slot, not by content; the expand cell never changes meaning and stays live.
        let isMidTurn = index < DrawerCapsulePreviewMetrics.appSlots && pager.isTurning
        return Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { hoveredCell = index } else if hoveredCell == index { hoveredCell = nil }
            }
            .onTapGesture {
                guard !isMidTurn, !isTapSuppressed() else { return }
                if let bundleID { activate(bundleID) } else { action() }
            }
            // A tap during a launch session or a turn is a no-op, so it gets no press feedback either.
            .chipPressGesture(
                isPressed: Binding(
                    get: { pressedCell == index },
                    set: { pressed in
                        if pressed { pressedCell = index } else if pressedCell == index { pressedCell = nil }
                    }),
                isEnabled: !isLaunching && !isMidTurn
            )
            .help(bundleID.map { AppDisplayNameResolver.displayName(for: $0) } ?? "")
    }

    /// Same default tap as a drawer icon: launch / bring forward / hide when frontmost.
    private func activate(_ bundleID: String) {
        guard !runtime.launchingBundleIDs.contains(bundleID) else { return }
        let finderHasRealWindow = FinderTaskbarPolicy.isFinder(bundleID)
            && StripItem.items(from: runtime.snapshot).contains {
                $0.bundleIdentifier == bundleID && !$0.isAppLevelFallback
            }
        LauncherChip.performDefaultTap(
            bundleID: bundleID,
            isRunning: runningApplicationStore.isRunning(bundleID),
            finderHasRealWindow: finderHasRealWindow,
            launch: { if runtime.beginLaunch(bundleID) { onPrimaryAction() } },
            onOpen: onPrimaryAction
        )
    }
}

private extension View {
    /// Hover grows the cell in place, press dips it; both settle back exactly.
    func cellFeedback(hovered: Bool, pressed: Bool) -> some View {
        scaleEffect(hovered ? DrawerCapsulePreviewMetrics.hoverScale : 1.0)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .chipPressScale(pressed)
    }
}

/// Places one app's icon by the capsule's position. The position is the animatable value, so a
/// spring between two pages moves the icon along its blend frame by frame.
private struct DrawerCapsuleFlow: ViewModifier, Animatable {
    let index: Int
    var position: CGFloat
    let side: CGFloat
    let unit: CGFloat
    /// Nil while hover is disabled.
    let hoveredCell: Int?
    let memberCount: Int

    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    func body(content: Content) -> some View {
        let pose = DrawerCapsulePaging.endPullPose(index: index, position: position, memberCount: memberCount)
            ?? DrawerCapsulePaging.pose(index: index, position: position)
        // Hover is judged and scaled by the position on screen, so a turn hands it from one icon
        // to the next while neither is lifted. The timed animation only runs when the pointer
        // moves between cells; mid-turn the flag flips where the lift is already zero.
        let hovered = DrawerCapsulePaging.isHovered(index: index, position: position,
                                                    hoveredCell: hoveredCell, memberCount: memberCount)
        let lift = hovered
            ? 1 + (DrawerCapsulePreviewMetrics.hoverScale - 1) * DrawerCapsulePaging.hoverCalm(position: position)
            : 1
        content
            .scaleEffect(lift)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .scaleEffect(pose.size / DrawerCapsulePreviewMetrics.iconSize)
            .position(x: side / 2 + pose.x * unit, y: side / 2 + pose.y * unit)
            // The later app is always on top: turning forward the arriving icon covers the app it
            // replaces; turning back the leaving one shrinks away over the app coming back.
            .zIndex(Double(index))
            .opacity(pose.size > 0 ? 1 : 0)
    }
}

// MARK: - Capsule Paging

/// Where the capsule rests (`page`) and how far a live trackpad gesture has pulled it (`drag`).
/// The page is not clamped here — the member list changes underneath it — the view clamps on read.
@MainActor
final class DrawerCapsulePager: ObservableObject {
    @Published private(set) var page = 0
    @Published private(set) var drag: CGFloat = 0
    /// True from the moment a turn is committed until its spring has visibly settled. App cells
    /// ignore clicks meanwhile: the click page has already moved on while the old icons are
    /// still the larger ones on screen.
    @Published private(set) var isTurning = false
    private var turnTimer: Timer?
    private var returnTimer: Timer?
    /// Whether the pointer is off the capsule. Kept here, not only reacted to, because a turn can
    /// settle after the pointer has already left — the return must be armed at that point too.
    var pointerAway = true {
        didSet {
            guard pointerAway != oldValue else { return }
            if pointerAway { scheduleReturn() } else { cancelReturn() }
        }
    }

    /// Turn springs are critically damped: any overshoot past a page plays the start of the next
    /// turn, which reads as the capsule moving again just after it landed. A wheel notch plays the
    /// whole handover on its own; a trackpad release has the fingers' travel behind it.
    private static let wheelTurn = Animation.spring(response: 0.38, dampingFraction: 1)
    private static let releaseTurn = Animation.spring(response: 0.32, dampingFraction: 1)
    private static let returnHome = Animation.spring(response: 0.5, dampingFraction: 0.9)
    private static let returnDelay: TimeInterval = 3
    /// By now the arriving icons are within about a point of rest for the turn springs, and the
    /// apps they replace have shrunk to nothing.
    private static let turnSettle: TimeInterval = 0.3

    deinit {
        returnTimer?.invalidate()
        turnTimer?.invalidate()
    }

    /// Commits a turn to `target`; gates app clicks only when the page really changes.
    private func turn(to target: Int, from shown: Int, animation: Animation) {
        if target != shown {
            isTurning = true
            turnTimer?.invalidate()
            let timer = Timer(timeInterval: Self.turnSettle, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.turnTimer = nil
                    self?.isTurning = false
                }
            }
            turnTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        withAnimation(animation) {
            page = target
            drag = 0
        }
    }

    /// A wheel notch: one page, animated.
    func step(_ direction: Int, pageCount: Int) {
        let shown = DrawerCapsulePaging.clampedPage(page, pageCount: pageCount)
        turn(to: DrawerCapsulePaging.clampedPage(shown + direction, pageCount: pageCount),
             from: shown, animation: Self.wheelTurn)
        if pointerAway { scheduleReturn() }
    }

    /// Trackpad travel follows the fingers frame by frame, so it is never animated.
    func drag(points: CGFloat, side: CGFloat) {
        guard side > 0, points.isFinite else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drag = min(max(drag - points / side, -1), 1)
        }
    }

    func endDrag(pageCount: Int) {
        // The click page before release is the one nearest to what is shown; only a release that
        // lands elsewhere changes what a click would hit.
        let shown = DrawerCapsulePaging.hitPage(page: page, drag: drag, pageCount: pageCount)
        turn(to: DrawerCapsulePaging.settledPage(page: page, drag: drag, pageCount: pageCount),
             from: shown, animation: Self.releaseTurn)
        if pointerAway { scheduleReturn() }
    }

    private func scheduleReturn() {
        returnTimer?.invalidate()
        guard page != 0 else { return }
        let timer = Timer(timeInterval: Self.returnDelay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.returnTimer = nil
                self.turn(to: 0, from: self.page, animation: Self.returnHome)
            }
        }
        returnTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelReturn() {
        returnTimer?.invalidate()
        returnTimer = nil
    }
}

enum DrawerCapsuleScrollEvent {
    /// A wheel notch: -1 = previous page, 1 = next.
    case step(Int)
    /// Trackpad travel in points, in the system's content direction.
    case drag(CGFloat)
    case dragEnded
}

struct DrawerCapsuleScrollReceiver: NSViewRepresentable {
    let enabled: Bool
    let onEvent: (DrawerCapsuleScrollEvent) -> Void

    func makeNSView(context: Context) -> DrawerCapsuleScrollView { DrawerCapsuleScrollView() }

    func updateNSView(_ view: DrawerCapsuleScrollView, context: Context) {
        view.onEvent = onEvent
        view.enabled = enabled
    }

    static func dismantleNSView(_ view: DrawerCapsuleScrollView, coordinator: ()) { view.finishTracking() }
}

final class DrawerCapsuleScrollView: NSView {
    var onEvent: (DrawerCapsuleScrollEvent) -> Void = { _ in }
    var enabled = true {
        didSet { if oldValue && !enabled { finishTracking() } }
    }
    private var isTracking = false
    private var lastStepTime: TimeInterval = 0
    private var watchdog: Timer?

    /// Fast wheel spins turn several pages, but never faster than one page per interval.
    private static let stepInterval: TimeInterval = 0.12
    /// A gesture whose end never arrives (the pointer left the capsule mid-swipe) still settles.
    /// Resting fingers send no events either, so the watchdog only ends a gesture once the
    /// pointer is off the capsule.
    private static let trackingTimeout: TimeInterval = 0.3

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard enabled, super.hitTest(point) != nil,
              let event = NSApp.currentEvent, event.type == .scrollWheel else { return nil }
        // End events carry zero deltas and still belong to this gesture.
        return abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard enabled else { return }
        // Paging settles on its own spring; the system's momentum tail would turn a second page.
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.isEmpty {
            let delta = event.scrollingDeltaY
            guard delta != 0, event.timestamp - lastStepTime >= Self.stepInterval else { return }
            lastStepTime = event.timestamp
            onEvent(.step(delta > 0 ? -1 : 1))
            return
        }
        if event.phase.contains(.began) { isTracking = true }
        guard isTracking else { return }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            finishTracking()
            return
        }
        if event.scrollingDeltaY != 0 { onEvent(.drag(event.scrollingDeltaY)) }
        armWatchdog()
    }

    private func armWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: Self.trackingTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.isPointerInside { self.armWatchdog() } else { self.finishTracking() }
        }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private var isPointerInside: Bool {
        guard let window else { return false }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return bounds.contains(convert(inWindow, from: nil))
    }

    func finishTracking() {
        watchdog?.invalidate()
        watchdog = nil
        guard isTracking else { return }
        isTracking = false
        onEvent(.dragEnded)
    }

    deinit { watchdog?.invalidate() }
}

// MARK: - Capsule App Icon

/// One directly clickable app in the capsule. Owns only the launch bounce; hover and press
/// are applied by the capsule, which owns the hit cells.
private struct DrawerCapsuleAppIcon: View {
    let bundleID: String
    let size: CGFloat
    let bounceHeight: CGFloat
    /// Runtime-owned launch session state, rendered only (same contract as `LauncherChip`).
    let isLaunching: Bool

    @State private var bounceUp = false
    @State private var bounceTimer: Timer?

    var body: some View {
        Image(nsImage: AppIconResolver.icon(for: bundleID))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .offset(y: bounceUp ? -bounceHeight : 0)
            .animation(.easeInOut(duration: 0.25), value: bounceUp)
            .onAppear { if isLaunching { startBounce() } }
            .onDisappear { stopBounce() }
            .onChange(of: isLaunching) { launching in
                if launching { startBounce() } else { stopBounce() }
            }
    }

    /// Finite legs scheduled by a common-mode timer, as in `LauncherChip`: a hover or layout
    /// transaction cannot turn the bounce into one that outlives the launch.
    private func startBounce() {
        guard bounceTimer == nil else { return }
        bounceUp = true
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in bounceUp.toggle() }
        timer.tolerance = 0.02
        bounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopBounce() {
        bounceTimer?.invalidate()
        bounceTimer = nil
        bounceUp = false
    }
}
