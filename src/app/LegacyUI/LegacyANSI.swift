// SPDX-License-Identifier: GPL-2.0-or-later
//
// Minimal terminal hygiene for the iOS 12.2 Emulation screen.
//
// A serial console streams control sequences that a UITextView would render as
// literal junk: CSI colour codes (`ESC [ 1 ; 3 2 m`), cursor moves, and CR for
// carriage return. We are not building a terminal emulator here -- the guest is a
// plain shell -- so the cheap correct thing is to drop the escape sequences and
// normalize line endings, which keeps the text readable and selectable.
import Foundation

enum LegacyANSI {

    /// Strip escape sequences and normalize CRLF/CR to LF.
    static func strip(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)

        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]

            if ch == "\r" {
                // CRLF -> single LF; a bare CR (progress redraw) becomes a newline
                // rather than vanishing, so nothing is silently swallowed.
                var j = s.index(after: i)
                if j < s.endIndex, s[j] == "\n" { j = s.index(after: j) }
                out.append("\n")
                i = j
                continue
            }

            if ch == "\u{1B}" {
                var j = s.index(after: i)
                if j < s.endIndex, s[j] == "[" {
                    // CSI: ESC '[' params, terminated by a byte in 0x40...0x7E.
                    j = s.index(after: j)
                    while j < s.endIndex {
                        let scalar = s[j].unicodeScalars.first?.value ?? 0
                        j = s.index(after: j)
                        if scalar >= 0x40 && scalar <= 0x7E { break }
                    }
                    i = j
                    continue
                }
                // Two-character escapes such as ESC ')' or a lone ESC.
                i = j < s.endIndex ? s.index(after: j) : j
                continue
            }

            // Other C0 controls (bell, backspace) would render as glyphs or eat the
            // previous character; neither is useful in this view.
            if let scalar = ch.unicodeScalars.first, scalar.value < 0x20, ch != "\n" {
                i = s.index(after: i)
                continue
            }

            out.append(ch)
            i = s.index(after: i)
        }

        return out
    }
}
