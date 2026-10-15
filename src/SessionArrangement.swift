import Foundation

struct SessionGroup: Equatable {
    let id: UUID
    var name: String
    var collapsed = false
}

struct SessionItem: Equatable {
    let id: TabID
    var groupID: UUID?
}

enum SessionDragItem: Hashable {
    case tab(TabID)
    case group(UUID)
}

enum SessionDropTarget: Equatable {
    case before(TabID), after(TabID), intoTab(TabID)
    case beforeGroup(UUID), afterGroup(UUID), intoGroup(UUID)
    case end
}

/// A value-only transaction: the live surfaces are reparented only after both lists validate.
struct SessionArrangement: Equatable {
    var items: [SessionItem] = []
    var groups: [UUID: SessionGroup] = [:]

    var ids: [TabID] { items.map(\.id) }

    var isValid: Bool {
        guard Set(ids).count == items.count else { return false }
        var seen: Set<UUID> = []
        var previous: UUID?
        for item in items {
            if let group = item.groupID {
                guard groups[group]?.id == group else { return false }
                if group != previous, !seen.insert(group).inserted { return false }
            }
            previous = item.groupID
        }
        return seen == Set(groups.keys)
    }

    func ids(for drag: SessionDragItem) -> [TabID] {
        switch drag {
        case .tab(let id): return items.contains { $0.id == id } ? [id] : []
        case .group(let id): return items.filter { $0.groupID == id }.map(\.id)
        }
    }

    mutating func pruneEmptyGroups() {
        let used = Set(items.compactMap(\.groupID))
        groups = groups.filter { used.contains($0.key) }
    }

    mutating func ungroup(_ id: UUID) {
        for index in items.indices where items[index].groupID == id { items[index].groupID = nil }
        groups.removeValue(forKey: id)
    }

    mutating func removeFromGroup(_ id: TabID) {
        guard let index = items.firstIndex(where: { $0.id == id }), let group = items[index].groupID else { return }
        var item = items.remove(at: index)
        item.groupID = nil
        let insertion = items.lastIndex(where: { $0.groupID == group }).map { $0 + 1 } ?? index
        items.insert(item, at: insertion)
        pruneEmptyGroups()
    }

    var nextGroupName: String {
        let names = Set(groups.values.map(\.name))
        var number = 1
        while names.contains("Group \(number)") { number += 1 }
        return "Group \(number)"
    }

    struct Transfer {
        let source: SessionArrangement
        let destination: SessionArrangement
        let movedIDs: [TabID]
    }

    static func transfer(_ drag: SessionDragItem, from source: Self, to destination: Self,
                         at target: SessionDropTarget, sameWindow: Bool) -> Transfer? {
        guard source.isValid, destination.isValid, !sameWindow || source == destination else { return nil }
        let movingIDs = source.ids(for: drag)
        let movingSet = Set(movingIDs)
        guard !movingIDs.isEmpty else { return nil }
        if !sameWindow, !movingSet.isDisjoint(with: destination.ids) { return nil }
        var result = destination
        result.items.removeAll { movingSet.contains($0.id) }
        var moving = source.items.filter { movingSet.contains($0.id) }
        let wholeGroup: Bool
        switch drag {
        case .tab:
            wholeGroup = false
            moving[0].groupID = nil
        case .group(let group):
            wholeGroup = true
            result.groups[group] = source.groups[group]
        }
        var insertion: Int
        var membership: UUID?
        switch target {
        case .end:
            insertion = result.items.count
        case .before(let id), .after(let id):
            guard let anchor = result.items.firstIndex(where: { $0.id == id }) else { return nil }
            let after = target == .after(id)
            if let group = result.items[anchor].groupID {
                if wholeGroup {
                    let indices = result.items.indices.filter { result.items[$0].groupID == group }
                    insertion = after ? indices.last! + 1 : indices.first!
                } else {
                    membership = group
                    insertion = anchor + (after ? 1 : 0)
                }
            } else { insertion = anchor + (after ? 1 : 0) }
        case .beforeGroup(let group), .afterGroup(let group), .intoGroup(let group):
            let indices = result.items.indices.filter { result.items[$0].groupID == group }
            if let first = indices.first, let last = indices.last {
                insertion = target == .beforeGroup(group) ? first : last + 1
            } else {
                // The only member can leave its own group at either edge even
                // though removing it also removed the target's last anchor.
                guard sameWindow, !wholeGroup, target != .intoGroup(group),
                      let original = source.items.firstIndex(where: { $0.groupID == group }),
                      movingSet.contains(source.items[original].id) else { return nil }
                insertion = original
            }
            if target == .intoGroup(group) {
                if drag == .group(group) { return nil }
                membership = group
            }
        case .intoTab(let id):
            guard let anchor = result.items.firstIndex(where: { $0.id == id }) else { return nil }
            if let group = result.items[anchor].groupID {
                if drag == .group(group) { return nil }
                membership = group
                insertion = result.items.lastIndex(where: { $0.groupID == group })! + 1
            } else {
                let group: SessionGroup
                if case .group(let id) = drag, let existing = source.groups[id] { group = existing }
                else { group = SessionGroup(id: UUID(), name: result.nextGroupName) }
                result.groups[group.id] = group
                result.items[anchor].groupID = group.id
                membership = group.id
                insertion = anchor + 1
            }
        }
        if let membership {
            for index in moving.indices { moving[index].groupID = membership }
            result.groups[membership]?.collapsed = false
        }
        result.items.insert(contentsOf: moving, at: insertion)
        result.pruneEmptyGroups()
        var remainder = source
        remainder.items.removeAll { movingSet.contains($0.id) }
        remainder.pruneEmptyGroups()
        guard result.isValid, remainder.isValid else { return nil }
        return Transfer(source: sameWindow ? result : remainder, destination: result, movedIDs: movingIDs)
    }

    static func selection(afterRemoving removed: Set<TabID>, from ids: [TabID], selected: TabID?) -> TabID? {
        let remaining = ids.filter { !removed.contains($0) }
        guard !remaining.isEmpty else { return nil }
        if let selected, remaining.contains(selected) { return selected }
        let oldIndex = selected.flatMap { ids.firstIndex(of: $0) } ?? 0
        let before = ids.prefix(oldIndex).filter { !removed.contains($0) }.count
        return remaining[min(before, remaining.count - 1)]
    }
}
