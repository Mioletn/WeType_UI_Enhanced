// SPDX-License-Identifier: GPL-2.0-or-later
//
// The document picker for iOS 12 and 13.
//
// `HuskFilePicker` (used on 15+) is built on `UTType` and the 14+ picker
// initialiser. Below that, `UIDocumentPickerViewController` still speaks UTI
// strings -- `documentTypes:in:` has been there since iOS 8 -- so this is the
// same behaviour in the older spelling: present, hand back the URLs, and let the
// caller copy them somewhere it can read later.
//
// The delegate is held in a static because the presented controller only holds
// it weakly and nothing else would keep it alive for the length of the sheet.

import MobileCoreServices
import UIKit

final class LegacyDocumentPicker: NSObject, UIDocumentPickerDelegate {
    private static var current: LegacyDocumentPicker?

    private let onPick: ([URL]) -> Void
    private let onCancel: () -> Void

    private init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    static func present(mimeTypes: String, multiple: Bool,
                        onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
        guard let host = topViewController() else { onCancel(); return }
        let delegate = LegacyDocumentPicker(onPick: onPick, onCancel: onCancel)
        current = delegate
        let picker = UIDocumentPickerViewController(documentTypes: documentTypes(mimeTypes), in: .import)
        picker.allowsMultipleSelection = multiple
        picker.delegate = delegate
        host.present(picker, animated: true)
    }

    // MARK: UIDocumentPickerDelegate (the 11+ two methods)

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        LegacyDocumentPicker.current = nil
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        LegacyDocumentPicker.current = nil
        onCancel()
    }

    // MARK: MIME -> UTI

    /// The intent's MIME types as UTIs. Unknown ones are looked up properly
    /// (MobileCoreServices has done this since iOS 5); `public.data` is the
    /// fallback, which shows every file the picker can import rather than none.
    private static func documentTypes(_ mimeTypes: String) -> [String] {
        let wanted = mimeTypes.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if wanted.isEmpty { return ["public.data"] }

        var types: [String] = []
        for mime in wanted {
            switch mime {
            case "*/*", "*": return ["public.data"]
            case "image/*": types.append("public.image")
            case "video/*": types.append("public.movie")
            case "audio/*": types.append("public.audio")
            case "text/*": types.append("public.text")
            case "application/*": types.append("public.data")
            default:
                if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, mime as CFString, nil)?
                    .takeRetainedValue() {
                    types.append(uti as String)
                } else {
                    types.append("public.data")
                }
            }
        }
        return types.isEmpty ? ["public.data"] : types
    }

    private static func topViewController() -> UIViewController? {
        var top = UIApplication.shared.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
