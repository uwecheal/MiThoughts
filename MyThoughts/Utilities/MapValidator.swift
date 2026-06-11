import Foundation

enum MapIssueKind: String, CaseIterable {
    case missingParent
    case selfParent
    case circularParent
    case missingParentChildConnection
    case duplicateParentChildConnection
    case missingConnectionEndpoint
    case conflictingParentChildConnection
    case duplicateSortIndex
    case invalidSummaryReference

    var label: String {
        switch self {
        case .missingParent:
            "Missing parent"
        case .selfParent:
            "Self parent"
        case .circularParent:
            "Circular parent"
        case .missingParentChildConnection:
            "Missing parent-child connection"
        case .duplicateParentChildConnection:
            "Duplicate parent-child connection"
        case .missingConnectionEndpoint:
            "Missing connection endpoint"
        case .conflictingParentChildConnection:
            "Conflicting parent-child connection"
        case .duplicateSortIndex:
            "Duplicate sibling order"
        case .invalidSummaryReference:
            "Invalid summary reference"
        }
    }
}

struct MapValidationIssue: Identifiable {
    let id = UUID()
    var kind: MapIssueKind
    var message: String
}

struct MapValidationReport {
    var issues: [MapValidationIssue]

    var isValid: Bool {
        issues.isEmpty
    }

    var summary: String {
        guard !issues.isEmpty else {
            return "No issues found."
        }

        let counts = Dictionary(grouping: issues, by: \.kind)
        return MapIssueKind.allCases
            .compactMap { kind in
                guard let count = counts[kind]?.count else {
                    return nil
                }

                return "\(kind.label): \(count)"
            }
            .joined(separator: "\n")
    }
}

struct MapRepairResult {
    var nodes: [CanvasNode]
    var connections: [CanvasConnection]
    var summaries: [CanvasSummary] = []
    var actions: [String]
    var validationReport: MapValidationReport

    var summary: String {
        guard !actions.isEmpty else {
            return "No repairs needed."
        }

        let counts = Dictionary(grouping: actions, by: { $0 })
        return counts
            .keys
            .sorted()
            .map { action in
                "\(action): \(counts[action]?.count ?? 0)"
            }
            .joined(separator: "\n")
    }
}

enum MapValidator {
    private static let parentChildType = "parentChild"

    static func validate(
        nodes: [CanvasNode],
        connections: [CanvasConnection],
        summaries: [CanvasSummary] = []
    ) -> MapValidationReport {
        let nodeIDs = Set(nodes.map(\.id))
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var issues: [MapValidationIssue] = []

        for node in nodes {
            if node.parentID == node.id {
                issues.append(
                    MapValidationIssue(
                        kind: .selfParent,
                        message: "\(node.title) points to itself as parent."
                    )
                )
            } else if let parentID = node.parentID, !nodeIDs.contains(parentID) {
                issues.append(
                    MapValidationIssue(
                        kind: .missingParent,
                        message: "\(node.title) points to a missing parent."
                    )
                )
            }

            if hasParentCycle(startingAt: node.id, nodesByID: nodesByID) {
                issues.append(
                    MapValidationIssue(
                        kind: .circularParent,
                        message: "\(node.title) is part of a circular parent chain."
                    )
                )
            }
        }

        for connection in connections where !nodeIDs.contains(connection.fromNodeID) || !nodeIDs.contains(connection.toNodeID) {
            issues.append(
                MapValidationIssue(
                    kind: .missingConnectionEndpoint,
                    message: "A connection points to a missing node."
                )
            )
        }

        let parentChildConnections = connections.filter { $0.type == parentChildType }
        let parentChildGroups = Dictionary(grouping: parentChildConnections) {
            ParentChildKey(parentID: $0.fromNodeID, childID: $0.toNodeID)
        }

        for group in parentChildGroups.values where group.count > 1 {
            issues.append(
                MapValidationIssue(
                    kind: .duplicateParentChildConnection,
                    message: "Duplicate parent-child connections were found."
                )
            )
        }

        for node in nodes {
            guard let parentID = node.parentID, nodeIDs.contains(parentID), parentID != node.id else {
                continue
            }

            let matchingCount = parentChildGroups[ParentChildKey(parentID: parentID, childID: node.id)]?.count ?? 0
            if matchingCount == 0 {
                issues.append(
                    MapValidationIssue(
                        kind: .missingParentChildConnection,
                        message: "\(node.title) has a parentID but no matching connection."
                    )
                )
            }
        }

        for connection in parentChildConnections where nodeIDs.contains(connection.fromNodeID) && nodeIDs.contains(connection.toNodeID) {
            let childParentID = nodesByID[connection.toNodeID]?.parentID
            if childParentID != connection.fromNodeID {
                issues.append(
                    MapValidationIssue(
                        kind: .conflictingParentChildConnection,
                        message: "A parent-child connection conflicts with child.parentID."
                    )
                )
            }
        }

        for siblings in Dictionary(grouping: nodes, by: \.parentID).values {
            let groupedSortIndexes = Dictionary(grouping: siblings, by: \.sortIndex)
            if siblings.contains(where: { !$0.sortIndex.isFinite }) {
                issues.append(
                    MapValidationIssue(
                        kind: .duplicateSortIndex,
                        message: "Sibling nodes have invalid sortIndex values."
                    )
                )
            } else if groupedSortIndexes.values.contains(where: { $0.count > 1 }) {
                issues.append(
                    MapValidationIssue(
                        kind: .duplicateSortIndex,
                        message: "Sibling nodes have duplicate sortIndex values."
                    )
                )
            }
        }

        for summary in summaries {
            if !nodeIDs.contains(summary.summaryNodeID) ||
                summary.summarizedNodeIDs.contains(where: { !nodeIDs.contains($0) }) ||
                summary.summarizedNodeIDs.count < 2 {
                issues.append(
                    MapValidationIssue(
                        kind: .invalidSummaryReference,
                        message: "A summary points to missing or insufficient nodes."
                    )
                )
            }
        }

        return MapValidationReport(issues: issues)
    }

