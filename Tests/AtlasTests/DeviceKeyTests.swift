import XCTest
@testable import Atlas

final class DeviceKeyTests: XCTestCase {
    func testMessageMatchesServerFormat() {
        XCTAssertEqual(
            AtlasDeviceKeyMessage.make(purpose: "sign_in", instanceId: "ins_1", keyId: "dvk_1", nonce: "n"),
            "atlas-device-key:v1:sign_in:ins_1:dvk_1:n"
        )
    }

    func testJWKFromX963() {
        let point = Data([0x04]) + Data(repeating: 1, count: 32) + Data(repeating: 2, count: 32)
        let jwk = AtlasDeviceKeyMessage.jwk(fromX963: point)
        XCTAssertEqual(jwk?.x, Data(repeating: 1, count: 32).base64URLEncodedString())
        XCTAssertEqual(jwk?.y, Data(repeating: 2, count: 32).base64URLEncodedString())
        XCTAssertNil(AtlasDeviceKeyMessage.jwk(fromX963: Data([0x03]) + Data(repeating: 1, count: 64)))
        XCTAssertNil(AtlasDeviceKeyMessage.jwk(fromX963: Data([0x04, 1])))
    }

    func testDERToP1363PadsAndTrims() {
        // r = 0x00 0x80 (leading zero for sign), s = 0x01
        let der = Data([0x30, 0x07, 0x02, 0x02, 0x00, 0x80, 0x02, 0x01, 0x01])
        let raw = AtlasDeviceKeyMessage.p1363(fromDER: der)
        XCTAssertEqual(raw?.count, 64)
        XCTAssertEqual(raw?[31], 0x80)
        XCTAssertEqual(raw?[63], 0x01)
        XCTAssertNil(AtlasDeviceKeyMessage.p1363(fromDER: Data([0x31, 0x00])))
        XCTAssertNil(AtlasDeviceKeyMessage.p1363(fromDER: Data([0x30, 0x03, 0x02, 0x01])))
    }
}
