import Foundation

struct MapHistorySnapshot: Equatable {
    var nodes: [CanvasNode]
    var connections: [CanvasConnection]
    var summaries: [CanvasSummary] = []
}

struct HistoryManager {
    private(set) var undoStack: [MapHistorySnapshot] = []
    private(set) var redoStack: [MapHistorySnapshot] = []

    private let maximumSnapshotCount = 50

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    mutating func record(_ snapshot: MapHistorySnapshot) {
        guard undoStack.last != snapshot else {
            return
        }

        undoStack.append(snapshot)
        if undoStack.count > maximumSnapshotCount {
            undoStack.removeFirst(undoStack.count - maximumSnapshotCount)
        }

        redoStack.removeAll()
    }

    mutating func undo(currentSnapshot: MapHistorySnapshot) -> MapHistorySnapshot? {
        guard let snapshot = undoStack.popLast() else {
            return nil
        }

        redoStack.append(currentSnapshot)
        if redoStack.count > maximumSnapshotCount {
            redoStack.removeFirst(redoStack.count - maximumSnapshotCount)
        }

        return snapshot
    }

    mutating func redo(currentSnapshot: MapHistorySnapshot) -> MapHistorySnapshot? {
        guard let snapshot = redoStack.popLast() else {
            return nil
        }

        undoStack.append(currentSnapshot)
        if undoStack.count > maximumSnapshotCount {
            undoStack.removeFirst(undoStack.count - maximumSnapshotCount)
        }

        return snapshot
    }
}
