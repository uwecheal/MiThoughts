import SwiftUI

enum TaskPriority: String, CaseIterable, Codable, Identifiable {
    case none
    case low
    case medium
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:
            "None"
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        }
    }
}

enum LinkType: String, CaseIterable, Codable, Identifiable {
    case web
    case file
    case unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .web:
            "Web"
        case .file:
            "File"
        case .unknown:
            "Unknown"
        }
    }

    static func inferred(from urlString: String) -> LinkType {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return .web
        }

        if lowercased.hasPrefix("file://") || trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return .file
        }

        return .unknown
    }
}

struct NodeLink: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var urlString: String
    var linkType: LinkType
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        urlString: String,
        linkType: LinkType? = nil,
        createdAt: Date = Date()
    ) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        self.id = id
        self.title = trimmedTitle.isEmpty ? trimmedURL : trimmedTitle
        self.urlString = trimmedURL
        self.linkType = linkType ?? LinkType.inferred(from: trimmedURL)
        self.createdAt = createdAt
    }

    static func legacy(_ urlString: String) -> NodeLink {
        NodeLink(title: urlString, urlString: urlString)
    }
}

enum NodeMarker: String, CaseIterable, Codable, Identifiable {
    case none
    case idea
    case task
    case done
    case warning
    case question
    case star
    case flag
    case priority

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:
            "None"
        case .idea:
            "Idea"
        case .task:
            "Task"
        case .done:
            "Done"
        case .warning:
            "Warning"
        case .question:
            "Question"
        case .star:
            "Star"
        case .flag:
            "Flag"
        case .priority:
            "Priority"
        }
    }

    var systemImageName: String? {
        switch self {
        case .none:
            nil
        case .idea:
            "lightbulb"
        case .task:
            "checkmark.circle"
        case .done:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle"
        case .question:
            "questionmark.circle"
        case .star:
            "star"
        case .flag:
            "flag"
        case .priority:
            "arrow.up.circle"
        }
    }
}

/// iThoughts topic shapes (`shape` attribute codes 0-12, see Docs/ITMZ_FORMAT.md).
enum TopicShape: Int, CaseIterable, Codable, Identifiable {
    case roundedRectangle = 0
    case rectangle = 1
    case ellipse = 2
    case underline = 3
    case none = 4
    case squareBracket = 5
    case roundBracket = 6
    case circle = 7
    case diamond = 8
    case parallelogram = 9
    case pill = 10
    case square = 11
    case triangle = 12

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .roundedRectangle: "Rounded Rectangle"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .underline: "Underline"
        case .none: "No Shape"
        case .squareBracket: "Square Brackets"
        case .roundBracket: "Round Brackets"
        case .circle: "Circle"
        case .diamond: "Diamond"
        case .parallelogram: "Parallelogram"
        case .pill: "Pill"
        case .square: "Square"
        case .triangle: "Triangle"
        }
    }
}

/// Per-topic appearance (iThoughts `color`, `shape`, `text-size`, `boundary`, topic image).
struct TopicStyle: Equatable, Codable {
    /// Fill colour as `RRGGBB` (no `#`), like iThoughts. nil = inherit / theme default.
    var colorHex: String?
    /// nil = use the canvas node style.
    var shape: TopicShape?
    var textSize: Double?
    var hasBoundary: Bool
    var imageData: Data?
    var imageName: String?
    /// Displayed image width in points (iThoughts `image-width`).
    var imageWidth: Double?

    init(
        colorHex: String? = nil,
        shape: TopicShape? = nil,
        textSize: Double? = nil,
        hasBoundary: Bool = false,
        imageData: Data? = nil,
        imageName: String? = nil,
        imageWidth: Double? = nil
    ) {
        self.colorHex = colorHex
        self.shape = shape
        self.textSize = textSize
        self.hasBoundary = hasBoundary
        self.imageData = imageData
        self.imageName = imageName
        self.imageWidth = imageWidth
    }

    private enum CodingKeys: String, CodingKey {
        case colorHex, shape, textSize, hasBoundary, imageData, imageName, imageWidth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        shape = try container.decodeIfPresent(TopicShape.self, forKey: .shape)
        textSize = try container.decodeIfPresent(Double.self, forKey: .textSize)
        hasBoundary = try container.decodeIfPresent(Bool.self, forKey: .hasBoundary) ?? false
        imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        imageName = try container.decodeIfPresent(String.self, forKey: .imageName)
        imageWidth = try container.decodeIfPresent(Double.self, forKey: .imageWidth)
    }

    var isDefault: Bool { self == TopicStyle() }
}

/// Values last agreed between a topic and its Apple Reminder / Calendar event.
/// Sync compares both sides against this baseline to see which side changed (3-way merge).
struct AppleSyncBaseline: Equatable, Codable {
    var title: String
    var notes: String
    var startDate: Date?
    var dueDate: Date?
    var isCompleted: Bool
    var priority: TaskPriority
    var syncedAt: Date
}

