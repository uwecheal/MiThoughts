import CoreGraphics
import Foundation

/// Markdown, OPML and FreeMind/Freeplane (.mm) export and import.
/// Export works on any map (not only opened .itmz files); the conventions follow
/// itmz-studio's exporters so files from both tools look the same.
enum OutlineFormat: String, CaseIterable, Identifiable {
    case markdown
    case opml
    case freemind

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .opml: "opml"
        case .freemind: "mm"
        }
    }

    var label: String {
        switch self {
        case .markdown: "Markdown"
        case .opml: "OPML"
        case .freemind: "FreeMind / Freeplane"
        }
    }

    static let importExtensions = ["md", "markdown", "opml", "mm"]

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "md", "markdown": self = .markdown
        case "opml": self = .opml
        case "mm": self = .freemind
        default: return nil
        }
    }
}

/// A topic as plain outline data (the common shape of all three formats).
struct OutlineTopic {
    var title: String
    var note = ""
    var link = ""
    var colorHex: String?
    var isCollapsed = false
    var marker: NodeMarker = .none
    var progress = 0
    var isDone = false
    var resources: [String] = []
    /// Identifier used by relationships inside the file (FreeMind `ID`).
    var sourceID: String?
    var children: [OutlineTopic] = []
}

struct OutlineImportResult {
    var nodes: [CanvasNode]
    var connections: [CanvasConnection]
    var relationships: [CanvasRelationship]
    var rootNodeID: CanvasNode.ID
    var topicCount: Int
}

enum OutlineFormatError: LocalizedError {
    case unreadable(String)
    case empty

    var errorDescription: String? {
        switch self {
        case let .unreadable(reason): "The file could not be read: \(reason)"
        case .empty: "The file does not contain any topics."
        }
    }
}

enum OutlineFormatService {
    // MARK: - Export

    /// Writes the map. Topic images (Markdown, FreeMind) go to `<name>.assets/` next to the file.
    /// Returns every file written.
    @discardableResult
    static func export(
        _ format: OutlineFormat,
        nodes: [CanvasNode],
        relationships: [CanvasRelationship],
        title: String,
        to url: URL
    ) throws -> [URL] {
        let tree = Tree(nodes: nodes)
        let assets = AssetWriter(target: url)
        let data: Data
        switch format {
        case .markdown:
            data = Data(markdown(tree: tree, relationships: relationships, assets: assets).utf8)
        case .opml:
            data = Data(opml(tree: tree, title: title).utf8)
        case .freemind:
            data = Data(freemind(tree: tree, relationships: relationships, title: title, assets: assets).utf8)
        }
        // In the App Sandbox only the chosen file is writable, so the images folder
        // next to it may be refused; the outline itself is still written.
        try? assets.flush()
        try data.write(to: url, options: .atomic)
        return [url] + assets.written
    }

    static func markdown(nodes: [CanvasNode], relationships: [CanvasRelationship]) -> String {
        markdown(tree: Tree(nodes: nodes), relationships: relationships, assets: nil)
    }

    private static let headingLevels = 2

