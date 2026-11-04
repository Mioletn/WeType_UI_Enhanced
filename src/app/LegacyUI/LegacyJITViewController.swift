// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's JIT screen.
//
// On iOS every app is forbidden to write executable memory; a debugger
// attaching to the process is what lifts that. Upstream's four ways in
// (StikDebug, TrollStore, Dopamine's Allow JIT, built-in StikJIT) all need
// iOS 14 at the least, so on iOS 12.2 there are two, and this screen is both
// their status readout and their walkthrough:
//
//   * No jailbreak — a debugger on a computer (lldb through ios-deploy, or
//     Xcode's Devices window) attaches over USB and marks the process
//     debugged. HusK then makes its own executable memory, which iOS 12
//     allows a debugged process to do.
//   * Jailbroken (unc0ver, Chimera, checkra1n on A7–A11) — either the same
//     debugger dance over Wi-Fi with debugserver, or the jailbreak's own
//     "allow JIT" behaviour marks the process debugged at launch.
//
// The C side (husk-ios-jit.c) already knows how to use CS_DEBUGGED; what was
// missing was a screen that explains the two ways in on the old OS.
import UIKit

final class LegacyJITViewController: UIViewController {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var statusTitle = UILabel()
    private var statusRows = UIStackView()
    private var claimButton = UIButton()
    private var pollTimer: DispatchSourceTimer?