struct AppleSyncState: Equatable, Codable {
    var reminder: AppleSyncBaseline?
    var event: AppleSyncBaseline?
}

struct CanvasNode: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var body: String
    var progress: Int
    var cost: Double
    var effort: Double
    var startDate: Date?
    var dueDate: Date?
    var priority: TaskPriority
    var completedAt: Date?
    var rollupEnabled: Bool
    var appleReminderID: String?
    var appleCalendarEventID: String?
    var marker: NodeMarker
    var links: [NodeLink]
    var attachmentLinks: [String]
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var sortIndex: Double
    var parentID: UUID?
    var isCollapsed: Bool
    var style: TopicStyle
    /// People or teams assigned to the task (iThoughts `resources`).
    var resources: [String]
    var appleSync: AppleSyncState?
    /// For floating topics imported from iThoughts: the topic they float beside.
    /// They are free roots here (no parent line) but are written back under this topic.
    var floatingAnchorID: UUID?

    init(
        id: UUID,
        title: String,
        body: String = "",
        progress: Int = 0,
        cost: Double = 0,
        effort: Double = 0,
        startDate: Date? = nil,
        dueDate: Date? = nil,
        priority: TaskPriority = .none,
        completedAt: Date? = nil,
        rollupEnabled: Bool = false,
        appleReminderID: String? = nil,
        appleCalendarEventID: String? = nil,
        marker: NodeMarker = .none,
        links: [NodeLink] = [],
        attachmentLinks: [String] = [],
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        sortIndex: Double = 0,
        parentID: UUID? = nil,
        isCollapsed: Bool = false,
        style: TopicStyle = TopicStyle(),
        floatingAnchorID: UUID? = nil,
        resources: [String] = [],
        appleSync: AppleSyncState? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.progress = min(max(progress, 0), 100)
        self.cost = cost
        self.effort = effort
        self.startDate = startDate
        self.dueDate = dueDate
        self.priority = priority
        self.completedAt = completedAt
        self.rollupEnabled = rollupEnabled
        self.appleReminderID = appleReminderID
        self.appleCalendarEventID = appleCalendarEventID
        self.marker = marker
        self.links = links.isEmpty ? attachmentLinks.map(NodeLink.legacy) : links
        self.attachmentLinks = attachmentLinks.isEmpty ? self.links.map(\.urlString) : attachmentLinks
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.sortIndex = sortIndex
        self.parentID = parentID
        self.isCollapsed = isCollapsed
        self.style = style
        self.floatingAnchorID = floatingAnchorID
        self.resources = resources
        self.appleSync = appleSync
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case progress
        case cost
        case effort
        case startDate
        case dueDate
        case priority
        case completedAt
        case rollupEnabled
        case appleReminderID
        case appleCalendarEventID
        case marker
        case links
        case attachmentLinks
        case x
        case y
        case width
        case height
        case sortIndex
        case parentID
        case isCollapsed
        case style
        case floatingAnchorID
        case resources
        case appleSync
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        progress = min(max(try container.decodeIfPresent(Int.self, forKey: .progress) ?? 0, 0), 100)
        cost = try container.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        effort = try container.decodeIfPresent(Double.self, forKey: .effort) ?? 0
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        priority = try container.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .none
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        rollupEnabled = try container.decodeIfPresent(Bool.self, forKey: .rollupEnabled) ?? false
        appleReminderID = try container.decodeIfPresent(String.self, forKey: .appleReminderID)
        appleCalendarEventID = try container.decodeIfPresent(String.self, forKey: .appleCalendarEventID)
        marker = try container.decodeIfPresent(NodeMarker.self, forKey: .marker) ?? .none
        attachmentLinks = try container.decodeIfPresent([String].self, forKey: .attachmentLinks) ?? []
        links = try container.decodeIfPresent([NodeLink].self, forKey: .links) ?? attachmentLinks.map(NodeLink.legacy)
        if attachmentLinks.isEmpty {
            attachmentLinks = links.map(\.urlString)
        }
        x = try container.decode(CGFloat.self, forKey: .x)
        y = try container.decode(CGFloat.self, forKey: .y)
        width = try container.decode(CGFloat.self, forKey: .width)
        height = try container.decode(CGFloat.self, forKey: .height)
        sortIndex = try container.decodeIfPresent(Double.self, forKey: .sortIndex) ?? 0
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        style = try container.decodeIfPresent(TopicStyle.self, forKey: .style) ?? TopicStyle()
        floatingAnchorID = try container.decodeIfPresent(UUID.self, forKey: .floatingAnchorID)
        resources = try container.decodeIfPresent([String].self, forKey: .resources) ?? []
        appleSync = try container.decodeIfPresent(AppleSyncState.self, forKey: .appleSync)
    }
}
