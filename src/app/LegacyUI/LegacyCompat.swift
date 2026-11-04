// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 backport's UIKit shell.
//
// Upstream Husk is SwiftUI end to end (iOS 13+ at the least, iOS 14 for the
// App protocol). iOS 12 has no SwiftUI, so the backport adds this directory:
// a small, plain-UIKit interface with the three things the old OS needs --
// Library (add APKs, run them), JIT (get executable memory), and Settings.
//
// Everything here is deliberately free of SwiftUI, Combine, Swift concurrency
// (Task/@MainActor) and UniformTypeIdentifiers, so it compiles and runs
// against the 12.2 deployment target. The app's models (TLApp, TLReport) and
// its C API (husk-tl.h, husk-ios-jit.h) are shared unchanged.
import UIKit

enum LegacyUI {
    /// The shell's colours: dark, because a game's screen is dark and the rest
    /// of the app should not glare next to it.
    static let background = UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    static let surface = UIColor(red: 0.13, green: 0.13, blue: 0.16, alpha: 1)
    static let surfaceHigh = UIColor(red: 0.19, green: 0.19, blue: 0.23, alpha: 1)
    static let text = UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)
    static let textDim = UIColor(red: 0.62, green: 0.62, blue: 0.68, alpha: 1)
    static let accent = UIColor(red: 0.35, green: 0.72, blue: 0.36, alpha: 1)
    static let warn = UIColor(red: 0.95, green: 0.62, blue: 0.21, alpha: 1)
    static let bad = UIColor(red: 0.90, green: 0.32, blue: 0.32, alpha: 1)

    /// A rounded card, the shell's one container shape.
    static func card(_ corner: CGFloat = 14) -> UIView {
        let v = UIView()
        v.backgroundColor = surface
        v.layer.cornerRadius = corner
        v.layer.masksToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    /// A section title above a card.
    static func sectionTitle(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text.uppercased()
        l.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        l.textColor = textDim
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    /// Body text, the shell's only text style.
    static func body(_ text: String, _ size: CGFloat = 15) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = UIFont.systemFont(ofSize: size)
        l.textColor = LegacyUI.text    // the parameter shadows the colour
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    /// A dim caption.
    static func caption(_ text: String, _ size: CGFloat = 13) -> UILabel {
        let l = body(text, size)
        l.textColor = textDim
        return l
    }

    /// Monospaced text, for log lines and commands.
    static func mono(_ text: String, _ size: CGFloat = 12) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = huskMonospacedFont(ofSize: size, weight: .regular)
        l.textColor = LegacyUI.text    // the parameter shadows the colour
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    /// A filled button, the shell's one button style.
    static func button(_ title: String, filled: Bool = true) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        b.layer.cornerRadius = 12
        b.layer.masksToBounds = true
        b.contentEdgeInsets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        if filled {
            b.backgroundColor = accent
            b.setTitleColor(.white, for: .normal)
        } else {
            b.backgroundColor = surfaceHigh
            b.setTitleColor(text, for: .normal)
        }
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    /// The small status dot + label pair used all over the JIT screen.
    static func statusDot(_ ok: Bool) -> UIView {
        let d = UIView()
        d.backgroundColor = ok ? accent : bad
        d.layer.cornerRadius = 5
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: 10).isActive = true
        d.heightAnchor.constraint(equalToConstant: 10).isActive = true
        return d
    }

    /// Wrap `content` in a scroll view with the shell's standard insets. iOS 12
    /// has no contentLayoutGuide, so the scroll view's own layout guides are
    /// used, which exist since iOS 9.
    static func scroll(_ content: UIView) -> UIScrollView {
        let s = UIScrollView()
        s.alwaysBounceVertical = true
        s.backgroundColor = background
        content.translatesAutoresizingMaskIntoConstraints = false
        s.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: s.topAnchor),
            content.bottomAnchor.constraint(equalTo: s.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: s.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: s.trailingAnchor, constant: -16),
            content.widthAnchor.constraint(equalTo: s.widthAnchor, constant: -32),
        ])
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    /// A one-line banner that appears over a view controller's content.
    final class Banner: UILabel {
        init(_ text: String, color: UIColor = warn) {
            super.init(frame: .zero)
            self.text = text
            font = UIFont.systemFont(ofSize: 13, weight: .medium)
            textColor = .white
            backgroundColor = color
            numberOfLines = 0
            textAlignment = .center
            layer.cornerRadius = 10
            layer.masksToBounds = true
            alpha = 0
            translatesAutoresizingMaskIntoConstraints = false
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        /// The label has no padding of its own, and a refusal is two or three
        /// lines long ("…is an iOS app — Husk runs Android apps"), which would
        /// otherwise sit on the rounded edge.
        private static let inset = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        override func textRect(forBounds bounds: CGRect,
                               limitedToNumberOfLines lines: Int) -> CGRect {
            let inner = CGRect(x: bounds.minX + Self.inset.left, y: bounds.minY + Self.inset.top,
                               width: bounds.width - Self.inset.left - Self.inset.right,
                               height: bounds.height - Self.inset.top - Self.inset.bottom)
            let text = super.textRect(forBounds: inner, limitedToNumberOfLines: lines)
            return CGRect(x: text.minX - Self.inset.left, y: text.minY - Self.inset.top,
                          width: text.width + Self.inset.left + Self.inset.right,
                          height: text.height + Self.inset.top + Self.inset.bottom)
        }

        override func drawText(in rect: CGRect) {
            super.drawText(in: rect.inset(by: Self.inset))
        }

        func show(in view: UIView, for seconds: TimeInterval = 4) {
            view.addSubview(self)
            NSLayoutConstraint.activate([
                centerXAnchor.constraint(equalTo: view.centerXAnchor),
                bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
                widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
            ])
            UIView.animate(withDuration: 0.25) { self.alpha = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                UIView.animate(withDuration: 0.25) { self.alpha = 0 }
            }
        }
    }
}
