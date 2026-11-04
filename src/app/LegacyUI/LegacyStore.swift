// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's model layer.
//
// Upstream's TranslationLayerStore is an ObservableObject on the main actor
// (Combine + Swift concurrency, iOS 13+), which iOS 12 cannot run. The shell
// therefore keeps its own tiny store: the same on-disk layout, read the same
// way, without any of the reactive machinery. TLApp, TLReport and the install
// pipeline (LegacyIngest) are shared with upstream unchanged.
import Foundation
import UIKit

final class LegacyStore {
    static let shared = LegacyStore()

    private(set) var apps: [TLApp] = []

    private init() {}

    // MARK: reading

    func reload() {
        let dirs: [URL]
        do {
            dirs = try FileManager.default.contentsOfDirectory(
                at: TranslationLayer.root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        } catch {
            dirs = []
        }
        apps = dirs.compactMap(Self.loadApp).sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    /// Mirrors TranslationLayerStore.load: the same folder layout, the same
    /// base-APK-first ordering, the same report.json decoding.
    private static func loadApp(dir: URL) -> TLApp? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        // A folder can also be filled by dropping a file into Husk's folder in
        // the Files app, which skips the import's own checks. A package with no
        // AndroidManifest.xml is not an Android app -- a build that filed an .ipa
        // here left exactly such a row -- and offering it would only ever end in
        // "could not execute", so it is left out of the list.
        let names = files.filter { $0.lowercased().hasSuffix(".apk") }
        let usable = names.filter {
            husk_tl_has_entry(dir.appendingPathComponent($0).path,
                              "AndroidManifest.xml") != 0
        }
        if usable.isEmpty, !names.isEmpty {
            // Worth a line: the folder stays on disk (58 MB of it, for an .ipa)
            // and nothing else would explain why it is not in the library.
            HuskLog.log("tl", "legacy: hiding \(dir.lastPathComponent): it holds no Android "
                              + "package (\(names.joined(separator: ", ")))")
            return nil
        }
        let apks = usable
            .sorted { a, b in
                let ra = BundleUnpacker.rank(a, siblings: names)
                let rb = BundleUnpacker.rank(b, siblings: names)
                return ra != rb ? ra < rb : a < b
            }
            .map { dir.appendingPathComponent($0).path }
        guard let first = apks.first else { return nil }

        let saved = try? String(contentsOf: dir.appendingPathComponent("label.txt"),
                                encoding: .utf8)
        let label = saved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let icon = dir.appendingPathComponent("icon.png").path
        let report = (try? Data(contentsOf: dir.appendingPathComponent("report.json")))
            .flatMap { try? JSONDecoder().decode(TLReport.self, from: $0) }
        let played = (try? String(contentsOf: dir.appendingPathComponent("last-played.txt"),
                                  encoding: .utf8))
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map { Date(timeIntervalSince1970: $0) }
        return TLApp(id: dir.lastPathComponent,
                     label: label.isEmpty ? (first as NSString).lastPathComponent : label,
                     iconPath: fm.fileExists(atPath: icon) ? icon : nil,
                     apks: apks, report: report, lastPlayed: played,
                     packageName: (try? String(contentsOf: dir.appendingPathComponent("package.txt"),
                                               encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: writing

    /// Copy APKs in and reload. Runs off the main thread: the copy is the slow
    /// part, and the shell has no reactive machinery to keep the UI honest
    /// meanwhile, so it simply comes back when it is done. The outcome carries
    /// the reason when nothing was added, which is what the banner shows.
    func importAPKs(_ urls: [URL], completion: @escaping (LegacyIngest.Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = LegacyIngest.copy(urls)
            DispatchQueue.main.async {
                self.reload()
                completion(outcome)
            }
        }
    }

    func remove(_ app: TLApp) {
        let dir = TranslationLayer.root.appendingPathComponent(app.id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        HuskLog.log("tl", "legacy: removed \(app.label)")
        reload()
    }

    func markPlayed(_ app: TLApp) {
        let dir = TranslationLayer.root.appendingPathComponent(app.id, isDirectory: true)
        try? String(Int(Date().timeIntervalSince1970).description)
            .write(to: dir.appendingPathComponent("last-played.txt"),
                   atomically: true, encoding: .utf8)
    }

    // MARK: what this iOS can run

    /// Whether this build carries the Java runtime payload (build/java-runtime,
    /// which scripts/build_java_runtime.sh produces and package_ipa.sh copies
    /// into the app). CI does not build it, so a Java app here has no boot class
    /// path to start from: every jar is missing, and the attempt ends in
    /// "no java/lang/Object on the boot class path". Checked once, at first use,
    /// because the answer is a property of the bundle on disk.
    static let shipsJavaRuntime: Bool = {
        FileManager.default.fileExists(
            atPath: (Bundle.main.resourcePath ?? "")
                + "/java-runtime/com.android.art/javalib/core-oj.jar")
    }()

    /// Whether the app runs on the iOS 12 path at all.
    ///
    /// The native runtime (Unity, cocos2d-x, Minecraft, SDL, Unreal, Godot,
    /// GTA, GameMaker, Flutter) presents into a CAMetalLayer. That layer is
    /// iOS 8, and it is handed straight to the ANGLE build this app carries, so
    /// the runtime runs here -- this used to say iOS 13 and it was wrong: 13 is
    /// where the SwiftUI screens around it start, not the layer. Web apps are
    /// the ones that cannot run: the bridge they talk to lives in the iOS 15 UI
    /// layer.
    func canRunOnThisiOS(_ app: TLApp) -> Bool {
        unavailableReason(app) == nil
    }

    /// Why it cannot run here, in words for the library cell.
    func unavailableReason(_ app: TLApp) -> String? {
        if app.report?.webKind != nil {
            return "Needs iOS 15 (web apps run on the WKWebView bridge)"
        }
        // An app with no native libraries at all runs on the Java runtime, and
        // this build has none -- see shipsJavaRuntime.
        if app.report?.nativeEngine == .java, !Self.shipsJavaRuntime {
            return "Needs the Java runtime, which this build does not include"
        }
        return nil
    }

    func icon(for app: TLApp) -> UIImage? {
        guard let path = app.iconPath else { return nil }
        return UIImage(contentsOfFile: path)
    }
}
