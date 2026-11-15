import Foundation
import UIKit
import shared

/// The iPhone Duo side column of one page (`RaftSideActionHostBridge`) as the page's navigation bar
/// buttons (RaftIosSideActionItems): iOS 27.1 draws them in the vertical bar on the camera's side,
/// as the system's own glass buttons, grouped like the tab bar; taps go back to the page by id. The
/// page keeps the column's width and draws nothing in it.
///
/// The navigation bar is shown while it holds the buttons (`raftSideActionsShown`): the system
/// draws no vertical bar items of a hidden bar. Its top band is not the page's, so the page keeps
/// the navigation controller's safe area (RaftPageViewController `raftPublishWindowInsets`).
///
/// Lifetime: the page controller owns the host (`raftSideActionHost`); the bridge, which stays in
/// the global RaftSideActionHostRegistry until this host's deinit unregisters it, reaches the host
/// only weakly (RaftIosWeakSideActionListener), so the page's teardown frees both.
///
/// Not used on a native-nav-bar prototype page (RaftPageControllerFactory): that page's
/// RaftNativeNavBarHost owns the same navigationItem's bar buttons.
@available(iOS 27.1, *)
final class RaftIosSideActionHost: NSObject, RaftSideActionHostListener {
    private weak var controller: RaftPageViewController?
    private let bridge: RaftSideActionHostBridge
    private let hostId: String

    /// Registers [bridge] under a new host id in [pageData] (before the page is created).
    static func register(pageData: inout [AnyHashable: Any]) -> (hostId: String, bridge: RaftSideActionHostBridge) {
        let hostId = UUID().uuidString
        let bridge = RaftSideActionHostBridge()
        RaftSideActionHostRegistry.shared.register(hostId: hostId, bridge: bridge)
        pageData[RaftSideActionHostBridgeKt.RaftSideActionHostIdPageDataKey] = hostId
        return (hostId, bridge)
    }

    init(controller: RaftPageViewController, bridge: RaftSideActionHostBridge, hostId: String) {
        self.controller = controller
        self.bridge = bridge
        self.hostId = hostId
        super.init()
        bridge.attachListener(listener: RaftIosWeakSideActionListener(self))
        // Only where the build's SDK and the system have vertical bar items; else the page keeps
        // drawing its own column.
        bridge.setAvailable(available: RaftIosVerticalBarItemsSupported())
    }

    deinit {
        bridge.detachListener()
        RaftSideActionHostRegistry.shared.unregister(hostId: hostId, bridge: bridge)
    }

    func onSideActionColumnChanged(json: String) {
        guard let controller else { return }
        guard let items = RaftIosSideActionItems.make(json: fittingBesideTabs(json, controller), onTap: { [weak self] id in _ = self?.bridge.sideActionTapped(id: id) }) else {
            handBackToPage(reason: "unreadable_column_or_symbol")
            return
        }
        guard RaftIosMakeBarButtonItemsVerticalPreferred(items.leading + items.trailing) else {
            handBackToPage(reason: "no_vertical_bar_items")
            return
        }
        let navigationItem = controller.navigationItem
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItems = items.leading
        // rightBarButtonItems run from the trailing edge in: reversed, they read in listed order.
        navigationItem.rightBarButtonItems = items.trailing.reversed()
        controller.raftSideActionsShown = true
    }

    func onSideActionColumnCleared() {
        // Only take down what this host put up (the replay on attach clears too).
        guard let controller, controller.raftSideActionsShown else { return }
        controller.navigationItem.leftBarButtonItems = nil
        controller.navigationItem.rightBarButtonItems = nil
        controller.navigationItem.hidesBackButton = false
        controller.raftSideActionsShown = false
    }

    /// Self-build (#4581 point 5): the shell's system tab bar shares the vertical bar, and the
    /// system makes no room between the two (on runzhou's Duo the fourth button met the first of five
    /// tabs, and eight slots still touched). Beside it the buttons and the tabs, the server's
    /// included, keep to seven slots: Back stays, and what does not fit (the inner screen's sidebar
    /// toggle too) moves into the ⋯.
    private func fittingBesideTabs(_ json: String, _ controller: RaftPageViewController) -> String {
        guard let tabBar = controller.children.lazy.compactMap({ $0 as? RaftIosTabBarController }).first,
              var column = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return json }
        let primary = column["primary"] as? [[String: Any]] ?? []
        let visible = column["visibleActionIds"] as? [String] ?? []
        let overflow = column["overflowActionIds"] as? [String] ?? []
        let room = 7 - tabBar.shownTabCount
        guard primary.count + visible.count + (overflow.isEmpty ? 0 : 1) > room else { return json }
        let keptPrimary = max(1, min(primary.count, room - 1))
        let keptVisible = max(0, room - 1 - keptPrimary)
        let extra = Array(primary.dropFirst(keptPrimary))
        let moved = extra.compactMap { $0["id"] as? String } + visible.dropFirst(keptVisible)
        let actions = (column["actions"] as? [[String: Any]] ?? []) + extra
        column["primary"] = Array(primary.prefix(keptPrimary))
        column["actions"] = actions
        column["visibleActionIds"] = Array(visible.prefix(keptVisible))
        column["overflowActionIds"] = moved + overflow
        if actions.contains(where: { moved.contains($0["id"] as? String ?? "") && $0["attention"] as? Bool == true }) {
            column["overflowAttention"] = true
        }
        return (try? JSONSerialization.data(withJSONObject: column)).flatMap { String(data: $0, encoding: .utf8) } ?? json
    }

    /// A column the system cannot draw (not JSON, a symbol this system lacks, no vertical bar
    /// items) goes back to the page: the bridge is switched off, so the page draws its own column,
    /// Back included, from its next frame, instead of keeping an empty one. Switched off on the next
    /// main-queue turn, because this is called from inside the page's present().
    private func handBackToPage(reason: String) {
        onSideActionColumnCleared()
        RaftIosDiagnosticsRecord("warn", "SlockCmpHost", "side_actions_page_drawn reason=\(reason)")
        DispatchQueue.main.async { [bridge] in bridge.setAvailable(available: false) }
    }
}
