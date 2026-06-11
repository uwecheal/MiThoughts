import Foundation

struct CanvasConnection: Identifiable, Equatable, Codable {
    let id: UUID
    var fromNodeID: UUID
    var toNodeID: UUID
    var type: String
}
