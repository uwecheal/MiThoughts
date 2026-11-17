import Foundation

/// An attribute, kept in document order (Foundation's XMLParser loses the order).
struct ItmzXMLAttribute: Equatable {
    var name: String
    var value: String
}

/// A small ElementTree-style DOM: `text` is the character data before the first
/// child, `tail` the character data after this element's end tag. That is exactly
/// what is needed to re-serialise iThoughts files byte for byte.
final class ItmzXMLElement {
    var tag: String
    var attributes: [ItmzXMLAttribute]
    var children: [ItmzXMLElement]
    var text: String?
    var tail: String?

    init(tag: String, attributes: [ItmzXMLAttribute] = [], children: [ItmzXMLElement] = [],
         text: String? = nil, tail: String? = nil) {
        self.tag = tag
        self.attributes = attributes
        self.children = children
        self.text = text
        self.tail = tail
    }

    /// Get/set an attribute. Setting `nil` removes it; setting a new name appends it.
    subscript(name: String) -> String? {
        get {
            attributes.first { $0.name == name }?.value
        }
        set {
            if let index = attributes.firstIndex(where: { $0.name == name }) {
                if let newValue {
                    attributes[index].value = newValue
                } else {
                    attributes.remove(at: index)
                }
            } else if let newValue {
                attributes.append(ItmzXMLAttribute(name: name, value: newValue))
            }
        }
    }

    var attributeDictionary: [String: String] {
        var result: [String: String] = [:]
        for attribute in attributes where result[attribute.name] == nil {
            result[attribute.name] = attribute.value
        }
        return result
    }

    func firstChild(named name: String) -> ItmzXMLElement? {
        children.first { $0.tag == name }
    }

    func children(named name: String) -> [ItmzXMLElement] {
        children.filter { $0.tag == name }
    }

    /// Pre-order traversal of all descendants (not including self) with the given tag.
    func descendants(named name: String) -> [ItmzXMLElement] {
        var result: [ItmzXMLElement] = []
        var stack: [ItmzXMLElement] = children.reversed()
        while let element = stack.popLast() {
            if element.tag == name {
                result.append(element)
            }
            stack.append(contentsOf: element.children.reversed())
        }
        return result
    }
}

enum ItmzXMLError: LocalizedError, Equatable {
    case malformed(String, offset: Int)

    var errorDescription: String? {
        switch self {
        case let .malformed(reason, offset):
            return "Malformed XML (\(reason)) at byte \(offset)."
        }
    }
}

/// A parsed document: everything before the root element (XML declaration,
/// comments) and after it is kept verbatim.
struct ItmzXMLDocument {
    var prolog: String
    var root: ItmzXMLElement
    var epilog: String

    init(prolog: String = "", root: ItmzXMLElement, epilog: String = "") {
        self.prolog = prolog
        self.root = root
        self.epilog = epilog
    }

    init(data: Data) throws {
        var parser = ItmzXMLParser(bytes: [UInt8](data))
        self = try parser.parseDocument()
    }

    func serialized() -> String {
        prolog + ItmzXMLSerializer.serialize(root) + epilog
    }

    func data() -> Data {
        Data(serialized().utf8)
    }
}

// MARK: - Parser