    private static func markdown(tree: Tree, relationships: [CanvasRelationship], assets: AssetWriter?) -> String {
        var out: [String] = []

        func emit(_ node: CanvasNode, depth: Int) {
            let icon = node.marker.emoji.map { "\($0) " } ?? ""
            var indent = ""
            if depth < headingLevels {
                out.append(String(repeating: "#", count: depth + 1) + " " + icon + oneLine(node.title))
                out.append("")
            } else {
                indent = String(repeating: "    ", count: depth - headingLevels)
                let lines = node.title.isEmpty ? ["·"] : node.title.components(separatedBy: "\n")
                out.append("\(indent)- \(icon)\(lines[0])")
                for line in lines.dropFirst() {
                    out.append(line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\(indent)  \(line)")
                }
                indent += "  "
            }

            var extras: [String] = []
            if let data = node.style.imageData, let assets {
                extras.append("![](\(assets.add(data, name: node.style.imageName ?? "image.png", id: node.id)))")
            }
            if let link = node.links.first {
                extras.append(link.title == link.urlString || link.title.isEmpty
                              ? "Link: <\(link.urlString)>"
                              : "Link: [\(link.title)](\(link.urlString))")
            }
            let task = taskSummary(node)
            if !task.isEmpty {
                extras.append("Task: \(task)")
            }
            if !extras.isEmpty {
                if depth >= headingLevels {
                    out.append("")
                }
                out += extras.map { indent + $0 + "  " }
                out.append("")
            }
            if !node.body.isEmpty {
                if depth >= headingLevels && extras.isEmpty {
                    out.append("")
                }
                // A note with its own headings/lists/"Link:" lines is quoted so it cannot be read back as topics.
                let noteLines = node.body.components(separatedBy: "\n")
                let quote = noteLines.contains { looksStructural($0.trimmingCharacters(in: .whitespaces)) }
                for line in noteLines {
                    if quote {
                        out.append(indent + (line.isEmpty ? ">" : "> " + line))
                    } else {
                        out.append(line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : indent + line)
                    }
                }
                out.append("")
            }
            for child in tree.children(of: node.id) {
                emit(child, depth: depth + 1)
            }
            if depth < headingLevels, out.last != "" {
                out.append("")
            }
        }

        for root in tree.roots {
            emit(root, depth: 0)
        }

        let live = relationships.filter { tree.byID[$0.fromNodeID] != nil && tree.byID[$0.toNodeID] != nil }
        if !live.isEmpty {
            out += ["", "## Relationships", ""]
            for relationship in live {
                let from = oneLine(tree.byID[relationship.fromNodeID]?.title ?? "?")
                let to = oneLine(tree.byID[relationship.toNodeID]?.title ?? "?")
                let label = relationship.label.isEmpty ? "" : " — \(relationship.label)"
                out.append("- \(from) → \(to)\(label)")
            }
        }

        var text = out.joined(separator: "\n")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func opml(tree: Tree, title: String) -> String {
        var out = ["<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<opml version=\"2.0\">", "  <head>",
                   "    <title>\(xml(title))</title>",
                   "    <dateModified>\(rfc822.string(from: Date()))</dateModified>",
                   "  </head>", "  <body>"]

        func emit(_ node: CanvasNode, level: Int) {
            var attributes = [("text", node.title)]
            if !node.body.isEmpty {
                attributes.append(("_note", node.body))
            }
            if let link = node.links.first {
                attributes.append(("type", "link"))
                attributes.append(("url", link.urlString))
            }
            if let color = node.style.colorHex {
                attributes.append(("_itmz_color", color))
            }
            if let icon = IThoughtsImportService.icon(for: node.marker) {
                attributes.append(("_itmz_icon1", icon))
            }
            if node.isCollapsed {
                attributes.append(("_itmz_folded", "1"))
            }
            if !node.resources.isEmpty {
                attributes.append(("_itmz_resources", node.resources.joined(separator: ", ")))
            }
            if node.completedAt != nil || node.progress > 0 {
                attributes.append(("_itmz_task_progress", node.completedAt != nil ? "101" : String(node.progress)))
            }
            let pad = String(repeating: "  ", count: level)
            let head = pad + "<outline " + attributes.map { "\($0.0)=\"\(xml($0.1))\"" }.joined(separator: " ")
            let children = tree.children(of: node.id)
            if children.isEmpty {
                out.append(head + " />")
            } else {
                out.append(head + ">")
                children.forEach { emit($0, level: level + 1) }
                out.append(pad + "</outline>")
            }
        }

        tree.roots.forEach { emit($0, level: 2) }
        out += ["  </body>", "</opml>"]
        return out.joined(separator: "\n") + "\n"
    }

    private static func freemind(tree: Tree, relationships: [CanvasRelationship], title: String, assets: AssetWriter?) -> String {
        var out = ["<map version=\"freeplane 1.9.13\">"]
        let outgoing = Dictionary(grouping: relationships.filter { tree.byID[$0.toNodeID] != nil }, by: \.fromNodeID)

        func emit(_ node: CanvasNode, depth: Int, parentCenterX: CGFloat?) {
            let pad = String(repeating: " ", count: depth + 1)
            var attributes = [("TEXT", node.title), ("ID", freemindID(node.id))]
            if depth == 1, let parentCenterX {
                attributes.append(("POSITION", node.x + node.width / 2 < parentCenterX ? "left" : "right"))
            }
            if node.isCollapsed {
                attributes.append(("FOLDED", "true"))
            }
            if let color = node.style.colorHex {
                attributes.append(("BACKGROUND_COLOR", "#" + color))
            }
            if let link = node.links.first {
                attributes.append(("LINK", link.urlString))
            }
            out.append(pad + "<node " + attributes.map { "\($0.0)=\"\(xml($0.1))\"" }.joined(separator: " ") + ">")
            if let icon = node.marker.freemindIcon {
                out.append(pad + " <icon BUILTIN=\"\(icon)\" />")
            }
            if let data = node.style.imageData, let assets {
                let path = assets.add(data, name: node.style.imageName ?? "image.png", id: node.id)
                out.append(pad + " <hook NAME=\"ExternalObject\" URI=\"\(xml(path))\" />")
            }
            if !node.body.isEmpty {
                let paragraphs = node.body.components(separatedBy: "\n\n").map {
                    "<p>" + xml($0, escapeQuotes: false).replacingOccurrences(of: "\n", with: "<br/>") + "</p>"
                }
                out.append(pad + " <richcontent TYPE=\"NOTE\"><html><head></head><body>"
                           + paragraphs.joined() + "</body></html></richcontent>")
            }
            for relationship in outgoing[node.id] ?? [] {
                var link = [("DESTINATION", freemindID(relationship.toNodeID)),
                            ("STARTARROW", relationship.startStyle == .arrow ? "Default" : "None"),
                            ("ENDARROW", relationship.endStyle == .arrow ? "Default" : "None")]
                if let color = relationship.colorHex {
                    link.append(("COLOR", "#" + color))
                }
                if !relationship.label.isEmpty {
                    link.append(("MIDDLE_LABEL", relationship.label))
                }
                out.append(pad + " <arrowlink " + link.map { "\($0.0)=\"\(xml($0.1))\"" }.joined(separator: " ") + " />")
            }
            let center = node.x + node.width / 2
            tree.children(of: node.id).forEach { emit($0, depth: depth + 1, parentCenterX: center) }
            out.append(pad + "</node>")
        }

        if tree.roots.count == 1, let root = tree.roots.first {
            emit(root, depth: 0, parentCenterX: nil)
        } else {
            // FreeMind needs exactly one root.
            out.append(" <node TEXT=\"\(xml(title))\" ID=\"ID_ROOT\">")
            let center = tree.roots.map { $0.x + $0.width / 2 }.reduce(0, +) / CGFloat(max(tree.roots.count, 1))
            tree.roots.forEach { emit($0, depth: 1, parentCenterX: center) }
            out.append(" </node>")
        }
        out.append("</map>")
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Import

    static func importFile(at url: URL) throws -> OutlineImportResult {
        guard let format = OutlineFormat(fileExtension: url.pathExtension) else {
            throw OutlineFormatError.unreadable("unknown file type .\(url.pathExtension)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OutlineFormatError.unreadable(error.localizedDescription)
        }
        let title = url.deletingPathExtension().lastPathComponent
        switch format {
        case .markdown:
            return try build(parseMarkdown(String(decoding: data, as: UTF8.self)), links: [], title: title)
        case .opml:
            return try build(OPMLParser.parse(data), links: [], title: title)
        case .freemind:
            let parsed = try FreeMindParser.parse(data)
            return try build(parsed.topics, links: parsed.links, title: title)
        }
    }

    static func parseMarkdown(_ text: String) -> [OutlineTopic] {
        // A stack of (level, path) where headings use levels 0...5 and bullets 100 + indent.
        var roots: [OutlineTopic] = []
        var stack: [(level: Int, index: [Int])] = []
        var noteTarget: [Int]?
        var noteLines: [String] = []
        var inRelationships = false
        /// Right after a bullet, indented non-blank lines continue its (multi-line) title.
        var continuesTitle = false

        func topic(at path: [Int]) -> OutlineTopic {
            var current = roots[path[0]]
            for index in path.dropFirst() {
                current = current.children[index]
            }
            return current
        }
        func modify(_ path: [Int], _ change: (inout OutlineTopic) -> Void) {
            func walk(_ topics: inout [OutlineTopic], _ rest: ArraySlice<Int>) {
                guard let first = rest.first else {
                    return
                }
                if rest.count == 1 {
                    change(&topics[first])
                } else {
                    walk(&topics[first].children, rest.dropFirst())
                }
            }
            walk(&roots, path[...])
        }
        func flushNote() {
            guard let target = noteTarget else {
                noteLines = []
                return
            }
            var lines = noteLines
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            var note: [String] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Link: ") {
                    let value = String(trimmed.dropFirst(6))
                    let url = value.hasPrefix("<") ? String(value.dropFirst().prefix { $0 != ">" })
                        : (value.range(of: "](").map { String(value[$0.upperBound...].prefix { $0 != ")" }) } ?? value)
                    modify(target) { $0.link = url }
                } else if trimmed.hasPrefix("Task: ") {
                    let summary = trimmed.dropFirst(6)
                    modify(target) { topic in
                        if summary.hasPrefix("done") {
                            topic.isDone = true
                        } else if let percent = Int(summary.prefix { $0.isNumber }) {
                            topic.progress = percent
                        }
                    }
                } else if !(trimmed.hasPrefix("![](") && trimmed.hasSuffix(")")) {
                    if trimmed == ">" {
                        note.append("")
                    } else if trimmed.hasPrefix("> ") {
                        note.append(String(trimmed.dropFirst(2)))
                    } else {
                        note.append(line)
                    }
                }
            }
            let joined = note.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty {
                modify(target) { $0.note = $0.note.isEmpty ? joined : $0.note + "\n\n" + joined }
            }
            noteLines = []
        }
        func add(_ new: OutlineTopic, level: Int) {
            flushNote()
            while let last = stack.last, last.level >= level {
                stack.removeLast()
            }
            let path: [Int]
            if let parent = stack.last {
                let count = topic(at: parent.index).children.count
                modify(parent.index) { $0.children.append(new) }
                path = parent.index + [count]
            } else {
                roots.append(new)
                path = [roots.count - 1]
            }
            stack.append((level, path))
            noteTarget = path
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == ">" || trimmed.hasPrefix("> ") {
                continuesTitle = false
                noteLines.append(line)
                continue
            }
            if let hashes = headingLevel(trimmed) {
                let title = String(trimmed.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces)
                if hashes == 2 && title == "Relationships" {
                    flushNote()
                    inRelationships = true
                    noteTarget = nil
                    continue
                }
                inRelationships = false
                add(makeTopic(title), level: hashes - 1)
                continuesTitle = false
                continue
            }
            if inRelationships {
                continue
            }
            if trimmed.isEmpty {
                continuesTitle = false
            } else if continuesTitle, let target = noteTarget, bulletContent(trimmed) == nil {
                modify(target) { $0.title += "\n" + trimmed }
                continue
            }
            let leading = line.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if let bullet = bulletContent(trimmed) {
                add(makeTopic(bullet), level: 100 + leading)
                continuesTitle = true
                continue
            }
            continuesTitle = false
            noteLines.append(String(line.dropFirst(min(leading, bulletIndent(stack: stack)))))
        }
        flushNote()
        return roots
    }

    private static func bulletIndent(stack: [(level: Int, index: [Int])]) -> Int {
        guard let level = stack.last?.level, level >= 100 else {
            return 0
        }
        return level - 100 + 2
    }

    private static func looksStructural(_ line: String) -> Bool {
        headingLevel(line) != nil || bulletContent(line) != nil || line.hasPrefix(">")
            || line.hasPrefix("Link: ") || line.hasPrefix("Task: ") || line.hasPrefix("![](")
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else {
            return nil
        }
        return hashes
    }

    private static func bulletContent(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(2))
        }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
           line[line.index(after: dot)...].hasPrefix(" ") {
            return String(line[line.index(dot, offsetBy: 2)...])
        }
        return nil
    }

