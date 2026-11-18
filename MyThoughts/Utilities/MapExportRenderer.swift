import AppKit
import SwiftUI

struct MapExportPayload {
    var nodes: [CanvasNode]
    var connections: [CanvasConnection]
    var summaries: [CanvasSummary] = []
    var appearance: CanvasAppearance
    var colorScheme: ColorScheme
    var displayedProgressByNodeID: [CanvasNode.ID: Int]
    var relationships: [CanvasRelationship] = []
    var effectiveColorHexByNodeID: [CanvasNode.ID: String] = [:]
}

struct MapExportResult {
    var warning: String?
}

enum MapExportRenderer {
    private static let contentPadding: CGFloat = 80
    private static let defaultCanvasSize = CGSize(width: 1024, height: 768)
    private static let maximumPNGDimension: CGFloat = 6000

    static func exportBounds(for nodes: [CanvasNode]) -> CGRect {
        guard let firstNode = nodes.first else {
            return CGRect(origin: .zero, size: defaultCanvasSize)
        }

        let contentBounds = nodes.dropFirst().reduce(rect(for: firstNode)) { bounds, node in
            bounds.union(rect(for: node))
        }

        return contentBounds.insetBy(dx: -contentPadding, dy: -contentPadding)
    }

    static func writePDF(payload: MapExportPayload, to url: URL) throws {
        let bounds = exportBounds(for: payload.nodes)
        let pageSize = pageSize(for: bounds)
        let view = hostingView(
            for: MapExportPageView(payload: payload, bounds: bounds, pageSize: pageSize),
            size: pageSize
        )
        let data = view.dataWithPDF(inside: view.bounds)
        try data.write(to: url, options: .atomic)
    }

    static func writePNG(payload: MapExportPayload, to url: URL) throws -> MapExportResult {
        let bounds = exportBounds(for: payload.nodes)
        let scale = pngScale(for: bounds.size)
        let view = hostingView(
            for: MapExportContentView(payload: payload, bounds: bounds),
            size: bounds.size
        )

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(bounds.width * scale), 1),
            pixelsHigh: max(Int(bounds.height * scale), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw MapExportError.renderingFailed
        }

        representation.size = bounds.size
        view.cacheDisplay(in: view.bounds, to: representation)

        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw MapExportError.renderingFailed
        }

        try data.write(to: url, options: .atomic)

        let warning = scale < 2
            ? "PNG export was capped to keep the image size safe for large maps."
            : nil
        return MapExportResult(warning: warning)
    }

    static func print(payload: MapExportPayload) {
        let bounds = exportBounds(for: payload.nodes)
        let pageSize = pageSize(for: bounds)
        let view = hostingView(
            for: MapExportPageView(payload: payload, bounds: bounds, pageSize: pageSize),
            size: pageSize
        )
        let operation = NSPrintOperation(view: view)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    private static func rect(for node: CanvasNode) -> CGRect {
        CGRect(x: node.x, y: node.y, width: node.width, height: node.height)
    }

    private static func pageSize(for bounds: CGRect) -> CGSize {
        bounds.width >= bounds.height
            ? CGSize(width: 792, height: 612)
            : CGSize(width: 612, height: 792)
    }

    private static func pngScale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else {
            return 2
        }

        let widthScale = maximumPNGDimension / size.width
        let heightScale = maximumPNGDimension / size.height
        return min(2, max(0.5, min(widthScale, heightScale)))
    }

    private static func hostingView<Content: View>(for content: Content, size: CGSize) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: AnyView(content.frame(width: size.width, height: size.height)))
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return view
    }
}

enum MapExportError: LocalizedError {
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .renderingFailed:
            "Could not render the map image."
        }
    }
}

private struct MapExportPageView: View {
    let payload: MapExportPayload
    let bounds: CGRect
    let pageSize: CGSize

    var body: some View {
        let scale = min(
            (pageSize.width - 48) / max(bounds.width, 1),
            (pageSize.height - 48) / max(bounds.height, 1)
        )
        let scaledSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        ZStack {
            payload.appearance.backgroundColor(for: payload.colorScheme)

            MapExportContentView(payload: payload, bounds: bounds)
                .frame(width: bounds.width, height: bounds.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: scaledSize.width, height: scaledSize.height, alignment: .topLeading)
        }
        .frame(width: pageSize.width, height: pageSize.height)
    }
}

private struct MapExportContentView: View {
    let payload: MapExportPayload
    let bounds: CGRect

