import Foundation

struct CanvasConnection: Identifiable, Equatable, Codable {
    let id: UUID
    var fromNodeID: UUID
    var toNodeID: UUID
    var type: String
}

/// iThoughts relationship `type`: 0 curve, 1 straight, 2 elbow.
enum RelationshipLineStyle: String, CaseIterable, Codable, Identifiable {
    case curved = "0"
    case straight = "1"
    case elbow = "2"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .curved: "Curved"
        case .straight: "Straight"
        case .elbow: "Elbow"
        }
    }
}

/// iThoughts `end1-style` / `end2-style`: 0 none, 1 arrow, 2 dot (inferred).
enum RelationshipEndStyle: String, CaseIterable, Codable, Identifiable {
    case none = "0"
    case arrow = "1"
    case dot = "2"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .arrow: "Arrow"
        case .dot: "Dot"
        }
    }
}

/// A free cross-link between any two topics (iThoughts `<relationship>`).
struct CanvasRelationship: Identifiable, Equatable, Codable {
    var id: UUID
    var fromNodeID: UUID
    var toNodeID: UUID
    var label: String
    var colorHex: String?
    var lineStyle: RelationshipLineStyle
    var startStyle: RelationshipEndStyle
    var endStyle: RelationshipEndStyle
    var isDashed: Bool

    init(
        id: UUID = UUID(),
        fromNodeID: UUID,
        toNodeID: UUID,
        label: String = "",
        colorHex: String? = nil,
        lineStyle: RelationshipLineStyle = .curved,
        startStyle: RelationshipEndStyle = .none,
        endStyle: RelationshipEndStyle = .arrow,
        isDashed: Bool = false
    ) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.label = label
        self.colorHex = colorHex
        self.lineStyle = lineStyle
        self.startStyle = startStyle
        self.endStyle = endStyle
        self.isDashed = isDashed
    }

    private enum CodingKeys: String, CodingKey {
        case id, fromNodeID, toNodeID, label, colorHex, lineStyle, startStyle, endStyle, isDashed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fromNodeID = try container.decode(UUID.self, forKey: .fromNodeID)
        toNodeID = try container.decode(UUID.self, forKey: .toNodeID)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        lineStyle = try container.decodeIfPresent(RelationshipLineStyle.self, forKey: .lineStyle) ?? .curved
        startStyle = try container.decodeIfPresent(RelationshipEndStyle.self, forKey: .startStyle) ?? .none
        endStyle = try container.decodeIfPresent(RelationshipEndStyle.self, forKey: .endStyle) ?? .arrow
        isDashed = try container.decodeIfPresent(Bool.self, forKey: .isDashed) ?? false
    }
}
