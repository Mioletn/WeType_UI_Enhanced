// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's game screen.
//
// Two very different screens hide behind one view controller, and the app
// decides which:
//
//   * An app the native runtime drives (Unity, cocos2d-x, Minecraft, SDL,
//     Unreal, Godot, GTA, GameMaker, the Java runtime, Flutter) gets a
//     TLUnityUIView: the runtime hands that view's CAMetalLayer to EGL and the
//     game draws into it on its own thread through ANGLE. CAMetalLayer is iOS 8
//     and ANGLE here is built for 12.2, so this runs on 12.2 like the rest.
//   * Anything else runs on the older prototype loader, whose frames come back
//     as pixels. TLScreenUIView (upstream's, plain UIKit) presents them and
//     turns touches back into the guest's coordinates; LegacyAttemptRunner
//     drives the run. That path is iOS-version-agnostic and is what makes
//     iOS 12.2 work at all.
import UIKit

final class LegacyGameViewController: UIViewController {
    private let app: TLApp
    private var gameView: TLScreenUIView?
    /// Set when the native runtime owns the screen: the game draws into this
    /// view's CAMetalLayer through ANGLE, and nothing comes back as pixels.
    private var nativeView: TLUnityUIView?
    private var nativeTimer: DispatchSourceTimer?
    private var statusLabel = UILabel()
    private var chromeHidden = false
    private var logVisible = false
    private var logTextView = UITextView()
    private var logTimer: DispatchSourceTimer?

    init(app: TLApp) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var prefersStatusBarHidden: Bool { true }