    private var colors: CanvasThemeColors {
        payload.appearance.themeColors(for: payload.colorScheme)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            payload.appearance.backgroundColor(for: payload.colorScheme)

            if payload.appearance.showsGrid {
                ExportGridView(appearance: payload.appearance, bounds: bounds, colors: colors)
            }

            if payload.appearance.showQuadrants {
                ExportQuadrantView(appearance: payload.appearance, bounds: bounds, colors: colors)
            }

            BoundaryLayerView(items: boundaryItems)

            ExportConnectionView(payload: payload, bounds: bounds, colors: colors)

            ExportSummaryView(payload: payload, bounds: bounds, colors: colors)

            RelationshipLayerView(
                items: relationshipItems,
                lineWidth: payload.appearance.connectionLineThickness.width,
                labelBackground: payload.appearance.backgroundColor(for: payload.colorScheme)
            )

            ForEach(payload.nodes) { node in
                ExportNodeView(
                    node: node,
                    appearance: payload.appearance,
                    colors: colors,
                    displayedProgress: payload.displayedProgressByNodeID[node.id] ?? node.progress,
                    fillHex: payload.effectiveColorHexByNodeID[node.id]
                )
                .position(
                    x: node.x - bounds.minX + node.width / 2,
                    y: node.y - bounds.minY + node.height / 2
                )
            }
        }
        .frame(width: bounds.width, height: bounds.height)
        .clipped()
    }

    private func localRect(_ node: CanvasNode) -> CGRect {
        CGRect(x: node.x - bounds.minX, y: node.y - bounds.minY, width: node.width, height: node.height)
    }

    private var relationshipItems: [RelationshipRenderItem] {
        let nodesByID = Dictionary(payload.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return payload.relationships.compactMap { relationship in
            guard let from = nodesByID[relationship.fromNodeID], let to = nodesByID[relationship.toNodeID] else {
                return nil
            }
            return RelationshipRenderItem(
                id: relationship.id,
                fromRect: localRect(from),
                toRect: localRect(to),
                lineStyle: relationship.lineStyle,
                startStyle: relationship.startStyle,
                endStyle: relationship.endStyle,
                isDashed: relationship.isDashed,
                color: TopicColor.color(relationship.colorHex) ?? colors.connection,
                label: relationship.label
            )
        }
    }

    private var boundaryItems: [BoundaryRenderItem] {
        let nodesByID = Dictionary(payload.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: payload.nodes.filter { $0.parentID != nil }) { $0.parentID! }
        return payload.nodes.filter(\.style.hasBoundary).map { node in
            var rect = localRect(node)
            var stack = children[node.id] ?? []
            var visited: Set<CanvasNode.ID> = [node.id]
            while let child = stack.popLast() {
                guard !visited.contains(child.id), nodesByID[child.id] != nil else {
                    continue
                }
                visited.insert(child.id)
                rect = rect.union(localRect(child))
                stack.append(contentsOf: children[child.id] ?? [])
            }
            return BoundaryRenderItem(
                rect: rect.insetBy(dx: -10, dy: -10),
                color: TopicColor.color(payload.effectiveColorHexByNodeID[node.id]) ?? colors.connection
            )
        }
    }
}

private struct ExportGridView: View {
    let appearance: CanvasAppearance
    let bounds: CGRect
    let colors: CanvasThemeColors

    var body: some View {
        Canvas { context, _ in
            let spacing = appearance.gridSize.spacing
            let startX = floor(bounds.minX / spacing) * spacing
            let startY = floor(bounds.minY / spacing) * spacing
            var path = Path()

            var x = startX
            while x <= bounds.maxX {
                let localX = x - bounds.minX
                path.move(to: CGPoint(x: localX, y: 0))
                path.addLine(to: CGPoint(x: localX, y: bounds.height))
                x += spacing
            }

            var y = startY
            while y <= bounds.maxY {
                let localY = y - bounds.minY
                path.move(to: CGPoint(x: 0, y: localY))
                path.addLine(to: CGPoint(x: bounds.width, y: localY))
                y += spacing
            }

            context.stroke(path, with: .color(colors.grid), lineWidth: 1)
        }
    }
}

private struct ExportQuadrantView: View {
    let appearance: CanvasAppearance
    let bounds: CGRect
    let colors: CanvasThemeColors

    var body: some View {
        let origin = CGPoint(x: -bounds.minX, y: -bounds.minY)

        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                var path = Path()

                if (0...size.width).contains(origin.x) {
                    path.move(to: CGPoint(x: origin.x, y: 0))
                    path.addLine(to: CGPoint(x: origin.x, y: size.height))
                }

                if (0...size.height).contains(origin.y) {
                    path.move(to: CGPoint(x: 0, y: origin.y))
                    path.addLine(to: CGPoint(x: size.width, y: origin.y))
                }

                context.stroke(path, with: .color(colors.quadrantAxis), lineWidth: 1.25)
            }

