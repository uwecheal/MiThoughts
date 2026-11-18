import AppKit
import SwiftUI

/// Weak handle on the NSWindow that hosts one map canvas.
final class WindowRef {
    weak var window: NSWindow?
}

/// Reports the NSWindow a SwiftUI view ends up in.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { }

    private final class ReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }
}

/// Every open map window, so menu commands reach only the front one, a file
/// that is already open is brought forward instead of opened twice, and
/// unsaved maps are not lost on close or quit.
@MainActor
final class MapWindowRegistry {
    static let shared = MapWindowRegistry()

    struct Entry {
        let id: UUID
        let windowRef: WindowRef
        /// The window that restores and keeps the crash-safe autosave.
        let ownsAutosave: Bool
        let fileURL: () -> URL?
        let isDirty: () -> Bool
        /// Empty, or only the start screen over an unchanged map: a file can open here.
        let isBlank: () -> Bool
        let openHere: (URL) -> Void
        /// Asks to save if needed; false = the user cancelled.
        let confirmClose: () -> Bool
    }

    private(set) var entries: [Entry] = []
    private var closeGuards: [ObjectIdentifier: CloseGuard] = [:]
    /// The map window that was last made main; used when no window is main
    /// (e.g. a panel is key or the app is in the background).
    private var lastActiveID: UUID?
    private var mainObserver: NSObjectProtocol?

    private init() {
        mainObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                let registry = MapWindowRegistry.shared
                if let window = notification.object as? NSWindow,
                   let entry = registry.entries.first(where: { $0.windowRef.window === window }) {
                    registry.lastActiveID = entry.id
                }
            }
        }
    }

    func register(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
    }

    func unregister(_ id: UUID) {
        if let window = entries.first(where: { $0.id == id })?.windowRef.window {
            closeGuards[ObjectIdentifier(window)] = nil
        }
        entries.removeAll { $0.id == id }
    }

    func attach(_ window: NSWindow, to id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return
        }
        entry.windowRef.window = window
        if window.isMainWindow || lastActiveID == nil {
            lastActiveID = id
        }
        let key = ObjectIdentifier(window)
        if closeGuards[key] == nil {
            closeGuards[key] = CloseGuard(window: window) { [weak self] in
                self?.shouldClose(windowID: id) ?? true
            }
        }
    }

    func isMapWindow(_ window: NSWindow) -> Bool {
        entries.contains { $0.windowRef.window === window }
    }

    /// The map that menu commands act on: the main window's, else the first one.
    var activeEntryID: UUID? {
        if let main = NSApp.mainWindow, let entry = entries.first(where: { $0.windowRef.window === main }) {
            return entry.id
        }
        if let key = NSApp.keyWindow, let entry = entries.first(where: { $0.windowRef.window === key }) {
            return entry.id
        }
        if let lastActiveID, entries.contains(where: { $0.id == lastActiveID }) {
            return lastActiveID
        }
        return entries.first?.id
    }

    func isActive(_ id: UUID) -> Bool {
        activeEntryID == id
    }

    /// Opens `url`: brings its window forward if it is already open, uses the
    /// front window when that one is blank, and otherwise opens a new window.
    func open(_ url: URL) {
        let target = url.standardizedFileURL
        if let entry = entries.first(where: { $0.fileURL()?.standardizedFileURL == target }) {
            entry.windowRef.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let id = activeEntryID, let entry = entries.first(where: { $0.id == id }), entry.isBlank() {
            entry.openHere(url)
            return
        }
        if WindowOpener.action != nil {
            openInNewWindow(url)
        } else {
            ExternalOpenQueue.enqueue(url)
        }
    }

    /// Files that arrived while no map window existed each get a window now.
    func openQueuedFilesIfNoWindow() {
        guard entries.isEmpty, WindowOpener.action != nil else {
            return
        }
        for url in ExternalOpenQueue.takeAll() {
            openInNewWindow(url)
        }
    }

    private var windowsToOpen: [URL] = []
    private var isOpeningWindows = false

    /// SwiftUI drops `openWindow` calls made in quick succession, so new windows
    /// are opened one at a time.
    private func openInNewWindow(_ url: URL) {
        guard !windowsToOpen.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else {
            return
        }
        windowsToOpen.append(url)
        openNextWindow()
    }

    private func openNextWindow() {
        guard !isOpeningWindows, !windowsToOpen.isEmpty, let openWindow = WindowOpener.action else {
            return
        }
        isOpeningWindows = true
        let url = windowsToOpen.removeFirst()
        // A short pause also keeps the first request clear of SwiftUI's own launch work.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                // A restored window may have taken this file in the meantime.
                if let existing = self.entries.first(where: { $0.fileURL()?.standardizedFileURL == url.standardizedFileURL }) {
                    existing.windowRef.window?.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(value: url)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                self.isOpeningWindows = false
                self.openNextWindow()
            }
        }
    }

    private func shouldClose(windowID: UUID) -> Bool {
        guard let entry = entries.first(where: { $0.id == windowID }) else {
            return true
        }
        // The autosaving window keeps its map across launches, as before.
        guard !entry.ownsAutosave, entry.isDirty() else {
            return true
        }
        return entry.confirmClose()
    }

    /// Before quitting: every window with unsaved changes that autosave does not cover asks once.
    func confirmQuit() -> Bool {
        for entry in entries where !entry.ownsAutosave && entry.isDirty() {
            entry.windowRef.window?.makeKeyAndOrderFront(nil)
            if !entry.confirmClose() {
                return false
            }
        }
        return true
    }
}

/// Lets SwiftUI's `openWindow` be used from places without a SwiftUI environment
/// (the app delegate handling Finder opens).
@MainActor
enum WindowOpener {
    static var action: OpenWindowAction?
}

/// What the crash-safe autosave holds: only unsaved work is brought back at launch,
/// so the app no longer reopens a stale map every time it starts.
enum AutosaveInfo {
    private static let unsavedKey = "MyThoughts.autosave.hasUnsavedChanges"
    private static let sourceKey = "MyThoughts.autosave.sourceFile"

    static var hasUnsavedChanges: Bool {
        UserDefaults.standard.bool(forKey: unsavedKey)
    }

    /// Name of the file the unsaved changes belong to, if any.
    static var sourceFileName: String? {
        UserDefaults.standard.string(forKey: sourceKey)
    }

    static func record(hasUnsavedChanges: Bool, fileURL: URL?) {
        UserDefaults.standard.set(hasUnsavedChanges, forKey: unsavedKey)
        UserDefaults.standard.set(fileURL?.lastPathComponent, forKey: sourceKey)
    }
}

/// Decides which window restores the autosaved map: the first one opened
/// without a file. Later windows start empty.
@MainActor
enum AutosaveOwnership {
    private(set) static var isClaimed = false

    static func claim() -> Bool {
        guard !isClaimed else {
            return false
        }
        isClaimed = true
        return true
    }

    static func release() {
        isClaimed = false
    }
}

/// Sits in front of SwiftUI's own window delegate to ask before a window with
/// unsaved changes closes; every other delegate message is passed through.
final class CloseGuard: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let shouldClose: @MainActor () -> Bool

    init(window: NSWindow, shouldClose: @escaping @MainActor () -> Bool) {
        self.original = window.delegate
        self.shouldClose = shouldClose
        super.init()
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
           original.windowShouldClose?(sender) == false {
            return false
        }
        return MainActor.assumeIsolated { shouldClose() }
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) {
            return original
        }
        return super.forwardingTarget(for: aSelector)
    }
}
