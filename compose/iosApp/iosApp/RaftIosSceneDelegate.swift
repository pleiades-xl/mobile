import Foundation
import SafariServices
import shared
import SwiftUI
import UIKit
import FoundationModels
import Speech
import AVFoundation
import CoreMotion

// task #471: scene plumbing for iPad multi-window.
//
// Declared via UIApplicationSceneManifest in Info.plist (class name
// `$(PRODUCT_MODULE_NAME).RaftIosSceneDelegate`). One instance exists per
// UISceneSession; each registers its RaftIosShellContext in
// RaftIosShellWindowRegistry so ContentView and the contract can resolve the
// owning shell identity. With a single scene the context stays
// "legacy-app-shell" — identical to the pre-scene behavior.
//
// Because the manifest names a custom scene delegate, SwiftUI no longer creates
// the window for `WindowGroup` — willConnectTo installs the UIHostingController
// itself.
final class RaftIosSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// Shell identity resolved for this scene. ContentView reaches it through
    /// the registry keyed by session.persistentIdentifier.
    let shellContext = RaftIosShellContext()

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let activity = connectionOptions.userActivities.first(where: {
            $0.activityType == RaftIosShellWindowContract.shellUserActivityType
        }), let context = RaftIosShellWindowContract.context(from: activity) {
            shellContext.apply(context)
            RaftIosDiagnosticsRecord(
                "info",
                "RaftIosShellWindow",
                "scene_identity_resolved source=user_activity shell=\(context.shellInstanceId)"
            )
        }
        RaftIosShellWindowRegistry.register(session: session, context: shellContext)
        RaftIosTopBandDiagnostics.install()

        // With a custom scene delegate the App's WindowGroup is inert; the
        // delegate owns window creation.
        if let windowScene = scene as? UIWindowScene {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIHostingController(rootView: ContentView())
            // Settings > Appearance > Theme: an explicit Light/Dark choice overrides the OS
            // style for the whole window (keyboards, system menus, the native tab bar);
            // System leaves it unspecified. The dark canvas behind the first frame avoids a
            // white flash.
            window.backgroundColor = UIColor(raftArgb: RaftAppAppearanceRuntime.shared.canvasArgb)
            window.overrideUserInterfaceStyle = UIUserInterfaceStyle(
                rawValue: Int(RaftAppAppearanceRuntime.shared.hostStyleCode)
            ) ?? .unspecified
            self.window = window
            RaftIosAppearanceHost.attach()
            window.makeKeyAndVisible()
        }

        // Product analytics: a launch for a URL or a link is not a plain launcher open.
        if !connectionOptions.urlContexts.isEmpty || connectionOptions.userActivities.contains(where: {
            $0.activityType != RaftIosShellWindowContract.shellUserActivityType
        }) {
            RaftIosProductEventsHost.shared.noteOtherLaunch()
        }
        for context in connectionOptions.urlContexts {
            RaftIosOpenURL.accept(
                context.url,
                shellInstanceId: shellInstanceId(for: scene),
                source: "scene_connect"
            )
        }
        if let response = connectionOptions.notificationResponse {
            let content = response.notification.request.content
            RaftIosPushHost.acceptSystemNotificationOpen(
                userInfo: content.userInfo,
                categoryIdentifier: content.categoryIdentifier,
                shellInstanceId: shellInstanceId(for: scene),
                source: "scene_connect"
            )
        }
        // Cold launch from a Universal Link (a Raft message link).
        for activity in connectionOptions.userActivities
        where activity.activityType == NSUserActivityTypeBrowsingWeb {
            acceptBrowsingWebActivity(activity, source: "scene_connect")
        }
        if let shortcutItem = connectionOptions.shortcutItem {
            RaftIosDesktopShortcutHost.acceptShortcutItem(
                shortcutItem,
                shellInstanceId: shellInstanceId(for: scene),
                source: "scene_connect"
            )
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            RaftIosOpenURL.accept(
                context.url,
                shellInstanceId: shellInstanceId(for: scene),
                source: "scene_open_url"
            )
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb {
            acceptBrowsingWebActivity(userActivity, source: "scene_continue")
            return
        }
        guard let context = RaftIosShellWindowContract.context(from: userActivity) else {
            return
        }
        shellContext.apply(context)
        RaftIosDiagnosticsRecord(
            "info",
            "RaftIosShellWindow",
            "scene_identity_updated source=continue_activity shell=\(context.shellInstanceId)"
        )
    }

    /// #proj-mobile #26: a Universal Link on app.raft.build / open.raft.build (or the Developer
    /// environment's web host). The shared inbox keeps a message link until the app shell has a
    /// ready session (through sign-in), then opens it through the same window navigation queue as
    /// a notification tap. Anything else the AASA routed here goes back to the web, in an in-app
    /// Safari view: `UIApplication.open` on our own Universal Link could route it straight back.
    private func acceptBrowsingWebActivity(_ activity: NSUserActivity, source: String) {
        guard let url = activity.webpageURL else { return }
        if RaftIosMessageLinkOpen.accept(url.absoluteString, source: "ios_\(source)") {
            RaftIosDiagnosticsRecord("info", "RaftMessageLink", "universal_link_accepted source=\(source)")
            return
        }
        RaftIosDiagnosticsRecord("info", "RaftMessageLink", "universal_link_not_claimed source=\(source)")
        guard url.scheme == "https" else { return }
        // The sign-up email of an account created in this app's web sign-in, naming the request
        // the app is still waiting for: reopen it in a new web sign-in sheet (replacing the one
        // left on "check your email"; the pending request survives). It shares that sheet's
        // browser session, so the web verifies, finishes the pending sign-in and calls back here;
        // the default browser would have no session and ask to sign in again. Any other request
        // (a Raft Desktop sign-up, an expired one) goes to in-app Safari below.
        if RaftMessageLinkIngress.shared.resumesPendingAppLogin(url: url.absoluteString, configuredWebUrl: nil) {
            DispatchQueue.main.async { [weak self] in
                RaftIosMobileOAuthHost.shared.openAppLogin(url: url.absoluteString, presentingWindow: self?.window) { result in
                    let started = (result["status"] as? String) == "started"
                    RaftIosDiagnosticsRecord("info", "SlockIosAppLogin", "verification_link_resume source=\(source) started=\(started)")
                    if !started { self?.presentInAppSafari(url) }
                }
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.presentInAppSafari(url)
        }
    }

    private func presentInAppSafari(_ url: URL) {
        guard let root = window?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        presenter.present(SFSafariViewController(url: url), animated: true)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        RaftIosDesktopShortcutHost.acceptShortcutItem(
            shortcutItem,
            shellInstanceId: shellInstanceId(for: windowScene),
            source: "scene_perform_action"
        )
        completionHandler(true)
    }

    /// task #483: shell owning this scene, resolved live from the registry so a
    /// `scene(_:continue:)` retarget is honored; `shellContext` is the fallback.
    private func shellInstanceId(for scene: UIScene) -> String {
        RaftIosShellWindowRegistry.context(forSessionId: scene.session.persistentIdentifier)?
            .shellInstanceId ?? shellContext.shellInstanceId
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        let context = RaftIosShellWindowRegistry.unregister(session: scene.session)
        guard let shellInstanceId = context?.shellInstanceId,
              shellInstanceId != RaftIosShellWindowContract.legacyShellInstanceId else {
            return
        }
        // Only document shells get their shared-store scope released; the legacy
        // shell scope is process-wide and stays alive across scene drops.
        RaftShellStoreLaunchKt.releaseRaftShellStoreScope(
            shellInstanceId: shellInstanceId,
            serverId: context?.serverId
        )
        RaftIosDiagnosticsRecord(
            "info",
            "RaftIosShellWindow",
            "scene_released shell=\(shellInstanceId)"
        )
    }
}

