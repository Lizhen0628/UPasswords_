import XCTest
@testable import UPasswordsCore

final class SiteMatchingTests: XCTestCase {
    func testBaseDomainMatchesSubdomainsAtRegistrableDomainBoundary() {
        let site = Field(name: "Website", type: .website, value: "https://accounts.example.co.uk/login")

        XCTAssertTrue(SiteMatching.matches("https://example.co.uk/other", site: site))
        XCTAssertTrue(SiteMatching.matches("https://login.example.co.uk/", site: site))
        XCTAssertFalse(SiteMatching.matches("https://attacker.co.uk/", site: site))
        XCTAssertFalse(SiteMatching.matches("https://example.com/", site: site))
    }

    func testHostRequiresExactHostnameAndPortButAllowsSchemeChange() {
        let site = Field(name: "Website", type: .website, value: "https://login.example.com:8443/path",
                         siteMatch: .host)

        XCTAssertTrue(SiteMatching.matches("http://login.example.com:8443/", site: site))
        XCTAssertFalse(SiteMatching.matches("https://login.example.com/", site: site))
        XCTAssertFalse(SiteMatching.matches("https://www.login.example.com:8443/", site: site))
    }

    func testStartsWithAndExactURLNormalizeWebURL() {
        let prefix = Field(name: "Website", type: .website, value: "example.com/login/",
                           siteMatch: .startsWith)
        XCTAssertTrue(SiteMatching.matches("https://example.com/login/step?next=1", site: prefix))
        XCTAssertFalse(SiteMatching.matches("https://example.com/logins/", site: prefix))

        let exact = Field(name: "Website", type: .website, value: "https://example.com/login",
                          siteMatch: .exactURL)
        XCTAssertTrue(SiteMatching.matches("https://EXAMPLE.com/login", site: exact))
        XCTAssertFalse(SiteMatching.matches("https://example.com/other", site: exact))
    }

    func testRegexNeverWildcardAndNonWebPages() {
        let regex = Field(name: "Website", type: .website,
                          value: #"^https://(?:www\.)?example\.com/(?:login|signin)"#,
                          siteMatch: .regex)
        XCTAssertTrue(SiteMatching.matches("https://www.example.com/login?next=1", site: regex))
        XCTAssertFalse(SiteMatching.matches("https://example.com/register", site: regex))

        let never = Field(name: "Website", type: .website, value: "https://example.com", siteMatch: .never)
        XCTAssertFalse(SiteMatching.matches("https://example.com/", site: never))
        XCTAssertFalse(SiteMatching.matches("file://example.com/", site: regex))

        let wildcard = Field(name: "Website", type: .website,
                             value: "https://*.example.com/*", siteMatch: .wildcard)
        XCTAssertTrue(SiteMatching.matches("https://login.example.com/sign-in", site: wildcard))
        XCTAssertFalse(SiteMatching.matches("https://example.com/sign-in", site: wildcard))
    }

    func testAnyWebsiteFieldCanMatch() {
        let fields = [
            Field(name: "Disabled", type: .website, value: "https://example.com", siteMatch: .never),
            Field(name: "Work", type: .website, value: "https://login.example.org", siteMatch: .host),
            Field(name: "Username", type: .login, value: "login.example.org"),
        ]

        XCTAssertTrue(SiteMatching.matches("https://login.example.org/account", sites: fields))
        XCTAssertFalse(SiteMatching.matches("https://example.com/", sites: fields))
    }

    func testRegexRejectsMultipleUnboundedRepeats() {
        let unsafeRegex = Field(
            name: "Website",
            type: .website,
            value: #"^https://.*example\.com/.*$"#,
            siteMatch: .regex)

        XCTAssertFalse(SiteMatching.matches("https://login.example.com/", site: unsafeRegex))
    }
}
