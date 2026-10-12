import AppKit
import os
import SwiftUI

/// The drawer is **app-centric**: one icon per bundleID, in the single order [[DrawerOrderStore]]
/// keeps. Running state never decides a position — it only picks how a cell looks and acts
/// (`showsAsRunning`): running = dot, click raises / hides the app (`LauncherChip.handleTap`);
/// otherwise the click launches it. Starting or quitting a visible app leaves every icon where it
/// is; an unkept app that quits hides and the cells after it close up, without touching the stored order.
///
/// DrawerStore 只记 placement，KeptAppStore 决定退出后是否继续显示。排序始终按完整
/// placement 集合记，隐藏成员下次启动仍回原位。
///
/// 两者**不再完全正交**（owner 2026-08-06）：**拖入**方向落定后会顺手打开 kept——不打开的话，
/// 拖进抽屉的普通应用一退出就从抽屉里消失了，不符合「收进抽屉 = 我要它一直在那儿」的心智。
/// **拖回任务条**方向仍然一律不动 kept。转换预览与回滚阶段也一律不碰 kept，只有 `endDrag()`
/// 落定那一刻才写。判据与完整语义见 `DragConversionPlan.enablesKeptOnDrop`。
struct DrawerView: View {
    /// Rows and columns the grid may take above the capsule on this screen; past them it scrolls
    /// inside the plate. The coordinator swaps the root view when they change.
    let limits: StackGridLayout.Limits
    /// The plate's arrow, kept on the capsule by the coordinator.
    let arrow: StackPopupArrowModel
    /// The plate's size changed: the coordinator re-lays out the drawer window. No default —
    /// without it the window stops following its content.
    let onPanelSizeChange: (CGSize) -> Void
    /// 底板走不走原生 Liquid Glass。**显式传入、无默认值**（同 `scale` / `hoverStyle`）——
    /// 每个面板都是独立的 hosting 根视图，漏传就会出现「这个面板是玻璃、旁边那个还是
    /// 毛玻璃」这种一眼可见的不一致。
    let usesLiquidGlass: Bool
    /// 本抽屉面板此刻开着没有。**显式传入、无默认值**：③④ 下每块屏各有一个抽屉视图，关掉的那个
    /// 还留着过期的 `drawerRootScreenRect`，不问这一句就会按旧位置把别的屏抽屉里的转正判成「已拖出」
    /// 而撤销——两个视图互相翻转换态，还在布局过程里改 `@Published`，2026-09-02 实机直接崩。
    /// **本视图里凡是由拖拽控制器驱动的回调都要先问它**（转正 / 撤销、重排、落点锚点、飞行中点击）：
    /// 关着的抽屉视图会一直活到下次打开，不问就会拿过期位置往共享的控制器里写——副屏抽屉拖出的图标
    /// 曾因此飞去主屏抽屉落位（同日第二起）。
    let isDrawerOpen: () -> Bool
    /// The edge the bar hugs, read when a drag needs it: a side bar opens the drawer beside it,
    /// which turns "above the bar" into "inside of the bar". No default, like `isDrawerOpen`.
    let taskbarEdge: () -> TaskbarEdge
    /// 点击 app 图标执行「唤出」或「启动」后回调。由 PanelCoordinator 注入，用于关闭抽屉。
    /// 「最小化（前台 → 收起）」不触发——抽屉保持打开。右键菜单、拖动操作同样不触发。
    var onPrimaryAction: () -> Void = {}

    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var drawerOrderStore: DrawerOrderStore
    @EnvironmentObject var dragController: DragController
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var runningApplicationStore: RunningApplicationStore
    @EnvironmentObject var appMembershipController: AppMembershipController

    /// Cell frames in the `"drawer"` space: the grab offset at pick-up and the reorder hit test.
    @State private var drawerFrames: [String: CGRect] = [:]

    /// 抽屉根视图的屏幕 frame（bottom-left），判"光标在不在抽屉体" + 屏幕坐标→`"drawer"` 空间换算。
    @State private var drawerRootScreenRect: CGRect = .zero

    // MARK: - 成员与分区（全 bundleID 级）

