import Foundation

struct StoreJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case contentReady, contentCommitted }
    let id: UUID
    var phase: Phase
    let record: MaterialRecord
    var baseVersionID: UUID? = nil
}
