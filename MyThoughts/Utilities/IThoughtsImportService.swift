import Foundation
import CoreGraphics

struct IThoughtsImportResult {
    var nodes: [CanvasNode]
    var connections: [CanvasConnection]
    var rootNodeIDs: [CanvasNode.ID]
}

enum IThoughtsImportError: LocalizedError {
    case unzipFailed
    case missingXML
    case unreadableXML
    case unsupportedStructure
    case emptyMap

    var errorDescription: String? {
        switch self {
        case .unzipFailed:
            "The selected .itmz file could not be unpacked."
        case .missingXML:
            "No map XML file was found in the .itmz archive."
        case .unreadableXML:
            "The iThoughts XML file could not be read."
        case .unsupportedStructure:
            "The iThoughts XML structure was not recognized."
        case .emptyMap:
            "The iThoughts file did not contain any importable topics."
        }
    }
}

enum IThoughtsImportService {
    private static let defaultNodeSize = CGSize(width: 160, height: 48)
    private static let horizontalSpacing: CGFloat = 220
    private static let verticalSpacing: CGFloat = 90

    static func `import`(from url: URL) throws -> IThoughtsImportResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyThoughts-iThoughts-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        try unzipITMZ(at: url, to: temporaryDirectory)
        let xmlURL = try findMapDataXML(in: temporaryDirectory)
        let parsedRoots = try parseIThoughtsXML(at: xmlURL)

        guard !parsedRoots.isEmpty else {
            throw IThoughtsImportError.emptyMap
        }

        return convertToCanvasNodes(parsedRoots)
    }

    private static func unzipITMZ(at sourceURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", sourceURL.path, destinationURL.path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("iThoughts import: failed to launch ditto: \(error).")
            throw IThoughtsImportError.unzipFailed
        }

        guard process.terminationStatus == 0 else {
            print("iThoughts import: ditto exited with status \(process.terminationStatus).")
            throw IThoughtsImportError.unzipFailed
        }
    }

    private static func findMapDataXML(in directoryURL: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw IThoughtsImportError.missingXML
        }

        var xmlCandidates: [URL] = []

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }

            let lowerName = fileURL.lastPathComponent.lowercased()
            if lowerName == "mapdata.xml" {
                return fileURL
            }

            if fileURL.pathExtension.lowercased() == "xml" {
                xmlCandidates.append(fileURL)
            }
        }

        if let likelyMapXML = xmlCandidates.first(where: {
            $0.lastPathComponent.lowercased().contains("map")
        }) {
            return likelyMapXML
        }

        guard let firstXML = xmlCandidates.first else {
            throw IThoughtsImportError.missingXML
        }

        return firstXML
    }

    private static func parseIThoughtsXML(at xmlURL: URL) throws -> [ParsedIThoughtsTopic] {
        guard let parser = XMLParser(contentsOf: xmlURL) else {
            throw IThoughtsImportError.unreadableXML
        }

        let delegate = IThoughtsXMLParserDelegate()
        parser.delegate = delegate

        guard parser.parse() else {
            print("iThoughts import: XML parse failed: \(parser.parserError?.localizedDescription ?? "Unknown error").")
            throw IThoughtsImportError.unreadableXML
        }

        guard delegate.didRecognizeTopicStructure else {
            throw IThoughtsImportError.unsupportedStructure
        }

        return delegate.rootTopics
    }

    private static func convertToCanvasNodes(_ rootTopics: [ParsedIThoughtsTopic]) -> IThoughtsImportResult {
        var nodes: [CanvasNode] = []
        var connections: [CanvasConnection] = []
        var rootNodeIDs: [CanvasNode.ID] = []
        var leafIndex = 0

        for (rootIndex, rootTopic) in rootTopics.enumerated() {
            let rootID = appendTopic(
                rootTopic,
                parentID: nil,
                depth: 0,
                sortIndex: Double(rootIndex),
                leafIndex: &leafIndex,
                nodes: &nodes,
                connections: &connections
            )
            rootNodeIDs.append(rootID)
        }

        return IThoughtsImportResult(
            nodes: nodes,
            connections: connections,
            rootNodeIDs: rootNodeIDs
        )
    }

    @discardableResult
    private static func appendTopic(
        _ topic: ParsedIThoughtsTopic,
        parentID: CanvasNode.ID?,
        depth: Int,
        sortIndex: Double,
        leafIndex: inout Int,
        nodes: inout [CanvasNode],
        connections: inout [CanvasConnection]
    ) -> CanvasNode.ID {
        let nodeID = UUID()
        let childStartIndex = nodes.count
        let title = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = topic.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let links = topic.links
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
            .map { NodeLink(title: $0, urlString: $0) }

        nodes.append(
            CanvasNode(
                id: nodeID,
                title: title.isEmpty ? "Untitled" : title,
                body: body,
                links: links,
                attachmentLinks: links.map(\.urlString),
                x: CGFloat(depth) * horizontalSpacing,
                y: CGFloat(leafIndex) * verticalSpacing,
                width: defaultNodeSize.width,
                height: defaultNodeSize.height,
                sortIndex: sortIndex,
                parentID: parentID,
                isCollapsed: false
            )
        )

        if let parentID {
            connections.append(
                CanvasConnection(
                    id: UUID(),
                    fromNodeID: parentID,
                    toNodeID: nodeID,
                    type: "parentChild"
                )
            )
        }

        if topic.children.isEmpty {
            leafIndex += 1
        } else {
            let startingLeafIndex = leafIndex
            for (childIndex, childTopic) in topic.children.enumerated() {
                appendTopic(
                    childTopic,
                    parentID: nodeID,
                    depth: depth + 1,
                    sortIndex: Double(childIndex),
                    leafIndex: &leafIndex,
                    nodes: &nodes,
                    connections: &connections
                )
            }

            let endingLeafIndex = max(startingLeafIndex, leafIndex - 1)
            let centerY = CGFloat(startingLeafIndex + endingLeafIndex) * verticalSpacing / 2
            if let nodeIndex = nodes.firstIndex(where: { $0.id == nodeID }) {
                nodes[nodeIndex].y = centerY
            }

            for childOffset in childStartIndex..<nodes.count where nodes[childOffset].parentID == nodeID {
                nodes[childOffset].sortIndex = Double(childOffset - childStartIndex)
            }
        }

        return nodeID
    }
}

