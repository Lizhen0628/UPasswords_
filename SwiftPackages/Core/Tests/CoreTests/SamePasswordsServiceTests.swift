import XCTest
@testable import UPasswordsCore

final class SamePasswordsServiceTests: XCTestCase {
    func testDetectsPasswordSharedByDifferentCards() {
        let first = card(passwords: ["shared"])
        let second = card(passwords: ["shared"])

        XCTAssertEqual(
            SamePasswordsService.cardIDsWithReusedPasswords(cards: [first, second]),
            [first.id, second.id])
    }

    func testDetectsRepeatedPasswordFieldsOnSameCard() {
        let entry = card(passwords: ["shared", "shared"])

        XCTAssertEqual(SamePasswordsService.cardIDsWithReusedPasswords(cards: [entry]), [entry.id])
    }

    func testDoesNotMatchDifferentOrEmptyPasswords() {
        let first = card(passwords: ["first", ""])
        let second = card(passwords: ["second", ""])

        XCTAssertTrue(SamePasswordsService.cardIDsWithReusedPasswords(cards: [first, second]).isEmpty)
    }

    func testIgnoresTrashedAndTemplateCards() {
        let first = card(passwords: ["shared"])
        var trashed = card(passwords: ["shared"])
        trashed.trashed = true
        var template = card(passwords: ["shared"])
        template.template = true

        XCTAssertEqual(
            SamePasswordsService.cardIDsWithReusedPasswords(cards: [first, trashed, template]),
            [])
    }

    private func card(passwords: [String]) -> Card {
        var card = Card()
        card.fields = passwords.map { Field(name: "password", type: .password, value: $0) }
        return card
    }
}
