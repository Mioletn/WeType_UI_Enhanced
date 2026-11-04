// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's Emulation screen.
//
// A plain UIKit view: a Start button that drives LegacyEmulationController, a
// live mirror of the guest framebuffer (pulled from the software display every
// tick), and the guest serial console tailed into a text view. No SwiftUI -- this
// is the old OS's shell, and the whole point is to prove QEMU runs here without
// the iOS 15 SwiftUI stack.
import UIKit

final class LegacyEmulationViewController: UIViewController {

    private let statusLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let imageView = UIImageView()
    private let logView = UITextView()
    private let spinner = UIActivityIndicatorView(style: .white)

    private var frameTimer: Timer?
    private var logTimer: Timer?
    private var lastSeq: UInt64 = 0

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
        refreshLog()
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

        startButton.setTitle("Start Android (QEMU)", for: .normal)
        startButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)

        stopButton.setTitle("Stop", for: .normal)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        stopButton.isEnabled = false

        spinner.hidesWhenStopped = true

        let buttonRow = UIStackView(arrangedSubviews: [startButton, stopButton, spinner])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 16
        buttonRow.alignment = .center
        buttonRow.distribution = .fill

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.layer.borderColor = LegacyUI.surfaceHigh.cgColor
        imageView.layer.borderWidth = 1
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)

        logView.backgroundColor = LegacyUI.surface
        logView.textColor = LegacyUI.textDim
        // monospacedSystemFont is iOS 13+; this is the backport's own shim.
        logView.font = huskMonospacedFont(ofSize: 11, weight: .regular)
        logView.isEditable = false
        logView.isSelectable = false
        logView.layer.cornerRadius = 8
        logView.text = "Guest serial console will appear here once QEMU starts."

        let vstack = UIStackView(arrangedSubviews: [statusLabel, buttonRow, imageView, logView])
        vstack.axis = .vertical
        vstack.spacing = 12
        vstack.alignment = .fill
        vstack.distribution = .fill
        vstack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vstack)

        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            vstack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            vstack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            vstack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            logView.heightAnchor.constraint(equalToConstant: 160),
        ])
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

    // MARK: - timers

    private func startTimers() {
        guard frameTimer == nil else { return }
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.pumpFrame()
        }
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refreshLog()
        }
    }

    private func stopTimers() {
        frameTimer?.invalidate(); frameTimer = nil
        logTimer?.invalidate(); logTimer = nil
    }

    private func pumpFrame() {
        guard let frame = LegacyEmulationController.shared.grabFrame() else { return }
        lastSeq = LegacyEmulationController.shared.latestSequence()
        guard let img = makeImage(data: frame.data, width: frame.width,
                                  height: frame.height, stride: frame.stride) else { return }
        imageView.image = img
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

    private func refreshLog() {
        let path = LegacyEmulationController.shared.serialLogPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let tail: String
        if text.count > 6000 {
            tail = String(text.suffix(6000))
        } else {
            tail = text
        }
        if tail != logView.text {
            logView.text = tail
            let range = NSRange(location: (tail as NSString).length, length: 0)
            logView.scrollRangeToVisible(range)
        }
    }

    private func refreshStatus() {
        let running = LegacyEmulationController.shared.isRunning
        if running {
            statusLabel.text = "QEMU running — seq \(lastSeq)"
            statusLabel.textColor = LegacyUI.accent
            spinner.stopAnimating()
        } else {
            statusLabel.text = "Idle"
            statusLabel.textColor = LegacyUI.text
            spinner.stopAnimating()
        }
    }
}
