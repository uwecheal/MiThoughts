import SwiftUI
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

// MARK: - Colours

/// Topic / relationship colours are stored like iThoughts does: `RRGGBB`, no `#`.
enum TopicColor {
    /// iThoughts-like palette for the colour menus.
    static let palette: [(name: String, hex: String)] = [
        ("Red", "DC322F"),
        ("Orange", "F28C28"),
        ("Yellow", "F4D03F"),
        ("Green", "47B247"),
        ("Teal", "2AA198"),
        ("Blue", "477DB2"),
        ("Indigo", "4747B2"),
        ("Purple", "B247B2"),
        ("Pink", "F06292"),
        ("Brown", "A0522D"),
        ("Gray", "93A1A1"),
        ("Black", "000000"),
        ("White", "FFFFFF")
    ]

    /// "#dc322f", "DC322F", "dc322fff" -> "DC322F"; nil when not a colour.
    static func normalizedHex(_ value: String) -> String? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        if hex.count == 8 {
            hex = String(hex.prefix(6))
        }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return hex
    }

    static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard let normalized = normalizedHex(hex), let value = Int(normalized, radix: 16) else {
            return nil
        }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func color(_ hex: String?) -> Color? {
        guard let hex, let rgb = components(hex) else {
            return nil
        }
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }

    static func hex(from color: Color) -> String? {
        guard let rgb = PlatformColor.srgbComponents(of: color) else {
            return nil
        }
        let red = Int((rgb.red * 255).rounded())
        let green = Int((rgb.green * 255).rounded())
        let blue = Int((rgb.blue * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }

    static func luminance(_ hex: String) -> Double {
        guard let rgb = components(hex) else {
            return 1
        }
        return 0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue
    }

    /// Black or white text, whichever reads better on the fill.
    static func textColor(onFill hex: String) -> Color {
        luminance(hex) > 0.6 ? Color.black.opacity(0.85) : .white
    }

    /// A darker shade of the fill for its outline.
    static func borderColor(forFill hex: String) -> Color {
        guard let rgb = components(hex) else {
            return .secondary
        }
        let factor = 0.72
        return Color(.sRGB, red: rgb.red * factor, green: rgb.green * factor, blue: rgb.blue * factor, opacity: 1)
    }
}

// MARK: - Shapes

extension TopicShape {
    /// Closed shapes get a fill; open ones (underline, brackets, none) only a stroke.
    var isFilled: Bool {
        switch self {
        case .underline, .none, .squareBracket, .roundBracket: false
        default: true
        }
    }

    var systemImageName: String {
        switch self {
        case .roundedRectangle: "app"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .underline: "underline"
        case .none: "textformat"
        case .squareBracket: "curlybraces"
        case .roundBracket: "parentheses"
        case .circle: "circle"
        case .diamond: "diamond"
        case .parallelogram: "rectangle.portrait.and.arrow.right"
        case .pill: "capsule"
        case .square: "square"
        case .triangle: "triangle"
        }
    }
}

/// The outline of a topic box.
struct TopicOutline: Shape {
    var shape: TopicShape
    var cornerRadius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .roundedRectangle:
            return Path(roundedRect: rect, cornerRadius: min(cornerRadius, rect.height / 2))
        case .rectangle, .square:
            return Path(rect)
        case .ellipse, .circle:
            return Path(ellipseIn: rect)
        case .pill:
            return Path(roundedRect: rect, cornerRadius: rect.height / 2)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        case .parallelogram:
            let slant = min(rect.height * 0.45, rect.width * 0.2)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + slant, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - slant, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        case .triangle:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        case .underline:
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            return path
        case .none:
            return Path()
        case .squareBracket:
            let arm = min(8, rect.width / 6)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + arm, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
            return path
        case .roundBracket:
            let bow = min(10, rect.width / 6)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + bow, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.minX + bow, y: rect.maxY), control: CGPoint(x: rect.minX - bow, y: rect.midY))
            path.move(to: CGPoint(x: rect.maxX - bow, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - bow, y: rect.maxY), control: CGPoint(x: rect.maxX + bow, y: rect.midY))
            return path
        }
    }
}

/// Fill + outline of a topic, shared by the canvas and PDF/PNG export.
struct TopicBoxBackground: View {
    var shape: TopicShape
    var fill: Color
    var stroke: Color
    var lineWidth: CGFloat
    var shadow: Color?
    var cornerRadius: CGFloat = 8
    /// Open shapes have no outline of their own to show selection, so draw a halo.
    var selectionHalo: Color?

