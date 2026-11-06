// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's Emulation screen.
//
// The guest's shell runs on the serial port, not on the framebuffer: a Linux VT
// only takes keys from legacy keyboard drivers, so QEMU's keyboard device can
// never type into it (see LegacySerialLink for the whole story). That makes the
// serial stream the real console, so it is the primary view here -- a large
// monospace terminal with an input line, and the virtio-gpu framebuffer
// available behind a Console/Screen switch for anything that paints.
//
// Pure UIKit: no SwiftUI, which does not exist on iOS 12.
import UIKit

final class LegacyEmulationViewController: UIViewController {

    private let statusLabel = UILabel()
    /// One line about the guest's three moving parts. Two of them live outside
    /// the IPA, so "missing" has to be visible before Start is pressed.
    private let guestLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let snapshotButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .white)
    private let modeControl = UISegmentedControl(items: ["Console", "Screen"])
    private let terminalView = UITextView()
    private let screenView = UIImageView()
    /// The GPU surface. virgl renders into its CAMetalLayer, so this is the view
    /// that shows an accelerated guest; screenView stays as the software path.
    private let glView = LegacyGLView.shared
    private let inputField = UITextField()
    private let enterButton = UIButton(type: .system)
    private let ctrlCButton = UIButton(type: .system)
    private let tabButton = UIButton(type: .system)

    /// The Android view. Entering the tab with a guest that is already drawing
    /// (or the moment a cold boot produces its first frame) hides every control
    /// and gives the whole screen to the picture. The console stays one tap away.
    private var mainStack: UIStackView?
    private let fullScreenRoot = UIView()
    private let fullScreenImage = UIImageView()
    private let fullScreenBar = UIStackView()
    private let consoleButton = UIButton(type: .system)
    private let fillButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    /// Husk opens a machine by tapping its picture. The same gesture is wired
    /// to the thumbnail below; this button keeps it discoverable before the
    /// first frame exists.
    private let enterFullScreenButton = UIButton(type: .system)
    private var fullScreen = false
    /// Fit keeps the guest's aspect ratio; Fill stretches it to the iPad's.
    private var fillMode = false
    private var pointerDown = false
    private var lastSentPoint = CGPoint(x: -1, y: -1)

    private var tickTimer: Timer?
    private var screenTimer: Timer?
    private var lastSeq: UInt64 = 0
    private var lastRendered = ""
    /// Set once the screen has been shown on its own. An autostarted guest begins
    /// on the console tab -- nobody tapped Start, so nobody picked a tab -- and a
    /// guest that is drawing a picture is what the user came to see. It fires at
    /// most once, so switching back to Console by hand is respected.
    private var autoShowedScreen = false

    override var prefersStatusBarHidden: Bool { fullScreen }
    override var prefersHomeIndicatorAutoHidden: Bool { fullScreen }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Emulation"
        view.backgroundColor = LegacyUI.background
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startTimers()
        refreshStatus()
        refreshGuestCard()
        refreshTerminal()
        // Returning to the tab with a guest that is already drawing: go straight
        // to the picture. A first boot stays on the console until there is a
        // frame to show, so the kernel log is visible instead of a black screen.
        if LegacyEmulationController.shared.isRunning,
           LegacyEmulationController.shared.latestSequence() > 0 {
            modeControl.selectedSegmentIndex = 1
            applyMode()
            autoShowedScreen = true
            DispatchQueue.main.async { [weak self] in self?.presentGuestFullScreen() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopTimers()
    }

    // MARK: - UI

    private func setupUI() {
        statusLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = LegacyUI.text
        statusLabel.text = "Idle"
        statusLabel.textAlignment = .center

        guestLabel.font = huskMonospacedFont(ofSize: 11, weight: .regular)
        guestLabel.textColor = LegacyUI.textDim
        guestLabel.textAlignment = .center
        guestLabel.numberOfLines = 0

        startButton.setTitle("Start guest (QEMU)", for: .normal)
        startButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)

        stopButton.setTitle("Stop", for: .normal)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        stopButton.isEnabled = false

        spinner.hidesWhenStopped = true

        resetButton.setTitle("Reset disk", for: .normal)
        resetButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        resetButton.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)

        // Android needs about fifteen minutes of emulated CPU to boot. Saving it
        // once means never paying that again -- the next Start restores instead.
        snapshotButton.setTitle("Save snapshot", for: .normal)
        snapshotButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        snapshotButton.addTarget(self, action: #selector(snapshotTapped), for: .touchUpInside)
        snapshotButton.isEnabled = false

        enterFullScreenButton.setTitle("⛶ Full screen", for: .normal)
        enterFullScreenButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        enterFullScreenButton.addTarget(self, action: #selector(presentGuestFullScreen),
                                        for: .touchUpInside)
        enterFullScreenButton.isEnabled = false

        let buttonRow = UIStackView(arrangedSubviews: [startButton, stopButton,
                                                       resetButton, snapshotButton,
                                                       enterFullScreenButton, spinner])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 16
        buttonRow.alignment = .center
        buttonRow.distribution = .fill

        modeControl.selectedSegmentIndex = 0
        modeControl.tintColor = LegacyUI.accent
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        // The terminal. Not editable: typing goes through the input line below, so
        // the caret and the keyboard never fight with the guest's cursor.
        terminalView.backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
        terminalView.textColor = LegacyUI.text
        terminalView.font = huskMonospacedFont(ofSize: 11, weight: .regular)
        terminalView.isEditable = false
        terminalView.isSelectable = true
        terminalView.layer.cornerRadius = 8
        terminalView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        terminalView.text = "The guest console appears here once QEMU is running."
        terminalView.setContentHuggingPriority(.defaultLow, for: .vertical)
        terminalView.isUserInteractionEnabled = true
        terminalView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(focusInput)))

        screenView.contentMode = .scaleAspectFit
        screenView.backgroundColor = .black
        screenView.layer.borderColor = LegacyUI.surfaceHigh.cgColor
        screenView.layer.borderWidth = 1
        screenView.layer.cornerRadius = 8
        screenView.setContentHuggingPriority(.defaultLow, for: .vertical)
        screenView.isHidden = true
        screenView.isUserInteractionEnabled = true
        screenView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(screenTapped(_:))))

        glView.backgroundColor = .black
        glView.layer.cornerRadius = 8
        glView.clipsToBounds = true
        glView.setContentHuggingPriority(.defaultLow, for: .vertical)
        glView.isHidden = true
        // The presenter needs the same layer the EGL surface is built on; it is
        // one object for the life of the process.
        LegacyMetalPresenter.shared.attach(layer: glView.metalLayer)

        // Input line. Every edit is refused and forwarded to the guest instead, so
        // the field stays empty and acts as a keystroke surface.
        inputField.backgroundColor = LegacyUI.surface
        inputField.textColor = LegacyUI.text
        inputField.tintColor = LegacyUI.accent
        inputField.font = huskMonospacedFont(ofSize: 13, weight: .regular)
        inputField.placeholder = "Type into the guest console"
        inputField.autocorrectionType = .no
        inputField.autocapitalizationType = .none
        inputField.spellCheckingType = .no
        inputField.keyboardType = .asciiCapable
        inputField.returnKeyType = .send
        inputField.delegate = self
        inputField.layer.cornerRadius = 8
        inputField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        inputField.leftViewMode = .always
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        styleKey(enterButton, "⏎", #selector(enterTapped))
        styleKey(ctrlCButton, "⌃C", #selector(ctrlCTapped))
        styleKey(tabButton, "⇥", #selector(tabTapped))

        let inputRow = UIStackView(arrangedSubviews: [inputField, enterButton,
                                                      ctrlCButton, tabButton])
        inputRow.axis = .horizontal
        inputRow.spacing = 8
        inputRow.alignment = .fill
        inputRow.distribution = .fill

        let vstack = UIStackView(arrangedSubviews: [statusLabel, guestLabel, buttonRow, modeControl,
                                                    terminalView, glView, screenView, inputRow])
        vstack.axis = .vertical
        vstack.spacing = 10
        vstack.alignment = .fill
        vstack.distribution = .fill
        vstack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vstack)

        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            vstack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            vstack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            vstack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            inputRow.heightAnchor.constraint(equalToConstant: 40),
        ])
        mainStack = vstack
        setupFullScreen()
        applyFullScreen()
    }

    // MARK: - the full-screen Android view

    /// One picture and a translucent corner bar. Everything that makes this tab
    /// look like a control panel hides behind it, so the guest fills the device
    /// and a finger can reach any part of Android without dodging a button.
    private func setupFullScreen() {
        fullScreenRoot.backgroundColor = .black
        fullScreenRoot.translatesAutoresizingMaskIntoConstraints = false
        fullScreenRoot.isHidden = true
        view.addSubview(fullScreenRoot)

        fullScreenImage.contentMode = .scaleAspectFit
        fullScreenImage.backgroundColor = .black
        // Touches must fall through to the controller; a UIImageView that eats
        // them would leave the guest with no input at all.
        fullScreenImage.isUserInteractionEnabled = false
        fullScreenImage.translatesAutoresizingMaskIntoConstraints = false
        fullScreenRoot.addSubview(fullScreenImage)

        NSLayoutConstraint.activate([
            fullScreenRoot.topAnchor.constraint(equalTo: view.topAnchor),
            fullScreenRoot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            fullScreenRoot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fullScreenRoot.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fullScreenImage.topAnchor.constraint(equalTo: fullScreenRoot.topAnchor),
            fullScreenImage.bottomAnchor.constraint(equalTo: fullScreenRoot.bottomAnchor),
            fullScreenImage.leadingAnchor.constraint(equalTo: fullScreenRoot.leadingAnchor),
            fullScreenImage.trailingAnchor.constraint(equalTo: fullScreenRoot.trailingAnchor),
        ])

        styleFullKey(consoleButton, "Controls", #selector(exitFullScreen))
        styleFullKey(fillButton, "Fill", #selector(toggleFill))
        styleFullKey(backButton, "◀ Back", #selector(androidBack))
        styleFullKey(saveButton, "Save", #selector(fullScreenSnapshot))
        fullScreenBar.axis = .horizontal
        fullScreenBar.spacing = 6
        fullScreenBar.alignment = .center
        fullScreenBar.distribution = .fill
        fullScreenBar.backgroundColor = UIColor(white: 0, alpha: 0.45)
        fullScreenBar.layer.cornerRadius = 8
        fullScreenBar.alpha = 0.55
        fullScreenBar.translatesAutoresizingMaskIntoConstraints = false
        [consoleButton, fillButton, backButton, saveButton].forEach {
            fullScreenBar.addArrangedSubview($0)
        }
        fullScreenRoot.addSubview(fullScreenBar)
        NSLayoutConstraint.activate([
            fullScreenBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                               constant: 6),
            fullScreenBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                                                    constant: -6),
            fullScreenBar.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func styleFullKey(_ b: UIButton, _ title: String, _ action: Selector) {
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        b.setTitleColor(.white, for: .normal)
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        b.addTarget(self, action: action, for: .touchUpInside)
    }

    private func applyFullScreen() {
        mainStack?.isHidden = fullScreen
        fullScreenRoot.isHidden = !fullScreen
        // The Metal layer is docked by LegacyGLView on its own; the only surface
        // that paints here is the CPU image.
        glView.isHidden = true
        fullScreenImage.contentMode = fillMode ? .scaleToFill : .scaleAspectFit
        fillButton.setTitle(fillMode ? "Fit" : "Fill", for: .normal)
        if let img = screenView.image { fullScreenImage.image = img }
        setNeedsStatusBarAppearanceUpdate()
        if #available(iOS 11.0, *) { setNeedsUpdateOfHomeIndicatorAutoHidden() }
    }

    @objc private func exitFullScreen() {
        modeControl.selectedSegmentIndex = 0
        applyMode()
        refreshTerminal()
    }

    @objc private func toggleFill() {
        fillMode = !fillMode
        applyFullScreen()
    }

    @objc private func androidBack() {
        LegacyEmulationController.shared.sendBackKey()
    }

    /// Save the booted machine without leaving the full-screen view. This is
    /// the button that turns a fifteen-minute cold boot into a one-off: once it
    /// has been pressed at the launcher, every later Start restores.
    @objc private func fullScreenSnapshot() {
        LegacyUI.Banner("Saving — the guest pauses until it finishes",
                        color: LegacyUI.accent).show(in: view)
        LegacyEmulationController.shared.saveSnapshot()
    }

    /// Undo whichever content mode is active. Fit has letterbox bars; Fill
    /// stretches the picture over the whole view. Both are invertible, which is
    /// what keeps a tap in the right place on Android.
    private func guestPoint(_ p: CGPoint) -> (x: CGFloat, y: CGFloat)? {
        guard let img = fullScreenImage.image else { return nil }
        let b = fullScreenImage.bounds
        let iw = img.size.width, ih = img.size.height
        guard b.width > 0, b.height > 0, iw > 0, ih > 0 else { return nil }
        let gx: CGFloat, gy: CGFloat
        if fillMode {
            gx = p.x / b.width * iw
            gy = p.y / b.height * ih
        } else {
            let s = min(b.width / iw, b.height / ih)
            let ox = (b.width - iw * s) / 2
            let oy = (b.height - ih * s) / 2
            gx = (p.x - ox) / s
            gy = (p.y - oy) / s
        }
        guard gx >= 0, gy >= 0, gx < iw, gy < ih else { return nil }
        return (gx, gy)
    }

    private func forwardTouch(_ t: UITouch, down: Bool, force: Bool) {
        let p = t.location(in: fullScreenImage)
        let gx: CGFloat, gy: CGFloat
        if let g = guestPoint(p) {
            gx = g.x; gy = g.y
        } else if !down, lastSentPoint.x >= 0 {
            // The finger left the picture before lifting. The release still has
            // to reach the guest, or Android keeps thinking it is held down.
            gx = lastSentPoint.x; gy = lastSentPoint.y
        } else {
            return
        }
        if !force {
            let dx = gx - lastSentPoint.x, dy = gy - lastSentPoint.y
            if dx * dx + dy * dy < 9 { return }   // ~3 guest pixels
        }
        lastSentPoint = CGPoint(x: gx, y: gy)
        LegacyEmulationController.shared.sendPointer(guestX: Int(gx), guestY: Int(gy),
                                                     down: down)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard fullScreen, let t = touches.first else {
            super.touchesBegan(touches, with: event); return
        }
        // The corner bar (and the gap around its buttons) is ours, not the
        // guest's. Rejecting the touch here rather than inside forwardTouch
        // keeps Ended free to send the matching button-up in every case.
        if fullScreenBar.frame.contains(t.location(in: fullScreenImage)) {
            super.touchesBegan(touches, with: event); return
        }
        pointerDown = true
        forwardTouch(t, down: true, force: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard fullScreen, pointerDown, let t = touches.first else {
            super.touchesMoved(touches, with: event); return
        }
        forwardTouch(t, down: true, force: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard fullScreen, pointerDown, let t = touches.first else {
            super.touchesEnded(touches, with: event); return
        }
        pointerDown = false
        forwardTouch(t, down: false, force: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard fullScreen, pointerDown, let t = touches.first else {
            super.touchesCancelled(touches, with: event); return
        }
        pointerDown = false
        forwardTouch(t, down: false, force: true)
    }

    private func styleKey(_ b: UIButton, _ title: String, _ action: Selector) {
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = huskMonospacedFont(ofSize: 15, weight: .regular)
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.backgroundColor = LegacyUI.surface
        b.layer.cornerRadius = 8
        b.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: - actions

    @objc private func startTapped() {
        startButton.isEnabled = false
        spinner.startAnimating()
        // A GL guest needs its surface on screen before the EGL context is built
        // against it: a hidden view has no window and no bounds, and creating a
        // window surface on that is asking for a failure. This also means the
        // picture appears where the user is already looking.
        if LegacyEmulationController.shared.bootWantsGL {
            modeControl.selectedSegmentIndex = 1
            applyMode()
            view.layoutIfNeeded()
        }
        LegacyEmulationController.shared.start()
        stopButton.isEnabled = true
        snapshotButton.isEnabled = true
        refreshStatus()
    }

    @objc private func stopTapped() {
        LegacyEmulationController.shared.stop()
        stopButton.isEnabled = false
        snapshotButton.isEnabled = false
    }

    /// Save the booted guest so the next Start restores instead of booting.
    ///
    /// Worth saying out loud in the UI: the guest freezes while this runs, and a
    /// snapshot taken mid-boot restores into a machine that is still mid-boot --
    /// so it is only useful once the guest has reached something worth returning
    /// to.
    @objc private func snapshotTapped() {
        snapshotButton.isEnabled = false
        LegacyUI.Banner("Saving — the guest pauses until it finishes",
                        color: LegacyUI.accent).show(in: view)
        LegacyEmulationController.shared.saveSnapshot()
        // The callback lands on the QEMU thread and the panel is not the place to
        // wait for it; give the save a moment and let the user try again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, LegacyEmulationController.shared.isRunning else { return }
            self.snapshotButton.isEnabled = true
        }
    }

    /// Recovery path: a broken persistent root cannot be repaired from inside
    /// the guest that is running off it, so throw the disk away instead.
    @objc private func resetTapped() {
        guard !LegacyEmulationController.shared.isRunning else {
            LegacyUI.Banner("Stop the guest first", color: LegacyUI.warn).show(in: view)
            return
        }
        let a = UIAlertController(
            title: "Reset guest disk?",
            message: "Deletes husk-root.img. The next start boots from the seed into a "
                   + "throwaway tmpfs, and anything installed since is lost.",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            LegacyEmulationController.shared.resetRootDisk()
            self?.refreshGuestCard()
        })
        present(a, animated: true)
    }

    @objc private func modeChanged() {
        applyMode()
        if modeControl.selectedSegmentIndex == 0 { refreshTerminal() }
    }

    /// Console, or Screen -- and inside Screen either the GPU surface or the CPU
    /// framebuffer. Which one is only known after Start, so this is re-applied
    /// whenever the guest's display state changes.
    private func applyMode() {
        let console = modeControl.selectedSegmentIndex == 0
        // The in-tab picture is a tappable thumbnail now. A child view can never
        // cover UINavigationBar / UITabBar -- those belong to the parent
        // controllers and are drawn above everything this controller adds to
        // its own view -- so the real full-screen guest lives in a separate
        // .overFullScreen controller, presented by presentGuestFullScreen().
        fullScreen = false
        applyFullScreen()
        enterFullScreenButton.isEnabled = screenView.image != nil
        terminalView.isHidden = !console || fullScreen
        /*
         * One screen surface for both modes.
         *
         * The GL path used to own a CAMetalLayer and be presented by Core
         * Animation. It no longer is: swapping an EGL window surface from the
         * QEMU thread blocked on a drawable that was not being driven, the main
         * loop stopped polling, and the guest's virtio-gpu control queue filled
         * until its kernel wedged -- Android never got past init. The frame is
         * read back to the CPU now, so it arrives here like any other picture
         * and the layer only has to exist.
         */
        glView.isHidden = true
        screenView.isHidden = console || fullScreen

        if console {
            // Nothing to poll in console mode: the framebuffer is not on screen.
            screenTimer?.invalidate()
            screenTimer = nil
        } else {
            startScreenTimer()
        }
        if !console { pumpFrame() }
    }

    /// GL comes up a second or two after Start, so the two screen surfaces have
    /// to swap themselves without the user touching the tab again.
    private func syncScreenVisibility() {
        // While the immersive controller is up it owns the frame pump, so the
        // thumbnail legitimately has no image. Re-applying the mode ten times a
        // second here would just churn the status-bar appearance for nothing.
        guard presentedViewController == nil else { return }
        guard modeControl.selectedSegmentIndex == 1 else { return }
        // With one screen surface the only thing that can be out of date is
        // whether a frame has arrived. Checking isHidden here would be true for
        // every tick in full-screen mode and re-apply the mode ten times a
        // second for nothing -- and each apply toggles the status bar.
        if screenView.image == nil { applyMode() }
    }

    @objc private func focusInput() {
        inputField.becomeFirstResponder()
    }

    @objc private func enterTapped() {
        LegacyEmulationController.shared.typeText("\r")
    }

    @objc private func ctrlCTapped() {
        LegacyEmulationController.shared.typeText("\u{03}")
    }

    @objc private func tabTapped() {
        LegacyEmulationController.shared.typeText("\t")
    }

    /// Husk's gesture: tap the picture to open the machine. Guest clicks are
    /// handled inside the full-screen controller, where the whole screen is the
    /// picture and the touch coordinates are unambiguous.
    @objc private func screenTapped(_ g: UITapGestureRecognizer) {
        presentGuestFullScreen()
    }

    /// Present the immersive guest view. Guarding on presentedViewController
    /// keeps the 10 Hz status ticker from opening a second copy every tick.
    @objc private func presentGuestFullScreen() {
        guard presentedViewController == nil else { return }
        guard LegacyEmulationController.shared.latestSequence() > 0 else { return }
        let host = LegacyGuestFullScreenViewController()
        host.seedImage = screenView.image
        present(host, animated: true)
    }

    // MARK: - timers

    private func startTimers() {
        guard tickTimer == nil else { return }
        // 10 Hz is enough for a console and far cheaper than re-reading a growing
        // log file on every frame.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshTerminal()
            self?.refreshStatus()
            self?.refreshGuestCard()
            self?.syncScreenVisibility()
            self?.autoShowScreenOnce()
            self?.checkSnapshotTrigger()
            self?.checkGuestCommand()
            self?.checkFrameExport()
        }
        applyMode()
    }

    /// A file, not a tap. There is no way to press an on-screen button over
    /// SSH, and a snapshot is only worth taking at the exact moment the guest
    /// becomes usable -- which a boot-watching script can see in the serial log
    /// before a human can. `touch Documents/husk-save-now` asks for one.
    private func checkSnapshotTrigger() {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                        .userDomainMask, true)[0]
        let marker = (docs as NSString).appendingPathComponent("husk-save-now")
        guard FileManager.default.fileExists(atPath: marker) else { return }
        try? FileManager.default.removeItem(atPath: marker)
        HuskLog.log("snap", "husk-save-now marker seen -- saving from the console")
        LegacyEmulationController.shared.saveSnapshot()
    }

    /// Type one line into the guest console from a file. SSH can write into
    /// Documents but cannot press an on-screen key, so this is the only remote
    /// way to ask a booted guest things like `logcat -d | tail`, `getprop`, or
    /// `wm size 400x300`. The reply lands in husk-phase0-serial.log with all the
    /// other console bytes. If the guest has no console shell, this is a no-op.
    private func checkGuestCommand() {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                        .userDomainMask, true)[0]
        let marker = (docs as NSString).appendingPathComponent("husk-guest-cmd")
        guard FileManager.default.fileExists(atPath: marker) else { return }
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: marker)) else { return }
        try? FileManager.default.removeItem(atPath: marker)
        let text = String(decoding: raw, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        HuskLog.log("cmd", "husk-guest-cmd: \(text)")
        LegacyEmulationController.shared.typeText(text + "\r")
    }

    /// Export the current guest frame as a real PNG so the picture can be
    /// inspected off-device. SSH cannot press a button and cannot read the
    /// framebuffer, but it can touch a file; the 10 Hz ticker sees it, copies
    /// the CPU framebuffer once, and writes Documents/husk-frame.png.
    private func checkFrameExport() {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                        .userDomainMask, true)[0]
        let marker = (docs as NSString).appendingPathComponent("husk-export-frame")
        guard FileManager.default.fileExists(atPath: marker) else { return }
        try? FileManager.default.removeItem(atPath: marker)
        guard let f = LegacyEmulationController.shared.grabFrame() else {
            HuskLog.log("shot", "husk-export-frame: no frame available yet")
            return
        }
        guard let img = makeImage(data: f.data, width: f.width,
                                  height: f.height, stride: f.stride),
              let png = UIImagePNGRepresentation(img) else {
            HuskLog.log("shot", "husk-export-frame: PNG encode failed")
            return
        }
        let out = (docs as NSString).appendingPathComponent("husk-frame.png")
        do {
            try png.write(to: URL(fileURLWithPath: out))
            HuskLog.log("shot", "husk-frame.png \(f.width)x\(f.height) \(png.count) bytes")
        } catch {
            HuskLog.log("shot", "husk-export-frame write failed: \(error)")
        }
    }

    /// Bring the picture up the first time the guest produces one.
    ///
    /// The console is the right tab while a guest is still booting -- that is
    /// where the kernel tells you what it is doing. The moment there is a frame,
    /// the picture is the more useful of the two, and on an autostart launch
    /// there was no Start tap to make that choice. Closing the immersive view
    /// leaves the thumbnail on the Screen tab, so it can be re-opened with one
    /// tap (Husk's "tap to enter" gesture).
    private func autoShowScreenOnce() {
        guard !autoShowedScreen,
              modeControl.selectedSegmentIndex == 0,
              LegacyEmulationController.shared.isRunning else { return }
        guard LegacyEmulationController.shared.latestSequence() > 0 else { return }
        autoShowedScreen = true
        modeControl.selectedSegmentIndex = 1
        applyMode()
        presentGuestFullScreen()
    }

    private func startScreenTimer() {
        guard screenTimer == nil else { return }
        screenTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.pumpFrame()
        }
    }

    private func stopTimers() {
        tickTimer?.invalidate(); tickTimer = nil
        screenTimer?.invalidate(); screenTimer = nil
    }

    // MARK: - rendering

    private func refreshTerminal() {
        let raw = LegacyEmulationController.shared.terminalText()
        guard !raw.isEmpty else { return }
        let text = LegacyANSI.strip(raw)
        guard text != lastRendered else { return }
        lastRendered = text
        terminalView.text = text
        let end = NSRange(location: (text as NSString).length, length: 0)
        terminalView.scrollRangeToVisible(end)
    }

    private func pumpFrame() {
        // The immersive controller owns the 20 Hz frame pump while it is up;
        // reading the same buffer twice per tick would just burn CPU on the
        // copy. Closing the modal hands the pump straight back to this tab.
        guard presentedViewController == nil else { return }
        guard let frame = LegacyEmulationController.shared.grabFrame() else { return }
        lastSeq = LegacyEmulationController.shared.latestSequence()
        guard let img = makeImage(data: frame.data, width: frame.width,
                                  height: frame.height, stride: frame.stride) else { return }
        screenView.image = img
        enterFullScreenButton.isEnabled = true
        if fullScreen { fullScreenImage.image = img }
    }

    private func makeImage(data: Data, width: Int, height: Int, stride: Int) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // virtio-gpu gives 32bpp; Metal's BGRA8Unorm is the matching iOS layout.
        let bmi = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: width, height: height,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: stride,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: bmi,
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    private func refreshGuestCard() {
        let s = LegacyEmulationController.shared.guestStatus()
        if s.usingCustomArgs {
            // The built-in fields describe the Alpine profile; under a custom
            // command line they would be misleading, so name the profile instead.
            guestLabel.text = "custom boot profile (husk-boot.args)"
            guestLabel.textColor = LegacyUI.textDim
            return
        }
        let gib = String(format: "%.1f GiB", Double(s.diskBytes) / 1_073_741_824)
        let kernel = s.kernelPresent ? "kernel OK" : "kernel MISSING"
        let root = s.rootImagePresent ? "root image OK" : "root image MISSING (Phase 0)"
        let disk = s.diskFormatted ? "disk \(gib) ext4" : "disk \(gib) unformatted"
        guestLabel.text = "\(kernel)   ·   \(root)   ·   \(disk)"
        guestLabel.textColor = (s.kernelPresent && s.rootImagePresent)
            ? LegacyUI.textDim : LegacyUI.warn
    }

    private func refreshStatus() {
        let running = LegacyEmulationController.shared.isRunning
        let console = LegacyEmulationController.shared.isConsoleConnected
        if running {
            statusLabel.text = console ? "QEMU running — console attached"
                                       : "QEMU running — attaching console…"
            statusLabel.textColor = console ? LegacyUI.accent : LegacyUI.warn
            spinner.stopAnimating()
        } else {
            statusLabel.text = "Idle"
            statusLabel.textColor = LegacyUI.text
            spinner.stopAnimating()
        }
    }
}

