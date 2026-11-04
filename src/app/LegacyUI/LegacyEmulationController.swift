// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's Emulation controller.
//
// This drives QEMU's system emulator directly through Husk's C bridge
// (HuskBridge.h: qemu_init / qemu_main_loop, husk_display_init /
// husk_display_lock_frame, husk_ios_jit_*). It deliberately does NOT go through
// QemuRunner or HuskGLView: those are marked @available(iOS 15.0, *) and
// HuskGLView imports SwiftUI, which simply does not exist on iOS 12.
//
// On iOS 12.2 the two things that must work do, because the C layer was built
// for this OS:
//   * JIT  -- husk-ios-jit.c's in-process, jailbreak-friendly route
//             (husk_self_dual_mapping: MAP_JIT, then plain memory made
//             executable) needs no debugger or StikDebug. A jailbroken 12.2
//             kernel allows unsigned pages to execute, which is exactly the
//             "plain" route.
//   * Display -- husk_display_init() + husk_display_lock_frame() is a pure-C
//             software path: it hands the guest framebuffer to us and we upload
//             it. No SwiftUI, no HuskGLView, no Metal presenter required.
//
// The default profile is Phase 0 (Alpine), whose kernel + initramfs ship in the
// IPA, so no download is needed to prove the whole TCG -> display -> input chain
// runs on this OS.
import Foundation
import UIKit

final class LegacyEmulationController {

    static let shared = LegacyEmulationController()

    private var thread: Thread?
    private(set) var isRunning = false

    /// Where the guest's serial console is written. A plain file chardev (see
    /// the -chardev argument), folded back into the UI by the view controller.
    let serialLogPath: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                       .userDomainMask, true)[0]
        return (docs as NSString).appendingPathComponent("husk-phase0-serial.log")
    }()

    /// JIT region size, in bytes. Must match tb-size in the command line below
    /// so QEMU takes the whole prewarmed region instead of asking for a second
    /// one (which, with no debugger attached, can never be granted).
    private let jitBytes = 256 * 1024 * 1024

    // MARK: - start / stop

    func start() {
        guard !isRunning else { return }

        // 1. Trap guard: an unserviced brk must return 0, not kill the process.
        husk_ios_jit_install_trap_handler()

        // 2. Claim the JIT region now. On 12.2 the device is jailbroken, so
        //    husk-ios-jit.c takes the plain-memory route with no StikDebug.
        let jitOK = husk_ios_jit_prewarm(jitBytes)
        HuskLog.log("emu", "JIT prewarm: \(jitOK ? "OK" : "FAILED")"
                         + (jitOK ? "" : " -- QEMU may abort on code-gen memory"))

        // 3. Software display listener must exist before qemu_init creates the
        //    graphics console.
        husk_display_init()

        // 4. Run QEMU on its own thread (it never returns until the guest halts).
        let t = Thread { [weak self] in self?.runQEMU() }
        t.name = "husk.qemu.legacy"
        // Same reasoning as QemuRunner: the guest's speed is the app's speed,
        // so it is user-interactive, on the performance cores.
        t.qualityOfService = .userInteractive
        t.stackSize = 16 * 1024 * 1024
        thread = t
        t.start()
    }

    func stop() {
        // QEMU has no monitor on iOS, so there is no clean shutdown request we
        // can send. The guest stays up until it reboots or is killed; telling
        // the user that is honest. A future build can add a -monitor chardev.
        HuskLog.log("emu", "stop() requested -- guest keeps running until it halts")
    }

    // MARK: - QEMU thread

    private func runQEMU() {
        isRunning = true
        let bundle = Bundle.main.bundlePath
        let args: [String] = [
            "qemu-system-aarch64",
            "-M", "virt",
            "-cpu", "cortex-a72",
            "-smp", "4",
            "-m", "1024",

            // split-wx=on is mandatory: with it off TCG goes straight to an RWX
            // mmap, which iOS refuses. The splitwx allocator is the only one
            // that can work here, and it is fed by husk_ios_jit_prewarm above.
            "-accel", "tcg,tb-size=256,thread=multi,split-wx=on",

            "-kernel", "\(bundle)/vmlinuz-virt",
            "-initrd", "\(bundle)/initramfs-virt",
            "-append", "console=tty0 console=ttyAMA0 loglevel=8",

            // No network needed for Phase 0; dropping the default virtio-net-pci
            // avoids a missing-ROM aborts we have already hit once.
            "-nic", "none",
            "-L", "\(bundle)/pc-bios",

            // Graphics + input devices. The software display listens on console 0.
            "-device", "virtio-gpu-pci",
            "-device", "virtio-tablet-pci",
            "-device", "virtio-keyboard-pci",

            // Guest serial console -> file. Far more informative than anything
            // else: if the guest is running translated code at all, it says so.
            "-chardev", "file,id=ser0,path=\(serialLogPath)",
            "-serial", "chardev:ser0",

            // Our DisplayChangeListener is the display; QEMU needs no backend.
            "-display", "none",
            "-monitor", "none",
            "-no-reboot",

            // Quiet but useful diagnostics.
            "-d", "guest_errors,unimp",
        ]

        // Confirm the guest images are in the bundle before QEMU opens them.
        for p in ["\(bundle)/vmlinuz-virt", "\(bundle)/initramfs-virt"] {
            let ok = FileManager.default.fileExists(atPath: p)
            HuskLog.log("emu", "needs \(((p as NSString).lastPathComponent)): "
                            + (ok ? "present" : "MISSING"))
        }

        HuskLog.log("emu", "---- QEMU argv (\(args.count)) ----")
        for (i, a) in args.enumerated() {
            HuskLog.log("emu", String(format: "  [%2d] %@", i, a))
        }

        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        argv.withUnsafeMutableBufferPointer { buf in
            qemu_init(Int32(args.count), buf.baseAddress)
        }
        HuskLog.log("emu", "qemu_init() returned -- DISPLAY MODE: software (CPU framebuffer)")

        HuskLog.log("emu", "entering qemu_main_loop() -- does not return until shutdown")
        qemu_main_loop()
        HuskLog.log("emu", "qemu_main_loop() RETURNED -- guest stopped")
        qemu_cleanup()
        HuskLog.log("emu", "qemu_cleanup() done")
        isRunning = false
    }

    // MARK: - frame pump (called by the view controller on a timer)

    /// Pull the latest guest frame, or nil if the display has nothing yet.
    ///
    /// Returns the raw framebuffer bytes (32bpp, what virtio-gpu gives and what
    /// Metal wants), plus width/height/stride, so the caller can build a CGImage.
    func grabFrame() -> (data: Data, width: Int, height: Int, stride: Int)? {
        // Same shape as HuskMetalView: zero-initialise, lock, copy, unlock.
        var info = HuskFrameInfo()
        guard husk_display_lock_frame(&info) else { return nil }
        defer { husk_display_unlock_frame() }

        let w = Int(info.width)
        let h = Int(info.height)
        let s = Int(info.stride)
        guard w > 0, h > 0, let p = info.pixels else { return nil }

        // Data(bytes:count:) copies, so releasing the lock in `defer` is safe.
        return (Data(UnsafeRawBufferPointer(start: p, count: s * h)), w, h, s)
    }

    func latestSequence() -> UInt64 { husk_display_sequence() }
}