    /// Placement 全集喂给顺序层，绝不按当前可见项裁。
    private var allMembers: [String] {
        AppMembershipProjection.drawerMembers(drawerIDs: drawerStore.bundleIDs)
    }

    private var displayOrder: [String] { drawerOrderStore.reconciled(members: allMembers) }

    /// 唯一可见漏斗：运行中，或有 kept / messaging 永久身份。输入用显示顺序，
    /// 因此隐藏 placement 再出现时仍回到原来的相对位置。
    private var visibleMembers: [String] {
        AppMembershipProjection.visibleDrawerIDs(
            drawerIDs: displayOrder,
            keptIDs: keptAppStore.bundleIDs,
            runningIDs: runningApplicationStore.runningBundleIDs
        )
    }

    /// 有真窗口的 app（用于启动门控判定）。
    private var windowBackedIDs: Set<String> {
        Set(StripItem.items(from: runtime.snapshot).filter { !$0.isAppLevelFallback }.compactMap(\.bundleIdentifier))
    }

    /// Window gate: launched from here, process up but no real window yet → still launching, so the
    /// cell keeps its not-running look and bounces.
    private func isLaunchingWithoutWindow(_ id: String) -> Bool {
        runtime.launchingBundleIDs.contains(id) && !windowBackedIDs.contains(id)
    }

    /// 只有访达格子读得到真值——`windowBackedIDs` 每次都要重扫一遍快照，而这个值只有
    /// `performDefaultTap` 的访达分支会用，没必要为每一格都付这笔钱。非访达恒 `false` 是有意的。
    private func finderHasRealWindow(_ id: String) -> Bool {
        guard FinderTaskbarPolicy.isFinder(id) else { return false }
        return windowBackedIDs.contains(id)
    }

    /// 运行判定走 RunningApplicationStore（NSWorkspace 进程投影），与任务条 pinned dot 同口径。
    private func isRunning(_ id: String) -> Bool { runningApplicationStore.isRunning(id) }

    /// 隐藏判定同口径：同 bundle 所有进程都 hidden 才算 hidden。
    private func isHiddenInSnapshot(_ id: String) -> Bool { runningApplicationStore.isHidden(id) }

    /// A cell shows and acts as running (dot, raise / hide on click, window list in its menu) once
    /// the process runs and, after a launch from here, its first real window is up. Look and
    /// behaviour only — never the cell's position.
    private func showsAsRunning(_ id: String) -> Bool {
        isRunning(id) && !isLaunchingWithoutWindow(id)
    }

    // MARK: - Body

    /// The grid's shape, held still while a conversion is in flight (`DrawerGridShape`).
    private func gridShape(cellIDs: [String]) -> DrawerGridShape.Result {
        let delta = dragController.drawerConversionDelta
        return DrawerGridShape.resolve(
            settledCount: DrawerGridShape.settledCount(visibleIDs: cellIDs,
                                                       convertedInID: delta.convertedInID,
                                                       convertedOutID: delta.convertedOutID),
            actualCount: cellIDs.count,
            limits: limits)
    }

