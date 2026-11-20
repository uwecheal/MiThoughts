import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Open / save locations and simple questions, on both platforms.
///
/// On the Mac these run modally and call `completion` before returning, so callers
/// can keep working synchronously. On iPad they present the Files picker or an
/// alert and call `completion` later.
@MainActor
enum FilePanel {
    struct Choice {
        var title: String
        var role: Role = .normal

        enum Role {
            case normal, destructive, cancel
        }
    }

    /// One existing file the user picks, or nil.
    static func pickFile(title: String, message: String? = nil, types: [UTType], completion: @escaping (URL?) -> Void) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = title
        if let message {
            panel.message = message
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        completion(panel.runModal() == .OK ? panel.url : nil)
        #else
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.item] : types, asCopy: false)
        picker.allowsMultipleSelection = false
        present(picker, completion: { urls in
            guard let url = urls.first else {
                completion(nil)
                return
            }
            _ = url.startAccessingSecurityScopedResource()
            completion(url)
        })
        #endif
    }

    /// Where to write a new file named `suggestedName`, or nil.
    ///
    /// iPad has no save panel that hands back a location to write to, so the user
    /// picks a folder and the file goes into it (with a number added if the name is taken).
    static func pickSaveURL(title: String, message: String? = nil, suggestedName: String, types: [UTType], completion: @escaping (URL?) -> Void) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = title
        if let message {
            panel.message = message
        }
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        completion(panel.runModal() == .OK ? panel.url : nil)
        #else
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.title = title
        present(picker, completion: { urls in
            guard let folder = urls.first else {
                completion(nil)
                return
            }
            // Kept open for the session: the map is saved here again later.
            _ = folder.startAccessingSecurityScopedResource()
            completion(uniqueURL(in: folder, name: suggestedName))
        })
        #endif
    }

    /// Asks a question; `completion` gets the index of the button chosen.
    static func ask(_ title: String, message: String, choices: [Choice], completion: @escaping (Int) -> Void) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        for choice in choices {
            alert.addButton(withTitle: choice.title)
        }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        completion(index)
        #else
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        for (index, choice) in choices.enumerated() {
            let style: UIAlertAction.Style = switch choice.role {
            case .normal: .default
            case .destructive: .destructive
            case .cancel: .cancel
            }
            alert.addAction(UIAlertAction(title: choice.title, style: style) { _ in completion(index) })
        }
        topViewController()?.present(alert, animated: true)
        #endif
    }

    /// Opens a web or file link with the system.
    @discardableResult
    static func openExternally(_ url: URL) -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        return true
        #endif
    }

    #if !os(macOS)
    private static func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = "\(stem) \(number)"
            candidate = folder.appendingPathComponent(ext.isEmpty ? numbered : "\(numbered).\(ext)")
            number += 1
        }
        return candidate
    }

    private static var activeDelegate: PickerDelegate?

    private static func present(_ picker: UIDocumentPickerViewController, completion: @escaping ([URL]) -> Void) {
        let delegate = PickerDelegate { urls in
            activeDelegate = nil
            completion(urls)
        }
        activeDelegate = delegate
        picker.delegate = delegate
        guard let presenter = topViewController() else {
            activeDelegate = nil
            completion([])
            return
        }
        presenter.present(picker, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
        let finish: ([URL]) -> Void

        init(finish: @escaping ([URL]) -> Void) {
            self.finish = finish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            MainActor.assumeIsolated { finish(urls) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            MainActor.assumeIsolated { finish([]) }
        }
    }
    #endif
}