    /// Leading marker emoji and task checkboxes become markers.
    private static func makeTopic(_ raw: String) -> OutlineTopic {
        var text = raw
        var topic = OutlineTopic(title: "")
        if text.hasPrefix("[ ] ") {
            topic.marker = .task
            text.removeFirst(4)
        } else if text.lowercased().hasPrefix("[x] ") {
            topic.marker = .done
            topic.isDone = true
            text.removeFirst(4)
        }
        for marker in NodeMarker.allCases {
            if let emoji = marker.emoji, text.hasPrefix(emoji + " ") {
                topic.marker = marker
                text.removeFirst(emoji.count + 1)
                break
            }
        }
        topic.title = text == "·" ? "" : text
        return topic
    }

    /// Topics -> nodes, laid out as a tree to the right of the central topic.
    static func build(_ topics: [OutlineTopic], links: [(from: String, to: String, label: String, color: String?)], title: String) throws -> OutlineImportResult {
        guard !topics.isEmpty else {
            throw OutlineFormatError.empty
        }
        let rootTopic = topics.count == 1 ? topics[0] : OutlineTopic(title: title, children: topics)
        var nodes: [CanvasNode] = []
        var connections: [CanvasConnection] = []
        var idsBySource: [String: UUID] = [:]

        func add(_ topic: OutlineTopic, parentID: UUID?, sortIndex: Int) -> UUID {
            let id = UUID()
            if let source = topic.sourceID {
                idsBySource[source] = id
            }
            let size = IThoughtsImportService.estimatedSize(text: topic.title.isEmpty ? " " : topic.title, textWidth: nil)
            var links: [NodeLink] = []
            if !topic.link.isEmpty {
                links.append(NodeLink(title: topic.link, urlString: ItmzLinks.normalize(topic.link)))
            }
            nodes.append(CanvasNode(
                id: id,
                title: topic.title.isEmpty ? "Untitled" : topic.title,
                body: topic.note,
                progress: topic.isDone ? 100 : topic.progress,
                completedAt: topic.isDone ? Date() : nil,
                marker: topic.marker,
                links: links,
                x: 0, y: 0, width: size.width, height: size.height,
                sortIndex: Double(sortIndex),
                parentID: parentID,
                isCollapsed: topic.isCollapsed && !topic.children.isEmpty,
                style: TopicStyle(colorHex: topic.colorHex),
                resources: topic.resources
            ))
            if let parentID {
                connections.append(CanvasConnection(id: UUID(), fromNodeID: parentID, toNodeID: id, type: "parentChild"))
            }
            for (index, child) in topic.children.enumerated() {
                _ = add(child, parentID: id, sortIndex: index)
            }
            return id
        }

        let rootID = add(rootTopic, parentID: nil, sortIndex: 0)
        if let index = nodes.firstIndex(where: { $0.id == rootID }) {
            nodes[index].x = 80
            nodes[index].y = 80
        }
        nodes = MapLayoutService.layoutBranch(nodes: nodes, rootID: rootID, horizontalSpacing: 260, verticalSpacing: 56).nodes

        let relationships = links.compactMap { link -> CanvasRelationship? in
            guard let from = idsBySource[link.from], let to = idsBySource[link.to] else {
                return nil
            }
            return CanvasRelationship(fromNodeID: from, toNodeID: to, label: link.label, colorHex: link.color)
        }
        return OutlineImportResult(nodes: nodes, connections: connections, relationships: relationships,
                                   rootNodeID: rootID, topicCount: nodes.count)
    }

