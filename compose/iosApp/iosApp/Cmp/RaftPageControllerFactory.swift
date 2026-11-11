import Foundation
import UIKit
import shared

/// Creates the view controller for a page name on iOS. Every page renders through Compose
/// Multiplatform: a `RaftPageViewController` (page host: navigation, host events, adaptive panes,
/// gestures) embedding the CMP page's controller (`RaftCmpIos.makePage`). Every place that
/// opens a page (`RaftPageRouter`, `HRBridgeModule` openPage, the SwiftUI root) asks this
/// factory. Page names and pageData are passed through untouched.
@objc final class RaftPageControllerFactory: NSObject {
    /// Call once at launch, before the first page is created.
    @objc static func configure() {
        #if DEBUG
        RaftCmpIos.shared.configure(debugBuild: true)
        #else
        RaftCmpIos.shared.configure(debugBuild: false)
        #endif
    }

    @objc(controllerForPageName:pageData:)
    static func controller(pageName: String, pageData: [AnyHashable: Any]) -> UIViewController {
        if !RaftCmpIos.shared.rendersOnCmp(pageName: pageName) {
            // RaftCmpRoot renders the unknown-page surface; keep a diagnostic trail.
            RaftIosDiagnosticsRecord("warn", "SlockCmpHost", "cmp_host_unknown_page page=\(pageName)")
        }
        // The app shell's bottom tabs are drawn by a system UITabBarController
        // (RaftIosTabBarController); shared finds its bridge through the host id in pageData.
        // Any other page drops an inherited id so it never publishes into a shell's bar.
        var hostPageData = pageData
        hostPageData.removeValue(forKey: RaftIosTabBarController.hostIdPageDataKey)
        var nativeTabBar: (hostId: String, bridge: RaftNativeTabBarBridge)?
        if RaftIosTabBarController.hostsNativeTabBar(pageName: pageName) {
            let hostId = UUID().uuidString
            let bridge = RaftNativeTabBarBridge()
            RaftNativeTabBarRegistry.shared.register(hostId: hostId, bridge: bridge)
            hostPageData[RaftIosTabBarController.hostIdPageDataKey] = hostId
            nativeTabBar = (hostId, bridge)
        }
        // PROTOTYPE (native nav bar): pages whose head is the real UINavigationBar.
        hostPageData.removeValue(forKey: RaftNativeNavBarHostIdPageDataKeyName)
        var nativeNavBar: (hostId: String, bridge: RaftNativeNavBarBridge)?
        let usesNativeNavBar = RaftNativeNavProto.usesNativeNavBar(pageName: pageName)
        if usesNativeNavBar || RaftNativeNavProto.scriptsPage(pageName: pageName) {
            let hostId = UUID().uuidString
            let bridge = RaftNativeNavBarBridge()
            // Prototype off in a capture: the bridge only lets the script scroll the page's list.
            bridge.hostDrawsBar = usesNativeNavBar
            RaftNativeNavBarRegistry.shared.register(hostId: hostId, bridge: bridge)
            hostPageData[RaftNativeNavBarHostIdPageDataKeyName] = hostId
            nativeNavBar = (hostId, bridge)
        }
        // Self-build (runzhou-tao 2026-11-10): the iPhone Duo side column's buttons are the system's
        // own bar buttons in the vertical bar (iOS 27.1), not drawn by the page.
        hostPageData.removeValue(forKey: raftSideActionHostPageDataKey)
        let sideActionBridge = RaftSideActionHostBridge()
        let sideActionHostId = UUID().uuidString
        if #available(iOS 27.1, *) {
            RaftSideActionHostRegistry.shared.register(hostId: sideActionHostId, bridge: sideActionBridge)
            hostPageData[raftSideActionHostPageDataKey] = sideActionHostId
        }
        let container = RaftPageViewController(pageName: pageName, pageData: hostPageData)
        if #available(iOS 27.1, *) {
            container.raftSideActionHost = RaftIosSideActionHost(
                controller: container, bridge: sideActionBridge, hostId: sideActionHostId
            )
        }
        if let nativeNavBar = nativeNavBar {
            container.raftUsesNativeNavBar = usesNativeNavBar
            let navHost = RaftNativeNavBarHost(
                controller: container,
                bridge: nativeNavBar.bridge,
                hostId: nativeNavBar.hostId,
                largeTitle: usesNativeNavBar && RaftNativeNavProto.usesLargeTitle(pageName: pageName)
            )
            container.raftNativeNavBarHost = navHost
            if usesNativeNavBar {
                navHost.attach()
            }
        }
        // Before the page's first composition: the last painted canvas, else the resolved app
        // theme's canvas (the stored Light/Dark/System choice), so nothing flashes white.
        container.raftInitialBackgroundColor =
            RaftCmpIos.shared.lastCanvasColor()
            ?? UIColor(raftArgb: RaftAppAppearanceRuntime.shared.canvasArgb)
        // Status bar icons from the first frame, not only after composition: by what the page
        // will paint under the status bar (the app shell's head paints the theme frame, other
        // pages mostly the canvas), judged by luminance like the page's own report.
        container.raftSetDarkTheme(
            RaftAppAppearanceRuntime.shared.statusBarBackdropDark(frameUnderStatusBar: container.raftIsAppShellPage)
        )
        let bridge = RaftCmpBridgeHost()
        bridge.hostController = container
        let navigator = RaftCmpPageNavigator()
        navigator.controller = container
        let listener = RaftPageListener()
        listener.controller = container
        let page = RaftCmpIos.shared.makePage(
            pageName: pageName,
            pageDataJson: jsonText(container.raftPageData),
            bridge: bridge,
            navigator: navigator,
            listener: listener
        )
        let content: UIViewController
        if let nativeTabBar = nativeTabBar {
            content = RaftIosTabBarController(
                content: page.viewController,
                bridge: nativeTabBar.bridge,
                hostId: nativeTabBar.hostId,
                keepsEdgeTouches: { point in page.keepsEdgeTouches(x: Double(point.x), y: Double(point.y)) }
            )
        } else if #available(iOS 26.0, *) {
            // Self-build: on iPhone Duo the shell's tabs stay in the side column over pushed pages.
            content = RaftIosTabBarController(mirroring: page.viewController)
        } else {
            content = page.viewController
        }
        container.attachContent(content) { event, data in
            page.sendEvent(event: event, dataJson: RaftPageControllerFactory.jsonText(data))
        }
        // Full-page back swipe: Compose horizontal content reports back-direction consumption.
        container.raftBackSwipeContentProbe = { point in
            page.contentConsumesBackSwipe(x: Double(point.x), y: Double(point.y))
        }
        // Covered (a native push, a full-screen presentation): the page closes its overlays.
        container.raftPageWillBeCoveredHook = {
            page.pageWillBeCovered()
        }
        return container
    }

    fileprivate static func jsonText(_ object: [AnyHashable: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}

/// Self-build: a page's iPhone Duo side column (`RaftSideActionHostBridge`) as the page's navigation
/// bar buttons, which iOS 27.1 puts in the Duo's vertical bar (`axisBehavior = .verticalPreferred`)
/// beside the system tab bar: the system's own glass buttons. Back's group leads, the page's
/// actions and the ⋯ trail; taps go back to the page by id.
private let raftSideActionHostPageDataKey = "slockSideActionHostId"

@available(iOS 27.1, *)
final class RaftIosSideActionHost: NSObject, RaftSideActionHostListener {
    private weak var controller: RaftPageViewController?
    private let bridge: RaftSideActionHostBridge
    private let hostId: String

    init(controller: RaftPageViewController, bridge: RaftSideActionHostBridge, hostId: String) {
        self.controller = controller
        self.bridge = bridge
        self.hostId = hostId
        super.init()
        bridge.attachListener(listener: self)
        bridge.setAvailable(available: true)
    }

    deinit {
        bridge.detachListener()
        RaftSideActionHostRegistry.shared.unregister(hostId: hostId, bridge: bridge)
    }

    func onSideActionColumnChanged(json: String) {
        guard let controller,
              let column = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return }
        let actions = column["actions"] as? [[String: Any]] ?? []
        let byId = Dictionary(actions.map { ($0["id"] as? String ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        let pick = { (key: String) in (column[key] as? [String] ?? []).compactMap { byId[$0] } }
        let leading = (column["primary"] as? [[String: Any]] ?? []).map(button)
        var visible = pick("visibleActionIds")
        var overflow = pick("overflowActionIds")
        // The shell's system tab bar shares the vertical bar, and the system does not make room
        // between the two (the buttons overlapped the tabs, also on the tabs' own navigation
        // bars): beside it the buttons and the tabs (the server's included) keep to eight slots,
        // the ⋯ at least. On runzhou's Duo the fourth button met the first of five tabs.
        if let tabBar = controller.children.lazy.compactMap({ $0 as? RaftIosTabBarController }).first {
            let room = max(1, 8 - tabBar.shownTabCount - leading.count)
            if visible.count + (overflow.isEmpty ? 0 : 1) > room {
                overflow = Array(visible.dropFirst(room - 1)) + overflow
                visible = Array(visible.prefix(room - 1))
            }
        }
        var trailing = visible.map(button)
        if !overflow.isEmpty {
            let rows = overflow.map { action in
                let id = action["id"] as? String ?? ""
                return UIAction(
                    title: action["label"] as? String ?? "",
                    image: UIImage(systemName: action["systemSymbol"] as? String ?? ""),
                    attributes: action["enabled"] as? Bool == false ? .disabled : []
                ) { [weak self] _ in _ = self?.bridge.sideActionTapped(id: id) }
            }
            let more = UIBarButtonItem(title: nil, image: UIImage(systemName: "ellipsis"), primaryAction: nil, menu: UIMenu(children: rows))
            more.accessibilityLabel = column["overflowLabel"] as? String
            if column["overflowAttention"] as? Bool == true { more.badge = MainActor.assumeIsolated { .indicator() } }
            trailing.append(more)
        }
        (leading + trailing).forEach { $0.axisBehavior = .verticalPreferred }
        let item = controller.navigationItem
        item.hidesBackButton = true
        item.leftBarButtonItems = leading
        // rightBarButtonItems run from the trailing edge in: reversed, they read in listed order.
        item.rightBarButtonItems = trailing.reversed()
        controller.raftSideActionsShown = true
    }

    func onSideActionColumnCleared() {
        guard let controller else { return }
        controller.navigationItem.leftBarButtonItems = nil
        controller.navigationItem.rightBarButtonItems = nil
        controller.navigationItem.hidesBackButton = false
        controller.raftSideActionsShown = false
    }

    private func button(_ action: [String: Any]) -> UIBarButtonItem {
        let id = action["id"] as? String ?? ""
        let item = UIBarButtonItem(
            title: nil,
            image: UIImage(systemName: action["systemSymbol"] as? String ?? ""),
            primaryAction: UIAction { [weak self] _ in _ = self?.bridge.sideActionTapped(id: id) },
            menu: nil
        )
        item.accessibilityLabel = action["label"] as? String
        item.isEnabled = action["enabled"] as? Bool ?? true
        if action["attention"] as? Bool == true { item.badge = MainActor.assumeIsolated { .indicator() } }
        return item
    }
}

/// Host navigation for one CMP page (Kotlin `RaftCmpIosNavigator`): `RouterModule.openPage` /
/// `closePage` through `RaftPageRouter` (the former Kuikly router handler: identity-only pageData,
/// `slockReplaceCurrentPage`, login replacement dedupe; push, or present when there is no
/// navigation controller; close pops, or dismisses a presented stack).
private final class RaftCmpPageNavigator: NSObject, RaftCmpIosNavigator {
    /// Weak: the page owns the Kotlin host that owns this navigator.
    weak var controller: UIViewController?
    private let router = RaftPageRouter()

    func openPage(pageName: String, pageDataJson: String) {
        let pageData =
            (try? JSONSerialization.jsonObject(with: Data(pageDataJson.utf8))) as? [AnyHashable: Any] ?? [:]
        onMain { [weak self] in
            guard let self, let controller = self.controller else { return }
            self.router.openPage(withName: pageName, pageData: pageData, controller: controller)
        }
    }

    func closePage() {
        onMain { [weak self] in
            guard let self, let controller = self.controller else { return }
            self.router.closePage(controller)
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

/// Page -> host notifications for one CMP page (Kotlin `RaftIosPageListener`).
private final class RaftPageListener: NSObject, RaftIosPageListener {
    /// Weak: the page owns the Kotlin host that owns this listener.
    weak var controller: RaftPageViewController?

    func onDarkThemeResolved(dark: Bool) {
        controller?.raftSetDarkTheme(dark)
    }
}
