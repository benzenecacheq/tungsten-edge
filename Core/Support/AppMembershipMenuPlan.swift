import Foundation

/// 成员菜单的**纯决策层**：给定图标所在面（strip / drawer）+ kept / messaging
/// 状态，产出应出现的成员项（顺序即渲染顺序，不含 closure）。抽成纯逻辑便于单测；把 `Item`
/// 映射成带动作的菜单项由 `LauncherMembershipItem.items` 完成，四条菜单构造路径统一消费。
///
/// 固定矩阵（消息项标题恒定，以原生勾选态表达成员身份）：
/// - strip 普通：在程序坞中保留 + 固定为应用图标（未勾选）
/// - strip 消息：在程序坞中保留 + 固定为应用图标（已勾选）
/// - drawer 普通：仅在程序坞中保留
/// - drawer 消息：在程序坞中保留 + 固定为应用图标（已勾选）
/// - Finder：同普通应用（2026-10-20 起可固定为应用图标）
enum AppMembershipMenuPlan {
    enum Surface: Equatable { case strip, drawer }

    /// 无 closure 的展示态，供渲染层映射成具体动作。
    enum Item: Equatable {
        case keep(isChecked: Bool)
        case messaging(isChecked: Bool)
    }

    static func items(surface: Surface,
                      isKept: Bool,
                      isMessaging: Bool) -> [Item] {
        // 保留勾选恒在前，消息命令在后。
        var items: [Item] = [.keep(isChecked: isKept)]
        if isMessaging {
            items.append(.messaging(isChecked: true))
        } else if surface == .strip {
            // 「固定为应用图标」只在 strip 的普通应用出现：抽屉里标记不改 placement（抽屉优先级更高），
            // 没有可见效果，故 drawer 面不提供该命令。
            items.append(.messaging(isChecked: false))
        }
        return items
    }
}