    var body: some View {
        ZStack {
            if shape.isFilled {
                TopicOutline(shape: shape, cornerRadius: cornerRadius)
                    .fill(fill)
                    .shadow(color: shadow ?? .clear, radius: 4, y: 2)
            }
            TopicOutline(shape: shape, cornerRadius: cornerRadius)
                .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            if let selectionHalo, !shape.isFilled {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selectionHalo, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .padding(-3)
            }
        }
    }
}

// MARK: - Title text (iThoughts titles are Markdown)

enum TopicText {
    private static var cache: [String: AttributedString] = [:]

    /// Inline Markdown (`**bold**`, `_italic_`, `~~strike~~`, links); `# heading` lines become bold.
    static func attributed(_ title: String) -> AttributedString {
        if let cached = cache[title] {
            return cached
        }
        var result = AttributedString()
        let lines = title.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            var line = String(rawLine)
            var isHeading = false
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }
                if hashes.count <= 6, line.dropFirst(hashes.count).first == " " {
                    line = String(line.dropFirst(hashes.count + 1))
                    isHeading = true
                }
            }
            line = line.replacingOccurrences(of: "<u>", with: "").replacingOccurrences(of: "</u>", with: "")
                .replacingOccurrences(of: "<mark>", with: "").replacingOccurrences(of: "</mark>", with: "")
            var part = (try? AttributedString(
                markdown: line,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(line)
            if isHeading {
                part.inlinePresentationIntent = .stronglyEmphasized
            }
            result.append(part)
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        if cache.count > 5000 {
            cache.removeAll()
        }
        cache[title] = result
        return result
    }

    /// Plain text without Markdown markers (for search, outline, window titles).
    static func plain(_ title: String) -> String {
        String(attributed(title).characters)
    }
}

// MARK: - Images

enum TopicImageCache {
    private static var images: [UUID: (data: Data, image: PlatformImage)] = [:]

    static func image(for nodeID: UUID, data: Data?) -> PlatformImage? {
        guard let data else {
            images[nodeID] = nil
            return nil
        }
        if let cached = images[nodeID], cached.data == data {
            return cached.image
        }
        guard let image = PlatformImage(data: data) else {
            return nil
        }
        images[nodeID] = (data, image)
        return image
    }
}

// MARK: - Relationship lines

struct RelationshipRenderItem {
    var id: UUID
    var fromRect: CGRect
    var toRect: CGRect
    var lineStyle: RelationshipLineStyle
    var startStyle: RelationshipEndStyle
    var endStyle: RelationshipEndStyle
    var isDashed: Bool
    var color: Color
    var label: String
    var isSelected: Bool = false
}

enum RelationshipGeometry {
    struct Curve {
        var path: Path
        var start: CGPoint
        var end: CGPoint
        /// Direction the line leaves `start` / arrives at `end` (for arrow heads).
        var startDirection: CGVector
        var endDirection: CGVector
        var midpoint: CGPoint
    }

