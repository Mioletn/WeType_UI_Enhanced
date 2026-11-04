// SPDX-License-Identifier: GPL-2.0-or-later
//
// The guest's serial console, as a Unix-domain socket.
//
// QEMU is started with
//     -chardev socket,id=ser0,path=<tmp>/husk-serial.sock,server=on,wait=off
//     -serial chardev:ser0
// so the guest's ttyAMA0 is a byte stream we can read and write.
//
// Why the serial port and not QEMU's keyboard: husk_display_send_key() feeds the
// virtio-keyboard device, whose events arrive in the guest as evdev events. A
// Linux virtual terminal only takes keys from legacy keyboard drivers (atkbd),
// so no amount of sendkey reaches a VT -- that path exists for Android, which
// reads evdev itself. Writing bytes to the serial chardev is what `qemu
// -nographic` does, it needs nothing from the guest's input stack, and it makes
// Ctrl-C, backspace and paste behave like a real terminal.
//
// The app mirrors everything the guest prints into a log file, so the existing
// in-app log viewer keeps working unchanged.
import Foundation
import Darwin

final class LegacySerialLink {

    let socketPath: String
    let logPath: String

    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private var readerThread: Thread?

    init(socketPath: String, logPath: String) {
        self.socketPath = socketPath
        self.logPath = logPath
    }

    var isConnected: Bool { fd >= 0 }

    /// QEMU creates the listening socket during qemu_init, so this is normally
    /// immediate; the retry loop only covers the few milliseconds before that.
    @discardableResult
    func connect(timeout: TimeInterval = 6.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if connectOnce() { return true }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return false
    }

    private func connectOnce() -> Bool {
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count + 1 <= capacity else {
            Darwin.close(s)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
            raw[pathBytes.count] = 0
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(s, sa, len)
            }
        }
        if rc != 0 {
            Darwin.close(s)
            return false
        }
        fd = s
        HuskLog.log("emu", "serial socket connected")
        return true
    }

    /// Raw bytes to the guest. Safe from any thread.
    func write(bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard fd >= 0 else { return }

        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf -> Int in
                Darwin.write(fd, buf.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if n <= 0 { break }
            sent += n
        }
    }

    /// Text to the guest. A terminal sends CR for Enter, not LF; the serial line
    /// discipline turns CR back into a newline for the shell.
    func write(text: String) {
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        write(bytes: Array(normalised.utf8))
    }

    /// Append everything the guest prints to `logPath`, and keep doing it for the
    /// life of the connection.
    func startMirroringToLog() {
        guard readerThread == nil, fd >= 0 else { return }

        if !FileManager.default.fileExists(atPath: logPath) {
            _ = FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: logPath) else {
            HuskLog.log("emu", "serial mirror: cannot open \(logPath)")
            return
        }
        fh.seekToEndOfFile()

        let t = Thread { [weak self] in
            guard let self = self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            while self.fd >= 0 {
                let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                    Darwin.read(self.fd, p.baseAddress, p.count)
                }
                if n > 0 {
                    fh.write(Data(buf[0..<n]))
                    fh.synchronizeFile()
                } else {
                    // 0 = guest closed, <0 = error. Either way, stop.
                    break
                }
            }
            // closeFile(), not close(): FileHandle.close() is iOS 13+.
            fh.closeFile()
            HuskLog.log("emu", "serial mirror stopped")
        }
        t.name = "husk.emu.serial"
        t.qualityOfService = .userInitiated
        t.stackSize = 1 << 20
        readerThread = t
        t.start()
    }
}
