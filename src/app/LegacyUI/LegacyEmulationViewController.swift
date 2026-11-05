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
    private let spinner = UIActivityIndicatorView(style: .white)
    private let modeControl = UISegmentedControl(items: ["Console", "Screen"])
    private let terminalView = UITextView()
    private let screenView = UIImageView()
    private let inputField = UITextField()
    private let enterButton = UIButton(type: .system)
    private let ctrlCButton = UIButton(type: .system)
    private let tabButton = UIButton(type: .system)

    private var tickTimer: Timer?
    private var screenTimer: Timer?
    private var lastSeq: UInt64 = 0
    private var lastRendered = ""

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

        let buttonRow = UIStackView(arrangedSubviews: [startButton, stopButton,
                                                       resetButton, spinner])
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
                                                    terminalView, screenView, inputRow])
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
        LegacyEmulationController.shared.start()
        stopButton.isEnabled = true
        refreshStatus()
    }

    @objc private func stopTapped() {
        LegacyEmulationController.shared.stop()
        stopButton.isEnabled = false
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
        let console = modeControl.selectedSegmentIndex == 0
        terminalView.isHidden = !console
        screenView.isHidden = console
        if console {
            screenTimer?.invalidate()
            screenTimer = nil
            refreshTerminal()
        } else {
            startScreenTimer()
            pumpFrame()
        }
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

    /// A tap on the guest framebuffer becomes a click in guest pixels. The image
    /// is aspect-fitted, so the letterbox bars have to be undone first.
    @objc private func screenTapped(_ g: UITapGestureRecognizer) {
        guard let img = screenView.image else { return }
        let bounds = screenView.bounds
        let iw = img.size.width, ih = img.size.height
        guard bounds.width > 0, bounds.height > 0, iw > 0, ih > 0 else { return }

        let scale = min(bounds.width / iw, bounds.height / ih)
        let ox = (bounds.width - iw * scale) / 2
        let oy = (bounds.height - ih * scale) / 2
        let p = g.location(in: screenView)

        let gx = (p.x - ox) / scale
        let gy = (p.y - oy) / scale
        guard gx >= 0, gy >= 0, gx < iw, gy < ih else { return }

        LegacyEmulationController.shared.sendClick(guestX: Int(gx), guestY: Int(gy))
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
        }
        if modeControl.selectedSegmentIndex == 1 {
            startScreenTimer()
        }
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
        guard let frame = LegacyEmulationController.shared.grabFrame() else { return }
        lastSeq = LegacyEmulationController.shared.latestSequence()
        guard let img = makeImage(data: frame.data, width: frame.width,
                                  height: frame.height, stride: frame.stride) else { return }
        screenView.image = img
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
