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
            RaftShakeDetector.shared.start()
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
            _ = RaftIosMobileOAuthHost.shared.acceptCallbackURL(
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
            _ = RaftIosMobileOAuthHost.shared.acceptCallbackURL(
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
        if RaftMessageLinkIngress.shared.accept(url: url.absoluteString, source: "ios_\(source)", configuredWebUrl: nil) {
            RaftIosDiagnosticsRecord("info", "RaftMessageLink", "universal_link_accepted source=\(source)")
            return
        }
        RaftIosDiagnosticsRecord("info", "RaftMessageLink", "universal_link_not_claimed source=\(source)")
        guard url.scheme == "https" else { return }
        DispatchQueue.main.async { [weak self] in
            guard let root = self?.window?.rootViewController else { return }
            var presenter = root
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            presenter.present(SFSafariViewController(url: url), animated: true)
        }
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

/// Self-build (xuheng-li 2026-10-28): shake the phone, or long-press the server button, to share
/// the app's diagnostics log files, the newest launches in full (the Settings export keeps only
/// the last ~120 KB).
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
            .prefix(2)
        let out = files.temporaryDirectory.appendingPathComponent("raft-logs-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? files.createDirectory(at: out, withIntermediateDirectories: true)
        var copies: [URL] = []
        for launch in launches {
            for file in (try? files.contentsOfDirectory(at: launch, includingPropertiesForKeys: nil)) ?? [] {
                let copy = out.appendingPathComponent("\(launch.lastPathComponent)-\(file.lastPathComponent)")
                if (try? files.copyItem(at: file, to: copy)) != nil { copies.append(copy) }
            }
        }
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        var presenter = window?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        guard !copies.isEmpty, let presenter, !(presenter is UIActivityViewController) else { return }
        let sheet = UIActivityViewController(activityItems: copies, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        presenter.present(sheet, animated: true)
    }
}

/// Local simulator debugging only: act out a fold from the command line,
/// `xcrun simctl spawn <udid> notifyutil -p dev.vgent.raft.fold` (window narrow <-> full)
/// or `... dev.vgent.raft.rotate` (portrait <-> landscape).
enum RaftDebugFold {
    static var narrow = false
    static var landscape = false

    /// The window on screen; not necessarily the one this scene delegate made.
    static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
    }

    static func install() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            DispatchQueue.main.async { RaftDebugFold.fold() }
        }, "dev.vgent.raft.fold" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            DispatchQueue.main.async { RaftDebugFold.rotate() }
        }, "dev.vgent.raft.rotate" as CFString, nil, .deliverImmediately)
    }

    static func fold() {
        guard let window, let screen = window.windowScene?.screen else { return }
        narrow.toggle()
        var frame = screen.bounds
        if narrow { frame.size.width = 420 }
        window.frame = frame
        RaftIosDiagnosticsRecordCriticalSynchronously("RaftTouchProbe", "debug_fold narrow=\(narrow) frame=\(frame) window=\(type(of: window))")
    }

    static func rotate() {
        guard #available(iOS 16.0, *), let scene = window?.windowScene else { return }
        landscape.toggle()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeLeft : .portrait)) { error in
            RaftIosDiagnosticsRecordCriticalSynchronously("RaftTouchProbe", "debug_rotate error=\(error)")
        }
        RaftIosDiagnosticsRecordCriticalSynchronously("RaftTouchProbe", "debug_rotate landscape=\(landscape)")
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

    func install(in window: UIWindow) {
        guard button.superview !== window else { return }
        button.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = .black
        button.layer.cornerRadius = 28
        button.accessibilityLabel = "Voice input"
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        bubble.numberOfLines = 4
        bubble.font = .systemFont(ofSize: 15)
        bubble.textColor = .white
        bubble.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        bubble.layer.cornerRadius = 12
        bubble.clipsToBounds = true
        bubble.isHidden = true
        for view in [button, bubble] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(view)
        }
        let guide = window.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 56),
            button.heightAnchor.constraint(equalToConstant: 56),
            button.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -88),
            bubble.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            bubble.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -10),
            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    @objc private func tapped() {
        window?.bringSubviewToFront(button)
        window?.bringSubviewToFront(bubble)
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
                if RaftVoiceInput.type(text) {
                    hide()
                } else {
                    UIPasteboard.general.string = text
                    show("No text field is focused; copied to the clipboard.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.hide() }
                }
            }
            return
        }
        busy = true
        Task { @MainActor in
            do {
                let session = try await RaftVoiceSession.start { [weak self] text in
                    DispatchQueue.main.async { self?.show(text.isEmpty ? "Listening…" : text) }
                }
                self.session = session
                setRecording(true)
                show("Listening…")
            } catch {
                show("Voice input unavailable: \(error.localizedDescription)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.hide() }
            }
            busy = false
        }
    }

    private var window: UIWindow? { button.window }

    private func setRecording(_ on: Bool) {
        button.backgroundColor = on ? .systemRed : .black
        button.setImage(UIImage(systemName: on ? "stop.fill" : "mic.fill"), for: .normal)
    }

    private func show(_ text: String) {
        bubble.text = "  \(text)  "
        bubble.isHidden = false
    }

    private func hide() {
        bubble.isHidden = true
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

    /// Types [text] into the first responder (the focused text field). False when none takes text.
    static func type(_ text: String) -> Bool {
        RaftFirstResponder.current = nil
        UIApplication.shared.sendAction(#selector(UIResponder.raft_captureFirstResponder), to: nil, from: nil, for: nil)
        guard let input = RaftFirstResponder.current as? UIKeyInput else { return false }
        input.insertText(text)
        return true
    }
}

private enum RaftFirstResponder {
    static weak var current: UIResponder?
}

extension UIResponder {
    @objc func raft_captureFirstResponder() {
        RaftFirstResponder.current = self
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

    static func start(onText: @escaping (String) -> Void) async throws -> RaftVoiceSession {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw RaftVoiceError("Microphone access is off (Settings → anyRaft)")
        }
        let preferred = Locale(identifier: Locale.preferredLanguages.first ?? "zh-CN")
        var supported = await SpeechTranscriber.supportedLocale(equivalentTo: preferred)
        if supported == nil {
            supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN"))
        }
        guard let locale = supported else {
            throw RaftVoiceError("This language is not supported")
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
