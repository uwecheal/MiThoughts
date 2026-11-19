import Foundation

enum TemplateID: String, CaseIterable, Identifiable {
    case blankMap
    case weeklyPlan
    case projectPlan
    case eisenhowerMatrix
    case meetingNotes
    case studyPlan
    case youtubeContentPlan
    case yogaClassPlan

    var id: String { rawValue }
}

struct TemplateDefinition: Identifiable, Equatable {
    var id: TemplateID
    var name: String
    var description: String
}

struct TemplateGeneratedMap {
    var nodes: [CanvasNode]
    var connections: [CanvasConnection]
    var rootNodeID: CanvasNode.ID?
    var enableQuadrants: Bool
}

enum BuiltInTemplateFactory {
    static let templates: [TemplateDefinition] = [
        TemplateDefinition(
            id: .blankMap,
            name: "Blank Map",
            description: "Start with an empty canvas."
        ),
        TemplateDefinition(
            id: .weeklyPlan,
            name: "Weekly Plan",
            description: "Plan weekdays, weekend work, and notes."
        ),
        TemplateDefinition(
            id: .projectPlan,
            name: "Project Plan",
            description: "Capture goals, tasks, timeline, risks, and next steps."
        ),
        TemplateDefinition(
            id: .eisenhowerMatrix,
            name: "Eisenhower Matrix",
            description: "Organize work by urgency and importance."
        ),
        TemplateDefinition(
            id: .meetingNotes,
            name: "Meeting Notes",
            description: "Structure agenda, discussion, decisions, and follow-up."
        ),
        TemplateDefinition(
            id: .studyPlan,
            name: "Study Plan",
            description: "Track topics, reading, practice, questions, and review."
        ),
        TemplateDefinition(
            id: .youtubeContentPlan,
            name: "YouTube Content Plan",
            description: "Move an idea through script, filming, editing, and publishing."
        ),
        TemplateDefinition(
            id: .yogaClassPlan,
            name: "Yoga Class Plan",
            description: "Plan a class from theme through closing words."
        )
    ]

    static func generate(_ templateID: TemplateID, nodeSize: CGSize) -> TemplateGeneratedMap {
        switch templateID {
        case .blankMap:
            TemplateGeneratedMap(nodes: [], connections: [], rootNodeID: nil, enableQuadrants: false)
        case .weeklyPlan:
            makeSimpleTree(
                rootTitle: "Weekly Plan",
                childTitles: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Weekend", "Notes"],
                nodeSize: nodeSize
            )
        case .projectPlan:
            makeSimpleTree(
                rootTitle: "Project Plan",
                childTitles: ["Goals", "Tasks", "Timeline", "Resources", "Risks", "Decisions", "Next Steps"],
                nodeSize: nodeSize
            )
        case .eisenhowerMatrix:
            makeEisenhowerMatrix(nodeSize: nodeSize)
        case .meetingNotes:
            makeSimpleTree(
                rootTitle: "Meeting Notes",
                childTitles: ["Agenda", "Attendees", "Key Discussion", "Decisions", "Action Items", "Follow-up"],
                nodeSize: nodeSize
            )
        case .studyPlan:
            makeSimpleTree(
                rootTitle: "Study Plan",
                childTitles: ["Topics", "Reading", "Practice", "Questions", "Review", "Exam / Deadline"],
                nodeSize: nodeSize
            )
        case .youtubeContentPlan:
            makeSimpleTree(
                rootTitle: "YouTube Content Plan",
                childTitles: ["Ideas", "Script", "Filming", "Editing", "Thumbnail", "Publishing", "Follow-up"],
                nodeSize: nodeSize
            )
        case .yogaClassPlan:
            makeSimpleTree(
                rootTitle: "Yoga Class Plan",
                childTitles: [
                    "Theme",
                    "Opening",
                    "Warm-Up",
                    "Standing Sequence",
                    "Peak Pose",
                    "Cool Down",
                    "Savasana",
                    "Closing Words",
                    "Props / Modifications"
                ],
                nodeSize: nodeSize
            )
        }
    }

    private static func makeSimpleTree(
        rootTitle: String,
        childTitles: [String],
        nodeSize: CGSize
    ) -> TemplateGeneratedMap {
        let rootID = UUID()
        var nodes = [
            CanvasNode(
                id: rootID,
                title: rootTitle,
                x: 0,
                y: 0,
                width: nodeSize.width,
                height: nodeSize.height,
                sortIndex: 0
            )
        ]
        var connections: [CanvasConnection] = []
        let horizontalSpacing: CGFloat = 240
        let verticalSpacing: CGFloat = 90
        let totalHeight = CGFloat(max(childTitles.count - 1, 0)) * verticalSpacing
        let rootCenterY = nodeSize.height / 2

        for (index, title) in childTitles.enumerated() {
            let childID = UUID()
            let childCenterY = rootCenterY - totalHeight / 2 + CGFloat(index) * verticalSpacing
            nodes.append(
                CanvasNode(
                    id: childID,
                    title: title,
                    x: horizontalSpacing,
                    y: childCenterY - nodeSize.height / 2,
                    width: nodeSize.width,
                    height: nodeSize.height,
                    sortIndex: Double(index),
                    parentID: rootID
                )
            )
            connections.append(
                CanvasConnection(
                    id: UUID(),
                    fromNodeID: rootID,
                    toNodeID: childID,
                    type: "parentChild"
                )
            )
        }

        return TemplateGeneratedMap(
            nodes: nodes,
            connections: connections,
            rootNodeID: rootID,
            enableQuadrants: false
        )
    }

    private static func makeEisenhowerMatrix(nodeSize: CGSize) -> TemplateGeneratedMap {
        let rootID = UUID()
        let quadrantItems: [(String, CGPoint)] = [
            ("Urgent & Important", CGPoint(x: 240, y: -180)),
            ("Important & Not Urgent", CGPoint(x: -420, y: -180)),
            ("Urgent & Not Important", CGPoint(x: 240, y: 180)),
            ("Not Urgent & Not Important", CGPoint(x: -420, y: 180))
        ]
        var nodes = [
            CanvasNode(
                id: rootID,
                title: "Eisenhower Matrix",
                x: -nodeSize.width / 2,
                y: -nodeSize.height / 2,
                width: nodeSize.width,
                height: nodeSize.height,
                sortIndex: 0
            )
        ]
        var connections: [CanvasConnection] = []

        for (index, item) in quadrantItems.enumerated() {
            let childID = UUID()
            nodes.append(
                CanvasNode(
                    id: childID,
                    title: item.0,
                    x: item.1.x,
                    y: item.1.y,
                    width: nodeSize.width,
                    height: nodeSize.height,
                    sortIndex: Double(index),
                    parentID: rootID
                )
            )
            connections.append(
                CanvasConnection(
                    id: UUID(),
                    fromNodeID: rootID,
                    toNodeID: childID,
                    type: "parentChild"
                )
            )
        }

        return TemplateGeneratedMap(
            nodes: nodes,
            connections: connections,
            rootNodeID: rootID,
            enableQuadrants: true
        )
    }
}