/// Non-validating parser for the subset of XML that iThoughts writes:
/// elements, attributes, character data, entity/char references, comments,
/// processing instructions, CDATA and a DOCTYPE without internal subset.
struct ItmzXMLParser {
    private let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) {
        var input = bytes
        if input.count >= 3, input[0] == 0xEF, input[1] == 0xBB, input[2] == 0xBF {
            input.removeFirst(3) // UTF-8 BOM
        }
        self.bytes = input
    }

    mutating func parseDocument() throws -> ItmzXMLDocument {
        let prologStart = index
        while true {
            skipWhitespace()
            if starts(with: "<?") {
                try skip(past: "?>")
            } else if starts(with: "<!--") {
                try skip(past: "-->")
            } else if starts(with: "<!") {
                try skip(past: ">")
            } else {
                break
            }
        }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "<") else {
            throw ItmzXMLError.malformed("no root element", offset: index)
        }
        let prolog = string(prologStart, index)
        let root = try parseElement()
        let epilog = string(index, bytes.count)
        return ItmzXMLDocument(prolog: prolog, root: root, epilog: epilog)
    }

    private mutating func parseElement() throws -> ItmzXMLElement {
        // at "<"
        index += 1
        let tag = readName()
        guard !tag.isEmpty else {
            throw ItmzXMLError.malformed("empty tag name", offset: index)
        }
        let element = ItmzXMLElement(tag: tag)

        // attributes
        while true {
            skipWhitespace()
            guard index < bytes.count else {
                throw ItmzXMLError.malformed("unterminated start tag <\(tag)>", offset: index)
            }
            let byte = bytes[index]
            if byte == UInt8(ascii: "/") {
                guard index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: ">") else {
                    throw ItmzXMLError.malformed("expected '/>'", offset: index)
                }
                index += 2
                return element
            }
            if byte == UInt8(ascii: ">") {
                index += 1
                break
            }
            let name = readName()
            guard !name.isEmpty else {
                throw ItmzXMLError.malformed("bad attribute in <\(tag)>", offset: index)
            }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else {
                throw ItmzXMLError.malformed("expected '=' after \(name)", offset: index)
            }
            index += 1
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") else {
                throw ItmzXMLError.malformed("expected quoted value for \(name)", offset: index)
            }
            let quote = bytes[index]
            index += 1
            let valueStart = index
            while index < bytes.count, bytes[index] != quote {
                index += 1
            }
            guard index < bytes.count else {
                throw ItmzXMLError.malformed("unterminated value for \(name)", offset: valueStart)
            }
            let value = ItmzXMLParser.decode(bytes[valueStart..<index], isAttribute: true)
            index += 1
            element.attributes.append(ItmzXMLAttribute(name: name, value: value))
        }

        // content
        var pending: [UInt8] = []
        func flush() {
            guard !pending.isEmpty else {
                return
            }
            let value = String(decoding: pending, as: UTF8.self)
            if let last = element.children.last {
                last.tail = (last.tail ?? "") + value
            } else {
                element.text = (element.text ?? "") + value
            }
            pending.removeAll(keepingCapacity: true)
        }

        while true {
            guard index < bytes.count else {
                throw ItmzXMLError.malformed("missing </\(tag)>", offset: index)
            }
            if bytes[index] != UInt8(ascii: "<") {
                let start = index
                while index < bytes.count, bytes[index] != UInt8(ascii: "<") {
                    index += 1
                }
                pending.append(contentsOf: Array(ItmzXMLParser.decode(bytes[start..<index], isAttribute: false).utf8))
                continue
            }
            if starts(with: "</") {
                flush()
                index += 2
                let closing = readName()
                guard closing == tag else {
                    throw ItmzXMLError.malformed("</\(closing)> does not close <\(tag)>", offset: index)
                }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ">") else {
                    throw ItmzXMLError.malformed("expected '>'", offset: index)
                }
                index += 1
                return element
            }
            if starts(with: "<!--") {
                try skip(past: "-->")
            } else if starts(with: "<![CDATA[") {
                index += 9
                let start = index
                try skip(past: "]]>")
                pending.append(contentsOf: bytes[start..<(index - 3)])
            } else if starts(with: "<?") {
                try skip(past: "?>")
            } else {
                flush()
                let child = try parseElement()
                element.children.append(child)
            }
        }
    }

    // MARK: Lexing helpers

    private mutating func readName() -> String {
        let start = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
                || byte == UInt8(ascii: "/") || byte == UInt8(ascii: ">") || byte == UInt8(ascii: "=") {
                break
            }
            index += 1
        }
        return string(start, index)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D else {
                return
            }
            index += 1
        }
    }

    private func starts(with literal: String) -> Bool {
        let pattern = Array(literal.utf8)
        guard index + pattern.count <= bytes.count else {
            return false
        }
        for offset in 0..<pattern.count where bytes[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    private mutating func skip(past literal: String) throws {
        let start = index
        while index < bytes.count {
            if starts(with: literal) {
                index += literal.utf8.count
                return
            }
            index += 1
        }
        throw ItmzXMLError.malformed("missing \(literal)", offset: start)
    }

    private func string(_ start: Int, _ end: Int) -> String {
        guard start < end else {
            return ""
        }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// Resolves entity and character references. Literal tab/CR/LF in attribute
    /// values become spaces (XML attribute-value normalisation); references such
    /// as `&#10;` are kept as real newlines.
    static func decode(_ slice: ArraySlice<UInt8>, isAttribute: Bool) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(slice.count)
        var position = slice.startIndex
        while position < slice.endIndex {
            let byte = slice[position]
            if byte == UInt8(ascii: "&") {
                var end = position + 1
                while end < slice.endIndex, end - position <= 12, slice[end] != UInt8(ascii: ";") {
                    end += 1
                }
                if end < slice.endIndex, slice[end] == UInt8(ascii: ";") {
                    let name = String(decoding: slice[(position + 1)..<end], as: UTF8.self)
                    if let replacement = resolveReference(name) {
                        output.append(contentsOf: Array(replacement.utf8))
                        position = end + 1
                        continue
                    }
                }
                output.append(byte)
            } else if isAttribute, byte == 0x09 || byte == 0x0A || byte == 0x0D {
                output.append(0x20)
            } else {
                output.append(byte)
            }
            position += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func resolveReference(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            break
        }
        guard name.hasPrefix("#") else {
            return nil
        }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, let scalar = Unicode.Scalar(value) else {
            return nil
        }
        return String(Character(scalar))
    }
}

// MARK: - Serializer

/// Serialises the way iThoughts does: double-quoted attributes, `&apos;` and
/// `&#10;` escapes, `<tag ... />` for elements without content.
enum ItmzXMLSerializer {
    static func serialize(_ element: ItmzXMLElement) -> String {
        var output = ""
        write(element, into: &output)
        return output
    }

    private static func write(_ element: ItmzXMLElement, into output: inout String) {
        output += "<"
        output += element.tag
        for attribute in element.attributes {
            output += " "
            output += attribute.name
            output += "=\""
            output += escapeAttribute(attribute.value)
            output += "\""
        }
        let hasText = !(element.text ?? "").isEmpty
        if element.children.isEmpty && !hasText {
            output += " />"
        } else {
            output += ">"
            if let text = element.text {
                output += escapeText(text)
            }
            for child in element.children {
                write(child, into: &output)
            }
            output += "</"
            output += element.tag
            output += ">"
        }
        if let tail = element.tail {
            output += escapeText(tail)
        }
    }

    static func escapeAttribute(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n": result += "&#10;"
            case "\r": result += "&#13;"
            case "\t": result += "&#9;"
            default:
                if scalar.value < 0x20 {
                    continue // not representable in XML 1.0
                }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func escapeText(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