    /// Where the line from the rect's centre towards `target` crosses the rect edge.
    static func edgePoint(of rect: CGRect, toward target: CGPoint, padding: CGFloat = 4) -> CGPoint {
        let box = rect.insetBy(dx: -padding, dy: -padding)
        let center = CGPoint(x: box.midX, y: box.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else {
            return center
        }
        let scaleX = dx == 0 ? CGFloat.infinity : (box.width / 2) / abs(dx)
        let scaleY = dy == 0 ? CGFloat.infinity : (box.height / 2) / abs(dy)
        let scale = min(scaleX, scaleY)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    static func curve(for item: RelationshipRenderItem) -> Curve {
        let fromCenter = CGPoint(x: item.fromRect.midX, y: item.fromRect.midY)
        let toCenter = CGPoint(x: item.toRect.midX, y: item.toRect.midY)
        var path = Path()

        switch item.lineStyle {
        case .straight:
            let start = edgePoint(of: item.fromRect, toward: toCenter)
            let end = edgePoint(of: item.toRect, toward: fromCenter)
            path.move(to: start)
            path.addLine(to: end)
            let direction = CGVector(dx: end.x - start.x, dy: end.y - start.y)
            return Curve(path: path, start: start, end: end, startDirection: direction, endDirection: direction,
                         midpoint: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))

        case .elbow:
            let goesRight = toCenter.x >= fromCenter.x
            let start = CGPoint(x: goesRight ? item.fromRect.maxX + 4 : item.fromRect.minX - 4, y: fromCenter.y)
            let end = CGPoint(x: goesRight ? item.toRect.minX - 4 : item.toRect.maxX + 4, y: toCenter.y)
            let midX = (start.x + end.x) / 2
            path.move(to: start)
            path.addLine(to: CGPoint(x: midX, y: start.y))
            path.addLine(to: CGPoint(x: midX, y: end.y))
            path.addLine(to: end)
            let horizontal = CGVector(dx: goesRight ? 1 : -1, dy: 0)
            return Curve(path: path, start: start, end: end, startDirection: horizontal, endDirection: horizontal,
                         midpoint: CGPoint(x: midX, y: (start.y + end.y) / 2))

        case .curved:
            let dx = toCenter.x - fromCenter.x
            let dy = toCenter.y - fromCenter.y
            let length = max(sqrt(dx * dx + dy * dy), 1)
            // Bow to the left of the travel direction, like iThoughts' default curve.
            let bow = min(length * 0.3, 120)
            let control = CGPoint(x: (fromCenter.x + toCenter.x) / 2 + dy / length * bow,
                                  y: (fromCenter.y + toCenter.y) / 2 - dx / length * bow)
            let start = edgePoint(of: item.fromRect, toward: control)
            let end = edgePoint(of: item.toRect, toward: control)
            path.move(to: start)
            path.addQuadCurve(to: end, control: control)
            let midpoint = CGPoint(x: 0.25 * start.x + 0.5 * control.x + 0.25 * end.x,
                                   y: 0.25 * start.y + 0.5 * control.y + 0.25 * end.y)
            return Curve(path: path, start: start, end: end,
                         startDirection: CGVector(dx: control.x - start.x, dy: control.y - start.y),
                         endDirection: CGVector(dx: end.x - control.x, dy: end.y - control.y),
                         midpoint: midpoint)
        }
    }

    /// Arrow head or dot at `point`; `direction` points along the line towards `point`.
    static func endCap(_ style: RelationshipEndStyle, at point: CGPoint, direction: CGVector, size: CGFloat) -> Path? {
        switch style {
        case .none:
            return nil
        case .dot:
            return Path(ellipseIn: CGRect(x: point.x - size / 2.6, y: point.y - size / 2.6, width: size / 1.3, height: size / 1.3))
        case .arrow:
            let length = max(sqrt(direction.dx * direction.dx + direction.dy * direction.dy), 0.0001)
            let ux = direction.dx / length
            let uy = direction.dy / length
            let base = CGPoint(x: point.x - ux * size, y: point.y - uy * size)
            var path = Path()
            path.move(to: point)
            path.addLine(to: CGPoint(x: base.x - uy * size * 0.5, y: base.y + ux * size * 0.5))
            path.addLine(to: CGPoint(x: base.x + uy * size * 0.5, y: base.y - ux * size * 0.5))
            path.closeSubpath()
            return path
        }
    }

    /// Distance from `point` to the relationship line (sampled), for click hit-testing.
    static func distance(from point: CGPoint, to item: RelationshipRenderItem) -> CGFloat {
        let curve = curve(for: item)
        var best = CGFloat.infinity
        let samples = 24
        var previous = curve.start
        for step in 1...samples {
            let t = CGFloat(step) / CGFloat(samples)
            let current = curve.path.trimmedPath(from: 0, to: t).currentPoint ?? curve.end
            best = min(best, segmentDistance(point, previous, current))
            previous = current
        }
        return best
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

struct RelationshipLayerView: View {
    var items: [RelationshipRenderItem]
    var lineWidth: CGFloat
    var labelBackground: Color
    var scale: CGFloat = 1

    var body: some View {
        Canvas { context, _ in
            for item in items {
                let curve = RelationshipGeometry.curve(for: item)
                let width = (item.isSelected ? lineWidth + 1.5 : lineWidth) * max(scale, 0.5)
                let dash: [CGFloat] = item.isDashed ? [6 * max(scale, 0.5), 4 * max(scale, 0.5)] : []
                context.stroke(curve.path, with: .color(item.color),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))

                let capSize = 10 * max(scale, 0.5)
                if let cap = RelationshipGeometry.endCap(item.endStyle, at: curve.end, direction: curve.endDirection, size: capSize) {
                    context.fill(cap, with: .color(item.color))
                }
                let reversed = CGVector(dx: -curve.startDirection.dx, dy: -curve.startDirection.dy)
                if let cap = RelationshipGeometry.endCap(item.startStyle, at: curve.start, direction: reversed, size: capSize) {
                    context.fill(cap, with: .color(item.color))
                }

                let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty {
                    let text = context.resolve(
                        Text(label).font(.system(size: 11 * max(scale, 0.6), weight: .medium)).foregroundColor(item.color)
                    )
                    let size = text.measure(in: CGSize(width: 220, height: 80))
                    let box = CGRect(x: curve.midpoint.x - size.width / 2 - 5, y: curve.midpoint.y - size.height / 2 - 2,
                                     width: size.width + 10, height: size.height + 4)
                    context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(labelBackground.opacity(0.92)))
                    context.draw(text, in: box.insetBy(dx: 5, dy: 2))
                }
            }
        }
    }
}

// MARK: - Boundaries

struct BoundaryRenderItem {
    var rect: CGRect
    var color: Color
}

/// A group box from an iThoughts file: drawn around its member topics' branches.
struct CanvasGroupBox {
    var colorHex: String?
    /// type 0 = tinted box, type 1 = outline only.
    var isFilled: Bool
    var memberIDs: [UUID]
}

struct GroupLayerView: View {
    var items: [(rect: CGRect, color: Color, isFilled: Bool)]
    var scale: CGFloat = 1

