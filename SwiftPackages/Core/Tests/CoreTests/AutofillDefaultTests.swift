import Foundation
import Testing
@testable import UPasswordsCore

@Suite("Autofill defaults")
struct AutofillDefaultTests {
    @Test("New login and custom cards allow autofill")
    func newCards() throws {
        #expect(Card().autofillEnabled)
        for id in [102, 103, 104, 114] {
            let spec = try #require(Templates.spec(id: id))
            #expect(Templates.makeCard(from: spec).autofillEnabled)
        }
    }

    @Test("An explicitly disabled card stays disabled when decoded")
    func explicitOptOut() throws {
        let xml = """
        <database><card id="00000000-0000-0000-0000-000000000001" autofill="off" /></database>
        """
        let database = try PasswordDatabase.parse(Data(xml.utf8))
        #expect(database.cards.first?.autofillEnabled == false)
        let restored = try PasswordDatabase.parse(database.xmlData())
        #expect(restored.cards.first?.autofillEnabled == false)
    }
}
