import SwiftUI

/// Files opened from Finder (double-click, "Open With", drag onto the Dock icon) wait here
/// until the canvas takes them, so a file that arrives during launch is never lost.
enum ExternalOpenQueue {
    private(set) static var pending: [URL] = []

    static func enqueue(_ url: URL) {
        pending.append(url)
        NotificationCenter.default.post(name: MyThoughtsFileCommand.openURL, object: nil)
    }

    /// The most recent request (older ones are superseded), or nil.
    static func takeLatest() -> URL? {
        defer { pending.removeAll() }
        return pending.last
    }

    /// Every waiting file, in the order they arrived; each opens in its own window.
    static func takeAll() -> [URL] {
        defer { pending.removeAll() }
        var seen = Set<URL>()
        return pending.filter { seen.insert($0.standardizedFileURL).inserted }
    }
}

final class MyThoughtsAppDelegate: NSObject, NSApplicationDelegate {
    /// Finder double-click, "Open With", drop on the Dock icon: each file gets its
    /// own window (or comes forward if it is already open).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                if MapWindowRegistry.shared.entries.isEmpty && WindowOpener.action == nil {
                    // Too early for any window: the first map window picks it up.
                    ExternalOpenQueue.enqueue(url)
                } else {
                    MapWindowRegistry.shared.open(url)
                }
            }
        }
        // Launched by opening files, SwiftUI shows no window of its own; make sure
        // queued files still get one.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                MapWindowRegistry.shared.openQueuedFilesIfNoWindow()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            MapWindowRegistry.shared.confirmQuit() ? .terminateNow : .terminateCancel
        }
    }
}

@main
struct MyThoughtsApp: App {
    @NSApplicationDelegateAdaptor(MyThoughtsAppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window per map; windows can also be merged into tabs (Window ▸ Merge All Windows).
        WindowGroup("MyThoughts", id: MapWindowID.map, for: URL.self) { $fileURL in
            ContentView(fileURL: $fileURL)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .commands {
            MyThoughtsCommands()
        }
    }
}

enum MapWindowID {
    static let map = "map"
}

struct MyThoughtsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("OutlineSettings.isVisible") private var isOutlineVisible = false