    private func row(_ title: String) -> (UILabel, UIView) {
        let label = UILabel()
        label.text = title
        label.font = UIFont.systemFont(ofSize: 15)
        label.textColor = LegacyUI.text
        let value = UILabel()
        value.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        value.textColor = LegacyUI.textDim
        value.textAlignment = .right
        let line = UIStackView(arrangedSubviews: [label, value])
        line.alignment = .center
        line.distribution = .fill
        line.spacing = 12
        return (value, line)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "JIT"
        view.backgroundColor = LegacyUI.background

        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -32),
        ])

        buildStatusCard()
        buildInstructions()
    }

    // MARK: status card

    private func buildStatusCard() {
        let card = LegacyUI.card()
        let pad = UIStackView(arrangedSubviews: [statusTitle, statusRows, claimButton])
        pad.axis = .vertical
        pad.spacing = 12
        pad.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(pad)
        NSLayoutConstraint.activate([
            pad.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            pad.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            pad.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            pad.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])

        statusTitle.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        statusTitle.textColor = LegacyUI.text

        statusRows.axis = .vertical
        statusRows.spacing = 8
        statusRows.distribution = .fillEqually

        claimButton.setTitle("Claim JIT now", for: .normal)
        claimButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        claimButton.backgroundColor = LegacyUI.accent
        claimButton.setTitleColor(.white, for: .normal)
        claimButton.layer.cornerRadius = 12
        claimButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        claimButton.addTarget(self, action: #selector(claimTapped), for: .touchUpInside)

        stack.addArrangedSubview(LegacyUI.sectionTitle("Status"))
        stack.addArrangedSubview(card)
    }

    private func rebuildStatusRows() {
        for sub in statusRows.arrangedSubviews { statusRows.removeArrangedSubview(sub); sub.removeFromSuperview() }

        let jitReady = JITBootstrap.ready
        statusTitle.text = jitReady ? "JIT is on" : "JIT is off"
        statusTitle.textColor = jitReady ? LegacyUI.accent : LegacyUI.text

        // No logging in the poll: debuggedFlag is the silent twin of isDebuggerAttached.
        let debugged = JITBootstrap.debuggedFlag
        let jailbroken = JITBootstrap.isJailbroken
        let route: String? = {
            guard let c = husk_ios_jit_self_route() else { return nil }
            return String(cString: c)
        }()
        let mapjit = JITBootstrap.mapJITResult

        func addRow(_ title: String, _ value: String, _ ok: Bool?) {
            let (valueLabel, line) = row(title)
            valueLabel.text = value
            valueLabel.textColor = ok == nil ? LegacyUI.textDim : (ok! ? LegacyUI.accent : LegacyUI.bad)
            statusRows.addArrangedSubview(line)
        }

        addRow("Debugger attached", debugged ? "yes" : "no", debugged)
        addRow("Jailbroken", jailbroken ? "yes" : "no", jailbroken)
        addRow("JIT region held", jitReady ? "yes" : "not yet", jitReady)
        if let route { addRow("Route used", route, true) }
        if let mapjit { addRow("MAP_JIT executes", mapjit ? "yes" : "no", mapjit) }

        claimButton.isEnabled = !jitReady
        claimButton.alpha = jitReady ? 0.4 : 1
    }

    // MARK: instructions

    private func buildInstructions() {
        stack.addArrangedSubview(LegacyUI.sectionTitle("What has to happen"))

        let why = LegacyUI.card()
        let whyText = LegacyUI.body(
            "iOS forbids every app from writing memory it can then execute. A game on the "
            + "translation layer runs its own 64-bit code here, so that code has to be made "
            + "executable first — and on iOS the only thing that lifts the ban is a debugger "
            + "attaching to the process. Once one has, iOS 12 lets the process make the "
            + "executable memory itself, which is what “Claim JIT now” does.", 14)
        why.addSubview(whyText)
        NSLayoutConstraint.activate([
            whyText.topAnchor.constraint(equalTo: why.topAnchor, constant: 14),
            whyText.bottomAnchor.constraint(equalTo: why.bottomAnchor, constant: -14),
            whyText.leadingAnchor.constraint(equalTo: why.leadingAnchor, constant: 14),
            whyText.trailingAnchor.constraint(equalTo: why.trailingAnchor, constant: -14),
        ])
        stack.addArrangedSubview(why)

        stack.addArrangedSubview(LegacyUI.sectionTitle("Route 1 — no jailbreak (a computer, over USB)"))

        let r1 = LegacyUI.card()
        let r1Text = LegacyUI.mono(
            """
            1. Install Husk.ipa with Cydia Impactor (or AltStore, which
               needs iOS 12.2 — exactly this version). The IPA carries
               get-task-allow, which is what lets a debugger attach.
            2. From a Mac with Xcode:
                 ios-deploy --debug --bundle <path to Husk.app>
               (npm install -g ios-deploy). Xcode's Devices window works
               too: install the app, then launch it from there with the
               debugger attached.
            3. lldb launches Husk and stays attached. Come back to this
               tab: “Debugger attached” turns yes.
            4. Tap “Claim JIT now”. The JIT region survives the debugger
               letting go, so the cable can come out afterwards.
            """)
        r1.addSubview(r1Text)
        NSLayoutConstraint.activate([
            r1Text.topAnchor.constraint(equalTo: r1.topAnchor, constant: 14),
            r1Text.bottomAnchor.constraint(equalTo: r1.bottomAnchor, constant: -14),
            r1Text.leadingAnchor.constraint(equalTo: r1.leadingAnchor, constant: 14),
            r1Text.trailingAnchor.constraint(equalTo: r1.trailingAnchor, constant: -14),
        ])
        stack.addArrangedSubview(r1)

        stack.addArrangedSubview(LegacyUI.sectionTitle("Route 2 — jailbroken iOS 12 (unc0ver / Chimera / checkra1n)"))

        let r2 = LegacyUI.card()
        let r2Text = LegacyUI.mono(
            """
            A. Let the jailbreak do it. unc0ver and Chimera mark an app
               as debugged when they are told to allow JIT in apps. With
               that on, open Husk: “Debugger attached” reads yes at
               launch, and “Claim JIT now” works with no computer.
            B. Or attach debugserver yourself:
                 ssh root@<iphone>
                 debugserver 0.0.0.0:1234 --attach=<Husk's PID>
               then from the computer:
                 lldb -o "gdb-remote <iphone's IP>:1234"
               (debugserver is inside the matching iOS 12.x Developer
               DiskImage: /usr/bin/debugserver after you push it over.)
               With it attached, tap “Claim JIT now”.
            """)
        r2.addSubview(r2Text)
        NSLayoutConstraint.activate([
            r2Text.topAnchor.constraint(equalTo: r2.topAnchor, constant: 14),
            r2Text.bottomAnchor.constraint(equalTo: r2.bottomAnchor, constant: -14),
            r2Text.leadingAnchor.constraint(equalTo: r2.leadingAnchor, constant: 14),
            r2Text.trailingAnchor.constraint(equalTo: r2.trailingAnchor, constant: -14),
        ])
        stack.addArrangedSubview(r2)

        stack.addArrangedSubview(LegacyUI.sectionTitle("Not available on iOS 12.2"))

        let r3 = LegacyUI.card()
        let r3Text = LegacyUI.body(
            "StikDebug needs iOS 17.4. TrollStore covers iOS 14–16. Built-in StikJIT is iOS 26. "
            + "None of them exist here — that is the whole reason for the two routes above.", 14)
        r3.addSubview(r3Text)
        NSLayoutConstraint.activate([
            r3Text.topAnchor.constraint(equalTo: r3.topAnchor, constant: 14),
            r3Text.bottomAnchor.constraint(equalTo: r3.bottomAnchor, constant: -14),
            r3Text.leadingAnchor.constraint(equalTo: r3.leadingAnchor, constant: 14),
            r3Text.trailingAnchor.constraint(equalTo: r3.trailingAnchor, constant: -14),
        ])
        stack.addArrangedSubview(r3)
    }

    // MARK: polling

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuildStatusRows()
        pollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.rebuildStatusRows() }
        t.resume()
        pollTimer = t
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.cancel()
        pollTimer = nil
    }

    @objc private func claimTapped() {
        let ok = JITBootstrap.prewarm()
        rebuildStatusRows()
        if ok {
            LegacyUI.Banner("JIT is on — you can close the debugger now", color: LegacyUI.accent)
                .show(in: view)
        } else {
            let why = JITBootstrap.lastFailure ?? "No debugger is attached and no jailbreak was found. "
                                                 + "Work through one of the two routes above, then try again."
            LegacyUI.Banner(why, color: LegacyUI.bad).show(in: view, for: 8)
        }
    }
}
