// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's Library: the games Husk can run here, how to add more,
// and what it cannot run. A plain UITableView over LegacyStore -- no diffable
// data sources (iOS 13+), no Combine.
import UIKit

final class LegacyLibraryViewController: UIViewController {
    private let table = UITableView(frame: .zero, style: .plain)
    private var store: LegacyStore { LegacyStore.shared }
    private var emptyLabel: UILabel?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = LegacyUI.background

        table.backgroundColor = .clear
        table.separatorColor = LegacyUI.surfaceHigh
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 76
        table.translatesAutoresizingMaskIntoConstraints = false
        table.register(LegacyAppCell.self, forCellReuseIdentifier: LegacyAppCell.reuseID)
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "JIT", style: .plain, target: self, action: #selector(jitTapped))

        let empty = LegacyUI.body("No games yet.\n\nTap + to add an APK, .xapk, .apkm or .apks, "
                                + "or drop one into Husk's folder in the Files app.\n\n"
                                + "JIT has to be on before a game can run — the JIT tab walks through it.",
                                 15)
        empty.textAlignment = .center
        empty.textColor = LegacyUI.textDim
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            empty.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -64),
        ])
        emptyLabel = empty

        store.reload()
        refresh()

        NotificationCenter.default.addObserver(self, selector: #selector(deepLinkFired),
                                              name: LegacyDeepLink.opened, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.reload()
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A husk://open_app link that arrived before this screen existed (a cold
        // launch from an App Clip icon) is opened here, once the Library is on
        // screen and can actually present it.
        openPendingDeepLink()
        adoptDroppedAPKs()
    }

    /// An APK left in the Husk folder -- dropped there through the Files app or
    /// copied in over iTunes file sharing -- is imported, the way the iOS 15
    /// screen's drop target imports one. The legacy shell had no such path: the
    /// + picker was the only way in.
    ///
    /// One file at a time, and each file once: the import copies rather than
    /// moves, so without a record of what has been taken the same APK would be
    /// imported again on every appearance.
    private var adoptingDropped = false
    /// Dropped files that failed this run, so a bad one is not retried on every appearance.
    private var refusedThisRun = Set<String>()
    private func adoptDroppedAPKs() {
        guard !adoptingDropped else { return }
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return }
        let exts = ["apk", "xapk", "apkm", "apks"]
        let dropped = ((try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let key = "husk.legacy.adoptedPackages"
        let adopted = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        guard let next = dropped.first(where: {
            !adopted.contains($0.lastPathComponent) && !refusedThisRun.contains($0.lastPathComponent)
        }) else { return }

        adoptingDropped = true
        HuskLog.log("ui", "legacy: importing \(next.lastPathComponent) from the Husk folder")

        store.importAPKs([next]) { [weak self] outcome in
            guard let self else { return }
            self.adoptingDropped = false
            switch outcome {
            case .added:
                // Recorded only once the copy is done. A big APK can take a while, and a run that
                // ends halfway through it (the app is killed, or the copy fails) used to leave the
                // file recorded as imported with no app to show for it, so it was never tried again.
                var done = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
                done.insert(next.lastPathComponent)
                UserDefaults.standard.set(Array(done), forKey: key)
                self.refresh()
                HuskLog.log("ui", "legacy: import done, \(self.store.apps.count) app(s) in the library")
                self.adoptDroppedAPKs()          // the next one, if several were dropped
            case .refused(let reason):
                // Not recorded, but not retried either: the same file would fail the same way on
                // every appearance of this screen.
                self.refusedThisRun.insert(next.lastPathComponent)
                HuskLog.log("ui", "legacy: \(next.lastPathComponent) was not imported: \(reason)")
                self.adoptDroppedAPKs()
            }
        }
    }

    /// A link that arrives while the app is already running. Registered in
    /// viewDidLoad, removed when this controller goes away.
    @objc private func deepLinkFired() { openPendingDeepLink() }

    private func openPendingDeepLink() {
        guard let id = LegacyDeepLink.pending else { return }
        LegacyDeepLink.pending = nil
        guard presentedViewController == nil else {
            HuskLog.log("ui", "legacy deep link: something is already presented; dropping \(id)")
            return
        }
        guard let app = store.apps.first(where: { $0.id == id }) else {
            HuskLog.log("ui", "legacy deep link: \(id) is not in the library")
            return
        }
        HuskLog.log("ui", "legacy deep link: opening \(app.label)")
        run(app)
    }

    private func refresh() {
        emptyLabel?.isHidden = !store.apps.isEmpty
        table.reloadData()
    }

    // MARK: actions

    @objc private func addTapped() {
        // The iOS 8+ document picker API: UTType (UniformTypeIdentifiers) is
        // iOS 14+, and these UTI strings work on every iOS from 8 up. The types
        // match the CFBundleDocumentTypes in Info.plist.
        let types = ["public.data", "public.archive", "public.content",
                     "com.android.package-archive",
                     "app.husk.xapk", "app.husk.apkm", "app.husk.apks"]
        let picker = UIDocumentPickerViewController(documentTypes: types, in: .import)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func jitTapped() {
        tabBarController?.selectedIndex = 1
    }

    private func run(_ app: TLApp) {
        guard store.canRunOnThisiOS(app) else {
            LegacyUI.Banner(store.unavailableReason(app) ?? "Not runnable on this iOS",
                            color: LegacyUI.warn).show(in: view)
            return
        }
        guard JITBootstrap.ready else {
            LegacyUI.Banner("JIT is not on yet — open the JIT tab first", color: LegacyUI.warn)
                .show(in: view)
            tabBarController?.selectedIndex = 1
            return
        }
        store.markPlayed(app)
        let vc = LegacyGameViewController(app: app)
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }
}

extension LegacyLibraryViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        store.apps.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LegacyAppCell.reuseID,
                                                 for: indexPath) as! LegacyAppCell
        cell.configure(with: store.apps[indexPath.row], store: store)
        return cell
    }

    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        store.remove(store.apps[indexPath.row])
        refresh()
    }
}