    var body: some View {
        // One grid in the drawer's own order: the folder popup's chrome with apps in its cells.
        let ids = visibleMembers
        let shape = gridShape(cellIDs: ids)
        return StackPopupChrome(title: String(localized: "Drawer"),
                                note: shape.showsHint ? String(localized: "Drag apps here from the taskbar") : nil,
                                layout: shape.layout,
                                plate: .drawer,
                                usesLiquidGlass: usesLiquidGlass,
                                arrow: arrow,
                                onPanelSizeChange: onPanelSizeChange,
                                gridAnimation: .easeInOut(duration: DrawerAnimation.duration),
                                gridAnimationKey: ids) {
            ForEach(ids, id: \.self) { drawerChip($0, running: showsAsRunning($0)) }
        }
        // 抽屉根视图的屏幕 frame（AppKit 换算,绕开 .global/y 翻转/shadowPadding 的坑,Codex 二审 P1-3）。
        // 与 `"drawer"` 命名空间挂在同一视图上 → 既能判"光标在不在抽屉里",又能把屏幕坐标映回 drawer 空间命中格子。
        // **抽屉面板自己挪了，也要重报落点锚点。** 松手那一刻 `teardown` 清掉 `conversion`，
        // 任务条宽度随即解冻、整条重新居中变窄；胶囊右对齐任务条、抽屉又锚在胶囊上，
        // 于是**整个抽屉面板在 0.22s 里往左滑一段**，而格子在 `"drawer"` 空间里的帧纹丝不动
        // ——只有这个屏幕 rect 在变。不接这一条的话，归位飞行会一直朝面板挪走**之前**那个
        // 位置飞（在右边），落地才发现格子已经在左边了，就是 owner 报的
        // 「先飘到目标位置的偏右，再去到目标位置」。纠偏机制本来就为这种事准备好了，
        // 缺的只是这里没喂给它。
        .background(ScreenRectReader { rect in
            guard rect != drawerRootScreenRect else { return }
            drawerRootScreenRect = rect
            updateLandingAnchor()
        })
        .coordinateSpace(name: "drawer")
        // **抽屉打开没有入场动画**（owner 2026-09-04：优先保任务条的动画，抽屉区可能重做）。
        // 之前的「面板淡入 + 内容 0.96→1 放大 + 卡片阶梯浮现」每次打开都要把整棵抽屉按入场前状态重算一遍，
        // 主线程停顿压在淡入开头（视图树复用后仍 22～40ms），动画本身反而是掉帧的来源。理由见 `Docs/27`。
        // 格子帧变了就重报落点锚点（理由同任务条那侧：松手后指针没事件了，网格还在重排）。
        .onPreferenceChange(DrawerChipFramePreferenceKey.self) { frames in
            drawerFrames = frames
            updateLandingAnchor()
        }
        // 拖动中被拖图标的 app 从成员里消失（外部移除等）→ 取消拖动，免得空位卡死。
        // 例外：转正进任务条（抽屉拖回任务条·精确落点）会**主动**把它移出抽屉，不算异常消失，不取消。
        .onChange(of: visibleMembers) { members in
            if let p = dragController.draggingPayload, p.source == .drawer,
               !dragController.isConvertedToStrip, !members.contains(p.id) {
                dragController.cancelDrag()
            }
        }
        // A strip card dragged into the drawer converts here; a drawer drag reorders here. Both follow the
        // global pointer and never publish from body (onChange + dedupe).
        // `onReceive` 而不是 `onChange(of: globalLocation)`，理由同 `DockStripView`：
        // 那个值一旦是 `@Published`，每动一下鼠标就要把整个面板打翻重算。
        .onReceive(dragController.pointerMoves) { _ in
            updateStripDropPreview(); updateDrawerReorder(); updateLandingAnchor()
        }
        .onChange(of: dragController.draggingPayload?.id) { id in
            if id == nil { convertedCarrierID = nil }   // 拖动结束：下一次同一应用再进来要重新换图
            // `onChange` 跑在 SwiftUI 的布局 / 提交过程里，这里面改 `DragController` 的 `@Published`
            //（转正 / 撤销）会让 AppKit 在 `_postWindowNeedsUpdateConstraints` 抛异常（2026-09-02 崩溃）。
            // 推到下一轮 run loop 再判。
            DispatchQueue.main.async { updateStripDropPreview() }
        }
        // 归位飞行途中点了一下抽屉图标 = 点了这个格子：走格子自己的默认左键行为（同一份静态逻辑）。
        .onReceive(dragController.carrierClicks) { payload in
            // 只有开着的那个抽屉视图分发（每块屏各一个视图；都分发的话运行中的 app 显 / 隐两次 = 净零）。
            guard isDrawerOpen(), payload.source == .drawer, !runtime.launchingBundleIDs.contains(payload.id) else { return }
            LauncherChip.performDefaultTap(
                bundleID: payload.id,
                isRunning: isRunning(payload.id),
                finderHasRealWindow: finderHasRealWindow(payload.id),
                launch: { if runtime.beginLaunch(payload.id) { onPrimaryAction() } },
                onOpen: onPrimaryAction)
        }
    }

    // MARK: - 单个图标（含拖动）

    /// `carriedPayload` 而不是 `draggingPayload`：松手后还有一段归位飞行，
    /// 那段时间格子必须继续空着，否则图标先在格子里显形、载体还在往这儿飞。
    private func isDragging(_ id: String) -> Bool {
        guard let p = dragController.hiddenSlotPayload else { return false }
        return p.source == .drawer && p.id == id
    }

