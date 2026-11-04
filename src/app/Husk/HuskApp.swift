// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// Which way the app may turn. The app follows the device, except while a landscape game is on screen:
/// Geometry Dash is a landscape game, and a fixed-size surface cannot follow a rotation.
enum HuskOrientation {
    static var standard: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : [.portrait, .landscapeLeft, .landscapeRight]
    }
    static var mask: UIInterfaceOrientationMask = standard

    /// Allow only `new`, and turn the screen to it if it is not already there.
    ///
    /// A game's screen asks as it appears, while its full-screen cover is still being presented, and iOS can refuse then
    /// ("Supported: portrait") because it has not yet asked the cover what it allows. So a refusal is retried a few times,
    /// a moment apart, for as long as `new` is still what is wanted.
    static func set(_ new: UIInterfaceOrientationMask, attempt: Int = 0) {
        mask = new
        guard #available(iOS 16, *) else {
            // iOS 15 and earlier ask the view controllers again when the device turns; nudge it to ask now.
            // The nudge is refused while the view controller that wants it is still being presented -- it has not
            // been asked what it allows yet -- so it is retried for as long as `new` is still what is wanted, the
            // same way the 16 path is. Without this a portrait app opens in whatever way the device happens to
            // be held, and the engine is told that size once, for good.
            UIViewController.attemptRotationToDeviceOrientation()
            guard attempt < 5 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if mask == new { set(new, attempt: attempt + 1) }
            }
            return
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            var vc = scene.keyWindow?.rootViewController
            while let v = vc { v.setNeedsUpdateOfSupportedInterfaceOrientations(); vc = v.presentedViewController }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: new)) { error in
                HuskLog.log("ui", "orientation change refused (attempt \(attempt + 1)): \(error.localizedDescription)")
                guard attempt < 5 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if mask == new { set(new, attempt: attempt + 1) }
                }
            }
        }
    }
}

/// Husk's entry point, and the heart of the iOS 12.2 backport.
///
/// Upstream this app is a SwiftUI `App` (`@main`), which needs iOS 14. The
/// deployment target is 12.2, where SwiftUI does not exist at all, so the
/// binary has a UIKit entry point instead: this delegate. On iOS 15 and later
/// it hosts the original SwiftUI interface in a `UIHostingController`, which is
/// what `App`'s WindowGroup did -- minus scene-based multi-window, a trade the
/// backport makes knowingly (iOS 12 never had it, and one IPA has to serve
/// both). On iOS 12.2 through 14.4 it shows `LegacyRootViewController`, the
/// UIKit shell in `src/app/LegacyUI`, and none of the SwiftUI code is ever
/// touched.
@UIApplicationMain
final class HuskAppDelegate: NSObject, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        HuskOrientation.mask
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Order matters. HuskLog redirects stderr, so anything that logs before
        // this point is lost -- and the JIT path is exactly what we cannot afford
        // to lose the first line of.
        HuskLog.start()
        HuskLog.logFootprint("app-launch")
        // Before anything asks a debugger for anything: was this process already marked as debugged (a jailbreak that allows JIT in apps)?
        JITBootstrap.noteLaunchState()
        HuskLog.log("jit", "debugged at launch: \(JITBootstrap.debuggedAtLaunch); TrollStore install: \(JITBootstrap.isInstalledWithTrollStore); jailbreak: \(JITBootstrap.isJailbroken); can grant its own JIT: \(JITBootstrap.canGrantOwnJIT)")

        // Then the trap guard: without it, any brk we issue when StikDebug is
        // absent kills the process outright rather than returning an error.
        JITBootstrap.installTrapGuard()

        // Android no longer starts by itself unless someone turns that on: once, for everyone who had it from the old default.
        let d = UserDefaults.standard
        if !d.bool(forKey: "husk.autoStart.offByDefault") {
            d.set(false, forKey: "husk.autoStart")
            d.set(true, forKey: "husk.autoStart.offByDefault")
        }
        // Copies of shared APKs that were never placed. (IncomingFiles is Combine,
        // so it is iOS 15+; the C side's leftovers are cleared on both.)
        if #available(iOS 15.0, *) {
            IncomingFiles.clearLeftovers()
            // Game controllers, for the games the native runtime runs.
            HuskGamepads.shared.start()
        }

        window = UIWindow(frame: UIScreen.main.bounds)
        if #available(iOS 15.0, *) {
            // The SwiftUI interface, exactly as upstream ships it.
            HuskLog.log("ui", "iOS 15+: hosting the SwiftUI interface")
            FilePickerFix.installIfAvailable()
            window?.rootViewController = UIHostingController(rootView: ContentView())
        } else {
            // iOS 12.2: the UIKit legacy shell. No SwiftUI is referenced from
            // here on down -- see src/app/LegacyUI.
            HuskLog.log("ui", "iOS 12: showing the UIKit legacy shell")
            window?.rootViewController = LegacyRootViewController()
        }
        window?.makeKeyAndVisible()

        // The download session reconnects to whatever was running before Husk was closed or relaunched in the background.
        if #available(iOS 15.0, *) { _ = Downloads.shared }
        return true
    }

    /// husk://open_app?unique_identifier=<id>: an app-clip icon on the Home Screen opened a game.
    ///
    /// On iOS 15 and later SwiftUI's `.onOpenURL` answers this (AppClip.handle, which drives the router). The legacy shell has no
    /// router, so on iOS 12.2-14.4 the game's Home Screen icon opens Husk on its library instead -- the app still launches, which
    /// is the part the profile installation depends on.
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard #available(iOS 15.0, *) else {
            return LegacyDeepLink.handle(url)
        }
        return AppClip.handle(url)
    }

    /// iOS woke Husk because background downloads finished or need attention: handle them, then say so.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard #available(iOS 15.0, *) else { completionHandler(); return }
        guard identifier == Downloads.sessionID else { completionHandler(); return }
        HuskLog.log("downloads", "woken for background download events")
        Downloads.shared.backgroundCompletion = completionHandler
    }
}
