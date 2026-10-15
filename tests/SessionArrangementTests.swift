import AppKit

// Pure transfer transactions and native sidebar fixtures; no live shell or user preferences.
enum SessionArrangementTests {
    static func run(_ check: (String, Bool) -> Void) {
        let ids = (1...8).map { TabID(raw: $0) }
        let a = ids[0], b = ids[1], c = ids[2], d = ids[3], e = ids[4], f = ids[5]
        let plain = SessionArrangement(items: [a, b, c, d].map { SessionItem(id: $0) })
        func move(_ item: SessionDragItem, in list: SessionArrangement, to target: SessionDropTarget) -> SessionArrangement? {
            SessionArrangement.transfer(item, from: list, to: list, at: target, sameWindow: true)?.destination
        }
        check("session order starts valid", plain.isValid)
        check("dragging a row above another reorders by identity", move(.tab(d), in: plain, to: .before(b))?.ids == [a, d, b, c])
        check("dragging downward adjusts for the removed source slot", move(.tab(a), in: plain, to: .after(c))?.ids == [b, c, a, d])
        check("dropping in empty sidebar space moves to the end", move(.tab(b), in: plain, to: .end)?.ids == [a, c, d, b])
        check("dropping onto itself cannot create a group", move(.tab(a), in: plain, to: .intoTab(a)) == nil)
        check("a stale source identity is rejected", move(.tab(f), in: plain, to: .end) == nil)
        check("a stale target identity is rejected", move(.tab(a), in: plain, to: .before(f)) == nil)
        check("a stale group target is rejected", move(.tab(a), in: plain, to: .intoGroup(UUID())) == nil)

        guard let grouped = move(.tab(c), in: plain, to: .intoTab(a)),
              let group = grouped.items.first?.groupID else { check("create session group fixture", false); return }
        check("a center drop creates a contiguous two-session group", grouped.ids == [a, c, b, d] && grouped.ids(for: .group(group)) == [a, c])
        check("new groups have a useful default name", grouped.groups[group]?.name == "Group 1")
        check("created groups start expanded", grouped.groups[group]?.collapsed == false)
        check("group creation leaves its input untouched", plain.groups.isEmpty && plain.ids == [a, b, c, d])
        let joined = move(.tab(d), in: grouped, to: .intoTab(c))!
        check("a center drop on a member joins its existing group", joined.ids(for: .group(group)) == [a, c, d] && joined.groups.count == 1)
        let headerJoin = move(.tab(b), in: grouped, to: .intoGroup(group))!
        check("a group header drop appends to its members", headerJoin.ids == [a, c, b, d] && headerJoin.ids(for: .group(group)) == [a, c, b])
        let edgeJoin = move(.tab(d), in: grouped, to: .before(c))!
        check("a row inserted between group members inherits membership", edgeJoin.ids(for: .group(group)) == [a, d, c] && edgeJoin.isValid)
        let outside = move(.tab(c), in: grouped, to: .beforeGroup(group))!
        check("dropping before a group extracts a member without splitting the group", outside.ids == [c, a, b, d] && outside.items[0].groupID == nil && outside.isValid)
        let below = move(.tab(a), in: grouped, to: .afterGroup(group))!
        check("dropping below a group extracts a member", below.ids == [c, a, b, d] && below.items[1].groupID == nil)
        let extracted = move(.tab(a), in: grouped, to: .end)!
        check("dragging a member to empty space removes its membership", extracted.ids == [c, b, d, a] && extracted.items.last?.groupID == nil)
        check("one-member groups are retained", extracted.ids(for: .group(group)) == [c] && extracted.groups[group] != nil)
        for index in [0, 1, plain.items.count - 1] {
            var loneMember = plain
            loneMember.items[index].groupID = group
            loneMember.groups[group] = grouped.groups[group]
            let member = loneMember.items[index].id
            check("a sole member at index \(index) can leave before its group", move(.tab(member), in: loneMember, to: .beforeGroup(group)) == plain)
            check("a sole member at index \(index) can leave after its group", move(.tab(member), in: loneMember, to: .afterGroup(group)) == plain)
            check("a sole member at index \(index) cannot drop into its own group", move(.tab(member), in: loneMember, to: .intoGroup(group)) == nil)
        }
        var collapsed = grouped
        collapsed.groups[group]?.collapsed = true
        check("dropping into a collapsed group expands it", move(.tab(d), in: collapsed, to: .intoGroup(group))?.groups[group]?.collapsed == false)
        let whole = move(.group(group), in: collapsed, to: .end)!
        check("a group is reordered as an intact block", whole.ids == [b, d, a, c] && whole.ids(for: .group(group)) == [a, c])
        check("group reorder preserves collapse and name", whole.groups[group] == collapsed.groups[group])
        var named = grouped
        named.groups[group]?.name = "Work"
        let combined = move(.group(group), in: named, to: .intoTab(b))!
        check("joining an ungrouped tab to a dragged group retains its name and identity", combined.groups[group]?.name == "Work" && combined.ids(for: .group(group)) == [b, a, c])
        check("a group cannot be dropped into itself", move(.group(group), in: grouped, to: .intoGroup(group)) == nil)
        let twoGroups = move(.tab(d), in: grouped, to: .intoTab(b))!
        let second = twoGroups.items.first { $0.id == b }!.groupID!
        check("default group names do not collide", twoGroups.groups[second]?.name == "Group 2")
        let snapped = move(.group(second), in: twoGroups, to: .before(c))!
        check("group edge drops never split another group", snapped.ids == [b, d, a, c] && snapped.isValid && snapped.groups.count == 2)
        let merged = move(.group(second), in: twoGroups, to: .intoGroup(group))!
        check("dropping a group into another merges all its members", merged.ids == [a, c, b, d] && merged.groups.count == 1 && merged.ids(for: .group(group)).count == 4)
        check("merged groups leave no orphan metadata", merged.groups[second] == nil && merged.isValid)

        var removed = joined
        removed.removeFromGroup(c)
        check("remove-from-group places the member after its surviving group", removed.ids == [a, d, c, b] && removed.items[2].groupID == nil && removed.isValid)
        removed.removeFromGroup(a)
        removed.removeFromGroup(d)
        check("empty groups are pruned after the last member leaves", removed.groups.isEmpty && removed.isValid)
        var dissolved = twoGroups
        dissolved.ungroup(group)
        check("ungroup retains order and unrelated group metadata", dissolved.ids == twoGroups.ids && dissolved.groups.count == 1 && dissolved.groups[second] != nil && dissolved.isValid)

        let other = SessionArrangement(items: [SessionItem(id: e), SessionItem(id: f)])
        let transfer = SessionArrangement.transfer(.tab(c), from: grouped, to: other, at: .before(f), sameWindow: false)!
        check("cross-window transfer removes only the requested source session", transfer.source.ids == [a, b, d] && transfer.destination.ids == [e, c, f])
        check("a single transferred member is ungrouped by default", transfer.destination.items[1].groupID == nil && transfer.destination.groups.isEmpty)
        check("cross-window plans do not mutate their inputs", grouped.ids == [a, c, b, d] && other.ids == [e, f])
        let groupTransfer = SessionArrangement.transfer(.group(group), from: collapsed, to: other, at: .end, sameWindow: false)!
        check("a whole group retains metadata across windows", groupTransfer.source.groups.isEmpty && groupTransfer.destination.groups[group] == collapsed.groups[group])
        check("whole-group transfer preserves member order", groupTransfer.movedIDs == [a, c] && groupTransfer.destination.ids == [e, f, a, c])
        let intoOtherGroup = SessionArrangement.transfer(.tab(e), from: other, to: grouped, at: .intoGroup(group), sameWindow: false)!
        check("cross-window sessions can join an existing group", intoOtherGroup.destination.ids(for: .group(group)) == [a, c, e])
        let crossCreate = SessionArrangement.transfer(.tab(e), from: other, to: plain, at: .intoTab(b), sameWindow: false)!
        check("a cross-window center drop creates a group around the destination", crossCreate.destination.items.first { $0.id == e }?.groupID == crossCreate.destination.items.first { $0.id == b }?.groupID && crossCreate.destination.groups.count == 1)
        let single = SessionArrangement(items: [SessionItem(id: a)])
        let last = SessionArrangement.transfer(.tab(a), from: single, to: other, at: .end, sameWindow: false)!
        check("transferring the last session does not create a replacement shell", last.source.items.isEmpty && last.destination.ids == [e, f, a])
        let empty = SessionArrangement()
        check("a detached window can receive the existing session into an empty list", SessionArrangement.transfer(.tab(a), from: single, to: empty, at: .end, sameWindow: false)?.destination.ids == [a])
        check("duplicate ownership across different windows is refused", SessionArrangement.transfer(.tab(a), from: single, to: plain, at: .end, sameWindow: false) == nil)
        check("a same-window plan cannot refer to two different lists", SessionArrangement.transfer(.tab(a), from: plain, to: other, at: .end, sameWindow: true) == nil)
        let invalid = SessionArrangement(items: [SessionItem(id: a), SessionItem(id: a)])
        check("duplicate session IDs invalidate a list", !invalid.isValid)
        let broken = SessionArrangement(items: [SessionItem(id: a, groupID: group), SessionItem(id: b), SessionItem(id: c, groupID: group)], groups: grouped.groups)
        check("split group membership is rejected", !broken.isValid)
        check("invalid arrangements cannot be transferred", SessionArrangement.transfer(.tab(a), from: broken, to: other, at: .end, sameWindow: false) == nil)
        check("dangling group membership is invalid", !SessionArrangement(items: [SessionItem(id: a, groupID: group)]).isValid)
        check("empty group metadata is invalid", !SessionArrangement(groups: grouped.groups).isValid)

        check("reordering does not change the active session identity", move(.tab(a), in: plain, to: .end)?.ids.contains(b) == true)
        check("removing an inactive session retains the active identity", SessionArrangement.selection(afterRemoving: [a], from: plain.ids, selected: c) == c)
        check("the next surviving neighbor replaces a moved active group member", SessionArrangement.selection(afterRemoving: [a, b, c], from: plain.ids, selected: b) == d)
        check("the previous surviving neighbor replaces the last active member", SessionArrangement.selection(afterRemoving: [c, d], from: plain.ids, selected: d) == b)
        check("moving every session leaves no active source identity", SessionArrangement.selection(afterRemoving: Set(plain.ids), from: plain.ids, selected: a) == nil)

        // Deterministic mixed cross-window moves exercise ownership and contiguity together.
        var windows = [plain, other]
        var seed: UInt64 = 0xB00E
        func random(_ upper: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(upper))
        }
        var valid = true
        var completed = 0
        for _ in 0..<1500 {
            let from = random(2), to = random(2)
            guard !windows[from].items.isEmpty else { continue }
            let sourceItem = windows[from].items[random(windows[from].items.count)]
            let drag: SessionDragItem = sourceItem.groupID.flatMap { random(3) == 0 ? .group($0) : nil } ?? .tab(sourceItem.id)
            let target: SessionDropTarget
            if windows[to].items.isEmpty || random(5) == 0 { target = .end }
            else {
                let anchor = windows[to].items[random(windows[to].items.count)]
                switch random(5) {
                case 0: target = .before(anchor.id)
                case 1: target = .after(anchor.id)
                case 2: target = .intoTab(anchor.id)
                case 3: target = anchor.groupID.map(SessionDropTarget.intoGroup) ?? .before(anchor.id)
                default: target = anchor.groupID.map(SessionDropTarget.afterGroup) ?? .after(anchor.id)
                }
            }
            guard let plan = SessionArrangement.transfer(drag, from: windows[from], to: windows[to], at: target, sameWindow: from == to) else { continue }
            windows[from] = plan.source
            windows[to] = plan.destination
            let all = windows.flatMap(\.ids)
            valid = valid && windows.allSatisfy(\.isValid) && all.count == 6 && Set(all) == Set([a, b, c, d, e, f])
            completed += 1
        }
        check("mixed transfers preserve unique ownership and contiguous groups over 1500 attempts", valid && completed > 700)
        sidebar(check, grouped: grouped, group: group)
        check("new-window shortcut belongs to the application", AppShortcut.owns(.init(command: true, option: false, shift: false, control: false, key: "n", keyCode: 45)))
        check("close-window shortcut belongs to the application", AppShortcut.owns(.init(command: true, option: false, shift: true, control: false, key: "w", keyCode: 13)))
    }

    private static func sidebar(_ check: (String, Bool) -> Void, grouped: SessionArrangement, group: UUID) {
        _ = NSApplication.shared
        let sidebar = TabSidebar(frame: NSRect(x: 0, y: 0, width: 200, height: 280))
        func rows(_ list: SessionArrangement) -> [TabPresentation] {
            list.ids.map { TabPresentation.make(label: "Session \($0.raw)", customTitle: true) }
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func row(_ id: TabID) -> NSView? { views(sidebar).first { $0.accessibilityIdentifier() == "SessionTab-\(id.raw)" } }
        let active = grouped.ids[0]
        sidebar.reload(arrangement: grouped, rows: rows(grouped), selected: active)
        check("native sidebar renders one header for a contiguous group", views(sidebar).filter { $0.accessibilityIdentifier().hasPrefix("SessionGroup-") }.count == 1)
        check("expanded groups render every session", grouped.ids.allSatisfy { row($0) != nil })
        let original = row(active)
        var selected: TabID?
        sidebar.onSelect = { selected = $0 }
        _ = original?.accessibilityPerformPress()
        check("sidebar activation uses a stable session identity", selected == active)
        var renamedRows = rows(grouped)
        renamedRows[0].primary = "Changed title"
        sidebar.reload(arrangement: grouped, rows: renamedRows, selected: active)
        check("title-only changes reuse the native row", row(active) === original)
        var collapsed = grouped
        collapsed.groups[group]?.collapsed = true
        sidebar.reload(arrangement: collapsed, rows: rows(collapsed), selected: active)
        check("collapsed groups hide members without removing their sessions", row(active) == nil && collapsed.ids == grouped.ids)
        let header = views(sidebar).first { $0.accessibilityIdentifier() == "SessionGroup-\(group.uuidString)" }
        check("a collapsed active group remains visibly selected", header?.isAccessibilitySelected() == true)
        var toggled: UUID?
        sidebar.onToggleGroup = { toggled = $0 }
        _ = header?.accessibilityPerformPress()
        check("a group header exposes native expand-collapse activation", toggled == group)
        sidebar.reload(arrangement: grouped, rows: rows(grouped), selected: active)
        let reordered = SessionArrangement.transfer(.tab(grouped.ids.last!), from: grouped, to: grouped, at: .beforeGroup(group), sameWindow: true)!.destination
        sidebar.reload(arrangement: reordered, rows: rows(reordered), selected: active)
        selected = nil
        _ = row(active)?.accessibilityPerformPress()
        check("reordered native rows do not retain stale index callbacks", selected == active)
    }
}