/// Applies the app theme choice (`RaftAppAppearanceRuntime`) to every window of the app.
enum RaftIosAppearanceHost {
    static func attach() {
        RaftAppAppearanceRuntime.shared.setHostListener { code in
            let style = UIUserInterfaceStyle(rawValue: Int(truncating: code)) ?? .unspecified
            let canvas = UIColor(raftArgb: RaftAppAppearanceRuntime.shared.canvasArgb)
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    window.overrideUserInterfaceStyle = style
                    window.backgroundColor = canvas
                }
            }
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Posted after every theme choice is applied to the windows.
    static let didChangeNotification = Notification.Name("RaftIosAppearanceDidChange")

    /// The app's explicit Light/Dark choice, or `.unspecified` to follow the system.
    static var currentStyle: UIUserInterfaceStyle {
        UIUserInterfaceStyle(rawValue: Int(RaftAppAppearanceRuntime.shared.hostStyleCode)) ?? .unspecified
    }
}

extension UIColor {
    /// `0xAARRGGBB` as produced by Compose `Color.toArgb()`.
    convenience init(raftArgb argb: Int32) {
        let value = UInt32(bitPattern: argb)
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: CGFloat((value >> 24) & 0xFF) / 255.0
        )
    }
}

/// Self-build: a message link (a notification, a Universal Link, a `raft://` link) opens from the
/// app shell. A shell covered by other pages does not recompose, so it took the link only once
/// they closed, when the user pressed Back, and the app then jumped to it; the pages close first.
enum RaftIosMessageLinkOpen {
    static func accept(_ url: String, source: String) -> Bool {
        let accepted = RaftMessageLinkIngress.shared.accept(url: url, source: source, configuredWebUrl: nil)
        if accepted { DispatchQueue.main.async(execute: popToShell) }
        return accepted
    }

