@testable import DesignSystem

import Testing

@MainActor
@Suite
struct RowInteractionTests {
    @Test
    func test_swipeBinding_openingARow_closesTheOpenOne() {
        let interaction = RowInteraction<Int>()

        interaction.swipeBinding(for: 1).wrappedValue = true
        #expect(interaction.swipedID == 1)

        interaction.swipeBinding(for: 2).wrappedValue = true
        #expect(interaction.swipedID == 2)
        #expect(interaction.swipeBinding(for: 1).wrappedValue == false)
        #expect(interaction.swipeBinding(for: 2).wrappedValue == true)
    }

    @Test
    func test_swipeBinding_closingAnotherRow_keepsTheOpenOne() {
        let interaction = RowInteraction<Int>()
        interaction.swipedID = 2

        // A row that closes as another opens reports it after the other took over.
        interaction.swipeBinding(for: 1).wrappedValue = false

        #expect(interaction.swipedID == 2)
    }

    @Test
    func test_swipeBinding_closingTheOpenRow_leavesNoneOpen() {
        let interaction = RowInteraction<Int>()
        interaction.swipedID = 1

        interaction.swipeBinding(for: 1).wrappedValue = false

        #expect(interaction.swipedID == nil)
    }

    @Test(arguments: [Int?.some(1), nil])
    func test_closeSwipe_openOrNone_leavesNoneOpen(open: Int?) {
        let interaction = RowInteraction<Int>()
        interaction.swipedID = open

        interaction.closeSwipe()

        #expect(interaction.swipedID == nil)
    }
}
