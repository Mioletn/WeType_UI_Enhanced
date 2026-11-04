// SPDX-License-Identifier: GPL-2.0-or-later
//
// The document-picker tweak (issue #60): on certificate-signed installs the
// picker's Open button hands the app a URL it cannot read, so this hooks
// UIDocumentPickerViewController and gives it a copy instead. It is a prebuilt
// Theos dylib for iOS 15 that this project cannot rebuild.
//
// It is embedded rather than linked, and loaded here on the systems it was built
// for. Linking it made it load at launch on every system, and on iOS 12 the
// first imported call inside its init block landed on 0x0 -- SIGSEGV at address
// 0, on a queue started from the tweak's own init (crash report
// Husk-2026-10-22-131628). Its LC_BUILD_VERSION minimum had already been patched
// down to 12.2 so dyld would map it; that is not the same as it being able to
// run, because the stub and lazy-binding layout it uses is the newer one.
//
// So: load it where it works, never on 12.2, where the legacy shell copies the
// picker's results itself (LegacyIngest.copy, with the same security-scoped
// access and NSFileCoordinator the tweak would have used).

import Foundation

enum FilePickerFix {
    /// dlopen the embedded tweak. Failure is logged and survivable: the picker
    /// behaves as it does without the fix, which is the pre-existing behaviour.
    static func installIfAvailable() {
        guard #available(iOS 15.0, *) else { return }
        if dlopen("@rpath/libFilePickerFix.dylib", RTLD_NOW) == nil {
            let why = dlerror().map { String(cString: $0) } ?? "no reason given"
            HuskLog.log("ui", "file picker fix not loaded: \(why)")
            return
        }
        HuskLog.log("ui", "file picker fix loaded")
    }
}
