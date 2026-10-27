import XCTest
@testable import Atlas

final class AttestationTests: XCTestCase {
    func testGuardedPaths() {
        XCTAssertTrue(AtlasAttestation.isGuarded(path: "/v1/client/sign_ups", method: "POST"))
        XCTAssertTrue(AtlasAttestation.isGuarded(path: "/v1/client/sign_ins?x=1", method: "POST"))
        XCTAssertTrue(AtlasAttestation.isGuarded(path: "/v1/client/me/phone_numbers/pn_1/prepare_verification", method: "POST"))
        XCTAssertFalse(AtlasAttestation.isGuarded(path: "/v1/client/sign_ins", method: "GET"))
        XCTAssertFalse(AtlasAttestation.isGuarded(path: "/v1/client/me", method: "POST"))
    }

    func testHeaderIsBase64URLJSON() throws {
        let header = AtlasAttestation.header(nonce: "n1", proof: .appAttest(assertion: "a", receipt: "r"))
        XCTAssertFalse(header.contains("+") || header.contains("/") || header.contains("="))
        var b64 = header.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let object = try JSONSerialization.jsonObject(with: Data(base64Encoded: b64)!) as? [String: String]
        XCTAssertEqual(object, ["n": "n1", "p": "ios", "a": "a", "r": "r"])
    }
}
