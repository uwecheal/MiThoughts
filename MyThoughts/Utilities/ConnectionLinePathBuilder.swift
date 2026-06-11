import SwiftUI

enum ConnectionLinePathBuilder {
    static func addConnection(
        from start: CGPoint,
        to end: CGPoint,
        style: CanvasAppearance.ConnectionLineStyle,
        to path: inout Path
    ) {
        path.move(to: start)

        switch style {
        case .straight:
            path.addLine(to: end)
        case .curved, .slightCurve:
            addCurvedConnection(from: start, to: end, to: &path)
        case .elbow:
            addElbowConnection(from: start, to: end, to: &path)
        case .roundedElbow:
            addRoundedElbowConnection(from: start, to: end, to: &path)
        }
    }

    static func addSummaryBracket(
        bracketX: CGFloat,
        topY: CGFloat,
        bottomY: CGFloat,
        summaryPoint: CGPoint,
        to path: inout Path
    ) {
        let radius = min(12, max((bottomY - topY) / 4, 0))
        let connectorY = (topY + bottomY) / 2
        let connectorEndX = summaryPoint.x

        path.move(to: CGPoint(x: bracketX, y: topY))

        if radius > 1 {
            path.addLine(to: CGPoint(x: bracketX + radius, y: topY))
            path.addQuadCurve(
                to: CGPoint(x: bracketX + radius, y: topY + radius),
                control: CGPoint(x: bracketX + radius * 2, y: topY)
            )
            path.addLine(to: CGPoint(x: bracketX + radius, y: bottomY - radius))
            path.addQuadCurve(
                to: CGPoint(x: bracketX, y: bottomY),
                control: CGPoint(x: bracketX + radius * 2, y: bottomY)
            )
        } else {
            path.addLine(to: CGPoint(x: bracketX, y: bottomY))
        }

        path.move(to: CGPoint(x: bracketX + radius, y: connectorY))
        path.addLine(to: CGPoint(x: connectorEndX, y: connectorY))
        path.addLine(to: summaryPoint)
    }

    private static func addCurvedConnection(from start: CGPoint, to end: CGPoint, to path: inout Path) {
        let midpointX = (start.x + end.x) / 2
        path.addCurve(
            to: end,
            control1: CGPoint(x: midpointX, y: start.y),
            control2: CGPoint(x: midpointX, y: end.y)
        )
    }

    private static func addElbowConnection(from start: CGPoint, to end: CGPoint, to path: inout Path) {
        let midpointX = (start.x + end.x) / 2
        path.addLine(to: CGPoint(x: midpointX, y: start.y))
        path.addLine(to: CGPoint(x: midpointX, y: end.y))
        path.addLine(to: end)
    }

    private static func addRoundedElbowConnection(from start: CGPoint, to end: CGPoint, to path: inout Path) {
        let midpointX = (start.x + end.x) / 2
        let dx = end.x - start.x
        let dy = end.y - start.y
        let horizontalDirection: CGFloat = dx >= 0 ? 1 : -1
        let verticalDirection: CGFloat = dy >= 0 ? 1 : -1
        let radius = min(14, max(abs(dx) / 4, 0), max(abs(dy) / 2, 0))

        guard radius > 1 else {
            addElbowConnection(from: start, to: end, to: &path)
            return
        }

        let firstCornerEntry = CGPoint(x: midpointX - horizontalDirection * radius, y: start.y)
        let firstCornerExit = CGPoint(x: midpointX, y: start.y + verticalDirection * radius)
        let secondCornerEntry = CGPoint(x: midpointX, y: end.y - verticalDirection * radius)
        let secondCornerExit = CGPoint(x: midpointX + horizontalDirection * radius, y: end.y)

        path.addLine(to: firstCornerEntry)
        path.addQuadCurve(to: firstCornerExit, control: CGPoint(x: midpointX, y: start.y))
        path.addLine(to: secondCornerEntry)
        path.addQuadCurve(to: secondCornerExit, control: CGPoint(x: midpointX, y: end.y))
        path.addLine(to: end)
    }
}
