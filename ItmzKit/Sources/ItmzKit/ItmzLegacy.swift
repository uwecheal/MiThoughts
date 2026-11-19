import Foundation

/// Reads maps saved by iThoughts 3 and earlier: the archive holds `map.itm`, a
/// property list whose `MapData` string is `<iThoughtsRelative>` XML with short
/// attribute names (`txt`, `x`/`y`, `topcol`, `rsrcnm`, `ddMMyy HHmmss` dates …)
/// and whose `MapStyle` string is the same `<style>` element as today's `style.xml`.
///
/// The map is translated into current `mapdata.xml` / `style.xml` in memory, so
/// everything downstream (import, display, saving as a current `.itmz`) is shared.
/// The original file is never written back in the old format.
enum ItmzLegacy {
    enum Failure: Error {
        case unreadablePlist
        case missingMapData
    }

    static func convert(mapItm data: Data) throws -> (mapData: Data, style: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.unreadablePlist
        }
        guard let mapString = plist["MapData"] as? String, let mapXML = mapString.data(using: .utf8) else {
            throw Failure.missingMapData
        }

        let reader = LegacyMapReader()
        let parser = XMLParser(data: mapXML)
        parser.delegate = reader
        guard parser.parse() else {
            throw Failure.missingMapData
        }

        var out = "<iThoughts version=\"4.0\" app=\"MiThoughts\" app-version=\"1.0\""
        out += " modified=\"\(ItmzFormat.timestamp(Date()))\"><topics>\n"
        for topic in reader.topics {
            write(topic, to: &out)
        }
        out += "</topics>\n"
        if !reader.relationships.isEmpty {
            out += "<relationships>\n"
            for attributes in reader.relationships {
                out += "<relationship" + attributeText(relationshipAttributes(attributes)) + "/>\n"
            }
            out += "</relationships>\n"
        }
        out += "</iThoughts>"

        let style = (plist["MapStyle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? synthesizedStyle(from: plist)
        return (Data(out.utf8), Data(style.utf8))
    }

    // MARK: Topics

    final class Topic {
        var attributes: [String: String]
        var children: [Topic] = []
        init(_ attributes: [String: String]) { self.attributes = attributes }
    }

    private static func write(_ topic: Topic, to out: inout String) {
        out += "<topic" + attributeText(topicAttributes(topic.attributes))
        if topic.children.isEmpty {
            out += "/>\n"
        } else {
            out += ">\n"
            topic.children.forEach { write($0, to: &out) }
            out += "</topic>\n"
        }
    }

    /// Old name -> current name for attributes whose value is copied as is.
    private static let renamed: [String: String] = [
        "note": "note", "link": "link", "attID": "att-id", "attName": "att-name",
        "topcol": "color", "shape": "shape", "folded": "folded", "floating": "floating",
        "callout": "callout", "boundary": "boundary", "priority": "task-priority",
        "rsrcnm": "resources", "wdth": "text-width", "txtNumber": "numbering",
        "map_layout": "map-layout", "l1_link": "l1-link", "l1_link_tapered": "l1-link-tapered",
        "ln_link": "ln-link", "auto_align": "auto-align", "complete": "task-progress",
    ]

    static func topicAttributes(_ old: [String: String]) -> [(String, String)] {
        var result: [(String, String)] = []
        result.append(("uuid", old["uuid"] ?? UUID().uuidString))
        let x = old["x"].flatMap(Double.init) ?? 0
        let y = old["y"].flatMap(Double.init) ?? 0
        result.append(("position", ItmzFormat.formatPosition(x: x, y: y)))
        let text = old["txt"] ?? old["txtPLIST"].flatMap(archivedString) ?? ""
        if !text.isEmpty {
            result.append(("text", text))
        }
        if let created = old["created"].flatMap(timestamp) {
            result.append(("created", created))
        }
        if let modified = old["modified"].flatMap(timestamp) {
            result.append(("modified", modified))
        }
        if old["note"] == nil, let note = old["notePLIST"].flatMap(archivedString), !note.isEmpty {
            result.append(("note", note))
        }
        if let size = old["fnt"].flatMap(Double.init), abs(size - 14) > 0.01 {
            result.append(("text-size", ItmzFormat.formatNumber(size)))
        }
        if let start = old["start"].flatMap(timestamp) {
            result.append(("task-start", start))
        }
        if let due = old["due"].flatMap(timestamp) {
            result.append(("task-due", due))
        }
        for key in renamed.keys.sorted() {
            if let value = old[key], !value.isEmpty, let newName = renamed[key] {
                result.append((newName, value))
            }
        }
        return result
    }

    static func relationshipAttributes(_ old: [String: String]) -> [(String, String)] {
        var result: [(String, String)] = [("type", old["type"] ?? "0")]
        let map = [
            ("end1", "end1-uuid"), ("end1style", "end1-style"), ("end2", "end2-uuid"),
            ("end2style", "end2-style"), ("dashed", "dashed"), ("Boffset", "b-offset"),
        ]
        for (oldName, newName) in map {
            if let value = old[oldName], !value.isEmpty {
                result.append((newName, value))
            }
        }
        if let color = old["color"], !color.isEmpty {
            result.append(("color", color.replacingOccurrences(of: "#", with: "")))
        }
        let label = old["centretxt"] ?? old["centretxtPLIST"].flatMap(archivedString) ?? ""
        if !label.isEmpty {
            result.append(("center-text", label))
        }
        return result
    }

    // MARK: Values

    /// `ddMMyy HHmmss` (e.g. `100415 092030`) -> `2015-04-10T09:20:30`.
    static func timestamp(_ value: String) -> String? {
        guard let date = legacyFormatter.date(from: value) else {
            return nil
        }
        return ItmzFormat.timestamp(date)
    }

    private static let legacyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "ddMMyy HHmmss"
        return formatter
    }()

