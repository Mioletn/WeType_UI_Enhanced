// SPDX-License-Identifier: GPL-2.0-or-later
//
// iOS 12.2 shims for APIs the app was written against.
//
// The deployment target is 12.2 (AltStore's floor, and the point of the
// backport), but most of this code was written for iOS 15. Where a newer API
// has an older primitive underneath that behaves identically, it is wrapped
// here under a `husk` name and the call sites use that name, rather than the
// code being rewritten to the old spelling everywhere. The distinction matters
// for FileHandle in particular: `readData(ofLength:)` returns an empty Data at
// end of file where `read(upToCount:)` returns nil, and a mechanical rename
// would quietly turn every EOF check into "false".

import Foundation
import UIKit
import CommonCrypto

// MARK: - FileHandle (iOS 13 / 13.4 APIs over the iOS 2 primitives)

extension FileHandle {
    /// `read(upToCount:)`, iOS 13.4+. Yields nil at end of file, which is what
    /// every caller here tests for.
    func huskRead(upToCount count: Int) throws -> Data? {
        let data = readData(ofLength: count)
        return data.isEmpty ? nil : data
    }

    /// `close()`, iOS 13+. The old call cannot report an error; FileHandle logs
    /// it itself.
    func huskClose() throws {
        closeFile()
    }

    /// `seek(toOffset:)`, iOS 13+.
    func huskSeek(toOffset offset: UInt64) throws {
        seek(toFileOffset: offset)
    }

    /// `seekToEnd()`, iOS 13.4+.
    @discardableResult
    func huskSeekToEnd() throws -> UInt64 {
        seekToEndOfFile()
    }

    /// `write(contentsOf:)`, iOS 13.4+.
    func huskWrite(contentsOf data: Data) throws {
        write(data)
    }
}

// MARK: - Fonts

/// Where the extra (CJK) fonts live. `CJKFonts` is an iOS 15 ObservableObject because
/// it is the download UI, but the path is just Application Support; the native
/// runtime asks for it directly and has to do so on 12.2 as well.
enum HuskFonts {
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fonts", isDirectory: true)
    }
}

/// Stands in for `UIFont.monospacedSystemFont(ofSize:weight:)`, which is iOS
/// 13+. Menlo ships on every iOS 12 device, so the only thing lost is the system
/// UI font's exact metrics; the fallback keeps the app readable rather than
/// failing to build.
func huskMonospacedFont(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
    let bold: Bool
    switch weight {
    case .bold, .semibold, .heavy, .black:
        bold = true
    default:
        bold = false
    }
    if let menlo = UIFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: size) {
        return menlo
    }
    return UIFont.systemFont(ofSize: size, weight: weight)
}

// MARK: - SHA-256

/// CryptoKit's `SHA256` is iOS 13+. This is the same digest one layer down
/// (CommonCrypto, present since iOS 5), with the two calls the app makes:
/// streaming `update(data:)` and `finalize()`, the latter matching CryptoKit's
/// `[UInt8]` so the hex formatting at the call site is unchanged.
final class HuskSHA256 {
    private var context = CC_SHA256_CTX()

    init() {
        CC_SHA256_Init(&context)
    }

    func update(data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            // Chunks are a few megabytes, so the CC_LONG conversion is exact.
            _ = CC_SHA256_Update(&context, base, CC_LONG(buffer.count))
        }
    }

    func finalize() -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = CC_SHA256_Final(&digest, &context)
        return digest
    }
}
