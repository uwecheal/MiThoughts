import Foundation

/// Errors for opening/saving iThoughts maps.
enum ItmzError: LocalizedError, Equatable {
    case notAnItmzFile(String)
    case missingMapData
    case unexpectedRoot(String)
    case duplicateTopic(String)
    case emptyMap
    case noSaveLocation

    var errorDescription: String? {
        switch self {
        case let .notAnItmzFile(reason):
            return "Not an iThoughts file: \(reason)"
        case .missingMapData:
            return "The archive has no mapdata.xml, so it is not an iThoughts map."
        case let .unexpectedRoot(tag):
            return "Unexpected root element <\(tag)> in mapdata.xml."
        case let .duplicateTopic(uuid):
            return "Topic \(uuid) appears twice in the edited map."
        case .emptyMap:
            return "A map needs at least one topic."
        case .noSaveLocation:
            return "No file location to save to."
        }
    }
}

/// A topic as plain data, for converting to/from the app's own model.
/// `attributes` uses the original iThoughts attribute names (see Docs/ITMZ_FORMAT.md).
struct ItmzTopicNode: Equatable {
    var attributes: [String: String]
    var children: [ItmzTopicNode]

    var uuid: String { attributes["uuid"] ?? "" }

    init(attributes: [String: String], children: [ItmzTopicNode] = []) {
        self.attributes = attributes
        self.children = children
    }
}

/// What `ItmzDocument.apply(_:)` changed.
struct ItmzChangeReport: Equatable {
    var created = 0
    var changed = 0
    var moved = 0
    var deleted = 0
}

/// An opened .itmz file.
///
/// Design rule ("the DOM is the model"): editors change only `managedAttributes`
/// and the tree structure. Every other attribute, element and archive entry
/// (images, note attachments, style.xml, preview.png, ...) is carried through
/// untouched, which is what keeps saved files compatible with iThoughts.
final class ItmzDocument {
    /// Attributes an editor may change. Everything else is read-only.
    static let managedAttributes = ["text", "note", "link", "color", "icon1", "icon2", "folded", "position"]

    /// The wider set a full editor (MyThoughts) manages: style, task, image and summary fields.
    /// Callers must pass the original value for every key they did not change, or it is removed.
    static let extendedManagedAttributes = managedAttributes + [
        "shape", "text-size", "boundary", "floating",
        "task-progress", "task-start", "task-due", "task-priority", "task-effort", "cost", "cost-type", "resources",
        "att-id", "att-name", "image-width", "summary1", "summary2", "text-width"
    ]

    /// Relationship attributes an editor may change; others (e.g. `b-offset`) are kept.
    static let managedRelationshipAttributes = [
        "type", "end1-uuid", "end1-style", "end2-uuid", "end2-style", "color", "dashed", "center-text"
    ]

    private(set) var entryNames: [String]
    private(set) var files: [String: Data]
    private(set) var xml: ItmzXMLDocument
    private(set) var style: ItmzXMLElement?
    var fileURL: URL?
    /// Read from an iThoughts 3 `map.itm` archive and translated to the current
    /// format; it must be saved to a new file, never back over the original.
    private(set) var isLegacyFormat = false

    var root: ItmzXMLElement { xml.root }

    // MARK: Opening

    init(data: Data, fileURL: URL? = nil) throws {
        let entries: [ItmzZipEntry]
        do {
            entries = try ItmzZip.read(data)
        } catch {
            throw ItmzError.notAnItmzFile(error.localizedDescription)
        }
        var names: [String] = []
        var files: [String: Data] = [:]
        for entry in entries where files[entry.name] == nil {
            names.append(entry.name)
            files[entry.name] = entry.data
        }
        var isLegacy = false
        if files["mapdata.xml"] == nil, let legacy = files["map.itm"],
           let converted = try? ItmzLegacy.convert(mapItm: legacy) {
            // Saved as a current .itmz: mapdata.xml first, style.xml, and the old entry dropped.
            files["map.itm"] = nil
            files["mapdata.xml"] = converted.mapData
            if files["style.xml"] == nil {
                files["style.xml"] = converted.style
            }
            names = ["mapdata.xml", "style.xml"] + names.filter { $0 != "map.itm" && $0 != "mapdata.xml" && $0 != "style.xml" }
            isLegacy = true
        }
        guard let mapData = files["mapdata.xml"] else {
            throw ItmzError.missingMapData
        }
        let xml = try ItmzXMLDocument(data: mapData)
        guard xml.root.tag == "iThoughts" else {
            throw ItmzError.unexpectedRoot(xml.root.tag)
        }
        self.entryNames = names
        self.files = files
        self.xml = xml
        self.fileURL = fileURL
        self.isLegacyFormat = isLegacy
        if let styleData = files["style.xml"] {
            style = try? ItmzXMLDocument(data: styleData).root
        }
    }

    convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url), fileURL: url)
    }

    /// A new, empty map with one central topic, using iThoughts' default style.
    static func makeNew(title: String = "Central Topic", now: Date = Date()) -> ItmzDocument {
        let stamp = ItmzFormat.timestamp(now)
        let topic = ItmzXMLElement(tag: "topic", attributes: [
            .init(name: "uuid", value: ItmzFormat.newUUID()),
            .init(name: "position", value: "{0, 0}"),
            .init(name: "text", value: title),
            .init(name: "created", value: stamp),
            .init(name: "modified", value: stamp)
        ], text: "\n", tail: "\n")
        let topics = ItmzXMLElement(tag: "topics", children: [topic], text: "\n", tail: "")
        let relationships = ItmzXMLElement(tag: "relationships", text: "\n", tail: "\n")
        let root = ItmzXMLElement(tag: "iThoughts", attributes: [
            .init(name: "version", value: "4.0"),
            .init(name: "app", value: "com.toketaware.ithoughtsx"),
            .init(name: "app-version", value: "9.4"),
            .init(name: "modified", value: stamp),
            .init(name: "author", value: "MyThoughts"),
            .init(name: "system-version", value: "MyThoughts")
        ], children: [topics, relationships])

        let preferences = (try? PropertyListSerialization.data(
            fromPropertyList: ["HideCompletedTasks": false, "SnapToTopic": true],
            format: .xml, options: 0)) ?? Data()
        let manifest = (try? PropertyListSerialization.data(
            fromPropertyList: ["AppID": "com.toketaware.ithoughtsx", "AppVersion": "9.4"],
            format: .xml, options: 0)) ?? Data()

        let document = ItmzDocument(
            names: ["mapdata.xml", "style.xml", "manifest.plist", "preferences.plist"],
            files: [
                "mapdata.xml": ItmzXMLDocument(root: root).data(),
                "style.xml": Data(ItmzFormat.defaultStyleXML.utf8),
                "manifest.plist": manifest,
                "preferences.plist": preferences
            ],
            xml: ItmzXMLDocument(root: root)
        )
        document.refreshManifest(now: now)
        return document
    }

    private init(names: [String], files: [String: Data], xml: ItmzXMLDocument) {
        self.entryNames = names
        self.files = files
        self.xml = xml
        self.fileURL = nil
        if let styleData = files["style.xml"] {
            self.style = try? ItmzXMLDocument(data: styleData).root
        }
    }

    // MARK: Reading

    var topicsElement: ItmzXMLElement {
        if let topics = root.firstChild(named: "topics") {
            return topics
        }
        let topics = ItmzXMLElement(tag: "topics", text: "\n")
        root.children.insert(topics, at: 0)
        return topics
    }

    /// Top-level topics (normally one central topic).
    var topLevelTopics: [ItmzXMLElement] { topicsElement.children(named: "topic") }

    /// All topics in pre-order.
    var allTopics: [ItmzXMLElement] { topicsElement.descendants(named: "topic") }

    var relationships: [ItmzXMLElement] { root.firstChild(named: "relationships")?.children(named: "relationship") ?? [] }

    var groups: [ItmzXMLElement] { root.firstChild(named: "groups")?.children(named: "group") ?? [] }

    var title: String {
        let text = topLevelTopics.first?["text"] ?? ""
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = firstLine.drop { $0 == "#" || $0 == " " }
        return trimmed.isEmpty ? "Untitled" : String(trimmed)
    }

    /// Attachments: topic images (`assets/<att-id>/…`) and note files (`notes/<topic uuid>/…`).
    var attachmentNames: [String] { entryNames.filter { $0.hasPrefix("assets/") || $0.hasPrefix("notes/") } }

    func file(named name: String) -> Data? { files[name] }

    /// Archive path of a topic's image, or nil (att-name is sometimes missing).
    func imagePath(forTopicAttributes attributes: [String: String]) -> String? {
        guard let id = attributes["att-id"], !id.isEmpty else {
            return nil
        }
        if let name = attributes["att-name"], files["assets/\(id)/\(name)"] != nil {
            return "assets/\(id)/\(name)"
        }
        return entryNames.first { $0.hasPrefix("assets/\(id)/") }
    }

    /// The topic tree as plain data.
    func topicTree() -> [ItmzTopicNode] {
        func convert(_ element: ItmzXMLElement) -> ItmzTopicNode {
            ItmzTopicNode(attributes: element.attributeDictionary,
                          children: element.children(named: "topic").map(convert))
        }
        return topLevelTopics.map(convert)
    }

    /// Style for a depth: iThoughts levels inherit from the nearest defined level above.
    func styleValue(_ key: String, depth: Int) -> String? {
        guard let style else {
            return nil
        }
        let levels = style.children(named: "level")
        var level = depth
        while level >= 0 {
            if let element = levels.first(where: { $0["n"] == String(level) }),
               let value = element[key], !value.isEmpty {
                return value
            }
            level -= 1
        }
        return nil
    }

    // MARK: Editing

    /// Applies an edited topic tree (same shape as `topicTree()`).
    /// * known uuids: only `managedAttributes` are updated, all other attributes untouched;
    /// * unknown/empty uuids: new topics are created;
    /// * topics missing from `topics` are deleted, with dangling relationship/group/summary
    ///   references cleaned up;
    /// * order and parentage follow `topics`.
    @discardableResult
    func apply(_ topics: [ItmzTopicNode],
               managedKeys: [String] = ItmzDocument.managedAttributes,
               now: Date = Date()) throws -> ItmzChangeReport {
        guard !topics.isEmpty else {
            throw ItmzError.emptyMap
        }
        let stamp = ItmzFormat.timestamp(now)
        let bytesBefore = xml.data()
        var index: [String: ItmzXMLElement] = [:]
        var oldParent: [String: String] = [:]
        for element in allTopics {
            if let uuid = element["uuid"] {
                index[uuid] = element
            }
        }
        func recordParents(_ element: ItmzXMLElement, parent: String?) {
            for child in element.children(named: "topic") {
                if let uuid = child["uuid"] {
                    oldParent[uuid] = parent ?? ""
                    recordParents(child, parent: uuid)
                }
            }
        }
        recordParents(topicsElement, parent: nil)

        var seen = Set<String>()
        var report = ItmzChangeReport()

        func build(_ node: ItmzTopicNode, parent: String?) throws -> ItmzXMLElement {
            var uuid = node.uuid
            if uuid.isEmpty {
                uuid = ItmzFormat.newUUID()
            }
            guard !seen.contains(uuid) else {
                throw ItmzError.duplicateTopic(uuid)
            }
            seen.insert(uuid)

            var changed = false
            let element: ItmzXMLElement
            if let existing = index[uuid] {
                element = existing
                if oldParent[uuid] != (parent ?? "") {
                    report.moved += 1
                    changed = true
                }
            } else {
                element = ItmzXMLElement(tag: "topic", attributes: [
                    .init(name: "uuid", value: uuid),
                    .init(name: "position", value: node.attributes["position"] ?? "{0, 0}"),
                    .init(name: "created", value: stamp)
                ])
                report.created += 1
                changed = true
            }

            for key in managedKeys {
                let newValue = node.attributes[key]
                let oldValue = element[key]
                if key == "position" {
                    if let newValue, !newValue.isEmpty, !ItmzFormat.samePosition(newValue, oldValue) {
                        element[key] = newValue
                        changed = true
                    }
                } else if newValue == nil || newValue == "" {
                    if oldValue != nil {
                        element[key] = nil
                        changed = true
                    }
                } else if newValue != oldValue {
                    element[key] = newValue
                    changed = true
                }
            }

            if changed {
                element["modified"] = stamp
                if index[uuid] != nil {
                    report.changed += 1
                }
                ItmzDocument.canonicalAttributeOrder(element)
            }

            let kids = try node.children.map { try build($0, parent: uuid) }
            let others = element.children.filter { $0.tag != "topic" }
            element.children = kids + others
            element.text = "\n"
            for kid in kids {
                kid.tail = "\n"
            }
            return element
        }

        let built = try topics.map { try build($0, parent: nil) }
        let container = topicsElement
        container.children = built
        container.text = "\n"
        for element in built {
            element.tail = "\n"
        }
        report.deleted = Set(index.keys).subtracting(seen).count
        dropDanglingReferences(deleted: Set(index.keys).subtracting(seen))
        // Only a real change (content, order, structure) touches the map's timestamp and manifest,
        // so "open, don't edit, save" stays byte-identical.
        if xml.data() != bytesBefore {
            root["modified"] = stamp
            files["mapdata.xml"] = xml.data()
            refreshManifest(now: now)
        }
        return report
    }

    /// Replaces the relationship list. Known uuids keep every non-managed attribute
    /// (such as `b-offset`); new ones are created; missing ones are removed.
    /// Returns true when mapdata.xml changed.
    @discardableResult
    /// Identity of a `<relationship>`: its uuid, or — for the older lines iThoughts
    /// wrote without one — a stand-in made from its position among the lines.
    static func relationshipKey(_ attributes: [String: String], index: Int) -> String {
        if let uuid = attributes["uuid"], !uuid.isEmpty {
            return uuid
        }
        return "#rel\(index)"
    }

    func applyRelationships(_ relationships: [[String: String]], now: Date = Date()) -> Bool {
        let container: ItmzXMLElement
        if let existing = root.firstChild(named: "relationships") {
            container = existing
        } else if relationships.isEmpty {
            return false
        } else {
            container = ItmzXMLElement(tag: "relationships", text: "\n", tail: "\n")
            let insertIndex = (root.children.firstIndex { $0.tag == "topics" } ?? -1) + 1
            root.children.insert(container, at: insertIndex)
        }

        var index: [String: ItmzXMLElement] = [:]
        for (position, element) in container.children(named: "relationship").enumerated() {
            index[Self.relationshipKey(element.attributeDictionary, index: position)] = element
        }

        var changed = false
        var built: [ItmzXMLElement] = []
        var seen = Set<String>()
        for attributes in relationships {
            var uuid = attributes["uuid"] ?? ""
            if uuid.isEmpty || (uuid.hasPrefix("#rel") && index[uuid] == nil) {
                uuid = ItmzFormat.newUUID()
            }
            guard !seen.contains(uuid) else {
                continue
            }
            seen.insert(uuid)

            let element: ItmzXMLElement
            if let existing = index[uuid] {
                element = existing
            } else {
                element = ItmzXMLElement(tag: "relationship", attributes: [
                    .init(name: "type", value: attributes["type"] ?? "0"),
                    .init(name: "uuid", value: uuid)
                ])
                changed = true
            }
            for key in ItmzDocument.managedRelationshipAttributes {
                let newValue = attributes[key].flatMap { $0.isEmpty ? nil : $0 }
                if element[key] != newValue {
                    element[key] = newValue
                    changed = true
                }
            }
            element.tail = "\n"
            built.append(element)
        }

        let others = container.children.filter { $0.tag != "relationship" }
        if Set(index.keys) != seen {
            changed = true
        }
        if !changed && built.map({ $0["uuid"] }) == container.children(named: "relationship").map({ $0["uuid"] }) {
            return false
        }
        container.children = built + others
        container.text = "\n"
        root["modified"] = ItmzFormat.timestamp(now)
        files["mapdata.xml"] = xml.data()
        refreshManifest(now: now)
        return true
    }

    /// Adds, replaces (data != nil) or removes (data == nil) an archive entry such as `assets/<id>/<name>`.
    func setFile(_ data: Data?, named name: String) {
        guard name != "mapdata.xml" else {
            return
        }
        if let data {
            files[name] = data
            if !entryNames.contains(name) {
                entryNames.append(name)
            }
        } else {
            files[name] = nil
            entryNames.removeAll { $0 == name }
        }
    }

    /// Relationship attributes, in file order.
    func relationshipAttributes() -> [[String: String]] {
        relationships.map(\.attributeDictionary)
    }

    /// Removes references to topics deleted by this apply. References that were
    /// already dangling in the file are left alone, as iThoughts tolerates them.
    private func dropDanglingReferences(deleted: Set<String>) {
        let deletedLowercased = Set(deleted.map { $0.lowercased() })
        guard !deletedLowercased.isEmpty else {
            return
        }
        func isAlive(_ uuid: String?) -> Bool {
            guard let uuid else {
                return true
            }
            return !deletedLowercased.contains(uuid.lowercased())
        }

        if let relationships = root.firstChild(named: "relationships") {
            relationships.children.removeAll { element in
                element.tag == "relationship" && !(isAlive(element["end1-uuid"]) && isAlive(element["end2-uuid"]))
            }
        }

        if let groups = root.firstChild(named: "groups") {
            var keptGroups: [ItmzXMLElement] = []
            for group in groups.children {
                let memberAttributes = group.attributes.filter { ItmzDocument.isMemberAttribute($0.name) }
                guard group.tag == "group", !memberAttributes.isEmpty else {
                    keptGroups.append(group)
                    continue
                }
                let kept = memberAttributes.map(\.value).filter { isAlive($0) }
                if kept.count == memberAttributes.count {
                    keptGroups.append(group)
                    continue
                }
                guard !kept.isEmpty else {
                    continue
                }
                group.attributes.removeAll { ItmzDocument.isMemberAttribute($0.name) }
                for (offset, member) in kept.enumerated() {
                    group["member\(offset)"] = member
                }
                keptGroups.append(group)
            }
            groups.children = keptGroups
        }

        for topic in allTopics {
            let first = topic["summary1"]
            let last = topic["summary2"]
            if (first != nil && !isAlive(first)) || (last != nil && !isAlive(last)) {
                topic["summary1"] = nil
                topic["summary2"] = nil
            }
        }
    }

    static func isMemberAttribute(_ name: String) -> Bool {
        name.hasPrefix("member") && !name.dropFirst(6).isEmpty && name.dropFirst(6).allSatisfy(\.isNumber)
    }

    /// uuid/position/text first, created/modified last - like iThoughts.
    private static func canonicalAttributeOrder(_ element: ItmzXMLElement) {
        let head = ["uuid", "position", "text"]
        let tail = ["created", "modified"]
        var ordered: [ItmzXMLAttribute] = []
        for name in head {
            if let attribute = element.attributes.first(where: { $0.name == name }) {
                ordered.append(attribute)
            }
        }
        ordered += element.attributes.filter { !head.contains($0.name) && !tail.contains($0.name) }
        for name in tail {
            if let attribute = element.attributes.first(where: { $0.name == name }) {
                ordered.append(attribute)
            }
        }
        element.attributes = ordered
    }

    private func refreshManifest(now: Date) {
        var manifest: [String: Any] = [:]
        if let data = files["manifest.plist"],
           let decoded = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            manifest = decoded
        }
        let topics = allTopics
        let notes = topics.compactMap { $0["note"] }.filter { !$0.isEmpty }
        func words(_ text: String?) -> Int {
            (text ?? "").split(whereSeparator: { $0.isWhitespace }).count
        }
        manifest["Generated"] = now
        manifest["MapRevision"] = ItmzFormat.newUUID()
        manifest["TopicCount"] = topics.count
        manifest["TopicWordCount"] = topics.reduce(0) { $0 + words($1["text"]) }
        manifest["NoteCount"] = notes.count
        manifest["NoteWordCount"] = notes.reduce(0) { $0 + words($1) }
        if let data = try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0) {
            files["manifest.plist"] = data
            if !entryNames.contains("manifest.plist") {
                entryNames.append("manifest.plist")
            }
        }
    }

    // MARK: Saving

    /// mapdata.xml as iThoughts writes it (no XML declaration, iThoughts escaping).
    func mapDataBytes() -> Data { xml.data() }

    /// The complete .itmz archive. mapdata.xml stays the first entry.
    func archiveData(now: Date = Date()) throws -> Data {
        files["mapdata.xml"] = xml.data()
        var names = entryNames.filter { $0 != "mapdata.xml" }
        names.insert("mapdata.xml", at: 0)
        let entries = names.compactMap { name in files[name].map { ItmzZipEntry(name: name, data: $0) } }
        return try ItmzZip.write(entries, date: now)
    }

    /// Writes the archive atomically. If `backupDirectory` is given and the target
    /// exists, the old file is copied there first. Returns the backup URL, if any.
    @discardableResult
    func save(to url: URL? = nil, backupDirectory: URL? = nil, now: Date = Date()) throws -> URL? {
        guard let target = url ?? fileURL else {
            throw ItmzError.noSaveLocation
        }
        let data = try archiveData(now: now)
        _ = try ItmzDocument(data: data) // our own output must re-open

        var backupURL: URL?
        let fileManager = FileManager.default
        if let backupDirectory, fileManager.fileExists(atPath: target.path) {
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stem = target.deletingPathExtension().lastPathComponent
            let candidate = backupDirectory.appendingPathComponent("\(stem).\(formatter.string(from: now)).itmz")
            if fileManager.fileExists(atPath: candidate.path) {
                try fileManager.removeItem(at: candidate)
            }
            try fileManager.copyItem(at: target, to: candidate)
            backupURL = candidate
        }
        try data.write(to: target, options: .atomic)
        fileURL = target
        return backupURL
    }
}

