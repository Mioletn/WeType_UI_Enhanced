// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's Settings: what this build is, what it cannot do, and
// the log — which on the old OS is the only diagnostics there are.
import UIKit
import SafariServices

final class LegacySettingsViewController: UIViewController {
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
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

        buildAbout()
        buildLimits()
        buildLogCard()
    }

    private func card(_ arranged: [UIView]) -> UIView {
        let c = LegacyUI.card()
        let pad = UIStackView(arrangedSubviews: arranged)
        pad.axis = .vertical
        pad.spacing = 10
        pad.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(pad)
        NSLayoutConstraint.activate([
            pad.topAnchor.constraint(equalTo: c.topAnchor, constant: 14),
            pad.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -14),
            pad.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
            pad.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -14),
        ])
        return c
    }

    private func buildAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let text = LegacyUI.body(
            "Husk \(version) (\(build)) — iOS 12.2 legacy shell.\n\n"
            + "This is the Android-on-iPhone app, running on the oldest iOS a sideloader can still "
            + "install on (AltStore's floor is 12.2). The interface you are looking at is the "
            + "backport's UIKit shell: the SwiftUI screens upstream ships are iOS 13+, so on iOS 12 "
            + "this one stands in for them.", 14)
        stack.addArrangedSubview(LegacyUI.sectionTitle("About"))
        stack.addArrangedSubview(card([text]))
    }

    private func buildLimits() {
        let text = LegacyUI.body(
            "• Games on the older loader path: run here.\n"
            + "• Games on the native runtime (Unity, cocos2d-x, Minecraft, SDL, Unreal, Godot, "
            + "GTA, GameMaker, Java apps, Flutter): run here too — they draw into a CAMetalLayer, "
            + "which iOS 8 has, through the ANGLE build the app carries.\n"
            + "• Web apps: need iOS 15, where the WKWebView bridge lives.\n"
            + "• Emulation: a real Alpine Linux guest (3.24.3, aarch64) under QEMU/TCG — persistent ext4 root disk, working network, apk, and a console you can type into from the Emulation tab. Wants a jailbreak so the JIT pages may execute; no StikDebug. Boot kernel and root image live outside the IPA (they are far too large to ship per build), so the Emulation tab reports whether they are present.\n"
            + "• JIT: from a debugger (JIT tab), as on every other iOS.", 14)
        stack.addArrangedSubview(LegacyUI.sectionTitle("What works on iOS 12.2"))
        stack.addArrangedSubview(card([text]))
    }

    private func buildLogCard() {
        let open = LegacyUI.button("Show log", filled: false)
        open.addTarget(self, action: #selector(showLog), for: .touchUpInside)
        let docs = LegacyUI.button("Backport report (GitHub)", filled: false)
        docs.addTarget(self, action: #selector(openDocs), for: .touchUpInside)
        stack.addArrangedSubview(LegacyUI.sectionTitle("Diagnostics"))
        stack.addArrangedSubview(card([
            LegacyUI.caption("The log is the only diagnostics this build has: everything Husk and "
                             + "the C side print lands in one file.", 13),
            open, docs,
        ]))
    }

    @objc private func showLog() {
        let vc = UIViewController()
        vc.title = "Log"
        vc.view.backgroundColor = .black
        let text = UITextView()
        text.backgroundColor = .black
        text.textColor = UIColor(red: 0.85, green: 0.9, blue: 0.85, alpha: 1)
        text.font = huskMonospacedFont(ofSize: 10, weight: .regular)
        text.isEditable = false
        text.text = HuskLog.recentLines(2000).joined(separator: "\n")
        text.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            text.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
        ])
        let share = UIBarButtonItem(barButtonSystemItem: .action, target: self,
                                    action: #selector(shareLog))
        vc.navigationItem.rightBarButtonItem = share
        navigationController?.pushViewController(vc, animated: true)
    }

    @objc private func shareLog() {
        let items: [Any] = [HuskLog.logFileURL]
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        present(sheet, animated: true)
    }

    @objc private func openDocs() {
        guard let url = URL(string: "https://github.com/Leviidev/Husk/blob/main/docs/90-ios12-backport.md") else { return }
        present(SFSafariViewController(url: url), animated: true)
    }
}
