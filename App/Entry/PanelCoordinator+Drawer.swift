import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · 抽屉：开合、host 复用、拖动投放区几何、弹簧文件夹自动弹开。
// 2026-09-05 从 PanelCoordinator.swift 按 extension 拆出，只搬不改。
extension PanelCoordinator {
    func openDrawer() {
        guard let mainPanel = dockPanel, capsulePanel != nil else { return }
        onAccessoryWillOpen?(self, .drawer)
        drawerActionCloseToken += 1  // 旧点击排队的 delayed close 捕获旧 token，不匹配则丢弃
        drawerWantsOpen = true
        setAutoHideInhibitor(.drawerOpen, active: true)
        drawerSpringOpened = false   // 默认手动开；弹簧路径在 springOpenDrawer 里再置 true

        let screen = panelCurrentScreen(panel: mainPanel)
        let (capsuleRef, limits) = drawerAnchor(on: screen)

        // 宿主只建一次；之后打开只在可用高度变了才换 rootView。
        // 各阶段打 `HoverTrace.action("drawerOpen")` 标记：打开这一转的主线程停顿由哪段贡献，只有它能分出来。
        HoverTrace.action("drawerOpen", phase: "begin")
        guard let host = ensureDrawerHost(limits: limits) else { return }
        let (panel, hosting) = host
        HoverTrace.action("drawerOpen", phase: "host")

        // 首帧就位（owner 2026-07-06「不丝滑」主因之一）：orderFront **前**同步量真实尺寸,
        // 首帧即最终大小,不再「旧尺寸弹出→瞬间校正」。量不到合理值退回 lastDrawerSize,
        // 后面的 double-defer 复测仍在,作兜底校正。
        panel.layoutIfNeeded()
        HoverTrace.action("drawerOpen", phase: "layout")
        let sync = hosting.fittingSize
        HoverTrace.action("drawerOpen", phase: "fitting")
        if Self.isPlausibleDrawerSize(sync) {
            lastDrawerSize = sync
        }
        let initialFrame = drawerTargetFrame(forCapsule: capsuleRef, size: lastDrawerSize, on: screen)
        lastDrawerTargetFrame = initialFrame

        panel.setFrame(initialFrame, display: false)
        syncDrawerArrow(after: .instant)
        // The arrow's position was only known with the frame: lay it out before the first show.
        hosting.layoutSubtreeIfNeeded()
        // 打开无动画（owner 2026-09-04，理由见 `DrawerView` 与 `Docs/27`）：直接以 alpha 1 上屏。
        // 淡出中途重开也直接回到 1；`closeDrawer` 的 completion 有 `!drawerWantsOpen` 守卫，不会把它 orderOut。
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        HoverTrace.action("drawerOpen", phase: "ordered")
        pinOverlappingPanelIfNeeded(panel)
        HoverTrace.action("drawerOpen", phase: "shown")
        // 弹出后复测 fittingSize 重新布局（瞬时,刚弹出不滑）——同步量偏差时的兜底校正。
        DispatchQueue.main.async { [weak self] in
            HoverTrace.action("drawerOpen", phase: "turn1")
            DispatchQueue.main.async { [weak self] in
                HoverTrace.action("drawerOpen", phase: "turn2")
                self?.relayout(animated: false)
            }
        }

        removeDrawerMonitors()   // reopened without a close in between: never stack a second set
        drawerLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.dismissDrawerIfOutside()
            return event
        }
        drawerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dismissDrawerIfOutside()
        }
        drawerMoveMonitors = [
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.dismissDrawerIfPointerFar()
                return event
            } as Any,
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                self?.dismissDrawerIfPointerFar()
            } as Any,
        ]
    }

    /// 抽屉的定位输入：胶囊**目标** frame（不读 live：用户可能在任务条宽度动画中触发弹簧开抽屉,Codex 二审 P1）
    /// 和网格的行列上限 = 胶囊上方到屏幕上沿放得下多少。超出由网格在底板里滚动,
    /// 绝不靠下压底边来塞下（否则压向胶囊/任务条 = 重叠,Codex 二审第 4 点）。
    /// 顶部上限仍避让菜单栏 / 刘海；底部锚点不避让原生 Dock，避免 Command+Option+D 或侧边 Dock 推动抽屉。
    private func drawerAnchor(on screen: NSScreen) -> (capsuleRef: NSRect, limits: StackGridLayout.Limits) {
        let screenGeometry = Self.screenGeometry(screen)
        let group = lastCapsuleTargetFrame == .zero ? (capsulePanel?.frame ?? .zero) : lastCapsuleTargetFrame
        let capsuleRef = group == .zero ? group : activeCapsuleFrame(inGroup: group)
        return (capsuleRef, PanelGeometry.drawerGridLimits(forCapsule: capsuleRef, on: screenGeometry,
                                                           metrics: layoutMetrics, edge: taskbarEdge))
    }

    /// Smaller than any plate means the host has not laid out yet, never a real size.
    static func isPlausibleDrawerSize(_ size: CGSize) -> Bool { size.width >= 160 && size.height >= 100 }

    /// The drawer's visible part for a window frame: plate plus arrow strip, without the 40pt
    /// transparent border.
    static func drawerPlateFrame(_ panelFrame: NSRect) -> CGRect {
        PanelGeometry.folderPopupPlateFrame(panelFrame: panelFrame)
    }

    // MARK: - Capsules

    /// Each drawer's capsule frame inside the capsule panel's frame `group`, padded like a panel.
    func capsuleSlots(inGroup group: NSRect) -> [(drawerID: String, frame: NSRect)] {
        drawerStore.drawers.enumerated().map { index, drawer in
            (drawer.id, PanelGeometry.capsuleSlotFrame(index: index, inGroup: group,
                                                       metrics: layoutMetrics, edge: taskbarEdge))
        }
    }

    /// The active drawer's capsule: what the open drawer, its arrow and a stash flight aim at.
    func activeCapsuleFrame(inGroup group: NSRect) -> NSRect {
        let slots = capsuleSlots(inGroup: group)
        return (slots.first { $0.drawerID == drawerStore.activeDrawerID } ?? slots.first)?.frame ?? group
    }

    /// The drawer whose capsule's spring zone holds `point` (target frames), if any.
    func capsuleDrawerID(at point: CGPoint) -> String? {
        guard lastCapsuleTargetFrame != .zero else { return nil }
        return capsuleSlots(inGroup: lastCapsuleTargetFrame).first { springZone($0.frame).contains(point) }?.drawerID
    }

    /// The pointer entered or left a capsule: show its drawer's name in the title bubble.
    /// `title` = what the pointer is over (an app's name, or the drawer's); nil = it left.
    func drawerCapsuleHoverChanged(_ drawerID: String, title: String?) {
        let chipID = "drawer-capsule-\(drawerID)"
        guard let title else {
            handleWindowTitleTooltipEvent(.exit(chipID: chipID))
            return
        }
        guard dragController.draggingPayload == nil,
              let group = capsulePanel?.frame,
              let slot = capsuleSlots(inGroup: group).first(where: { $0.drawerID == drawerID }) else { return }
        let visible = slot.frame.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)
        handleWindowTitleTooltipEvent(.update(WindowTitleTooltipRequest(
            chipID: chipID, title: title, anchorVisibleRect: visible)))
    }

    // MARK: - Arrow

    /// The single writer of the drawer arrow's offset, keyed on what `setFrames` actually did
    /// with the drawer's frame — never on "layout ran" or the `animated` it was asked for:
    /// - `.animated`: sync from the two panels' live frames now and keep following every tick
    ///   until the animation's end (`animatedFramesUntil`), then land on the target. A plate
    ///   clamped at the screen edge moves against its capsule for the whole animation; writing
    ///   the end value at once takes the arrow up to ~64pt off the capsule.
    /// - `.unchanged`: nothing. Same targets does not mean the running animation is over.
    /// - `.instant`: stop following, write the target.
    /// Live frames here only draw the arrow; no panel is ever positioned from them.
    func syncDrawerArrow(after commit: FrameCommit) {
        switch commit {
        case .unchanged:
            return
        case .instant:
            stopDrawerArrowFollow()
            writeDrawerArrow(live: false)
        case .animated:
            writeDrawerArrow(live: true)
            guard drawerArrowFollowTimer == nil else { return }   // one timer; the deadline is read per tick
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.drawerArrowFollowTimer != nil else { return }
                    if CACurrentMediaTime() >= self.animatedFramesUntil {
                        self.stopDrawerArrowFollow()
                        self.writeDrawerArrow(live: false)
                    } else {
                        self.writeDrawerArrow(live: true)
                    }
                }
            }
            drawerArrowFollowTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stopDrawerArrowFollow() {
        drawerArrowFollowTimer?.invalidate()
        drawerArrowFollowTimer = nil
    }

    private func writeDrawerArrow(live: Bool) {
        let group = live ? capsulePanel?.frame : lastCapsuleTargetFrame
        let drawer = live ? drawerPanel?.frame : lastDrawerTargetFrame
        guard let group, let drawer, group != .zero, drawer != .zero else { return }
        let capsule = activeCapsuleFrame(inGroup: group)
        let offset = capsule.midX - drawer.midX   // the capsule's visible rect is inset symmetrically
        if drawerArrow.offsetFromCenter != offset { drawerArrow.offsetFromCenter = offset }
        let hidden = taskbarEdge.isVertical
        if drawerArrow.isHidden != hidden { drawerArrow.isHidden = hidden }
    }

    private func makeDrawerRootView(limits: StackGridLayout.Limits) -> DrawerRootView {
        DrawerRootView(limits: limits,
                       arrow: drawerArrow,
                       // Next main-loop turn: `fittingSize` reads zero inside the SwiftUI update
                       // that reports the new size; `layoutPanels` measures it outside.
                       onPanelSizeChange: { [weak self] _ in
                           DispatchQueue.main.async { [weak self] in
                               guard let self, self.drawerWantsOpen else { return }
                               self.relayout(animated: true)
                           }
                       },
                       usesLiquidGlass: usesLiquidGlass,
                       isDrawerOpen: { [weak self] in self?.drawerPanel?.isVisible == true },
                       taskbarEdge: { [weak self] in self?.taskbarEdge ?? .default },
                       onPrimaryAction: { [weak self] in self?.closeDrawerAfterAction() },
                       runtime: runtime, drawerStore: drawerStore, messagingStore: messagingStore,
                       drawerOrderStore: drawerOrderStore, dragController: dragController,
                       keptAppStore: keptAppStore, runningApplicationStore: runningApplicationStore,
                       appMembershipController: appMembershipController)
    }

    /// 抽屉面板 + SwiftUI 宿主，**只建一次**；之后只在行列上限变了才换 rootView。
    /// 2026-09-04 之前每次打开都现建一棵视图树，主线程停顿 55～135ms 压在淡入开头（弹开掉帧主因）。
    private func ensureDrawerHost(limits: StackGridLayout.Limits) -> (NSPanel, NSHostingView<DrawerRootView>)? {
        if drawerPanel == nil {
            let panel = makeFloatingPanel(
                contentRect: NSRect(origin: .zero, size: lastDrawerSize),
                usesLiquidGlass: usesLiquidGlass
            )
            configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: false)
            drawerPanel = panel
        }
        guard let panel = drawerPanel else { return nil }

        if let hosting = drawerHosting {
            if drawerHostedLimits != limits {
                hosting.rootView = makeDrawerRootView(limits: limits)
                drawerHostedLimits = limits
            }
            return (panel, hosting)
        }

        let hosting = NSHostingView(rootView: makeDrawerRootView(limits: limits))
        drawerHostedLimits = limits
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor

        // 关键：用普通 NSView 当 contentView,hosting 作为子视图自适应填充——**不让 NSHostingView 直接当 contentView**。
        // 否则内容变高时 macOS 会用内容尺寸**顶边锚定、向下撑大**窗口（日志实测 cur(y=24 h=194)、top 恒=218），
        // 我们的布局随后才把它纠正成底边锚定向上长（y=68）——这一前一后打架 = owner 看到的"先向下扩展再上移"
        // 的真因（2026-06-22）。普通 NSView 不把子视图内容尺寸传给窗口,窗口高度只由 layoutPanels/setFrames 控制;
        // fittingSize 改读 hosting（存进 drawerContentHost）。
        let container = NSView(frame: NSRect(origin: .zero, size: lastDrawerSize))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        drawerContentHost = hosting
        drawerHosting = hosting
        return (panel, hosting)
    }

    /// 启动后把抽屉宿主预热出来（不 orderFront、不动任何开合状态），让本次会话**第一次**打开也不用现建。
    /// 排在启动首帧事务之后 1 秒，不碰它。关着的抽屉视图活着不是新状态（③④ 下本来就有），拖拽回调都先问 `isDrawerOpen()`。
    func prewarmDrawerHost() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.isSuspendedForPermissionLoss, self.drawerHosting == nil,
                  let mainPanel = self.dockPanel, self.capsulePanel != nil else { return }
            let anchor = self.drawerAnchor(on: self.panelCurrentScreen(panel: mainPanel))
            guard let host = self.ensureDrawerHost(limits: anchor.limits) else { return }
            let (panel, hosting) = host
            panel.layoutIfNeeded()
            _ = hosting.fittingSize
        }
    }

    /// 抽屉内点击 app 主操作后的延迟关闭。捕获 token，触发时三重确认才关：
    /// 1. token 匹配（排除抽屉在延迟期被重开的情况）；2. 抽屉仍是逻辑打开态；3. 无拖动进行中。
    func closeDrawerAfterAction() {
        let token = drawerActionCloseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  self.drawerActionCloseToken == token,
                  self.drawerWantsOpen,
                  self.dragController.draggingPayload == nil else { return }
            self.closeDrawer()
        }
    }

    /// 可打断淡出关闭：立即摘监视器、动画 alpha→0,completion 里确认仍要关才 orderOut（淡出中又打开则不关）。
    func closeDrawer() {
        guard drawerWantsOpen else { return }
        drawerWantsOpen = false
        setAutoHideInhibitor(.drawerOpen, active: false)
        drawerSpringOpened = false
        removeDrawerMonitors()
        stopDrawerArrowFollow()
        guard let panel = drawerPanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PopoverAnimation.closeDuration
            ctx.timingFunction = PopoverAnimation.curve()
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.drawerWantsOpen else { return }   // 淡出中又开了 → 别 orderOut
                panel.orderOut(nil)
                self.drawerArrow.scrollGeneration &+= 1   // next open starts at the grid's top
            }
        })
    }

    /// 全屏输入已经被 tap 暂停投递，不能等淡出动画；状态和监视器照常收口后立即移出 WindowServer。
    func closeDrawerImmediately() {
        guard drawerWantsOpen || drawerPanel?.isVisible == true else { return }
        drawerWantsOpen = false
        setAutoHideInhibitor(.drawerOpen, active: false)
        drawerSpringOpened = false
        removeDrawerMonitors()
        stopDrawerArrowFollow()
        drawerPanel?.alphaValue = 0
        drawerPanel?.orderOut(nil)
        drawerArrow.scrollGeneration &+= 1
    }

    private func removeDrawerMonitors() {
        if let m = drawerLocalMonitor  { NSEvent.removeMonitor(m); drawerLocalMonitor  = nil }
        if let m = drawerGlobalMonitor { NSEvent.removeMonitor(m); drawerGlobalMonitor = nil }
        drawerMoveMonitors.forEach { NSEvent.removeMonitor($0) }
        drawerMoveMonitors = []
    }

    /// How far past the drawer, its capsules and the bar the pointer may go before the drawer
    /// closes by itself.
    static let drawerDismissDistance: CGFloat = 150

    /// Closes the drawer once the pointer is `drawerDismissDistance` from everything it belongs
    /// to: the plate, the capsules and the bar. Not during a drag (the spring logic owns that).
    private func dismissDrawerIfPointerFar() {
        guard drawerWantsOpen, dragController.draggingPayload == nil,
              NSEvent.pressedMouseButtons == 0,
              let drawer = drawerPanel, drawer.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let areas = [Self.drawerPlateFrame(drawer.frame), capsulePanel?.frame, dockPanel?.frame].compactMap { $0 }
        let near = areas.contains { $0.insetBy(dx: -Self.drawerDismissDistance, dy: -Self.drawerDismissDistance).contains(mouse) }
        if !near { closeDrawer() }
    }

    private func dismissDrawerIfOutside() {
        if dragController.draggingPayload != nil {   // 拖动中不误关
            // A new click means the drag's button was released: a payload still set is at most a
            // landing flight, or one that outlived its drag and would keep the drawer open.
            Logger(subsystem: "com.caye.macosdockcc.v2", category: "drawer")
                .error("click outside the drawer ignored: a drag payload is still set")
            return
        }
        guard let drawer = drawerPanel, drawer.isVisible,
              let dock   = dockPanel else { return }
        let mouse = NSEvent.mouseLocation
        // The plate, not the window: its 40pt transparent border dismisses like any outside click.
        guard !Self.drawerPlateFrame(drawer.frame).contains(mouse),
              !dock.frame.contains(mouse),
              !(capsulePanel?.frame.contains(mouse) ?? false) else { return }
        closeDrawer()
    }

    func dragDropZones(for source: DragSource) -> [CGRect] {
        // 读**目标** frame：动画中 live frame 是中途值,会和视觉/落点短暂错位（Codex 二审 P2）。目标未初始化时退回 live。
        func target(_ stored: NSRect, _ live: NSRect?) -> NSRect? { stored != .zero ? stored : live }
        switch source {
        case .strip, .messaging:
            var zones: [CGRect] = []
            if let group = target(lastCapsuleTargetFrame, capsulePanel?.frame) {
                // One zone per capsule: a drop goes to the drawer of the capsule under it.
                for slot in capsuleSlots(inGroup: group) {
                    zones.append(slot.frame.insetBy(dx: Self.shadowPadding - 8, dy: Self.shadowPadding - 8))
                }
            }
            if let drawer = drawerPanel, drawer.isVisible, let d = target(lastDrawerTargetFrame, drawer.frame) {
                // 抽屉只向上长：投放区**上沿拉到屏幕顶**,只认固定的底边+宽度,不随面板增高/缩短而变。
                // 否则"投放区尺寸→是否插空格→面板增高→投放区尺寸"成反馈环,空格闪烁、面板动画被高频打断
                // 而过冲向下（owner 2026-06-21"先向下扩展再上移"的真因）。
                let inset = Self.drawerPlateFrame(d)   // bottom = arrow tip, 3pt above the bar's top
                // 投放区向上延伸到与抽屉一致的顶部上限：避让菜单栏/刘海，但不避让原生 Dock。
                let geometry = Self.screenGeometry(panelCurrentScreen(panel: drawer))
                let top = geometry.topUsableY
                if taskbarEdge.isVertical {
                    // Beside a column the plate re-centres on the capsule as it grows, so it has no
                    // fixed edge to hang the zone from: take its width over the screen's full height.
                    let bottom = geometry.frame.minY
                    zones.append(CGRect(x: inset.minX, y: bottom, width: inset.width, height: top - bottom))
                } else {
                    zones.append(CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: max(inset.height, top - inset.minY)))
                }
            }
            return zones
        case .drawer:
            guard let d = target(lastDockTargetFrame, dockPanel?.frame) else { return [] }
            return [d.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)]
        case .folder:
            // 文件夹 chip 无投放区（canExternalDrop=false 本就不会查;区内重排/拖出移除/拖回打开
            // 全在 DockStripView 用 FolderChipDropZone 判定）。与 strip/drawer 收纳语义隔离（评审拍板）。
            return []
        }
    }

    // MARK: - 弹簧文件夹：拖卡悬停胶囊自动弹开抽屉

    /// strip 卡悬在胶囊上（抽屉关着时投放区只有胶囊）约 0.4s → 自动弹开抽屉,之后移进抽屉即接上精确定位;
    /// 不等它开、直接在胶囊松手仍按"收进末尾"。移开/松手取消定时器。
    func subscribeDragSpringLoad() {
        // 订阅 globalLocation（不是 isOverDropZone）——光标回到任务条上不改 isOverDropZone,
        // 必须靠位置才能实时收回抽屉（owner 2026-06-21：拖回任务条即收、再移回胶囊再开）。
        dragSpringSubscription = dragController.pointerMoves
            .combineLatest(dragController.$draggingPayload)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location, payload in
                self?.updateSpringLoad(location: location, payload: payload)
            }
    }

    func subscribeDragInhibitor() {
        dragInhibitorSubscription = dragController.$draggingPayload
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dragging in
                if dragging { self?.dismissWindowTitleTooltip(suppressCurrentUntilExit: true) }
                self?.setAutoHideInhibitor(.dragging, active: dragging)
            }
    }

    /// 视区命中：目标 frame 取可见内容区 + 6pt 迟滞（防胶囊/任务条交界反复横跳）。
    func springZone(_ target: NSRect) -> CGRect {
        target.insetBy(dx: Self.shadowPadding - 6, dy: Self.shadowPadding - 6)
    }

    /// The drawer's spring zone: its plate (the window has a 40pt transparent border, not the
    /// 20pt `springZone` assumes) with the same 6pt hysteresis.
    private func drawerSpringZone() -> CGRect {
        Self.drawerPlateFrame(lastDrawerTargetFrame).insetBy(dx: -6, dy: -6)
    }

    private func updateSpringLoad(location: CGPoint, payload: DragPayload?) {
        // 整段拖动只要从任务条发起就享受弹簧（转正成 .drawer 后仍认这个标记）。消息区 chip 同享：
        // 悬胶囊自动弹开抽屉才有精确收纳落点。
        if let p = payload, p.source == .strip || p.source == .messaging {
            dragOriginatedFromStrip = true; springDragBundleID = p.bundleID
        }

        // 松手兜底：弹簧开的抽屉若没把卡收进抽屉 → 收回。（实时悬停大多已处理,这里兜底。）
        if payload == nil {
            cancelSpringTimers()
            if drawerSpringOpened, let bid = springDragBundleID, !drawerStore.contains(bid) {
                closeDrawer()
            }
            drawerSpringOpened = false
            springDragBundleID = nil
            dragOriginatedFromStrip = false
            return
        }
        // 非任务条发起（纯抽屉内拖动 / 抽屉→任务条移回）不弹簧。
        guard dragOriginatedFromStrip else { cancelSpringTimers(); return }

        let inDrawer  = drawerWantsOpen && lastDrawerTargetFrame != .zero && drawerSpringZone().contains(location)
        let hoveredCapsule = inDrawer ? nil : capsuleDrawerID(at: location)
        let inCapsule = hoveredCapsule != nil
        // Over another capsule: drops now go to its drawer, and an open drawer switches to it.
        if let hoveredCapsule, hoveredCapsule != drawerStore.activeDrawerID {
            drawerStore.setActiveDrawer(hoveredCapsule)
            if drawerWantsOpen {
                closeDrawerImmediately()
                openDrawer()
                drawerSpringOpened = true
                dragController.bringCarrierToFront()
            }
        }

        if inDrawer || inCapsule {
            // 在抽屉或胶囊上 → 取消收回；关着且在胶囊上 → 起开抽屉定时器。
            springCloseTimer?.invalidate(); springCloseTimer = nil
            if !drawerWantsOpen {
                if inCapsule && springOpenTimer == nil { armSpringOpenTimer() }
            } else {
                springOpenTimer?.invalidate(); springOpenTimer = nil      // 已开 → 保持
            }
        } else {
            // 离开抽屉+胶囊（任务条上或空隙）→ 取消未触发的开；开着则**延迟**收回（owner 2026-06-22）。
            springOpenTimer?.invalidate(); springOpenTimer = nil
            if drawerWantsOpen && springCloseTimer == nil { armSpringCloseTimer() }
        }
    }

    private func cancelSpringTimers() {
        springOpenTimer?.invalidate(); springOpenTimer = nil
        springCloseTimer?.invalidate(); springCloseTimer = nil
    }

    private func armSpringOpenTimer() {
        // .common 模式：拖动时主 run loop 在事件跟踪模式,scheduledTimer(默认 default) 拖动期间不触发。
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.springOpenDrawer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        springOpenTimer = timer
    }

    /// 离开抽屉+胶囊 ~0.35s 后才收回（短暂蹭过任务条/空隙不收）。到点仍在拖、仍开、仍在外才真关。
    private func armSpringCloseTimer() {
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.springCloseDrawerIfStillOutside() }
        }
        RunLoop.main.add(timer, forMode: .common)
        springCloseTimer = timer
    }

    private func springCloseDrawerIfStillOutside() {
        springCloseTimer = nil
        guard dragOriginatedFromStrip, drawerWantsOpen else { return }
        let loc = dragController.globalLocation
        let inDrawer  = lastDrawerTargetFrame != .zero && drawerSpringZone().contains(loc)
        let inCapsule = capsuleDrawerID(at: loc) != nil
        guard !inDrawer, !inCapsule else { return }   // 又回到抽屉/胶囊 → 不关
        closeDrawer()
    }

    private func springOpenDrawer() {
        springOpenTimer = nil
        // 到点仍在拖、仍悬胶囊、抽屉仍关 → 弹开。用 dragOriginatedFromStrip + 重测胶囊命中（不用
        // isOverDropZone：转正成 .drawer 后它指的是任务条区,悬胶囊时为 false,会误拦重开。owner 2026-06-22）。
        let loc = dragController.globalLocation
        let inCapsule = capsuleDrawerID(at: loc) != nil
        guard dragController.draggingPayload != nil,
              dragOriginatedFromStrip,
              inCapsule,
              !drawerWantsOpen else { return }
        openDrawer()
        drawerSpringOpened = true   // openDrawer 把它置 false 了,这里标记是弹簧开的
        dragController.bringCarrierToFront()
    }
}