    /// 松手时浮动副本该飞回抽屉哪一格（屏幕坐标）。任务条侧同样在写它那一份，靠 owner 标签分开。
    /// 任务条卡收进抽屉（来源已翻成 `.drawer`）也走这里 —— 图标会直接飞进它落定的格子。
    private func updateLandingAnchor() {
        guard isDrawerOpen() else { return }   // 关着的抽屉既不报锚点、也不清掉开着那个报的
        let anchor: CGRect? = {
            // `carriedPayload`：飞行途中也要继续报，网格重排落定后才纠得了偏。
            guard let p = dragController.carriedPayload, p.source == .drawer,
                  !dragController.isConvertedToStrip,
                  drawerRootScreenRect != .zero,
                  let frame = drawerFrames[p.id] else { return nil }
            return drawerFrameToScreen(frame)
        }()
        dragController.setLandingAnchor(anchor, owner: .drawer)
    }

    private func membershipItems(for id: String) -> [LauncherMembershipItem] {
        LauncherMembershipItem.items(
            surface: .drawer,
            bundleID: id,
            isKept: keptAppStore.contains(id),
            isMessaging: messagingStore.contains(id),
            controller: appMembershipController
        )
    }

    /// `running` is `showsAsRunning`, so look, click and menu agree: a process launched from here
    /// stays "not running" until its first real window; the runtime's launch session drives the bounce.
    /// 抽屉格子里**画什么**。拆出来的唯一理由：载体位图要从这里出
    /// （`ChipSnapshotter`），渲染格子和渲染载体必须是同一份代码、同一批参数。
    /// 外面那层入场动画 / 拖动时置 0 的透明度 / 手势都不能进快照，所以留在 `drawerChip` 里。
    private func drawerChipContent(_ id: String, running: Bool) -> some View {
        LauncherChip(bundleID: id,
                     isRunning: running,
                     isHidden: running ? isHiddenInSnapshot(id) : false,
                     finderHasRealWindow: finderHasRealWindow(id),
                     isLaunching: runtime.launchingBundleIDs.contains(id),
                     // 76pt icon = 1.9 × the bar's 40pt slot (`StackCellMetrics.drawer.iconSize`).
                     scale: 1.9,
                     layout: .stackCell,
                     // 抽屉有意不受「悬停效果」设置影响（owner 2026-08-02），但**固定成安静档**
                     // （owner 2026-08-17 要「抽屉图标悬停微微放大」）。
                     //
                     // 当年写 `.standard` 是为了「悬停冒名字」，那个理由 2026-08-16 就没了：
                     // 名字挪进了图标上方的气泡，而抽屉这个调用处**根本没接气泡回调**——
                     // 于是 `.standard` 在这里等于「什么都不做」，抽屉悬停零反馈。
                     // `.quiet` 恰好就是「没有名字，所以给一个轻微放大」那一档，语义对得上。
                     // 112.5pt 宽的格子里图标可见部分约 62pt，放大 1.10 仍在自己那格的透明边里。
                     hoverStyle: .quiet,
                     // 抽屉这块面板没有整条那样的跟踪区，图标各自挂 `.onHover`。
                     // 格子 112.5pt 宽、指针在里面停留的时间远长于条上横扫，漏格不成问题。
                     hoverInput: .selfTracked,
                     // 抽屉应用的窗口块整体藏在任务条之外，这个列表是找回它们的唯一入口。
                     // 点窗口行不触发 onPrimaryAction——抽屉保持打开（同右键「打开」的规矩）。
                     windowEntriesProvider: {
                         WindowListMenuPlan.entries(
                             snapshot: runtime.snapshot,
                             bundleID: id,
                             fallbackTitle: AppDisplayNameResolver.displayName(for: id)
                         )
                     },
                     onActivateWindow: { runtime.activate(windowID: $0) },
                     membershipItems: membershipItems(for: id),
                     slotHidden: isDragging(id),
                     hoverSuppressed: isHoverSuppressed(id),
                     onLaunch: { runtime.beginLaunch(id) },
                     onPrimaryAction: onPrimaryAction)
    }

