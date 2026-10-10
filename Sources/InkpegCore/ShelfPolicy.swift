import Foundation

public enum ShelfPolicy {
    public static func canAdmit(snapshot: WorkspaceSnapshot, matterID: UUID, capacity: Int) -> Bool {
        guard capacity > 0, snapshot.matters.contains(where: { $0.id == matterID }) else { return false }
        let pinnedCount = snapshot.materials.filter { $0.matterID == matterID && $0.status == .hanging && $0.pinned }.count
        return pinnedCount < capacity
    }
    public static func admit(_ incoming: MaterialRecord, snapshot: WorkspaceSnapshot, capacity: Int) -> ImportResult {
        if snapshot.materials.contains(where: { $0.id == incoming.id }) {
            return ImportResult(disposition: .duplicate(incoming.id), snapshot: snapshot)
        }
        guard canAdmit(snapshot: snapshot, matterID: incoming.matterID, capacity: capacity) else {
            return ImportResult(disposition: .shelfFull, snapshot: snapshot)
        }
        var state = snapshot
        let hanging = state.materials.filter { $0.matterID == incoming.matterID && $0.status == .hanging }
        let candidates = hanging.filter { !$0.pinned }.sorted { $0.order < $1.order }
        let takeCount = max(0, hanging.count - capacity + 1)
        let displaced = Set(candidates.prefix(takeCount).map(\.id))
        for index in state.materials.indices where displaced.contains(state.materials[index].id) {
            state.materials[index].status = .takenDown
        }
        var item = incoming
        let maximumOrder = state.materials.filter { $0.matterID == incoming.matterID }.map(\.order).max() ?? -1
        guard maximumOrder < Int.max else { return ImportResult(disposition: .shelfFull, snapshot: snapshot) }
        item.order = maximumOrder + 1
        item.status = .hanging
        state.materials.append(item)
        return ImportResult(disposition: .hanging(item.id), snapshot: state)
    }
    public static func visible(snapshot: WorkspaceSnapshot, matterID: UUID, capacity: Int) -> [MaterialRecord] {
        Array(snapshot.materials.filter { $0.matterID == matterID && $0.status == .hanging }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.order < $1.order
        }.prefix(max(0, capacity)))
    }
}