extension LegacyLibraryViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        run(store.apps[indexPath.row])
    }
}

extension LegacyLibraryViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        let banner = LegacyUI.Banner("Adding…", color: LegacyUI.surfaceHigh)
        banner.show(in: view, for: 30)
        store.importAPKs(urls) { [weak self] outcome in
            banner.removeFromSuperview()
            guard let self else { return }
            self.refresh()
            switch outcome {
            case .added:
                break
            case .refused(let reason):
                // The reason is the whole point: "that did not import" tells the
                // user nothing about an .ipa picked instead of an .apk.
                LegacyUI.Banner(reason, color: LegacyUI.bad).show(in: self.view)
            }
        }
    }
}

/// One row: icon, name, what it is, and whether this iOS can run it.
final class LegacyAppCell: UITableViewCell {
    static let reuseID = "LegacyAppCell"

    private let icon = UIImageView()
    private let name = UILabel()
    private let detail = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .gray

        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 12
        icon.layer.masksToBounds = true
        icon.backgroundColor = LegacyUI.surfaceHigh
        icon.translatesAutoresizingMaskIntoConstraints = false

        name.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        name.textColor = LegacyUI.text

        detail.font = UIFont.systemFont(ofSize: 13)
        detail.textColor = LegacyUI.textDim
        detail.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [name, detail])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(icon)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),

            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(with app: TLApp, store: LegacyStore) {
        name.text = app.label
        var line = app.report?.nativeEngineName ?? "Android app"
        if let reason = store.unavailableReason(app) {
            line += " · \(reason)"
            name.textColor = LegacyUI.textDim
        } else {
            name.textColor = LegacyUI.text
        }
        detail.text = line
        icon.image = store.icon(for: app)
    }
}

// MARK: - husk://open_app on the iOS 12 shell

/// `husk://open_app?unique_identifier=<id>`: the App Clip's Home Screen icon
/// sends this, and on iOS 15 the SwiftUI router answers it (AppClip.handle).
/// The legacy shell has no router, so the app delegate used to log the URL and
/// open the Library instead -- the app launched, which is all the profile
/// installation needed, but not the game the icon named.
///
/// Kept in this file rather than its own: a new source file only reaches the
/// target when the project is regenerated from project.yml, and a build that
/// used the checked-in project instead would fail to link it.
enum LegacyDeepLink {
    static let opened = Notification.Name("husk.legacy.deepLink")

    /// Set by the app delegate when the URL arrives before the Library exists
    /// (a cold launch from an icon), consumed the first time it appears.
    static var pending: String?

    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "husk",
              url.host?.lowercased() == "open_app",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "unique_identifier" })?.value,
              !id.isEmpty
        else { return false }
        HuskLog.log("ui", "legacy deep link: \(id)")
        pending = id
        NotificationCenter.default.post(name: opened, object: id)
        return true
    }
}
