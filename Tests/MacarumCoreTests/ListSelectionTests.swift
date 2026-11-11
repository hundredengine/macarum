import Testing
@testable import MacarumCore

@Suite struct ListSelectionTests {
    private let order: [Int64] = [10, 20, 30, 40, 50]

    @Test func plainSelectReplacesEverything() {
        var s = ListSelection()
        s.select(20)
        s.select(40)
        #expect(s.ids == [40])
        #expect(s.focus == 40)
        #expect(!s.isMultiple)
    }

    @Test func commandClickTogglesItems() {
        var s = ListSelection()
        s.select(20)
        s.toggle(40)
        #expect(s.ids == [20, 40])
        #expect(s.focus == 40)
        s.toggle(20)
        #expect(s.ids == [40])
        #expect(s.focus == 40)
    }

    @Test func togglingTheLastItemOffKeepsIt() {
        var s = ListSelection()
        s.select(20)
        s.toggle(20)
        #expect(s.ids == [20])
    }

    @Test func togglingTheFocusedItemOffMovesFocusToAnotherSelected() {
        var s = ListSelection()
        s.select(20)
        s.toggle(40)
        s.toggle(40)
        #expect(s.focus == 20)
    }

    @Test func shiftClickSelectsTheRangeFromTheAnchor() {
        var s = ListSelection()
        s.select(20)
        s.extend(to: 40, in: order)
        #expect(s.ids == [20, 30, 40])
        #expect(s.focus == 40)
        // A second shift-click re-draws the range from the same anchor, upwards too.
        s.extend(to: 10, in: order)
        #expect(s.ids == [10, 20])
    }

    @Test func shiftClickAfterCommandClickAnchorsOnTheToggledItem() {
        var s = ListSelection()
        s.select(10)
        s.toggle(30)
        s.extend(to: 50, in: order)
        #expect(s.ids == [30, 40, 50])
    }

    @Test func shiftArrowGrowsAndShrinks() {
        var s = ListSelection()
        s.select(30)
        s.extend(by: 1, in: order)
        s.extend(by: 1, in: order)
        #expect(s.ids == [30, 40, 50])
        #expect(s.focus == 50)
        s.extend(by: 1, in: order) // already at the end
        #expect(s.focus == 50)
        s.extend(by: -1, in: order)
        #expect(s.ids == [30, 40])
        s.extend(by: -2, in: order)
        #expect(s.ids == [20, 30])
        #expect(s.focus == 20)
    }

    @Test func orderedFollowsTheList() {
        var s = ListSelection()
        s.select(50)
        s.toggle(10)
        s.toggle(30)
        #expect(s.ordered(in: order) == [10, 30, 50])
    }

    @Test func reloadDropsMissingItems() {
        var s = ListSelection()
        s.select(20)
        s.extend(to: 40, in: order)
        s.keep(only: [10, 30, 50])
        #expect(s.ids == [30])
        #expect(s.focus == 30)
        s.keep(only: [10])
        #expect(s.ids.isEmpty)
        #expect(s.focus == nil)
    }

    @Test func afterDeletingTheNextRowBelowIsChosen() {
        var s = ListSelection()
        s.select(20)
        s.extend(to: 30, in: order)
        #expect(s.successor(in: order) == 40)
        s.select(50)
        s.toggle(40)
        #expect(s.successor(in: order) == 30)
        s.select(10)
        #expect(ListSelection().successor(in: order) == nil)
        var all = ListSelection()
        all.select(10)
        all.extend(to: 50, in: order)
        #expect(all.successor(in: order) == nil)
    }

    @Test func gapsInsideASelectionAreNotPickedAsSuccessor() {
        var s = ListSelection()
        s.select(10)
        s.toggle(30)
        // 20 sits between deleted rows; the row below the last deleted one wins.
        #expect(s.successor(in: order) == 40)
    }
}