    // MARK: - Helpers

    private static func oneLine(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var line = line.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            return line.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return lines.isEmpty ? "·" : lines.joined(separator: " ")
    }

    private static func taskSummary(_ node: CanvasNode) -> String {
        var bits: [String] = []
        if node.completedAt != nil {
            bits.append("done")
        } else if node.progress > 0 {
            bits.append("\(node.progress)%")
        }
        if node.priority != .none {
            bits.append("priority \(node.priority.label.lowercased())")
        }
        if let start = node.startDate {
            bits.append("start " + shortDate.string(from: start))
        }
        if let due = node.dueDate {
            bits.append("due " + shortDate.string(from: due))
        }
        if node.effort > 0 {
            bits.append(String(format: "effort %.2fh", node.effort))
        }
        if !node.resources.isEmpty {
            bits.append("@" + node.resources.joined(separator: ", "))
        }
        if node.cost != 0 {
            bits.append("cost " + ItmzFormat.formatNumber(node.cost))
        }
        return bits.joined(separator: " · ")
    }

    private static func freemindID(_ id: UUID) -> String {
        "ID_" + id.uuidString.replacingOccurrences(of: "-", with: "_")
    }

    static func xml(_ value: String, escapeQuotes: Bool = true) -> String {
        var result = ""
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"" where escapeQuotes: result += "&quot;"
            case "\n" where escapeQuotes: result += "&#10;"
            case "\r": break
            default: result.append(character)
            }
        }
        return result
    }

    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}