    var body: some View {
        Canvas { context, _ in
            for item in items {
                let path = Path(roundedRect: item.rect, cornerRadius: 16 * max(scale, 0.5))
                if item.isFilled {
                    context.fill(path, with: .color(item.color.opacity(0.16)))
                }
                context.stroke(path, with: .color(item.color.opacity(0.8)), lineWidth: 1.5)
            }
        }
    }
}

/// iThoughts topic numbering (`numbering="^nn^.nn^...^ "`): children of a numbered
/// topic get 1, 2, … and deeper levels 1.1, 1.1.1, ….
enum TopicNumbering {
    static func prefixes(
        nodes: [CanvasNode],
        childrenByParent: [UUID: [CanvasNode]]
    ) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for numbered in nodes where numbered.style.numbering != nil {
            let separator = numbered.style.numbering?.hasSuffix(" ") == false ? "" : " "
            var stack: [(UUID, [Int])] = [(numbered.id, [])]
            while let (parentID, path) = stack.popLast() {
                let children = (childrenByParent[parentID] ?? [])
                    .filter { $0.floatingAnchorID == nil && !$0.style.isCallout }
                    .sorted { $0.sortIndex < $1.sortIndex }
                for (index, child) in children.enumerated() {
                    let childPath = path + [index + 1]
                    result[child.id] = childPath.map(String.init).joined(separator: ".") + separator
                    if child.style.numbering == nil {
                        stack.append((child.id, childPath))
                    }
                }
            }
        }
        return result
    }
}

struct BoundaryLayerView: View {
    var items: [BoundaryRenderItem]
    var scale: CGFloat = 1

