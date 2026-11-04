// SPDX-License-Identifier: GPL-2.0-or-later
//
// APK ingestion for the iOS 12.2 shell.
//
// Upstream's pipeline lives in TranslationLayerStore, which is iOS 15+ (Combine,
// the main actor) even though the work itself is C behind husk_tl_*. The shell
// therefore carries its own copy of the same steps, writing the same files into
// the same folder layout: exactly what LegacyStore already does for reading
// (LegacyStore.loadApp mirrors TranslationLayerStore.load for the same reason).
// That keeps the iOS 15 path untouched and gives 12.2 the same library entries,
// labels and icons.
//
// One deliberate difference: an adaptive icon is an XML description that
// upstream composes into a PNG, and that composition needs the resource table
// walker in ApkMetadata's icon path. Here an XML icon is skipped and every app
// that ships one also ships the flat bitmap older launchers use, so the fallback
// is the bitmap rather than nothing.

import Foundation
import UIKit

enum LegacyIngest {
    /// Where the scan version is recorded. Must match
    /// TranslationLayerStore.scanVersion: a folder written here has to look
    /// freshly scanned to the iOS 15 store if the same library is ever opened on
    /// a newer system, or it would be re-scanned for nothing.
    private static let scanVersion = 8

    /// What an import produced. A refusal carries the words for the banner: an
    /// .apk that is not an Android package (an .ipa picked by mistake, a renamed
    /// zip of something else) has to say so, because the alternative is a
    /// library row that can only ever fail to run -- the pixel loader finds no
    /// arm64 libraries, falls through to the DEX path, finds no DEX, and reports
    /// "could not execute" with no hint as to why.
    enum Outcome {
        case added(id: String)
        case refused(reason: String)
    }

