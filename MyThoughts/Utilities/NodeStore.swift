import Foundation

enum MyThoughtsDocumentService {
    static let fileExtension = "mythoughts"

    static func makeDocument(
        nodes: [CanvasNode],
        connections: [CanvasConnection],
        summaries: [CanvasSummary] = [],
        canvasSettings: CanvasAppearance,
        notePanelSettings: NotePanelSettings,
        documentType: MyThoughtsDocumentType = .fullMap,
        metadata: [String: String] = [:],
        createdAt: Date = Date()
    ) -> MyThoughtsDocumentData {
        MyThoughtsDocumentData(
            createdAt: createdAt,
            updatedAt: Date(),
            documentType: documentType,
            nodes: nodes,
            connections: connections,
            summaries: summaries,
            canvasSettings: canvasSettings,
            notePanelSettings: notePanelSettings,
            metadata: metadata
        )
    }

    static func export(
        nodes: [CanvasNode],
        connections: [CanvasConnection],
        summaries: [CanvasSummary] = [],
        canvasSettings: CanvasAppearance,
        notePanelSettings: NotePanelSettings,
        documentType: MyThoughtsDocumentType = .fullMap,
        metadata: [String: String] = [:],
        createdAt: Date = Date(),
        to url: URL
    ) throws {
        let document = makeDocument(
            nodes: nodes,
            connections: connections,
            summaries: summaries,
            canvasSettings: canvasSettings,
            notePanelSettings: notePanelSettings,
            documentType: documentType,
            metadata: metadata,
            createdAt: createdAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
    }

    static func `import`(from url: URL) throws -> MyThoughtsDocumentData {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        if let document = try? decoder.decode(MyThoughtsDocumentData.self, from: data) {
            return document
        }

        if let oldDocument = try? decoder.decode(NodeStore.CanvasDocument.self, from: data) {
            return MyThoughtsDocumentData(
                nodes: oldDocument.nodes,
                connections: oldDocument.connections,
                summaries: []
            )
        }

        let oldNodes = try decoder.decode([CanvasNode].self, from: data)
        return MyThoughtsDocumentData(nodes: oldNodes, connections: [], summaries: [])
    }
}

enum MyThoughtsFileCommand {
    static let newMap = Notification.Name("MyThoughtsFileCommand.newMap")
    static let newFromTemplate = Notification.Name("MyThoughtsFileCommand.newFromTemplate")
    static let showStartScreen = Notification.Name("MyThoughtsFileCommand.showStartScreen")
    static let open = Notification.Name("MyThoughtsFileCommand.open")
    static let openRecent = Notification.Name("MyThoughtsFileCommand.openRecent")
    static let save = Notification.Name("MyThoughtsFileCommand.save")
    static let saveAs = Notification.Name("MyThoughtsFileCommand.saveAs")
    static let exportPDF = Notification.Name("MyThoughtsFileCommand.exportPDF")
    static let exportPNG = Notification.Name("MyThoughtsFileCommand.exportPNG")
    static let printMap = Notification.Name("MyThoughtsFileCommand.printMap")
}

enum MyThoughtsViewCommand {
    static let toggleOutline = Notification.Name("MyThoughtsViewCommand.toggleOutline")
}

enum BranchOperation {
    case select
    case collapse
    case expand
    case collapseChildren
    case expandChildren
    case layout
    case duplicate
    case delete
    case export
    case focus
    case createSummary
}

enum MyThoughtsBranchCommand {
    static let perform = Notification.Name("MyThoughtsBranchCommand.perform")
}

enum RecentFilesStore {
    private static let userDefaultsKey = "RecentMyThoughtsFiles"
    private static let maximumCount = 10

    static func load() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        var urls = load().filter { $0.standardizedFileURL.path != standardizedURL.path }
        urls.insert(standardizedURL, at: 0)
        save(Array(urls.prefix(maximumCount)))
    }

    static func remove(_ url: URL) {
        let standardizedPath = url.standardizedFileURL.path
        save(load().filter { $0.standardizedFileURL.path != standardizedPath })
    }

    private static func save(_ urls: [URL]) {
        UserDefaults.standard.set(urls.map(\.path), forKey: userDefaultsKey)
    }
}

enum NodeStore {
    private static let fileName = "nodes.json"

    struct CanvasDocument: Codable {
        var nodes: [CanvasNode]
        var connections: [CanvasConnection]

        static let empty = CanvasDocument(nodes: [], connections: [])
    }

    static var fileURL: URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        return applicationSupportURL
            .appendingPathComponent("MyThoughts", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func loadDocument() -> MyThoughtsDocumentData {
        let url = fileURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("MyThoughts NodeStore: no saved nodes file found at \(url.path). Starting with an empty canvas.")
            return MyThoughtsDocumentData(nodes: [], connections: [])
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()

            if let document = try? decoder.decode(MyThoughtsDocumentData.self, from: data) {
                return document
            }

            if let document = try? decoder.decode(CanvasDocument.self, from: data) {
                print("MyThoughts NodeStore: loaded legacy autosave JSON from \(url.path).")
                return MyThoughtsDocumentData(nodes: document.nodes, connections: document.connections, summaries: [])
            }

            let oldNodes = try decoder.decode([CanvasNode].self, from: data)
            print("MyThoughts NodeStore: loaded legacy node JSON from \(url.path).")
            return MyThoughtsDocumentData(nodes: oldNodes, connections: [], summaries: [])
        } catch {
            print("MyThoughts NodeStore: failed to load nodes from \(url.path): \(error). Starting with an empty canvas.")
            return MyThoughtsDocumentData(nodes: [], connections: [])
        }
    }

    static func saveDocument(
        nodes: [CanvasNode],
        connections: [CanvasConnection],
        summaries: [CanvasSummary] = [],
        canvasSettings: CanvasAppearance = CanvasAppearance(),
        notePanelSettings: NotePanelSettings = NotePanelSettings(),
        createdAt: Date = Date()
    ) {
        saveDocument(
            MyThoughtsDocumentService.makeDocument(
                nodes: nodes,
                connections: connections,
                summaries: summaries,
                canvasSettings: canvasSettings,
                notePanelSettings: notePanelSettings,
                createdAt: createdAt
            )
        )
    }

    static func saveDocument(_ document: MyThoughtsDocumentData) {
        let url = fileURL

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)
        } catch {
            print("MyThoughts NodeStore: failed to save nodes to \(url.path): \(error)")
        }
    }
}
