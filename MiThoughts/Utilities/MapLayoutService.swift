import Foundation

struct MapLayoutResult {
    var nodes: [CanvasNode]
    var didMoveNodes: Bool
}

enum MapLayoutService {
    static func layoutBranch(
        nodes: [CanvasNode],
        rootID: CanvasNode.ID,
        horizontalSpacing: CGFloat = 240,
        verticalSpacing: CGFloat = 90
    ) -> MapLayoutResult {
        guard let rootNode = nodes.first(where: { $0.id == rootID }) else {
            return MapLayoutResult(nodes: nodes, didMoveNodes: false)
        }

        let childrenByParent = Dictionary(grouping: nodes.filter { $0.parentID != nil }, by: { $0.parentID! })
            .mapValues { children in
                children.sorted { left, right in
                    if left.sortIndex == right.sortIndex {
                        return left.y < right.y
                    }

                    return left.sortIndex < right.sortIndex
                }
            }
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let branchIDs = collectBranchIDs(rootID: rootID, childrenByParent: childrenByParent)
        var updatedNodes = nodes
        var positionsByID: [CanvasNode.ID: CGPoint] = [
            rootID: CGPoint(x: rootNode.x, y: rootNode.y)
        ]

        func subtreeHeight(for nodeID: CanvasNode.ID) -> CGFloat {
            guard let node = nodesByID[nodeID] else {
                return 0
            }

            let children = childrenByParent[nodeID] ?? []
            guard !children.isEmpty else {
                return node.height
            }

            let childrenHeight = children.reduce(0) { result, child in
                result + subtreeHeight(for: child.id)
            }
            let spacingHeight = CGFloat(max(children.count - 1, 0)) * verticalSpacing
            return max(node.height, childrenHeight + spacingHeight)
        }

        func assignDescendantPositions(parent: CanvasNode) {
            let children = childrenByParent[parent.id] ?? []
            guard !children.isEmpty else {
                return
            }

            let parentCenterY = (positionsByID[parent.id]?.y ?? parent.y) + parent.height / 2
            let totalHeight = children.reduce(0) { result, child in
                result + subtreeHeight(for: child.id)
            } + CGFloat(max(children.count - 1, 0)) * verticalSpacing
            var cursorY = parentCenterY - totalHeight / 2

            for child in children {
                let childSubtreeHeight = subtreeHeight(for: child.id)
                let childY = cursorY + childSubtreeHeight / 2 - child.height / 2
                let childPosition = CGPoint(
                    x: parent.x + horizontalSpacing,
                    y: childY
                )
                positionsByID[child.id] = childPosition

                var childForLayout = child
                childForLayout.x = childPosition.x
                childForLayout.y = childPosition.y
                assignDescendantPositions(parent: childForLayout)

                cursorY += childSubtreeHeight + verticalSpacing
            }
        }

        assignDescendantPositions(parent: rootNode)

        var didMoveNodes = false
        for index in updatedNodes.indices where branchIDs.contains(updatedNodes[index].id) {
            guard let newPosition = positionsByID[updatedNodes[index].id] else {
                continue
            }

            if updatedNodes[index].x != newPosition.x || updatedNodes[index].y != newPosition.y {
                updatedNodes[index].x = newPosition.x
                updatedNodes[index].y = newPosition.y
                didMoveNodes = true
            }
        }

        return MapLayoutResult(nodes: updatedNodes, didMoveNodes: didMoveNodes)
    }

    private static func collectBranchIDs(
        rootID: CanvasNode.ID,
        childrenByParent: [CanvasNode.ID: [CanvasNode]]
    ) -> Set<CanvasNode.ID> {
        var result: Set<CanvasNode.ID> = [rootID]

        func visit(_ nodeID: CanvasNode.ID) {
            for child in childrenByParent[nodeID] ?? [] {
                guard !result.contains(child.id) else {
                    continue
                }

                result.insert(child.id)
                visit(child.id)
            }
        }

        visit(rootID)
        return result
    }
}