// MARK: - Tree helper

private struct Tree {
    let byID: [UUID: CanvasNode]
    let roots: [CanvasNode]
    private let childrenByParent: [UUID: [CanvasNode]]

    init(nodes: [CanvasNode]) {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func ordered(_ list: [CanvasNode]) -> [CanvasNode] {
            list.sorted { $0.sortIndex == $1.sortIndex ? $0.y < $1.y : $0.sortIndex < $1.sortIndex }
        }
        self.byID = byID
        childrenByParent = Dictionary(grouping: nodes.filter { $0.parentID.map { byID[$0] != nil } ?? false }) { $0.parentID! }
            .mapValues(ordered)
        roots = ordered(nodes.filter { $0.parentID.map { byID[$0] == nil } ?? true })
    }

    func children(of id: UUID) -> [CanvasNode] {
        childrenByParent[id] ?? []
    }
}

/// Copies topic images to `<stem>.assets/` next to an exported file.
private final class AssetWriter {
    let folderName: String
    let folderURL: URL
    private var pending: [(URL, Data)] = []
    private(set) var written: [URL] = []

    init(target: URL) {
        folderName = target.deletingPathExtension().lastPathComponent + ".assets"
        folderURL = target.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
    }

    /// Returns the relative path to use in the exported file.
    func add(_ data: Data, name: String, id: UUID) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let relative = "\(id.uuidString.prefix(8))-\(safe)"
        pending.append((folderURL.appendingPathComponent(relative), data))
        let encoded = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
        return "\(folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folderName)/\(encoded)"
    }

    func flush() throws {
        guard !pending.isEmpty else {
            return
        }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        for (url, data) in pending {
            try data.write(to: url, options: .atomic)
            written.append(url)
        }
    }
}

