import CoreGraphics
import Foundation

/// An .itmz file opened for editing. Saving writes the edited map back into the
/// *same* XML DOM, so everything MyThoughts does not model (style.xml, groups,
/// callouts, note attachments, preview.png, unknown attributes ...) is kept.
final class ItmzEditingSession {
    let document: ItmzDocument
    /// Node id -> iThoughts topic uuid string, exactly as it appears in the file.
    var topicUUIDs: [UUID: String]
    var relationshipUUIDs: [UUID: String]
    /// MyThoughts canvas coordinates = iThoughts coordinates + offset.
    var canvasOffset: CGPoint

    /// iThoughts groups (`<group type color member0…>`), mapped to node ids once; drawn as boxes.
    lazy var groups: [CanvasGroupBox] = {
        var nodeIDByUUID: [String: UUID] = [:]
        for (id, uuid) in topicUUIDs {
            nodeIDByUUID[uuid.lowercased()] = id
        }
        return document.groups.compactMap { element -> CanvasGroupBox? in
            let attributes = element.attributeDictionary
            guard attributes["type"] != "-1" else {
                return nil
            }
            let members = attributes
                .filter { ItmzDocument.isMemberAttribute($0.key) }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .compactMap { nodeIDByUUID[$0.value.lowercased()] }
            guard !members.isEmpty else {
                return nil
            }
            return CanvasGroupBox(
                colorHex: attributes["color"].flatMap { TopicColor.normalizedHex($0) },
                isFilled: attributes["type"] != "1",
                memberIDs: members
            )
        }
    }()

    init(document: ItmzDocument, topicUUIDs: [UUID: String], relationshipUUIDs: [UUID: String], canvasOffset: CGPoint) {
        self.document = document
        self.topicUUIDs = topicUUIDs
        self.relationshipUUIDs = relationshipUUIDs
        self.canvasOffset = canvasOffset
    }
}

struct ItmzSaveResult {
    var session: ItmzEditingSession
    var report: ItmzChangeReport
    var backupURL: URL?
}

enum ItmzExportService {
    static let fileExtension = "itmz"

    /// Opens an .itmz for editing: the converted map plus the session needed to save it back.
    static func open(_ url: URL) throws -> (result: IThoughtsImportResult, session: ItmzEditingSession) {
        let document: ItmzDocument
        do {
            document = try ItmzDocument(contentsOf: url)
        } catch {
            throw IThoughtsImportError.unreadableFile(error.localizedDescription)
        }
        let result = try IThoughtsImportService.convert(document)
        let session = ItmzEditingSession(
            document: document,
            topicUUIDs: result.topicUUIDs,
            relationshipUUIDs: result.relationshipUUIDs,
            canvasOffset: result.canvasOffset
        )
        return (result, session)
    }

    /// Where overwritten .itmz files are copied before saving.
    static var backupDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyThoughts", isDirectory: true)
            .appendingPathComponent("iThoughts Backups", isDirectory: true)
    }

    /// Writes the map as .itmz. With a session, the original file's DOM is updated in
    /// place (only what changed); without one, a new iThoughts map is created.
    static func save(
        nodes: [CanvasNode],
        summaries: [CanvasSummary],
        relationships: [CanvasRelationship],
        session: ItmzEditingSession?,
        to url: URL,
        now: Date = Date()
    ) throws -> ItmzSaveResult {
        guard !nodes.isEmpty else {
            throw ItmzError.emptyMap
        }
        let document = session?.document ?? ItmzDocument.makeNew(now: now)
        var writer = TreeWriter(nodes: nodes, summaries: summaries, session: session, document: document)
        let tree = writer.buildTree()
        let report = try document.apply(tree, managedKeys: ItmzDocument.extendedManagedAttributes, now: now)
        document.applyRelationships(writer.relationshipAttributes(relationships), now: now)

        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let backupURL = try document.save(to: url, backupDirectory: fileExists ? backupDirectory : nil, now: now)

        let updatedSession = session ?? ItmzEditingSession(
            document: document, topicUUIDs: [:], relationshipUUIDs: [:], canvasOffset: writer.origin
        )
        updatedSession.topicUUIDs = writer.topicUUIDs
        updatedSession.relationshipUUIDs = writer.relationshipUUIDs
        updatedSession.canvasOffset = writer.origin
        return ItmzSaveResult(session: updatedSession, report: report, backupURL: backupURL)
    }
}