// MARK: - keystrokes -> guest

extension LegacyEmulationViewController: UITextFieldDelegate {

    /// Every edit is refused and forwarded instead, so the field stays empty and
    /// the guest sees exactly the bytes that were typed (paste included).
    func textField(_ textField: UITextField,
                   shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        if string.isEmpty {
            // Backspace arrives as a deletion with no replacement text. A terminal
            // sends DEL (0x7f) for erase, not a cursor key.
            LegacyEmulationController.shared.typeText("\u{7f}")
            return false
        }
        LegacyEmulationController.shared.typeText(string)
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        LegacyEmulationController.shared.typeText("\r")
        return false
    }
}

// MARK: - the GPU surface (the iOS 12 port of Husk's GL display)

/// A CAMetalLayer-backed view. It is both what ANGLE creates its EGL window
/// surface against and what the Metal presenter draws into.
///
/// Same role as HuskGLView on iOS 15, without the SwiftUI plumbing: layerClass,
/// CAMetalLayer and Metal are all present on 12.2, which is what makes this path
/// possible here at all. The engine itself is already inside the QEMU dylib --
/// husk_display_gl_early/create/bind are exported, and ANGLE is built with a
/// 12.2 deployment target.
///
/// One instance for the process: QEMU builds its EGL window surface against
/// whichever layer is published when GL comes up and never rebuilds it, so a
/// second view would orphan the display -- a frame counter climbing happily
/// against a black screen.
final class LegacyGLView: UIView {
    static let shared = LegacyGLView(frame: .zero)

    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        // ANGLE presents through this layer, so it is rendered into rather than
        // merely displayed.
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = resizeDrawable()
    }

    /// The EGL surface is sized from the layer at create time, so it has to be
    /// real before then. A view hidden inside a stack has zero bounds, hence the
    /// screen-sized fallback: Android draws at panel resolution regardless, and
    /// the presenter letterboxes whatever arrives.
    @discardableResult
    func resizeDrawable() -> CGSize {
        var size = bounds.size
        if size.width < 1 || size.height < 1 { size = UIScreen.main.bounds.size }
        let scale = UIScreen.main.scale
        let px = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        if px.width >= 1, px.height >= 1, metalLayer.drawableSize != px {
            metalLayer.drawableSize = px
        }
        return metalLayer.drawableSize
    }

    /// Main thread. The layer plus the pixel size to build the surface at.
    ///
    /// An EGL window surface cannot be created against a layer that is not in a
    /// window, and QEMU may be started without the Emulation tab ever having been
    /// shown (a headless launch, or the autostart flag). So the view parks itself
    /// in the key window, at the back and screen-sized, when it has no window of
    /// its own. Being a UIView, moving it into the tab later keeps the same
    /// layer -- and the same EGL surface.
    static func prepareSurface() -> (UnsafeMutableRawPointer, CGSize)? {
        let v = shared
        if v.window == nil {
            let windows = UIApplication.shared.windows
            let key = windows.first(where: { $0.isKeyWindow }) ?? windows.first
            if let win = key {
                v.frame = win.bounds
                v.isHidden = false
                win.insertSubview(v, at: 0)
                HuskLog.log("emu", "GL surface parked in the key window "
                                 + "(the tab is not on screen)")
            }
        }
        // Visible even when the tab is showing the console: a hidden layer is not
        // composited, and the surface has to survive until the user looks at it.
        // The layer is no longer presented from -- the frame goes back to the CPU
        // and is drawn by an image view -- but the EGL surface is still built
        // against it, so it has to exist with a real drawable size.
        let px = v.resizeDrawable()
        guard px.width >= 1, px.height >= 1 else { return nil }
        return (Unmanaged.passUnretained(v.metalLayer).toOpaque(), px)
    }
}