    private static func popToShell() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                guard let navigation = navigationController(in: window.rootViewController) else { continue }
                navigation.presentedViewController?.dismiss(animated: false)
                if navigation.viewControllers.count > 1 {
                    RaftIosDiagnosticsRecord("info", "RaftMessageLink", "message_link_pop_to_shell pages=\(navigation.viewControllers.count - 1)")
                    navigation.popToRootViewController(animated: false)
                }
            }
        }
    }

    private static func navigationController(in controller: UIViewController?) -> UINavigationController? {
        guard let controller else { return nil }
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let found = navigationController(in: child) { return found }
        }
        return nil
    }
}

/// A URL opened into the app (`raft://…`): a sign-in callback, else a Raft Desktop message link
/// (`raft:///s/{slug}/channel/{cid}?msg={mid}`), which the shared ingress turns into the Developer
/// environment's web link and queues like a Universal Link. Anything else is ignored, as before.
enum RaftIosOpenURL {
    static func accept(_ url: URL, shellInstanceId: String? = nil, source: String) {
        if RaftIosMobileOAuthHost.shared.acceptCallbackURL(url, shellInstanceId: shellInstanceId, source: source) {
            return
        }
        let accepted = RaftIosMessageLinkOpen.accept(url.absoluteString, source: "ios_\(source)")
        RaftIosDiagnosticsRecord(
            "info",
            "RaftMessageLink",
            "app_scheme_link_\(accepted ? "accepted" : "not_claimed") source=\(source)"
        )
    }
}

/// Self-build (xuheng-li 2026-10-28): shake the phone, or long-press Settings in the side dock, to
/// share the app's diagnostics log files, the newest launches in full (the Settings export keeps
/// only the last ~120 KB).
///
/// iOS hands the shake gesture to the first responder only, which Raft's views never pass on (and
/// with nothing focused there is none), so the accelerometer detects the shake itself: three
/// readings over 1.8 g within 0.8 s.
final class RaftShakeDetector {
    static let shared = RaftShakeDetector()
    private let motion = CMMotionManager()
    private var peaks: [TimeInterval] = []
    private var lastShare: TimeInterval = 0

    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 1.0 / 30.0
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            guard (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() > 1.8 else { return }
            let now = Date().timeIntervalSince1970
            self.peaks = self.peaks.filter { now - $0 < 0.8 } + [now]
            guard self.peaks.count >= 3, now - self.lastShare > 3 else { return }
            self.peaks.removeAll()
            self.lastShare = now
            RaftIosDiagnosticsRecordCriticalSynchronously("RaftShakeShare", "shake_share source=accelerometer")
            RaftLogShare.present()
        }
    }
}