// MARK: - Tree writer

private struct TreeWriter {
    let nodes: [CanvasNode]
    let summaries: [CanvasSummary]
    let session: ItmzEditingSession?
    let document: ItmzDocument

    private(set) var topicUUIDs: [UUID: String] = [:]
    private(set) var relationshipUUIDs: [UUID: String] = [:]
    private(set) var origin: CGPoint = .zero

    private let nodesByID: [UUID: CanvasNode]
    private let childrenByParent: [UUID: [CanvasNode]]
    private let originalTopics: [String: [String: String]]
    private let originalTopLevel: Set<String>
    private var summaryRange: [UUID: (first: UUID, last: UUID)] = [:]
    /// For roots that become floating topics: the topic they are written under.
    private var floatingParent: [UUID: UUID] = [:]
    /// Original topic uuid -> its index among its parent's children, so floating
    /// topics go back between their siblings where iThoughts had them.
    private var originalChildIndex: [String: Int] = [:]

    init(nodes: [CanvasNode], summaries: [CanvasSummary], session: ItmzEditingSession?, document: ItmzDocument) {
        self.nodes = nodes
        self.summaries = summaries
        self.session = session
        self.document = document

        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        nodesByID = byID
        childrenByParent = Dictionary(grouping: nodes.filter { $0.parentID.map { byID[$0] != nil } ?? false }) { $0.parentID! }
            .mapValues { TreeWriter.ordered($0) }

        var originals: [String: [String: String]] = [:]
        if session != nil {
            for element in document.allTopics {
                if let uuid = element["uuid"], originals[uuid] == nil {
                    originals[uuid] = element.attributeDictionary
                }
            }
        }
        originalTopics = originals
        if session != nil {
            var stack = document.topicTree()
            while let topic = stack.popLast() {
                for (position, child) in topic.children.enumerated() {
                    originalChildIndex[child.uuid] = position
                }
                stack.append(contentsOf: topic.children)
            }
        }
        originalTopLevel = session == nil ? [] : Set(document.topLevelTopics.compactMap { $0["uuid"] })

        for node in nodes {
            topicUUIDs[node.id] = session?.topicUUIDs[node.id] ?? node.id.uuidString
        }
    }

    static func ordered(_ nodes: [CanvasNode]) -> [CanvasNode] {
        nodes.sorted { left, right in
            left.sortIndex == right.sortIndex ? left.y < right.y : left.sortIndex < right.sortIndex
        }
    }

    private func center(_ node: CanvasNode) -> CGPoint {
        CGPoint(x: node.x + node.width / 2, y: node.y + node.height / 2)
    }

    // MARK: Structure

    mutating func buildTree() -> [ItmzTopicNode] {
        let roots = TreeWriter.ordered(nodes.filter { node in
            guard let parentID = node.parentID else {
                return true
            }
            return nodesByID[parentID] == nil
        })

        // Which roots stay top-level topics in the file.
        var topLevel: [CanvasNode]
        if session != nil {
            topLevel = roots.filter { originalTopLevel.contains(topicUUIDs[$0.id] ?? "") }
        } else {
            topLevel = []
        }
        if topLevel.isEmpty, let first = roots.first(where: { $0.floatingAnchorID == nil }) ?? roots.first {
            topLevel = [first]
        }
        let topLevelIDs = Set(topLevel.map(\.id))
        let main = topLevel[0]

        // Every other root is a floating topic: under its original anchor if that still works, else the central topic.
        for root in roots where !topLevelIDs.contains(root.id) {
            if let anchor = root.floatingAnchorID, nodesByID[anchor] != nil {
                floatingParent[root.id] = anchor
            } else {
                floatingParent[root.id] = main.id
            }
        }
        for root in roots where floatingParent[root.id] != nil && createsCycle(root.id) {
            floatingParent[root.id] = main.id
        }

        origin = session?.canvasOffset ?? center(main)
        computeSummaryRanges()

        var floatingChildren: [UUID: [CanvasNode]] = [:]
        for root in roots {
            if let parent = floatingParent[root.id] {
                floatingChildren[parent, default: []].append(root)
            }
        }
        return topLevel.map { build($0, parent: nil, isFloating: false, floatingChildren: floatingChildren) }
    }