// MARK: - Parsers

private final class OPMLParser: NSObject, XMLParserDelegate {
    private var stack: [OutlineTopic] = []
    private var roots: [OutlineTopic] = []
    private var inBody = false

    static func parse(_ data: Data) throws -> [OutlineTopic] {
        let delegate = OPMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw OutlineFormatError.unreadable(parser.parserError?.localizedDescription ?? "invalid OPML")
        }
        return delegate.roots
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "body" {
            inBody = true
        }
        guard inBody, name == "outline" else {
            return
        }
        var topic = OutlineTopic(title: attributes["text"] ?? attributes["title"] ?? "")
        topic.note = attributes["_note"] ?? ""
        topic.link = attributes["url"] ?? attributes["htmlUrl"] ?? attributes["xmlUrl"] ?? ""
        topic.colorHex = attributes["_itmz_color"].flatMap { TopicColor.normalizedHex($0) }
        topic.isCollapsed = attributes["_itmz_folded"] == "1"
        topic.resources = IThoughtsImportService.resources(from: attributes["_itmz_resources"])
        if let icon = attributes["_itmz_icon1"] {
            topic.marker = IThoughtsImportService.marker(forIcon: icon) ?? .none
        }
        if let progress = attributes["_itmz_task_progress"].flatMap(Double.init) {
            topic.isDone = progress > 100
            topic.progress = Int(min(max(progress, 0), 100))
        }
        stack.append(topic)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "body" {
            inBody = false
        }
        guard inBody, name == "outline", let topic = stack.popLast() else {
            return
        }
        if stack.isEmpty {
            roots.append(topic)
        } else {
            stack[stack.count - 1].children.append(topic)
        }
    }
}

