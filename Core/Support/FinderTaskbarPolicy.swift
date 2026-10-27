import Foundation

/// 访达在任务条侧的成员资格与常驻策略（owner 2026-08-20 定，反转「访达永远常驻、不提供保留状态」）。
///
/// 访达现在和普通应用走同一套「在程序坞中保留」：勾上（默认）就永远有一个应用级入口，
/// 取消勾选后，所有访达窗口关掉时那张入口卡消失，再开窗口时窗口卡回来。抽屉也一并放开。
/// Since 2026-10-20 Finder can be pinned as an app icon too: like any pinned app, the tile
/// takes its first window on the bar and the rest follow it.
///
/// 跟踪层（`AppTracker` / `FinderWindowRules`）不受这里影响：访达始终被收编、进程重启也保住条目，
/// 「消失」只发生在投影层（`DockStripView.makeProjection`），这样一开窗口卡就能瞬时回来。
enum FinderTaskbarPolicy {
    /// Core/App 侧的访达常量。Platform 侧另有 `FinderWindowRules.bundleIdentifier`——
    /// 那个管窗口可跟踪性，与成员资格是两件事，不要合并。
    static let bundleID = "com.apple.finder"

    static func isFinder(_ bundleID: String?) -> Bool {
        bundleID == Self.bundleID
    }

    /// 访达的应用级入口（无窗口时那张卡）是否显示——只由「在程序坞中保留」决定。
    ///
    /// 普通应用运行中无窗口时照样有兜底卡，访达却是开机就一直在跑的，
    /// 所以不在这里闸一道，勾选框对访达就毫无效果。
    static func showsAppLevelEntry(isKept: Bool) -> Bool {
        isKept
    }

    /// 能否固定为应用图标。
    static func canMarkMessaging(_ bundleID: String) -> Bool {
        !bundleID.isEmpty
    }
}
