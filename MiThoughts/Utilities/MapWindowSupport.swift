#if os(macOS)
import AppKit
typealias PlatformWindow = NSWindow
#else
import UIKit
typealias PlatformWindow = UIWindow
#endif
import SwiftUI

/// Weak handle on the window that hosts one map canvas.
final class WindowRef {
    weak var window: PlatformWindow?
}

#if os(macOS)

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
#else
/// Reports the UIWindow a SwiftUI view ends up in.
struct WindowAccessor: UIViewRepresentable {
    var onWindow: (UIWindow) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = ReportingView()
        view.onWindow = onWindow
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { }

    private final class ReportingView: UIView {
        var onWindow: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }
}
#endif

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
    #if os(macOS)
    private var closeGuards: [ObjectIdentifier: CloseGuard] = [:]
    #endif
    /// The map window that was last made main; used when no window is main
    /// (e.g. a panel is key or the app is in the background).
    private var lastActiveID: UUID?
    private var mainObserver: NSObjectProtocol?

    private init() {
        #if os(macOS)
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
        #else
        mainObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                let registry = MapWindowRegistry.shared
                if let window = notification.object as? UIWindow,
                   let entry = registry.entries.first(where: { $0.windowRef.window === window }) {
                    registry.lastActiveID = entry.id
                }
            }
        }
        #endif
    }

    /// iPad: the scene this map is in came to the front.
    func markActive(_ id: UUID) {
        lastActiveID = id
    }

    func register(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
    }

    func unregister(_ id: UUID) {
        #if os(macOS)
        if let window = entries.first(where: { $0.id == id })?.windowRef.window {
            closeGuards[ObjectIdentifier(window)] = nil
        }
        #endif
        entries.removeAll { $0.id == id }
    }

    func attach(_ window: PlatformWindow, to id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return
        }
        entry.windowRef.window = window
        #if os(macOS)
        // Needed so moving the mouse brings back a pointer hidden while panning.
        window.acceptsMouseMovedEvents = true
        if window.isMainWindow || lastActiveID == nil {
            lastActiveID = id
        }
        let key = ObjectIdentifier(window)
        if closeGuards[key] == nil {
            closeGuards[key] = CloseGuard(window: window) { [weak self] in
                self?.shouldClose(windowID: id) ?? true
            }
        }
        #else
        if window.isKeyWindow || lastActiveID == nil {
            lastActiveID = id
        }
        #endif
    }

    func isMapWindow(_ window: PlatformWindow) -> Bool {
        entries.contains { $0.windowRef.window === window }
    }

    /// The map that menu commands act on: the main window's, else the first one.
    var activeEntryID: UUID? {
        #if os(macOS)
        if let main = NSApp.mainWindow, let entry = entries.first(where: { $0.windowRef.window === main }) {
            return entry.id
        }
        if let key = NSApp.keyWindow, let entry = entries.first(where: { $0.windowRef.window === key }) {
            return entry.id
        }
        #endif
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
            Self.bringForward(entry)
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
    func openQueuedFilesIfNoWindow(attempt: Int = 0) {
        guard entries.isEmpty else {
            return
        }
        // At a cold launch the menu (and with it `openWindow`) may not exist yet: try again shortly.
        guard WindowOpener.action != nil else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    MainActor.assumeIsolated { self.openQueuedFilesIfNoWindow(attempt: attempt + 1) }
                }
            }
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
    private func openInNewWindow(_ url: URL, attempt: Int = 0) {
        guard !windowsToOpen.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else {
            return
        }
        windowsToOpen.append(url)
        windowAttempts[url.standardizedFileURL] = attempt
        openNextWindow()
    }

    private var windowAttempts: [URL: Int] = [:]

    private func hasWindow(for url: URL) -> Bool {
        entries.contains { $0.fileURL()?.standardizedFileURL == url.standardizedFileURL }
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
                    Self.bringForward(existing)
                } else {
                    openWindow(value: url)
                    // SwiftUI can drop the request during launch: check, and ask again if no window came.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        MainActor.assumeIsolated {
                            let key = url.standardizedFileURL
                            let attempt = self.windowAttempts[key] ?? 0
                            self.windowAttempts[key] = nil
                            if !self.hasWindow(for: url), attempt < 3 {
                                self.openInNewWindow(url, attempt: attempt + 1)
                            }
                        }
                    }
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
        guard needsSaveOnClose(entry) else {
            return true
        }
        return entry.confirmClose()
    }

    /// A changed map with a file is saved on close. A new, never-saved map in the
    /// autosaving window is kept by the crash-safe autosave instead, as before.
    private func needsSaveOnClose(_ entry: Entry) -> Bool {
        guard entry.isDirty() else {
            return false
        }
        return !entry.ownsAutosave || entry.fileURL() != nil
    }

    private static func bringForward(_ entry: Entry) {
        #if os(macOS)
        entry.windowRef.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #else
        if let scene = entry.windowRef.window?.windowScene {
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil, errorHandler: nil)
        }
        #endif
    }

    /// Before quitting: every window with unsaved changes that autosave does not cover asks once.
    func confirmQuit() -> Bool {
        for entry in entries where needsSaveOnClose(entry) {
            Self.bringForward(entry)
            if !entry.confirmClose() {
                return false
            }
        }
        return true
    }
}

/// Hides the pointer while the canvas is panned with two fingers or driven by
/// keys, and shows it again only when the mouse really moves, a button is
/// pressed or the app goes to the background. `NSCursor.setHiddenUntilMouseMoves`
/// flickers here, because topics sliding under the pointer trigger cursor updates.
#if os(macOS)
@MainActor
enum CanvasPointer {
    private static var isHidden = false
    private static var eventMonitor: Any?
    private static var resignObserver: NSObjectProtocol?

    static func hide() {
        guard !isHidden else {
            return
        }
        isHidden = true
        NSCursor.hide()
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged]
        ) { event in
            // A trackpad scroll can carry a zero-length move; only real movement shows the pointer.
            if event.type != .mouseMoved || abs(event.deltaX) + abs(event.deltaY) > 0.5 {
                MainActor.assumeIsolated { show() }
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { show() }
        }
    }

    static func show() {
        guard isHidden else {
            return
        }
        isHidden = false
        NSCursor.unhide()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
    }
}
#else
/// Touch screens have no pointer to hide; an iPad trackpad pointer hides by itself.
@MainActor
enum CanvasPointer {
    static func hide() { }
    static func show() { }
}
#endif

/// Lets SwiftUI's `openWindow` be used from places without a SwiftUI environment
/// (the app delegate handling Finder opens).
@MainActor
enum WindowOpener {
    static var action: OpenWindowAction?
}

/// What the crash-safe autosave holds: only unsaved work is brought back at launch,
/// so the app no longer reopens a stale map every time it starts.
enum AutosaveInfo {
    // Storage keys keep the app's earlier name (MyThoughts) so existing settings carry over.
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

#if os(macOS)
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
#endif

extension PlatformWindow {
    /// Shows a map's title (and on the Mac its file proxy icon and edited dot).
    func showMapTitle(_ title: String, fileURL: URL?, edited: Bool) {
        #if os(macOS)
        self.title = title
        representedURL = fileURL
        isDocumentEdited = edited
        #else
        windowScene?.title = title
        #endif
    }

    func bringMapToFront() {
        #if os(macOS)
        makeKeyAndOrderFront(nil)
        #else
        if let scene = windowScene {
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil, errorHandler: nil)
        }
        #endif
    }

    func closeMapWindow() {
        #if os(macOS)
        close()
        #else
        if let scene = windowScene {
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil, errorHandler: nil)
        }
        #endif
    }
}