    /// The plain string inside a base64 keyed archive of an attributed string
    /// (`txtPLIST`, `notePLIST`). iOS font classes make a real unarchive fail
    /// on the Mac, so the archive is read as a plain property list.
    static func archivedString(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = archive["$objects"] as? [Any] else {
            return nil
        }
        func resolve(_ value: Any?) -> Any? {
            guard let value else {
                return nil
            }
            if let index = uidIndex(value), objects.indices.contains(index) {
                return objects[index]
            }
            return value
        }
        if let top = archive["$top"] as? [String: Any],
           let root = resolve(top["root"]) as? [String: Any] {
            let stringObject = resolve(root["NSString"] ?? root["NS.string"])
            if let string = stringObject as? String {
                return string
            }
            if let dictionary = stringObject as? [String: Any], let string = dictionary["NS.string"] as? String {
                return string
            }
        }
        // Fallback: the first archived string object.
        for object in objects {
            if let dictionary = object as? [String: Any], let string = dictionary["NS.string"] as? String {
                return string
            }
        }
        return nil
    }

    /// Index held by a `CF$UID` (bridged as an opaque object whose description ends `{value = N}`).
    private static func uidIndex(_ value: Any) -> Int? {
        if let dictionary = value as? [String: Any], let uid = dictionary["CF$UID"] as? Int {
            return uid
        }
        let description = String(describing: value)
        guard description.contains("CFKeyedArchiverUID"),
              let range = description.range(of: "value = ") else {
            return nil
        }
        return Int(description[range.upperBound...].prefix { $0.isNumber })
    }

    private static func attributeText(_ attributes: [(String, String)]) -> String {
        attributes.map { " \($0.0)=\"\(escape($0.1))\"" }.joined()
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n": result += "&#10;"
            case "\r": result += "&#13;"
            case "\t": result += "&#9;"
            default: result.append(character)
            }
        }
        return result
    }

    /// A `<style>` element for the few old maps saved without one.
    private static func synthesizedStyle(from plist: [String: Any]) -> String {
        func number(_ key: String, _ fallback: Int) -> Int {
            (plist[key] as? Int) ?? (plist[key] as? NSNumber)?.intValue ?? fallback
        }
        let rainbow = (plist["Rainbow"] as? Bool) == true ? 1 : 0
        let tapered = (plist["Level1LinkTapered"] as? Bool) == false ? 0 : 1
        return "<style version=\"2\" canvasStyle=\"\(number("CanvasStyle", 0))\" mapLayout=\"\(number("MapLayout", 1))\""
            + " level1LinkStyle=\"\(number("Level1LinkStyle", 3))\" level1LinkStyleTapered=\"\(tapered)\""
            + " levelNLinkStyle=\"\(number("LevelNLinkStyle", 3))\" rainbow=\"\(rainbow)\" inheritColor=\"1\"></style>"
    }
}

private final class LegacyMapReader: NSObject, XMLParserDelegate {
    var topics: [ItmzLegacy.Topic] = []
    var relationships: [[String: String]] = []
    private var stack: [ItmzLegacy.Topic] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "topic":
            let topic = ItmzLegacy.Topic(attributes)
            if let parent = stack.last {
                parent.children.append(topic)
            } else {
                topics.append(topic)
            }
            stack.append(topic)
        case "relationship":
            relationships.append(attributes)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "topic" {
            stack.removeLast()
        }
    }
}
