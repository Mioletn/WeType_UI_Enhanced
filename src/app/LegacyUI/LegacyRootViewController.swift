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

        // FEXCore probe (Madeira-lite M0). Gated on a marker file so a normal
        // boot never touches the JIT region -- the probe takes a dual-mapped
        // region and leaves QEMU without a second one. With the marker present
        // it runs a 12-byte x86-64 exit(42) through FEXCore and writes the
        // result to Documents/husk-fex-probe.log for collection over SSH.
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let probeMarker = (docs as NSString).appendingPathComponent("husk-fex-probe")
        let peMarker = (docs as NSString).appendingPathComponent("husk-pe-probe")
        let m6Marker = (docs as NSString).appendingPathComponent("husk-m6-probe")
        let m6bMarker = (docs as NSString).appendingPathComponent("husk-m6b-probe")
        let m7Marker = (docs as NSString).appendingPathComponent("husk-m7-probe")
        let m7bMarker = (docs as NSString).appendingPathComponent("husk-m7b-probe")
        let m7cMarker = (docs as NSString).appendingPathComponent("husk-m7c-probe")
        // Only ONE FEXCore guest program may run per launch: a second guest
        // thread crashes on iOS 12.2 (SIGBUS in the second JIT code buffer).
        // The markers are therefore mutually exclusive, in this priority:
        // m7c (real DLL + real ntdll execution) > m7b (real DLL + page
        // protections) > m7 (real DLL map, host-only) >
        // m6b (syscall -> wineserver) > m6 (Windows syscalls) >
        // pe (Linux exit stub) > fex (M0 self-check).
        if FileManager.default.fileExists(atPath: m7cMarker) {
            DispatchQueue.global(qos: .userInitiated).async {
                // M7c: the first execution of REAL Windows code on this
                // device. Loads the 4.8 MB Wine ntdll.dll, applies real page
                // protections, then runs RtlCompareMemory through FEXCore with
                // no TEB/PEB at all. rc=42 needs both comparisons correct.
                let m7cRc = husk_m7c_probe()
                var m7cMsg = "husk-m7c-probe: rc=\(m7cRc)"
                if m7cRc != 42, let m7cErr = husk_m7_last_error() {
                    m7cMsg += " err=\(String(cString: m7cErr))"
                }
                HuskLog.log("m7c", m7cMsg)
                let m7cLog = (docs as NSString).appendingPathComponent("husk-m7c-probe.log")
                try? (m7cMsg + "\n").write(toFile: m7cLog, atomically: true, encoding: .utf8)
            }
        } else if FileManager.default.fileExists(atPath: m7bMarker) {
            DispatchQueue.global(qos: .userInitiated).async {
                // M7b: same map as M7a, then the real per-16 KB-page
                // protections (RX/RW/R in 5 mprotect ranges) read back with
                // mach_vm_region_recurse. No guest thread: it cannot consume
                // this launch's single JIT region.
                let m7bRc = husk_m7b_probe()
                var m7bMsg = "husk-m7b-probe: rc=\(m7bRc)"
                if m7bRc != 42, let m7bErr = husk_m7_last_error() {
                    m7bMsg += " err=\(String(cString: m7bErr))"
                }
                HuskLog.log("m7b", m7bMsg)
                let m7bLog = (docs as NSString).appendingPathComponent("husk-m7b-probe.log")
                try? (m7bMsg + "\n").write(toFile: m7bLog, atomically: true, encoding: .utf8)
            }
        } else if FileManager.default.fileExists(atPath: m7Marker) {
            DispatchQueue.global(qos: .userInitiated).async {
                // M7a is pure host-side PE loading: no FEXCore guest thread,
                // no TEB/PEB, so it cannot consume this launch's single JIT
                // region. It lays out the real 4.8 MB Wine ntdll.dll.
                let m7Rc = husk_m7_probe()
                var m7Msg = "husk-m7-probe: rc=\(m7Rc)"
                if m7Rc != 42, let m7Err = husk_m7_last_error() {
                    m7Msg += " err=\(String(cString: m7Err))"
                }
                HuskLog.log("m7", m7Msg)
                let m7Log = (docs as NSString).appendingPathComponent("husk-m7-probe.log")
                try? (m7Msg + "\n").write(toFile: m7Log, atomically: true, encoding: .utf8)
            }
        } else if FileManager.default.fileExists(atPath: m6bMarker) {
            DispatchQueue.global(qos: .userInitiated).async {
                // M6b needs the wineserver request channel BEFORE the guest
                // thread is created. husk_ws_start() is synchronous (socket
                // discovery + REQ_init_first_thread handshake), so keeping
                // both calls on this same background queue makes the ordering
                // deterministic without blocking the main thread.
                let wsRc = husk_ws_start()
                HuskLog.log("m6b", "husk-ws-start: rc=\(wsRc)")
                let m6bRc = husk_m6b_probe()
                var m6bMsg = "husk-m6b-probe: rc=\(m6bRc) ws=\(wsRc)"
                if m6bRc != 42, let m6bErr = husk_m6_last_error() {
                    m6bMsg += " err=\(String(cString: m6bErr))"
                }
                HuskLog.log("m6b", m6bMsg)
                let m6bLog = (docs as NSString).appendingPathComponent("husk-m6b-probe.log")
                try? (m6bMsg + "\n").write(toFile: m6bLog, atomically: true, encoding: .utf8)
            }
        } else if FileManager.default.fileExists(atPath: m6Marker) {
            DispatchQueue.global(qos: .userInitiated).async {
                // M6: same real PE bytes, but the guest now makes four Windows
                // x64 syscalls through the 258-entry id dispatch table. rc=42
                // means the whole sequence and the NTSTATUS write-back worked.
                let m6Rc = husk_m6_probe()
                var m6Msg = "husk-m6-probe: rc=\(m6Rc)"
                if m6Rc != 42, let m6Err = husk_m6_last_error() {
                    m6Msg += " err=\(String(cString: m6Err))"
                }
                HuskLog.log("m6", m6Msg)
                let m6Log = (docs as NSString).appendingPathComponent("husk-m6-probe.log")
                try? (m6Msg + "\n").write(toFile: m6Log, atomically: true, encoding: .utf8)
            }
        } else if FileManager.default.fileExists(atPath: peMarker) {
            DispatchQueue.global(qos: .userInitiated).async {
                // M5: freestanding PE32+ mapped and executed as the launch's
                // only guest program. Its entry returns 42 through a stubbed
                // exit(60) syscall; see FEXBridge.mm.
                let peRc = husk_pe_probe()
                var peMsg = "husk-pe-probe: rc=\(peRc)"
                if peRc != 42, let peErr = husk_pe_last_error() {
                    peMsg += " err=\(String(cString: peErr))"
                }
                HuskLog.log("pe", peMsg)
                let peLog = (docs as NSString).appendingPathComponent("husk-pe-probe.log")
                try? (peMsg + "\n").write(toFile: peLog, atomically: true, encoding: .utf8)
            }
        } else if FileManager.default.fileExists(atPath: probeMarker) {
            DispatchQueue.global(qos: .userInitiated).async {
                let rc = husk_fex_probe()
                var msg = "husk-fex-probe: exit=\(rc)"
                if rc != 42, let e = husk_fex_last_error() {
                    msg += " err=\(String(cString: e))"
                }
                HuskLog.log("fex", msg)
                let logPath = (docs as NSString).appendingPathComponent("husk-fex-probe.log")
                try? (msg + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
            }
        }

        // Wine runtime probe (Madeira-lite M1e). Same marker discipline: with
        // Documents/husk-wine-probe present, wineserver is started on a
        // background thread and the probe waits for its socket. Result goes to
        // Documents/husk-wine-probe.log.
        let wineMarker = (docs as NSString).appendingPathComponent("husk-wine-probe")
        if FileManager.default.fileExists(atPath: wineMarker) {
            DispatchQueue.global(qos: .userInitiated).async {
                let rc = husk_wine_probe()
                var msg = "husk-wine-probe: rc=\(rc)"
                if let e = husk_wine_last_error() {
                    msg += " \(String(cString: e))"
                }
                HuskLog.log("wine", msg)
                let logPath = (docs as NSString).appendingPathComponent("husk-wine-probe.log")
                try? (msg + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
            }
        }

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
