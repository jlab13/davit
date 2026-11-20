import Foundation

/// Pure selection bookkeeping for the five native resource lists.
///
/// Kept free of SwiftUI so the selftest can exercise it without a daemon: the
/// view layer supplies the ids that are currently on screen and the predicate
/// for a group action.
enum ListSelection {
    /// Drops ids that are no longer visible (deleted, filtered out, or inside a
    /// collapsed group). A bulk action must never reach a row the user can't see.
    static func pruned<ID: Hashable>(_ selection: Set<ID>, to visible: Set<ID>) -> Set<ID> {
        selection.intersection(visible)
    }

    /// Double-click / Return opens details only when the target is unambiguous.
    static func primaryTarget<ID: Hashable>(_ selection: Set<ID>) -> ID? {
        selection.count == 1 ? selection.first : nil
    }

    /// The selected rows a bulk action applies to, in list order.
    static func targets<Item, ID: Hashable>(
        _ items: [Item],
        selected: Set<ID>,
        id: (Item) -> ID,
        applicable: (Item) -> Bool = { _ in true }
    ) -> [Item] {
        guard !selected.isEmpty else { return [] }
        return items.filter { selected.contains(id($0)) && applicable($0) }
    }
}