    /// A landscape game in a portrait-first shell: the delegate's mask is the
    /// only place this app consults (nothing in the shell overrides it), so
    /// setting it here is what turns the screen -- the same call upstream's
    /// game screen makes when it appears.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard app.report?.nativeEngine != nil else { return }
        HuskOrientation.set(app.drawsPortraitByManifest() ? .portrait : .landscape)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard app.report?.nativeEngine != nil else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        HuskOrientation.set(HuskOrientation.standard)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        logWindowState("on appear")
        // Once more after layout has settled: a window that is hidden, behind
        // another, or of the wrong size at the moment a frame is first presented
        // is the difference between a picture and a black screen, and only the
        // second look is after Auto Layout has run.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.logWindowState("after 1 s")
        }
    }

    /// Every UIWindow, in front-to-back order, with the one this screen is in
    /// marked. A game layer can be unhidden, opaque and in a key window and still
    /// be covered by another window -- that is invisible in every other log line,
    /// so the whole list goes in.
    private func logWindowState(_ when: String) {
        let screen = UIScreen.main
        let windows = UIApplication.shared.windows
        HuskLog.log("ui", "windows \(windows.count) \(when); screen \(screen.bounds.size) "
                  + "native \(screen.nativeBounds.size) scale \(screen.scale)/\(screen.nativeScale)")
        for (i, w) in windows.enumerated() {
            let root = w.rootViewController.map { String(describing: type(of: $0)) } ?? "nil"
            let ours = (w === view.window) ? " <-- this screen" : ""
            HuskLog.log("ui", "  #\(i) \(Self.rect(w.frame)) level \(w.windowLevel) "
                      + "hidden \(w.isHidden) key \(w.isKeyWindow) root \(root)\(ours)")
        }
        HuskLog.log("ui", "  our view \(Self.rect(view.frame)), window \(view.window != nil ? "yes" : "NO")")
    }

    /// A CGRect as "x,y wxh", in a form every SDK accepts: NSStringFromCGRect is
    /// an error now ("has been replaced by NSCoder.string(for:)") and the
    /// replacement is newer than this target's floor on some SDKs.
    private static func rect(_ r: CGRect) -> String {
        "(\(Int(r.origin.x)),\(Int(r.origin.y))) \(Int(r.width))x\(Int(r.height))"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        if !LegacyStore.shared.canRunOnThisiOS(app) {
            buildUnavailableScreen()
            return
        }
        // Which screen this is depends on the app, not on the iOS: a game the
        // native runtime can drive gets the runtime, everything else the pixel
        // path it always had.
        if app.report?.nativeEngine != nil, let apk = app.apks.first {
            buildNativeScreen(apk: apk)
        } else {
            buildPixelScreen()
        }
    }

    // MARK: the native runtime

    /// A game the runtime drives: Unity, cocos2d-x, Minecraft, SDL, Unreal,
    /// Godot, GTA, GameMaker, the Java runtime, Flutter. The runtime presents
    /// into this view's CAMetalLayer on its own thread; GL comes from the ANGLE
    /// dylib the app carries, which is built for 12.2 like everything else here.
    /// One view per app, for the life of the process.
    ///
    /// The runtime is handed this view's CAMetalLayer and an engine cannot be started twice. A second visit that made
    /// a second view would put a fresh, empty layer on screen while every frame still went into the first one -- which
    /// is no longer in a window. The picture is perfect, the frame count is honest, and the screen is black. The iOS 15
    /// screen keeps its views for exactly this reason (TLUnityScreen.shared); this is the same rule for the 12.2 shell.
    private static var nativeViews: [String: TLUnityUIView] = [:]

    private func buildNativeScreen(apk: String) {
        // An engine cannot be unloaded once it has started, so a run that already
        // loaded a different APK cannot start this one. This used to fall through
        // to "unity: already started; resuming" and leave the dead app's black
        // layer on screen -- which reads exactly like the black-screen bug and
        // is not it. Say what is wrong instead, as the windowed screen does.
        if husk_unity_state() != Int32(HUSK_UNITY_IDLE),
           let loaded = husk_native_loaded_apk().map({ String(cString: $0) }),
           loaded != apk {
            let name = (loaded as NSString).lastPathComponent
            HuskLog.log("tl", "ios12 shell: refusing \(app.label) -- \(name) is already loaded "
                      + "this session; force-quit Husk to run this one")
            buildLoadedElsewhereScreen(name)
            return
        }
        let gv: TLUnityUIView
        if let kept = Self.nativeViews[apk] {
            gv = kept
            gv.removeFromSuperview()          /* still the engine's layer: it belongs to whichever screen shows it now */
            HuskLog.log("tl", "ios12 shell: \(app.label) already owns a GL layer — reusing that view")
        } else {
            gv = TLUnityUIView(apk: apk,
                               extraApks: Array(app.apks.dropFirst()),
                               dataDir: app.nativeDataDir,
                               engine: app.screenEngine,
                               portrait: app.drawsPortraitByManifest())
            Self.nativeViews[apk] = gv
        }
        gv.onThreeFingerTap = { [weak self] in self?.toggleChrome() }
        // Held by the same host the windowed screen uses, for the same reason. An engine is told its size once, when it starts;
        // a view pinned to this controller's edges resizes with the window, which changes the layer's drawable under a running
        // engine. Core Animation keeps nothing it is handed after the size moves, and an app that draws once never draws again --
        // the frame count stays honest and the screen is black. The host keeps the view at the size it started and scales the
        // picture into whatever the window then is.
        let host = TLWindowHost(game: gv)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        nativeView = gv

        // No Stop: an engine cannot be unloaded once it has started (upstream
        // says the same). Back pauses the view and leaves it loaded.
        addChrome(includeStop: false)
        startNativePolling()
        HuskLog.log("tl", "ios12 shell: native runtime for \(app.label) (\(app.screenEngine))")
    }

    private func startNativePolling() {
        nativeTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.refreshStatus() }
        t.resume()
        nativeTimer = t
    }

    private func nativeStatusText() -> String {
        let state = husk_unity_state()
        let frames = husk_unity_frames()
        let phase: String
        if state == Int32(HUSK_UNITY_RUNNING) {
            phase = "Running"
        } else if state == Int32(HUSK_UNITY_ENDED) {
            phase = "Finished"
        } else if state == Int32(HUSK_UNITY_FAILED) {
            phase = "Failed"
        } else {
            phase = "Starting"
        }
        return "\(app.label) · \(phase) · \(frames) frames"
    }

    // MARK: the pixel path

    private func buildPixelScreen() {
        let gv = TLScreenUIView()
        gv.showsStats = true
        gv.onThreeFingerTap = { [weak self] in self?.toggleChrome() }
        gv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gv)
        NSLayoutConstraint.activate([
            gv.topAnchor.constraint(equalTo: view.topAnchor),
            gv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            gv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        gameView = gv

        addChrome(includeStop: true)

        LegacyAttemptRunner.shared.onChange = { [weak self] in self?.refreshStatus() }
        refreshStatus()
        LegacyAttemptRunner.shared.start(apks: app.apks)
    }

    /// The status line, the buttons and the log panel, over whichever view drew
    /// the game.
    private func addChrome(includeStop: Bool) {
        statusLabel.font = huskMonospacedFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.textAlignment = .center
        statusLabel.layer.cornerRadius = 8
        statusLabel.layer.masksToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        let back = LegacyUI.button("Back", filled: false)
        back.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        let log = LegacyUI.button("Log", filled: false)
        log.addTarget(self, action: #selector(logTapped), for: .touchUpInside)
        let export = LegacyUI.button("Export", filled: false)
        export.addTarget(self, action: #selector(exportLogTapped), for: .touchUpInside)

        var buttons = [export, log, back]
        if includeStop {
            let stop = LegacyUI.button("Stop", filled: false)
            stop.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
            buttons.insert(stop, at: 0)
        }

        let pill = UIStackView(arrangedSubviews: buttons)
        pill.spacing = 8
        pill.distribution = .fillEqually
        pill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pill)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),

            pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            pill.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            pill.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])

        logTextView.backgroundColor = UIColor.black.withAlphaComponent(0.92)
        logTextView.textColor = UIColor(red: 0.8, green: 0.9, blue: 0.8, alpha: 1)
        logTextView.font = huskMonospacedFont(ofSize: 10, weight: .regular)
        logTextView.isEditable = false
        logTextView.isHidden = true
        logTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logTextView)
        NSLayoutConstraint.activate([
            logTextView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            logTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            logTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            logTextView.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -8),
        ])
    }

    private func buildUnavailableScreen() {
        let reason = LegacyStore.shared.unavailableReason(app) ?? "Not runnable on this iOS."
        let text = LegacyUI.body(
            "\(reason)\n\n"
            + "Games and ordinary Android apps do run here, on the native runtime or the older "
            + "loader path — the Library marks which one each app gets.", 15)
        text.textColor = .white
        text.translatesAutoresizingMaskIntoConstraints = false

        let close = LegacyUI.button("Back to Library")
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [text, close])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
        ])
    }

    /// A run can load one engine, so a second app in the same run gets this
    /// screen instead of a black one.
    private func buildLoadedElsewhereScreen(_ loaded: String) {
        let title = UILabel()
        title.text = "Another app is already loaded"
        title.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .white
        title.textAlignment = .center
        title.numberOfLines = 0

        let body = UILabel()
        body.text = "\(loaded) was started in this session, and an engine cannot be unloaded. "
                  + "Force-quit Husk (swipe it away in the app switcher), open it again, "
                  + "and then open \(app.label)."
        body.font = UIFont.systemFont(ofSize: 15)
        body.textColor = UIColor.white.withAlphaComponent(0.8)
        body.textAlignment = .center
        body.numberOfLines = 0

        let back = LegacyUI.button("Back to Library")
        back.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, body, back])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
        ])
    }

    // MARK: chrome

    private func refreshStatus() {
        if nativeView != nil {
            statusLabel.text = nativeStatusText()
            return
        }
        let runner = LegacyAttemptRunner.shared
        var text = "\(app.label) · \(runner.statusText)"
        if runner.isRunning { text += " · \(runner.frameCount) frames" }
        statusLabel.text = text
    }

    /// The runtime's own log, whichever path is on screen: the native runtime
    /// and the pixel loader write the same one.
    private var currentLog: String {
        guard let c = husk_tl_attempt_log() else { return "" }
        defer { free(c) }
        return String(cString: c)
    }

    @objc private func toggleChrome() {
        chromeHidden.toggle()
        view.subviews.compactMap { $0 as? UIStackView }.forEach { $0.isHidden = chromeHidden }
        statusLabel.isHidden = chromeHidden
    }

    @objc private func stopTapped() {
        LegacyAttemptRunner.shared.stop()
        refreshStatus()
    }

    @objc private func logTapped() {
        logVisible.toggle()
        logTextView.isHidden = !logVisible
        if logVisible {
            logTimer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: 0.5)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.logTextView.text = self.currentLog
            }
            t.resume()
            logTimer = t
        } else {
            logTimer?.cancel()
            logTimer = nil
        }
    }

    /// Write the whole run to one file and hand it to the share sheet.
    ///
    /// The log panel is readable on the device but a screenshot of it cannot be
    /// searched, diffed or pasted into a terminal -- and the lines that matter
    /// (screen bounds, window order, gpu readback) are exactly the ones a
    /// screenshot loses. The file goes into Documents (also visible over the
    /// Files app and iTunes, since UIFileSharingEnabled is on) and the share
    /// sheet offers AirDrop and Save to Files.
    @objc private func exportLogTapped() {
        HuskLog.flushNow()
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dest = dir.appendingPathComponent("husk-export-\(f.string(from: Date())).log")

        let info = Bundle.main.infoDictionary ?? [:]
        let screen = UIScreen.main
        var text = """
        Husk export — \(app.label)
        when    : \(Date())
        build   : \(info["CFBundleVersion"] ?? "?") \
        \(info["HuskBuildCommit"] ?? "?") built \(info["HuskBuildDate"] ?? "?")
        screen  : bounds \(screen.bounds.size) nativeBounds \(screen.nativeBounds.size) \
        scale \(screen.scale)/\(screen.nativeScale)
        state   : husk_unity_state=\(husk_unity_state()) frames=\(husk_unity_frames())

        """
        for name in ["husk.log", "husk-native.log"] {
            if let s = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) {
                text += "\n===== \(name) (\(s.count) chars) =====\n" + s + "\n"
            }
        }
        let attempt = currentLog
        if !attempt.isEmpty { text += "\n===== attempt log =====\n" + attempt + "\n" }

        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            HuskLog.log("ui", "export failed: \(error.localizedDescription)")
            let alert = UIAlertController(title: "Export failed", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        HuskLog.log("ui", "exported \(dest.lastPathComponent) (\(text.count) chars)")
        UIPasteboard.general.string = String(text.suffix(20_000))

        let sheet = UIActivityViewController(activityItems: [dest], applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    @objc private func closeTapped() {
        if nativeView != nil {
            // An engine cannot be unloaded once it has started: leaving the
            // screen pauses it, which didMoveToWindow also does when the view
            // comes off the window. It stays loaded for the next visit.
            nativeTimer?.cancel()
            nativeTimer = nil
            husk_unity_set_paused(true)
            nativeView?.removeFromSuperview()
            nativeView = nil
        } else {
            LegacyAttemptRunner.shared.stop()
            LegacyAttemptRunner.shared.onChange = nil
        }
        dismiss(animated: true)
    }

    deinit {
        logTimer?.cancel()
        nativeTimer?.cancel()
    }
}