    /// True when writing `rootID` under its floating parent would put it inside itself.
    private func createsCycle(_ rootID: UUID) -> Bool {
        var visited = Set<UUID>()
        var current: UUID? = floatingParent[rootID]
        while let id = current {
            if id == rootID || visited.contains(id) {
                return true
            }
            visited.insert(id)
            if let parentID = nodesByID[id]?.parentID, nodesByID[parentID] != nil {
                current = parentID
            } else {
                current = floatingParent[id]
            }
        }
        return false
    }

    private mutating func computeSummaryRanges() {
        for summary in summaries {
            guard let summaryNode = nodesByID[summary.summaryNodeID] else {
                continue
            }
            let siblings = childrenByParent[summaryNode.parentID ?? UUID()] ?? []
            let members = siblings.filter { summary.summarizedNodeIDs.contains($0.id) }
            guard let first = members.first, let last = members.last else {
                continue
            }
            summaryRange[summaryNode.id] = (first.id, last.id)
        }
    }

    private func build(_ node: CanvasNode, parent: CanvasNode?, isFloating: Bool,
                       floatingChildren: [UUID: [CanvasNode]]) -> ItmzTopicNode {
        let uuid = topicUUIDs[node.id] ?? node.id.uuidString
        let nodeCenter = center(node)
        let position: (x: Double, y: Double)
        if let parent {
            let parentCenter = center(parent)
            position = (Double(nodeCenter.x - parentCenter.x), Double(nodeCenter.y - parentCenter.y))
        } else {
            position = (Double(nodeCenter.x - origin.x), Double(nodeCenter.y - origin.y))
        }

        // A top-level topic can carry floating="1" in iThoughts files; it means
        // nothing for a top-level topic, so keep whatever the file had.
        let writesFloating = parent == nil ? originalTopics[uuid]?["floating"] == "1" : isFloating
        var attributes = topicAttributes(for: node, original: originalTopics[uuid], isFloating: writesFloating)
        attributes["uuid"] = uuid
        attributes["position"] = ItmzFormat.formatPosition(x: position.x, y: position.y)

        var children = (childrenByParent[node.id] ?? []).map {
            build($0, parent: node, isFloating: false, floatingChildren: floatingChildren)
        }
        // Floating topics return to their original slot when they had one, else go last.
        let floating = (floatingChildren[node.id] ?? []).map { child -> (Int, ItmzTopicNode) in
            let uuid = topicUUIDs[child.id] ?? child.id.uuidString
            return (originalChildIndex[uuid] ?? Int.max, build(child, parent: node, isFloating: true, floatingChildren: floatingChildren))
        }
        for (slot, topic) in floating.sorted(by: { $0.0 < $1.0 }) {
            children.insert(topic, at: min(slot, children.count))
        }
        return ItmzTopicNode(attributes: attributes, children: children)
    }

    // MARK: Attributes

