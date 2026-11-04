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

    /// True once qemu_init() has returned, i.e. QEMU's locks and console exist.
    /// Nothing may call into QEMU before this point: bql_lock() on an
    /// uninitialised mutex aborts the process. Input and the frame pump check
    /// this, not isRunning, because isRunning is set the moment the thread
    /// starts -- which is *before* qemu_init runs.
    private(set) var qemuReady = false

    /// Where the guest's serial console output is mirrored. The VC tails this
    /// file, so it is the in-app terminal view as well as the on-disk record.
    let serialLogPath: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                       .userDomainMask, true)[0]
        return (docs as NSString).appendingPathComponent("husk-phase0-serial.log")
    }()

    /// The guest console as a byte stream. Kept in NSTemporaryDirectory() rather
    /// than Documents because a Unix socket path must fit in sun_path (104 bytes
    /// on Darwin) and the app's container path alone is already ~75.
    let serialSocketPath: String = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("husk-serial.sock")

    private lazy var serial = LegacySerialLink(socketPath: serialSocketPath,
                                               logPath: serialLogPath)

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

        // 3. Run QEMU on its own thread (it never returns until the guest halts).
        //    The software display listener is registered inside runQEMU, after
        //    qemu_init(): console 0 does not exist before then, and touching
        //    QEMU's locks earlier aborts on an uninitialised BQL mutex.
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
            // ttyAMA0 is listed LAST on purpose: the kernel binds /dev/console to
            // the last console= given, so the shell runs on the serial port --
            // the one channel we can feed input into. printk still goes to tty0
            // as well, so boot messages also appear on the framebuffer.
            "-append", "console=tty0 console=ttyAMA0 loglevel=8",

            // No network needed for Phase 0; dropping the default virtio-net-pci
            // avoids a missing-ROM aborts we have already hit once.
            "-nic", "none",
            "-L", "\(bundle)/pc-bios",

            // Graphics + input devices. The software display listens on console 0.
            // The keyboard device is for guests that read evdev themselves
            // (Android); it can never reach a Linux VT -- see LegacySerialLink.
            "-device", "virtio-gpu-pci",
            "-device", "virtio-tablet-pci",
            "-device", "virtio-keyboard-pci",

            // Guest serial console -> Unix socket, so it is bidirectional: the
            // guest's output is mirrored to a log file and our keystrokes are
            // written back as bytes. A plain `file` chardev would be write-only
            // and the console could never be typed into.
            "-chardev", "socket,id=ser0,path=\(serialSocketPath),server=on,wait=off",
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
        HuskLog.log("emu", "qemu_init() returned -- registering the software display")
        qemuReady = true

        // Must happen after qemu_init (the console does not exist before it) and
        // before qemu_main_loop (which does not return). This is the same rule
        // QemuRunner follows in its non-GL path; there is no GL path on 12.2.
        husk_display_init()

        // The socket exists as soon as qemu_init has run. Connect and start
        // mirroring the guest's console into the log file the UI tails.
        if serial.connect() {
            serial.startMirroringToLog()
        } else {
            HuskLog.log("emu", "serial socket \(serialSocketPath) never appeared -- "
                             + "the guest console will not be typable")
        }

        HuskLog.log("emu", "entering qemu_main_loop() -- does not return until shutdown")
        startAutoTypeIfRequested()
        qemu_main_loop()
        HuskLog.log("emu", "qemu_main_loop() RETURNED -- guest stopped")
        qemu_cleanup()
        HuskLog.log("emu", "qemu_cleanup() done")
        qemuReady = false
        isRunning = false
    }

    // MARK: - guest input

    /// Send one QKeyCode press/release by name. False if QEMU is not up yet or
    /// the name is not a QKeyCode.
    @discardableResult
    func sendKey(_ qcode: String, down: Bool) -> Bool {
        guard qemuReady else { return false }
        return husk_display_send_key(qcode, down)
    }

    func tapKey(_ qcode: String) {
        _ = sendKey(qcode, down: true)
        _ = sendKey(qcode, down: false)
    }

    /// Type text into the guest console. The serial console is a byte stream, so
    /// this is a single write rather than a sequence of synthetic key events --
    /// paste works, and so do control characters (0x03 for Ctrl-C, 0x7f for
    /// backspace).
    func typeText(_ text: String) {
        guard qemuReady, serial.isConnected else { return }
        serial.write(text: text)
    }

    /// Type one character into the guest console.
    func typeCharacter(_ ch: Character) {
        typeText(String(ch))
    }

    /// Click at a point in guest pixels. The C side clamps to the console size.
    func sendClick(guestX: Int, guestY: Int) {
        guard qemuReady else { return }
        husk_display_send_pointer(Int32(max(0, guestX)), Int32(max(0, guestY)), true)
        husk_display_send_pointer(Int32(max(0, guestX)), Int32(max(0, guestY)), false)
    }

    /// DEBUG hook: if a file named `emu_autotype` sits in the app bundle, type its
    /// contents into the guest once the guest has had time to reach its shell.
    ///
    /// This exists so the whole input path (QKeyCode resolution -> virtio-keyboard
    /// -> guest VT) can be exercised and proven from a shell on the host, with no
    /// tap on the device. Typing something whose effect lands in printk -- e.g.
    /// `echo ok >/dev/kmsg` -- makes the proof show up in the serial log too.
    /// No-op in normal use.
    private func startAutoTypeIfRequested() {
        let path = Bundle.main.bundlePath + "/emu_autotype"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              !text.isEmpty else { return }

        HuskLog.log("emu", "autotype: \(text.count) chars queued from \(path)")
        let t = Thread { [weak self] in
            // The guest reached its emergency shell at ~8.3 s on this device;
            // wait well past that so the shell is certainly reading.
            Thread.sleep(forTimeInterval: 16)
            self?.typeText(text)
            // Write it a second time in case the first landed before the line
            // discipline was live. The proof command is idempotent.
            Thread.sleep(forTimeInterval: 6)
            self?.typeText(text)
            HuskLog.log("emu", "autotype: done")
        }
        t.name = "husk.emu.autotype"
        t.qualityOfService = .userInitiated
        t.stackSize = 1 << 20
        t.start()
    }

    // MARK: - frame pump (called by the view controller on a timer)

    /// Pull the latest guest frame, or nil if the display has nothing yet.
    ///
    /// Returns the raw framebuffer bytes (32bpp, what virtio-gpu gives and what
    /// Metal wants), plus width/height/stride, so the caller can build a CGImage.
    func grabFrame() -> (data: Data, width: Int, height: Int, stride: Int)? {
        // Nothing in QEMU may be touched before qemu_init() has returned.
        guard qemuReady else { return nil }
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