private final class ParsedIThoughtsTopic {
    var title: String
    var body: String
    var links: [String]
    var children: [ParsedIThoughtsTopic]

    init(title: String = "", body: String = "", links: [String] = []) {
        self.title = title
        self.body = body
        self.links = links
        self.children = []
    }
}

private final class IThoughtsXMLParserDelegate: NSObject, XMLParserDelegate {
    enum CaptureKind {
        case title
        case note
        case link
    }

    struct TextCapture {
        var kind: CaptureKind
        weak var topic: ParsedIThoughtsTopic?
        var elementName: String
    }

    private(set) var rootTopics: [ParsedIThoughtsTopic] = []
    private(set) var didRecognizeTopicStructure = false

    private var topicStack: [ParsedIThoughtsTopic] = []
    private var textCapture: TextCapture?
    private var textBuffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let lowerName = elementName.lowercased()

        if isTopicElement(lowerName, attributes: attributeDict) {
            didRecognizeTopicStructure = true

            let topic = ParsedIThoughtsTopic(
                title: firstAttributeValue(in: attributeDict, matching: titleAttributeNames),
                body: firstAttributeValue(in: attributeDict, matching: noteAttributeNames),
                links: links(in: attributeDict.values)
            )

            if let parent = topicStack.last {
                parent.children.append(topic)
            } else {
                rootTopics.append(topic)
            }

            topicStack.append(topic)
            return
        }

        guard let currentTopic = topicStack.last else {
            return
        }

        currentTopic.links.append(contentsOf: links(in: attributeDict.values))

        if isTitleElement(lowerName) {
            beginTextCapture(.title, topic: currentTopic, elementName: lowerName)
        } else if isNoteElement(lowerName) {
            beginTextCapture(.note, topic: currentTopic, elementName: lowerName)
        } else if isLinkElement(lowerName) {
            beginTextCapture(.link, topic: currentTopic, elementName: lowerName)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard textCapture != nil else {
            return
        }

        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let lowerName = elementName.lowercased()

        if let capture = textCapture,
           capture.elementName == lowerName {
            applyCapturedText(capture)
            textCapture = nil
            textBuffer = ""
        }

        if isTopicElementName(lowerName), !topicStack.isEmpty {
            topicStack.removeLast()
        }
    }

    private func beginTextCapture(_ kind: CaptureKind, topic: ParsedIThoughtsTopic, elementName: String) {
        textCapture = TextCapture(kind: kind, topic: topic, elementName: elementName)
        textBuffer = ""
    }

    private func applyCapturedText(_ capture: TextCapture) {
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let topic = capture.topic else {
            return
        }

        switch capture.kind {
        case .title:
            if topic.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                topic.title = text
            }
        case .note:
            if topic.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                topic.body = text
            } else {
                topic.body += "\n\n\(text)"
            }
        case .link:
            topic.links.append(contentsOf: links(in: [text]))
        }
    }

    private func isTopicElement(_ lowerName: String, attributes: [String: String]) -> Bool {
        if isTopicElementName(lowerName) {
            return true
        }

        if lowerName.contains("topic") {
            return attributes.keys.contains { key in
                titleAttributeNames.contains(key.lowercased()) ||
                key.lowercased().contains("text") ||
                key.lowercased().contains("title")
            }
        }

        return false
    }

    private func isTopicElementName(_ lowerName: String) -> Bool {
        ["topic", "node", "item"].contains(lowerName)
    }

    private func isTitleElement(_ lowerName: String) -> Bool {
        ["title", "text", "label", "name"].contains(lowerName) ||
        lowerName.hasSuffix("title") ||
        lowerName.hasSuffix("text")
    }

    private func isNoteElement(_ lowerName: String) -> Bool {
        ["note", "notes", "comment", "body"].contains(lowerName) ||
        lowerName.contains("note")
    }

    private func isLinkElement(_ lowerName: String) -> Bool {
        ["link", "url", "hyperlink"].contains(lowerName) ||
        lowerName.contains("link") ||
        lowerName.contains("url")
    }

    private var titleAttributeNames: Set<String> {
        ["text", "title", "name", "label", "topic", "content"]
    }

    private var noteAttributeNames: Set<String> {
        ["note", "notes", "comment", "body"]
    }

    private func firstAttributeValue(in attributes: [String: String], matching names: Set<String>) -> String {
        for (key, value) in attributes {
            let lowerKey = key.lowercased()
            if names.contains(lowerKey) || names.contains(where: { lowerKey.hasSuffix($0) }) {
                return value
            }
        }

        return ""
    }

    private func links(in values: Dictionary<String, String>.Values) -> [String] {
        links(in: Array(values))
    }

    private func links(in values: [String]) -> [String] {
        values.flatMap { value in
            value
                .components(separatedBy: .whitespacesAndNewlines)
                .map { token in
                    token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>(),;"))
                }
                .filter { token in
                    token.lowercased().hasPrefix("http://") ||
                    token.lowercased().hasPrefix("https://")
                }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