    /// Start from the original values and only replace what the user changed in meaning,
    /// so untouched topics are written back byte-for-byte.
    private func topicAttributes(for node: CanvasNode, original: [String: String]?, isFloating: Bool) -> [String: String] {
        var a: [String: String] = [:]
        let managed = Set(ItmzDocument.extendedManagedAttributes)
        for (key, value) in original ?? [:] where managed.contains(key) {
            a[key] = value
        }

        func set(_ key: String, _ value: String?, unchangedIf same: Bool) {
            guard !same else {
                return
            }
            a[key] = value.flatMap { $0.isEmpty ? nil : $0 }
        }

        // text
        let originalText = original?["text"] ?? ""
        let trimmedOriginal = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholderKept = trimmedOriginal.isEmpty && (node.title == "Untitled" || node.title.isEmpty)
        set("text", node.title, unchangedIf: original != nil && (trimmedOriginal == node.title || placeholderKept))

        // note
        set("note", node.body, unchangedIf: original != nil && (original?["note"] ?? "") == node.body)

        // link
        let link = node.links.first?.urlString ?? ""
        let originalLink = original?["link"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        set("link", link, unchangedIf: original != nil && (originalLink.isEmpty ? link.isEmpty : ItmzLinks.normalize(originalLink) == link))

        // colour, shape, size, boundary, folded, floating
        let originalColor = original?["color"].flatMap { TopicColor.normalizedHex($0) }
        set("color", node.style.colorHex, unchangedIf: original != nil && originalColor == node.style.colorHex)
        let originalShape = original?["shape"].flatMap(Int.init).flatMap(TopicShape.init(rawValue:))
        set("shape", node.style.shape.map { String($0.rawValue) },
            unchangedIf: original != nil && originalShape == node.style.shape)
        let originalSize = original?["text-size"].flatMap(Double.init)
        set("text-size", node.style.textSize.map { ItmzFormat.formatNumber($0) },
            unchangedIf: original != nil && originalSize == node.style.textSize)
        set("boundary", node.style.hasBoundary ? "1" : nil,
            unchangedIf: original != nil && (original?["boundary"] == "1") == node.style.hasBoundary)
        set("folded", node.isCollapsed ? "1" : nil,
            unchangedIf: original != nil && (original?["folded"] == "1") == node.isCollapsed)
        set("floating", isFloating ? "1" : nil,
            unchangedIf: original != nil && (original?["floating"] == "1") == isFloating)

        // icons
        let originalMarker = original.map { IThoughtsImportService.marker(fromIcons: $0) } ?? .none
        if original == nil || originalMarker != node.marker {
            a["icon1"] = IThoughtsImportService.icon(for: node.marker)
            if let icon2 = a["icon2"], IThoughtsImportService.marker(forIcon: icon2) != nil {
                a["icon2"] = nil
            }
        }

        // task fields
        let rawProgress = original?["task-progress"].flatMap(Double.init) ?? 0
        let progressSame = Int(min(max(rawProgress, 0), 100)) == node.progress && (rawProgress > 100) == (node.completedAt != nil)
        let progressValue: String? = node.completedAt != nil ? "101" : (node.progress > 0 ? String(node.progress) : nil)
        set("task-progress", progressValue, unchangedIf: original != nil && progressSame)

        set("task-start", node.startDate.map(ItmzFormat.timestamp),
            unchangedIf: original != nil && ItmzFormat.date(fromTimestamp: original?["task-start"]) == node.startDate)
        set("task-due", node.dueDate.map(ItmzFormat.timestamp),
            unchangedIf: original != nil && ItmzFormat.date(fromTimestamp: original?["task-due"]) == node.dueDate)

        let priorityValue: String? = switch node.priority {
        case .none: nil
        case .high: "2"
        case .medium: "5"
        case .low: "8"
        }
        set("task-priority", priorityValue,
            unchangedIf: original != nil && IThoughtsImportService.priority(from: original?["task-priority"]) == node.priority)

        set("task-effort", node.effort > 0 ? String(format: "%.2fh", node.effort) : nil,
            unchangedIf: original != nil && abs(IThoughtsImportService.effort(from: original?["task-effort"]) - node.effort) < 0.0001)
        let originalCost = original?["cost"].flatMap(Double.init) ?? 0
        set("cost", node.cost != 0 ? ItmzFormat.formatNumber(node.cost) : nil,
            unchangedIf: original != nil && abs(originalCost - node.cost) < 0.0001)
        set("resources", node.resources.joined(separator: ", "),
            unchangedIf: original != nil && IThoughtsImportService.resources(from: original?["resources"]) == node.resources)
        set("cost-type", node.rollupEnabled ? "2" : nil,
            unchangedIf: original != nil && (original?["cost-type"] == "2") == node.rollupEnabled)

        // image
        let originalImagePath = original.flatMap { document.imagePath(forTopicAttributes: $0) }
        let originalImage = originalImagePath.flatMap { document.file(named: $0) }
        if let data = node.style.imageData {
            if data != originalImage {
                let attID = UUID().uuidString
                let name = TreeWriter.safeFileName(node.style.imageName ?? "image.png")
                document.setFile(data, named: "assets/\(attID)/\(name)")
                a["att-id"] = attID
                a["att-name"] = name
            }
        } else if originalImage != nil {
            a["att-id"] = nil
            a["att-name"] = nil
            a["image-width"] = nil
        }
        if node.style.imageData != nil {
            let originalWidth = original?["image-width"].flatMap(Double.init)
            set("image-width", node.style.imageWidth.map { ItmzFormat.formatNumber($0) },
                unchangedIf: original != nil && originalWidth == node.style.imageWidth)
        }

        // summary
        if let range = summaryRange[node.id],
           let first = topicUUIDs[range.first], let last = topicUUIDs[range.last] {
            let same = original?["summary1"]?.lowercased() == first.lowercased()
                && original?["summary2"]?.lowercased() == last.lowercased()
            if !same {
                a["summary1"] = first
                a["summary2"] = last
            }
        } else {
            a["summary1"] = nil
            a["summary2"] = nil
        }
        return a
    }

    static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? "image.png" : cleaned
    }

