import Foundation
import CoreGraphics

/// What was (and was not yet) carried over from the .itmz file.
struct IThoughtsImportReport: Equatable {
    var topicCount = 0
    var floatingTopicCount = 0
    var summaryCount = 0
    var relationshipCount = 0   // shown from milestone 37C
    var imageCount = 0          // shown from milestone 37C
    var coloredTopicCount = 0   // shown from milestone 37C
    var unmappedIconCount = 0

    /// One line for the status message, or nil when nothing was left out.
    var notImportedDescription: String? {
        var parts: [String] = []
        if relationshipCount > 0 {
            parts.append("\(relationshipCount) relationship line(s)")
        }
        if imageCount > 0 {
            parts.append("\(imageCount) topic image(s)")
        }
        if coloredTopicCount > 0 {
            parts.append("colors on \(coloredTopicCount) topic(s)")
        }
        if unmappedIconCount > 0 {
            parts.append("\(unmappedIconCount) icon(s) without a matching marker")
        }
        guard !parts.isEmpty else {
            return nil
        }
        return "Not imported yet: " + parts.joined(separator: ", ") + "."
    }
}

struct IThoughtsImportResult {
    var nodes: [CanvasNode]
    var connections: [CanvasConnection]
    var rootNodeIDs: [CanvasNode.ID]
    var summaries: [CanvasSummary] = []
    var report = IThoughtsImportReport()
}

enum IThoughtsImportError: LocalizedError {
    case unreadableFile(String)
    case emptyMap

    var errorDescription: String? {
        switch self {
        case let .unreadableFile(reason):
            return "The .itmz file could not be read. \(reason)"
        case .emptyMap:
            return "The iThoughts file did not contain any importable topics."
        }
    }
}

/// Converts an iThoughts map into MyThoughts nodes, keeping the original layout.
///
/// iThoughts stores each topic's *centre* relative to its parent's centre
/// (`position="{x, y}"`); MyThoughts stores absolute top-left corners. Floating
/// topics become separate roots, folded topics stay collapsed, task fields,
/// notes, links, markers and summaries are mapped. See Docs/ITMZ_FORMAT.md.
enum IThoughtsImportService {
    static func `import`(from url: URL) throws -> IThoughtsImportResult {
        let document: ItmzDocument
        do {
            document = try ItmzDocument(contentsOf: url)
        } catch {
            throw IThoughtsImportError.unreadableFile(error.localizedDescription)
        }
        return try convert(document)
    }

    static func convert(_ document: ItmzDocument) throws -> IThoughtsImportResult {
        let tree = document.topicTree()
        guard !tree.isEmpty else {
            throw IThoughtsImportError.emptyMap
        }

        var builder = ImportBuilder(document: document)
        for (index, topic) in tree.enumerated() {
            // Top-level positions are canvas coordinates, i.e. relative to (0, 0).
            builder.add(topic, parentID: nil, depth: 0, sortIndex: Double(index), parentCenter: .zero)
        }
        builder.addSummaries(in: tree, parentID: nil)
        builder.moveIntoPositiveSpace()
        builder.report.relationshipCount = document.relationships.count

        guard !builder.nodes.isEmpty else {
            throw IThoughtsImportError.emptyMap
        }
        return IThoughtsImportResult(
            nodes: builder.nodes,
            connections: builder.connections,
            rootNodeIDs: builder.rootNodeIDs,
            summaries: builder.summaries,
            report: builder.report
        )
    }

    // MARK: Mapping helpers

