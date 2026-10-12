import Foundation

/// A native membership-menu descriptor shared by launcher and window chips.
struct LauncherMembershipItem {
    let label: String
    /// nil = ordinary command; non-nil = native NSMenuItem check state.
    var isChecked: Bool? = nil
    let action: () -> Void
}

extension LauncherMembershipItem {
    /// Keeps the four menu construction paths on one membership matrix. Messaging uses a
    /// constant title: unchecked calls mark, checked calls unmark; neither path changes drawer.
    @MainActor
    static func items(
        surface: AppMembershipMenuPlan.Surface,
        bundleID: String,
        isKept: Bool,
        isMessaging: Bool,
        controller: AppMembershipController
    ) -> [LauncherMembershipItem] {
        AppMembershipMenuPlan.items(
            surface: surface,
            isFinder: FinderTaskbarPolicy.isFinder(bundleID),
            isKept: isKept,
            isMessaging: isMessaging
        ).map { item in
            switch item {
            case let .keep(isChecked):
                return LauncherMembershipItem(label: String(localized: "Keep in Dock"), isChecked: isChecked) {
                    controller.setKept(bundleID, enabled: !isChecked)
                }
            case let .messaging(isChecked):
                return LauncherMembershipItem(label: String(localized: "Pin as App Icon"), isChecked: isChecked) {
                    if isChecked {
                        controller.unmarkMessaging(bundleID)
                    } else {
                        controller.markMessaging(bundleID)
                    }
                }
            }
        } + pinnedDividerItems(surface: surface, bundleID: bundleID, isMessaging: isMessaging,
                               controller: controller)
    }

    /// Pinned tiles on the bar can carry a divider after them.
    @MainActor
    private static func pinnedDividerItems(
        surface: AppMembershipMenuPlan.Surface,
        bundleID: String,
        isMessaging: Bool,
        controller: AppMembershipController
    ) -> [LauncherMembershipItem] {
        guard surface == .strip, isMessaging else { return [] }
        return [dividerAfterItem(bundleID: bundleID, controller: controller)]
    }

    /// The Divider After toggle, also offered on the Apps entry heading a side-edge bar.
    @MainActor
    static func dividerAfterItem(bundleID: String, controller: AppMembershipController) -> LauncherMembershipItem {
        let isChecked = controller.hasPinnedDivider(after: bundleID)
        return LauncherMembershipItem(label: String(localized: "Divider After"), isChecked: isChecked) {
            controller.setPinnedDivider(after: bundleID, enabled: !isChecked)
        }
    }
}