    // MARK: Relationships

    mutating func relationshipAttributes(_ relationships: [CanvasRelationship]) -> [[String: String]] {
        var originals: [String: [String: String]] = [:]
        if session != nil {
            for (position, attributes) in document.relationshipAttributes().enumerated() {
                let key = ItmzDocument.relationshipKey(attributes, index: position)
                if originals[key] == nil {
                    originals[key] = attributes
                }
            }
        }

        var result: [[String: String]] = []
        for relationship in relationships {
            guard let from = topicUUIDs[relationship.fromNodeID], let to = topicUUIDs[relationship.toNodeID] else {
                continue
            }
            let uuid = session?.relationshipUUIDs[relationship.id] ?? relationship.id.uuidString
            relationshipUUIDs[relationship.id] = uuid
            let original = originals[uuid]

            var a: [String: String] = [:]
            for key in ItmzDocument.managedRelationshipAttributes {
                a[key] = original?[key]
            }
            func set(_ key: String, _ value: String?, unchangedIf same: Bool) {
                guard !same else {
                    return
                }
                a[key] = value.flatMap { $0.isEmpty ? nil : $0 }
            }
            a["uuid"] = uuid
            set("end1-uuid", from, unchangedIf: original?["end1-uuid"]?.lowercased() == from.lowercased())
            set("end2-uuid", to, unchangedIf: original?["end2-uuid"]?.lowercased() == to.lowercased())
            set("type", relationship.lineStyle.rawValue,
                unchangedIf: original != nil && (original?["type"].flatMap(RelationshipLineStyle.init(rawValue:)) ?? .curved) == relationship.lineStyle)
            set("end1-style", relationship.startStyle.rawValue,
                unchangedIf: original != nil && (original?["end1-style"].flatMap(RelationshipEndStyle.init(rawValue:)) ?? .none) == relationship.startStyle)
            set("end2-style", relationship.endStyle.rawValue,
                unchangedIf: original != nil && (original?["end2-style"].flatMap(RelationshipEndStyle.init(rawValue:)) ?? .none) == relationship.endStyle)
            set("color", relationship.colorHex,
                unchangedIf: original != nil && original?["color"].flatMap { TopicColor.normalizedHex($0) } == relationship.colorHex)
            set("dashed", relationship.isDashed ? "1" : nil,
                unchangedIf: original != nil && (original?["dashed"] == "1") == relationship.isDashed)
            set("center-text", relationship.label,
                unchangedIf: original != nil && (original?["center-text"] ?? "") == relationship.label)
            result.append(a)
        }
        return result
    }
}