    var body: some Commands {
            // Lets the app delegate open windows for Finder files even before any window exists.
            let _ = MainActor.assumeIsolated { WindowOpener.action = openWindow }
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(id: MapWindowID.map)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("New Map in This Window") {
                    NotificationCenter.default.post(name: MyThoughtsFileCommand.newMap, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Button("New From Template...") {
                    NotificationCenter.default.post(name: MyThoughtsFileCommand.newFromTemplate, object: nil)
                }

                Divider()

                Button("Show Start Screen") {
                    NotificationCenter.default.post(name: MyThoughtsFileCommand.showStartScreen, object: nil)
                }
            }

            CommandGroup(after: .newItem) {
                Button("Open...") {
                    NotificationCenter.default.post(name: MyThoughtsFileCommand.open, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Menu("Open Recent") {
                    let recentFiles = RecentFilesStore.load()

                    if recentFiles.isEmpty {
                        Text("No Recent Files")
                    } else {
                        ForEach(recentFiles, id: \.path) { url in
                            Button(url.lastPathComponent) {
                                NotificationCenter.default.post(
                                    name: MyThoughtsFileCommand.openRecent,
                                    object: url
                                )
                            }
                        }
                    }
                }

                Divider()

                Button("Save") {
                    NotificationCenter.default.post(name: MyThoughtsFileCommand.save, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Save As...") {
                    NotificationCenter.default.post(name: MyThoughtsFileCommand.saveAs, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Import iThoughts (.itmz)...") {
                    NotificationCenter.default.post(name: MyThoughtsFileCommand.importITMZ, object: nil)
                }

                Button("Export as iThoughts (.itmz)...") {
                    NotificationCenter.default.post(name: MyThoughtsFileCommand.exportITMZ, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Menu("Export Outline") {
                    Button("Markdown (.md)...") {
                        NotificationCenter.default.post(name: MyThoughtsFileCommand.exportOutline, object: OutlineFormat.markdown.rawValue)
                    }
                    Button("OPML (.opml)...") {
                        NotificationCenter.default.post(name: MyThoughtsFileCommand.exportOutline, object: OutlineFormat.opml.rawValue)
                    }
                    Button("FreeMind / Freeplane (.mm)...") {
                        NotificationCenter.default.post(name: MyThoughtsFileCommand.exportOutline, object: OutlineFormat.freemind.rawValue)
                    }
                }

                Button("Export as PDF...") {
                    NotificationCenter.default.post(name: MyThoughtsFileCommand.exportPDF, object: nil)
                }

                Button("Export as PNG...") {
                    NotificationCenter.default.post(name: MyThoughtsFileCommand.exportPNG, object: nil)
                }

                Divider()

                Button("Print...") {
                    NotificationCenter.default.post(name: MyThoughtsFileCommand.printMap, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command])
            }

            // Into the system View menu (a WindowGroup already has one).
            // Shortcuts follow iThoughtsX.
            CommandGroup(before: .toolbar) {
                Button(isOutlineVisible ? "Hide Outline" : "Outline View") {
                    NotificationCenter.default.post(name: MyThoughtsViewCommand.toggleOutline, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Edit/View Notes") { NotificationCenter.default.post(name: MyThoughtsViewCommand.editNotes, object: nil) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Show/Hide Notes Window") { NotificationCenter.default.post(name: MyThoughtsViewCommand.toggleNotes, object: nil) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Find…") { NotificationCenter.default.post(name: MyThoughtsViewCommand.find, object: nil) }
                    .keyboardShortcut("f", modifiers: [.command])

                Menu("Zoom") {
                    Button("Zoom In") { NotificationCenter.default.post(name: MyThoughtsViewCommand.zoomIn, object: nil) }
                        .keyboardShortcut(">", modifiers: [.command])
                    Button("Zoom Out") { NotificationCenter.default.post(name: MyThoughtsViewCommand.zoomOut, object: nil) }
                        .keyboardShortcut("<", modifiers: [.command])
                    Button("Fit Map") { NotificationCenter.default.post(name: MyThoughtsViewCommand.fitMap, object: nil) }
                        .keyboardShortcut("0", modifiers: [.command])
                    Button("Fit Selection") { NotificationCenter.default.post(name: MyThoughtsViewCommand.fitSelection, object: nil) }
                        .keyboardShortcut("0", modifiers: [.command, .shift])
                }
            }

            CommandMenu("Task") {
                TaskActionMenuItems(showsShortcuts: true) { action in
                    TaskCommand.post(action)
                }

                Divider()

                Button("Show Task Panel") {
                    NotificationCenter.default.post(name: TaskCommand.toggleTaskList, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .option, .control])

                Divider()

                Button("Create Reminder") { NotificationCenter.default.post(name: MyThoughtsViewCommand.createReminder, object: nil) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Create Calendar Event") { NotificationCenter.default.post(name: MyThoughtsViewCommand.createEvent, object: nil) }
                    .keyboardShortcut("r", modifiers: [.command, .control])

                Button("Hide/Show Completed Tasks") {
                    NotificationCenter.default.post(name: TaskCommand.toggleHideCompleted, object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .control])

                Button("Sync with Reminders & Calendar") {
                    NotificationCenter.default.post(name: TaskCommand.syncApple, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }

            CommandMenu("Insert") {
                Button("Relationship") {
                    NotificationCenter.default.post(name: MyThoughtsViewCommand.addRelationship, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command])
            }

            CommandMenu("Branch") {
                Button("Select Branch") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.select)
                }

                Divider()

                Button("Collapse Branch") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.collapse)
                }

                Button("Expand Branch") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.expand)
                }

                Button("Collapse Children") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.collapseChildren)
                }

                Button("Expand Children") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.expandChildren)
                }

                Button("Layout Selected Branch") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.layout)
                }

                Divider()

                Button("Create Summary") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.createSummary)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button("Duplicate Branch") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.duplicate)
                }

                Button("Delete Branch") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.delete)
                }

                Button("Export Branch") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.export)
                }

                Divider()

                Button("Focus on Branch") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.focus)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            CommandMenu("Arrange") {
                Button("Layout Selected Branch") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.layout)
                }
            }
    }
}
