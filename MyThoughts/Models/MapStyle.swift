import Foundation

/// The map-wide look of an iThoughts map, read from the `style.xml` entry of an
/// `.itmz` file: branch line shapes, canvas colour, level colours and rainbow
/// branch colouring. It only changes how the map is drawn; topics keep their
/// own attributes, so saving back to `.itmz` leaves `style.xml` untouched.
///
/// Codes were worked out from iThoughts' own `preview.png` renderings:
/// line style `2` = right-angle (elbow), `3` = curved, `5` = straight.
struct MapStyle: Codable, Equatable {
    /// Off = draw the map with the app's Canvas settings instead.
    var isEnabled = true
    var name = ""
    var level1LineStyle: CanvasAppearance.ConnectionLineStyle = .curved
    var levelNLineStyle: CanvasAppearance.ConnectionLineStyle = .curved
    /// iThoughts draws the lines leaving the central topic thicker (tapered).
    var level1Tapered = true
    var lineThickness: Double = 2
    var linkColorHex: String?
    var canvasColorHex: String?
    var canvasIsDark = false
    var canvasShowsGrid = false
    /// `level n` → `topicColor`, used for topics without their own colour.
    var levelColorHex: [String: String] = [:]
    var rainbow = false
    var rainbowStartHex = "268BD2"
    var rainbowClockwise = true
    var inheritColor = true

    init() { }

    init?(styleXML data: Data?) {
        guard let data, !data.isEmpty else {
            return nil
        }
        let reader = StyleXMLReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), let style = reader.style else {
            return nil
        }

        name = style["name"] ?? ""
        level1LineStyle = Self.lineStyle(code: style["level1LinkStyle"])
        levelNLineStyle = Self.lineStyle(code: style["levelNLinkStyle"])
        level1Tapered = style["level1LinkStyleTapered"] != "0"
        lineThickness = style["linkThickness"].flatMap(Double.init) ?? 2
        linkColorHex = Self.hex(style["linkColor"])
        rainbow = style["rainbow"] == "1"
        rainbowStartHex = Self.hex(style["rainbowStartColor"]) ?? "268BD2"
        rainbowClockwise = style["rainbowClockwise"] != "0"
        inheritColor = style["inheritColor"] != "0"
        for (level, attributes) in reader.levels {
            if let color = Self.hex(attributes["topicColor"]) {
                levelColorHex[level] = color
            }
        }

        let canvasStyle = style["canvasStyle"].flatMap(Int.init) ?? 0
        if canvasStyle == -1 {
            canvasColorHex = Self.hex(reader.canvas?["dominantColor"])
        } else {
            canvasColorHex = Self.builtInCanvasColors[canvasStyle]
        }
        canvasShowsGrid = Self.gridCanvasStyles.contains(canvasStyle)
        if let canvasColorHex {
            canvasIsDark = reader.canvas?["dark"] == "1" || Self.luminance(canvasColorHex) < 0.42
        }
    }

    /// Colour of the `index`-th main branch when iThoughts' rainbow colouring is on:
    /// the start colour's hue turned in equal steps around the colour wheel.
    func rainbowColorHex(index: Int, count: Int) -> String {
        guard count > 0, let (h, s, b) = Self.hsb(rainbowStartHex) else {
            return rainbowStartHex
        }
        let step = 1.0 / Double(max(count, 1)) * Double(index)
        var hue = rainbowClockwise ? h + step : h - step
        hue -= floor(hue)
        return Self.hex(hue: hue, saturation: max(s, 0.6), brightness: max(b, 0.75))
    }

    func colorHex(forLevel level: Int) -> String? {
        levelColorHex[String(level)]
    }

    // MARK: Codes

    static func lineStyle(code: String?) -> CanvasAppearance.ConnectionLineStyle {
        switch code {
        case "1", "5":
            return .straight
        case "2":
            return .elbow
        case "4":
            return .roundedElbow
        default:
            return .curved
        }
    }

    /// Background colours of iThoughts' built-in canvases, sampled from previews.
    static let builtInCanvasColors: [Int: String] = [
        0: "FFFFFF",
        1: "000000",
        2: "85888E",
        8: "676767",
        10: "F4F4F4",
        13: "ECE4B3",
        16: "003846",
        17: "004553",
        18: "F1ECDC",
        26: "F4F4F4",
        29: "4F5864",
        33: "000000",
        37: "F3F0E3",
    ]

    /// Canvases drawn as squared paper.
    static let gridCanvasStyles: Set<Int> = [26]

    // MARK: Colour maths

    static func hex(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, UInt32(value, radix: 16) != nil else {
            return nil
        }
        return value.uppercased()
    }

    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        guard let clean = Self.hex(hex), let value = UInt32(clean, radix: 16) else {
            return nil
        }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    static func luminance(_ hex: String) -> Double {
        guard let (r, g, b) = rgb(hex) else {
            return 1
        }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func hsb(_ hex: String) -> (Double, Double, Double)? {
        guard let (r, g, b) = rgb(hex) else {
            return nil
        }
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue
        var hue = 0.0
        if delta > 0 {
            if maxValue == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 {
                hue += 1
            }
        }
        return (hue, maxValue == 0 ? 0 : delta / maxValue, maxValue)
    }

    static func hex(hue: Double, saturation: Double, brightness: Double) -> String {
        let h = (hue - floor(hue)) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        func byte(_ value: Double) -> Int { Int(((value + m) * 255).rounded()).clamped(0, 255) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}

private final class StyleXMLReader: NSObject, XMLParserDelegate {
    var style: [String: String]?
    var canvas: [String: String]?
    var levels: [String: [String: String]] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName {
        case "style" where style == nil:
            style = attributes
        case "canvas":
            canvas = attributes
        case "level":
            if let level = attributes["n"] {
                levels[level] = attributes
            }
        default:
            break
        }
    }
}
