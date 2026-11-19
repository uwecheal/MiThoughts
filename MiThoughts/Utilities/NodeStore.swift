import Foundation

enum MiThoughtsDocumentService {
    static let fileExtension = "mythoughts"

    static func makeDocument(
        nodes: [CanvasNode],
        connections: [CanvasConnection],
        summaries: [CanvasSummary] = [],
        relationships: [CanvasRelationship] = [],
        canvasSettings: CanvasAppearance,
        notePanelSettings: NotePanelSettings,
        documentType: MiThoughtsDocumentType = .fullMap,
        metadata: [String: String] = [:],
        createdAt: Date = Date()
    ) -> MiThoughtsDocumentData {
        MiThoughtsDocumentData(
            createdAt: createdAt,
            updatedAt: Date(),
            documentType: documentType,
            nodes: nodes,
            connections: connections,
            summaries: summaries,
            relationships: relationships,
            canvasSettings: canvasSettings,
            notePanelSettings: notePanelSettings,
            metadata: metadata
        )
    }

    static func export(
        nodes: [CanvasNode],
        connections: [CanvasConnection],
        summaries: [CanvasSummary] = [],
        relationships: [CanvasRelationship] = [],
        canvasSettings: CanvasAppearance,
        notePanelSettings: NotePanelSettings,
        documentType: MiThoughtsDocumentType = .fullMap,
        metadata: [String: String] = [:],
        createdAt: Date = Date(),
        to url: URL
    ) throws {
        let document = makeDocument(
            nodes: nodes,
            connections: connections,
            summaries: summaries,
            relationships: relationships,
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

    static func `import`(from url: URL) throws -> MiThoughtsDocumentData {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        if let document = try? decoder.decode(MiThoughtsDocumentData.self, from: data) {
            return document
        }

        if let oldDocument = try? decoder.decode(NodeStore.CanvasDocument.self, from: data) {
            return MiThoughtsDocumentData(
                nodes: oldDocument.nodes,
                connections: oldDocument.connections,
                summaries: []
            )
        }

        let oldNodes = try decoder.decode([CanvasNode].self, from: data)
        return MiThoughtsDocumentData(nodes: oldNodes, connections: [], summaries: [])
    }
}

enum MiThoughtsFileCommand {
    static let newMap = Notification.Name("MiThoughtsFileCommand.newMap")
    static let newFromTemplate = Notification.Name("MiThoughtsFileCommand.newFromTemplate")
    static let showStartScreen = Notification.Name("MiThoughtsFileCommand.showStartScreen")
    static let open = Notification.Name("MiThoughtsFileCommand.open")
    static let openRecent = Notification.Name("MiThoughtsFileCommand.openRecent")
    static let save = Notification.Name("MiThoughtsFileCommand.save")
    static let saveAs = Notification.Name("MiThoughtsFileCommand.saveAs")
    static let exportPDF = Notification.Name("MiThoughtsFileCommand.exportPDF")
    static let exportPNG = Notification.Name("MiThoughtsFileCommand.exportPNG")
    static let printMap = Notification.Name("MiThoughtsFileCommand.printMap")
    static let exportITMZ = Notification.Name("MiThoughtsFileCommand.exportITMZ")
    static let importITMZ = Notification.Name("MiThoughtsFileCommand.importITMZ")
    /// object: OutlineFormat.rawValue
    static let exportOutline = Notification.Name("MiThoughtsFileCommand.exportOutline")
    static let openURL = Notification.Name("MiThoughtsFileCommand.openURL")
}

enum MiThoughtsViewCommand {
    static let toggleOutline = Notification.Name("MiThoughtsViewCommand.toggleOutline")
    static let addRelationship = Notification.Name("MiThoughtsViewCommand.addRelationship")
    static let toggleNotes = Notification.Name("MiThoughtsViewCommand.toggleNotes")
    static let editNotes = Notification.Name("MiThoughtsViewCommand.editNotes")
    static let find = Notification.Name("MiThoughtsViewCommand.find")
    static let zoomIn = Notification.Name("MiThoughtsViewCommand.zoomIn")
    static let zoomOut = Notification.Name("MiThoughtsViewCommand.zoomOut")
    static let fitMap = Notification.Name("MiThoughtsViewCommand.fitMap")
    static let fitSelection = Notification.Name("MiThoughtsViewCommand.fitSelection")
    static let createReminder = Notification.Name("MiThoughtsViewCommand.createReminder")
    static let createEvent = Notification.Name("MiThoughtsViewCommand.createEvent")
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

enum MiThoughtsBranchCommand {
    static let perform = Notification.Name("MiThoughtsBranchCommand.perform")
}

enum RecentFilesStore {
    // Keeps the app's earlier name (MyThoughts) so existing recent files carry over.
    private static let userDefaultsKey = "RecentMyThoughtsFiles"
    /// Security-scoped bookmarks by path: in the App Sandbox a remembered path alone
    /// cannot be reopened after relaunch.
    private static let bookmarksKey = "RecentMyThoughtsBookmarks"
    private static let maximumCount = 10
    private static var accessedPaths: Set<String> = []

    /// Re-gains access to a remembered file (Open Recent, restored windows) and
    /// returns the URL to use. Harmless for files the user just picked.
    @discardableResult
    static func startAccess(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        guard !accessedPaths.contains(path) else {
            return url
        }
        var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        guard let data = bookmarks[path] else {
            return url
        }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return url
        }
        if resolved.startAccessingSecurityScopedResource() {
            accessedPaths.insert(path)
        }
        if isStale, let fresh = try? resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarks[path] = fresh
            UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
        }
        return resolved
    }

    static func load() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        var urls = load().filter { $0.standardizedFileURL.path != standardizedURL.path }
        urls.insert(standardizedURL, at: 0)
        urls = Array(urls.prefix(maximumCount))
        save(urls)

        var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        if let data = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData()) {
            bookmarks[standardizedURL.path] = data
        }
        let kept = Set(urls.map(\.path))
        bookmarks = bookmarks.filter { kept.contains($0.key) }
        UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
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
            .appendingPathComponent("MyThoughts", isDirectory: true) // earlier app name, kept so saved data is found
            .appendingPathComponent(fileName)
    }

    static func loadDocument() -> MiThoughtsDocumentData {
        let url = fileURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("MiThoughts NodeStore: no saved nodes file found at \(url.path). Starting with an empty canvas.")
            return MiThoughtsDocumentData(nodes: [], connections: [])
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()

            if let document = try? decoder.decode(MiThoughtsDocumentData.self, from: data) {
                return document
            }

            if let document = try? decoder.decode(CanvasDocument.self, from: data) {
                print("MiThoughts NodeStore: loaded legacy autosave JSON from \(url.path).")
                return MiThoughtsDocumentData(nodes: document.nodes, connections: document.connections, summaries: [])
            }

            let oldNodes = try decoder.decode([CanvasNode].self, from: data)
            print("MiThoughts NodeStore: loaded legacy node JSON from \(url.path).")
            return MiThoughtsDocumentData(nodes: oldNodes, connections: [], summaries: [])
        } catch {
            print("MiThoughts NodeStore: failed to load nodes from \(url.path): \(error). Starting with an empty canvas.")
            return MiThoughtsDocumentData(nodes: [], connections: [])
        }
    }

    static func saveDocument(
        nodes: [CanvasNode],
        connections: [CanvasConnection],
        summaries: [CanvasSummary] = [],
        relationships: [CanvasRelationship] = [],
        canvasSettings: CanvasAppearance = CanvasAppearance(),
        notePanelSettings: NotePanelSettings = NotePanelSettings(),
        createdAt: Date = Date()
    ) {
        saveDocument(
            MiThoughtsDocumentService.makeDocument(
                nodes: nodes,
                connections: connections,
                summaries: summaries,
                relationships: relationships,
                canvasSettings: canvasSettings,
                notePanelSettings: notePanelSettings,
                createdAt: createdAt
            )
        )
    }

    static func saveDocument(_ document: MiThoughtsDocumentData) {
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
            print("MiThoughts NodeStore: failed to save nodes to \(url.path): \(error)")
        }
    }
}