// MARK: - Format helpers

enum ItmzFormat {
    /// "{x, y}": a topic's centre relative to its parent's centre (top-level: canvas coordinates).
    static func parsePosition(_ value: String?) -> (x: Double, y: Double) {
        guard let value else {
            return (0, 0)
        }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "{} \n\t"))
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
            return (0, 0)
        }
        return (x, y)
    }

    static func formatPosition(x: Double, y: Double) -> String {
        "{\(formatNumber(x)), \(formatNumber(y))}"
    }

    static func formatNumber(_ value: Double) -> String {
        if abs(value - value.rounded()) < 1e-6 {
            return String(Int(value.rounded()))
        }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    static func samePosition(_ a: String?, _ b: String?) -> Bool {
        let first = parsePosition(a)
        let second = parsePosition(b)
        return abs(first.x - second.x) < 0.01 && abs(first.y - second.y) < 0.01
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// iThoughts timestamps: local time, no zone, e.g. 2019-06-29T11:11:08.
    static func timestamp(_ date: Date) -> String { timestampFormatter.string(from: date) }

    static func date(fromTimestamp value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return timestampFormatter.date(from: value)
    }

    static func newUUID() -> String { UUID().uuidString }

    static let defaultStyleXML = """
    <style version="2" name="" canvasStyle="0" mapLayout="1" handDrawnTopics="0" topicHugging="1" layoutDensity="0" \
    radialLayout="0" mapViewStyle="0" level1LinkStyle="5" level1LinkStyleTapered="1" levelNLinkStyle="3" linkThickness="2" \
    autoAlign="1" calloutShape="0" rainbow="0" rainbowStartColor="" rainbowRange="0" rainbowClockwise="1" \
    rainbowAngularDistribution="0" inheritColor="1" linkColor=""  calloutFont="HelveticaNeue | Helvetica Neue |  | " \
    calloutFontSize="14" noteFont="HelveticaNeue | Helvetica Neue |  | " noteFontSize="14">\
    <level n="0" topicShape="2" textFont="Helvetica | Helvetica |  | " textFontSize="14" /><level n="1" topicShape="0" /></style>
    """
}