    /// Rough size of a topic box. iThoughts does not store heights, so this is an estimate
    /// based on text length (CJK characters count double) and the stored text width.
    static func estimatedSize(text: String, textWidth: Double?) -> CGSize {
        // Tuned against 195 real maps: typical iThoughts sibling spacing is 44-50 pt,
        // so a single-line topic must stay under ~40 pt to avoid overlaps.
        let characterWidth: CGFloat = 7
        let lineHeight: CGFloat = 16
        let horizontalPadding: CGFloat = 24
        let verticalPadding: CGFloat = 14
        let minimumHeight: CGFloat = 34
        let maximumAutoWidth: CGFloat = 260

        let lineUnits = text.split(separator: "\n", omittingEmptySubsequences: false).map { displayUnits($0) }
        let longest = CGFloat(lineUnits.max() ?? 0)

        let width: CGFloat
        if let textWidth, textWidth > 0 {
            width = min(max(CGFloat(textWidth) + horizontalPadding, 120), 520)
        } else {
            width = min(max(longest * characterWidth + horizontalPadding, 120), maximumAutoWidth)
        }
        let usableWidth = max(width - horizontalPadding, 1)
        let lineCount = lineUnits.reduce(0) { total, units in
            total + max(1, Int((CGFloat(units) * characterWidth / usableWidth).rounded(.up)))
        }
        let height = max(minimumHeight, CGFloat(lineCount) * lineHeight + verticalPadding)
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    private static func displayUnits(_ line: Substring) -> Int {
        line.unicodeScalars.reduce(0) { total, scalar in
            total + (scalar.value >= 0x2E80 ? 2 : 1)
        }
    }

    /// iThoughts icon name -> closest MyThoughts marker (nil = no equivalent).
    static func marker(forIcon name: String) -> NodeMarker? {
        switch name {
        case "idea":
            return .idea
        case "tick", "icon-green-tick":
            return .done
        case "tickbox":
            return .task
        case "alert", "icon-exclamationmark", "sign-stop", "sign-forbidden", "icon-alarm":
            return .warning
        case "question", "icon-questionmark":
            return .question
        case "icon-star":
            return .star
        default:
            if name.contains("signal-flag") {
                return .flag
            }
            if name.count == 2, name.hasPrefix("p"), name.last?.isNumber == true {
                return .priority
            }
            return nil
        }
    }

    /// iThoughts priority 1 (highest) ... 9 (lowest). Inferred: only "2" occurs in the samples.
    static func priority(from value: String?) -> TaskPriority {
        guard let value, let number = Int(value) else {
            return .none
        }
        switch number {
        case 1...3:
            return .high
        case 4...6:
            return .medium
        case 7...9:
            return .low
        default:
            return .none
        }
    }

    /// "3.00h" -> 3. Negative values mean "not set" in iThoughts.
    static func effort(from value: String?) -> Double {
        guard let value else {
            return 0
        }
        let numeric = value.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return max(0, Double(numeric) ?? 0)
    }
}

// MARK: - Builder

private struct ImportBuilder {
    let document: ItmzDocument
    var nodes: [CanvasNode] = []
    var connections: [CanvasConnection] = []
    var rootNodeIDs: [CanvasNode.ID] = []
    var summaries: [CanvasSummary] = []
    var report = IThoughtsImportReport()

    private var idsByUUID: [String: UUID] = [:]
    private var usedIDs = Set<UUID>()

    init(document: ItmzDocument) {
        self.document = document
    }

