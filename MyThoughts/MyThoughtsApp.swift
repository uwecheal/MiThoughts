import SwiftUI

@main
struct MyThoughtsApp: App {
    @AppStorage("OutlineSettings.isVisible") private var isOutlineVisible = false

    var body: some Scene {
        WindowGroup {
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
