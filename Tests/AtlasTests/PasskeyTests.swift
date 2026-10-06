import XCTest
@testable import Atlas

/// Device-free coverage of the passkey feature's pure parts: the base64url
/// codec, the `begin`-response decoding, and the credential → `finish` body
/// mapping. The `ASAuthorizationController` ceremony needs a real authenticator
/// and is not exercised here.
final class PasskeyTests: XCTestCase {
    // MARK: base64url

    func testBase64URLRoundTrips() {
        // Bytes that force both `+`/`-` and `/`/`_` substitutions and padding.
        let bytes = Data([0xFB, 0xFF, 0xBE, 0x00, 0x10, 0x83])
        let encoded = bytes.base64URLEncodedString()
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(Data(base64URLEncoded: encoded), bytes)
    }

    func testBase64URLDecodesUnpaddedAndPadded() {
        // "hello" → aGVsbG8 (unpadded) / aGVsbG8= (padded) — both must decode.
        XCTAssertEqual(Data(base64URLEncoded: "aGVsbG8"), Data("hello".utf8))
        XCTAssertEqual(Data(base64URLEncoded: "aGVsbG8="), Data("hello".utf8))
    }

    // MARK: begin-response decoding

    func testDecodeRegistrationOptions() throws {
        let json = """
        {
          "challenge": "Y2hhbF9SRUc",
          "rp": { "id": "fapi.acme.atlasauth.net", "name": "Atlas" },
          "user": { "id": "dXNyXzEyMw", "name": "ada", "displayName": "Ada Lovelace" },
          "pubKeyCredParams": [{ "type": "public-key", "alg": -7 }],
          "excludeCredentials": [],
          "timeout": 60000,
          "attestation": "none"
        }
        """
        let options = try JSONDecoder().decode(PasskeyRegistrationOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.challenge, "Y2hhbF9SRUc")
        XCTAssertEqual(options.rp.id, "fapi.acme.atlasauth.net")
        XCTAssertEqual(options.user.id, "dXNyXzEyMw")
        XCTAssertEqual(options.user.name, "ada")
        XCTAssertEqual(options.user.displayName, "Ada Lovelace")
    }

    func testDecodeAuthenticationOptions() throws {
        let json = """
        {
          "handle": "wa_abc123",
          "challenge": "Y2hhbF9BVVRI",
          "rpId": "fapi.acme.atlasauth.net",
          "allowCredentials": [],
          "userVerification": "required",
          "timeout": 60000
        }
        """
        let options = try JSONDecoder().decode(PasskeyAuthenticationOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.handle, "wa_abc123")
        XCTAssertEqual(options.challenge, "Y2hhbF9BVVRI")
        XCTAssertEqual(options.rpId, "fapi.acme.atlasauth.net")
    }

    func testDecodeSignInResponse() throws {
        let json = """
        {
          "object": "sign_in_attempt",
          "status": "complete",
          "created_session_id": "sess_789",
          "jwt": "header.payload.sig",
          "expires_in": 60,
          "cloned_authenticator_warning": false
        }
        """
        let response = try JSONDecoder().decode(PasskeySignInResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.jwt, "header.payload.sig")
        XCTAssertEqual(response.createdSessionId, "sess_789")
        XCTAssertEqual(response.expiresIn, 60)
        XCTAssertEqual(response.clonedAuthenticatorWarning, false)
    }

    // MARK: finish-body mapping

    func testRegistrationFinishBodyWithName() {
        let result = PasskeyRegistrationResult(
            attestationObject: Data("att".utf8),
            clientDataJSON: Data("cdj".utf8)
        )
        let body = registrationFinishBody(challenge: "chal_R", result: result, name: "My iPhone")
        XCTAssertEqual(body, [
            "challenge": "chal_R",
            "attestation_object": Data("att".utf8).base64URLEncodedString(),
            "client_data_json": Data("cdj".utf8).base64URLEncodedString(),
            "name": "My iPhone",
        ])
    }

    func testRegistrationFinishBodyOmitsEmptyName() {
        let result = PasskeyRegistrationResult(
            attestationObject: Data("att".utf8),
            clientDataJSON: Data("cdj".utf8)
        )
        XCTAssertNil(registrationFinishBody(challenge: "c", result: result, name: nil)["name"])
        XCTAssertNil(registrationFinishBody(challenge: "c", result: result, name: "")["name"])
    }

    func testAssertionFinishBody() {
        let result = PasskeyAssertionResult(
            credentialID: Data("cred".utf8),
            authenticatorData: Data("ad".utf8),
            clientDataJSON: Data("cdj".utf8),
            signature: Data("sig".utf8)
        )
        let body = assertionFinishBody(handle: "wa_1", challenge: "chal_A", result: result)
        XCTAssertEqual(body, [
            "handle": "wa_1",
            "challenge": "chal_A",
            "credential_id": Data("cred".utf8).base64URLEncodedString(),
            "authenticator_data": Data("ad".utf8).base64URLEncodedString(),
            "client_data_json": Data("cdj".utf8).base64URLEncodedString(),
            "signature": Data("sig".utf8).base64URLEncodedString(),
        ])
    }
}
