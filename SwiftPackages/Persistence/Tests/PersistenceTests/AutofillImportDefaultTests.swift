import Foundation
import Testing
import UPasswordsCore
@testable import UPasswordsPersistence

@Suite("Imported autofill defaults")
struct AutofillImportDefaultTests {
    @Test("Login imports allow autofill", arguments: ["chrome-chrome", "bitwarden-csv", "bitwarden-json"])
    func importedLogins(formatID: String) throws {
        let formats: [String: String] = [
            "chrome-chrome": "name,url,username,password\nSite,https://example.com,user,password\n",
            "bitwarden-csv": "name,login_uri,login_username,login_password\nSite,https://example.com,user,password\n",
            "bitwarden-json": """
            {"items":[{"name":"Site","login":{"username":"user","password":"password"}}]}
            """,
        ]
        let format = try #require(ImportFormatFactory.format(id: formatID))
        let text = try #require(formats[formatID])
        var database = PasswordDatabase()
        _ = try format.parse(text, into: &database, now: Date(timeIntervalSince1970: 0))
        #expect(database.cards.count == 1)
        #expect(database.cards.first?.autofillEnabled == true)
    }
}