            quadrantLabel("Urgent & Important")
                .position(labelPosition(origin: origin, horizontal: .right, vertical: .top))
            quadrantLabel("Urgent & Not Important")
                .position(labelPosition(origin: origin, horizontal: .right, vertical: .bottom))
            quadrantLabel("Important & Not Urgent")
                .position(labelPosition(origin: origin, horizontal: .left, vertical: .top))
            quadrantLabel("Not Urgent & Not Important")
                .position(labelPosition(origin: origin, horizontal: .left, vertical: .bottom))
        }
    }

    private func quadrantLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(colors.quadrantLabel)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private enum HorizontalSide {
        case left
        case right
    }

    private enum VerticalSide {
        case top
        case bottom
    }

    private func labelPosition(origin: CGPoint, horizontal: HorizontalSide, vertical: VerticalSide) -> CGPoint {
        let margin: CGFloat = 72
        let minimumX: CGFloat = 92
        let maximumX = max(bounds.width - 92, minimumX)
        let minimumY: CGFloat = 26
        let maximumY = max(bounds.height - 26, minimumY)
        let x = horizontal == .left
            ? min(max(origin.x - margin, minimumX), maximumX)
            : min(max(origin.x + margin, minimumX), maximumX)
        let y = vertical == .top
            ? min(max(origin.y - margin, minimumY), maximumY)
            : min(max(origin.y + margin, minimumY), maximumY)

        return CGPoint(x: x, y: y)
    }
}

private struct ExportLineKey: Hashable {
    var colorHex: String?
    var isLevel1: Bool
}

private struct ExportConnectionView: View {
    let payload: MapExportPayload
    let bounds: CGRect
    let colors: CanvasThemeColors

