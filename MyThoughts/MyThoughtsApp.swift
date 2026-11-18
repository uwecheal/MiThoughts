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
}

final class MyThoughtsAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.last {
            ExternalOpenQueue.enqueue(url)
        }
    }
}

@main
struct MyThoughtsApp: App {
    @NSApplicationDelegateAdaptor(MyThoughtsAppDelegate.self) private var appDelegate
    @AppStorage("OutlineSettings.isVisible") private var isOutlineVisible = false

    var body: some Scene {
        Window("MyThoughts", id: "main") {
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Map") {
                    NotificationCenter.default.post(name: MyThoughtsFileCommand.newMap, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])

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

            CommandMenu("View") {
                Button(isOutlineVisible ? "Hide Outline" : "Show Outline") {
                    NotificationCenter.default.post(name: MyThoughtsViewCommand.toggleOutline, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
            }

            CommandMenu("Task") {
                TaskActionMenuItems(showsShortcuts: true) { action in
                    TaskCommand.post(action)
                }

                Divider()

                Button("Show Task List") {
                    NotificationCenter.default.post(name: TaskCommand.toggleTaskList, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

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
                .keyboardShortcut("r", modifiers: [.command, .shift])
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
            }

            CommandMenu("Arrange") {
                Button("Layout Selected Branch") {
                    NotificationCenter.default.post(name: MyThoughtsBranchCommand.perform, object: BranchOperation.layout)
                }
            }
        }
    }
}