    /// 这一格的悬停反馈是不是该按住：正被拎着（`.onHover` 在透明期间照样为 true）、
    /// 或刚落定而指针还没动（`DragController.hoverHoldPayload`）。任务条那边由整条跟踪区在源头压住，
    /// 抽屉的 `LauncherChip` 各自挂 `.onHover`，只能在这里按格子压。
    private func isHoverSuppressed(_ id: String) -> Bool {
        if let p = dragController.hoverHoldPayload, p.source == .drawer, p.id == id { return true }
        return isDragging(id)
    }

    /// 抽屉格子起拖那一刻的姿态：抽屉恒安静档、指针必在格子上（mouse-down 就发生在它上面），
    /// 所以是 1.10 底锚放大 × 0.93 按压——除非悬停正被按住。倍数用渲染格子的同一个函数算。
    private func pickUpPose(for id: String, slot: CGRect?) -> DragCarrierGeometry.PickUpPose {
        let height = slot?.height ?? StackCellMetrics.drawer.cellSize.height
        let width = slot?.width ?? StackCellMetrics.drawer.cellSize.width
        let hoverScale: CGFloat? = isHoverSuppressed(id)
            ? nil
            : ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: 1.9)
        return DragCarrierGeometry.pickUpPose(
            chipHeight: height,
            pressedScale: ChipPressSwitches.pressDownEnabled ? ChipPressDecision.pressedScale : nil,
            hoverScale: hoverScale)
    }

    /// 屏幕坐标的格子帧；抽屉根帧还没量到就给 nil（起拖时会退回「摆在指针下」）。
    private func slotScreenRect(_ id: String) -> CGRect? {
        guard drawerRootScreenRect != .zero, let slot = drawerFrames[id] else { return nil }
        return drawerFrameToScreen(slot)
    }

    /// 松手时浮动副本该飞回抽屉哪一格 / 起拖时载体从哪一格接手：`"drawer"` 空间帧 → 屏幕坐标。
    private func drawerFrameToScreen(_ frame: CGRect) -> CGRect {
        CGRect(x: drawerRootScreenRect.minX + frame.minX,
               y: drawerRootScreenRect.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }

    @ViewBuilder
    private func drawerChip(_ id: String, running: Bool) -> some View {
        drawerChipContent(id, running: running)
            .opacity(isDragging(id) ? 0 : 1)
            // The frame in the `"drawer"` space via a background GeometryReader (takes no clicks):
            // grab offset and reorder hit test.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: DrawerChipFramePreferenceKey.self,
                                           value: [id: geo.frame(in: .named("drawer"))])
                }
            )
            // 本手势**只负责起拖一次**：拿到"是哪张卡 + 抓取偏移"后交给 DragController。
            // 重排**不在这里做**——第一次重排会把被拖图标在网格里挪位,SwiftUI 随即取消这个手势、
            // onChanged 不再触发 → "挤一下就卡住"（owner 2026-06-22）。重排改由 updateDrawerReorder()
            // 按 DragController 的全局鼠标位置驱动（见 onChange(globalLocation)），图标怎么换位都不受影响。
            // **按下即预备**（`DragController.prepareCandidate`）：mouse-down 那一刻就把这格的位图
            // 挂上载体图层预热纹理，起拖当轮才能「点亮 + 藏格」同帧。松手没起拖就撤掉。
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("drawer"))
                    .onChanged { _ in
                        guard let rect = slotScreenRect(id) else { return }
                        dragController.prepareCandidate(
                            payloadID: id,
                            sourceScreenRect: rect,
                            snapshot: ChipSnapshotter.snapshot(of: drawerChipContent(id, running: running),
                                                             screenPoint: CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)))
                    }
                    .onEnded { _ in dragController.clearCandidate(payloadID: id) }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named("drawer"))
                    .onChanged { value in
                        guard dragController.draggingPayload == nil else { return }
                        let slot = drawerFrames[id]
                        let grab: CGSize = slot.map {
                            CGSize(width: $0.midX - value.startLocation.x,
                                   height: $0.midY - value.startLocation.y)
                        } ?? .zero
                        let payload = DragPayload(source: .drawer, id: id, bundleID: id, item: nil,
                                                  visualKind: .drawerIcon, canExternalDrop: true)
                        dragController.beginDrag(
                            payload: payload,
                            startScreenLocation: NSEvent.mouseLocation,
                            grabOffset: grab,
                            sourceScreenRect: slotScreenRect(id) ?? .zero,
                            pose: pickUpPose(for: id, slot: slot),
                            snapshot: ChipSnapshotter.snapshot(of: drawerChipContent(id, running: running),
                                                             screenPoint: CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)))
                    }
                    // 松手兜底，与条内那侧对齐：平时收尾靠 DragController 的全局监视器 + 轮询，
                    // 这条是监视器万一没收到 mouseUp 时的第二条路（条内拖动一直有，抽屉这侧原本没有）。
                    .onEnded { _ in dragController.endDrag() }
            )
    }

    /// Reorder inside the drawer, driven by DragController's global pointer (the per-icon gesture is
    /// cancelled after the first move). The screen point maps back into the `"drawer"` space; the
    /// member count does not change, so the live `drawerRootScreenRect` is the right mapping.
    private func updateDrawerReorder() {
        guard isDrawerOpen(), let p = dragController.draggingPayload, p.source == .drawer,
              !dragController.isOverDropZone,            // 光标已在任务条上 = 移回,不重排
              drawerRootScreenRect != .zero else { return }
        let pt = CGPoint(x: dragController.globalLocation.x - drawerRootScreenRect.minX,
                         y: drawerRootScreenRect.maxY - dragController.globalLocation.y)   // 屏幕(左下) → drawer(左上)
        reorderTarget(at: pt, dragging: p.id, among: visibleMembers)
    }

    /// Any visible cell is a target: the grid is drawn in `DrawerOrderStore` order alone, so a move
    /// shows at once, whatever the two apps' running states.
    private func reorderTarget(at point: CGPoint, dragging id: String, among candidates: [String]) {
        // Cells tile the grid edge to edge, so the plain frame is the whole hit area.
        for tid in candidates where tid != id {
            guard let f = drawerFrames[tid], f.contains(point) else { continue }
            drawerOrderStore.reorder(draggedID: id, relativeTo: tid, after: point.x > f.midX)
            return
        }
    }

    // MARK: - 任务条卡进抽屉体 → 转成抽屉内拖动 / 拖出还原

    /// 任务条卡拖进**打开的抽屉体** → 即时转成抽屉内拖动（DragController.convertStripToDrawer：加入抽屉成员、
    /// 来源改 `.drawer`）。此后这张卡就是普通抽屉成员,由全局鼠标驱动的 `updateDrawerReorder` 重排——与抽屉内
    /// 拖动**完全同一套**(owner 2026-06-22：统一手感)。彻底绕开旧的"占位空格 + 面板反复缩放"机制（闪烁/卡顿源）。
    /// 底边/侧边留容差：载体相对鼠标有抓取偏移,鼠标常落在抽屉底边附近,容差让贴边也能稳定判"进了抽屉体"。
    private func updateStripDropPreview() {
        let dc = dragController
        // 只有**开着的**抽屉才有资格转正 / 撤销（理由见 `isDrawerOpen`）。
        guard dc.draggingPayload != nil, drawerRootScreenRect != .zero, isDrawerOpen() else { return }
        // The plate, not the window (40pt of transparent border). The floor is the capsule's top
        // = the bar's top edge: anything lower would convert a chip still being dragged along
        // the bar. Beside a column the same tests run in the bar's canonical frame, where the
        // floor is the plate's side facing the bar.
        let edge = taskbarEdge()
        let g = edge.screenCanonical(dc.globalLocation)
        let r = edge.screenCanonical(PanelGeometry.folderPopupPlateFrame(panelFrame: drawerRootScreenRect))
        let floor = PanelGeometry.drawerBodyFloorY(plate: r)
        // 进入阈值松（容差大,好进）；撤销阈值更靠外（迟滞带,防边缘反复转正/撤销 → 抽屉一胀一缩抖）。
        let enterBody = g.x >= r.minX - 8  && g.x <= r.maxX + 8  && g.y >= floor
        let clearlyOut = g.x < r.minX - 20 || g.x > r.maxX + 20 || g.y < floor - 20
        if let p = dc.draggingPayload, p.canExternalDrop, enterBody {
            switch p.source {
            case .strip:     dc.convertStripToDrawer()      // 进抽屉体 → 临时转正(挤开别人=预览)
            case .messaging: dc.convertMessagingToDrawer()  // 消息 chip 同一套收纳预览手感
            case .drawer, .folder: break
            }
            syncConvertedCarrier()
        } else if clearlyOut {
            if dc.isConvertedFromStrip {
                dc.revertStripFromDrawer()          // 拖出抽屉体 → 撤销还原(抽屉缩回最初样子)
            } else if dc.isConvertedFromMessaging {
                dc.revertMessagingFromDrawer()      // 消息 chip 拖出 → 还原回消息区原位
            }
            syncConvertedCarrier()
        }
    }

    /// 任务条卡 / 消息 chip 一进抽屉体，载体就换成**抽屉格子的位图**（`drawerChipContent` 同款整格、
    /// 无角标），并按尺寸比例把抓取点重新锚到指针上；拖出抽屉体还原成起拖那张。
    /// 反方向（抽屉图标转正进任务条）早就换图（`DockStripView.syncConvertedCarrier`），这个方向之前漏了：
    /// 载体一直是 40pt 图标甚至 168pt 标题卡，压在抽屉边上（owner 2026-08-19 截图）。
    /// 落进格子那一帧才能逐像素一致——位图必须由渲染格子的同一份代码出。
    @State private var convertedCarrierID: String?
    private func syncConvertedCarrier() {
        let dc = dragController
        let converted = dc.isConvertedFromStrip || dc.isConvertedFromMessaging
        if converted, let p = dc.draggingPayload, p.source == .drawer {
            guard convertedCarrierID != p.id else { return }
            convertedCarrierID = p.id
            dc.setCarrierSnapshot(
                ChipSnapshotter.snapshot(of: drawerChipContent(p.id, running: showsAsRunning(p.id)),
                                         screenPoint: CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)),
                reanchor: true)
        } else if !converted, convertedCarrierID != nil {
            convertedCarrierID = nil
            dc.setCarrierSnapshot(nil, reanchor: true)   // 换回起拖那张；拖动已结束时里面直接不动
        }
    }
}

