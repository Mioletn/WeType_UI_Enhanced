// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's root: four tabs, because that is the whole app on the
// old OS. Library (what you can run), JIT (what you must do first), Settings
// (what this build is and is not), Emulation (QEMU directly, no SwiftUI).
import UIKit

final class LegacyRootViewController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()

        // Title-only tab items: SF Symbols (UIImage(systemName:)) are iOS 13+,
        // and the shell's asset catalog carries no tab icons.
        let library = UINavigationController(rootViewController: LegacyLibraryViewController())
        library.tabBarItem = UITabBarItem(title: "Library", image: nil, tag: 0)

        let jit = UINavigationController(rootViewController: LegacyJITViewController())
        jit.tabBarItem = UITabBarItem(title: "JIT", image: nil, tag: 1)

        let settings = UINavigationController(rootViewController: LegacySettingsViewController())
        settings.tabBarItem = UITabBarItem(title: "Settings", image: nil, tag: 2)

        let emu = UINavigationController(rootViewController: LegacyEmulationViewController())
        emu.tabBarItem = UITabBarItem(title: "Emulation", image: nil, tag: 3)

        viewControllers = [library, jit, settings, emu]
        tabBar.barTintColor = LegacyUI.surface
        tabBar.tintColor = LegacyUI.accent
        tabBar.unselectedItemTintColor = LegacyUI.textDim

        // DEBUG auto-start: when this flag file is present, begin the QEMU guest
        // a few seconds after launch so the Emulation bring-up can be exercised
        // and its serial log captured with no UI interaction. Used for headless
        // bring-up testing on-device; harmless (no-op) in normal use.
        //
        // The flag lives in the app's own bundle, not at a fixed /Applications
        // path: a sideloaded install lives under
        // /var/containers/Bundle/Application/<UUID>/Husk.app, so only the bundle
        // path is correct on every install method.
        var autostartCandidates = [Bundle.main.bundlePath + "/emu_autostart"]
        autostartCandidates.append("/Applications/Husk.app/emu_autostart")
        let autostartFlag = autostartCandidates.first {
            FileManager.default.fileExists(atPath: $0)
        }
        if let flag = autostartFlag {
            HuskLog.log("emu", "autostart flag found: \(flag)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                LegacyEmulationController.shared.start()
                HuskLog.log("emu", "autostart: QEMU start requested from flag file")
            }
        }
    }

    override var prefersStatusBarHidden: Bool { false }
}
