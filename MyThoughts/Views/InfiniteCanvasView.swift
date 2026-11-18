import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InfiniteCanvasView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var panOffset: CGSize = .zero
    @State private var zoomScale: CGFloat = 1.0
    @State private var nodes: [CanvasNode] = []
    @State private var connections: [CanvasConnection] = []
    @State private var summaries: [CanvasSummary] = []
    @State private var relationships: [CanvasRelationship] = []
    /// Set while an .itmz file is open: saving writes back into the original file's DOM.
    @State private var itmzSession: ItmzEditingSession?
    /// "Add Relationship" mode: the next clicked topic becomes the other end.
    @State private var relationshipSourceID: CanvasNode.ID?
    @State private var selectedRelationshipID: CanvasRelationship.ID?
    @State private var editingRelationshipID: CanvasRelationship.ID?
    @State private var isShowingTaskList = false
    @State private var isSyncingApple = false
    @State private var lastAppleSyncAt: Date?
    @State private var derivedData: CanvasDerivedData
    @State private var historyManager = HistoryManager()
    @State private var selectedNodeID: CanvasNode.ID?
    @State private var selectedNodeIDs: Set<CanvasNode.ID> = []
    @State private var editingNodeID: CanvasNode.ID?
    @State private var detailsNodeID: CanvasNode.ID?
    @State private var newNodeIDs: Set<CanvasNode.ID> = []
    @State private var activePanIsAllowed: Bool?
    @State private var isDraggingNode = false
    @State private var draggedNodeID: CanvasNode.ID?
    @State private var dropTargetNodeID: CanvasNode.ID?
    @State private var appearance = CanvasAppearance.load()
    @State private var notePanelSettings: NotePanelSettings
    @State private var outlineSettings: OutlineSettings
    @State private var outlineItems: [OutlineItem]
    @State private var isShowingAppearancePopover = false
    @State private var pendingImportDocument: MyThoughtsDocument?
    @State private var isShowingImportConfirmation = false
    @State private var pendingIThoughtsImportResult: IThoughtsImportResult?
    @State private var isShowingIThoughtsImportConfirmation = false
    @State private var isShowingTemplateChooser = false
    @State private var isShowingStartScreen: Bool
    @State private var currentFileURL: URL?
    @State private var isDirty = false
    @State private var lastSavedAt: Date?
    @State private var documentCreatedAt: Date
    @State private var statusMessage = ""
    @State private var isShowingStatusMessage = false
    @State private var isShowingDeleteConfirmation = false
    @State private var pendingCalendarCreationNodeID: CanvasNode.ID?
    @State private var pendingCalendarCreationAllowsDuplicate = false
    @State private var isShowingCalendarCreationConfirmation = false
    @State private var viewportSize: CGSize = .zero
    @State private var hasCenteredInitialContent = false
    @State private var noteHistoryNodeID: CanvasNode.ID?
    @State private var detailsHistoryNodeID: CanvasNode.ID?
    @State private var isShowingSearchPanel = false
    @State private var searchQuery = ""
    @State private var searchResults: [NodeSearchResult] = []
    @State private var isFocusMode = false
    @State private var focusedNodeID: CanvasNode.ID?
    @State private var dragOriginalNodePositions: [CanvasNode.ID: CGPoint] = [:]
    @State private var copiedFragment: CopiedMapFragment?
    @FocusState private var isCanvasFocused: Bool
    @FocusState private var isNoteEditorFocused: Bool
    @FocusState private var isSearchFieldFocused: Bool

    @State private var dragStartPanOffset: CGSize = .zero
    @State private var magnificationStartZoomScale: CGFloat = 1.0

    private let minimumZoomScale: CGFloat = 0.3
    private let maximumZoomScale: CGFloat = 3.0
    private let defaultNodeSize = CGSize(width: 160, height: 48)
    private let childHorizontalOffset: CGFloat = 220
    private let childVerticalSpacing: CGFloat = 90
    private let showsDebugOverlay = false

    init() {
        let document = NodeStore.loadDocument()
        var notePanelSettings = NotePanelSettings.load()
        notePanelSettings.position = .right
        var loadedNodes = document.nodes
        Self.ensureStableSortIndexes(for: &loadedNodes)

        let loadedConnections = document.connections
        let loadedSummaries = Self.cleanedSummaries(document.summaries, validNodeIDs: Set(loadedNodes.map(\.id)))
        let loadedNodeIDs = Set(loadedNodes.map(\.id))
        _relationships = State(initialValue: document.relationships.filter {
            loadedNodeIDs.contains($0.fromNodeID) && loadedNodeIDs.contains($0.toNodeID)
        })
        let initialDerivedData = CanvasDerivedData(
            nodes: loadedNodes,
            connections: loadedConnections,
            hidesCompletedTasks: CanvasAppearance.load().taskDisplay.hideCompletedTasks
        )

        _nodes = State(initialValue: loadedNodes)
        _connections = State(initialValue: loadedConnections)
        _summaries = State(initialValue: loadedSummaries)
        _derivedData = State(initialValue: initialDerivedData)
        _notePanelSettings = State(initialValue: notePanelSettings)
        _outlineSettings = State(initialValue: OutlineSettings.load())
        _isShowingStartScreen = State(initialValue: loadedNodes.isEmpty && loadedConnections.isEmpty)
        _documentCreatedAt = State(initialValue: document.createdAt)
        _outlineItems = State(initialValue: Self.buildOutlineItems(
            nodes: loadedNodes,
            derivedData: initialDerivedData,
            focusedNodeID: nil
        ))
    }

    private static func ensureStableSortIndexes(for nodes: inout [CanvasNode]) {
        let groupedIDs = Dictionary(grouping: nodes.indices, by: { nodes[$0].parentID })

        for indexes in groupedIDs.values {
            let sortedIndexes = indexes.sorted { left, right in
                if nodes[left].sortIndex == nodes[right].sortIndex {
                    return nodes[left].y < nodes[right].y
                }

                return nodes[left].sortIndex < nodes[right].sortIndex
            }

            for (offset, index) in sortedIndexes.enumerated() {
                nodes[index].sortIndex = Double(offset)
            }
        }
    }

    private static func cleanedSummaries(
        _ summaries: [CanvasSummary],
        validNodeIDs: Set<CanvasNode.ID>
    ) -> [CanvasSummary] {
        summaries.compactMap { summary in
            guard validNodeIDs.contains(summary.summaryNodeID) else {
                return nil
            }

            let summarizedNodeIDs = summary.summarizedNodeIDs.filter { validNodeIDs.contains($0) }
            guard summarizedNodeIDs.count >= 2 else {
                return nil
            }

            var cleanedSummary = summary
            cleanedSummary.summarizedNodeIDs = summarizedNodeIDs
            return cleanedSummary
        }
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                notePanelLayout

                if detailsNodeID != nil {
                    detailsOverlay
                }

                if isShowingSearchPanel {
                    searchOverlay
                }

                if isShowingTaskList {
                    taskListOverlay
                }

                if isShowingStartScreen {
                    startScreen
                        .transition(.opacity)
                        .zIndex(40)
                }
            }
            .alert(
                "Importing this file will replace the current map. Continue?",
                isPresented: $isShowingImportConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    pendingImportDocument = nil
                }

                Button("Continue", role: .destructive) {
                    applyPendingImport()
                }
            }
            .alert(
                "Importing this iThoughts file will replace the current map. Continue?",
                isPresented: $isShowingIThoughtsImportConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    pendingIThoughtsImportResult = nil
                }

                Button("Continue", role: .destructive) {
                    applyPendingIThoughtsImport()
                }
            }
            .alert("MyThoughts", isPresented: $isShowingStatusMessage) {
                Button("OK") { }
            } message: {
                Text(statusMessage)
            }
            .alert("Delete selected nodes and their child nodes?", isPresented: $isShowingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    deleteSelectedNodes(confirmingSubtreeDelete: true)
                }
            } message: {
                Text("This will delete each selected node and any descendants.")
            }
            .alert("Create Apple Calendar Event?", isPresented: $isShowingCalendarCreationConfirmation) {
                Button("Cancel", role: .cancel) {
                    pendingCalendarCreationNodeID = nil
                    pendingCalendarCreationAllowsDuplicate = false
                }

                Button("Create") {
                    if let pendingCalendarCreationNodeID {
                        createAppleCalendarEvent(
                            for: pendingCalendarCreationNodeID,
                            allowDuplicate: pendingCalendarCreationAllowsDuplicate
                        )
                    }
                    pendingCalendarCreationNodeID = nil
                    pendingCalendarCreationAllowsDuplicate = false
                }
            } message: {
                Text("MyThoughts will create a one-way Apple Calendar event from this topic.")
            }
            .sheet(isPresented: Binding(
                get: { editingRelationshipID != nil },
                set: { if !$0 { editingRelationshipID = nil } }
            )) {
                if let binding = editingRelationshipBinding {
                    RelationshipEditorView(
                        relationship: binding,
                        fromTitle: relationshipEndTitle(binding.wrappedValue.fromNodeID),
                        toTitle: relationshipEndTitle(binding.wrappedValue.toNodeID),
                        onDelete: {
                            if let id = editingRelationshipID {
                                deleteRelationship(id)
                            }
                            editingRelationshipID = nil
                        },
                        onDone: {
                            editingRelationshipID = nil
                            saveNodes()
                            focusCanvas()
                        }
                    )
                }
            }
            .sheet(isPresented: $isShowingTemplateChooser) {
                TemplateChooserView(
                    templates: BuiltInTemplateFactory.templates,
                    onChoose: { templateID in
                        isShowingTemplateChooser = false
                        applyTemplate(templateID)
                    },
                    onCancel: {
                        isShowingTemplateChooser = false
                        focusCanvas()
                    }
                )
            }
        }
    }

    private var hasWorkingMapContent: Bool {
        !nodes.isEmpty || !connections.isEmpty
    }

    private var detailsOverlay: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    detailsNodeID = nil
                    detailsHistoryNodeID = nil
                    focusCanvas()
                }

            if let node = detailsNodeBinding {
                NodeDetailsView(
                    node: node,
                    directChildCount: derivedData.directChildCounts[node.wrappedValue.id, default: 0],
                    displayedProgress: displayedProgress(for: node.wrappedValue),
                    displayedCost: displayedCost(for: node.wrappedValue),
                    displayedEffort: displayedEffort(for: node.wrappedValue),
                    onCreateAppleReminder: createAppleReminderForDetailsNode,
                    onCreateAppleReminderAgain: createAppleReminderAgainForDetailsNode,
                    onOpenAppleReminder: openAppleReminderForDetailsNode,
                    onClearAppleReminderLink: clearAppleReminderLinkForDetailsNode,
                    onCreateAppleCalendarEvent: requestAppleCalendarEventCreationForDetailsNode,
                    onCreateAppleCalendarEventAgain: requestAppleCalendarEventCreationAgainForDetailsNode,
                    onOpenAppleCalendarEvent: openAppleCalendarEventForDetailsNode,
                    onClearAppleCalendarEventLink: clearAppleCalendarEventLinkForDetailsNode,
                    onEditingBegan: recordDetailsEditSnapshotIfNeeded,
                    onLinkOpenFailed: { message in
                        showStatusMessage(message)
                    }
                ) {
                    saveNodes()
                }
                .frame(width: 460, height: 620)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { }
            }
        }
        .zIndex(20)
    }

    private var taskListOverlay: some View {
        HStack {
            Spacer()
            TaskListPanelView(
                nodes: nodes,
                isSyncing: isSyncingApple,
                lastSyncText: lastAppleSyncAt.map { "Last sync " + $0.formatted(date: .omitted, time: .shortened) },
                onJump: jumpToNode,
                onToggleDone: { id in applyTaskAction(.toggleDone, to: [id]) },
                onAddToReminders: addRemindersForTasks,
                onSync: { syncWithApple(isAutomatic: false) },
                onClose: { isShowingTaskList = false; focusCanvas() }
            )
            .frame(width: 520, height: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(.trailing, 24)
        }
        .zIndex(25)
    }

    private var searchOverlay: some View {
        VStack {
            SearchPanelView(
                query: $searchQuery,
                results: searchResults,
                isSearchFocused: $isSearchFieldFocused,
                onQueryChanged: { query in
                    searchResults = searchNodes(query: query)
                },
                onSelectResult: { result in
                    jumpToSearchResult(result)
                },
                onClose: closeSearchPanel
            )
            .frame(width: 380, height: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(.top, 24)

            Spacer()
        }
        .zIndex(30)
    }

    private var startScreen: some View {
        StartScreenView(
            recentFiles: RecentFilesStore.load(),
            hasLastWorkingMap: hasWorkingMapContent,
            onContinueLastWorkingMap: continueLastWorkingMap,
            onNewBlankMap: {
                _ = newMap()
            },
            onNewFromTemplate: showTemplateChooser,
            onOpenExistingMap: openMyThoughtsFile,
            onOpenRecentFile: openRecentFile,
            onChooseTemplate: applyTemplate
        )
        .contentShape(Rectangle())
    }

    private var notePanelLayout: some View {
        ZStack(alignment: .trailing) {
            ZStack(alignment: .leading) {
                canvasContent

                if outlineSettings.isVisible {
                    outlinePanel
                        .transition(.move(edge: .leading))
                        .zIndex(8)
                }
            }

            if notePanelSettings.isVisible {
                notePanel
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: notePanelSettings.isVisible)
        .animation(.easeInOut(duration: 0.18), value: outlineSettings.isVisible)
    }

    private var outlinePanel: some View {
        OutlineView(
            items: outlineItems,
            selectedNodeID: selectedNodeID,
            taskDisplaySettings: appearance.taskDisplay,
            onSelect: selectNodeFromOutline,
            onToggleCollapse: toggleOutlineCollapse,
            onEditTitle: editNodeTitleFromOutline,
            onBranchOperation: performBranchOperation
        )
        .frame(maxHeight: .infinity)
    }

    private var canvasContent: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                appearance.backgroundColor(for: colorScheme)
                    .ignoresSafeArea()

                if appearance.showGrid {
                    grid(in: geometry.size)
                }

                if appearance.showQuadrants {
                    quadrantLayer(in: geometry.size)
                }

                boundaryLayer(in: geometry.size)

                connectionLayer(in: geometry.size)

                summaryLayer(in: geometry.size)

                relationshipLayer(in: geometry.size)

                ForEach(derivedData.visibleNodes) { node in
                    canvasNodeView(for: binding(for: node.id))
                }

                if relationshipSourceID != nil {
                    relationshipModeIndicator
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .top)
                }

                if showsDebugOverlay {
                    debugOverlay
                        .padding(12)
                }

                if isFocusMode {
                    focusModeIndicator
                        .padding(12)
                }

                VStack {
                    Spacer()

                    HStack {
                        Spacer()

                        VStack(alignment: .trailing, spacing: 8) {
                            if appearance.showQuadrants {
                                Button("Center Axes") {
                                    centerAxes(in: geometry.size)
                                    focusCanvas()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Button {
                                isShowingTaskList.toggle()
                            } label: {
                                Label("Tasks", systemImage: "checklist")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Task list (⌥⌘T)")

                            Button("Canvas") {
                                isShowingAppearancePopover.toggle()
                                focusCanvas()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .popover(isPresented: $isShowingAppearancePopover, arrowEdge: .bottom) {
                                appearancePopover(in: geometry.size)
                            }

                        }
                        .padding(12)
                    }
                }

                if !notePanelSettings.isVisible {
                    HStack {
                        Spacer()

                        VStack {
                            Spacer()
                            notePanelOpenHandle
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(
                KeyboardEventMonitor { event in
                    handleKeyEvent(event)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .coordinateSpace(name: "canvasScreen")
            .simultaneousGesture(panGesture)
            .simultaneousGesture(zoomGesture)
            .simultaneousGesture(canvasSingleClickGesture)
            .simultaneousGesture(canvasDoubleClickGesture)
            .focusable()
            .focused($isCanvasFocused)
            .onAppear {
                viewportSize = geometry.size
                centerInitialContentIfNeeded(in: geometry.size)
                isCanvasFocused = true
                updateWindowTitle()
                DispatchQueue.main.async {
                    openPendingExternalFile()
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
                centerInitialContentIfNeeded(in: newSize)
            }
            .onChange(of: nodes) { _, _ in
                refreshDerivedData()
                validateFocusModeState()
                if isShowingSearchPanel {
                    searchResults = searchNodes(query: searchQuery)
                }
            }
            .onChange(of: connections) { _, _ in
                refreshDerivedData()
            }
            .onChange(of: currentFileURL) { _, _ in
                updateWindowTitle()
            }
            .onChange(of: isDirty) { _, _ in
                updateWindowTitle()
            }
            .onChange(of: isShowingStartScreen) { _, _ in
                updateWindowTitle()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.newMap)) { _ in
                _ = newMap()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.newFromTemplate)) { _ in
                showTemplateChooser()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.showStartScreen)) { _ in
                showStartScreen()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.open)) { _ in
                openMyThoughtsFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.openRecent)) { notification in
                if let url = notification.object as? URL {
                    openRecentFile(url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.save)) { _ in
                _ = saveCurrentFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.saveAs)) { _ in
                _ = saveCurrentFileAs()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.exportPDF)) { _ in
                exportMapAsPDF()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.exportPNG)) { _ in
                exportMapAsPNG()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.printMap)) { _ in
                printMap()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsViewCommand.toggleOutline)) { _ in
                toggleOutlineView()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.exportITMZ)) { _ in
                exportITMZFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.exportOutline)) { notification in
                if let raw = notification.object as? String, let format = OutlineFormat(rawValue: raw) {
                    exportOutlineFile(format)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.importITMZ)) { _ in
                importIThoughtsFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsFileCommand.openURL)) { _ in
                openPendingExternalFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: TaskCommand.perform)) { notification in
                if let action = notification.object as? TaskAction {
                    applyTaskAction(action, to: selectedNodeIDs.isEmpty ? Set(selectedNodeID.map { [$0] } ?? []) : selectedNodeIDs)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: TaskCommand.toggleTaskList)) { _ in
                isShowingTaskList.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: TaskCommand.syncApple)) { _ in
                syncWithApple(isAutomatic: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: TaskCommand.toggleHideCompleted)) { _ in
                updateAppearance { $0.taskDisplay.hideCompletedTasks.toggle() }
                refreshDerivedData()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                syncWithApple(isAutomatic: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsViewCommand.addRelationship)) { _ in
                addRelationshipFromSelection()
            }
            .onReceive(NotificationCenter.default.publisher(for: MyThoughtsBranchCommand.perform)) { notification in
                if let operation = notification.object as? BranchOperation {
                    performBranchOperationOnSelected(operation)
                }
            }
        }
    }

    private var notePanel: some View {
        NotePanelView(
            settings: $notePanelSettings,
            noteText: selectedNodeBodyBinding,
            editorFocus: $isNoteEditorFocused,
            onEditingBegan: recordNoteEditSnapshotIfNeeded,
            onSave: { saveNodes() },
            onSettingsChanged: saveNotePanelSettings
        )
    }

    private var notePanelOpenHandle: some View {
        Button {
            openNotePanel()
        } label: {
            Capsule()
                .fill(Color.secondary.opacity(0.28))
                .frame(width: 6, height: 54)
                .overlay {
                    Capsule()
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .help("Show Notes")
    }

    private var focusModeIndicator: some View {
        HStack(spacing: 8) {
            Text("Focus: \(focusedNodeTitle)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button("Exit") {
                exitFocusMode()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }

    private var focusedNodeTitle: String {
        guard let focusedNodeID,
              let node = nodes.first(where: { $0.id == focusedNodeID }) else {
            return "Missing Node"
        }

        return displayTitle(for: node)
    }

    private func refreshDerivedData() {
        let activeFocusNodeID = isFocusMode ? focusedNodeID : nil
        let updatedDerivedData = CanvasDerivedData(
            nodes: nodes,
            connections: connections,
            focusedNodeID: activeFocusNodeID,
            hidesCompletedTasks: appearance.taskDisplay.hideCompletedTasks
        )
        derivedData = updatedDerivedData
        outlineItems = Self.buildOutlineItems(
            nodes: nodes,
            derivedData: updatedDerivedData,
            focusedNodeID: activeFocusNodeID
        )
    }

    private static func buildOutlineItems(
        nodes: [CanvasNode],
        derivedData: CanvasDerivedData,
        focusedNodeID: CanvasNode.ID?
    ) -> [OutlineItem] {
        let sortedChildrenByParent = derivedData.childrenByParent.mapValues { children in
            children.sorted { left, right in
                if left.sortIndex == right.sortIndex {
                    return left.y < right.y
                }

                return left.sortIndex < right.sortIndex
            }
        }
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let roots: [CanvasNode]

        if let focusedNodeID,
           let focusedNode = nodesByID[focusedNodeID] {
            roots = [focusedNode]
        } else {
            roots = nodes
                .filter { $0.parentID == nil }
                .sorted { left, right in
                    if left.sortIndex == right.sortIndex {
                        return left.y < right.y
                    }

                    return left.sortIndex < right.sortIndex
                }
        }

        var items: [OutlineItem] = []
        var visitedIDs = Set<CanvasNode.ID>()

        func append(_ node: CanvasNode, depth: Int) {
            guard !visitedIDs.contains(node.id) else {
                return
            }

            visitedIDs.insert(node.id)
            let children = sortedChildrenByParent[node.id] ?? []
            items.append(
                OutlineItem(
                    id: node.id,
                    title: node.title,
                    marker: node.marker,
                    isCollapsed: node.isCollapsed,
                    hasChildren: !children.isEmpty,
                    depth: depth,
                    displayedProgress: derivedData.displayedProgressByNodeID[node.id] ?? node.progress
                )
            )

            guard !node.isCollapsed else {
                return
            }

            for child in children {
                append(child, depth: depth + 1)
            }
        }

        for root in roots {
            append(root, depth: 0)
        }

        return items
    }

    private var visibleNodeIDs: Set<CanvasNode.ID> {
        derivedData.visibleNodeIDs
    }

    private var visibleNodes: [CanvasNode] {
        derivedData.visibleNodes
    }

    private var selectedNode: CanvasNode? {
        guard let selectedNodeID else {
            return nil
        }

        return nodes.first { $0.id == selectedNodeID }
    }

    func canvasToScreenPosition(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * zoomScale + panOffset.width,
            y: point.y * zoomScale + panOffset.height
        )
    }

    func screenToCanvasPosition(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - panOffset.width) / zoomScale,
            y: (point.y - panOffset.height) / zoomScale
        )
    }

    private var panGesture: some Gesture {
        DragGesture(coordinateSpace: .named("canvasScreen"))
            .onChanged { value in
                if activePanIsAllowed == nil {
                    activePanIsAllowed = !isDraggingNode && node(at: screenToCanvasPosition(value.startLocation)) == nil
                    if activePanIsAllowed == true {
                        dropTargetNodeID = nil
                    }
                }

                guard activePanIsAllowed == true else {
                    return
                }

                panOffset = CGSize(
                    width: dragStartPanOffset.width + value.translation.width,
                    height: dragStartPanOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                dragStartPanOffset = panOffset
                activePanIsAllowed = nil
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoomScale = clampZoomScale(magnificationStartZoomScale * value)
            }
            .onEnded { _ in
                magnificationStartZoomScale = zoomScale
            }
    }

    private func clampZoomScale(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumZoomScale), maximumZoomScale)
    }

    private var canvasDoubleClickGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                let canvasPoint = screenToCanvasPosition(value.location)

                guard node(at: canvasPoint) == nil else {
                    return
                }
                if let relationshipID = relationship(at: canvasPoint) {
                    selectedRelationshipID = relationshipID
                    editingRelationshipID = relationshipID
                    return
                }
                createNode(at: canvasPoint)
            }
    }

    private var canvasSingleClickGesture: some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { value in
                let canvasPoint = screenToCanvasPosition(value.location)

                guard node(at: canvasPoint) == nil else {
                    return
                }
                if let relationshipID = relationship(at: canvasPoint) {
                    clearSelection()
                    selectedRelationshipID = relationshipID
                    return
                }
                relationshipSourceID = nil
                clearSelection()
            }
    }

    private func node(at canvasPoint: CGPoint) -> CanvasNode? {
        let visibleIDs = visibleNodeIDs

        return nodes.last { node in
            visibleIDs.contains(node.id) &&
            CGRect(x: node.x, y: node.y, width: node.width, height: node.height)
                .contains(canvasPoint)
        }
    }

    private func createNode(at canvasPoint: CGPoint) {
        let node = CanvasNode(
            id: UUID(),
            title: "",
            x: canvasPoint.x,
            y: canvasPoint.y,
            width: defaultNodeSize.width,
            height: defaultNodeSize.height
        )

        recordUndoSnapshot()
        nodes.append(node)
        selectedNodeID = node.id
        selectedNodeIDs = [node.id]
        editingNodeID = node.id
        newNodeIDs.insert(node.id)
        saveNodes()
    }

    private func focusCanvas() {
        DispatchQueue.main.async {
            isCanvasFocused = true
        }
    }

    private func toggleQuadrants(in size: CGSize) {
        if appearance.showQuadrants {
            updateAppearance {
                $0.showQuadrants = false
            }
        } else {
            updateAppearance {
                $0.showQuadrants = true
            }
            centerAxes(in: size)
        }

        focusCanvas()
    }

    private func updateAppearance(_ update: (inout CanvasAppearance) -> Void) {
        update(&appearance)
        appearance.save()
        markDirty()
    }

    private func openNotePanel() {
        notePanelSettings.position = .right
        notePanelSettings.isVisible = true
        saveNotePanelSettings()
        focusCanvas()
    }

    private func saveNotePanelSettings() {
        notePanelSettings.save()
    }

    private func toggleOutlineView() {
        outlineSettings.isVisible.toggle()
        outlineSettings.save()
        focusCanvas()
    }

    private func selectNodeFromOutline(_ nodeID: CanvasNode.ID) {
        guard nodes.contains(where: { $0.id == nodeID }) else {
            return
        }

        expandAncestors(of: nodeID)
        refreshDerivedData()
        selectSingleNode(nodeID)
        centerCanvas(on: nodeID)
        focusCanvas()
    }

    private func toggleOutlineCollapse(_ nodeID: CanvasNode.ID) {
        toggleCollapse(for: nodeID)
    }

    private func editNodeTitleFromOutline(_ nodeID: CanvasNode.ID) {
        guard nodes.contains(where: { $0.id == nodeID }) else {
            return
        }

        selectNodeFromOutline(nodeID)
        recordUndoSnapshot()
        editingNodeID = nodeID
        focusCanvas()
    }

    private func performBranchOperationOnSelected(_ operation: BranchOperation) {
        guard let selectedNodeID else {
            showStatusMessage("Select a node first.")
            return
        }

        performBranchOperation(operation, rootID: selectedNodeID)
    }

    private func performBranchOperation(_ operation: BranchOperation, rootID: CanvasNode.ID) {
        guard nodes.contains(where: { $0.id == rootID }) else {
            return
        }

        switch operation {
        case .select:
            selectBranch(rootID: rootID)
        case .collapse:
            collapseBranch(rootID: rootID)
        case .expand:
            expandBranch(rootID: rootID)
        case .collapseChildren:
            collapseDirectChildren(of: rootID)
        case .expandChildren:
            expandDirectChildren(of: rootID)
        case .layout:
            layoutBranch(rootID: rootID)
        case .duplicate:
            duplicateBranch(rootID: rootID)
        case .delete:
            deleteBranch(rootID: rootID)
        case .export:
            exportBranch(rootID: rootID)
        case .focus:
            focusBranch(rootID: rootID)
        case .createSummary:
            createSummaryFromSelection()
        }
    }

    private func branchNodeIDs(rootID: CanvasNode.ID) -> Set<CanvasNode.ID> {
        var ids = descendantIDs(of: rootID)
        ids.insert(rootID)
        return ids
    }

    private func selectBranch(rootID: CanvasNode.ID) {
        let branchIDs = branchNodeIDs(rootID: rootID)
        selectedNodeID = rootID
        selectedNodeIDs = branchIDs
        editingNodeID = nil
        noteHistoryNodeID = nil
        focusCanvas()
    }

    private func collapseBranch(rootID: CanvasNode.ID) {
        guard let rootIndex = nodes.firstIndex(where: { $0.id == rootID }),
              hasChildren(rootID),
              !nodes[rootIndex].isCollapsed else {
            return
        }

        recordUndoSnapshot()
        nodes[rootIndex].isCollapsed = true
        selectedNodeID = rootID
        selectedNodeIDs = [rootID]
        saveNodes()
        focusCanvas()
    }

    private func expandBranch(rootID: CanvasNode.ID) {
        let branchIDs = branchNodeIDs(rootID: rootID)
        let indexesToExpand = nodes.indices.filter { branchIDs.contains(nodes[$0].id) && nodes[$0].isCollapsed }
        guard !indexesToExpand.isEmpty else {
            return
        }

        recordUndoSnapshot()
        for index in indexesToExpand {
            nodes[index].isCollapsed = false
        }
        selectedNodeID = rootID
        selectedNodeIDs = [rootID]
        saveNodes()
        focusCanvas()
    }

    private func collapseDirectChildren(of rootID: CanvasNode.ID) {
        guard nodes.contains(where: { $0.id == rootID }) else {
            return
        }

        var changedIndexes: [Array<CanvasNode>.Index] = []
        if let rootIndex = nodes.firstIndex(where: { $0.id == rootID }),
           nodes[rootIndex].isCollapsed {
            changedIndexes.append(rootIndex)
        }

        let childIDs = Set(directChildren(of: rootID).map(\.id))
        changedIndexes.append(contentsOf: nodes.indices.filter { index in
            childIDs.contains(nodes[index].id) &&
            hasChildren(nodes[index].id) &&
            !nodes[index].isCollapsed
        })

        guard !changedIndexes.isEmpty else {
            return
        }

        recordUndoSnapshot()
        for index in changedIndexes {
            nodes[index].isCollapsed = index == nodes.firstIndex(where: { $0.id == rootID }) ? false : true
        }
        selectedNodeID = rootID
        selectedNodeIDs = [rootID]
        saveNodes()
        focusCanvas()
    }

    private func expandDirectChildren(of rootID: CanvasNode.ID) {
        let childIDs = Set(directChildren(of: rootID).map(\.id))
        let indexesToExpand = nodes.indices.filter { childIDs.contains(nodes[$0].id) && nodes[$0].isCollapsed }
        guard !indexesToExpand.isEmpty else {
            return
        }

        recordUndoSnapshot()
        for index in indexesToExpand {
            nodes[index].isCollapsed = false
        }
        selectedNodeID = rootID
        selectedNodeIDs = [rootID]
        saveNodes()
        focusCanvas()
    }

    private func layoutBranch(rootID: CanvasNode.ID) {
        let result = MapLayoutService.layoutBranch(nodes: nodes, rootID: rootID)
        guard result.didMoveNodes else {
            selectedNodeID = rootID
            selectedNodeIDs = [rootID]
            focusCanvas()
            return
        }

        recordUndoSnapshot()
        nodes = result.nodes
        selectedNodeID = rootID
        selectedNodeIDs = [rootID]
        editingNodeID = nil
        saveNodes()
        validateMapAfterBranchOperation("layout branch")
        focusCanvas()
    }

    private func duplicateBranch(rootID: CanvasNode.ID) {
        let branchIDs = branchNodeIDs(rootID: rootID)
        let fragment = makeCopiedFragment(from: branchIDs)
        pasteFragment(fragment, at: duplicatePastePoint(for: fragment), asChildOf: nil)
    }

    private func createSummaryFromSelection() {
        let selectedIDs = selectedVisibleNodeIDs()
        let selectedNodes = nodes.filter { selectedIDs.contains($0.id) }.sorted { left, right in
            if left.sortIndex == right.sortIndex {
                return left.y < right.y
            }

            return left.sortIndex < right.sortIndex
        }

        guard selectedNodes.count >= 2 else {
            showStatusMessage("Select multiple sibling nodes first.")
            return
        }

        let parentID = selectedNodes[0].parentID
        guard selectedNodes.allSatisfy({ $0.parentID == parentID }) else {
            showStatusMessage("Summary currently supports sibling nodes only.")
            return
        }

        let maxX = selectedNodes.map { $0.x + $0.width }.max() ?? 0
        let minY = selectedNodes.map(\.y).min() ?? 0
        let maxY = selectedNodes.map { $0.y + $0.height }.max() ?? 0
        let summaryX = maxX + 160
        let summaryY = ((minY + maxY) / 2) - (defaultNodeSize.height / 2)
        let summarySortIndex = nextSortIndex(forParentID: parentID)
        let summaryNode = CanvasNode(
            id: UUID(),
            title: "Summary",
            x: summaryX,
            y: summaryY,
            width: defaultNodeSize.width,
            height: defaultNodeSize.height,
            sortIndex: summarySortIndex,
            parentID: parentID
        )
        let summary = CanvasSummary(
            parentID: parentID,
            summarizedNodeIDs: selectedNodes.map(\.id),
            summaryNodeID: summaryNode.id,
            sortIndex: Int(summaryNode.sortIndex)
        )

        recordUndoSnapshot()
        nodes.append(summaryNode)
        if let parentID {
            ensureParentConnection(from: parentID, to: summaryNode.id)
            normalizeSiblingOrder(parentID: parentID)
        } else {
            normalizeSiblingOrder(parentID: nil)
        }
        summaries.append(summary)
        selectedNodeID = summaryNode.id
        selectedNodeIDs = [summaryNode.id]
        editingNodeID = summaryNode.id
        newNodeIDs.insert(summaryNode.id)
        saveNodes()
        focusCanvas()
    }

    private func deleteBranch(rootID: CanvasNode.ID) {
        guard nodes.contains(where: { $0.id == rootID }) else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete this branch and all child nodes?"
        alert.informativeText = "This will remove the selected node, its descendants, and related connections."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else {
            focusCanvas()
            return
        }

        deleteBranchWithoutPrompt(rootID: rootID)
    }

    private func deleteBranchWithoutPrompt(rootID: CanvasNode.ID) {
        let deletedIDs = branchNodeIDs(rootID: rootID)
        guard !deletedIDs.isEmpty else {
            return
        }

        let parentID = nodes.first(where: { $0.id == rootID })?.parentID
        recordUndoSnapshot()
        nodes.removeAll { deletedIDs.contains($0.id) }
        connections.removeAll { connection in
            deletedIDs.contains(connection.fromNodeID) || deletedIDs.contains(connection.toNodeID)
        }
        cleanupSummaries(afterDeleting: deletedIDs)

        if let parentID,
           nodes.contains(where: { $0.id == parentID }) {
            normalizeSiblingOrder(parentID: parentID)
            layoutDirectChildren(of: parentID)
        } else {
            normalizeSiblingOrder(parentID: nil)
        }

        if let focusedNodeID,
           deletedIDs.contains(focusedNodeID) {
            isFocusMode = false
            self.focusedNodeID = nil
        }

        clearSelection()
        editingNodeID = nil
        newNodeIDs.subtract(deletedIDs)
        saveNodes()
        validateMapAfterBranchOperation("delete branch")
        focusCanvas()
    }

    private func exportBranch(rootID: CanvasNode.ID) {
        selectedNodeID = rootID
        selectedNodeIDs = [rootID]
        exportSelectedBranchFile()
    }

    private func focusBranch(rootID: CanvasNode.ID) {
        selectedNodeID = rootID
        selectedNodeIDs = [rootID]
        enterFocusModeOnSelectedNode()
    }

    private func validateMapAfterBranchOperation(_ operationName: String) {
        let report = MapValidator.validate(nodes: nodes, connections: connections, summaries: summaries)
        if !report.isValid {
            print("MyThoughts \(operationName) validation:\n\(report.summary)")
        }
    }

    @discardableResult
    private func saveCurrentFile() -> Bool {
        guard let currentFileURL else {
            return saveCurrentFileAs()
        }

        return saveCurrentMap(to: currentFileURL, shouldUpdateCurrentFile: true)
    }

    @discardableResult
    private func saveCurrentFileAs() -> Bool {
        isShowingAppearancePopover = false

        let isITMZ = isITMZFile(currentFileURL)
        let savePanel = NSSavePanel()
        savePanel.title = "Save Map"
        savePanel.message = "Save as .itmz to stay compatible with iThoughts, or .mythoughts for MyThoughts-only features."
        let defaultExtension = isITMZ ? ItmzExportService.fileExtension : MyThoughtsDocumentService.fileExtension
        savePanel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "\(suggestedMapFileName).\(defaultExtension)"
        savePanel.canCreateDirectories = true
        savePanel.allowedContentTypes = isITMZ
            ? [iThoughtsDocumentContentType, myThoughtsDocumentContentType]
            : [myThoughtsDocumentContentType, iThoughtsDocumentContentType]

        guard savePanel.runModal() == .OK,
              var url = savePanel.url else {
            focusCanvas()
            return false
        }

        let pathExtension = url.pathExtension.lowercased()
        if pathExtension != MyThoughtsDocumentService.fileExtension && pathExtension != ItmzExportService.fileExtension {
            url.appendPathExtension(defaultExtension)
        }

        return saveCurrentMap(to: url, shouldUpdateCurrentFile: true)
    }

    @discardableResult
    private func saveCurrentMap(to url: URL, shouldUpdateCurrentFile: Bool) -> Bool {
        let validationReport = MapValidator.validate(nodes: nodes, connections: connections, summaries: summaries)
        if !validationReport.isValid {
            print("MyThoughts save validation:\n\(validationReport.summary)")
        }

        if isITMZFile(url) {
            return saveCurrentMapAsITMZ(to: url, shouldUpdateCurrentFile: shouldUpdateCurrentFile)
        }

        do {
            try MyThoughtsDocumentService.export(
                nodes: nodes,
                connections: connections,
                summaries: summaries,
                relationships: relationships,
                canvasSettings: appearance,
                notePanelSettings: notePanelSettings,
                createdAt: documentCreatedAt,
                to: url
            )

            if shouldUpdateCurrentFile {
                itmzSession = nil
                currentFileURL = url
                RecentFilesStore.add(url)
                isDirty = false
                lastSavedAt = Date()
                updateWindowTitle()
            }

            showStatusMessage("Saved MyThoughts file.")
            focusCanvas()
            return true
        } catch {
            print("MyThoughts save: failed to save file to \(url.path): \(error).")
            showStatusMessage("Could not save MyThoughts file: \(error.localizedDescription)")
            focusCanvas()
            return false
        }
    }

    private func openMyThoughtsFile() {
        isShowingAppearancePopover = false

        guard confirmUnsavedChangesIfNeeded() else {
            focusCanvas()
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.title = "Open Map"
        openPanel.message = "Open a MyThoughts (.mythoughts) or iThoughts (.itmz) map, or an OPML, Markdown or FreeMind outline."
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [myThoughtsDocumentContentType, iThoughtsDocumentContentType]
            + OutlineFormat.importExtensions.compactMap { UTType(filenameExtension: $0) }

        guard openPanel.runModal() == .OK,
              let url = openPanel.url else {
            focusCanvas()
            return
        }

        openMyThoughtsFile(at: url)
    }

    private func openRecentFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            RecentFilesStore.remove(url)
            showStatusMessage("Recent file no longer exists.")
            focusCanvas()
            return
        }

        guard confirmUnsavedChangesIfNeeded() else {
            focusCanvas()
            return
        }

        openMyThoughtsFile(at: url)
    }

    private func openMyThoughtsFile(at url: URL) {
        if isITMZFile(url) {
            openITMZFile(at: url)
            return
        }
        if OutlineFormat(fileExtension: url.pathExtension) != nil {
            openOutlineFile(at: url)
            return
        }

        do {
            let document = try MyThoughtsDocumentService.import(from: url)
            guard document.documentType == .fullMap else {
                showStatusMessage("Open expects a full MyThoughts map. Use Import for branch files.")
                focusCanvas()
                return
            }

            applyOpenedDocument(document, from: url)
            showStatusMessage("Opened MyThoughts file.")
        } catch {
            RecentFilesStore.remove(url)
            print("MyThoughts open: failed to open \(url.path): \(error).")
            showStatusMessage("Could not open MyThoughts file: \(error.localizedDescription)")
            focusCanvas()
        }
    }

    @discardableResult
    private func newMap() -> Bool {
        guard confirmUnsavedChangesIfNeeded() else {
            focusCanvas()
            return false
        }

        nodes = []
        connections = []
        summaries = []
        relationships = []
        itmzSession = nil
        relationshipSourceID = nil
        clearSelection()
        editingNodeID = nil
        detailsNodeID = nil
        isFocusMode = false
        focusedNodeID = nil
        newNodeIDs.removeAll()
        draggedNodeID = nil
        dropTargetNodeID = nil
        isDraggingNode = false
        currentFileURL = nil
        lastSavedAt = nil
        documentCreatedAt = Date()
        isDirty = false
        historyManager.removeAll()
        saveNodes(markDirty: false)
        hasCenteredInitialContent = false
        centerInitialContentIfNeeded(in: viewportSize)
        isShowingStartScreen = false
        updateWindowTitle()
        showStatusMessage("Created new untitled map.")
        focusCanvas()
        return true
    }

    private func showTemplateChooser() {
        isShowingAppearancePopover = false

        guard confirmUnsavedChangesIfNeeded() else {
            focusCanvas()
            return
        }

        isShowingTemplateChooser = true
    }

    private func showStartScreen() {
        isShowingAppearancePopover = false
        detailsNodeID = nil
        isShowingSearchPanel = false

        guard confirmUnsavedChangesIfNeeded() else {
            focusCanvas()
            return
        }

        isShowingStartScreen = true
        updateWindowTitle()
    }

    private func continueLastWorkingMap() {
        isShowingStartScreen = false
        focusCanvas()
        updateWindowTitle()
    }

    private func applyTemplate(_ templateID: TemplateID) {
        let generatedMap = BuiltInTemplateFactory.generate(templateID, nodeSize: defaultNodeSize)
        let repairResult = MapValidator.repair(
            nodes: generatedMap.nodes,
            connections: generatedMap.connections
        )

        nodes = repairResult.nodes
        connections = repairResult.connections
        summaries = []
        relationships = []
        itmzSession = nil

        clearSelection()
        editingNodeID = nil
        detailsNodeID = nil
        isFocusMode = false
        focusedNodeID = nil
        newNodeIDs.removeAll()
        draggedNodeID = nil
        dropTargetNodeID = nil
        isDraggingNode = false
        currentFileURL = nil
        lastSavedAt = nil
        documentCreatedAt = Date()
        isDirty = false
        historyManager.removeAll()

        if generatedMap.enableQuadrants {
            appearance.showQuadrants = true
            appearance.save()
        }

        refreshDerivedData()

        if let generatedRootNodeID = generatedMap.rootNodeID,
           let rootNodeID = repairResult.nodes.first(where: { $0.id == generatedRootNodeID })?.id {
            selectedNodeID = rootNodeID
            selectedNodeIDs = [rootNodeID]
        }

        saveNodes(markDirty: false)
        hasCenteredInitialContent = false
        isShowingStartScreen = false

        if let selectedNodeID {
            centerCanvas(on: selectedNodeID)
            hasCenteredInitialContent = true
        } else {
            centerInitialContentIfNeeded(in: viewportSize)
        }

        updateWindowTitle()

        if !repairResult.actions.isEmpty {
            print("MyThoughts template repair:\n\(repairResult.summary)")
        }

        showStatusMessage("Created new map from template.")
        focusCanvas()
    }

    private func applyOpenedDocument(_ document: MyThoughtsDocument, from url: URL) {
        let repairResult = MapValidator.repair(nodes: document.nodes, connections: document.connections, summaries: document.summaries)
        nodes = repairResult.nodes
        connections = repairResult.connections
        summaries = repairResult.summaries
        relationships = document.relationships
        itmzSession = nil
        appearance = document.canvasSettings
        notePanelSettings = document.notePanelSettings

        clearSelection()
        editingNodeID = nil
        detailsNodeID = nil
        isFocusMode = false
        focusedNodeID = nil
        newNodeIDs.removeAll()
        draggedNodeID = nil
        dropTargetNodeID = nil
        isDraggingNode = false
        historyManager.removeAll()

        refreshDerivedData()
        if let rootNodeID = nodes.first(where: { $0.parentID == nil })?.id ?? nodes.first?.id {
            selectedNodeID = rootNodeID
            selectedNodeIDs = [rootNodeID]
            centerCanvas(on: rootNodeID)
        }

        currentFileURL = url
        RecentFilesStore.add(url)
        lastSavedAt = Date()
        documentCreatedAt = document.createdAt
        isDirty = false
        saveNodes(markDirty: false)
        appearance.save()
        saveNotePanelSettings()
        isShowingStartScreen = false
        updateWindowTitle()

        if !repairResult.actions.isEmpty {
            print("MyThoughts open repair:\n\(repairResult.summary)")
        }
    }

    private func confirmUnsavedChangesIfNeeded() -> Bool {
        guard isDirty else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes. Save before opening another file?"
        alert.informativeText = "Your local autosave remains available, but explicit file changes have not been saved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveCurrentFile()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// The map window, also when the app is not frontmost (keyWindow is nil then).
    private static var mainWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    private func updateWindowTitle() {
        guard !isShowingStartScreen else {
            DispatchQueue.main.async {
                Self.mainWindow?.title = "MyThoughts"
            }
            return
        }

        let baseTitle = currentFileURL.map { url in
            isITMZFile(url) ? "\(url.lastPathComponent) — iThoughts" : url.lastPathComponent
        } ?? "Untitled"
        let title = isDirty ? "\(baseTitle) *" : baseTitle

        DispatchQueue.main.async {
            Self.mainWindow?.title = title
        }
    }

    private func exportMyThoughtsFile() {
        isShowingAppearancePopover = false

        let savePanel = NSSavePanel()
        savePanel.title = "Export MyThoughts File"
        savePanel.nameFieldStringValue = "MyThoughts.\(MyThoughtsDocumentService.fileExtension)"
        savePanel.canCreateDirectories = true
        savePanel.allowedContentTypes = [myThoughtsDocumentContentType]

        guard savePanel.runModal() == .OK,
              var url = savePanel.url else {
            focusCanvas()
            return
        }

        if url.pathExtension.lowercased() != MyThoughtsDocumentService.fileExtension {
            url.appendPathExtension(MyThoughtsDocumentService.fileExtension)
        }

        do {
            try MyThoughtsDocumentService.export(
                nodes: nodes,
                connections: connections,
                summaries: summaries,
                relationships: relationships,
                canvasSettings: appearance,
                notePanelSettings: notePanelSettings,
                createdAt: documentCreatedAt,
                to: url
            )
            print("MyThoughts export: saved document to \(url.path).")
            showStatusMessage("Exported MyThoughts file.")
        } catch {
            print("MyThoughts export: failed to save document: \(error).")
            showStatusMessage("Could not export MyThoughts file: \(error.localizedDescription)")
        }

        focusCanvas()
    }

    private func exportSelectedBranchFile() {
        isShowingAppearancePopover = false

        let branchIDs = collectSubtreeIDs(from: selectedVisibleNodeIDs())
        guard !branchIDs.isEmpty else {
            showStatusMessage("Select a node first.")
            return
        }

        let fragment = makeCopiedFragment(from: branchIDs)
        let branchNodes = sanitizedBranchNodes(from: fragment)
        let branchNodeIDs = Set(branchNodes.map(\.id))
        let branchConnections = fragment.connections.filter { connection in
            branchNodeIDs.contains(connection.fromNodeID) &&
            branchNodeIDs.contains(connection.toNodeID)
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Export Selected Branch"
        savePanel.nameFieldStringValue = "MyThoughts Branch.\(MyThoughtsDocumentService.fileExtension)"
        savePanel.canCreateDirectories = true
        savePanel.allowedContentTypes = [myThoughtsDocumentContentType]

        guard savePanel.runModal() == .OK,
              var url = savePanel.url else {
            focusCanvas()
            return
        }

        if url.pathExtension.lowercased() != MyThoughtsDocumentService.fileExtension {
            url.appendPathExtension(MyThoughtsDocumentService.fileExtension)
        }

        do {
            try MyThoughtsDocumentService.export(
                nodes: branchNodes,
                connections: branchConnections,
                summaries: branchSummaries(from: fragment, exportedNodeIDs: branchNodeIDs),
                canvasSettings: appearance,
                notePanelSettings: notePanelSettings,
                documentType: .branch,
                metadata: [
                    "exportedNodeCount": "\(branchNodes.count)",
                    "exportedConnectionCount": "\(branchConnections.count)"
                ],
                createdAt: Date(),
                to: url
            )
            print("MyThoughts branch export: saved document to \(url.path).")
            showStatusMessage("Exported selected branch.")
        } catch {
            print("MyThoughts branch export: failed to save document: \(error).")
            showStatusMessage("Could not export selected branch: \(error.localizedDescription)")
        }

        focusCanvas()
    }

    private func exportMapAsPDF() {
        isShowingAppearancePopover = false

        let savePanel = NSSavePanel()
        savePanel.title = "Export as PDF"
        savePanel.nameFieldStringValue = "MyThoughts Map.pdf"
        savePanel.canCreateDirectories = true
        savePanel.allowedContentTypes = [.pdf]

        guard savePanel.runModal() == .OK,
              var url = savePanel.url else {
            focusCanvas()
            return
        }

        if url.pathExtension.lowercased() != "pdf" {
            url.appendPathExtension("pdf")
        }

        do {
            try MapExportRenderer.writePDF(payload: currentMapExportPayload(), to: url)
            showStatusMessage("Exported PDF.")
        } catch {
            print("MyThoughts PDF export: failed to export \(url.path): \(error).")
            showStatusMessage("Could not export PDF: \(error.localizedDescription)")
        }

        focusCanvas()
    }

    private func exportMapAsPNG() {
        isShowingAppearancePopover = false

        let savePanel = NSSavePanel()
        savePanel.title = "Export as PNG"
        savePanel.nameFieldStringValue = "MyThoughts Map.png"
        savePanel.canCreateDirectories = true
        savePanel.allowedContentTypes = [.png]

        guard savePanel.runModal() == .OK,
              var url = savePanel.url else {
            focusCanvas()
            return
        }

        if url.pathExtension.lowercased() != "png" {
            url.appendPathExtension("png")
        }

        do {
            let result = try MapExportRenderer.writePNG(payload: currentMapExportPayload(), to: url)
            if let warning = result.warning {
                showStatusMessage("Exported PNG.\n\n\(warning)")
            } else {
                showStatusMessage("Exported PNG.")
            }
        } catch {
            print("MyThoughts PNG export: failed to export \(url.path): \(error).")
            showStatusMessage("Could not export PNG: \(error.localizedDescription)")
        }

        focusCanvas()
    }

    private func printMap() {
        isShowingAppearancePopover = false
        MapExportRenderer.print(payload: currentMapExportPayload())
        focusCanvas()
    }

    private func currentMapExportPayload() -> MapExportPayload {
        let visibleNodes = derivedData.visibleNodes
        let visibleIDs = Set(visibleNodes.map(\.id))
        let visibleConnections = connections.filter { connection in
            visibleIDs.contains(connection.fromNodeID) &&
            visibleIDs.contains(connection.toNodeID)
        }
        let displayedProgressByNodeID = Dictionary(
            uniqueKeysWithValues: visibleNodes.map { node in
                (node.id, displayedProgress(for: node))
            }
        )

        return MapExportPayload(
            nodes: visibleNodes,
            connections: visibleConnections,
            summaries: visibleSummaries(for: visibleIDs),
            appearance: appearance,
            colorScheme: colorScheme,
            displayedProgressByNodeID: displayedProgressByNodeID,
            relationships: relationships.filter { visibleIDs.contains($0.fromNodeID) && visibleIDs.contains($0.toNodeID) },
            effectiveColorHexByNodeID: derivedData.effectiveColorHexByNodeID
        )
    }

    private func summaryRenderItems() -> [SummaryRenderItem] {
        let visibleIDs = visibleNodeIDs
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return summaries.compactMap { summary in
            guard let summaryNode = nodesByID[summary.summaryNodeID],
                  visibleIDs.contains(summaryNode.id) else {
                return nil
            }

            let summarizedNodes = summary.summarizedNodeIDs.compactMap { nodeID -> CanvasNode? in
                guard visibleIDs.contains(nodeID) else {
                    return nil
                }

                return nodesByID[nodeID]
            }

            guard summarizedNodes.count >= 2 else {
                return nil
            }

            let maxX = summarizedNodes.map { $0.x + $0.width }.max() ?? 0
            let topY = summarizedNodes.map { $0.y + $0.height / 2 }.min() ?? 0
            let bottomY = summarizedNodes.map { $0.y + $0.height / 2 }.max() ?? 0
            return SummaryRenderItem(
                bracketX: maxX + 34,
                topY: topY,
                bottomY: bottomY,
                summaryPoint: CGPoint(x: summaryNode.x, y: summaryNode.y + summaryNode.height / 2)
            )
        }
    }

    private func visibleSummaries(for visibleIDs: Set<CanvasNode.ID>) -> [CanvasSummary] {
        summaries.filter { summary in
            visibleIDs.contains(summary.summaryNodeID) &&
            summary.summarizedNodeIDs.filter { visibleIDs.contains($0) }.count >= 2
        }
    }

    private func importMyThoughtsFile() {
        isShowingAppearancePopover = false

        let openPanel = NSOpenPanel()
        openPanel.title = "Import MyThoughts File"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [myThoughtsDocumentContentType]

        guard openPanel.runModal() == .OK,
              let url = openPanel.url else {
            focusCanvas()
            return
        }

        do {
            let document = try MyThoughtsDocumentService.import(from: url)
            if document.documentType == .branch {
                importBranchDocument(document)
            } else {
                pendingImportDocument = document
                isShowingImportConfirmation = true
            }
        } catch {
            pendingImportDocument = nil
            print("MyThoughts import: failed to load document from \(url.path): \(error).")
            showStatusMessage("Could not import MyThoughts file: \(error.localizedDescription)")
            focusCanvas()
        }
    }

    private func importIThoughtsFile() {
        isShowingAppearancePopover = false

        let openPanel = NSOpenPanel()
        openPanel.title = "Import iThoughts .itmz"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [iThoughtsDocumentContentType]

        guard openPanel.runModal() == .OK,
              let url = openPanel.url else {
            focusCanvas()
            return
        }

        do {
            pendingIThoughtsImportResult = try IThoughtsImportService.import(from: url)
            isShowingIThoughtsImportConfirmation = true
        } catch {
            pendingIThoughtsImportResult = nil
            print("iThoughts import: failed to load \(url.path): \(error).")
            showStatusMessage("Could not import iThoughts file: \(error.localizedDescription)")
            focusCanvas()
        }
    }

    /// Opens a file handed over by Finder, if one is waiting.
    private func openPendingExternalFile() {
        guard let url = ExternalOpenQueue.takeLatest() else {
            return
        }
        if currentFileURL?.standardizedFileURL == url.standardizedFileURL && !isDirty {
            isShowingStartScreen = false
            return
        }
        openRecentFile(url)
    }

    // MARK: iThoughts (.itmz) files

    private func isITMZFile(_ url: URL?) -> Bool {
        url?.pathExtension.lowercased() == ItmzExportService.fileExtension
    }

    private var suggestedMapFileName: String {
        let rootTitle = nodes.filter { $0.parentID == nil }
            .min { $0.sortIndex < $1.sortIndex }
            .map { TopicText.plain($0.title).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let firstLine = rootTitle.split(separator: "\n").first.map(String.init) ?? ""
        let cleaned = firstLine.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))
    }

    /// Opens an .itmz for editing in place: Save writes back into the same file.
    private func openITMZFile(at url: URL) {
        do {
            let opened = try ItmzExportService.open(url)
            let result = opened.result
            let repairResult = MapValidator.repair(
                nodes: result.nodes,
                connections: result.connections,
                summaries: result.summaries
            )
            nodes = repairResult.nodes
            connections = repairResult.connections
            summaries = repairResult.summaries
            relationships = result.relationships
            itmzSession = opened.session

            clearSelection()
            editingNodeID = nil
            detailsNodeID = nil
            isFocusMode = false
            focusedNodeID = nil
            newNodeIDs.removeAll()
            draggedNodeID = nil
            dropTargetNodeID = nil
            isDraggingNode = false
            relationshipSourceID = nil
            historyManager.removeAll()
            refreshDerivedData()

            if let rootID = result.rootNodeIDs.first(where: { id in nodes.contains { $0.id == id } }) ?? nodes.first?.id {
                selectedNodeID = rootID
                selectedNodeIDs = [rootID]
                centerCanvas(on: rootID)
            }

            currentFileURL = url
            RecentFilesStore.add(url)
            lastSavedAt = Date()
            documentCreatedAt = Date()
            isDirty = false
            saveNodes(markDirty: false)
            hasCenteredInitialContent = true
            isShowingStartScreen = false
            updateWindowTitle()

            var message = "Opened iThoughts map (\(result.report.importedDescription))."
            if let notes = result.report.notImportedDescription {
                message += "\n\n\(notes)"
            }
            if !repairResult.actions.isEmpty {
                print("iThoughts open repair:\n\(repairResult.summary)")
            }
            showStatusMessage(message)
        } catch {
            RecentFilesStore.remove(url)
            print("iThoughts open: failed to open \(url.path): \(error).")
            showStatusMessage("Could not open iThoughts file: \(error.localizedDescription)")
        }
        focusCanvas()
    }

    @discardableResult
    private func saveCurrentMapAsITMZ(to url: URL, shouldUpdateCurrentFile: Bool) -> Bool {
        // Keep the original file's DOM only when saving that same file (or exporting from it).
        let session = itmzSession
        do {
            let result = try ItmzExportService.save(
                nodes: nodes,
                summaries: summaries,
                relationships: relationships,
                session: session,
                to: url
            )
            if shouldUpdateCurrentFile {
                itmzSession = result.session
                currentFileURL = url
                RecentFilesStore.add(url)
                isDirty = false
                lastSavedAt = Date()
                updateWindowTitle()
            }
            let report = result.report
            var message = "Saved iThoughts file."
            let changes = [
                report.created > 0 ? "\(report.created) new" : nil,
                report.changed > 0 ? "\(report.changed) changed" : nil,
                report.moved > 0 ? "\(report.moved) moved" : nil,
                report.deleted > 0 ? "\(report.deleted) deleted" : nil
            ].compactMap { $0 }
            if session != nil && !changes.isEmpty {
                message += " Topics: " + changes.joined(separator: ", ") + "."
            }
            if let backupURL = result.backupURL {
                message += "\n\nThe previous version was backed up to \(backupURL.lastPathComponent)."
            }
            showStatusMessage(message)
            focusCanvas()
            return true
        } catch {
            print("iThoughts save: failed to write \(url.path): \(error).")
            showStatusMessage("Could not save iThoughts file: \(error.localizedDescription)")
            focusCanvas()
            return false
        }
    }

    private func exportITMZFile() {
        isShowingAppearancePopover = false

        let savePanel = NSSavePanel()
        savePanel.title = "Export as iThoughts"
        savePanel.nameFieldStringValue = "\(suggestedMapFileName).\(ItmzExportService.fileExtension)"
        savePanel.canCreateDirectories = true
        savePanel.allowedContentTypes = [iThoughtsDocumentContentType]

        guard savePanel.runModal() == .OK, var url = savePanel.url else {
            focusCanvas()
            return
        }
        if url.pathExtension.lowercased() != ItmzExportService.fileExtension {
            url.appendPathExtension(ItmzExportService.fileExtension)
        }

        do {
            // Exporting a copy: do not let the export redirect the open session's file.
            let exportSession: ItmzEditingSession?
            if let itmzSession {
                exportSession = ItmzEditingSession(
                    document: try ItmzDocument(data: try itmzSession.document.archiveData()),
                    topicUUIDs: itmzSession.topicUUIDs,
                    relationshipUUIDs: itmzSession.relationshipUUIDs,
                    canvasOffset: itmzSession.canvasOffset
                )
            } else {
                exportSession = nil
            }
            _ = try ItmzExportService.save(
                nodes: nodes,
                summaries: summaries,
                relationships: relationships,
                session: exportSession,
                to: url
            )
            showStatusMessage("Exported iThoughts file \(url.lastPathComponent).")
        } catch {
            print("iThoughts export: failed to write \(url.path): \(error).")
            showStatusMessage("Could not export iThoughts file: \(error.localizedDescription)")
        }
        focusCanvas()
    }

    // MARK: Tasks

    /// All resource names used in the map, for the Task ▸ Resources menu.
    private var knownResources: [String] {
        Array(Set(nodes.flatMap(\.resources))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func applyTaskAction(_ action: TaskAction, to ids: Set<CanvasNode.ID>) {
        guard !ids.isEmpty else {
            showStatusMessage("Select a topic first.")
            return
        }
        recordUndoSnapshot()
        let now = Date()
        for index in nodes.indices where ids.contains(nodes[index].id) {
            TaskAction.apply(action, to: &nodes[index], now: now)
        }
        saveNodes()
    }

    private func jumpToNode(_ nodeID: CanvasNode.ID) {
        guard nodes.contains(where: { $0.id == nodeID }) else {
            return
        }
        if isFocusMode, !isNodeVisibleInFocusMode(nodeID) {
            exitFocusMode()
        }
        if appearance.taskDisplay.hideCompletedTasks,
           nodes.first(where: { $0.id == nodeID })?.completedAt != nil {
            updateAppearance { $0.taskDisplay.hideCompletedTasks = false }
        }
        expandAncestors(of: nodeID)
        refreshDerivedData()
        selectNode(nodeID)
        centerCanvas(on: nodeID)
    }

    private func addRemindersForTasks(_ ids: [CanvasNode.ID]) {
        let targets = nodes.filter { ids.contains($0.id) && $0.appleReminderID == nil }
        guard !targets.isEmpty, !isSyncingApple else {
            return
        }
        isSyncingApple = true
        Task { @MainActor in
            defer { isSyncingApple = false }
            do {
                let created = try await AppleIntegrationService.createReminders(for: targets)
                for index in nodes.indices {
                    if let reminderID = created[nodes[index].id] {
                        nodes[index].appleReminderID = reminderID
                        var syncState = nodes[index].appleSync ?? AppleSyncState()
                        syncState.reminder = AppleIntegrationService.reminderValues(of: nodes[index])
                        nodes[index].appleSync = syncState
                    }
                }
                saveNodes()
                showStatusMessage("Added \(created.count) task(s) to Apple Reminders. Changes made there come back with Sync.")
            } catch {
                showStatusMessage(appleReminderErrorMessage(for: error))
            }
        }
    }

    /// Two-way sync with linked Reminders and Calendar events.
    /// Automatic runs (when the app becomes active) are throttled and quiet unless something changed.
    private func syncWithApple(isAutomatic: Bool) {
        guard !isSyncingApple else {
            return
        }
        let hasLinks = nodes.contains { $0.appleReminderID != nil || $0.appleCalendarEventID != nil }
        if isAutomatic {
            guard hasLinks, appearance.taskDisplay.autoSyncWithApple else {
                return
            }
            if let lastAppleSyncAt, Date().timeIntervalSince(lastAppleSyncAt) < 60 {
                return
            }
        }
        isSyncingApple = true
        let snapshot = nodes
        Task { @MainActor in
            let result = await AppleIntegrationService.sync(nodes: snapshot)
            isSyncingApple = false
            lastAppleSyncAt = Date()
            // Only apply if the map was not edited meanwhile (otherwise the next sync merges it).
            guard nodes == snapshot else {
                return
            }
            let changedMap = result.nodes != snapshot
            if changedMap {
                recordUndoSnapshot()
                nodes = result.nodes
                saveNodes(markDirty: result.report.pulled > 0 || result.nodes.map(\.appleReminderID) != snapshot.map(\.appleReminderID))
            }
            if !isAutomatic || result.report.pulled > 0 || result.report.unlinked > 0 || !result.report.errors.isEmpty {
                showStatusMessage(result.report.summary)
            }
        }
    }

    // MARK: Outline formats (Markdown, OPML, FreeMind)

    /// Opens an outline as a new, untitled map (Save asks where to store it).
    private func openOutlineFile(at url: URL) {
        do {
            let result = try OutlineFormatService.importFile(at: url)
            nodes = result.nodes
            connections = result.connections
            summaries = []
            relationships = result.relationships
            itmzSession = nil

            clearSelection()
            editingNodeID = nil
            detailsNodeID = nil
            isFocusMode = false
            focusedNodeID = nil
            newNodeIDs.removeAll()
            relationshipSourceID = nil
            historyManager.removeAll()
            refreshDerivedData()
            selectedNodeID = result.rootNodeID
            selectedNodeIDs = [result.rootNodeID]
            centerCanvas(on: result.rootNodeID)

            currentFileURL = nil
            lastSavedAt = nil
            documentCreatedAt = Date()
            saveNodes(markDirty: true)
            hasCenteredInitialContent = true
            isShowingStartScreen = false
            updateWindowTitle()
            showStatusMessage("Imported \(url.lastPathComponent) (\(result.topicCount) topics) as a new map. Use Save to keep it.")
        } catch {
            print("Outline import: failed to read \(url.path): \(error).")
            showStatusMessage("Could not open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        focusCanvas()
    }

    private func exportOutlineFile(_ format: OutlineFormat) {
        isShowingAppearancePopover = false
        guard !nodes.isEmpty else {
            showStatusMessage("The map is empty.")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Export as \(format.label)"
        savePanel.nameFieldStringValue = "\(suggestedMapFileName).\(format.fileExtension)"
        savePanel.canCreateDirectories = true
        if let type = UTType(filenameExtension: format.fileExtension) {
            savePanel.allowedContentTypes = [type]
        }
        guard savePanel.runModal() == .OK, var url = savePanel.url else {
            focusCanvas()
            return
        }
        if url.pathExtension.lowercased() != format.fileExtension {
            url.appendPathExtension(format.fileExtension)
        }

        do {
            let written = try OutlineFormatService.export(
                format,
                nodes: nodes,
                relationships: relationships,
                title: suggestedMapFileName,
                to: url
            )
            let images = written.count - 1
            showStatusMessage("Exported \(url.lastPathComponent)." + (images > 0 ? " \(images) image(s) were copied next to it." : ""))
        } catch {
            print("\(format.label) export: failed to write \(url.path): \(error).")
            showStatusMessage("Could not export \(format.label): \(error.localizedDescription)")
        }
        focusCanvas()
    }

    // MARK: Relationships

    private var editingRelationshipBinding: Binding<CanvasRelationship>? {
        guard let editingRelationshipID,
              relationships.contains(where: { $0.id == editingRelationshipID }) else {
            return nil
        }
        return Binding(
            get: {
                relationships.first { $0.id == editingRelationshipID }
                    ?? CanvasRelationship(fromNodeID: UUID(), toNodeID: UUID())
            },
            set: { newValue in
                guard let index = relationships.firstIndex(where: { $0.id == editingRelationshipID }) else {
                    return
                }
                if relationships[index] != newValue {
                    recordRelationshipEditSnapshotIfNeeded()
                    relationships[index] = newValue
                    markDirty()
                }
            }
        )
    }

    private func recordRelationshipEditSnapshotIfNeeded() {
        guard detailsHistoryNodeID != editingRelationshipID else {
            return
        }
        recordUndoSnapshot()
        detailsHistoryNodeID = editingRelationshipID
    }

    private func relationshipEndTitle(_ nodeID: CanvasNode.ID) -> String {
        guard let node = nodes.first(where: { $0.id == nodeID }) else {
            return "Missing topic"
        }
        let title = TopicText.plain(node.title).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? (node.style.imageData != nil ? "Image" : "Untitled") : String(title.prefix(60))
    }

    private var relationshipModeIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
            Text("Click the topic to connect to “\(relationshipSourceID.map(relationshipEndTitle) ?? "")”.  Esc cancels.")
                .lineLimit(1)
            Button("Cancel") {
                relationshipSourceID = nil
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
    }

    /// Two topics selected: connect them. One selected: start "click the other end" mode.
    private func addRelationshipFromSelection() {
        let selected = nodes.filter { selectedNodeIDs.contains($0.id) }
        if selected.count == 2 {
            let ordered = selectedNodeID == selected[1].id ? [selected[0], selected[1]] : [selected[1], selected[0]]
            createRelationship(from: ordered[0].id, to: ordered[1].id)
        } else if let selectedNodeID {
            relationshipSourceID = selectedNodeID
        } else {
            showStatusMessage("Select one topic (then click the other end), or two topics, to add a relationship.")
        }
    }

    private func createRelationship(from fromID: CanvasNode.ID, to toID: CanvasNode.ID) {
        guard fromID != toID else {
            return
        }
        recordUndoSnapshot()
        let relationship = CanvasRelationship(fromNodeID: fromID, toNodeID: toID)
        relationships.append(relationship)
        relationshipSourceID = nil
        selectedRelationshipID = relationship.id
        saveNodes()
        focusCanvas()
    }

    private func deleteRelationship(_ id: CanvasRelationship.ID) {
        guard relationships.contains(where: { $0.id == id }) else {
            return
        }
        recordUndoSnapshot()
        relationships.removeAll { $0.id == id }
        if selectedRelationshipID == id {
            selectedRelationshipID = nil
        }
        saveNodes()
        focusCanvas()
    }

    private func pruneDanglingRelationships() {
        let ids = Set(nodes.map(\.id))
        if relationships.contains(where: { !ids.contains($0.fromNodeID) || !ids.contains($0.toNodeID) }) {
            relationships.removeAll { !ids.contains($0.fromNodeID) || !ids.contains($0.toNodeID) }
        }
    }

    private func relationshipItems(inScreenSpace: Bool) -> [RelationshipRenderItem] {
        let visibleIDs = derivedData.visibleNodeIDs
        let nodesByID = derivedData.visibleNodesByID
        let defaultColor = appearance.themeColors(for: colorScheme).connection
        return relationships.compactMap { relationship in
            guard visibleIDs.contains(relationship.fromNodeID), visibleIDs.contains(relationship.toNodeID),
                  let from = nodesByID[relationship.fromNodeID], let to = nodesByID[relationship.toNodeID] else {
                return nil
            }
            return RelationshipRenderItem(
                id: relationship.id,
                fromRect: inScreenSpace ? screenRect(for: from) : canvasRect(for: from),
                toRect: inScreenSpace ? screenRect(for: to) : canvasRect(for: to),
                lineStyle: relationship.lineStyle,
                startStyle: relationship.startStyle,
                endStyle: relationship.endStyle,
                isDashed: relationship.isDashed,
                color: TopicColor.color(relationship.colorHex) ?? defaultColor,
                label: relationship.label,
                isSelected: relationship.id == selectedRelationshipID
            )
        }
    }

    private func canvasRect(for node: CanvasNode) -> CGRect {
        CGRect(x: node.x, y: node.y, width: node.width, height: node.height)
    }

    private func screenRect(for node: CanvasNode) -> CGRect {
        let origin = canvasToScreenPosition(CGPoint(x: node.x, y: node.y))
        return CGRect(x: origin.x, y: origin.y, width: node.width * zoomScale, height: node.height * zoomScale)
    }

    /// The relationship line under a canvas point, if any.
    private func relationship(at canvasPoint: CGPoint) -> CanvasRelationship.ID? {
        let tolerance = 6 / max(zoomScale, 0.1)
        return relationshipItems(inScreenSpace: false)
            .map { ($0.id, RelationshipGeometry.distance(from: canvasPoint, to: $0)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func relationshipLayer(in size: CGSize) -> some View {
        RelationshipLayerView(
            items: relationshipItems(inScreenSpace: true),
            lineWidth: appearance.connectionLineThickness.width,
            labelBackground: appearance.backgroundColor(for: colorScheme),
            scale: zoomScale
        )
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func boundaryLayer(in size: CGSize) -> some View {
        let defaultColor = appearance.themeColors(for: colorScheme).connection
        let items = derivedData.boundaries.map { boundary in
            let origin = canvasToScreenPosition(boundary.rect.origin)
            return BoundaryRenderItem(
                rect: CGRect(x: origin.x, y: origin.y,
                             width: boundary.rect.width * zoomScale, height: boundary.rect.height * zoomScale),
                color: TopicColor.color(boundary.colorHex) ?? defaultColor
            )
        }
        return BoundaryLayerView(items: items, scale: zoomScale)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
    }

    // MARK: Topic style

    private func applyTopicStyleAction(_ action: TopicStyleAction, to nodeID: CanvasNode.ID) {
        let targetIDs = selectedNodeIDs.contains(nodeID) ? selectedNodeIDs : [nodeID]
        switch action {
        case .startRelationship:
            selectSingleNode(nodeID)
            relationshipSourceID = nodeID
            return
        case let .editRelationship(id):
            selectedRelationshipID = id
            editingRelationshipID = id
            return
        case let .deleteRelationship(id):
            deleteRelationship(id)
            return
        case .chooseImage:
            chooseImage(for: nodeID)
            return
        default:
            break
        }

        recordUndoSnapshot()
        for index in nodes.indices where targetIDs.contains(nodes[index].id) {
            switch action {
            case let .setColor(hex):
                nodes[index].style.colorHex = hex
            case let .setShape(shape):
                nodes[index].style.shape = shape
            case let .setTextSize(size):
                nodes[index].style.textSize = size
                resizeToFitContent(at: index)
            case .toggleBoundary:
                nodes[index].style.hasBoundary.toggle()
            case .removeImage:
                nodes[index].style.imageData = nil
                nodes[index].style.imageName = nil
                nodes[index].style.imageWidth = nil
                resizeToFitContent(at: index)
            default:
                break
            }
        }
        saveNodes()
        focusCanvas()
    }

    private func chooseImage(for nodeID: CanvasNode.ID) {
        let panel = NSOpenPanel()
        panel.title = "Choose Topic Image"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let index = nodes.firstIndex(where: { $0.id == nodeID }) else {
            focusCanvas()
            return
        }
        do {
            let prepared = try TopicImageImport.prepare(contentsOf: url)
            recordUndoSnapshot()
            nodes[index].style.imageData = prepared.data
            nodes[index].style.imageName = prepared.name
            nodes[index].style.imageWidth = nil
            resizeToFitContent(at: index)
            saveNodes()
        } catch {
            showStatusMessage("Could not use this image: \(error.localizedDescription)")
        }
        focusCanvas()
    }

    /// Grows/shrinks a topic around its centre to fit its text size and image.
    private func resizeToFitContent(at index: Int) {
        let node = nodes[index]
        let center = CGPoint(x: node.x + node.width / 2, y: node.y + node.height / 2)
        var size = IThoughtsImportService.topicSize(
            title: TopicText.plain(node.title),
            textWidth: nil,
            textSize: node.style.textSize,
            image: node.style.imageData,
            imageWidth: node.style.imageWidth
        )
        size.width = max(size.width, defaultNodeSize.width)
        size.height = max(size.height, defaultNodeSize.height)
        nodes[index].width = size.width
        nodes[index].height = size.height
        nodes[index].x = center.x - size.width / 2
        nodes[index].y = center.y - size.height / 2
    }

    private func validateCurrentMap() {
        isShowingAppearancePopover = false

        let report = MapValidator.validate(nodes: nodes, connections: connections, summaries: summaries)
        print("MyThoughts validation:\n\(report.summary)")
        showStatusMessage(report.summary)
        focusCanvas()
    }

    private func repairCurrentMap() {
        isShowingAppearancePopover = false

        let result = MapValidator.repair(nodes: nodes, connections: connections, summaries: summaries)
        if !result.actions.isEmpty {
            recordUndoSnapshot()
        }
        nodes = result.nodes
        connections = result.connections
        summaries = result.summaries

        if result.validationReport.isValid {
            saveNodes()
            print("MyThoughts repair:\n\(result.summary)")
            showStatusMessage(result.summary)
        } else {
            saveNodes()
            let message = "\(result.summary)\n\nRemaining issues:\n\(result.validationReport.summary)"
            print("MyThoughts repair left validation issues:\n\(message)")
            showStatusMessage(message)
        }

        focusCanvas()
    }

    private func applyPendingImport() {
        guard let document = pendingImportDocument else {
            return
        }

        pendingImportDocument = nil
        let repairResult = MapValidator.repair(nodes: document.nodes, connections: document.connections, summaries: document.summaries)
        recordUndoSnapshot()
        nodes = repairResult.nodes
        connections = repairResult.connections
        summaries = repairResult.summaries
        relationships = document.relationships
        appearance = document.canvasSettings
        documentCreatedAt = document.createdAt

        var importedNotePanelSettings = document.notePanelSettings
        importedNotePanelSettings.position = .right
        notePanelSettings = importedNotePanelSettings

        clearSelection()
        editingNodeID = nil
        detailsNodeID = nil
        isFocusMode = false
        focusedNodeID = nil
        newNodeIDs.removeAll()
        draggedNodeID = nil
        dropTargetNodeID = nil
        isDraggingNode = false

        saveNodes()
        appearance.save()
        saveNotePanelSettings()

        hasCenteredInitialContent = false
        centerInitialContentIfNeeded(in: viewportSize)

        if repairResult.actions.isEmpty && repairResult.validationReport.isValid {
            showStatusMessage("Imported MyThoughts file.")
        } else if repairResult.validationReport.isValid {
            print("MyThoughts import repair:\n\(repairResult.summary)")
            showStatusMessage("Imported and repaired MyThoughts file.\n\n\(repairResult.summary)")
        } else {
            let message = "Imported MyThoughts file with remaining validation issues.\n\n\(repairResult.validationReport.summary)"
            print("MyThoughts import validation:\n\(message)")
            showStatusMessage(message)
        }

        focusCanvas()
    }

    private func applyPendingIThoughtsImport() {
        guard let importResult = pendingIThoughtsImportResult else {
            return
        }

        pendingIThoughtsImportResult = nil
        let repairResult = MapValidator.repair(
            nodes: importResult.nodes,
            connections: importResult.connections,
            summaries: importResult.summaries
        )

        recordUndoSnapshot()
        nodes = repairResult.nodes
        connections = repairResult.connections
        summaries = repairResult.summaries
        relationships = importResult.relationships
        documentCreatedAt = Date()

        clearSelection()
        editingNodeID = nil
        detailsNodeID = nil
        isFocusMode = false
        focusedNodeID = nil
        newNodeIDs.removeAll()
        draggedNodeID = nil
        dropTargetNodeID = nil
        isDraggingNode = false

        refreshDerivedData()

        let importedRootID = importResult.rootNodeIDs.first { rootID in
            nodes.contains { $0.id == rootID }
        } ?? nodes.first?.id

        if let importedRootID {
            selectedNodeID = importedRootID
            selectedNodeIDs = [importedRootID]
            centerCanvas(on: importedRootID)
        } else {
            clearSelection()
        }

        saveNodes()
        hasCenteredInitialContent = true

        let importNotes = importResult.report.notImportedDescription.map { "\n\n\($0)" } ?? ""
        if repairResult.actions.isEmpty && repairResult.validationReport.isValid {
            showStatusMessage("Imported iThoughts map (\(importResult.report.importedDescription)).\(importNotes)")
        } else if repairResult.validationReport.isValid {
            print("iThoughts import repair:\n\(repairResult.summary)")
            showStatusMessage("Imported and repaired iThoughts map.\n\n\(repairResult.summary)\(importNotes)")
        } else {
            let message = "Imported iThoughts map with remaining validation issues.\n\n\(repairResult.validationReport.summary)"
            print("iThoughts import validation:\n\(message)")
            showStatusMessage(message)
        }

        focusCanvas()
    }

    private func createAppleReminderForDetailsNode() {
        createAppleReminderForDetailsNode(allowDuplicate: false)
    }

    private func createAppleReminderAgainForDetailsNode() {
        createAppleReminderForDetailsNode(allowDuplicate: true)
    }

    private func createAppleReminderForDetailsNode(allowDuplicate: Bool) {
        guard let detailsNodeID,
              let nodeIndex = nodes.firstIndex(where: { $0.id == detailsNodeID }) else {
            showStatusMessage("Select a node first.")
            return
        }

        let nodeID = detailsNodeID
        let node = nodes[nodeIndex]
        if node.appleReminderID != nil && !allowDuplicate {
            showStatusMessage("Already created in Apple Reminders.")
            return
        }

        AppleIntegrationService.createReminder(from: node) { result in
            switch result {
            case .success(let reminderID):
                guard let currentIndex = nodes.firstIndex(where: { $0.id == nodeID }) else {
                    return
                }

                detailsHistoryNodeID = nodeID
                nodes[currentIndex].appleReminderID = reminderID
                var syncState = nodes[currentIndex].appleSync ?? AppleSyncState()
                syncState.reminder = AppleIntegrationService.reminderValues(of: nodes[currentIndex])
                nodes[currentIndex].appleSync = syncState
                saveNodes()
                historyManager.removeAll()
                showStatusMessage("Created Apple Reminder.")
            case .failure(let error):
                print("MyThoughts Apple Reminders: failed to create reminder: \(error).")
                showStatusMessage(appleReminderErrorMessage(for: error))
            }
        }
    }

    private func requestAppleCalendarEventCreationForDetailsNode() {
        requestAppleCalendarEventCreationForDetailsNode(allowDuplicate: false)
    }

    private func requestAppleCalendarEventCreationAgainForDetailsNode() {
        requestAppleCalendarEventCreationForDetailsNode(allowDuplicate: true)
    }

    private func requestAppleCalendarEventCreationForDetailsNode(allowDuplicate: Bool) {
        guard let detailsNodeID,
              let nodeIndex = nodes.firstIndex(where: { $0.id == detailsNodeID }) else {
            showStatusMessage("Select a node first.")
            return
        }

        let node = nodes[nodeIndex]
        if node.appleCalendarEventID != nil && !allowDuplicate {
            showStatusMessage("Already created in Apple Calendar.")
            return
        }

        pendingCalendarCreationNodeID = detailsNodeID
        pendingCalendarCreationAllowsDuplicate = allowDuplicate
        isShowingCalendarCreationConfirmation = true
    }

    private func createAppleCalendarEvent(for nodeID: CanvasNode.ID, allowDuplicate: Bool = false) {
        guard let nodeIndex = nodes.firstIndex(where: { $0.id == nodeID }) else {
            showStatusMessage("Select a node first.")
            return
        }

        let node = nodes[nodeIndex]
        if node.appleCalendarEventID != nil && !allowDuplicate {
            showStatusMessage("Already created in Apple Calendar.")
            return
        }

        AppleIntegrationService.createCalendarEvent(from: node) { result in
            switch result {
            case .success(let eventID):
                guard let currentIndex = nodes.firstIndex(where: { $0.id == nodeID }) else {
                    return
                }

                detailsHistoryNodeID = nodeID
                nodes[currentIndex].appleCalendarEventID = eventID
                nodes[currentIndex].appleSync?.event = nil
                saveNodes()
                historyManager.removeAll()
                showStatusMessage("Created Apple Calendar Event.")
            case .failure(let error):
                print("MyThoughts Apple Calendar: failed to create event: \(error).")
                showStatusMessage(appleCalendarErrorMessage(for: error))
            }
        }
    }

    private func openAppleReminderForDetailsNode() {
        showStatusMessage("Opening existing reminders is not supported yet.")
    }

    private func openAppleCalendarEventForDetailsNode() {
        showStatusMessage("Opening existing calendar events is not supported yet.")
    }

    private func clearAppleReminderLinkForDetailsNode() {
        guard let detailsNodeID,
              let nodeIndex = nodes.firstIndex(where: { $0.id == detailsNodeID }) else {
            showStatusMessage("Select a node first.")
            return
        }

        guard nodes[nodeIndex].appleReminderID != nil else {
            return
        }

        recordUndoSnapshot()
        nodes[nodeIndex].appleReminderID = nil
        saveNodes()
        showStatusMessage("Cleared the Apple Reminder link in MyThoughts. This does not delete the Apple Reminder.")
    }

    private func clearAppleCalendarEventLinkForDetailsNode() {
        guard let detailsNodeID,
              let nodeIndex = nodes.firstIndex(where: { $0.id == detailsNodeID }) else {
            showStatusMessage("Select a node first.")
            return
        }

        guard nodes[nodeIndex].appleCalendarEventID != nil else {
            return
        }

        recordUndoSnapshot()
        nodes[nodeIndex].appleCalendarEventID = nil
        saveNodes()
        showStatusMessage("Cleared the Apple Calendar event link in MyThoughts. This does not delete the Apple Calendar event.")
    }

    private func appleReminderErrorMessage(for error: Error) -> String {
        if case AppleIntegrationError.permissionDenied = error {
            return "Permission is required to create Apple Reminders."
        }

        return "Could not create Apple Reminder: \(error.localizedDescription)"
    }

    private func appleCalendarErrorMessage(for error: Error) -> String {
        if case AppleIntegrationError.permissionDenied = error {
            return "Permission is required to create Apple Calendar events."
        }

        return "Could not create Apple Calendar Event: \(error.localizedDescription)"
    }

    private func showStatusMessage(_ message: String) {
        statusMessage = message
        isShowingStatusMessage = true
    }

    private func openSearchPanel() {
        isShowingSearchPanel = true
        isShowingAppearancePopover = false
        searchResults = searchNodes(query: searchQuery)

        DispatchQueue.main.async {
            isSearchFieldFocused = true
        }
    }

    private func closeSearchPanel() {
        isShowingSearchPanel = false
        isSearchFieldFocused = false
        focusCanvas()
    }

    private func searchNodes(query: String) -> [NodeSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        return nodes.compactMap { node in
            searchResult(for: node, query: trimmedQuery)
        }
    }

    private func searchResult(for node: CanvasNode, query: String) -> NodeSearchResult? {
        if node.title.localizedCaseInsensitiveContains(query) {
            return NodeSearchResult(
                nodeID: node.id,
                title: displayTitle(for: node),
                matchSource: "Title",
                snippet: node.title
            )
        }

        if node.body.localizedCaseInsensitiveContains(query) {
            return NodeSearchResult(
                nodeID: node.id,
                title: displayTitle(for: node),
                matchSource: "Note",
                snippet: snippet(from: node.body, query: query)
            )
        }

        if let matchingLink = node.links.first(where: {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.urlString.localizedCaseInsensitiveContains(query)
        }) {
            return NodeSearchResult(
                nodeID: node.id,
                title: displayTitle(for: node),
                matchSource: "Link",
                snippet: snippet(from: "\(matchingLink.title) \(matchingLink.urlString)", query: query)
            )
        }

        return nil
    }

    private func displayTitle(for node: CanvasNode) -> String {
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }

    private func snippet(from text: String, query: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return ""
        }

        let maximumLength = 90
        guard trimmedText.count > maximumLength else {
            return trimmedText
        }

        guard let range = trimmedText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(trimmedText.prefix(maximumLength)) + "..."
        }

        let queryOffset = trimmedText.distance(from: trimmedText.startIndex, to: range.lowerBound)
        let startOffset = max(queryOffset - 30, 0)
        let startIndex = trimmedText.index(trimmedText.startIndex, offsetBy: startOffset)
        let endIndex = trimmedText.index(startIndex, offsetBy: min(maximumLength, trimmedText.distance(from: startIndex, to: trimmedText.endIndex)))
        let prefix = startOffset > 0 ? "..." : ""
        let suffix = endIndex < trimmedText.endIndex ? "..." : ""
        return prefix + String(trimmedText[startIndex..<endIndex]) + suffix
    }

    private func jumpToSearchResult(_ result: NodeSearchResult) {
        guard nodes.contains(where: { $0.id == result.nodeID }) else {
            return
        }

        if isFocusMode,
           !isNodeVisibleInFocusMode(result.nodeID) {
            exitFocusMode()
        }
        expandAncestors(of: result.nodeID)
        refreshDerivedData()
        selectNode(result.nodeID)
        centerCanvas(on: result.nodeID)
        closeSearchPanel()
    }

    private func expandAncestors(of nodeID: CanvasNode.ID) {
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var currentParentID = nodesByID[nodeID]?.parentID
        var visitedIDs = Set<CanvasNode.ID>()
        var changedCollapseState = false

        while let parentID = currentParentID,
              !visitedIDs.contains(parentID),
              let parentNode = nodesByID[parentID] {
            visitedIDs.insert(parentID)

            if let parentIndex = nodes.firstIndex(where: { $0.id == parentID }),
               nodes[parentIndex].isCollapsed {
                if !changedCollapseState {
                    recordUndoSnapshot()
                }

                nodes[parentIndex].isCollapsed = false
                changedCollapseState = true
            }

            currentParentID = parentNode.parentID
        }

        if changedCollapseState {
            saveNodes()
        }
    }

    private func centerCanvas(on nodeID: CanvasNode.ID) {
        guard let node = nodes.first(where: { $0.id == nodeID }),
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return
        }

        let center = nodeCenter(node)
        panOffset = CGSize(
            width: viewportSize.width / 2 - center.x * zoomScale,
            height: viewportSize.height / 2 - center.y * zoomScale
        )
        dragStartPanOffset = panOffset
    }

    private func centerSelectedNode() {
        guard let selectedNodeID else {
            showStatusMessage("Select a node first.")
            return
        }

        centerCanvas(on: selectedNodeID)
        focusCanvas()
    }

    private func enterFocusModeOnSelectedNode() {
        guard let selectedNodeID,
              nodes.contains(where: { $0.id == selectedNodeID }) else {
            showStatusMessage("Select a node first.")
            return
        }

        focusedNodeID = selectedNodeID
        isFocusMode = true
        refreshDerivedData()
        centerCanvas(on: selectedNodeID)
        focusCanvas()
    }

    private func exitFocusMode() {
        isFocusMode = false
        focusedNodeID = nil
        refreshDerivedData()
        focusCanvas()
    }

    private func toggleFocusModeOnSelectedNode() {
        if isFocusMode {
            exitFocusMode()
        } else {
            enterFocusModeOnSelectedNode()
        }
    }

    private func isNodeVisibleInFocusMode(_ nodeID: CanvasNode.ID) -> Bool {
        guard isFocusMode,
              let focusedNodeID else {
            return true
        }

        return nodeID == focusedNodeID || descendantIDs(of: focusedNodeID).contains(nodeID)
    }

    private func copySelectedNodes() {
        let copiedIDs = collectSubtreeIDs(from: selectedVisibleNodeIDs())
        guard !copiedIDs.isEmpty else {
            showStatusMessage("Select a node first.")
            return
        }

        copiedFragment = makeCopiedFragment(from: copiedIDs)
    }

    private func duplicateSelectedNodes() {
        let copiedIDs = collectSubtreeIDs(from: selectedVisibleNodeIDs())
        guard !copiedIDs.isEmpty else {
            showStatusMessage("Select a node first.")
            return
        }

        let fragment = makeCopiedFragment(from: copiedIDs)
        pasteFragment(fragment, at: duplicatePastePoint(for: fragment), asChildOf: nil)
    }

    private func pasteCopiedNodes() {
        guard let copiedFragment else {
            showStatusMessage("Nothing to paste.")
            return
        }

        pasteFragment(copiedFragment, at: defaultPastePoint(for: copiedFragment), asChildOf: nil)
    }

    private func pasteCopiedNodesAsChild() {
        guard let parentID = selectedNodeID,
              nodes.contains(where: { $0.id == parentID }) else {
            showStatusMessage("Select a parent node first.")
            return
        }

        guard let copiedFragment else {
            showStatusMessage("Nothing to paste.")
            return
        }

        pasteFragment(copiedFragment, at: nil, asChildOf: parentID)
    }

    private func collectSubtreeIDs(from selectedIDs: Set<CanvasNode.ID>) -> Set<CanvasNode.ID> {
        let visibleSelectedIDs = selectedIDs.intersection(visibleNodeIDs)
        let selectedRootIDs = visibleSelectedIDs.filter { nodeID in
            !ancestorIDs(of: nodeID).contains { visibleSelectedIDs.contains($0) }
        }

        return selectedRootIDs.reduce(into: Set<CanvasNode.ID>()) { result, nodeID in
            result.insert(nodeID)
            result.formUnion(descendantIDs(of: nodeID))
        }
    }

    private func ancestorIDs(of nodeID: CanvasNode.ID) -> [CanvasNode.ID] {
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ancestors: [CanvasNode.ID] = []
        var visitedIDs = Set<CanvasNode.ID>()
        var currentParentID = nodesByID[nodeID]?.parentID

        while let parentID = currentParentID,
              !visitedIDs.contains(parentID) {
            ancestors.append(parentID)
            visitedIDs.insert(parentID)
            currentParentID = nodesByID[parentID]?.parentID
        }

        return ancestors
    }

    private func makeCopiedFragment(from nodeIDs: Set<CanvasNode.ID>) -> CopiedMapFragment {
        let copiedNodes = nodes.filter { nodeIDs.contains($0.id) }
        let copiedConnections = connections.filter { connection in
            nodeIDs.contains(connection.fromNodeID) && nodeIDs.contains(connection.toNodeID)
        }
        let copiedSummaries = summaries.filter { summary in
            nodeIDs.contains(summary.summaryNodeID) &&
            summary.summarizedNodeIDs.allSatisfy { nodeIDs.contains($0) }
        }
        let rootNodeIDs = copiedNodes
            .filter { node in
                guard let parentID = node.parentID else {
                    return true
                }

                return !nodeIDs.contains(parentID)
            }
            .sorted { left, right in
                if left.sortIndex == right.sortIndex {
                    return left.y < right.y
                }

                return left.sortIndex < right.sortIndex
            }
            .map(\.id)

        return CopiedMapFragment(
            nodes: copiedNodes,
            connections: copiedConnections,
            summaries: copiedSummaries,
            rootNodeIDs: rootNodeIDs
        )
    }

    private func makeFragment(from document: MyThoughtsDocument) -> CopiedMapFragment {
        let nodeIDs = Set(document.nodes.map(\.id))
        let rootNodeIDs = document.nodes
            .filter { node in
                guard let parentID = node.parentID else {
                    return true
                }

                return !nodeIDs.contains(parentID)
            }
            .sorted { left, right in
                if left.sortIndex == right.sortIndex {
                    return left.y < right.y
                }

                return left.sortIndex < right.sortIndex
            }
            .map(\.id)

        return CopiedMapFragment(
            nodes: document.nodes,
            connections: document.connections.filter { connection in
                nodeIDs.contains(connection.fromNodeID) && nodeIDs.contains(connection.toNodeID)
            },
            summaries: document.summaries.filter { summary in
                nodeIDs.contains(summary.summaryNodeID) &&
                summary.summarizedNodeIDs.allSatisfy { nodeIDs.contains($0) }
            },
            rootNodeIDs: rootNodeIDs
        )
    }

    private func branchSummaries(
        from fragment: CopiedMapFragment,
        exportedNodeIDs: Set<CanvasNode.ID>
    ) -> [CanvasSummary] {
        fragment.summaries.filter { summary in
            exportedNodeIDs.contains(summary.summaryNodeID) &&
            summary.summarizedNodeIDs.allSatisfy { exportedNodeIDs.contains($0) }
        }
    }

    private func sanitizedBranchNodes(from fragment: CopiedMapFragment) -> [CanvasNode] {
        let rootIDs = Set(fragment.rootNodeIDs)

        return fragment.nodes.map { node in
            CanvasNode(
                id: node.id,
                title: node.title,
                body: node.body,
                progress: node.progress,
                cost: node.cost,
                effort: node.effort,
                startDate: node.startDate,
                dueDate: node.dueDate,
                priority: node.priority,
                completedAt: node.completedAt,
                rollupEnabled: node.rollupEnabled,
                appleReminderID: nil,
                appleCalendarEventID: nil,
                marker: node.marker,
                links: node.links,
                attachmentLinks: node.links.map(\.urlString),
                x: node.x,
                y: node.y,
                width: node.width,
                height: node.height,
                sortIndex: node.sortIndex,
                parentID: rootIDs.contains(node.id) ? nil : node.parentID,
                isCollapsed: node.isCollapsed,
                style: node.style
            )
        }
    }

    private func importBranchDocument(_ document: MyThoughtsDocument) {
        let repairResult = MapValidator.repair(nodes: document.nodes, connections: document.connections, summaries: document.summaries)
        if !repairResult.validationReport.isValid {
            print("MyThoughts branch import validation:\n\(repairResult.validationReport.summary)")
        }

        let fragment = makeFragment(
            from: MyThoughtsDocument(
                documentType: .branch,
                nodes: repairResult.nodes,
                connections: repairResult.connections,
                summaries: repairResult.summaries,
                canvasSettings: document.canvasSettings,
                notePanelSettings: document.notePanelSettings,
                metadata: document.metadata
            )
        )

        if let selectedNodeID,
           nodes.contains(where: { $0.id == selectedNodeID }) {
            pasteFragment(fragment, at: nil, asChildOf: selectedNodeID)
        } else {
            pasteFragment(fragment, at: visibleCanvasCenter, asChildOf: nil)
        }

        showStatusMessage("Imported branch.")
    }

    private func pasteFragment(
        _ fragment: CopiedMapFragment,
        at canvasPoint: CGPoint?,
        asChildOf parentID: CanvasNode.ID?
    ) {
        guard !fragment.nodes.isEmpty else {
            return
        }

        let idMap = Dictionary(uniqueKeysWithValues: fragment.nodes.map { ($0.id, UUID()) })
        let rootIDs = Set(fragment.rootNodeIDs)
        let translation = pasteTranslation(for: fragment, targetPoint: canvasPoint, asChildOf: parentID)
        let rootBaseSortIndex = nextSortIndex(forParentID: parentID)

        let remappedNodes = fragment.nodes.map { node -> CanvasNode in
            let newParentID: CanvasNode.ID?
            let newSortIndex: Double

            if rootIDs.contains(node.id) {
                newParentID = parentID
                if let rootOffset = fragment.rootNodeIDs.firstIndex(of: node.id) {
                    newSortIndex = rootBaseSortIndex + Double(rootOffset)
                } else {
                    newSortIndex = node.sortIndex
                }
            } else if let oldParentID = node.parentID {
                newParentID = idMap[oldParentID]
                newSortIndex = node.sortIndex
            } else {
                newParentID = nil
                newSortIndex = node.sortIndex
            }

            return CanvasNode(
                id: idMap[node.id] ?? UUID(),
                title: node.title,
                body: node.body,
                progress: node.progress,
                cost: node.cost,
                effort: node.effort,
                startDate: node.startDate,
                dueDate: node.dueDate,
                priority: node.priority,
                completedAt: node.completedAt,
                rollupEnabled: node.rollupEnabled,
                appleReminderID: nil,
                appleCalendarEventID: nil,
                marker: node.marker,
                links: node.links,
                attachmentLinks: node.links.map(\.urlString),
                x: node.x + translation.width,
                y: node.y + translation.height,
                width: node.width,
                height: node.height,
                sortIndex: newSortIndex,
                parentID: newParentID,
                isCollapsed: node.isCollapsed,
                style: node.style
            )
        }

        var remappedConnections = fragment.connections.compactMap { connection -> CanvasConnection? in
            guard let newFromID = idMap[connection.fromNodeID],
                  let newToID = idMap[connection.toNodeID] else {
                return nil
            }

            return CanvasConnection(
                id: UUID(),
                fromNodeID: newFromID,
                toNodeID: newToID,
                type: connection.type
            )
        }
        let remappedSummaries = fragment.summaries.compactMap { summary -> CanvasSummary? in
            guard let newSummaryNodeID = idMap[summary.summaryNodeID] else {
                return nil
            }

            let remappedSummarizedNodeIDs = summary.summarizedNodeIDs.compactMap { idMap[$0] }
            guard remappedSummarizedNodeIDs.count >= 2 else {
                return nil
            }

            return CanvasSummary(
                id: UUID(),
                parentID: summary.parentID.flatMap { idMap[$0] } ?? parentID,
                summarizedNodeIDs: remappedSummarizedNodeIDs,
                summaryNodeID: newSummaryNodeID,
                sortIndex: summary.sortIndex
            )
        }

        if let parentID {
            for rootID in fragment.rootNodeIDs {
                guard let remappedRootID = idMap[rootID] else {
                    continue
                }

                remappedConnections.append(
                    CanvasConnection(
                        id: UUID(),
                        fromNodeID: parentID,
                        toNodeID: remappedRootID,
                        type: "parentChild"
                    )
                )
            }
        }

        if isFocusMode && parentID == nil {
            exitFocusMode()
        }

        recordUndoSnapshot()
        nodes.append(contentsOf: remappedNodes)
        connections.append(contentsOf: remappedConnections)
        summaries.append(contentsOf: remappedSummaries)

        if let parentID {
            normalizeSiblingOrder(parentID: parentID)
            let rootPositionsBeforeLayout = Dictionary(
                uniqueKeysWithValues: fragment.rootNodeIDs.compactMap { oldRootID -> (CanvasNode.ID, CGPoint)? in
                    guard let newRootID = idMap[oldRootID],
                          let node = nodes.first(where: { $0.id == newRootID }) else {
                        return nil
                    }

                    return (newRootID, CGPoint(x: node.x, y: node.y))
                }
            )
            layoutDirectChildren(of: parentID)
            movePastedDescendantsAfterRootLayout(rootPositionsBeforeLayout)
        } else {
            normalizeSiblingOrder(parentID: nil)
        }

        let pastedRootIDs = fragment.rootNodeIDs.compactMap { idMap[$0] }
        selectedNodeIDs = Set(pastedRootIDs)
        selectedNodeID = pastedRootIDs.first
        editingNodeID = nil
        saveNodes()
        validateMapAfterPaste()
        focusCanvas()
    }

    private func validateMapAfterPaste() {
        let report = MapValidator.validate(nodes: nodes, connections: connections)
        if !report.isValid {
            print("MyThoughts paste validation:\n\(report.summary)")
        }
    }

    private func movePastedDescendantsAfterRootLayout(_ originalRootPositions: [CanvasNode.ID: CGPoint]) {
        for (rootID, originalPosition) in originalRootPositions {
            guard let rootNode = nodes.first(where: { $0.id == rootID }) else {
                continue
            }

            let delta = CGSize(width: rootNode.x - originalPosition.x, height: rootNode.y - originalPosition.y)
            guard delta != .zero else {
                continue
            }

            let descendantIDsToMove = descendantIDs(of: rootID)
            for nodeIndex in nodes.indices where descendantIDsToMove.contains(nodes[nodeIndex].id) {
                nodes[nodeIndex].x += delta.width
                nodes[nodeIndex].y += delta.height
            }
        }
    }

    private func pasteTranslation(
        for fragment: CopiedMapFragment,
        targetPoint: CGPoint?,
        asChildOf parentID: CanvasNode.ID?
    ) -> CGSize {
        guard let bounds = fragmentBounds(fragment) else {
            return CGSize(width: 32, height: 32)
        }

        if let parentID,
           let parent = nodes.first(where: { $0.id == parentID }) {
            let target = CGPoint(
                x: parent.x + childHorizontalOffset,
                y: parent.y + childVerticalSpacing
            )
            return CGSize(width: target.x - bounds.minX, height: target.y - bounds.minY)
        }

        let target = targetPoint ?? visibleCanvasCenter
        return CGSize(width: target.x - bounds.minX, height: target.y - bounds.minY)
    }

    private func defaultPastePoint(for fragment: CopiedMapFragment) -> CGPoint {
        if let selectedNode,
           visibleNodeIDs.contains(selectedNode.id) {
            return CGPoint(x: selectedNode.x + 36, y: selectedNode.y + 36)
        }

        return visibleCanvasCenter
    }

    private func duplicatePastePoint(for fragment: CopiedMapFragment) -> CGPoint {
        guard let bounds = fragmentBounds(fragment) else {
            return visibleCanvasCenter
        }

        return CGPoint(x: bounds.minX + 32, y: bounds.minY + 32)
    }

    private var visibleCanvasCenter: CGPoint {
        screenToCanvasPosition(CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2))
    }

    private func fragmentBounds(_ fragment: CopiedMapFragment) -> CGRect? {
        guard let firstNode = fragment.nodes.first else {
            return nil
        }

        return fragment.nodes.dropFirst().reduce(
            CGRect(x: firstNode.x, y: firstNode.y, width: firstNode.width, height: firstNode.height)
        ) { bounds, node in
            bounds.union(CGRect(x: node.x, y: node.y, width: node.width, height: node.height))
        }
    }

    private var myThoughtsDocumentContentType: UTType {
        UTType(filenameExtension: MyThoughtsDocumentService.fileExtension) ?? .json
    }

    private var iThoughtsDocumentContentType: UTType {
        UTType(filenameExtension: "itmz") ?? .data
    }

    private func centerAxes(in size: CGSize) {
        panOffset = CGSize(width: size.width / 2, height: size.height / 2)
        dragStartPanOffset = panOffset
    }

    private func centerInitialContentIfNeeded(in size: CGSize) {
        guard !hasCenteredInitialContent,
              size.width > 0,
              size.height > 0 else {
            return
        }

        hasCenteredInitialContent = true

        guard let bounds = nodeContentBounds else {
            centerAxes(in: size)
            return
        }

        let contentCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        panOffset = CGSize(
            width: size.width / 2 - contentCenter.x * zoomScale,
            height: size.height / 2 - contentCenter.y * zoomScale
        )
        dragStartPanOffset = panOffset
    }

    private var nodeContentBounds: CGRect? {
        guard let firstNode = nodes.first else {
            return nil
        }

        return nodes.dropFirst().reduce(
            CGRect(x: firstNode.x, y: firstNode.y, width: firstNode.width, height: firstNode.height)
        ) { bounds, node in
            bounds.union(CGRect(x: node.x, y: node.y, width: node.width, height: node.height))
        }
    }

    private func createChildForSelectedNode() {
        guard let parentNodeID = selectedNodeID,
              let parentNode = nodes.first(where: { $0.id == parentNodeID }) else {
            return
        }

        let childNode = CanvasNode(
            id: UUID(),
            title: "",
            x: parentNode.x + childHorizontalOffset,
            y: parentNode.y,
            width: defaultNodeSize.width,
            height: defaultNodeSize.height,
            sortIndex: nextSortIndex(forParentID: parentNode.id),
            parentID: parentNode.id
        )
        let connection = CanvasConnection(
            id: UUID(),
            fromNodeID: parentNode.id,
            toNodeID: childNode.id,
            type: "parentChild"
        )

        recordUndoSnapshot()
        nodes.append(childNode)
        connections.append(connection)
        if let parentIndex = nodes.firstIndex(where: { $0.id == parentNode.id }) {
            nodes[parentIndex].isCollapsed = false
        }
        layoutDirectChildren(of: parentNode.id)
        selectedNodeID = childNode.id
        selectedNodeIDs = [childNode.id]
        editingNodeID = childNode.id
        newNodeIDs.insert(childNode.id)
        saveNodes()
    }

    private func createSiblingForSelectedNode(insertBeforeSelected: Bool = false) {
        guard let sourceNodeID = selectedNodeID,
              let selectedIndex = nodes.firstIndex(where: { $0.id == sourceNodeID }) else {
            return
        }

        let selectedNode = nodes[selectedIndex]
        let siblingSortIndex = insertBeforeSelected ? selectedNode.sortIndex - 0.5 : selectedNode.sortIndex + 0.5
        let siblingNode = CanvasNode(
            id: UUID(),
            title: "",
            x: selectedNode.x,
            y: selectedNode.y + (insertBeforeSelected ? -childVerticalSpacing : childVerticalSpacing),
            width: defaultNodeSize.width,
            height: defaultNodeSize.height,
            sortIndex: siblingSortIndex,
            parentID: selectedNode.parentID
        )

        recordUndoSnapshot()
        if insertBeforeSelected {
            nodes.insert(siblingNode, at: selectedIndex)
        } else {
            nodes.append(siblingNode)
        }

        if let parentID = selectedNode.parentID {
            let connection = CanvasConnection(
                id: UUID(),
                fromNodeID: parentID,
                toNodeID: siblingNode.id,
                type: "parentChild"
            )

            connections.append(connection)
            normalizeSiblingOrder(parentID: parentID)
            layoutDirectChildren(of: parentID)
        } else {
            normalizeSiblingOrder(parentID: nil)
        }

        selectedNodeID = siblingNode.id
        selectedNodeIDs = [siblingNode.id]
        editingNodeID = siblingNode.id
        newNodeIDs.insert(siblingNode.id)
        saveNodes()
    }

    private func toggleCollapse(for nodeID: CanvasNode.ID) {
        guard let nodeIndex = nodes.firstIndex(where: { $0.id == nodeID }),
              hasChildren(nodeID) else {
            return
        }

        recordUndoSnapshot()
        nodes[nodeIndex].isCollapsed.toggle()
        saveNodes()
        focusCanvas()
    }

    private func deleteSelectedNode() {
        deleteSelectedNodes(confirmingSubtreeDelete: false)
    }

    private func deleteSelectedNodes(confirmingSubtreeDelete: Bool) {
        let targetIDs = selectedVisibleNodeIDs()
        guard !targetIDs.isEmpty else {
            return
        }

        let descendantIDsToDelete = targetIDs.reduce(into: Set<CanvasNode.ID>()) { result, nodeID in
            result.formUnion(descendantIDs(of: nodeID))
        }

        if !confirmingSubtreeDelete,
           !descendantIDsToDelete.isEmpty {
            isShowingDeleteConfirmation = true
            return
        }

        let parentIDs = targetIDs.compactMap { nodeID in
            nodes.first(where: { $0.id == nodeID })?.parentID
        }
        let deletedIDs = descendantIDsToDelete.union(targetIDs)
        recordUndoSnapshot()
        nodes.removeAll { deletedIDs.contains($0.id) }
        connections.removeAll { connection in
            deletedIDs.contains(connection.fromNodeID) || deletedIDs.contains(connection.toNodeID)
        }
        cleanupSummaries(afterDeleting: deletedIDs)

        let survivingParentIDs = Set(parentIDs).filter { parentID in
            nodes.contains(where: { $0.id == parentID })
        }
        for parentID in survivingParentIDs {
            layoutDirectChildren(of: parentID)
        }

        clearSelection()
        editingNodeID = nil
        newNodeIDs.subtract(deletedIDs)
        saveNodes()
        focusCanvas()
    }

    private func cleanupSummaries(afterDeleting deletedIDs: Set<CanvasNode.ID>) {
        let validNodeIDs = Set(nodes.map(\.id))
        summaries = summaries.compactMap { summary in
            guard !deletedIDs.contains(summary.summaryNodeID),
                  validNodeIDs.contains(summary.summaryNodeID) else {
                return nil
            }

            var updatedSummary = summary
            updatedSummary.summarizedNodeIDs = summary.summarizedNodeIDs.filter { nodeID in
                !deletedIDs.contains(nodeID) && validNodeIDs.contains(nodeID)
            }

            return updatedSummary.summarizedNodeIDs.count >= 2 ? updatedSummary : nil
        }
    }

    private func updateDropTarget(for draggedNodeID: CanvasNode.ID) {
        guard let draggedNode = nodes.first(where: { $0.id == draggedNodeID }) else {
            dropTargetNodeID = nil
            return
        }

        let draggedCenter = CGPoint(
            x: draggedNode.x + draggedNode.width / 2,
            y: draggedNode.y + draggedNode.height / 2
        )
        let visibleIDs = visibleNodeIDs

        dropTargetNodeID = nodes.last { targetNode in
            guard visibleIDs.contains(targetNode.id),
                  canMakeParent(childID: draggedNodeID, newParentID: targetNode.id) else {
                return false
            }

            return CGRect(
                x: targetNode.x,
                y: targetNode.y,
                width: targetNode.width,
                height: targetNode.height
            )
            .contains(draggedCenter)
        }?.id
    }

    private func finishDraggingNode(_ nodeID: CanvasNode.ID) {
        defer {
            draggedNodeID = nil
            dropTargetNodeID = nil
            isDraggingNode = false
            dragOriginalNodePositions.removeAll()
            focusCanvas()
        }

        guard let targetNodeID = dropTargetNodeID,
              canMakeParent(childID: nodeID, newParentID: targetNodeID) else {
            saveNodes()
            return
        }

        makeNode(nodeID, childOf: targetNodeID, recordsHistory: false)
    }

    private func prepareNodeDrag(for nodeID: CanvasNode.ID) {
        recordUndoSnapshot()

        if !selectedNodeIDs.contains(nodeID) {
            selectSingleNode(nodeID)
        }

        let draggableIDs = selectedVisibleNodeIDs()
        dragOriginalNodePositions = Dictionary(
            uniqueKeysWithValues: nodes.compactMap { node in
                guard draggableIDs.contains(node.id) else {
                    return nil
                }

                return (node.id, CGPoint(x: node.x, y: node.y))
            }
        )

        isDraggingNode = true
        draggedNodeID = nodeID
        dropTargetNodeID = nil
        selectedNodeID = nodeID
        editingNodeID = nil
    }

    private func moveSelectedNodes(by canvasDelta: CGSize) {
        guard !dragOriginalNodePositions.isEmpty else {
            return
        }

        for nodeIndex in nodes.indices {
            guard let originalPosition = dragOriginalNodePositions[nodes[nodeIndex].id] else {
                continue
            }

            nodes[nodeIndex].x = originalPosition.x + canvasDelta.width
            nodes[nodeIndex].y = originalPosition.y + canvasDelta.height
        }
    }

    private func makeNode(_ childID: CanvasNode.ID, childOf newParentID: CanvasNode.ID, recordsHistory: Bool = true) {
        guard let childIndex = nodes.firstIndex(where: { $0.id == childID }),
              nodes.contains(where: { $0.id == newParentID }) else {
            return
        }

        let oldParentID = nodes[childIndex].parentID

        guard oldParentID != newParentID else {
            layoutDirectChildren(of: newParentID)
            saveNodes()
            return
        }

        if recordsHistory {
            recordUndoSnapshot()
        }
        nodes[childIndex].parentID = newParentID
        nodes[childIndex].sortIndex = nextSortIndex(forParentID: newParentID)
        if let newParentIndex = nodes.firstIndex(where: { $0.id == newParentID }) {
            nodes[newParentIndex].isCollapsed = false
        }

        connections.removeAll { connection in
            connection.type == "parentChild" && connection.toNodeID == childID
        }

        ensureParentConnection(from: newParentID, to: childID)

        if let oldParentID {
            normalizeSiblingOrder(parentID: oldParentID)
            layoutDirectChildren(of: oldParentID)
        }

        normalizeSiblingOrder(parentID: newParentID)
        layoutDirectChildren(of: newParentID)
        selectedNodeID = childID
        selectedNodeIDs = [childID]
        editingNodeID = nil
        saveNodes()
    }

    private func openDetails(for nodeID: CanvasNode.ID) {
        guard nodes.contains(where: { $0.id == nodeID }) else {
            return
        }

        selectedNodeID = nodeID
        selectedNodeIDs = [nodeID]
        detailsHistoryNodeID = nil
        editingNodeID = nil
        detailsNodeID = nodeID
    }

    private func cancelEditing() {
        editingNodeID = nil
        focusCanvas()
    }

    private func applyVisibleDepth(_ depth: Int, to nodeID: CanvasNode.ID) {
        guard nodes.contains(where: { $0.id == nodeID }) else {
            return
        }

        if depth == 0 {
            if let selectedIndex = nodes.firstIndex(where: { $0.id == nodeID }),
               hasChildren(nodeID) {
                recordUndoSnapshot()
                nodes[selectedIndex].isCollapsed = true
            }
            saveNodes()
            focusCanvas()
            return
        }

        recordUndoSnapshot()
        applyVisibleDepth(depth, from: nodeID, currentDepth: 0)
        saveNodes()
        focusCanvas()
    }

    private func applyVisibleDepth(_ maximumDepth: Int, from nodeID: CanvasNode.ID, currentDepth: Int) {
        guard let nodeIndex = nodes.firstIndex(where: { $0.id == nodeID }) else {
            return
        }

        let children = childNodes(of: nodeID)

        if children.isEmpty {
            return
        }

        nodes[nodeIndex].isCollapsed = currentDepth >= maximumDepth

        for child in children {
            applyVisibleDepth(maximumDepth, from: child.id, currentDepth: currentDepth + 1)
        }
    }

    private func layoutDirectChildren(of parentID: CanvasNode.ID) {
        guard let parentNode = nodes.first(where: { $0.id == parentID }) else {
            return
        }

        let childIndexes = siblingIndexes(parentID: parentID)
        let totalHeight = CGFloat(max(childIndexes.count - 1, 0)) * childVerticalSpacing
        let parentCenterY = parentNode.y + parentNode.height / 2

        for (offset, childIndex) in childIndexes.enumerated() {
            let childCenterY = parentCenterY - totalHeight / 2 + CGFloat(offset) * childVerticalSpacing
            nodes[childIndex].x = parentNode.x + childHorizontalOffset
            nodes[childIndex].y = childCenterY - nodes[childIndex].height / 2
        }
    }

    private func siblingIndexes(parentID: CanvasNode.ID?) -> [Array<CanvasNode>.Index] {
        nodes.indices
            .filter { nodes[$0].parentID == parentID }
            .sorted { left, right in
                if nodes[left].sortIndex == nodes[right].sortIndex {
                    return nodes[left].y < nodes[right].y
                }

                return nodes[left].sortIndex < nodes[right].sortIndex
            }
    }

    private func siblings(of node: CanvasNode) -> [CanvasNode] {
        siblingIndexes(parentID: node.parentID).map { nodes[$0] }
    }

    private func previousSibling(of node: CanvasNode) -> CanvasNode? {
        let siblings = siblings(of: node)
        guard let index = siblings.firstIndex(where: { $0.id == node.id }),
              index > 0 else {
            return nil
        }

        return siblings[index - 1]
    }

    private func nextSibling(of node: CanvasNode) -> CanvasNode? {
        let siblings = siblings(of: node)
        guard let index = siblings.firstIndex(where: { $0.id == node.id }),
              index < siblings.count - 1 else {
            return nil
        }

        return siblings[index + 1]
    }

    private func nextSortIndex(forParentID parentID: CanvasNode.ID?) -> Double {
        let indexes = siblingIndexes(parentID: parentID)
        return (indexes.map { nodes[$0].sortIndex }.max() ?? -1) + 1
    }

    private func normalizeSiblingOrder(parentID: CanvasNode.ID?) {
        for (offset, index) in siblingIndexes(parentID: parentID).enumerated() {
            nodes[index].sortIndex = Double(offset)
        }
    }

    private func ensureParentConnection(from parentID: CanvasNode.ID, to childID: CanvasNode.ID) {
        connections.removeAll { connection in
            connection.type == "parentChild" && connection.toNodeID == childID
        }

        guard !connections.contains(where: {
            $0.type == "parentChild" &&
            $0.fromNodeID == parentID &&
            $0.toNodeID == childID
        }) else {
            return
        }

        connections.append(
            CanvasConnection(
                id: UUID(),
                fromNodeID: parentID,
                toNodeID: childID,
                type: "parentChild"
            )
        )
    }

    private func commitEditing(for nodeID: CanvasNode.ID) {
        guard let nodeIndex = nodes.firstIndex(where: { $0.id == nodeID }) else {
            editingNodeID = nil
            return
        }

        nodes[nodeIndex].title = nodes[nodeIndex].title.trimmingCharacters(in: .whitespacesAndNewlines)

        if nodes[nodeIndex].title.isEmpty && newNodeIDs.contains(nodeID) {
            nodes.remove(at: nodeIndex)
            connections.removeAll { $0.fromNodeID == nodeID || $0.toNodeID == nodeID }
            cleanupSummaries(afterDeleting: [nodeID])
            selectedNodeID = nil
        }

        newNodeIDs.remove(nodeID)
        editingNodeID = nil
        saveNodes()
        focusCanvas()
    }

    private func saveNodes(markDirty shouldMarkDirty: Bool = true) {
        pruneDanglingRelationships()
        refreshDerivedData()
        NodeStore.saveDocument(
            nodes: nodes,
            connections: connections,
            summaries: summaries,
            relationships: relationships,
            canvasSettings: appearance,
            notePanelSettings: notePanelSettings,
            createdAt: documentCreatedAt
        )
        if shouldMarkDirty {
            markDirty()
        }
    }

    private func markDirty() {
        if !isDirty {
            isDirty = true
        }
    }

    private var currentHistorySnapshot: MapHistorySnapshot {
        MapHistorySnapshot(nodes: nodes, connections: connections, summaries: summaries, relationships: relationships)
    }

    private func recordUndoSnapshot() {
        historyManager.record(currentHistorySnapshot)
    }

    private func recordNoteEditSnapshotIfNeeded() {
        guard let selectedNodeID, noteHistoryNodeID != selectedNodeID else {
            return
        }

        recordUndoSnapshot()
        noteHistoryNodeID = selectedNodeID
    }

    private func recordDetailsEditSnapshotIfNeeded() {
        guard let detailsNodeID, detailsHistoryNodeID != detailsNodeID else {
            return
        }

        recordUndoSnapshot()
        detailsHistoryNodeID = detailsNodeID
    }

    private func applyHistorySnapshot(_ snapshot: MapHistorySnapshot) {
        nodes = snapshot.nodes
        connections = snapshot.connections
        summaries = snapshot.summaries
        relationships = snapshot.relationships
        refreshDerivedData()

        if let selectedNodeID, !nodes.contains(where: { $0.id == selectedNodeID }) {
            self.selectedNodeID = nil
        }

        selectedNodeIDs = selectedNodeIDs.filter { nodeID in
            nodes.contains { $0.id == nodeID }
        }

        if let editingNodeID, !nodes.contains(where: { $0.id == editingNodeID }) {
            self.editingNodeID = nil
        }

        if let detailsNodeID, !nodes.contains(where: { $0.id == detailsNodeID }) {
            self.detailsNodeID = nil
        }

        if let focusedNodeID, !nodes.contains(where: { $0.id == focusedNodeID }) {
            isFocusMode = false
            self.focusedNodeID = nil
            refreshDerivedData()
        }

        if let selectedNodeID, isFocusMode, !visibleNodeIDs.contains(selectedNodeID) {
            self.selectedNodeID = focusedNodeID
            if let focusedNodeID {
                selectedNodeIDs = [focusedNodeID]
            } else {
                selectedNodeIDs.removeAll()
            }
        }

        draggedNodeID = nil
        dropTargetNodeID = nil
        isDraggingNode = false
        newNodeIDs = newNodeIDs.filter { nodeID in
            nodes.contains { $0.id == nodeID }
        }
        noteHistoryNodeID = nil
        detailsHistoryNodeID = nil
        saveNodes()
    }

    private func validateFocusModeState() {
        guard isFocusMode else {
            return
        }

        guard let focusedNodeID,
              nodes.contains(where: { $0.id == focusedNodeID }) else {
            isFocusMode = false
            self.focusedNodeID = nil
            refreshDerivedData()
            return
        }

        if let selectedNodeID,
           !visibleNodeIDs.contains(selectedNodeID) {
            self.selectedNodeID = focusedNodeID
        }

        pruneSelectionToVisibleNodes()
    }

    private func performUndo() {
        guard let snapshot = historyManager.undo(currentSnapshot: currentHistorySnapshot) else {
            showStatusMessage("Nothing to undo.")
            return
        }

        applyHistorySnapshot(snapshot)
        showStatusMessage("Undone.")
        focusCanvas()
    }

    private func performRedo() {
        guard let snapshot = historyManager.redo(currentSnapshot: currentHistorySnapshot) else {
            showStatusMessage("Nothing to redo.")
            return
        }

        applyHistorySnapshot(snapshot)
        showStatusMessage("Redone.")
        focusCanvas()
    }

    private func binding(for nodeID: CanvasNode.ID) -> Binding<CanvasNode> {
        guard let nodeIndex = nodes.firstIndex(where: { $0.id == nodeID }) else {
            fatalError("Missing node binding for \(nodeID)")
        }

        return $nodes[nodeIndex]
    }

    private var detailsNodeBinding: Binding<CanvasNode>? {
        guard let detailsNodeID,
              let nodeIndex = nodes.firstIndex(where: { $0.id == detailsNodeID }) else {
            return nil
        }

        return $nodes[nodeIndex]
    }

    private var selectedNodeBodyBinding: Binding<String>? {
        guard let selectedNodeID,
              let nodeIndex = nodes.firstIndex(where: { $0.id == selectedNodeID }) else {
            return nil
        }

        return $nodes[nodeIndex].body
    }

    private func childNodes(of parentID: CanvasNode.ID) -> [CanvasNode] {
        derivedData.childrenByParent[parentID] ?? []
    }

    private func directChildren(of nodeID: CanvasNode.ID) -> [CanvasNode] {
        childNodes(of: nodeID)
    }

    private func rollupProgress(for node: CanvasNode) -> Int {
        displayedProgress(for: node)
    }

    private func rollupCost(for node: CanvasNode) -> Double {
        displayedCost(for: node)
    }

    private func rollupEffort(for node: CanvasNode) -> Double {
        displayedEffort(for: node)
    }

    private func displayedProgress(for node: CanvasNode) -> Int {
        derivedData.displayedProgressByNodeID[node.id] ?? clampedProgress(node.progress)
    }

    private func displayedCost(for node: CanvasNode) -> Double {
        derivedData.displayedCostByNodeID[node.id] ?? node.cost
    }

    private func displayedEffort(for node: CanvasNode) -> Double {
        derivedData.displayedEffortByNodeID[node.id] ?? node.effort
    }

    private func clampedProgress(_ progress: Int) -> Int {
        min(max(progress, 0), 100)
    }

    private func descendantIDs(of nodeID: CanvasNode.ID) -> Set<CanvasNode.ID> {
        childNodes(of: nodeID).reduce(into: Set<CanvasNode.ID>()) { result, child in
            result.insert(child.id)
            result.formUnion(descendantIDs(of: child.id))
        }
    }

    private func isDescendant(_ possibleDescendantID: CanvasNode.ID, of nodeID: CanvasNode.ID) -> Bool {
        childNodes(of: nodeID).contains { child in
            child.id == possibleDescendantID || isDescendant(possibleDescendantID, of: child.id)
        }
    }

    private func canMakeParent(childID: CanvasNode.ID, newParentID: CanvasNode.ID) -> Bool {
        childID != newParentID && !isDescendant(newParentID, of: childID)
    }

    private func hasChildren(_ nodeID: CanvasNode.ID) -> Bool {
        derivedData.directChildCounts[nodeID, default: 0] > 0
    }

    private func selectSingleNode(_ nodeID: CanvasNode.ID) {
        guard visibleNodeIDs.contains(nodeID) else {
            return
        }

        if selectedNodeID != nodeID {
            noteHistoryNodeID = nil
        }
        selectedNodeID = nodeID
        selectedNodeIDs = [nodeID]
        editingNodeID = nil
        focusCanvas()
    }

    private func setMarker(_ marker: NodeMarker, for nodeID: CanvasNode.ID) {
        guard let nodeIndex = nodes.firstIndex(where: { $0.id == nodeID }),
              nodes[nodeIndex].marker != marker else {
            return
        }

        recordUndoSnapshot()
        nodes[nodeIndex].marker = marker
        saveNodes()
        focusCanvas()
    }

    private func toggleNodeSelection(_ nodeID: CanvasNode.ID) {
        guard visibleNodeIDs.contains(nodeID) else {
            return
        }

        if selectedNodeIDs.contains(nodeID) {
            selectedNodeIDs.remove(nodeID)
            if selectedNodeID == nodeID {
                selectedNodeID = selectedNodeIDs.first
                noteHistoryNodeID = nil
            }
        } else {
            selectedNodeIDs.insert(nodeID)
            selectedNodeID = nodeID
            noteHistoryNodeID = nil
        }

        editingNodeID = nil
        focusCanvas()
    }

    private func clearSelection() {
        selectedNodeID = nil
        selectedNodeIDs.removeAll()
        editingNodeID = nil
        noteHistoryNodeID = nil
        focusCanvas()
    }

    private func selectedVisibleNodeIDs() -> Set<CanvasNode.ID> {
        selectedNodeIDs.intersection(visibleNodeIDs)
    }

    private func pruneSelectionToVisibleNodes() {
        let visibleSelectedIDs = selectedVisibleNodeIDs()
        if visibleSelectedIDs != selectedNodeIDs {
            selectedNodeIDs = visibleSelectedIDs
        }

        if let selectedNodeID,
           !visibleNodeIDs.contains(selectedNodeID) {
            self.selectedNodeID = selectedNodeIDs.first
            noteHistoryNodeID = nil
        }
    }

    private func selectNode(_ nodeID: CanvasNode.ID?) {
        guard let nodeID else {
            clearSelection()
            return
        }

        selectSingleNode(nodeID)
    }

    private func selectParent() {
        guard let selectedNode = selectedNode,
              let parentID = selectedNode.parentID else {
            return
        }

        selectNode(parentID)
    }

    private func selectFirstChild() {
        guard let selectedNode else {
            return
        }

        let visibleIDs = visibleNodeIDs
        let firstChild = childNodes(of: selectedNode.id)
            .filter { visibleIDs.contains($0.id) }
            .sorted { $0.sortIndex < $1.sortIndex }
            .first
        selectNode(firstChild?.id)
    }

    private func selectNearestNode(direction: NavigationDirection) {
        guard let selectedNode else {
            selectNode(visibleNodes.first?.id)
            return
        }

        switch direction {
        case .up:
            if let previousSibling = previousSibling(of: selectedNode),
               visibleNodeIDs.contains(previousSibling.id) {
                selectNode(previousSibling.id)
                return
            }
        case .down:
            if let nextSibling = nextSibling(of: selectedNode),
               visibleNodeIDs.contains(nextSibling.id) {
                selectNode(nextSibling.id)
                return
            }
        case .left:
            if let parentID = selectedNode.parentID {
                selectNode(parentID)
                return
            }
        case .right:
            if selectedNode.isCollapsed, hasChildren(selectedNode.id),
               let selectedIndex = nodes.firstIndex(where: { $0.id == selectedNode.id }) {
                recordUndoSnapshot()
                nodes[selectedIndex].isCollapsed = false
                refreshDerivedData()
                saveNodes()
                selectFirstChild()
                return
            }

            let visibleChildren = childNodes(of: selectedNode.id).filter { visibleNodeIDs.contains($0.id) }
            if let firstChild = visibleChildren.sorted(by: { $0.sortIndex < $1.sortIndex }).first {
                selectNode(firstChild.id)
                return
            }
        }

        selectNode(nearestVisibleNode(to: selectedNode, direction: direction)?.id)
    }

    private func nearestVisibleNode(to sourceNode: CanvasNode, direction: NavigationDirection) -> CanvasNode? {
        let sourceCenter = nodeCenter(sourceNode)

        return visibleNodes
            .filter { node in
                guard node.id != sourceNode.id else {
                    return false
                }

                let center = nodeCenter(node)
                switch direction {
                case .up:
                    return center.y < sourceCenter.y
                case .down:
                    return center.y > sourceCenter.y
                case .left:
                    return center.x < sourceCenter.x
                case .right:
                    return center.x > sourceCenter.x
                }
            }
            .min { left, right in
                spatialScore(from: sourceCenter, to: nodeCenter(left), direction: direction) <
                spatialScore(from: sourceCenter, to: nodeCenter(right), direction: direction)
            }
    }

    private func nodeCenter(_ node: CanvasNode) -> CGPoint {
        CGPoint(x: node.x + node.width / 2, y: node.y + node.height / 2)
    }

    private func spatialScore(from source: CGPoint, to candidate: CGPoint, direction: NavigationDirection) -> CGFloat {
        let primaryDistance: CGFloat
        let secondaryDistance: CGFloat

        switch direction {
        case .up, .down:
            primaryDistance = abs(candidate.y - source.y)
            secondaryDistance = abs(candidate.x - source.x)
        case .left, .right:
            primaryDistance = abs(candidate.x - source.x)
            secondaryDistance = abs(candidate.y - source.y)
        }

        return primaryDistance * 10 + secondaryDistance
    }

    private func moveSelectedNodeUp() {
        moveSelectedNodeSiblingOffset(-1)
    }

    private func moveSelectedNodeDown() {
        moveSelectedNodeSiblingOffset(1)
    }

    private func moveSelectedNodeSiblingOffset(_ offset: Int) {
        guard let selectedNode,
              let selectedIndex = nodes.firstIndex(where: { $0.id == selectedNode.id }) else {
            return
        }

        let siblings = siblings(of: selectedNode)
        guard let siblingIndex = siblings.firstIndex(where: { $0.id == selectedNode.id }) else {
            return
        }

        let targetIndex = siblingIndex + offset
        guard siblings.indices.contains(targetIndex),
              let targetNodeIndex = nodes.firstIndex(where: { $0.id == siblings[targetIndex].id }) else {
            return
        }

        recordUndoSnapshot()
        let sortIndex = nodes[selectedIndex].sortIndex
        nodes[selectedIndex].sortIndex = nodes[targetNodeIndex].sortIndex
        nodes[targetNodeIndex].sortIndex = sortIndex
        normalizeSiblingOrder(parentID: selectedNode.parentID)

        if let parentID = selectedNode.parentID {
            layoutDirectChildren(of: parentID)
        }

        selectedNodeID = selectedNode.id
        selectedNodeIDs = [selectedNode.id]
        saveNodes()
        focusCanvas()
    }

    private func indentSelectedNode() {
        guard let selectedNode,
              let previousSibling = previousSibling(of: selectedNode),
              canMakeParent(childID: selectedNode.id, newParentID: previousSibling.id) else {
            return
        }

        makeNode(selectedNode.id, childOf: previousSibling.id)
    }

    private func outdentSelectedNode() {
        guard let selectedNode,
              let nodeIndex = nodes.firstIndex(where: { $0.id == selectedNode.id }),
              let oldParentID = selectedNode.parentID,
              let oldParent = nodes.first(where: { $0.id == oldParentID }) else {
            return
        }

        let newParentID = oldParent.parentID
        recordUndoSnapshot()
        nodes[nodeIndex].parentID = newParentID
        nodes[nodeIndex].sortIndex = oldParent.sortIndex + 0.5

        connections.removeAll { connection in
            connection.type == "parentChild" && connection.toNodeID == selectedNode.id
        }

        if let newParentID {
            ensureParentConnection(from: newParentID, to: selectedNode.id)
        }

        normalizeSiblingOrder(parentID: oldParentID)
        if let newParentID {
            normalizeSiblingOrder(parentID: newParentID)
            layoutDirectChildren(of: newParentID)
        } else {
            normalizeSiblingOrder(parentID: nil)
        }
        layoutDirectChildren(of: oldParentID)

        selectedNodeID = selectedNode.id
        selectedNodeIDs = [selectedNode.id]
        editingNodeID = nil
        saveNodes()
        focusCanvas()
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        if isSearchFieldFocused {
            if event.keyCode == KeyCode.escape {
                closeSearchPanel()
                return true
            }

            if event.keyCode == KeyCode.return,
               let firstResult = searchResults.first {
                jumpToSearchResult(firstResult)
                return true
            }

            return false
        }

        if isShowingSearchPanel,
           event.keyCode == KeyCode.escape {
            closeSearchPanel()
            return true
        }

        if isNoteEditorFocused {
            return false
        }

        if detailsNodeID != nil {
            return false
        }

        if editingNodeID != nil {
            if event.keyCode == KeyCode.escape {
                cancelEditing()
                return true
            }

            return false
        }

        if event.keyCode == KeyCode.escape, relationshipSourceID != nil {
            relationshipSourceID = nil
            return true
        }

        if let selectedRelationshipID {
            if event.keyCode == KeyCode.delete || event.keyCode == KeyCode.forwardDelete {
                deleteRelationship(selectedRelationshipID)
                return true
            }
            if event.keyCode == KeyCode.return {
                editingRelationshipID = selectedRelationshipID
                return true
            }
            if event.keyCode == KeyCode.escape {
                self.selectedRelationshipID = nil
                return true
            }
        }

        if event.keyCode == KeyCode.escape,
           isFocusMode {
            exitFocusMode()
            return true
        }

        if event.modifierFlags.contains(.command),
           event.modifierFlags.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            centerSelectedNode()
            return true
        }

        if event.modifierFlags.contains(.command),
           event.modifierFlags.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            toggleFocusModeOnSelectedNode()
            return true
        }

        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copySelectedNodes()
            return true
        }

        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteCopiedNodes()
            return true
        }

        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "d" {
            duplicateSelectedNodes()
            return true
        }

        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            openSearchPanel()
            return true
        }

        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                performRedo()
            } else {
                performUndo()
            }
            return true
        }

        if handleArrowKeyEvent(event) {
            return true
        }

        if event.keyCode == KeyCode.delete || event.keyCode == KeyCode.forwardDelete {
            deleteSelectedNode()
            return true
        }

        if event.keyCode == KeyCode.tab {
            createChildForSelectedNode()
            return true
        }

        if event.keyCode == KeyCode.return {
            createSiblingForSelectedNode(insertBeforeSelected: event.modifierFlags.contains(.shift))
            return true
        }

        if event.charactersIgnoringModifiers == ".",
           let selectedNodeID {
            toggleCollapse(for: selectedNodeID)
            return true
        }

        if let characters = event.charactersIgnoringModifiers,
           characters.count == 1,
           let depth = Int(characters),
           (0...9).contains(depth),
           let selectedNodeID {
            applyVisibleDepth(depth, to: selectedNodeID)
            return true
        }

        return false
    }

    private func handleArrowKeyEvent(_ event: NSEvent) -> Bool {
        let isCommand = event.modifierFlags.contains(.command)

        switch event.keyCode {
        case KeyCode.upArrow:
            isCommand ? moveSelectedNodeUp() : selectNearestNode(direction: .up)
            return true
        case KeyCode.downArrow:
            isCommand ? moveSelectedNodeDown() : selectNearestNode(direction: .down)
            return true
        case KeyCode.leftArrow:
            isCommand ? outdentSelectedNode() : selectNearestNode(direction: .left)
            return true
        case KeyCode.rightArrow:
            isCommand ? indentSelectedNode() : selectNearestNode(direction: .right)
            return true
        default:
            return false
        }
    }

    private func appearancePopover(in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(
                "Theme",
                selection: Binding(
                    get: { appearance.theme },
                    set: { newValue in
                        updateAppearance {
                            $0.theme = newValue
                        }
                    }
                )
            ) {
                ForEach(CanvasAppearance.ThemeOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            Divider()

            Picker(
                "Node Style",
                selection: Binding(
                    get: { appearance.nodeStyle },
                    set: { newValue in
                        updateAppearance {
                            $0.nodeStyle = newValue
                        }
                    }
                )
            ) {
                ForEach(CanvasAppearance.NodeStyleOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            Picker(
                "Node Font",
                selection: Binding(
                    get: { appearance.nodeFontSize },
                    set: { newValue in
                        updateAppearance {
                            $0.nodeFontSize = newValue
                        }
                    }
                )
            ) {
                ForEach(CanvasAppearance.NodeFontSize.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            Divider()

            Text("Task Display")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(
                "Completion Marker",
                isOn: Binding(
                    get: { appearance.taskDisplay.showCompletionMarker },
                    set: { newValue in
                        updateAppearance {
                            $0.taskDisplay.showCompletionMarker = newValue
                        }
                    }
                )
            )

            Toggle(
                "Progress",
                isOn: Binding(
                    get: { appearance.taskDisplay.showProgress },
                    set: { newValue in
                        updateAppearance {
                            $0.taskDisplay.showProgress = newValue
                        }
                    }
                )
            )

            Toggle(
                "Due Date",
                isOn: Binding(
                    get: { appearance.taskDisplay.showDueDate },
                    set: { newValue in
                        updateAppearance {
                            $0.taskDisplay.showDueDate = newValue
                        }
                    }
                )
            )

            Toggle(
                "Priority",
                isOn: Binding(
                    get: { appearance.taskDisplay.showPriority },
                    set: { newValue in
                        updateAppearance {
                            $0.taskDisplay.showPriority = newValue
                        }
                    }
                )
            )

            Toggle(
                "Resources",
                isOn: Binding(
                    get: { appearance.taskDisplay.showResources },
                    set: { newValue in
                        updateAppearance {
                            $0.taskDisplay.showResources = newValue
                        }
                    }
                )
            )

            Toggle(
                "Hide Completed Tasks",
                isOn: Binding(
                    get: { appearance.taskDisplay.hideCompletedTasks },
                    set: { newValue in
                        updateAppearance {
                            $0.taskDisplay.hideCompletedTasks = newValue
                        }
                        refreshDerivedData()
                    }
                )
            )

            Toggle(
                "Auto-sync Reminders & Calendar",
                isOn: Binding(
                    get: { appearance.taskDisplay.autoSyncWithApple },
                    set: { newValue in
                        updateAppearance {
                            $0.taskDisplay.autoSyncWithApple = newValue
                        }
                    }
                )
            )

            Divider()

            Picker(
                "Connection",
                selection: Binding(
                    get: { appearance.connectionLineStyle },
                    set: { newValue in
                        updateAppearance {
                            $0.connectionLineStyle = newValue
                        }
                    }
                )
            ) {
                ForEach(CanvasAppearance.ConnectionLineStyle.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            Picker(
                "Line Thickness",
                selection: Binding(
                    get: { appearance.connectionLineThickness },
                    set: { newValue in
                        updateAppearance {
                            $0.connectionLineThickness = newValue
                        }
                    }
                )
            ) {
                ForEach(CanvasAppearance.ConnectionLineThickness.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            Divider()

            Toggle(
                "Show Grid",
                isOn: Binding(
                    get: { appearance.showGrid },
                    set: { newValue in
                        updateAppearance {
                            $0.showGrid = newValue
                        }
                    }
                )
            )

            Picker(
                "Grid Size",
                selection: Binding(
                    get: { appearance.gridSize },
                    set: { newValue in
                        updateAppearance {
                            $0.gridSize = newValue
                        }
                    }
                )
            ) {
                ForEach(CanvasAppearance.GridSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
            .disabled(!appearance.showGrid)

            Divider()

            Toggle(
                "Show Quadrants",
                isOn: Binding(
                    get: { appearance.showQuadrants },
                    set: { newValue in
                        if newValue != appearance.showQuadrants {
                            toggleQuadrants(in: size)
                        }
                    }
                )
            )

            Button("Center Axes") {
                centerAxes(in: size)
                focusCanvas()
            }
            .disabled(!appearance.showQuadrants)

            Divider()

            Button("Center Selected Node") {
                centerSelectedNode()
            }
            .disabled(selectedNodeID == nil)

            if isFocusMode {
                Button("Exit Focus Mode") {
                    exitFocusMode()
                }
            } else {
                Button("Focus on Selected Branch") {
                    enterFocusModeOnSelectedNode()
                }
                .disabled(selectedNodeID == nil)
            }

            Divider()

            Button("Export MyThoughts File") {
                exportMyThoughtsFile()
            }

            Button("Export Selected Branch") {
                exportSelectedBranchFile()
            }
            .disabled(selectedVisibleNodeIDs().isEmpty)

            Button("Import MyThoughts File") {
                importMyThoughtsFile()
            }

            Button("Import iThoughts .itmz") {
                importIThoughtsFile()
            }

            Button("Export as iThoughts .itmz") {
                exportITMZFile()
            }

            Divider()

            Button("Copy") {
                copySelectedNodes()
            }
            .disabled(selectedVisibleNodeIDs().isEmpty)

            Button("Paste") {
                pasteCopiedNodes()
            }
            .disabled(copiedFragment == nil)

            Button("Paste as Child") {
                pasteCopiedNodesAsChild()
            }
            .disabled(copiedFragment == nil || selectedNodeID == nil)

            Button("Duplicate") {
                duplicateSelectedNodes()
            }
            .disabled(selectedVisibleNodeIDs().isEmpty)

            Divider()

            Button("Undo") {
                performUndo()
            }
            .disabled(!historyManager.canUndo)

            Button("Redo") {
                performRedo()
            }
            .disabled(!historyManager.canRedo)

            Divider()

            Button("Validate Map") {
                validateCurrentMap()
            }

            Button("Repair Map") {
                repairCurrentMap()
            }
        }
        .pickerStyle(.menu)
        .toggleStyle(.switch)
        .padding(16)
        .frame(width: 260)
    }

    private func canvasNodeView(for node: Binding<CanvasNode>) -> some View {
        let wrappedNode = node.wrappedValue
        let screenPosition = canvasToScreenPosition(
            CGPoint(
                x: wrappedNode.x + wrappedNode.width / 2,
                y: wrappedNode.y + wrappedNode.height / 2
            )
        )

        return NodeView(
            node: node,
            visualStyle: NodeVisualStyle(
                appearance: appearance,
                colors: appearance.themeColors(for: colorScheme)
            ),
            taskIndicators: NodeTaskIndicators(
                node: wrappedNode,
                displayedProgress: displayedProgress(for: wrappedNode),
                settings: appearance.taskDisplay,
                dateFormatter: Self.compactTaskDateFormatter
            ),
            isSelected: selectedNodeIDs.contains(wrappedNode.id),
            isPrimarySelected: selectedNodeID == wrappedNode.id,
            isEditing: editingNodeID == wrappedNode.id,
            isDropTarget: dropTargetNodeID == wrappedNode.id,
            zoomScale: zoomScale,
            hasChildren: hasChildren(wrappedNode.id),
            fillHex: derivedData.effectiveColorHexByNodeID[wrappedNode.id],
            isRelationshipSource: relationshipSourceID == wrappedNode.id,
            relationshipMenuItems: relationships
                .filter { $0.fromNodeID == wrappedNode.id || $0.toNodeID == wrappedNode.id }
                .map { relationship in
                    let otherID = relationship.fromNodeID == wrappedNode.id ? relationship.toNodeID : relationship.fromNodeID
                    let arrow = relationship.fromNodeID == wrappedNode.id ? "→" : "←"
                    let label = relationship.label.isEmpty ? "" : " (\(relationship.label))"
                    return RelationshipMenuItem(id: relationship.id, title: "\(arrow) \(relationshipEndTitle(otherID))\(label)")
                },
            knownResources: knownResources,
            onStyleAction: { action in
                applyTopicStyleAction(action, to: wrappedNode.id)
            },
            onTaskAction: { action in
                let targets = selectedNodeIDs.contains(wrappedNode.id) ? selectedNodeIDs : [wrappedNode.id]
                applyTaskAction(action, to: targets)
            },
            onSelect: {
                selectedRelationshipID = nil
                if let sourceID = relationshipSourceID {
                    if sourceID != wrappedNode.id {
                        createRelationship(from: sourceID, to: wrappedNode.id)
                    }
                    return
                }
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    toggleNodeSelection(wrappedNode.id)
                } else {
                    selectSingleNode(wrappedNode.id)
                }
            },
            onEdit: {
                recordUndoSnapshot()
                selectedNodeID = wrappedNode.id
                selectedNodeIDs = [wrappedNode.id]
                editingNodeID = wrappedNode.id
            },
            onCommit: {
                commitEditing(for: wrappedNode.id)
            },
            onCancel: {
                cancelEditing()
            },
            onDragStart: {
                prepareNodeDrag(for: wrappedNode.id)
            },
            onDragChanged: { canvasDelta in
                moveSelectedNodes(by: canvasDelta)
                updateDropTarget(for: wrappedNode.id)
            },
            onDragEnd: {
                finishDraggingNode(wrappedNode.id)
            },
            onAddChild: {
                selectSingleNode(wrappedNode.id)
                createChildForSelectedNode()
            },
            onAddSibling: {
                selectSingleNode(wrappedNode.id)
                createSiblingForSelectedNode()
            },
            onDelete: {
                if !selectedNodeIDs.contains(wrappedNode.id) {
                    selectSingleNode(wrappedNode.id)
                }
                deleteSelectedNode()
            },
            onPasteAsChild: {
                selectSingleNode(wrappedNode.id)
                pasteCopiedNodesAsChild()
            },
            onDuplicate: {
                if !selectedNodeIDs.contains(wrappedNode.id) {
                    selectSingleNode(wrappedNode.id)
                }
                duplicateSelectedNodes()
            },
            onEditDetails: {
                openDetails(for: wrappedNode.id)
            },
            onSetMarker: { marker in
                setMarker(marker, for: wrappedNode.id)
            },
            onBranchOperation: { operation in
                performBranchOperation(operation, rootID: wrappedNode.id)
            },
            onToggleCollapse: {
                selectSingleNode(wrappedNode.id)
                toggleCollapse(for: wrappedNode.id)
            }
        )
        .position(screenPosition)
    }

    private static let compactTaskDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private func quadrantLayer(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let origin = canvasToScreenPosition(.zero)
            let axisColor = appearance.themeColors(for: colorScheme).quadrantAxis
            let fillOpacity = 0.055

            let topRight = CGRect(
                x: origin.x,
                y: 0,
                width: max(canvasSize.width - origin.x, 0),
                height: max(origin.y, 0)
            )
            let bottomRight = CGRect(
                x: origin.x,
                y: origin.y,
                width: max(canvasSize.width - origin.x, 0),
                height: max(canvasSize.height - origin.y, 0)
            )
            let topLeft = CGRect(
                x: 0,
                y: 0,
                width: max(origin.x, 0),
                height: max(origin.y, 0)
            )
            let bottomLeft = CGRect(
                x: 0,
                y: origin.y,
                width: max(origin.x, 0),
                height: max(canvasSize.height - origin.y, 0)
            )

            context.fill(Path(topRight), with: .color(.red.opacity(fillOpacity)))
            context.fill(Path(bottomRight), with: .color(.orange.opacity(fillOpacity)))
            context.fill(Path(topLeft), with: .color(.blue.opacity(fillOpacity)))
            context.fill(Path(bottomLeft), with: .color(.gray.opacity(fillOpacity)))

            var axisPath = Path()

            if (0...canvasSize.width).contains(origin.x) {
                axisPath.move(to: CGPoint(x: origin.x, y: 0))
                axisPath.addLine(to: CGPoint(x: origin.x, y: canvasSize.height))
            }

            if (0...canvasSize.height).contains(origin.y) {
                axisPath.move(to: CGPoint(x: 0, y: origin.y))
                axisPath.addLine(to: CGPoint(x: canvasSize.width, y: origin.y))
            }

            context.stroke(axisPath, with: .color(axisColor), lineWidth: 1.25)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            quadrantLabels(in: size)
        }
        .allowsHitTesting(false)
    }

    private func quadrantLabels(in size: CGSize) -> some View {
        let origin = canvasToScreenPosition(.zero)

        return ZStack(alignment: .topLeading) {
            quadrantLabel("Urgent & Important")
                .position(labelPosition(in: size, origin: origin, horizontal: .right, vertical: .top))

            quadrantLabel("Urgent & Not Important")
                .position(labelPosition(in: size, origin: origin, horizontal: .right, vertical: .bottom))

            quadrantLabel("Important & Not Urgent")
                .position(labelPosition(in: size, origin: origin, horizontal: .left, vertical: .top))

            quadrantLabel("Not Urgent & Not Important")
                .position(labelPosition(in: size, origin: origin, horizontal: .left, vertical: .bottom))
        }
        .frame(width: size.width, height: size.height)
    }

    private func quadrantLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(appearance.themeColors(for: colorScheme).quadrantLabel)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private enum HorizontalQuadrantSide {
        case left
        case right
    }

    private enum VerticalQuadrantSide {
        case top
        case bottom
    }

    private func labelPosition(
        in size: CGSize,
        origin: CGPoint,
        horizontal: HorizontalQuadrantSide,
        vertical: VerticalQuadrantSide
    ) -> CGPoint {
        let margin: CGFloat = 72
        let minimumX: CGFloat = 92
        let maximumX = max(size.width - 92, minimumX)
        let minimumY: CGFloat = 26
        let maximumY = max(size.height - 26, minimumY)

        let x: CGFloat
        switch horizontal {
        case .left:
            x = min(max(origin.x - margin, minimumX), maximumX)
        case .right:
            x = min(max(origin.x + margin, minimumX), maximumX)
        }

        let y: CGFloat
        switch vertical {
        case .top:
            y = min(max(origin.y - margin, minimumY), maximumY)
        case .bottom:
            y = min(max(origin.y + margin, minimumY), maximumY)
        }

        return CGPoint(x: x, y: y)
    }

    private func connectionLayer(in size: CGSize) -> some View {
        let segments = derivedData.visibleConnectionSegments.map { segment in
            ConnectionSegment(
                start: canvasToScreenPosition(segment.start),
                end: canvasToScreenPosition(segment.end),
                colorHex: segment.colorHex
            )
        }

        return ConnectionLayerView(
            segments: segments,
            lineStyle: appearance.connectionLineStyle,
            lineColor: appearance.themeColors(for: colorScheme).connection,
            lineWidth: appearance.connectionLineThickness.width
        )
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func summaryLayer(in size: CGSize) -> some View {
        let items = summaryRenderItems().map { item in
            SummaryRenderItem(
                bracketX: canvasToScreenPosition(CGPoint(x: item.bracketX, y: 0)).x,
                topY: canvasToScreenPosition(CGPoint(x: 0, y: item.topY)).y,
                bottomY: canvasToScreenPosition(CGPoint(x: 0, y: item.bottomY)).y,
                summaryPoint: canvasToScreenPosition(item.summaryPoint)
            )
        }

        return SummaryLayerView(
            items: items,
            lineColor: appearance.themeColors(for: colorScheme).connection,
            lineWidth: appearance.connectionLineThickness.width
        )
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func grid(in size: CGSize) -> some View {
        let topLeft = screenToCanvasPosition(.zero)
        let bottomRight = screenToCanvasPosition(CGPoint(x: size.width, y: size.height))
        var canvasSpacing = appearance.gridSize.spacing
        let minimumScreenSpacing: CGFloat = 14

        while canvasSpacing * zoomScale < minimumScreenSpacing {
            canvasSpacing *= 2
        }

        let margin = canvasSpacing * 2
        let minX = min(topLeft.x, bottomRight.x) - margin
        let maxX = max(topLeft.x, bottomRight.x) + margin
        let minY = min(topLeft.y, bottomRight.y) - margin
        let maxY = max(topLeft.y, bottomRight.y) + margin
        let startCanvasX = floor(minX / canvasSpacing) * canvasSpacing
        let startCanvasY = floor(minY / canvasSpacing) * canvasSpacing
        let maxGridLineCount = 500

        var verticalLines: [CGFloat] = []
        var canvasX = startCanvasX
        while canvasX <= maxX && verticalLines.count < maxGridLineCount {
            let screenX = canvasToScreenPosition(CGPoint(x: canvasX, y: 0)).x
            if screenX >= -minimumScreenSpacing && screenX <= size.width + minimumScreenSpacing {
                verticalLines.append(screenX)
            }
            canvasX += canvasSpacing
        }

        var horizontalLines: [CGFloat] = []
        var canvasY = startCanvasY
        while canvasY <= maxY && horizontalLines.count < maxGridLineCount {
            let screenY = canvasToScreenPosition(CGPoint(x: 0, y: canvasY)).y
            if screenY >= -minimumScreenSpacing && screenY <= size.height + minimumScreenSpacing {
                horizontalLines.append(screenY)
            }
            canvasY += canvasSpacing
        }

        return Canvas { context, canvasSize in
            let lineColor = appearance.themeColors(for: colorScheme).grid

            var path = Path()

            for x in verticalLines {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))
            }

            for y in horizontalLines {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y))
            }

            context.stroke(path, with: .color(lineColor), lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
    }

    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("panOffset.width: \(panOffset.width, specifier: "%.1f")")
            Text("panOffset.height: \(panOffset.height, specifier: "%.1f")")
            Text("zoomScale: \(zoomScale, specifier: "%.2f")")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct CanvasDerivedData {
    var visibleNodeIDs: Set<CanvasNode.ID> = []
    var visibleNodes: [CanvasNode] = []
    var childrenByParent: [CanvasNode.ID: [CanvasNode]] = [:]
    var directChildCounts: [CanvasNode.ID: Int] = [:]
    var displayedProgressByNodeID: [CanvasNode.ID: Int] = [:]
    var displayedCostByNodeID: [CanvasNode.ID: Double] = [:]
    var displayedEffortByNodeID: [CanvasNode.ID: Double] = [:]
    var visibleConnectionSegments: [ConnectionSegment] = []
    var visibleNodesByID: [CanvasNode.ID: CanvasNode] = [:]
    /// Own colour, else the nearest coloured ancestor's (iThoughts `inheritColor`).
    var effectiveColorHexByNodeID: [CanvasNode.ID: String] = [:]
    var boundaries: [(rect: CGRect, colorHex: String?)] = []

    init() { }

    init(nodes: [CanvasNode], connections: [CanvasConnection], focusedNodeID: CanvasNode.ID? = nil, hidesCompletedTasks: Bool = false) {
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        childrenByParent = Dictionary(grouping: nodes.compactMap { node -> CanvasNode? in
            guard node.parentID != nil else {
                return nil
            }

            return node
        }, by: { $0.parentID! })
        directChildCounts = childrenByParent.mapValues(\.count)

        visibleNodeIDs = Set(
            nodes
                .filter { node in
                    Self.isVisibleInFocusMode(node, focusedNodeID: focusedNodeID, nodesByID: nodesByID) &&
                    Self.isVisible(node, nodesByID: nodesByID) &&
                    !(hidesCompletedTasks && Self.isInCompletedBranch(node, nodesByID: nodesByID))
                }
                .map(\.id)
        )
        visibleNodes = nodes.filter { visibleNodeIDs.contains($0.id) }
        visibleNodesByID = Dictionary(visibleNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        effectiveColorHexByNodeID = Self.effectiveColors(nodes: nodes, nodesByID: nodesByID)
        boundaries = Self.boundaries(
            visibleNodes: visibleNodes,
            visibleNodesByID: visibleNodesByID,
            childrenByParent: childrenByParent,
            colors: effectiveColorHexByNodeID
        )

        for node in nodes {
            displayedProgressByNodeID[node.id] = Self.displayedProgress(for: node, childrenByParent: childrenByParent)
            displayedCostByNodeID[node.id] = Self.displayedCost(for: node, childrenByParent: childrenByParent)
            displayedEffortByNodeID[node.id] = Self.displayedEffort(for: node, childrenByParent: childrenByParent)
        }

        visibleConnectionSegments = connections.compactMap { connection in
            guard let parentNode = nodesByID[connection.fromNodeID],
                  let childNode = nodesByID[connection.toNodeID],
                  visibleNodeIDs.contains(parentNode.id),
                  visibleNodeIDs.contains(childNode.id) else {
                return nil
            }

            return ConnectionSegment(
                start: Self.connectionStartPoint(from: parentNode, to: childNode),
                end: Self.connectionEndPoint(from: parentNode, to: childNode),
                colorHex: effectiveColorHexByNodeID[childNode.id]
            )
        }
    }

    private static func effectiveColors(
        nodes: [CanvasNode],
        nodesByID: [CanvasNode.ID: CanvasNode]
    ) -> [CanvasNode.ID: String] {
        var result: [CanvasNode.ID: String] = [:]
        var resolved = Set<CanvasNode.ID>()
        for node in nodes {
            var chain: [CanvasNode.ID] = []
            var current: CanvasNode? = node
            var found: String?
            var visited = Set<CanvasNode.ID>()
            while let candidate = current, !visited.contains(candidate.id) {
                visited.insert(candidate.id)
                if resolved.contains(candidate.id) {
                    found = result[candidate.id]
                    break
                }
                chain.append(candidate.id)
                if let hex = candidate.style.colorHex {
                    found = hex
                    break
                }
                current = candidate.parentID.flatMap { nodesByID[$0] }
            }
            for id in chain {
                resolved.insert(id)
                if let found {
                    result[id] = found
                }
            }
        }
        return result
    }

    private static func boundaries(
        visibleNodes: [CanvasNode],
        visibleNodesByID: [CanvasNode.ID: CanvasNode],
        childrenByParent: [CanvasNode.ID: [CanvasNode]],
        colors: [CanvasNode.ID: String]
    ) -> [(rect: CGRect, colorHex: String?)] {
        visibleNodes.filter(\.style.hasBoundary).map { node in
            var rect = CGRect(x: node.x, y: node.y, width: node.width, height: node.height)
            var stack = childrenByParent[node.id] ?? []
            var visited: Set<CanvasNode.ID> = [node.id]
            while let child = stack.popLast() {
                guard !visited.contains(child.id) else {
                    continue
                }
                visited.insert(child.id)
                guard let visibleChild = visibleNodesByID[child.id] else {
                    continue
                }
                rect = rect.union(CGRect(x: visibleChild.x, y: visibleChild.y, width: visibleChild.width, height: visibleChild.height))
                stack.append(contentsOf: childrenByParent[child.id] ?? [])
            }
            return (rect.insetBy(dx: -10, dy: -10), colors[node.id])
        }
    }

    private static func isVisibleInFocusMode(
        _ node: CanvasNode,
        focusedNodeID: CanvasNode.ID?,
        nodesByID: [CanvasNode.ID: CanvasNode]
    ) -> Bool {
        guard let focusedNodeID else {
            return true
        }

        if node.id == focusedNodeID {
            return true
        }

        var visitedIDs = Set<CanvasNode.ID>()
        var currentParentID = node.parentID

        while let parentID = currentParentID {
            guard !visitedIDs.contains(parentID) else {
                return false
            }

            if parentID == focusedNodeID {
                return true
            }

            visitedIDs.insert(parentID)
            currentParentID = nodesByID[parentID]?.parentID
        }

        return false
    }

    /// A completed task hides with its whole branch (iThoughts "Hide completed tasks").
    private static func isInCompletedBranch(_ node: CanvasNode, nodesByID: [CanvasNode.ID: CanvasNode]) -> Bool {
        var current: CanvasNode? = node
        var visited = Set<CanvasNode.ID>()
        while let candidate = current, !visited.contains(candidate.id) {
            if candidate.completedAt != nil {
                return true
            }
            visited.insert(candidate.id)
            current = candidate.parentID.flatMap { nodesByID[$0] }
        }
        return false
    }

    private static func isVisible(_ node: CanvasNode, nodesByID: [CanvasNode.ID: CanvasNode]) -> Bool {
        var visitedIDs = Set<CanvasNode.ID>()
        var currentParentID = node.parentID

        while let parentID = currentParentID {
            guard !visitedIDs.contains(parentID) else {
                return false
            }

            visitedIDs.insert(parentID)

            guard let parentNode = nodesByID[parentID] else {
                return true
            }

            if parentNode.isCollapsed {
                return false
            }

            currentParentID = parentNode.parentID
        }

        return true
    }

    private static func displayedProgress(
        for node: CanvasNode,
        childrenByParent: [CanvasNode.ID: [CanvasNode]]
    ) -> Int {
        guard node.rollupEnabled,
              let children = childrenByParent[node.id],
              !children.isEmpty else {
            return clampedProgress(node.progress)
        }

        let totalProgress = children.reduce(0.0) { result, child in
            result + Double(clampedProgress(child.progress))
        }

        return clampedProgress(Int((totalProgress / Double(children.count)).rounded()))
    }

    private static func displayedCost(
        for node: CanvasNode,
        childrenByParent: [CanvasNode.ID: [CanvasNode]]
    ) -> Double {
        guard node.rollupEnabled,
              let children = childrenByParent[node.id],
              !children.isEmpty else {
            return node.cost
        }

        return children.reduce(0) { result, child in
            result + child.cost
        }
    }

    private static func displayedEffort(
        for node: CanvasNode,
        childrenByParent: [CanvasNode.ID: [CanvasNode]]
    ) -> Double {
        guard node.rollupEnabled,
              let children = childrenByParent[node.id],
              !children.isEmpty else {
            return node.effort
        }

        return children.reduce(0) { result, child in
            result + child.effort
        }
    }

    private static func clampedProgress(_ progress: Int) -> Int {
        min(max(progress, 0), 100)
    }

    private static func nodeCenter(_ node: CanvasNode) -> CGPoint {
        CGPoint(x: node.x + node.width / 2, y: node.y + node.height / 2)
    }

    private static func connectionStartPoint(from parentNode: CanvasNode, to childNode: CanvasNode) -> CGPoint {
        let parentCenter = nodeCenter(parentNode)
        let childCenter = nodeCenter(childNode)
        let x = childCenter.x >= parentCenter.x ? parentNode.x + parentNode.width : parentNode.x
        return CGPoint(x: x, y: parentCenter.y)
    }

    private static func connectionEndPoint(from parentNode: CanvasNode, to childNode: CanvasNode) -> CGPoint {
        let parentCenter = nodeCenter(parentNode)
        let childCenter = nodeCenter(childNode)
        let x = childCenter.x >= parentCenter.x ? childNode.x : childNode.x + childNode.width
        return CGPoint(x: x, y: childCenter.y)
    }
}

private struct ConnectionSegment {
    var start: CGPoint
    var end: CGPoint
    var colorHex: String? = nil
}

private struct SummaryRenderItem {
    var bracketX: CGFloat
    var topY: CGFloat
    var bottomY: CGFloat
    var summaryPoint: CGPoint
}

private struct ConnectionLayerView: View {
    var segments: [ConnectionSegment]
    var lineStyle: CanvasAppearance.ConnectionLineStyle
    var lineColor: Color
    var lineWidth: CGFloat

    var body: some View {
        Canvas { context, _ in
            // Branch lines take their topic's colour, like iThoughts.
            for (colorHex, group) in Dictionary(grouping: segments, by: \.colorHex) {
                var path = Path()
                for segment in group {
                    ConnectionLinePathBuilder.addConnection(
                        from: segment.start,
                        to: segment.end,
                        style: lineStyle,
                        to: &path
                    )
                }
                context.stroke(path, with: .color(TopicColor.color(colorHex) ?? lineColor), lineWidth: lineWidth)
            }
        }
    }
}

private struct SummaryLayerView: View {
    var items: [SummaryRenderItem]
    var lineColor: Color
    var lineWidth: CGFloat

    var body: some View {
        Canvas { context, _ in
            var path = Path()

            for item in items {
                ConnectionLinePathBuilder.addSummaryBracket(
                    bracketX: item.bracketX,
                    topY: item.topY,
                    bottomY: item.bottomY,
                    summaryPoint: item.summaryPoint,
                    to: &path
                )
            }

            context.stroke(path, with: .color(lineColor.opacity(0.82)), lineWidth: lineWidth)
        }
    }
}

private struct NodeVisualStyle {
    var style: CanvasAppearance.NodeStyleOption
    var backgroundColor: Color
    var borderColor: Color
    var selectedBorderColor: Color
    var textColor: Color
    var shadowColor: Color
    var font: Font
    var fontPointSize: CGFloat
    var cornerRadius: CGFloat
    var showsShadow: Bool

    init(appearance: CanvasAppearance, colors: CanvasThemeColors) {
        style = appearance.nodeStyle
        backgroundColor = colors.nodeBackground
        borderColor = colors.nodeBorder
        selectedBorderColor = colors.selectedBorder
        textColor = colors.nodeText
        shadowColor = colors.shadow
        font = appearance.nodeFontSize.font
        fontPointSize = appearance.nodeFontSize.pointSize

        switch appearance.nodeStyle {
        case .roundedRectangle:
            cornerRadius = 8
            showsShadow = true
        case .capsule:
            cornerRadius = 24
            showsShadow = true
        case .minimalUnderline:
            cornerRadius = 3
            showsShadow = false
        }
    }
}

private struct NodeTaskIndicators {
    var showCompletionMarker: Bool
    var completionVisible: Bool
    var progress: Int?
    var dueDateText: String?
    var dueStatus: DueStatus
    var priority: TaskPriority
    var resources: [String]

    var hasDetailRow: Bool {
        progress != nil || dueDateText != nil || priority != .none || !resources.isEmpty
    }

    /// Badges appear only for data the topic actually has.
    init(
        node: CanvasNode,
        displayedProgress: Int,
        settings: TaskDisplaySettings,
        dateFormatter: DateFormatter
    ) {
        let isDone = node.completedAt != nil || displayedProgress >= 100
        showCompletionMarker = settings.showCompletionMarker
        completionVisible = settings.showCompletionMarker && isDone
        progress = settings.showProgress && displayedProgress > 0 && !isDone ? displayedProgress : nil
        dueDateText = settings.showDueDate && !isDone ? Self.compactDueDateText(node.dueDate, formatter: dateFormatter) : nil
        dueStatus = node.dueStatus()
        priority = settings.showPriority && !isDone ? node.priority : .none
        resources = settings.showResources ? node.resources : []
    }

    private static func compactDueDateText(_ dueDate: Date?, formatter: DateFormatter) -> String? {
        guard let dueDate else {
            return nil
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dueDay = calendar.startOfDay(for: dueDate)

        if dueDay < today {
            return "Overdue " + formatter.string(from: dueDate)
        }

        if calendar.isDateInToday(dueDate) {
            return "Today"
        }

        if calendar.isDateInTomorrow(dueDate) {
            return "Tomorrow"
        }

        return formatter.string(from: dueDate)
    }
}

private struct NodeView: View {
    @Binding var node: CanvasNode

    let visualStyle: NodeVisualStyle
    let taskIndicators: NodeTaskIndicators
    let isSelected: Bool
    let isPrimarySelected: Bool
    let isEditing: Bool
    let isDropTarget: Bool
    let zoomScale: CGFloat
    let hasChildren: Bool
    let fillHex: String?
    let isRelationshipSource: Bool
    let relationshipMenuItems: [RelationshipMenuItem]
    let knownResources: [String]
    let onStyleAction: (TopicStyleAction) -> Void
    let onTaskAction: (TaskAction) -> Void
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onDragStart: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnd: () -> Void
    let onAddChild: () -> Void
    let onAddSibling: () -> Void
    let onDelete: () -> Void
    let onPasteAsChild: () -> Void
    let onDuplicate: () -> Void
    let onEditDetails: () -> Void
    let onSetMarker: (NodeMarker) -> Void
    let onBranchOperation: (BranchOperation) -> Void
    let onToggleCollapse: () -> Void

    @FocusState private var isTitleFocused: Bool
    @State private var originalCanvasPosition: CGPoint?

    var body: some View {
        ZStack {
            TopicBoxBackground(
                shape: resolvedShape,
                fill: fillColor,
                stroke: borderColor,
                lineWidth: borderWidth,
                shadow: visualStyle.showsShadow ? visualStyle.shadowColor : nil,
                cornerRadius: visualStyle.cornerRadius * min(max(zoomScale, 0.5), 1.5),
                selectionHalo: isSelected || isRelationshipSource ? visualStyle.selectedBorderColor : nil
            )

            if isEditing {
                TextField("Title", text: $node.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(titleFont)
                    .multilineTextAlignment(.center)
                    .focused($isTitleFocused)
                    .onSubmit(onCommit)
                    .onKeyPress(.escape) {
                        onCancel()
                        return .handled
                    }
                    .padding(.horizontal, 10 * zoomScale)
                    .onAppear {
                        isTitleFocused = true
                    }
            } else {
                VStack(spacing: 4 * zoomScale) {
                    if let image = topicImage {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: imageDisplaySize.width * zoomScale, height: imageDisplaySize.height * zoomScale)
                            .clipShape(RoundedRectangle(cornerRadius: 3 * zoomScale))
                    }

                    HStack(spacing: 6 * zoomScale) {
                        if let systemImageName = node.marker.systemImageName {
                            Image(systemName: systemImageName)
                                .font(.system(size: 11 * zoomScale, weight: .medium))
                                .foregroundStyle(textColor.opacity(0.62))
                        }

                        if taskIndicators.completionVisible {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11 * zoomScale, weight: .medium))
                                .foregroundStyle(visualStyle.selectedBorderColor.opacity(0.70))
                        }

                        if !node.title.isEmpty || topicImage == nil {
                            Text(TopicText.attributed(node.title))
                                .font(titleFont)
                                .strikethrough(taskIndicators.completionVisible, color: textColor.opacity(0.5))
                                .foregroundStyle(textColor.opacity(taskIndicators.completionVisible ? 0.6 : 1))
                                .multilineTextAlignment(.center)
                                .lineLimit(maximumTitleLines)
                                .frame(maxWidth: .infinity)
                        }

                        if hasChildren {
                            Button(action: onToggleCollapse) {
                                Text(node.isCollapsed ? "+" : "-")
                                    .font(.system(size: 11 * zoomScale, weight: .semibold))
                                .frame(minWidth: 18 * zoomScale, minHeight: 18 * zoomScale)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(textColor.opacity(0.6))
                            .contentShape(Rectangle())
                            .help(node.isCollapsed ? "Expand" : "Collapse")
                        }
                    }

                    if taskIndicators.hasDetailRow {
                        TaskBadgeRow(
                            progress: taskIndicators.progress,
                            dueText: taskIndicators.dueDateText,
                            dueStatus: taskIndicators.dueStatus,
                            priority: taskIndicators.priority,
                            resources: taskIndicators.resources,
                            scale: zoomScale,
                            textColor: textColor
                        )
                    }
                }
                .padding(.horizontal, 10 * zoomScale)
            }
        }
        .frame(width: node.width * zoomScale, height: node.height * zoomScale)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .onTapGesture(count: 1, perform: onSelect)
        .contextMenu {
            if isSelected {
                Button("Add Child", action: onAddChild)
                Button("Add Sibling", action: onAddSibling)
                Button("Edit Title", action: onEdit)
                Button("Edit Details", action: onEditDetails)
                Menu("Marker") {
                    ForEach(NodeMarker.allCases) { marker in
                        Button {
                            onSetMarker(marker)
                        } label: {
                            Label {
                                Text(marker.label)
                            } icon: {
                                if let systemImageName = marker.systemImageName {
                                    Image(systemName: systemImageName)
                                }
                            }
                        }
                    }
                }

                Menu("Task") {
                    TaskActionMenuItems(
                        knownResources: knownResources,
                        assignedResources: node.resources,
                        isCompleted: node.isTaskCompleted,
                        perform: onTaskAction
                    )
                }

                Menu("Colour") {
                    ForEach(TopicColor.palette, id: \.hex) { entry in
                        Button {
                            onStyleAction(.setColor(entry.hex))
                        } label: {
                            Label {
                                Text(entry.name)
                            } icon: {
                                Image(nsImage: TopicColor.swatch(entry.hex))
                            }
                        }
                    }
                    Divider()
                    Button("No Colour") {
                        onStyleAction(.setColor(nil))
                    }
                }

                Menu("Shape") {
                    Button("Canvas Default") {
                        onStyleAction(.setShape(nil))
                    }
                    Divider()
                    ForEach(TopicShape.allCases) { shape in
                        Button {
                            onStyleAction(.setShape(shape))
                        } label: {
                            Label(shape.label, systemImage: shape.systemImageName)
                        }
                    }
                }

                Menu("Text Size") {
                    Button("Default") {
                        onStyleAction(.setTextSize(nil))
                    }
                    Divider()
                    ForEach([10.0, 12, 14, 18, 24, 30, 36, 48], id: \.self) { size in
                        Button("\(Int(size)) pt") {
                            onStyleAction(.setTextSize(size))
                        }
                    }
                }

                Button(node.style.hasBoundary ? "Remove Boundary" : "Add Boundary") {
                    onStyleAction(.toggleBoundary)
                }

                Menu("Image") {
                    Button(node.style.imageData == nil ? "Add Image..." : "Replace Image...") {
                        onStyleAction(.chooseImage)
                    }
                    Button("Remove Image") {
                        onStyleAction(.removeImage)
                    }
                    .disabled(node.style.imageData == nil)
                }

                Divider()

                Button("Add Relationship...") {
                    onStyleAction(.startRelationship)
                }

                if !relationshipMenuItems.isEmpty {
                    Menu("Relationships") {
                        ForEach(relationshipMenuItems) { item in
                            Menu(item.title) {
                                Button("Edit...") {
                                    onStyleAction(.editRelationship(item.id))
                                }
                                Button("Delete") {
                                    onStyleAction(.deleteRelationship(item.id))
                                }
                            }
                        }
                    }
                }

                Divider()

                Menu("Branch") {
                    Button("Select Branch") {
                        onBranchOperation(.select)
                    }
                    Button("Collapse Branch") {
                        onBranchOperation(.collapse)
                    }
                    Button("Expand Branch") {
                        onBranchOperation(.expand)
                    }
                    Button("Collapse Children") {
                        onBranchOperation(.collapseChildren)
                    }
                    Button("Expand Children") {
                        onBranchOperation(.expandChildren)
                    }
                    Button("Layout Selected Branch") {
                        onBranchOperation(.layout)
                    }
                    Button("Create Summary") {
                        onBranchOperation(.createSummary)
                    }
                    Button("Duplicate Branch") {
                        onBranchOperation(.duplicate)
                    }
                    Button("Delete Branch") {
                        onBranchOperation(.delete)
                    }
                    Button("Export Branch") {
                        onBranchOperation(.export)
                    }
                    Button("Focus on Branch") {
                        onBranchOperation(.focus)
                    }
                }

                Button("Paste as Child", action: onPasteAsChild)
                Button("Duplicate", action: onDuplicate)
                Button("Delete Node", action: onDelete)
            }
        }
        .gesture(nodeDragGesture)
    }

    private var resolvedShape: TopicShape {
        node.style.shape ?? visualStyle.style.topicShape
    }

    private var fillColor: Color {
        TopicColor.color(fillHex) ?? visualStyle.backgroundColor
    }

    private var textColor: Color {
        if let fillHex, resolvedShape.isFilled {
            return TopicColor.textColor(onFill: fillHex)
        }
        return visualStyle.textColor
    }

    private var titleFont: Font {
        let base = node.style.textSize.map { CGFloat($0) * 13 / 14 } ?? visualStyle.fontPointSize
        return .system(size: max(base * zoomScale, 1))
    }

    private var topicImage: NSImage? {
        TopicImageCache.image(for: node.id, data: node.style.imageData)
    }

    private var imageDisplaySize: CGSize {
        guard let image = topicImage, image.size.width > 0 else {
            return .zero
        }
        let preferred = node.style.imageWidth.map { CGFloat($0) } ?? min(image.size.width, 240)
        let width = min(preferred, max(node.width - 16, 16))
        let height = width * image.size.height / image.size.width
        let maximumHeight = max(node.height - (node.title.isEmpty ? 12 : 30), 12)
        if height > maximumHeight {
            return CGSize(width: maximumHeight * image.size.width / image.size.height, height: maximumHeight)
        }
        return CGSize(width: width, height: height)
    }

    private var maximumTitleLines: Int {
        let base = node.style.textSize.map { CGFloat($0) } ?? visualStyle.fontPointSize
        let imageHeight = topicImage == nil ? 0 : imageDisplaySize.height + 6
        let detailHeight: CGFloat = taskIndicators.hasDetailRow ? 14 : 0
        let available = node.height - imageHeight - detailHeight - 8
        return max(1, Int(available / (base * 1.25)))
    }

    private var borderColor: Color {
        if isDropTarget {
            return visualStyle.selectedBorderColor.opacity(0.75)
        }

        if isSelected || isRelationshipSource {
            return visualStyle.selectedBorderColor
        }
        if let fillHex {
            return resolvedShape.isFilled ? TopicColor.borderColor(forFill: fillHex) : (TopicColor.color(fillHex) ?? visualStyle.borderColor)
        }
        return visualStyle.borderColor
    }

    private var borderWidth: CGFloat {
        if isDropTarget {
            return 3
        }

        return isPrimarySelected ? 2.5 : (isSelected ? 2 : 1)
    }

    private var nodeDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("canvasScreen"))
            .onChanged { value in
                if originalCanvasPosition == nil {
                    originalCanvasPosition = CGPoint(x: node.x, y: node.y)
                    onDragStart()
                }

                guard let originalCanvasPosition else {
                    return
                }

                let canvasDeltaX = value.translation.width / zoomScale
                let canvasDeltaY = value.translation.height / zoomScale

                node.x = originalCanvasPosition.x + canvasDeltaX
                node.y = originalCanvasPosition.y + canvasDeltaY
                onDragChanged(CGSize(width: canvasDeltaX, height: canvasDeltaY))
            }
            .onEnded { _ in
                originalCanvasPosition = nil
                onDragEnd()
            }
    }
}

private enum KeyCode {
    static let `return`: UInt16 = 36
    static let tab: UInt16 = 48
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let forwardDelete: UInt16 = 117
}

private enum NavigationDirection {
    case up
    case down
    case left
    case right
}

private struct CopiedMapFragment {
    var nodes: [CanvasNode]
    var connections: [CanvasConnection]
    var summaries: [CanvasSummary] = []
    var rootNodeIDs: [CanvasNode.ID]
}

private struct NodeSearchResult: Identifiable, Equatable {
    var nodeID: CanvasNode.ID
    var title: String
    var matchSource: String
    var snippet: String

    var id: CanvasNode.ID {
        nodeID
    }
}

private struct SearchPanelView: View {
    @Binding var query: String

    let results: [NodeSearchResult]
    let isSearchFocused: FocusState<Bool>.Binding
    let onQueryChanged: (String) -> Void
    let onSelectResult: (NodeSearchResult) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Find Node", text: $query)
                    .textFieldStyle(.plain)
                    .focused(isSearchFocused)
                    .onSubmit {
                        if let firstResult = results.first {
                            onSelectResult(firstResult)
                        }
                    }

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Search")
            }
            .padding(10)

            Divider()

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Spacer()
            } else if results.isEmpty {
                VStack {
                    Spacer()
                    Text("No Results")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List(results) { result in
                    Button {
                        onSelectResult(result)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                Text(result.matchSource)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)

                                if !result.snippet.isEmpty {
                                    Text(result.snippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .onChange(of: query) { _, newValue in
            onQueryChanged(newValue)
        }
    }
}

private struct NotePanelView: View {
    @Binding var settings: NotePanelSettings

    let noteText: Binding<String>?
    let editorFocus: FocusState<Bool>.Binding
    let onEditingBegan: () -> Void
    let onSave: () -> Void
    let onSettingsChanged: () -> Void

    @State private var dragStartWidth: CGFloat?
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        ZStack {
            if let noteText {
                TextEditor(text: noteText)
                    .font(.body)
                    .focused(editorFocus)
                    .scrollContentBackground(.hidden)
                    .simultaneousGesture(TapGesture().onEnded {
                        onEditingBegan()
                    })
                    .onChange(of: noteText.wrappedValue) { _, _ in
                        onEditingBegan()
                        onSave()
                    }
            } else {
                TextEditor(text: .constant(""))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .disabled(true)
            }
        }
        .padding(8)
        .frame(width: horizontalPanelWidth, height: verticalPanelHeight)
        .frame(maxWidth: settings.position.isHorizontal ? nil : .infinity,
               maxHeight: settings.position.isHorizontal ? .infinity : nil)
        .background(.regularMaterial)
        .overlay(resizeHandle, alignment: resizeHandleAlignment)
    }

    private var horizontalPanelWidth: CGFloat? {
        settings.position.isHorizontal ? settings.width : nil
    }

    private var verticalPanelHeight: CGFloat? {
        settings.position.isHorizontal ? nil : settings.height
    }

    private var resizeHandleAlignment: Alignment {
        switch settings.position {
        case .left:
            .trailing
        case .right:
            .leading
        case .top:
            .bottom
        case .bottom:
            .top
        }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(
                width: settings.position.isHorizontal ? 6 : nil,
                height: settings.position.isHorizontal ? nil : 6
            )
            .contentShape(Rectangle())
            .gesture(resizeGesture)
            .overlay {
                if settings.position == .right {
                    Button {
                        settings.isVisible = false
                        onSettingsChanged()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 30)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Hide Notes")
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if settings.position.isHorizontal {
                    if dragStartWidth == nil {
                        dragStartWidth = settings.width
                    }

                    let startWidth = dragStartWidth ?? settings.width
                    let delta = settings.position == .left ? value.translation.width : -value.translation.width
                    settings.width = NotePanelSettings.clampWidth(startWidth + delta)
                } else {
                    if dragStartHeight == nil {
                        dragStartHeight = settings.height
                    }

                    let startHeight = dragStartHeight ?? settings.height
                    let delta = settings.position == .top ? value.translation.height : -value.translation.height
                    settings.height = NotePanelSettings.clampHeight(startHeight + delta)
                }
            }
            .onEnded { _ in
                dragStartWidth = nil
                dragStartHeight = nil
                onSettingsChanged()
            }
    }
}

private struct NodeDetailsView: View {
    @Binding var node: CanvasNode
    let directChildCount: Int
    let displayedProgress: Int
    let displayedCost: Double
    let displayedEffort: Double
    let onCreateAppleReminder: () -> Void
    let onCreateAppleReminderAgain: () -> Void
    let onOpenAppleReminder: () -> Void
    let onClearAppleReminderLink: () -> Void
    let onCreateAppleCalendarEvent: () -> Void
    let onCreateAppleCalendarEventAgain: () -> Void
    let onOpenAppleCalendarEvent: () -> Void
    let onClearAppleCalendarEventLink: () -> Void
    let onEditingBegan: () -> Void
    let onLinkOpenFailed: (String) -> Void
    let onSave: () -> Void

    @State private var newAttachmentURL = ""
    @State private var newAttachmentTitle = ""

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $node.title)
            }

            Section("Marker") {
                Picker("Marker", selection: $node.marker) {
                    ForEach(NodeMarker.allCases) { marker in
                        Label {
                            Text(marker.label)
                        } icon: {
                            if let systemImageName = marker.systemImageName {
                                Image(systemName: systemImageName)
                            }
                        }
                        .tag(marker)
                    }
                }
            }

            Section("Task Info") {
                Toggle("Auto Rollup from Children", isOn: $node.rollupEnabled)

                Text("Rollup uses direct child nodes only. \(directChildCount) direct children used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if node.rollupEnabled {
                    readOnlyTaskRow("Progress", value: "\(displayedProgress)%")
                    readOnlyTaskRow("Cost", value: displayedCost.formatted(.number.precision(.fractionLength(0...2))))
                    readOnlyTaskRow("Effort", value: displayedEffort.formatted(.number.precision(.fractionLength(0...2))))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Progress")
                            Spacer()
                            Text("\(node.progress)%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: progressBinding,
                            in: 0...100,
                            step: 5
                        )
                    }

                    TextField("Cost", value: $node.cost, format: .number.precision(.fractionLength(0...2)))
                    TextField("Effort", value: $node.effort, format: .number.precision(.fractionLength(0...2)))
                }

                OptionalDateField("Start Date", date: $node.startDate)
                OptionalDateField("Due Date", date: $node.dueDate)

                Picker("Priority", selection: $node.priority) {
                    ForEach(TaskPriority.allCases) { priority in
                        Text(priority.label).tag(priority)
                    }
                }

                TextField("Resources", text: resourcesBinding, prompt: Text("e.g. Anna, Ben"))
                    .help("People or teams assigned to this task, separated by commas")

                Toggle("Completed", isOn: Binding(
                    get: { node.isTaskCompleted },
                    set: { done in
                        if done != node.isTaskCompleted {
                            TaskAction.apply(.toggleDone, to: &node)
                        }
                    }
                ))

                if displayedProgress == 100 || node.completedAt != nil {
                    OptionalDateField("Completed At", date: $node.completedAt)
                }
            }

            Section("Links") {
                if node.links.isEmpty {
                    Text("No links")
                        .foregroundStyle(.secondary)
                }

                ForEach(node.links.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Link Title", text: $node.links[index].title)

                        HStack {
                            Text(node.links[index].urlString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button("Open") {
                                openLink(node.links[index])
                            }

                            Button("Remove") {
                                onEditingBegan()
                                node.links.remove(at: index)
                                syncLegacyAttachmentLinks()
                                onSave()
                            }
                        }
                    }
                }

                TextField("Add Link Title", text: $newAttachmentTitle)

                HStack {
                    TextField("Add URL", text: $newAttachmentURL)

                    Button("Add") {
                        addAttachmentLink()
                    }
                    .disabled(newAttachmentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button("Add File Link") {
                    addFileLink()
                }
            }

            Section {
                Text("Linked reminders and events sync both ways: ticking a reminder off on your iPhone marks the topic done, and edits here update Apple. Use Tasks ▸ Sync, or keep auto-sync on in Canvas settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Reminder") {
                if node.appleReminderID == nil {
                    Button("Create Apple Reminder", action: onCreateAppleReminder)
                } else {
                    Text("Already created in Apple Reminders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open Reminder", action: onOpenAppleReminder)

                    Button("Clear Apple Reminder Link", role: .destructive, action: onClearAppleReminderLink)

                    Text("This only clears the link in MyThoughts. It does not delete the Apple Reminder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Create New Reminder Again", action: onCreateAppleReminderAgain)
                }
            }

            Section("Apple Calendar") {
                if node.appleCalendarEventID == nil {
                    Button("Create Apple Calendar Event", action: onCreateAppleCalendarEvent)
                } else {
                    Text("Already created in Apple Calendar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open Calendar Event", action: onOpenAppleCalendarEvent)

                    Button("Clear Calendar Event Link", role: .destructive, action: onClearAppleCalendarEventLink)

                    Text("This only clears the link in MyThoughts. It does not delete the Apple Calendar event.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Create New Event Again", action: onCreateAppleCalendarEventAgain)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .simultaneousGesture(TapGesture().onEnded {
            onEditingBegan()
        })
        .onChange(of: node) { _, _ in
            onEditingBegan()
            onSave()
        }
    }

    private var resourcesBinding: Binding<String> {
        Binding(
            get: { node.resources.joined(separator: ", ") },
            set: { node.resources = IThoughtsImportService.resources(from: $0) }
        )
    }

    @ViewBuilder
    private func readOnlyTaskRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: { Double(node.progress) },
            set: { newValue in
                let progress = min(max(Int(newValue), 0), 100)
                onEditingBegan()
                node.progress = progress

                if progress == 100 {
                    node.completedAt = node.completedAt ?? Date()
                } else {
                    node.completedAt = nil
                }

                onSave()
            }
        )
    }

    private func addAttachmentLink() {
        let trimmedLink = newAttachmentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = newAttachmentTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLink.isEmpty else {
            return
        }

        onEditingBegan()
        node.links.append(
            NodeLink(
                title: trimmedTitle,
                urlString: trimmedLink
            )
        )
        syncLegacyAttachmentLinks()
        newAttachmentTitle = ""
        newAttachmentURL = ""
        onSave()
    }

    private func addFileLink() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Add File Link"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        guard openPanel.runModal() == .OK,
              let url = openPanel.url else {
            return
        }

        onEditingBegan()
        node.links.append(
            NodeLink(
                title: url.lastPathComponent,
                urlString: url.absoluteString,
                linkType: .file
            )
        )
        syncLegacyAttachmentLinks()
        onSave()
    }

    private func openLink(_ link: NodeLink) {
        guard let url = resolvedURL(for: link) else {
            onLinkOpenFailed("Could not open link: invalid URL.")
            return
        }

        guard NSWorkspace.shared.open(url) else {
            onLinkOpenFailed("Could not open link.")
            return
        }
    }

    private func resolvedURL(for link: NodeLink) -> URL? {
        let trimmedURL = link.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmedURL),
           url.scheme != nil {
            return url
        }

        if link.linkType == .file || trimmedURL.hasPrefix("/") || trimmedURL.hasPrefix("~") {
            let expandedPath = (trimmedURL as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath)
        }

        return nil
    }

    private func syncLegacyAttachmentLinks() {
        node.attachmentLinks = node.links.map(\.urlString)
    }
}

private struct OptionalDateField: View {
    let title: String
    @Binding var date: Date?

    init(_ title: String, date: Binding<Date?>) {
        self.title = title
        _date = date
    }

    var body: some View {
        Toggle(
            title,
            isOn: Binding(
                get: { date != nil },
                set: { isEnabled in
                    date = isEnabled ? (date ?? Date()) : nil
                }
            )
        )

        if let _ = date {
            DatePicker(
                title,
                selection: Binding(
                    get: { date ?? Date() },
                    set: { date = $0 }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )
        }
    }
}

enum NotePanelPosition: String, CaseIterable, Codable, Identifiable {
    case right
    case left
    case bottom
    case top

    var id: String { rawValue }

    var label: String {
        switch self {
        case .right:
            "Right"
        case .left:
            "Left"
        case .bottom:
            "Bottom"
        case .top:
            "Top"
        }
    }

    var isHorizontal: Bool {
        self == .left || self == .right
    }
}

struct NotePanelSettings: Codable, Equatable {
    var isVisible = false
    var position: NotePanelPosition = .right
    var width: CGFloat = 320
    var height: CGFloat = 220

    private static let userDefaultsKey = "NotePanelSettings"
    private static let minimumWidth: CGFloat = 220
    private static let maximumWidth: CGFloat = 600
    private static let minimumHeight: CGFloat = 140
    private static let maximumHeight: CGFloat = 500

    static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    static func clampHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, minimumHeight), maximumHeight)
    }

    static func load() -> NotePanelSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return NotePanelSettings()
        }

        do {
            var settings = try JSONDecoder().decode(NotePanelSettings.self, from: data)
            settings.width = clampWidth(settings.width)
            settings.height = clampHeight(settings.height)
            return settings
        } catch {
            print("MyThoughts NotePanelSettings: failed to load settings: \(error). Using defaults.")
            return NotePanelSettings()
        }
    }

    func save() {
        do {
            var settings = self
            settings.width = Self.clampWidth(settings.width)
            settings.height = Self.clampHeight(settings.height)
            let data = try JSONEncoder().encode(settings)
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        } catch {
            print("MyThoughts NotePanelSettings: failed to save settings: \(error).")
        }
    }
}

struct TaskDisplaySettings: Codable, Equatable {
    /// 2 = badges appear only on topics that have the data (so they can be on by default).
    static let currentVersion = 2

    var showCompletionMarker = true
    var showProgress = true
    var showDueDate = true
    var showPriority = true
    var showResources = true
    /// iThoughts "Hide completed tasks".
    var hideCompletedTasks = false
    /// Sync linked Reminders/Calendar items when MyThoughts becomes active.
    var autoSyncWithApple = true
    var version = TaskDisplaySettings.currentVersion

    init() { }

    private enum CodingKeys: String, CodingKey {
        case showCompletionMarker, showProgress, showDueDate, showPriority, showResources
        case hideCompletedTasks, autoSyncWithApple, version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        showCompletionMarker = try container.decodeIfPresent(Bool.self, forKey: .showCompletionMarker) ?? true
        if version >= 2 {
            showProgress = try container.decodeIfPresent(Bool.self, forKey: .showProgress) ?? true
            showDueDate = try container.decodeIfPresent(Bool.self, forKey: .showDueDate) ?? true
            showPriority = try container.decodeIfPresent(Bool.self, forKey: .showPriority) ?? true
        }
        // Version 1 showed "0%" on every topic, so it was off by default; badges are now
        // shown only where a task has data, so they start on.
        showResources = try container.decodeIfPresent(Bool.self, forKey: .showResources) ?? true
        hideCompletedTasks = try container.decodeIfPresent(Bool.self, forKey: .hideCompletedTasks) ?? false
        autoSyncWithApple = try container.decodeIfPresent(Bool.self, forKey: .autoSyncWithApple) ?? true
        self.version = TaskDisplaySettings.currentVersion
    }
}

struct CanvasAppearance: Codable, Equatable {
    var theme: ThemeOption = .systemDefault
    var nodeStyle: NodeStyleOption = .roundedRectangle
    var connectionLineStyle: ConnectionLineStyle = .roundedElbow
    var connectionLineThickness: ConnectionLineThickness = .thin
    var nodeFontSize: NodeFontSize = .medium
    var taskDisplay = TaskDisplaySettings()
    var showGrid = true
    var gridSize: GridSize = .medium
    var showQuadrants = false

    private static let userDefaultsKey = "CanvasAppearance"

    enum ThemeOption: String, CaseIterable, Codable, Identifiable {
        case systemDefault
        case lightPaper
        case warmPaper
        case softBlue
        case darkGraphite

        var id: String { rawValue }

        var label: String {
            switch self {
            case .systemDefault:
                "System Default"
            case .lightPaper:
                "Light Paper"
            case .warmPaper:
                "Warm Paper"
            case .softBlue:
                "Soft Blue"
            case .darkGraphite:
                "Dark Graphite"
            }
        }
    }

    enum NodeStyleOption: String, CaseIterable, Codable, Identifiable {
        case roundedRectangle
        case capsule
        case minimalUnderline

        var id: String { rawValue }

        var label: String {
            switch self {
            case .roundedRectangle:
                "Rounded Rectangle"
            case .capsule:
                "Capsule"
            case .minimalUnderline:
                "Minimal Underline"
            }
        }
    }

    enum ConnectionLineStyle: String, Codable, Identifiable {
        case roundedElbow
        case curved
        case elbow
        case straight
        case slightCurve

        static var allCases: [ConnectionLineStyle] {
            [.roundedElbow, .curved, .elbow, .straight]
        }

        var id: String { rawValue }

        var label: String {
            switch self {
            case .roundedElbow:
                "Rounded Elbow"
            case .curved, .slightCurve:
                "Curved"
            case .elbow:
                "Elbow"
            case .straight:
                "Straight"
            }
        }
    }

    enum ConnectionLineThickness: String, CaseIterable, Codable, Identifiable {
        case thin
        case medium

        var id: String { rawValue }

        var label: String {
            switch self {
            case .thin:
                "Thin"
            case .medium:
                "Medium"
            }
        }

        var width: CGFloat {
            switch self {
            case .thin:
                1.25
            case .medium:
                2
            }
        }
    }

    enum NodeFontSize: String, CaseIterable, Codable, Identifiable {
        case small
        case medium
        case large

        var id: String { rawValue }

        var label: String {
            switch self {
            case .small:
                "Small"
            case .medium:
                "Medium"
            case .large:
                "Large"
            }
        }

        var font: Font {
            switch self {
            case .small:
                .callout
            case .medium:
                .body
            case .large:
                .title3
            }
        }

        /// macOS point sizes of `font` (callout / body / title3).
        var pointSize: CGFloat {
            switch self {
            case .small:
                12
            case .medium:
                13
            case .large:
                15
            }
        }
    }

    enum GridSize: String, CaseIterable, Codable, Identifiable {
        case small
        case medium
        case large

        var id: String { rawValue }

        var label: String {
            switch self {
            case .small:
                "Small"
            case .medium:
                "Medium"
            case .large:
                "Large"
            }
        }

        var spacing: CGFloat {
            switch self {
            case .small:
                24
            case .medium:
                40
            case .large:
                64
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case theme
        case background
        case nodeStyle
        case connectionLineStyle
        case connectionLineThickness
        case nodeFontSize
        case taskDisplay
        case showGrid
        case gridSize
        case showQuadrants
    }

    init() { }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let theme = try container.decodeIfPresent(ThemeOption.self, forKey: .theme) {
            self.theme = theme
        } else {
            let legacyBackground = try container.decodeIfPresent(String.self, forKey: .background)
            self.theme = Self.themeForLegacyBackground(legacyBackground)
        }

        nodeStyle = try container.decodeIfPresent(NodeStyleOption.self, forKey: .nodeStyle) ?? .roundedRectangle
        let decodedConnectionLineStyle = try container.decodeIfPresent(ConnectionLineStyle.self, forKey: .connectionLineStyle) ?? .roundedElbow
        connectionLineStyle = decodedConnectionLineStyle == .slightCurve ? .curved : decodedConnectionLineStyle
        connectionLineThickness = try container.decodeIfPresent(ConnectionLineThickness.self, forKey: .connectionLineThickness) ?? .thin
        nodeFontSize = try container.decodeIfPresent(NodeFontSize.self, forKey: .nodeFontSize) ?? .medium
        taskDisplay = try container.decodeIfPresent(TaskDisplaySettings.self, forKey: .taskDisplay) ?? TaskDisplaySettings()
        showGrid = try container.decodeIfPresent(Bool.self, forKey: .showGrid) ?? true
        gridSize = try container.decodeIfPresent(GridSize.self, forKey: .gridSize) ?? .medium
        showQuadrants = try container.decodeIfPresent(Bool.self, forKey: .showQuadrants) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(theme, forKey: .theme)
        try container.encode(nodeStyle, forKey: .nodeStyle)
        try container.encode(connectionLineStyle, forKey: .connectionLineStyle)
        try container.encode(connectionLineThickness, forKey: .connectionLineThickness)
        try container.encode(nodeFontSize, forKey: .nodeFontSize)
        try container.encode(taskDisplay, forKey: .taskDisplay)
        try container.encode(showGrid, forKey: .showGrid)
        try container.encode(gridSize, forKey: .gridSize)
        try container.encode(showQuadrants, forKey: .showQuadrants)
    }

    private static func themeForLegacyBackground(_ rawValue: String?) -> ThemeOption {
        switch rawValue {
        case "warmWhite", "softYellow":
            .warmPaper
        case "lightBlue":
            .softBlue
        case "darkGray":
            .darkGraphite
        default:
            .systemDefault
        }
    }

    static func load() -> CanvasAppearance {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return CanvasAppearance()
        }

        do {
            return try JSONDecoder().decode(CanvasAppearance.self, from: data)
        } catch {
            print("MyThoughts CanvasAppearance: failed to load settings: \(error). Using defaults.")
            return CanvasAppearance()
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(self)
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        } catch {
            print("MyThoughts CanvasAppearance: failed to save settings: \(error).")
        }
    }

    func backgroundColor(for colorScheme: ColorScheme) -> Color {
        themeColors(for: colorScheme).canvasBackground
    }

    func themeColors(for colorScheme: ColorScheme) -> CanvasThemeColors {
        switch theme {
        case .systemDefault:
            CanvasThemeColors(
                canvasBackground: Color(nsColor: .windowBackgroundColor),
                grid: .secondary.opacity(0.16),
                quadrantAxis: .secondary.opacity(0.36),
                quadrantLabel: .secondary.opacity(0.72),
                nodeBackground: Color(nsColor: .controlBackgroundColor),
                nodeBorder: .secondary.opacity(0.25),
                selectedBorder: .accentColor,
                nodeText: .primary,
                connection: .secondary.opacity(0.35),
                shadow: .black.opacity(colorScheme == .dark ? 0.18 : 0.10)
            )
        case .lightPaper:
            CanvasThemeColors(
                canvasBackground: colorScheme == .dark ? Color(red: 0.13, green: 0.13, blue: 0.12) : Color(red: 0.98, green: 0.98, blue: 0.95),
                grid: Color(red: 0.42, green: 0.42, blue: 0.38).opacity(0.15),
                quadrantAxis: Color(red: 0.30, green: 0.30, blue: 0.27).opacity(0.30),
                quadrantLabel: .secondary.opacity(0.70),
                nodeBackground: colorScheme == .dark ? Color(red: 0.20, green: 0.20, blue: 0.18) : .white.opacity(0.94),
                nodeBorder: Color(red: 0.52, green: 0.50, blue: 0.44).opacity(0.30),
                selectedBorder: .accentColor,
                nodeText: .primary,
                connection: Color(red: 0.36, green: 0.36, blue: 0.33).opacity(0.36),
                shadow: .black.opacity(colorScheme == .dark ? 0.16 : 0.08)
            )
        case .warmPaper:
            CanvasThemeColors(
                canvasBackground: colorScheme == .dark ? Color(red: 0.16, green: 0.14, blue: 0.12) : Color(red: 0.98, green: 0.95, blue: 0.88),
                grid: Color(red: 0.58, green: 0.45, blue: 0.30).opacity(0.16),
                quadrantAxis: Color(red: 0.48, green: 0.36, blue: 0.22).opacity(0.34),
                quadrantLabel: Color(red: 0.45, green: 0.36, blue: 0.26).opacity(colorScheme == .dark ? 0.80 : 0.68),
                nodeBackground: colorScheme == .dark ? Color(red: 0.23, green: 0.20, blue: 0.17) : Color(red: 1.00, green: 0.98, blue: 0.93),
                nodeBorder: Color(red: 0.60, green: 0.45, blue: 0.30).opacity(0.34),
                selectedBorder: Color(red: 0.33, green: 0.48, blue: 0.82),
                nodeText: .primary,
                connection: Color(red: 0.48, green: 0.36, blue: 0.24).opacity(0.40),
                shadow: .black.opacity(colorScheme == .dark ? 0.18 : 0.09)
            )
        case .softBlue:
            CanvasThemeColors(
                canvasBackground: colorScheme == .dark ? Color(red: 0.09, green: 0.12, blue: 0.16) : Color(red: 0.91, green: 0.96, blue: 0.99),
                grid: Color(red: 0.25, green: 0.45, blue: 0.62).opacity(0.15),
                quadrantAxis: Color(red: 0.22, green: 0.38, blue: 0.52).opacity(0.34),
                quadrantLabel: Color(red: 0.24, green: 0.36, blue: 0.46).opacity(colorScheme == .dark ? 0.85 : 0.68),
                nodeBackground: colorScheme == .dark ? Color(red: 0.15, green: 0.19, blue: 0.24) : Color(red: 0.97, green: 0.99, blue: 1.00),
                nodeBorder: Color(red: 0.34, green: 0.53, blue: 0.68).opacity(0.30),
                selectedBorder: Color(red: 0.20, green: 0.46, blue: 0.86),
                nodeText: .primary,
                connection: Color(red: 0.25, green: 0.42, blue: 0.56).opacity(0.40),
                shadow: .black.opacity(colorScheme == .dark ? 0.18 : 0.08)
            )
        case .darkGraphite:
            CanvasThemeColors(
                canvasBackground: Color(red: 0.08, green: 0.08, blue: 0.09),
                grid: Color.white.opacity(0.08),
                quadrantAxis: Color.white.opacity(0.20),
                quadrantLabel: Color.white.opacity(0.62),
                nodeBackground: Color(red: 0.15, green: 0.15, blue: 0.17),
                nodeBorder: Color.white.opacity(0.16),
                selectedBorder: Color(red: 0.42, green: 0.62, blue: 1.00),
                nodeText: Color.white.opacity(0.90),
                connection: Color.white.opacity(0.28),
                shadow: .black.opacity(0.24)
            )
        }
    }
}

extension CanvasAppearance.NodeStyleOption {
    /// The iThoughts shape a canvas-wide node style corresponds to.
    var topicShape: TopicShape {
        switch self {
        case .roundedRectangle: .roundedRectangle
        case .capsule: .pill
        case .minimalUnderline: .underline
        }
    }
}

struct CanvasThemeColors {
    var canvasBackground: Color
    var grid: Color
    var quadrantAxis: Color
    var quadrantLabel: Color
    var nodeBackground: Color
    var nodeBorder: Color
    var selectedBorder: Color
    var nodeText: Color
    var connection: Color
    var shadow: Color
}

private struct KeyboardEventMonitor: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyDown: onKeyDown)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.startMonitoring()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKeyDown = onKeyDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var onKeyDown: (NSEvent) -> Bool
        private var monitor: Any?

        init(onKeyDown: @escaping (NSEvent) -> Bool) {
            self.onKeyDown = onKeyDown
        }

        deinit {
            stopMonitoring()
        }

        func startMonitoring() {
            guard monitor == nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else {
                    return event
                }

                return onKeyDown(event) ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

#Preview {
    InfiniteCanvasView()
        .frame(width: 720, height: 480)
}