    static func repair(
        nodes originalNodes: [CanvasNode],
        connections originalConnections: [CanvasConnection],
        summaries originalSummaries: [CanvasSummary] = []
    ) -> MapRepairResult {
        var nodes = originalNodes
        var connections = originalConnections
        var summaries = originalSummaries
        var actions: [String] = []

        var nodeIDs = Set(nodes.map(\.id))

        for index in nodes.indices {
            if nodes[index].parentID == nodes[index].id {
                nodes[index].parentID = nil
                actions.append("Cleared self parent")
            } else if let parentID = nodes[index].parentID, !nodeIDs.contains(parentID) {
                nodes[index].parentID = nil
                actions.append("Cleared missing parent")
            }
        }

        var didBreakCycle = true
        while didBreakCycle {
            didBreakCycle = false
            let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            for index in nodes.indices where hasParentCycle(startingAt: nodes[index].id, nodesByID: nodesByID) {
                nodes[index].parentID = nil
                actions.append("Cleared circular parent")
                didBreakCycle = true
                break
            }
        }

        nodeIDs = Set(nodes.map(\.id))
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seenParentChildKeys = Set<ParentChildKey>()

        connections.removeAll { connection in
            if !nodeIDs.contains(connection.fromNodeID) || !nodeIDs.contains(connection.toNodeID) {
                actions.append("Removed missing-endpoint connection")
                return true
            }

            guard connection.type == parentChildType else {
                return false
            }

            let key = ParentChildKey(parentID: connection.fromNodeID, childID: connection.toNodeID)
            guard nodesByID[connection.toNodeID]?.parentID == connection.fromNodeID else {
                actions.append("Removed conflicting parent-child connection")
                return true
            }

            guard !seenParentChildKeys.contains(key) else {
                actions.append("Removed duplicate parent-child connection")
                return true
            }

            seenParentChildKeys.insert(key)
            return false
        }

        for node in nodes {
            guard let parentID = node.parentID, nodeIDs.contains(parentID), parentID != node.id else {
                continue
            }

            let key = ParentChildKey(parentID: parentID, childID: node.id)
            if !seenParentChildKeys.contains(key) {
                connections.append(
                    CanvasConnection(
                        id: UUID(),
                        fromNodeID: parentID,
                        toNodeID: node.id,
                        type: parentChildType
                    )
                )
                seenParentChildKeys.insert(key)
                actions.append("Added missing parent-child connection")
            }
        }

        let groupedIndexes = Dictionary(grouping: nodes.indices, by: { nodes[$0].parentID })
        for indexes in groupedIndexes.values {
            let sortIndexes = indexes.map { nodes[$0].sortIndex }
            let hasDuplicateSortIndex = Set(sortIndexes).count != sortIndexes.count
            let hasInvalidSortIndex = sortIndexes.contains { !$0.isFinite }

            guard hasDuplicateSortIndex || hasInvalidSortIndex else {
                continue
            }

            let sortedIndexes = indexes.sorted { left, right in
                let leftSortIndex = nodes[left].sortIndex.isFinite ? nodes[left].sortIndex : 0
                let rightSortIndex = nodes[right].sortIndex.isFinite ? nodes[right].sortIndex : 0

                if leftSortIndex == rightSortIndex {
                    return nodes[left].y < nodes[right].y
                }

                return leftSortIndex < rightSortIndex
            }

            for (offset, index) in sortedIndexes.enumerated() {
                nodes[index].sortIndex = Double(offset)
            }

            actions.append("Reassigned sibling order")
        }

        let validNodeIDs = Set(nodes.map(\.id))
        summaries = summaries.compactMap { summary in
            guard validNodeIDs.contains(summary.summaryNodeID) else {
                actions.append("Removed invalid summary")
                return nil
            }

            var repairedSummary = summary
            repairedSummary.summarizedNodeIDs = summary.summarizedNodeIDs.filter { validNodeIDs.contains($0) }
            guard repairedSummary.summarizedNodeIDs.count >= 2 else {
                actions.append("Removed invalid summary")
                return nil
            }

            return repairedSummary
        }

        let report = validate(nodes: nodes, connections: connections, summaries: summaries)
        return MapRepairResult(
            nodes: nodes,
            connections: connections,
            summaries: summaries,
            actions: actions,
            validationReport: report
        )
    }

    private static func hasParentCycle(startingAt nodeID: CanvasNode.ID, nodesByID: [CanvasNode.ID: CanvasNode]) -> Bool {
        var seen = Set<CanvasNode.ID>()
        var currentID: CanvasNode.ID? = nodeID

        while let id = currentID {
            if seen.contains(id) {
                return true
            }

            seen.insert(id)
            currentID = nodesByID[id]?.parentID
        }

        return false
    }

    private struct ParentChildKey: Hashable {
        var parentID: UUID
        var childID: UUID
    }
}