enum RaftLogShare {
    /// The diagnostics queue writes entries asynchronously: wait a moment so the latest ones (the
    /// taps just before the share) are in the files.
    static func present() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { presentNow() }
    }

    private static func presentNow() {
        let files = FileManager.default
        guard let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let root = support.appendingPathComponent("raft_diagnostics_logs", isDirectory: true)
        let launches = ((try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("launch-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(3)
        let out = files.temporaryDirectory.appendingPathComponent("raft-logs-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? files.createDirectory(at: out, withIntermediateDirectories: true)
        var copies: [URL] = []
        for launch in launches {
            for file in (try? files.contentsOfDirectory(at: launch, includingPropertiesForKeys: nil)) ?? [] {
                let copy = out.appendingPathComponent("\(launch.lastPathComponent)-\(file.lastPathComponent)")
                if (try? files.copyItem(at: file, to: copy)) != nil { copies.append(copy) }
            }
        }
        // iPhone Duo has a scene per screen: present on the one in use, not the folded-away one.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var presenter = scene?.keyWindow?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        RaftIosDiagnosticsRecordCriticalSynchronously(
            "RaftShareLogs",
            "share_logs_present files=\(copies.count) presenter=\(presenter.map { String(describing: type(of: $0)) } ?? "none")"
        )
        guard !copies.isEmpty, let presenter, !(presenter is UIActivityViewController) else { return }
        let sheet = UIActivityViewController(activityItems: copies, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        presenter.present(sheet, animated: true)
    }
}

/// Self-build (xuheng-li 2026-10-30): voice input for Apple Vision Pro, which takes no third-party
/// keyboards. A floating mic button: tap to talk (on-device SpeechAnalyzer, live text in a bubble),
/// tap again to stop; the on-device model (Foundation Models) tidies the text, which is then typed
/// into the focused text field, as a keyboard would.
@available(iOS 26.0, *)
final class RaftVoiceInput: NSObject {
    static let shared = RaftVoiceInput()

    private let button = UIButton(type: .system)
    private let bubble = UILabel()
    private var session: RaftVoiceSession?
    private var busy = false
    /// The text field that had focus when recording started; the text goes there.
    private weak var target: UIResponder?

    private static let localeKey = "RaftVoiceInputLocale"
    private static let centerKey = "RaftVoiceInputButtonCenter"

    /// Chinese unless the user switched to English (long press).
    private var localeIdentifier: String {
        get { UserDefaults.standard.string(forKey: Self.localeKey) ?? "zh-CN" }
        set { UserDefaults.standard.set(newValue, forKey: Self.localeKey) }
    }

    func install(in window: UIWindow) {
        if button.superview === window {
            button.center = clamped(button.center, in: window)
            return
        }
        button.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = .black
        button.layer.cornerRadius = 28
        button.frame = CGRect(x: 0, y: 0, width: 56, height: 56)
        button.accessibilityLabel = "Voice input"
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(switchLanguage(_:))))
        bubble.numberOfLines = 4
        bubble.font = .systemFont(ofSize: 15)
        bubble.textColor = .white
        bubble.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        bubble.layer.cornerRadius = 12
        bubble.clipsToBounds = true
        bubble.isHidden = true
        window.addSubview(bubble)
        window.addSubview(button)
        // On the right edge, halfway up: clear of the composer and its send button. Draggable.
        let saved = UserDefaults.standard.string(forKey: Self.centerKey).map(NSCoder.cgPoint(for:))
        button.center = clamped(saved ?? CGPoint(x: window.bounds.maxX - 48, y: window.bounds.midY), in: window)
    }

    private func clamped(_ point: CGPoint, in window: UIWindow) -> CGPoint {
        let inset = window.safeAreaInsets
        return CGPoint(
            x: min(max(point.x, inset.left + 32), window.bounds.maxX - inset.right - 32),
            y: min(max(point.y, inset.top + 32), window.bounds.maxY - inset.bottom - 32)
        )
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard let window = button.window else { return }
        let move = pan.translation(in: window)
        pan.setTranslation(.zero, in: window)
        button.center = clamped(CGPoint(x: button.center.x + move.x, y: button.center.y + move.y), in: window)
        layoutBubble()
        if pan.state == .ended {
            UserDefaults.standard.set(NSCoder.string(for: button.center), forKey: Self.centerKey)
        }
    }

    @objc private func switchLanguage(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began, session == nil, !busy else { return }
        localeIdentifier = localeIdentifier.hasPrefix("zh") ? "en-US" : "zh-CN"
        flash(localeIdentifier.hasPrefix("zh") ? "中文" : "English")
    }

    @objc private func tapped() {
        if busy { return }
        if let session {
            self.session = nil
            busy = true
            show("…")
            Task { @MainActor in
                let raw = await session.stop()
                let text = await RaftVoiceInput.tidy(raw)
                busy = false
                setRecording(false)
                if text.isEmpty { hide(); return }
                if type(text) {
                    hide()
                } else {
                    UIPasteboard.general.string = text
                    flash("Copied to the clipboard: tap a text field first to type it in.")
                }
            }
            return
        }
        target = focusedResponder()
        busy = true
        Task { @MainActor in
            do {
                let session = try await RaftVoiceSession.start(locale: Locale(identifier: localeIdentifier)) { [weak self] text in
                    DispatchQueue.main.async { self?.show(text.isEmpty ? "Listening…" : text) }
                }
                self.session = session
                setRecording(true)
                show(localeIdentifier.hasPrefix("zh") ? "请说…" : "Listening…")
            } catch {
                flash("Voice input unavailable: \(error.localizedDescription)")
            }
            busy = false
        }
    }

    /// The focused text field in any of this scene's windows.
    private func focusedResponder() -> UIResponder? {
        func find(_ view: UIView) -> UIResponder? {
            if view.isFirstResponder { return view }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        for window in button.window?.windowScene?.windows ?? [] {
            if let found = find(window) { return found }
        }
        return nil
    }

    /// Types [text] into the field focused when recording started (or the one focused now).
    private func type(_ text: String) -> Bool {
        guard let responder = target ?? focusedResponder(), let input = responder as? UIKeyInput else { return false }
        if !responder.isFirstResponder { _ = responder.becomeFirstResponder() }
        input.insertText(text)
        return true
    }

    private func setRecording(_ on: Bool) {
        button.backgroundColor = on ? .systemRed : .black
        button.setImage(UIImage(systemName: on ? "stop.fill" : "mic.fill"), for: .normal)
    }

    private func show(_ text: String) {
        bubble.text = "  \(text)  "
        bubble.isHidden = false
        layoutBubble()
    }

    private func flash(_ text: String) {
        show(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.session == nil { self?.hide() }
        }
    }

    private func hide() {
        bubble.isHidden = true
    }

    /// Beside the button, on the side with more room.
    private func layoutBubble() {
        guard let window = button.window, !bubble.isHidden else { return }
        window.bringSubviewToFront(bubble)
        window.bringSubviewToFront(button)
        let size = bubble.sizeThatFits(CGSize(width: 360, height: 200))
        let width = min(size.width, 360)
        let height = min(size.height + 12, 120)
        let onLeft = button.center.x > window.bounds.midX
        let x = onLeft ? button.frame.minX - 10 - width : button.frame.maxX + 10
        let y = min(max(button.center.y - height / 2, 8), window.bounds.maxY - height - 8)
        bubble.frame = CGRect(x: x, y: y, width: width, height: height)
    }

    /// Removes fillers, adds punctuation and paragraphs with the on-device model; the raw text
    /// when the model is unavailable or fails.
    static func tidy(_ raw: String) async -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, case .available = SystemLanguageModel.default.availability else { return text }
        let session = LanguageModelSession(instructions: """
            You tidy dictated text. Rewrite the user's dictation as clean written text in the same \
            language (keep mixed Chinese and English as spoken): remove fillers and repetitions \
            (嗯、啊、那个、就是说, um, uh), fix punctuation, split paragraphs or lists where the \
            speaker clearly enumerates. Do not add, drop or answer anything. Output only the text.
            """)
        do {
            let tidied = try await session.respond(to: text).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return tidied.isEmpty ? text : tidied
        } catch {
            return text
        }
    }
}

/// One dictation: the microphone into SpeechAnalyzer, reporting the running text.
@available(iOS 26.0, *)
final class RaftVoiceSession {
    private let engine = AVAudioEngine()
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var finalized = ""
    private var volatile = ""
    private var results: Task<Void, Never>?

    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzer = analyzer
        self.input = input
    }

    static func start(locale preferred: Locale, onText: @escaping (String) -> Void) async throws -> RaftVoiceSession {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw RaftVoiceError("Microphone access is off (Settings → anyRaft)")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) else {
            throw RaftVoiceError("\(preferred.identifier) is not supported")
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let session = RaftVoiceSession(analyzer: analyzer, input: continuation)
        session.results = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        session.finalized += text
                        session.volatile = ""
                    } else {
                        session.volatile = text
                    }
                    onText(session.finalized + session.volatile)
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)

        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)
        let node = session.engine.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? micFormat
        let converter = AVAudioConverter(from: micFormat, to: targetFormat)
        node.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            guard let converter, micFormat != targetFormat else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / micFormat.sampleRate) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
        }
        session.engine.prepare()
        try session.engine.start()
        return session
    }

    /// Stops the microphone and returns the whole transcript.
    func stop() async -> String {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results?.value
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return finalized + volatile
    }
}

