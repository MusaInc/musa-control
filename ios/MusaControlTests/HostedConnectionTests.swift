import XCTest
@testable import MusaControl

final class HostedConnectionTests: XCTestCase {
    func testRequiresHTTPSAndDoesNotAcceptEmbeddedCredentials() throws {
        XCTAssertEqual(try HostedConnection.url(" https://musastudios.co.uk/control-hafsa/ ").absoluteString, "https://musastudios.co.uk/control-hafsa")
        for value in ["http://example.com", "https://user:pass@example.com", "https://example.com?code=SECRET", "https://example.com#token", "not a URL"] {
            XCTAssertThrowsError(try HostedConnection.url(value))
        }
    }
    func testHostedTokenCannotOverwritePersonalToken() {
        let hosted = Machine(id: "hafsa", name: "Hafsa", kind: .direct, addedAt: 0)
        XCTAssertNotEqual(hosted.tokenKey, "deviceToken")
        XCTAssertFalse(hosted.isPersonal)
        XCTAssertTrue(hosted.usesSocketTerminal)
    }
}