// MARK: - Drawer drag-reorder preference

private struct DrawerChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 抽屉宿主的根视图：`DrawerView` + 它的八个环境对象。
///
/// 存在的唯一理由是给 `PanelCoordinator` 一个**可命名**的宿主类型 `NSHostingView<DrawerRootView>`：
/// 宿主只建一次、之后每次打开只换 `rootView`（2026-09-04，抽屉弹开掉帧的修法），而
/// `DrawerView(...).environmentObject(...)` 链出来的是写不出名字的 `ModifiedContent<…>`。
struct DrawerRootView: View {
    let limits: StackGridLayout.Limits
    let arrow: StackPopupArrowModel
    let onPanelSizeChange: (CGSize) -> Void
    let usesLiquidGlass: Bool
    let isDrawerOpen: () -> Bool
    let taskbarEdge: () -> TaskbarEdge
    let onPrimaryAction: () -> Void
    let runtime: AppRuntime
    let drawerStore: DrawerStore
    let messagingStore: MessagingAppStore
    let drawerOrderStore: DrawerOrderStore
    let dragController: DragController
    let keptAppStore: KeptAppStore
    let runningApplicationStore: RunningApplicationStore
    let appMembershipController: AppMembershipController

    var body: some View {
        DrawerView(limits: limits,
                   arrow: arrow,
                   onPanelSizeChange: onPanelSizeChange,
                   usesLiquidGlass: usesLiquidGlass,
                   isDrawerOpen: isDrawerOpen,
                   taskbarEdge: taskbarEdge,
                   onPrimaryAction: onPrimaryAction)
            .environmentObject(runtime).environmentObject(drawerStore).environmentObject(messagingStore)
            .environmentObject(drawerOrderStore).environmentObject(dragController)
            .environmentObject(keptAppStore).environmentObject(runningApplicationStore)
            .environmentObject(appMembershipController)
    }
}