    mutating func add(_ topic: ItmzTopicNode, parentID: UUID?, depth: Int, sortIndex: Double, parentCenter: CGPoint) {
        let attributes = topic.attributes
        let offset = ItmzFormat.parsePosition(attributes["position"])
        let center = CGPoint(x: parentCenter.x + CGFloat(offset.x), y: parentCenter.y + CGFloat(offset.y))

        // Floating topics are free-standing in iThoughts (no line to the parent).
        let isFloating = parentID != nil && attributes["floating"] == "1"
        let effectiveParentID: UUID? = isFloating ? nil : parentID

        let id = makeID(for: attributes["uuid"])
        let text = (attributes["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImage = document.imagePath(forTopicAttributes: attributes) != nil
        let title = text.isEmpty ? (hasImage ? "Image" : "Untitled") : text
        let size = IThoughtsImportService.estimatedSize(text: title, textWidth: attributes["text-width"].flatMap(Double.init))

        var links: [NodeLink] = []
        if let link = attributes["link"]?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty {
            links.append(NodeLink(title: link, urlString: ItmzLinks.normalize(link)))
        }

        var marker: NodeMarker = .none
        var hadIcon = false
        for key in ["icon1", "icon2"] {
            guard let icon = attributes[key], !icon.isEmpty else {
                continue
            }
            hadIcon = true
            if marker == .none, let mapped = IThoughtsImportService.marker(forIcon: icon) {
                marker = mapped
            }
        }
        if hadIcon && marker == .none {
            report.unmappedIconCount += 1
        }

        let rawProgress = attributes["task-progress"].flatMap(Double.init) ?? 0
        let isCompleted = rawProgress > 100
        let completedAt = isCompleted ? (ItmzFormat.date(fromTimestamp: attributes["modified"]) ?? Date()) : nil

        let node = CanvasNode(
            id: id,
            title: title,
            body: attributes["note"] ?? "",
            progress: Int(min(max(rawProgress, 0), 100)),
            cost: attributes["cost"].flatMap(Double.init) ?? 0,
            effort: IThoughtsImportService.effort(from: attributes["task-effort"]),
            startDate: ItmzFormat.date(fromTimestamp: attributes["task-start"]),
            dueDate: ItmzFormat.date(fromTimestamp: attributes["task-due"]),
            priority: IThoughtsImportService.priority(from: attributes["task-priority"]),
            completedAt: completedAt,
            rollupEnabled: attributes["cost-type"] == "2",
            marker: marker,
            links: links,
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height,
            sortIndex: effectiveParentID == nil && parentID != nil ? Double(rootNodeIDs.count) : sortIndex,
            parentID: effectiveParentID,
            isCollapsed: attributes["folded"] == "1"
        )
        nodes.append(node)

        if let effectiveParentID {
            connections.append(CanvasConnection(id: UUID(), fromNodeID: effectiveParentID, toNodeID: id, type: "parentChild"))
        } else {
            rootNodeIDs.append(id)
        }

        report.topicCount += 1
        if isFloating {
            report.floatingTopicCount += 1
        }
        if hasImage {
            report.imageCount += 1
        }
        if let color = attributes["color"], !color.isEmpty {
            report.coloredTopicCount += 1
        }

        for (index, child) in topic.children.enumerated() {
            add(child, parentID: id, depth: depth + 1, sortIndex: Double(index), parentCenter: center)
        }
    }

    /// iThoughts summary topics carry `summary1`/`summary2`: the first and last sibling they bracket.
    mutating func addSummaries(in topics: [ItmzTopicNode], parentID: UUID?) {
        let siblingKeys = topics.map { $0.uuid.lowercased() }
        for (index, topic) in topics.enumerated() {
            if let first = topic.attributes["summary1"]?.lowercased(),
               let last = topic.attributes["summary2"]?.lowercased(),
               let summaryNodeID = id(for: topic.uuid),
               let start = siblingKeys.firstIndex(of: first),
               let end = siblingKeys.firstIndex(of: last) {
                let ownKey = topic.uuid.lowercased()
                let summarized = (min(start, end)...max(start, end))
                    .map { topics[$0] }
                    .filter { $0.uuid.lowercased() != ownKey }
                    .compactMap { id(for: $0.uuid) }
                if summarized.count >= 2 {
                    summaries.append(CanvasSummary(
                        parentID: parentID,
                        summarizedNodeIDs: summarized,
                        summaryNodeID: summaryNodeID,
                        sortIndex: index
                    ))
                    report.summaryCount += 1
                }
            }
            addSummaries(in: topic.children, parentID: id(for: topic.uuid))
        }
    }

    /// iThoughts maps are centred on (0, 0); shift everything so it starts at a small margin.
    mutating func moveIntoPositiveSpace() {
        guard let minX = nodes.map(\.x).min(), let minY = nodes.map(\.y).min() else {
            return
        }
        let margin: CGFloat = 80
        let dx = margin - minX
        let dy = margin - minY
        for index in nodes.indices {
            nodes[index].x += dx
            nodes[index].y += dy
        }
    }

    /// Keeps the iThoughts UUID as the node ID when possible (needed later for saving back to .itmz).
    private mutating func makeID(for uuid: String?) -> UUID {
        var id = uuid.flatMap { UUID(uuidString: $0) } ?? UUID()
        if usedIDs.contains(id) {
            id = UUID()
        }
        usedIDs.insert(id)
        if let uuid {
            idsByUUID[uuid.lowercased()] = id
        }
        return id
    }

    private func id(for uuid: String) -> UUID? {
        idsByUUID[uuid.lowercased()]
    }
}
