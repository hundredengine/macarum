/// Which history rows are selected, the way Finder lists work: a plain click picks one row,
/// ⌘-click toggles a row, ⇧-click and ⇧↑/⇧↓ select the range from the anchor to the focus.
/// The focus is the row the preview and the single-item actions follow.
public struct ListSelection: Equatable, Sendable {
    public private(set) var ids: Set<Int64> = []
    public private(set) var focus: Int64?
    /// Where a ⇧ range starts: the last row picked with a plain click or ⌘-click.
    public private(set) var anchor: Int64?

    public init() {}

    public var isMultiple: Bool { ids.count > 1 }

    /// A plain click or arrow move: only this row.
    public mutating func select(_ id: Int64?) {
        ids = id.map { [$0] } ?? []
        focus = id
        anchor = id
    }

    /// ⌘-click. The last selected row cannot be toggled off, so something is always shown.
    public mutating func toggle(_ id: Int64) {
        if ids.contains(id) {
            guard ids.count > 1 else { return }
            ids.remove(id)
            if focus == id { focus = ids.min() }
            if anchor == id { anchor = focus }
        } else {
            ids.insert(id)
            focus = id
            anchor = id
        }
    }

    /// ⇧-click: every row between the anchor and `id`.
    public mutating func extend(to id: Int64, in order: [Int64]) {
        guard let end = order.firstIndex(of: id) else { return }
        guard let anchor, let start = order.firstIndex(of: anchor) else {
            select(id)
            return
        }
        ids = Set(order[min(start, end)...max(start, end)])
        focus = id
    }

    /// ⇧↑ / ⇧↓: moves the focus end of the range, growing or shrinking it.
    public mutating func extend(by offset: Int, in order: [Int64]) {
        guard !order.isEmpty else { return }
        let current = focus.flatMap { order.firstIndex(of: $0) } ?? (offset > 0 ? -1 : order.count)
        let next = max(0, min(order.count - 1, current + offset))
        if anchor == nil || !order.contains(anchor!) { anchor = focus ?? order[next] }
        extend(to: order[next], in: order)
    }

    /// The selected rows in list order.
    public func ordered(in order: [Int64]) -> [Int64] {
        order.filter { ids.contains($0) }
    }

    /// After a reload: forget rows that are no longer listed.
    public mutating func keep(only present: some Sequence<Int64>) {
        let present = Set(present)
        ids.formIntersection(present)
        if let f = focus, !present.contains(f) { focus = ids.min() }
        if let a = anchor, !present.contains(a) { anchor = focus }
        if ids.isEmpty {
            focus = nil
            anchor = nil
        }
    }

    /// The row to select once the selected rows are deleted: the first one below the last
    /// selected row, else the nearest one above the first selected row.
    public func successor(in order: [Int64]) -> Int64? {
        let positions = order.indices.filter { ids.contains(order[$0]) }
        guard let first = positions.first, let last = positions.last else { return nil }
        if order.indices.contains(last + 1) { return order[last + 1] }
        return first > 0 ? order[first - 1] : nil
    }
}
