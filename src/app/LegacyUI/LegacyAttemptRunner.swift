// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's game runner.
//
// A DispatchQueue twin of upstream's TLAttemptRunner, which is an
// @MainActor ObservableObject (iOS 13+). Same C entry points
// (husk-tl-attempt-*), same semantics: one run at a time, a 10 Hz poll for the
// status line, and the frames themselves published by the C side for
// TLScreenUIView to pick up on its own display link.
import Foundation
import UIKit

final class LegacyAttemptRunner {
    static let shared = LegacyAttemptRunner()

    private(set) var isRunning = false
    private(set) var isDone = false
    private(set) var exitCode: Int?
    private(set) var frameCount = 0

    /// Called on the main thread whenever anything above changes.
    var onChange: (() -> Void)?

    private var pollTimer: DispatchSourceTimer?

    private init() {}

    deinit { pollTimer?.cancel() }

    /// `seconds` of 0 is no limit: the run goes on until it is stopped, exactly
    /// as upstream's attempt runner.
    func start(apks: [String]) {
        guard !isRunning else { return }
        isRunning = true
        isDone = false
        exitCode = nil
        frameCount = 0
        onChange?()

        DispatchQueue.global(qos: .userInitiated).async {
            let owned = apks.map { strdup($0) }
            defer { owned.forEach { free($0) } }
            let pointers = owned.map { UnsafePointer<CChar>($0) }
            let rc = pointers.withUnsafeBufferPointer {
                husk_tl_attempt_start($0.baseAddress, Int32($0.count), Int32(0))
            }
            DispatchQueue.main.async {
                if rc != 0 {
                    self.isRunning = false
                    self.isDone = true
                    self.exitCode = -1
                    self.onChange?()
                    return
                }
                self.startPolling()
            }
        }
    }

    func stop() {
        husk_tl_attempt_stop()
        poll()
    }

    private func startPolling() {
        pollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        pollTimer = t
    }

    private func poll() {
        let n = Int(husk_tl_attempt_frames())
        if n != frameCount { frameCount = n }
        var code: Int32 = 0
        if husk_tl_attempt_done(&code) {
            pollTimer?.cancel()
            pollTimer = nil
            isRunning = false
            isDone = true
            exitCode = Int(code)
            onChange?()
        }
    }

    /// The run's own log, as the C side has it (caller frees).
    var logText: String? {
        guard let cLog = husk_tl_attempt_log() else { return nil }
        defer { free(cLog) }
        return String(cString: cLog)
    }

    var statusText: String {
        if isRunning { return "Running" }
        guard let code = exitCode else { return "Not started" }
        switch code {
        case 2:  return "Finished — \(frameCount) frame(s) drawn"
        case 1:  return "Loaded — libraries loaded, no draw"
        default: return "Refused — could not execute"
        }
    }
}