struct RaftVoiceError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Self-build (runzhou-tao, xuheng-li 2026-11-08): the keyboard's "Paste from …" (and any other
/// system paste) into the composer with only an image on the clipboard attaches the image. The
/// editor view is Compose's, which pastes text only; its class gets `paste:` hooked the first time
/// it brings up the keyboard.
enum RaftImagePasteHook {
    private static var hooked = Set<ObjectIdentifier>()
    fileprivate static weak var firstResponder: UIResponder?

    static func install() {
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { _ in hookFirstResponder() }
    }

    private static var imageOnly: Bool {
        let board = UIPasteboard.general
        return board.hasImages && !board.hasStrings
    }

    private static func hookFirstResponder() {
        firstResponder = nil
        UIApplication.shared.sendAction(#selector(UIResponder.raftCaptureFirstResponder), to: nil, from: nil, for: nil)
        guard let responder = firstResponder else {
            RaftIosDiagnosticsRecordCriticalSynchronously("RaftImagePaste", "no first responder")
            return
        }
        let cls: AnyClass = type(of: responder)
        guard hooked.insert(ObjectIdentifier(cls)).inserted else { return }
        // The composer's editor is a native text view (Compose's iOS text input); hooking its class also
        // covers other fields of that class, where an image-only paste was a no-op anyway.
        RaftIosDiagnosticsRecordCriticalSynchronously("RaftImagePaste", "hook class=\(NSStringFromClass(cls))")

        let canSel = #selector(UIResponder.canPerformAction(_:withSender:))
        if let method = class_getInstanceMethod(cls, canSel) {
            typealias Can = @convention(c) (AnyObject, Selector, Selector, Any?) -> Bool
            let original = unsafeBitCast(method_getImplementation(method), to: Can.self)
            let replacement: @convention(block) (AnyObject, Selector, Any?) -> Bool = { view, action, sender in
                if action == #selector(UIResponderStandardEditActions.paste(_:)) && imageOnly { return true }
                return original(view, canSel, action, sender)
            }
            let imp = imp_implementationWithBlock(replacement)
            if !class_addMethod(cls, canSel, imp, method_getTypeEncoding(method)) { method_setImplementation(method, imp) }
        }

        let pasteSel = #selector(UIResponderStandardEditActions.paste(_:))
        typealias Paste = @convention(c) (AnyObject, Selector, Any?) -> Void
        let original = class_getInstanceMethod(cls, pasteSel).map { unsafeBitCast(method_getImplementation($0), to: Paste.self) }
        let replacement: @convention(block) (AnyObject, Any?) -> Void = { view, sender in
            if imageOnly {
                RaftIosDiagnosticsRecordCriticalSynchronously("RaftImagePaste", "system_paste image")
                RaftImagePasteBridgeKt.raftRequestImagePaste()
                return
            }
            original?(view, pasteSel, sender)
        }
        let imp = imp_implementationWithBlock(replacement)
        if let method = class_getInstanceMethod(cls, pasteSel) {
            if !class_addMethod(cls, pasteSel, imp, method_getTypeEncoding(method)) { method_setImplementation(method, imp) }
        } else {
            class_addMethod(cls, pasteSel, imp, "v@:@")
        }
    }
}

extension UIResponder {
    @objc fileprivate func raftCaptureFirstResponder() { RaftImagePasteHook.firstResponder = self }
}
