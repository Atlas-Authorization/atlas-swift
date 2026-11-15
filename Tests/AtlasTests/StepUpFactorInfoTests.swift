import XCTest
@testable import Atlas

final class StepUpFactorInfoTests: XCTestCase {
    func testKnownFactors() {
        XCTAssertEqual(stepUpFactors.count, 9)
        XCTAssertEqual(stepUpFactorInfo("password").inputKind, .password)
        XCTAssertEqual(stepUpFactorInfo("passkey"), StepUpFactorInfo(factor: "passkey", label: "Passkey", needsInput: false, inputKind: .webauthn))
        XCTAssertEqual(stepUpFactorInfo("duo").inputKind, .redirect)
        XCTAssertEqual(stepUpFactorInfo("push").inputKind, .push)
    }

    func testUnknownFactorFallsBack() {
        XCTAssertEqual(stepUpFactorInfo("smart_card"), StepUpFactorInfo(factor: "smart_card", label: "Smart card", needsInput: true, inputKind: .otp))
    }
}