private final class FreeMindParser: NSObject, XMLParserDelegate {
    private var stack: [OutlineTopic] = []
    private var roots: [OutlineTopic] = []
    private var links: [(from: String, to: String, label: String, color: String?)] = []
    private var noteDepth = 0
    private var noteText = ""

    static func parse(_ data: Data) throws -> (topics: [OutlineTopic], links: [(from: String, to: String, label: String, color: String?)]) {
        let delegate = FreeMindParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw OutlineFormatError.unreadable(parser.parserError?.localizedDescription ?? "invalid FreeMind file")
        }
        return (delegate.roots, delegate.links)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if noteDepth > 0 {
            noteDepth += 1
            if ["p", "br", "li", "div"].contains(name.lowercased()), !noteText.isEmpty {
                noteText += name.lowercased() == "br" ? "\n" : "\n\n"
            }
            return
        }
        switch name {
        case "node":
            var topic = OutlineTopic(title: attributes["TEXT"] ?? "")
            topic.sourceID = attributes["ID"]
            topic.isCollapsed = attributes["FOLDED"] == "true"
            topic.colorHex = attributes["BACKGROUND_COLOR"].flatMap { TopicColor.normalizedHex($0) }
            topic.link = attributes["LINK"] ?? ""
            stack.append(topic)
        case "icon":
            if let builtin = attributes["BUILTIN"], let marker = NodeMarker.fromFreemindIcon(builtin),
               !stack.isEmpty, stack[stack.count - 1].marker == .none {
                stack[stack.count - 1].marker = marker
            }
        case "richcontent":
            let type = attributes["TYPE"] ?? ""
            if type == "NOTE" || type == "DETAILS" || type == "NODE" {
                noteDepth = 1
                noteText = ""
                parserNoteType = type
            }
        case "arrowlink":
            if let from = stack.last?.sourceID, let destination = attributes["DESTINATION"] {
                links.append((from, destination, attributes["MIDDLE_LABEL"] ?? "",
                              attributes["COLOR"].flatMap { TopicColor.normalizedHex($0) }))
            }
        default:
            break
        }
    }

    private var parserNoteType = ""

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if noteDepth > 0 {
            noteText += string.replacingOccurrences(of: "\n", with: " ")
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if noteDepth > 0 {
            noteDepth -= 1
            if noteDepth == 0, !stack.isEmpty {
                let text = noteText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if parserNoteType == "NODE" {
                    if stack[stack.count - 1].title.isEmpty {
                        stack[stack.count - 1].title = text
                    }
                } else if !text.isEmpty {
                    let current = stack[stack.count - 1].note
                    stack[stack.count - 1].note = current.isEmpty ? text : current + "\n\n" + text
                }
            }
            return
        }
        guard name == "node", let topic = stack.popLast() else {
            return
        }
        if stack.isEmpty {
            roots.append(topic)
        } else {
            stack[stack.count - 1].children.append(topic)
        }
    }
}

// MARK: - Marker mappings

extension NodeMarker {
    var emoji: String? {
        switch self {
        case .none: nil
        case .idea: "💡"
        case .task: "☐"
        case .done: "✅"
        case .warning: "⚠️"
        case .question: "❓"
        case .star: "⭐"
        case .flag: "🚩"
        case .priority: "❗"
        }
    }

    var freemindIcon: String? {
        switch self {
        case .none: nil
        case .idea: "idea"
        case .task: "unchecked"
        case .done: "button_ok"
        case .warning: "messagebox_warning"
        case .question: "help"
        case .star: "bookmark"
        case .flag: "flag"
        case .priority: "full-1"
        }
    }

    static func fromFreemindIcon(_ name: String) -> NodeMarker? {
        switch name {
        case "idea": .idea
        case "unchecked": .task
        case "button_ok", "checked": .done
        case "messagebox_warning", "stop-sign": .warning
        case "help", "question": .question
        case "bookmark", "favorite", "star": .star
        case "flag", "flag-red", "flag-blue", "flag-green", "flag-orange", "flag-yellow": .flag
        default: name.hasPrefix("full-") ? .priority : nil
        }
    }
}
