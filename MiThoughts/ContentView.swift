import SwiftUI

struct ContentView: View {
    /// The file this window shows (nil = untitled); kept in sync so window
    /// restoration reopens the right file.
    @Binding var fileURL: URL?

    var body: some View {
        #if os(macOS)
        InfiniteCanvasView(windowFileURL: $fileURL)
        #else
        // iPad / iPhone: the Mac's menu bar commands as a toolbar, for touch.
        NavigationStack {
            InfiniteCanvasView(windowFileURL: $fileURL)
                .toolbar { TouchToolbar() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
        }
        #endif
    }
}

#if !os(macOS)
/// File and editing buttons for a touch screen. Each posts the same command as
/// the matching Mac menu item or key, so the canvas handles both the same way.
private struct TouchToolbar: ToolbarContent {
    @AppStorage("OutlineSettings.isVisible") private var isOutlineVisible = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Menu {
                post("New Map", "doc.badge.plus", MiThoughtsFileCommand.newMap)
                post("New From Template…", "square.grid.2x2", MiThoughtsFileCommand.newFromTemplate)
                post("Open…", "folder", MiThoughtsFileCommand.open)
                post("Start Screen", "house", MiThoughtsFileCommand.showStartScreen)
                Divider()
                post("Save", "square.and.arrow.down", MiThoughtsFileCommand.save)
                post("Save As…", "square.and.arrow.down.on.square", MiThoughtsFileCommand.saveAs)
                Divider()
                Menu {
                    post("iThoughts (.itmz)…", "doc", MiThoughtsFileCommand.exportITMZ)
                    post("PDF…", "doc.richtext", MiThoughtsFileCommand.exportPDF)
                    post("PNG…", "photo", MiThoughtsFileCommand.exportPNG)
                    ForEach([OutlineFormat.markdown, .opml, .freemind], id: \.rawValue) { format in
                        Button("\(format.label)…") {
                            NotificationCenter.default.post(name: MiThoughtsFileCommand.exportOutline, object: format.rawValue)
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                post("Print…", "printer", MiThoughtsFileCommand.printMap)
            } label: {
                Label("File", systemImage: "doc")
            }

            post("Undo", "arrow.uturn.backward", MiThoughtsEditCommand.undo)
            post("Redo", "arrow.uturn.forward", MiThoughtsEditCommand.redo)
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            post("Add Child", "arrow.turn.down.right", MiThoughtsEditCommand.addChild)
            post("Add Sibling", "plus.rectangle.on.rectangle", MiThoughtsEditCommand.addSibling)
            post("Edit Title", "character.cursor.ibeam", MiThoughtsEditCommand.editTitle)
            post("Details", "info.circle", MiThoughtsEditCommand.showDetails)
            post("Delete", "trash", MiThoughtsEditCommand.delete)

            Menu {
                post(isOutlineVisible ? "Hide Outline" : "Show Outline", "list.bullet.indent", MiThoughtsViewCommand.toggleOutline)
                post("Notes", "note.text", MiThoughtsViewCommand.toggleNotes)
                post("Tasks", "checklist", TaskCommand.toggleTaskList)
                post("Find", "magnifyingglass", MiThoughtsViewCommand.find)
                Divider()
                post("Fit Map", "arrow.up.left.and.down.right.magnifyingglass", MiThoughtsViewCommand.fitMap)
                post("Fit Selection", "viewfinder", MiThoughtsViewCommand.fitSelection)
                Divider()
                post("Relationship", "arrow.triangle.branch", MiThoughtsViewCommand.addRelationship)
                Button {
                    NotificationCenter.default.post(name: MiThoughtsBranchCommand.perform, object: BranchOperation.createSummary)
                } label: {
                    Label("Summary", systemImage: "curlybraces")
                }
            } label: {
                Label("View", systemImage: "ellipsis.circle")
            }
        }
    }

    private func post(_ title: String, _ systemImage: String, _ name: Notification.Name) -> some View {
        Button {
            NotificationCenter.default.post(name: name, object: nil)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}
#endif

#Preview {
    ContentView(fileURL: .constant(nil))
        .frame(width: 720, height: 480)
}
