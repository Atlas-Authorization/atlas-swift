import XCTest
@testable import Atlas

final class PlatformSupportTests: XCTestCase {
    func testPlatformDeviceNameMatchesThePlatform() {
        let name = AtlasClient.platformDeviceName
        #if os(visionOS)
        XCTAssertEqual(name, "Apple Vision Pro")
        #elseif os(tvOS)
        XCTAssertEqual(name, "Apple TV")
        #elseif os(watchOS)
        XCTAssertEqual(name, "Apple Watch")
        #elseif os(macOS)
        XCTAssertEqual(name, "Mac")
        #else
        XCTAssertEqual(name, "iPhone or iPad")
        #endif
    }

    func testBrowserOpenerExistsWhereThereIsABrowser() {
        #if os(iOS) || os(visionOS) || os(macOS)
        XCTAssertNotNil(AtlasClient.defaultLogoutURLOpener)
        #else
        XCTAssertNil(AtlasClient.defaultLogoutURLOpener)
        #endif
    }

    #if canImport(AuthenticationServices) && !os(tvOS)
    @available(iOS 13.0, macOS 10.15, watchOS 6.2, *)
    func testWebAuthenticationIsAvailable() {
        _ = AtlasWebAuthentication()
    }
    #endif
}
