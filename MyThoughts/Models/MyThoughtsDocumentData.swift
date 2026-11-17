import Foundation

enum MyThoughtsDocumentType: String, Codable {
    case fullMap
    case branch
}

struct MyThoughtsDocumentData: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var appName: String
    var createdAt: Date
    var updatedAt: Date
    var documentType: MyThoughtsDocumentType
    var nodes: [CanvasNode]
    var connections: [CanvasConnection]
    var summaries: [CanvasSummary]
    var relationships: [CanvasRelationship]
    var canvasAppearanceSettings: CanvasAppearance
    var notePanelSettings: NotePanelSettings
    var metadata: [String: String]

    var canvasSettings: CanvasAppearance {
        get { canvasAppearanceSettings }
        set { canvasAppearanceSettings = newValue }
    }

    var taskDisplaySettings: TaskDisplaySettings {
        get { canvasAppearanceSettings.taskDisplay }
        set { canvasAppearanceSettings.taskDisplay = newValue }
    }

    init(
        formatVersion: Int = Self.currentFormatVersion,
        appName: String = "MyThoughts",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        documentType: MyThoughtsDocumentType = .fullMap,
        nodes: [CanvasNode],
        connections: [CanvasConnection],
        summaries: [CanvasSummary] = [],
        relationships: [CanvasRelationship] = [],
        canvasAppearanceSettings: CanvasAppearance = CanvasAppearance(),
        notePanelSettings: NotePanelSettings = NotePanelSettings(),
        metadata: [String: String] = [:]
    ) {
        self.formatVersion = formatVersion
        self.appName = appName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.documentType = documentType
        self.nodes = nodes
        self.connections = connections
        self.summaries = summaries
        self.relationships = relationships
        self.canvasAppearanceSettings = canvasAppearanceSettings
        self.notePanelSettings = notePanelSettings
        self.metadata = metadata
    }

    init(
        formatVersion: Int = Self.currentFormatVersion,
        appName: String = "MyThoughts",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        documentType: MyThoughtsDocumentType = .fullMap,
        nodes: [CanvasNode],
        connections: [CanvasConnection],
        summaries: [CanvasSummary] = [],
        relationships: [CanvasRelationship] = [],
        canvasSettings: CanvasAppearance,
        notePanelSettings: NotePanelSettings = NotePanelSettings(),
        metadata: [String: String] = [:]
    ) {
        self.init(
            formatVersion: formatVersion,
            appName: appName,
            createdAt: createdAt,
            updatedAt: updatedAt,
            documentType: documentType,
            nodes: nodes,
            connections: connections,
            summaries: summaries,
            relationships: relationships,
            canvasAppearanceSettings: canvasSettings,
            notePanelSettings: notePanelSettings,
            metadata: metadata
        )
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case appName
        case createdAt
        case updatedAt
        case documentType
        case nodes
        case connections
        case summaries
        case relationships
        case canvasAppearanceSettings = "canvasSettings"
        case notePanelSettings
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()

        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.currentFormatVersion
        appName = try container.decodeIfPresent(String.self, forKey: .appName) ?? "MyThoughts"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? now
        documentType = try container.decodeIfPresent(MyThoughtsDocumentType.self, forKey: .documentType) ?? .fullMap
        nodes = try container.decodeIfPresent([CanvasNode].self, forKey: .nodes) ?? []
        connections = try container.decodeIfPresent([CanvasConnection].self, forKey: .connections) ?? []
        summaries = try container.decodeIfPresent([CanvasSummary].self, forKey: .summaries) ?? []
        relationships = try container.decodeIfPresent([CanvasRelationship].self, forKey: .relationships) ?? []
        canvasAppearanceSettings = try container.decodeIfPresent(CanvasAppearance.self, forKey: .canvasAppearanceSettings) ?? CanvasAppearance()
        notePanelSettings = try container.decodeIfPresent(NotePanelSettings.self, forKey: .notePanelSettings) ?? NotePanelSettings()
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}

typealias MyThoughtsDocument = MyThoughtsDocumentData