    var body: some View {
        Canvas { context, _ in
            for item in items {
                let path = Path(roundedRect: item.rect, cornerRadius: 12 * max(scale, 0.5))
                context.fill(path, with: .color(item.color.opacity(0.08)))
                context.stroke(path, with: .color(item.color.opacity(0.65)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
        }
    }
}

// MARK: - Relationship editor

struct RelationshipEditorView: View {
    @Binding var relationship: CanvasRelationship
    let fromTitle: String
    let toTitle: String
    let onDelete: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Relationship")
                .font(.headline)
            Text("\(fromTitle)  →  \(toTitle)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Form {
                TextField("Label", text: $relationship.label)

                Picker("Line", selection: $relationship.lineStyle) {
                    ForEach(RelationshipLineStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }

                Picker("Start", selection: $relationship.startStyle) {
                    ForEach(RelationshipEndStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }

                Picker("End", selection: $relationship.endStyle) {
                    ForEach(RelationshipEndStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }

                Toggle("Dashed", isOn: $relationship.isDashed)

                ColorPicker("Colour", selection: Binding(
                    get: { TopicColor.color(relationship.colorHex) ?? .gray },
                    set: { relationship.colorHex = TopicColor.hex(from: $0) }
                ), supportsOpacity: false)

                HStack(spacing: 6) {
                    ForEach(TopicColor.palette.prefix(10), id: \.hex) { entry in
                        Button {
                            relationship.colorHex = entry.hex
                        } label: {
                            Circle()
                                .fill(TopicColor.color(entry.hex) ?? .gray)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(Color.primary.opacity(relationship.colorHex == entry.hex ? 0.8 : 0.15), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help(entry.name)
                    }
                    Button("Default") {
                        relationship.colorHex = nil
                    }
                    .controlSize(.small)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Delete Relationship", role: .destructive, action: onDelete)
                Spacer()
                Button("Swap Direction") {
                    let from = relationship.fromNodeID
                    relationship.fromNodeID = relationship.toNodeID
                    relationship.toNodeID = from
                    let start = relationship.startStyle
                    relationship.startStyle = relationship.endStyle
                    relationship.endStyle = start
                }
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Menu support

enum TopicStyleAction {
    case setColor(String?)
    case setShape(TopicShape?)
    case setTextSize(Double?)
    case toggleBoundary
    case chooseImage
    case removeImage
    case startRelationship
    case editRelationship(UUID)
    case deleteRelationship(UUID)
}

struct RelationshipMenuItem: Identifiable {
    var id: UUID
    var title: String
}

extension TopicColor {
    private static var swatches: [String: PlatformImage] = [:]

    /// A small non-template colour dot for menus.
    static func swatch(_ hex: String) -> PlatformImage {
        if let cached = swatches[hex] {
            return cached
        }
        #if os(macOS)
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            if let rgb = components(hex) {
                NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).setFill()
            }
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.isTemplate = false
        #else
        let size = CGSize(width: 12, height: 12)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5))
            if let rgb = components(hex) {
                UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).setFill()
            }
            path.fill()
            UIColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
        }.withRenderingMode(.alwaysOriginal)
        #endif
        swatches[hex] = image
        return image
    }
}

enum TopicImageImport {
    enum ImportError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            "The file is not an image MiThoughts can read."
        }
    }

    /// Reads an image for a topic. Large images are scaled down (max 1200 px) and stored as
    /// JPEG/PNG so maps stay small; small ones are kept byte-for-byte.
    static func prepare(contentsOf url: URL) throws -> (data: Data, name: String) {
        let data = try Data(contentsOf: url)
        #if os(macOS)
        guard let image = NSImage(data: data),
              let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else {
            throw ImportError.unreadable
        }
        let pixelWidth = CGFloat(bitmap.pixelsWide)
        let pixelHeight = CGFloat(bitmap.pixelsHigh)
        let maximum: CGFloat = 1200
        let fileName = url.lastPathComponent
        let knownFormat = ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased())

        if knownFormat && max(pixelWidth, pixelHeight) <= maximum && data.count <= 1_500_000 {
            return (data, fileName)
        }

        let scale = min(1, maximum / max(pixelWidth, pixelHeight, 1))
        let target = NSSize(width: (pixelWidth * scale).rounded(), height: (pixelHeight * scale).rounded())
        guard let resized = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw ImportError.unreadable
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()

        let stem = url.deletingPathExtension().lastPathComponent
        if bitmap.hasAlpha, let png = resized.representation(using: .png, properties: [:]) {
            return (png, "\(stem).png")
        }
        guard let jpeg = resized.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw ImportError.unreadable
        }
        return (jpeg, "\(stem).jpg")
        #else
        return try prepareWithImageIO(data: data, url: url)
        #endif
    }

    #if !os(macOS)
    private static func prepareWithImageIO(data: Data, url: URL) throws -> (data: Data, name: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            throw ImportError.unreadable
        }
        let maximum: CGFloat = 1200
        let fileName = url.lastPathComponent
        let knownFormat = ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased())
        if knownFormat && max(pixelWidth, pixelHeight) <= maximum && data.count <= 1_500_000 {
            return (data, fileName)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(min(maximum, max(pixelWidth, pixelHeight)))
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.unreadable
        }
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let stem = url.deletingPathExtension().lastPathComponent
        let output = NSMutableData()
        let type = hasAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw ImportError.unreadable
        }
        let destinationOptions: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, thumbnail, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImportError.unreadable
        }
        return (output as Data, hasAlpha ? "\(stem).png" : "\(stem).jpg")
    }
    #endif
}
