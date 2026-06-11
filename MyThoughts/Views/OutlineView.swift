import SwiftUI

struct OutlineSettings: Codable, Equatable {
    var isVisible = false

    private static let userDefaultsKey = "OutlineSettings.isVisible"

    static func load() -> OutlineSettings {
        OutlineSettings(isVisible: UserDefaults.standard.bool(forKey: userDefaultsKey))
    }

    func save() {
        UserDefaults.standard.set(isVisible, forKey: Self.userDefaultsKey)
    }
}

struct OutlineItem: Identifiable, Equatable {
    var id: CanvasNode.ID
    var title: String
    var marker: NodeMarker
    var isCollapsed: Bool
    var hasChildren: Bool
    var depth: Int
    var displayedProgress: Int
}

struct OutlineView: View {
    let items: [OutlineItem]
    let selectedNodeID: CanvasNode.ID?
    let taskDisplaySettings: TaskDisplaySettings
    let onSelect: (CanvasNode.ID) -> Void
    let onToggleCollapse: (CanvasNode.ID) -> Void
    let onEditTitle: (CanvasNode.ID) -> Void
    let onBranchOperation: (BranchOperation, CanvasNode.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        outlineRow(item)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 260)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.16))
                .frame(width: 1)
        }
    }

    private func outlineRow(_ item: OutlineItem) -> some View {
        HStack(spacing: 6) {
            Spacer()
                .frame(width: CGFloat(item.depth) * 14)

            if item.hasChildren {
                Button {
                    onToggleCollapse(item.id)
                } label: {
                    Image(systemName: item.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 14, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Color.clear
                    .frame(width: 14, height: 18)
            }

            if let systemImageName = item.marker.systemImageName {
                Image(systemName: systemImageName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }

            if taskDisplaySettings.showCompletionMarker && item.displayedProgress >= 100 {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .imageScale(.small)
            }

            Text(displayTitle(for: item))
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(selectionBackground(for: item), in: RoundedRectangle(cornerRadius: 5))
        .onTapGesture {
            onSelect(item.id)
        }
        .onTapGesture(count: 2) {
            onEditTitle(item.id)
        }
        .contextMenu {
            Button("Edit Title") {
                onEditTitle(item.id)
            }

            Menu("Branch") {
                Button("Select Branch") {
                    onBranchOperation(.select, item.id)
                }
                Button("Collapse Branch") {
                    onBranchOperation(.collapse, item.id)
                }
                Button("Expand Branch") {
                    onBranchOperation(.expand, item.id)
                }
                Button("Collapse Children") {
                    onBranchOperation(.collapseChildren, item.id)
                }
                Button("Expand Children") {
                    onBranchOperation(.expandChildren, item.id)
                }
                Button("Layout Selected Branch") {
                    onBranchOperation(.layout, item.id)
                }
                Button("Duplicate Branch") {
                    onBranchOperation(.duplicate, item.id)
                }
                Button("Delete Branch") {
                    onBranchOperation(.delete, item.id)
                }
                Button("Export Branch") {
                    onBranchOperation(.export, item.id)
                }
                Button("Focus on Branch") {
                    onBranchOperation(.focus, item.id)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private func displayTitle(for item: OutlineItem) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }

    private func selectionBackground(for item: OutlineItem) -> Color {
        item.id == selectedNodeID ? Color.accentColor.opacity(0.18) : Color.clear
    }
}