    var body: some View {
        let nodesByID = Dictionary(payload.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        Canvas { context, _ in
            let grouped = Dictionary(grouping: payload.connections) { connection in
                ExportLineKey(
                    colorHex: payload.effectiveColorHexByNodeID[connection.toNodeID],
                    isLevel1: nodesByID[connection.fromNodeID]?.parentID == nil
                )
            }
            for (key, connections) in grouped {
                let colorHex = key.colorHex
                var path = Path()
                for connection in connections {
                    guard let fromNode = nodesByID[connection.fromNodeID],
                          let toNode = nodesByID[connection.toNodeID] else {
                        continue
                    }

                    ConnectionLinePathBuilder.addConnection(
                        from: localConnectionStart(from: fromNode, to: toNode),
                        to: localConnectionEnd(from: fromNode, to: toNode),
                        style: payload.appearance.lineStyle(level1: key.isLevel1),
                        to: &path
                    )
                }

                context.stroke(
                    path,
                    with: .color(TopicColor.color(colorHex) ?? colors.connection),
                    style: StrokeStyle(
                        lineWidth: payload.appearance.lineWidth(level1: key.isLevel1),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
    }

    private func localCenter(of node: CanvasNode) -> CGPoint {
        CGPoint(
            x: node.x - bounds.minX + node.width / 2,
            y: node.y - bounds.minY + node.height / 2
        )
    }

    private func localConnectionStart(from parentNode: CanvasNode, to childNode: CanvasNode) -> CGPoint {
        let parentCenter = localCenter(of: parentNode)
        let childCenter = localCenter(of: childNode)
        let x = childCenter.x >= parentCenter.x
            ? parentNode.x - bounds.minX + parentNode.width
            : parentNode.x - bounds.minX
        return CGPoint(x: x, y: parentCenter.y)
    }

    private func localConnectionEnd(from parentNode: CanvasNode, to childNode: CanvasNode) -> CGPoint {
        let parentCenter = localCenter(of: parentNode)
        let childCenter = localCenter(of: childNode)
        let x = childCenter.x >= parentCenter.x
            ? childNode.x - bounds.minX
            : childNode.x - bounds.minX + childNode.width
        return CGPoint(x: x, y: childCenter.y)
    }
}

private struct ExportSummaryView: View {
    let payload: MapExportPayload
    let bounds: CGRect
    let colors: CanvasThemeColors

    var body: some View {
        let nodesByID = Dictionary(payload.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        Canvas { context, _ in
            var path = Path()

            for summary in payload.summaries {
                guard let summaryNode = nodesByID[summary.summaryNodeID] else {
                    continue
                }

                let summarizedNodes = summary.summarizedNodeIDs.compactMap { nodesByID[$0] }
                guard !summarizedNodes.isEmpty else {
                    continue
                }

                let maxX = summarizedNodes.map { $0.x + $0.width }.max() ?? 0
                let topY = summarizedNodes.map { $0.y + $0.height / 2 }.min() ?? 0
                let bottomY = summarizedNodes.map { $0.y + $0.height / 2 }.max() ?? 0
                let summaryPoint = CGPoint(
                    x: summaryNode.x - bounds.minX,
                    y: summaryNode.y - bounds.minY + summaryNode.height / 2
                )

                ConnectionLinePathBuilder.addSummaryBracket(
                    bracketX: maxX - bounds.minX + 34,
                    topY: topY - bounds.minY,
                    bottomY: bottomY - bounds.minY,
                    summaryPoint: summaryPoint,
                    to: &path
                )
            }

            context.stroke(
                path,
                with: .color(colors.connection.opacity(0.82)),
                lineWidth: payload.appearance.connectionLineThickness.width
            )
        }
    }
}

private struct ExportNodeView: View {
    let node: CanvasNode
    let appearance: CanvasAppearance
    let colors: CanvasThemeColors
    let displayedProgress: Int
    var fillHex: String? = nil

    private var shape: TopicShape {
        node.style.shape ?? appearance.nodeStyle.topicShape
    }

    private var textColor: Color {
        if let fillHex, shape.isFilled {
            return TopicColor.textColor(onFill: fillHex)
        }
        return colors.nodeText
    }

    private var image: NSImage? {
        node.style.imageData.flatMap { NSImage(data: $0) }
    }

    private var imageSize: CGSize {
        guard let image, image.size.width > 0 else {
            return .zero
        }
        let preferred = node.style.imageWidth.map { CGFloat($0) } ?? min(image.size.width, 240)
        let width = min(preferred, max(node.width - 16, 16))
        let height = width * image.size.height / image.size.width
        let maximumHeight = max(node.height - (node.title.isEmpty ? 12 : 30), 12)
        return height > maximumHeight
            ? CGSize(width: maximumHeight * image.size.width / image.size.height, height: maximumHeight)
            : CGSize(width: width, height: height)
    }

    private var cornerRadius: CGFloat {
        switch appearance.nodeStyle {
        case .roundedRectangle:
            8
        case .capsule:
            24
        case .minimalUnderline:
            3
        }
    }

    private var showsShadow: Bool {
        appearance.nodeStyle != .minimalUnderline
    }

    var body: some View {
        ZStack {
            TopicBoxBackground(
                shape: shape,
                fill: TopicColor.color(fillHex) ?? colors.nodeBackground,
                stroke: fillHex.map { shape.isFilled ? TopicColor.borderColor(forFill: $0) : (TopicColor.color($0) ?? colors.nodeBorder) } ?? colors.nodeBorder,
                lineWidth: 1,
                shadow: showsShadow ? colors.shadow : nil,
                cornerRadius: cornerRadius
            )

            VStack(spacing: 4) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: imageSize.width, height: imageSize.height)
                }

                HStack(spacing: 6) {
                    if let systemImageName = node.marker.systemImageName {
                        Image(systemName: systemImageName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(textColor.opacity(0.62))
                            .imageScale(.small)
                    }

                    if appearance.taskDisplay.showCompletionMarker && displayedProgress >= 100 {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(colors.selectedBorder.opacity(0.70))
                            .imageScale(.small)
                    }

                    if !(node.title.isEmpty && image != nil) {
                        Text(TopicText.attributed(displayTitle))
                            .font(node.style.textSize.map { .system(size: CGFloat($0) * 13 / 14) } ?? appearance.nodeFontSize.font)
                            .foregroundStyle(textColor)
                            .multilineTextAlignment(.center)
                            .lineLimit(max(1, Int((node.height - imageSize.height - 8) / 16)))
                            .frame(maxWidth: .infinity)
                    }
                }

                if hasTaskIndicatorRow {
                    HStack(spacing: 8) {
                        if appearance.taskDisplay.showProgress {
                            Text("\(displayedProgress)%")
                        }

                        if appearance.taskDisplay.showDueDate,
                           let dueDateText {
                            Text(dueDateText)
                        }

                        if appearance.taskDisplay.showPriority,
                           let priorityText {
                            Text(priorityText)
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(textColor.opacity(0.58))
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(width: node.width, height: node.height)
    }

    private var displayTitle: String {
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }

    private var hasTaskIndicatorRow: Bool {
        appearance.taskDisplay.showProgress ||
        (appearance.taskDisplay.showDueDate && dueDateText != nil) ||
        (appearance.taskDisplay.showPriority && priorityText != nil)
    }

    private var dueDateText: String? {
        guard let dueDate = node.dueDate else {
            return nil
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dueDay = calendar.startOfDay(for: dueDate)

        if dueDay < today {
            return "Overdue"
        }

        if calendar.isDateInToday(dueDate) {
            return "Today"
        }

        if calendar.isDateInTomorrow(dueDate) {
            return "Tomorrow"
        }

        return Self.dateFormatter.string(from: dueDate)
    }

    private var priorityText: String? {
        switch node.priority {
        case .none:
            nil
        case .low:
            "Low"
        case .medium:
            "Med"
        case .high:
            "High"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
}