/// Draws each guest scanout from its own MTLTexture.
///
/// Not from the GL texture id virgl reports: that id belongs to virglrenderer's
/// context, so attaching it to a framebuffer of ours raises
/// GL_INVALID_FRAMEBUFFER_OPERATION on every blit and the picture stays black
/// while the guest is demonstrably drawing. The pixels are in the MTLTexture this
/// QEMU fork carries beside the id -- which is also what UTM's display reaches
/// for first.
final class LegacyMetalPresenter {
    static let shared = LegacyMetalPresenter()

    private var layer: CAMetalLayer?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private let lock = NSLock()
    private var presented: UInt64 = 0
    /// Drawing is what kills the process under TCG (a guest frame can be seconds
    /// of GPU work), so frames are capped and only one may be in flight: the
    /// point is to let the GPU drain instead of queueing another render pass on
    /// top of work that has not finished.
    private var lastDraw: CFTimeInterval = 0
    private var inFlight = false
    private var dropped = 0
    private var slowestFrame: Double = 0

    /// Frames per second cap. `<Documents>/husk-gl-fps` overrides it; default 20.
    private lazy var fpsCap: Double = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                       .userDomainMask, true)[0]
        let path = (docs as NSString).appendingPathComponent("husk-gl-fps")
        if let s = try? String(contentsOfFile: path, encoding: .utf8),
           let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), v > 0 {
            return min(v, 120)
        }
        return 20
    }()

    /// Whether the presenter actually draws.
    ///
    /// `<Documents>/husk-gl-draw` present = draw; absent = count scanouts only.
    /// The second case is the isolation run: with the GL context created and
    /// bound but no drawable touched, a surviving guest means the kill came from
    /// our render pass; a guest that still dies means it came from virgl
    /// executing the guest's own GL commands. Those need different fixes, and
    /// guessing between them costs a 40-minute build each time.
    private lazy var drawEnabled: Bool = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                       .userDomainMask, true)[0]
        let flag = (docs as NSString).appendingPathComponent("husk-gl-draw")
        return FileManager.default.fileExists(atPath: flag)
    }()

    func attach(layer: CAMetalLayer) {
        lock.lock()
        self.layer = layer
        lock.unlock()
    }

    /// Build against the texture's own device: a texture can only be sampled by
    /// the device that owns it, and ANGLE picked that device, not us.
    private func prepare(for texture: MTLTexture, _ layer: CAMetalLayer) -> Bool {
        if pipeline != nil, device === texture.device { return true }

        let dev = texture.device
        device = dev
        layer.device = dev
        queue = dev.makeCommandQueue()

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VOut { float4 pos [[position]]; float2 uv; };
        struct Params { float flip; float rotate; float2 scale; };

        vertex VOut husk_vertex(uint vid [[vertex_id]],
                                constant Params &p [[buffer(0)]]) {
            const float2 corners[4] = { float2(-1, -1), float2(1, -1),
                                        float2(-1,  1), float2(1,  1) };
            VOut o;
            o.pos = float4(corners[vid] * p.scale, 0, 1);
            float2 uv = corners[vid] * 0.5 + 0.5;
            // Metal samples from the top-left, clip space counts y upward; the
            // guest's own y_0_top then flips it back.
            uv = float2(uv.x, p.flip > 0.5 ? uv.y : 1.0 - uv.y);
            o.uv = p.rotate > 0.5 ? float2(1.0 - uv.y, uv.x) : uv;
            return o;
        }

        fragment float4 husk_fragment(VOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      sampler smp [[sampler(0)]]) {
            // Alpha forced opaque: Android's scanout is commonly B8G8R8X8, whose
            // fourth byte is ignored by definition and zero in practice, and
            // Core Animation would blend the frame away.
            return float4(tex.sample(smp, in.uv).rgb, 1.0);
        }
        """

        do {
            let library = try dev.makeLibrary(source: source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "husk_vertex")
            desc.fragmentFunction = library.makeFunction(name: "husk_fragment")
            desc.colorAttachments[0].pixelFormat = layer.pixelFormat
            pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            HuskLog.log("emu", "metal: could not build the present pipeline: \(error)")
            pipeline = nil
            return false
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = dev.makeSamplerState(descriptor: sd)

        HuskLog.log("emu", "metal: presenting on \(dev.name), guest "
                        + "\(texture.width)x\(texture.height) -> layer "
                        + "\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height))")
        return sampler != nil
    }

    /// Called from QEMU's thread, once per guest frame.
    func present(texture: MTLTexture, flip: Bool) {
        lock.lock()
        defer { lock.unlock() }

        presented &+= 1
        if presented == 1 {
            HuskLog.log("emu", "metal: first scanout \(texture.width)x\(texture.height) "
                            + "flip=\(flip) draw=\(drawEnabled)")
        }
        guard drawEnabled else {
            if presented % 300 == 0 {
                HuskLog.log("emu", "metal: \(presented) scanouts, draw disabled")
            }
            return
        }

        let now = CACurrentMediaTime()
        guard !inFlight, now - lastDraw >= 1.0 / fpsCap else { return }
        lastDraw = now

        guard let layer = layer, prepare(for: texture, layer),
              let queue = queue, let pipeline = pipeline, let sampler = sampler
        else { return }

        // nil when the pool is exhausted: a dropped frame, not an error.
        guard let drawable = layer.nextDrawable() else {
            dropped += 1
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        // Letterbox rather than stretch: whichever axis runs out first sets the
        // scale and the other is inset, so the guest keeps its aspect ratio.
        let gw = Float(texture.width), gh = Float(texture.height)
        let lw = Float(layer.drawableSize.width), lh = Float(layer.drawableSize.height)
        var sx: Float = 1, sy: Float = 1
        if gw > 0, gh > 0, lw > 0, lh > 0 {
            let guestAspect = gw / gh
            let layerAspect = lw / lh
            if guestAspect > layerAspect { sy = layerAspect / guestAspect }
            else                        { sx = guestAspect / layerAspect }
        }

        var params = (flip: Float(flip ? 1 : 0), rotate: Float(0), sx: sx, sy: sy)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&params, length: MemoryLayout<Float>.size * 4, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // No manual retain of the texture: a command buffer keeps every resource
        // it references alive until it completes, which is exactly the window in
        // which the GPU reads it.
        buffer.present(drawable)
        inFlight = true
        let frames = presented
        buffer.addCompletedHandler { [weak self] cb in
            guard let self = self else { return }
            let seconds = cb.gpuEndTime - cb.gpuStartTime
            self.lock.lock()
            self.inFlight = false
            if seconds > self.slowestFrame { self.slowestFrame = seconds }
            self.lock.unlock()
            if frames == 1 || frames % 120 == 0 {
                HuskLog.log("emu", String(format:
                    "metal: frame %llu GPU %.0f ms (slowest %.0f ms), %d dropped",
                    frames, seconds * 1000, self.slowestFrame * 1000, self.dropped))
            }
        }
        buffer.commit()

        if presented % 600 == 0 {
            HuskLog.log("emu", "metal: presented \(presented) frames "
                            + "(\(texture.width)x\(texture.height), flip=\(flip))")
        }
    }
}

/// The C entry point QEMU calls. A plain function pointer, so everything hangs
/// off the shared presenter rather than a capture.
private let legacyMetalPresent: husk_metal_present_fn = { texture, flip, _, _ in
    guard let texture = texture else { return }
    let obj = Unmanaged<AnyObject>.fromOpaque(texture).takeUnretainedValue()
    guard let tex = obj as? MTLTexture else { return }
    LegacyMetalPresenter.shared.present(texture: tex, flip: flip != 0)
}

func legacyInstallMetalPresenter() {
    husk_display_gl_set_metal_presenter(legacyMetalPresent)
}

// MARK: - the immersive Android view
//
// Husk opens a machine by tapping its picture, and the picture then owns the
// whole device: no navigation bar above it, no tab bar below it, and every
// touch lands on Android. A child view inside a tab cannot do that on iOS 12 --
// UINavigationBar and UITabBar are drawn by the parent controllers and stay on
// top of anything this controller adds to its own view. A separate
// .overFullScreen controller lives above both of them.
//
// Info.plist sets UIStatusBarHidden=YES and
// UIViewControllerBasedStatusBarAppearance=NO, so there is no status bar to
// reserve space for either. Constraints here are deliberately pinned to the
// raw view edges, not the safe area: using the safe area would put the
// letterboxing back that the user asked to remove.
//
// The controls are a single translucent dot by default. A permanent bar was
// the thing that made the previous "full screen" not look full screen.

final class LegacyGuestFullScreenViewController: UIViewController {

    private let guestImage = UIImageView()
    private let handle = UIButton(type: .system)
    private let bar = UIStackView()
    private let closeButton = UIButton(type: .system)
    private let fitButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let hideButton = UIButton(type: .system)

    private var barVisible = false
    private var fillMode = false
    private var pointerDown = false
    private var lastSentPoint = CGPoint(x: -1, y: -1)
    private var frameTimer: Timer?

    /// The thumbnail's last frame, so opening never starts from a black screen.
    var seedImage: UIImage?

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        // Without this, .overFullScreen lets the *presenting* controller keep
        // deciding status-bar / home-indicator appearance.
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true

        guestImage.contentMode = .scaleAspectFit
        guestImage.backgroundColor = .black
        guestImage.isUserInteractionEnabled = false
        guestImage.image = seedImage
        guestImage.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(guestImage)
        NSLayoutConstraint.activate([
            guestImage.topAnchor.constraint(equalTo: view.topAnchor),
            guestImage.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            guestImage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guestImage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        handle.setTitle("•••", for: .normal)
        handle.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        handle.setTitleColor(.white, for: .normal)
        handle.backgroundColor = UIColor(white: 0, alpha: 0.45)
        handle.layer.cornerRadius = 15
        handle.alpha = 0.35
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.addTarget(self, action: #selector(toggleBar), for: .touchUpInside)
        view.addSubview(handle)
        NSLayoutConstraint.activate([
            handle.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            handle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            handle.widthAnchor.constraint(equalToConstant: 40),
            handle.heightAnchor.constraint(equalToConstant: 30),
        ])

        styleKey(closeButton, "✕", #selector(closeTapped))
        styleKey(fitButton, "Fill", #selector(toggleFill))
        styleKey(backButton, "◀", #selector(androidBack))
        styleKey(saveButton, "Save", #selector(saveTapped))
        styleKey(hideButton, "Hide", #selector(toggleBar))
        bar.axis = .horizontal
        bar.spacing = 6
        bar.alignment = .center
        bar.distribution = .fill
        bar.backgroundColor = UIColor(white: 0, alpha: 0.55)
        bar.layer.cornerRadius = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        [closeButton, backButton, fitButton, saveButton, hideButton].forEach {
            bar.addArrangedSubview($0)
        }
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: handle.bottomAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bar.heightAnchor.constraint(equalToConstant: 34),
        ])
        setBarVisible(false)

        if #available(iOS 11.0, *) { setNeedsUpdateOfHomeIndicatorAutoHidden() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startFrameTimer()
        LegacyUI.Banner("Tap ••• for controls · touches go to Android",
                        color: LegacyUI.accent).show(in: view)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        frameTimer?.invalidate()
        frameTimer = nil
        // A finger still down when the view goes away would leave Android with
        // a stuck button.
        if pointerDown {
            pointerDown = false
            LegacyEmulationController.shared.sendPointer(guestX: Int(lastSentPoint.x),
                                                         guestY: Int(lastSentPoint.y),
                                                         down: false)
        }
    }

    private func styleKey(_ b: UIButton, _ title: String, _ action: Selector) {
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        b.setTitleColor(.white, for: .normal)
        b.contentEdgeInsets = UIEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
        b.addTarget(self, action: action, for: .touchUpInside)
    }

    private func setBarVisible(_ visible: Bool) {
        barVisible = visible
        bar.isHidden = !visible
        handle.alpha = visible ? 0.75 : 0.35
    }

    @objc private func toggleBar() { setBarVisible(!barVisible) }

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func toggleFill() {
        fillMode = !fillMode
        guestImage.contentMode = fillMode ? .scaleToFill : .scaleAspectFit
        fitButton.setTitle(fillMode ? "Fit" : "Fill", for: .normal)
    }

    @objc private func androidBack() {
        LegacyEmulationController.shared.sendBackKey()
    }

    @objc private func saveTapped() {
        LegacyUI.Banner("Saving — the guest pauses until it finishes",
                        color: LegacyUI.accent).show(in: view)
        LegacyEmulationController.shared.saveSnapshot()
    }

    // MARK: - frames

    private func startFrameTimer() {
        guard frameTimer == nil else { return }
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0,
                                         repeats: true) { [weak self] _ in
            self?.pumpFrame()
        }
    }

    private func pumpFrame() {
        guard let f = LegacyEmulationController.shared.grabFrame() else { return }
        guard let provider = CGDataProvider(data: f.data as CFData) else { return }
        let bmi = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: f.width, height: f.height,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: f.stride,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: bmi, provider: provider,
                               decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return }
        guestImage.image = UIImage(cgImage: cg)
    }

    // MARK: - touches -> guest

    /// Undo the content mode so a tap lands on the same guest pixel the finger
    /// is over. Both Fit and Fill are invertible, which is what keeps drags
    /// honest under either one.
    private func guestPoint(_ p: CGPoint) -> (x: CGFloat, y: CGFloat)? {
        guard let img = guestImage.image else { return nil }
        let b = guestImage.bounds
        let iw = img.size.width, ih = img.size.height
        guard b.width > 0, b.height > 0, iw > 0, ih > 0 else { return nil }
        let gx: CGFloat, gy: CGFloat
        if fillMode {
            gx = p.x / b.width * iw
            gy = p.y / b.height * ih
        } else {
            let s = min(b.width / iw, b.height / ih)
            let ox = (b.width - iw * s) / 2
            let oy = (b.height - ih * s) / 2
            gx = (p.x - ox) / s
            gy = (p.y - oy) / s
        }
        guard gx >= 0, gy >= 0, gx < iw, gy < ih else { return nil }
        return (gx, gy)
    }

    private func forwardTouch(_ t: UITouch, down: Bool, force: Bool) {
        let p = t.location(in: guestImage)
        let gx: CGFloat, gy: CGFloat
        if let g = guestPoint(p) {
            gx = g.x; gy = g.y
        } else if !down, lastSentPoint.x >= 0 {
            // The finger left the picture before lifting; the release still has
            // to arrive or Android keeps thinking the button is held down.
            gx = lastSentPoint.x; gy = lastSentPoint.y
        } else {
            return
        }
        if !force {
            let dx = gx - lastSentPoint.x, dy = gy - lastSentPoint.y
            if dx * dx + dy * dy < 9 { return }   // ~3 guest pixels
        }
        lastSentPoint = CGPoint(x: gx, y: gy)
        LegacyEmulationController.shared.sendPointer(guestX: Int(gx), guestY: Int(gy),
                                                     down: down)
    }

    private func overControls(_ t: UITouch) -> Bool {
        let p = t.location(in: view)
        return handle.frame.contains(p) || (barVisible && bar.frame.contains(p))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, !overControls(t) else {
            super.touchesBegan(touches, with: event); return
        }
        pointerDown = true
        forwardTouch(t, down: true, force: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerDown, let t = touches.first else {
            super.touchesMoved(touches, with: event); return
        }
        forwardTouch(t, down: true, force: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerDown, let t = touches.first else {
            super.touchesEnded(touches, with: event); return
        }
        pointerDown = false
        forwardTouch(t, down: false, force: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerDown, let t = touches.first else {
            super.touchesCancelled(touches, with: event); return
        }
        pointerDown = false
        forwardTouch(t, down: false, force: true)
    }
}