// MARK: - Named drawers

extension PanelCoordinator {
    /// A capsule's right-click: its drawer's commands above the Tungsten menu.
    func showDrawerCapsuleMenu(event: NSEvent, view: NSView, drawerID: String) {
        let name = drawerStore.displayName(of: drawerID)
        var items: [NSMenuItem] = [
            ClosureMenuItem(String(localized: "New Drawer…")) { [weak self] in
                self?.promptForNewDrawer()
            },
            ClosureMenuItem(String(format: String(localized: "Rename “%@”…"), name)) { [weak self] in
                self?.promptToRenameDrawer(drawerID)
            },
        ]
        if drawerID != DrawerStore.defaultDrawerID {
            items.append(ClosureMenuItem(String(format: String(localized: "Delete “%@”"), name)) { [weak self] in
                self?.deleteDrawer(drawerID)
            })
        }
        onRequestTaskbarMenu?(event, view, items)
    }

    private func promptForNewDrawer() {
        guard let name = Self.askForDrawerName(title: String(localized: "New Drawer"),
                                               confirm: String(localized: "Create"), initial: "") else { return }
        drawerStore.createDrawer(named: name)
    }

    private func promptToRenameDrawer(_ drawerID: String) {
        let current = drawerStore.drawers.first { $0.id == drawerID }?.name ?? ""
        guard let name = Self.askForDrawerName(title: String(localized: "Rename Drawer"),
                                               confirm: String(localized: "Rename"),
                                               initial: current.isEmpty ? drawerStore.displayName(of: drawerID) : current)
        else { return }
        drawerStore.renameDrawer(drawerID, to: name)
    }

    /// Its apps go to the first drawer; an open drawer showing it closes first.
    private func deleteDrawer(_ drawerID: String) {
        if drawerWantsOpen && drawerStore.activeDrawerID == drawerID { closeDrawerImmediately() }
        drawerStore.deleteDrawer(drawerID)
    }

    /// A small name prompt; nil when cancelled or left empty.
    private static func askForDrawerName(title: String, confirm: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: initial)
        field.placeholderString = String(localized: "Name")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
