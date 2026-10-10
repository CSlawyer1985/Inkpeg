import Foundation

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var generation: UInt64 = 0
    public var materials: [MaterialRecord] = []
    public var matters: [MatterGroup] = [MatterGroup(id: MatterGroup.ungroupedID, name: "未分组")]
    public var selectedMatterID = MatterGroup.ungroupedID
    public var privacyHidden = false
    public var captureFolder: CaptureFolderSetting?
    public init() {}
}