    /// Copy APKs (or bundle files) in, describe them, and report what happened.
    /// Synthesised work: nothing here blocks a caller's thread beyond the file
    /// copy, so callers run it off the main queue.
    static func copy(_ urls: [URL]) -> Outcome {
        let fm = FileManager.default
        let root = TranslationLayer.root
        guard !urls.isEmpty else { return .refused(reason: "Nothing was picked.") }

        // An .ipa is the mistake worth catching before a byte is copied: "add"
        // gets handed one whenever someone means to add the app they are already
        // holding, and it is as big as a game, so finding out afterwards costs a
        // minute of their time for nothing. Only the name can be judged here;
        // what the file holds is judged below, after the copy.
        for url in urls where Self.iosOnlyExtensions.contains(url.pathExtension.lowercased()) {
            HuskLog.log("tl", "refused \(url.lastPathComponent): an .ipa is an iOS app, "
                              + "not an Android package")
            return .refused(reason: "“\(url.lastPathComponent)” is an iOS app — Husk runs "
                                  + "Android apps. Add an .apk, .xapk, .apkm or .apks.")
        }

        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for url in urls {
                // Security-scoped: the picker's URL is only readable inside this pair.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                if BundleUnpacker.extensions.contains(url.pathExtension.lowercased()) {
                    let names = try BundleUnpacker.unpack(url, into: dir)
                    HuskLog.log("tl", "unpacked \(url.lastPathComponent): \(names.joined(separator: ", "))")
                    continue
                }

                // Copied under the name it arrived with. Whether it is an APK is
                // decided from its contents below, and only then does it get the
                // extension -- a name alone proves nothing either way.
                let name = url.lastPathComponent
                // An expansion file goes to obb/ under its own name: the runtime
                // finds it there when the game asks for Android/obb/<package>/<name>.
                let isOBB = name.lowercased().hasSuffix(".obb")
                let dest: URL
                if isOBB {
                    let obb = dir.appendingPathComponent("obb", isDirectory: true)
                    try fm.createDirectory(at: obb, withIntermediateDirectories: true)
                    dest = obb.appendingPathComponent(name)
                } else {
                    dest = dir.appendingPathComponent(name)
                }
                // Coordinated, so a file that lives in iCloud and is not on the
                // phone yet is downloaded first.
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                    do { try fm.copyItem(at: readable, to: dest) } catch { copyError = error }
                }
                if let failure = coordinationError ?? copyError { throw failure }
            }
        } catch {
            try? fm.removeItem(at: dir)
            HuskLog.log("tl", "FAILED to add: \(error.localizedDescription)")
            return .refused(reason: "Husk could not copy it: \(error.localizedDescription)")
        }

        // Everything loose at the top of the folder is a candidate. obb/ is not,
        // and neither are the hidden files the system leaves behind.
        let loose = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: dir.appendingPathComponent(name).path,
                                       isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
        guard !loose.isEmpty else {
            try? fm.removeItem(at: dir)
            HuskLog.log("tl", "nothing to install: no APK inside what was picked")
            return .refused(reason: "That file is not an Android app: it holds no APK.")
        }

        // Every Android package has AndroidManifest.xml at the root of the zip,
        // and nothing else does. Checking here is what keeps an .ipa -- or any
        // other archive someone renamed -- out of the library, where its row
        // could only ever fail to run: the loader finds no arm64 libraries, falls
        // through to the DEX path, finds no DEX, and reports "could not execute"
        // with no hint as to why.
        var packages: [String] = []
        for name in loose {
            let path = dir.appendingPathComponent(name).path
            guard isAndroidPackage(path) else {
                try? fm.removeItem(at: dir)
                let why = refusal(for: path, named: name)
                HuskLog.log("tl", "refused \(name): no AndroidManifest.xml inside — \(why)")
                return .refused(reason: why)
            }
            // A packer's native library is the one thing an APK cannot hide: the
            // DEX files it ships are a shell, and the real classes are decrypted
            // into memory at run time by that library. The runtime reads the DEX
            // files as they are on disk, so such an app can never start -- it
            // gets as far as a class whose name is not text and dies there.
            // Saying why at import costs one central-directory read; the
            // alternative is the user reading a crash log to learn it.
            if let packer = packerLibrary(in: path) {
                try? fm.removeItem(at: dir)
                HuskLog.log("tl", "refused \(name): packed (\(packer))")
                return .refused(reason: "“\(name)” is a packed app (\(packer)): its code is encrypted "
                                      + "and decrypted only at run time, so Husk's Java engine has nothing "
                                      + "to read. A build of the same app that is not packed runs.")
            }
            packages.append(adopt(path, name, in: dir, fm: fm))
        }

        // Same order the runtime takes them in: the app first, then what it
        // cannot run without, then the splits it does not need.
        let apks = packages
            .sorted { a, b in
                let ra = BundleUnpacker.rank(a, siblings: packages)
                let rb = BundleUnpacker.rank(b, siblings: packages)
                return ra != rb ? ra < rb : a < b
            }
            .map { dir.appendingPathComponent($0).path }

        describe(apks, into: dir)
        let json = scan(apks)
        try? Data(json.utf8).write(to: dir.appendingPathComponent("report.json"))
        try? "\(scanVersion)".write(to: dir.appendingPathComponent("scan-version.txt"),
                                     atomically: true, encoding: .utf8)
        HuskLog.log("tl", "installed \(dir.lastPathComponent) (\(packages.count) apk)")

        return .added(id: dir.lastPathComponent)
    }

    // MARK: judging what was picked

    /// Extensions that only ever name an iOS app. Judged from the name alone,
    /// before the copy, because the file is big and the answer cannot change.
    private static let iosOnlyExtensions: Set<String> = ["ipa", "tipa", "app"]

    /// Whether the file is an Android package: a zip with a manifest at its root.
    /// Reads the central directory and nothing else, so this is cheap.
    private static func isAndroidPackage(_ path: String) -> Bool {
        husk_tl_has_entry(path, "AndroidManifest.xml") != 0
    }

    /// Give a validated package the name the rest of Husk looks for. The runtime
    /// and LegacyStore both walk the folder for *.apk, so a file that arrived
    /// under another name (a picker can hand back "update.bin") keeps its bytes
    /// and gains the extension.
    private static func adopt(_ path: String, _ name: String, in dir: URL,
                              fm: FileManager) -> String {
        guard !name.lowercased().hasSuffix(".apk") else { return name }
        let renamed = name + ".apk"
        do {
            try fm.moveItem(atPath: path, toPath: dir.appendingPathComponent(renamed).path)
            return renamed
        } catch {
            // Still a valid package; it just keeps its name. The scan below
            // looks for the manifest, not for the extension.
            HuskLog.log("tl", "could not rename \(name): \(error.localizedDescription)")
            return name
        }
    }

    /// Why a file that was picked is not an Android package, in words for the
    /// banner. Cheap checks first: the name, then the first bytes, then the zip.
    private static func refusal(for path: String, named name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if iosOnlyExtensions.contains(ext) {
            return "“\(name)” is an iOS app — Husk runs Android apps."
        }
        if isMachO(path) {
            return "“\(name)” is a bare iOS executable (Mach-O) — Husk runs Android apps."
        }
        if let entries = BundleUnpacker.entryNames(in: URL(fileURLWithPath: path)) {
            // An .ipa is a zip whose contents sit under Payload/<name>.app.
            // Renaming it does not change that, so the shape still gives it away.
            let lower = entries.map { $0.lowercased() }
            if lower.contains(where: { $0.hasPrefix("payload/") })
                || lower.contains(where: { $0.hasSuffix(".app/info.plist") }) {
                return "“\(name)” holds an iOS app (Payload/…app) — Husk runs Android apps."
            }
            return "“\(name)” is a zip, but not an Android package: "
                 + "it has no AndroidManifest.xml."
        }
        return "“\(name)” is not an APK: it is not even a zip archive."
    }

    /// The native libraries that Android packers ("加固") ship, by the names they
    /// use once the "lib" prefix and ".so" suffix are off. Prefixes, because
    /// several versions carry a number in the name (libshella-2.10.5.so). None
    /// of these is a library an ordinary app links against: a match is the
    /// packer, not a coincidence.
    private static let packerLibraries = ["protect", "jiagu", "shella", "shell", "secexe", "secmain",
                                          "secshell", "exec", "execmain", "sgmain", "sgsecuritybody",
                                          "mobisec", "tup", "nesec", "dexhelper", "baiduprotect",
                                          "kwscmm", "chaosvmp", "nqshield", "tprt", "dd", "demolish"]

    /// The packer library inside an APK, if it has one.
    private static func packerLibrary(in path: String) -> String? {
        guard let entries = BundleUnpacker.entryNames(in: URL(fileURLWithPath: path)) else { return nil }
        for entry in entries {
            let lower = entry.lowercased()
            guard lower.hasPrefix("lib/"), lower.hasSuffix(".so") else { continue }
            guard let slash = lower.lastIndex(of: "/") else { continue }
            let base = String(lower[lower.index(after: slash)...])
            guard base.hasPrefix("lib"), base.count > 6 else { continue }
            let stem = String(base.dropFirst(3).dropLast(3))        // "libprotect.so" -> "protect"
            if packerLibraries.contains(where: { stem.hasPrefix($0) }) {
                return (entry as NSString).lastPathComponent
            }
        }
        return nil
    }

    /// Whether the file starts with a Mach-O magic number, which is what an iOS
    /// binary -- or a bare executable pulled out of an .ipa -- looks like.
    private static func isMachO(_ path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        defer { try? handle.huskClose() }
        guard let head = try? handle.huskRead(upToCount: 4), head.count == 4 else { return false }
        let magic = head.map { String(format: "%02x", Int($0)) }.joined()
        // arm64 / armv7 and their big-endian twins, then the fat (universal) ones.
        return ["cffaedfe", "cefaedfe", "feedfacf", "feedface",
                "cafebabe", "bebafeca"].contains(magic)
    }

    // MARK: metadata

    /// Label, package name and icon, written into the app's folder.
    private static func describe(_ apks: [String], into dir: URL) {
        // The base APK carries the label and the icon; a config split's manifest
        // names neither. The base is usually called base.apk, and otherwise
        // usually the biggest.
        func size(_ path: String) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?
                .intValue ?? 0
        }
        let ordered = apks.sorted { a, b in
            let aBase = (a as NSString).lastPathComponent == "base.apk"
            let bBase = (b as NSString).lastPathComponent == "base.apk"
            return aBase != bBase ? aBase : size(a) > size(b)
        }

        for apk in ordered {
            guard let manifest = entry(apk, "AndroidManifest.xml", limit: 8 << 20),
                  let arsc = entry(apk, "resources.arsc", limit: 64 << 20) else { continue }
            let info = ApkMetadata.read(manifest: manifest, resources: arsc)
            guard info.label != nil || info.iconEntry != nil else { continue }

            if let package = ApkMetadata.packageName(manifest) {
                try? package.write(to: dir.appendingPathComponent("package.txt"),
                                   atomically: true, encoding: .utf8)
            }
            if let label = info.label {
                try? label.write(to: dir.appendingPathComponent("label.txt"),
                                 atomically: true, encoding: .utf8)
            }
            // Stored as PNG whatever it was, so the icon view needs no WebP.
            // An adaptive icon is XML and is skipped (see the file header).
            if let iconEntry = info.iconEntry, !iconEntry.hasSuffix(".xml"),
               let data = entry(apk, iconEntry, limit: 16 << 20),
               let png = UIImage(data: data)?.pngData() {
                try? png.write(to: dir.appendingPathComponent("icon.png"))
            }
            HuskLog.log("tl", "\((apk as NSString).lastPathComponent): "
                            + "label=\(info.label ?? "?") icon=\(info.iconEntry ?? "-")")
        }
    }

    /// One entry out of an APK (a zip), by name.
    private static func entry(_ apk: String, _ name: String, limit: Int) -> Data? {
        var length = 0
        guard let bytes = husk_tl_read_entry(apk, name, limit, &length) else { return nil }
        defer { husk_tl_free(bytes) }
        return Data(bytes: bytes, count: length)
    }

    /// The report `LegacyStore` displays: the same JSON the iOS 15 store writes.
    private static func scan(_ paths: [String]) -> String {
        let owned = paths.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        let pointers = owned.map { UnsafePointer<CChar>($0) }
        let raw = pointers.withUnsafeBufferPointer {
            husk_tl_scan($0.baseAddress, Int32($0.count))
        }
        defer { husk_tl_free(raw) }
        return raw.map { String(cString: $0) } ?? "{}"
    }
}
