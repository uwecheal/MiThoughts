import Foundation

struct CanvasSummary: Identifiable, Equatable, Codable {
    var id: UUID
    var parentID: UUID?
    var summarizedNodeIDs: [UUID]
    var summaryNodeID: UUID
    var sortIndex: Int?

    init(
        id: UUID = UUID(),
        parentID: UUID?,
        summarizedNodeIDs: [UUID],
        summaryNodeID: UUID,
        sortIndex: Int? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.summarizedNodeIDs = summarizedNodeIDs
        self.summaryNodeID = summaryNodeID
        self.sortIndex = sortIndex
    }
}
