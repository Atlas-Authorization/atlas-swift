import XCTest
@testable import Atlas

final class DesignTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    private let fullResolved = #"""
    {"version":1,"preset":"midnight","colorScheme":"dark",
     "palette":{"primary":"#0F766E","primaryInk":"#ffffff","accent":"#f59e0b","background":"#f8fafc","surface":"#ffffff","text":"#0f172a","muted":"#64748b","border":"#e2e8f0","danger":"#b91c1c","success":"#15803d","inputBackground":"#ffffff","inputText":"#0f172a"},
     "paletteDark":{"primary":"#2dd4bf","primaryInk":"#042f2e","accent":"#fbbf24","background":"#020617","surface":"#0f172a","text":"#f8fafc","muted":"#94a3b8","border":"#1e293b","danger":"#f87171","success":"#4ade80","inputBackground":"#020617","inputText":"#f8fafc"},
     "typography":{"font":"source-serif","headingFont":"playfair-display","baseSize":17,"headingWeight":700,"bodyWeight":300,"letterCase":"uppercase","scale":"golden"},
     "shape":{"radius":20,"controlRadius":999,"borderWidth":2},
     "elevation":{"cardShadow":"xl"},"spacing":{"density":"spacious"},
     "card":{"style":"glass","blur":24,"width":"wide"},
     "layout":{"position":"split","splitImageSide":"right","logoPlacement":"card","logoSize":"lg"},
     "buttons":{"style":"gradient","socialLayout":"icons"},"inputs":{"style":"underline"},
     "background":{},"backgroundDark":{},"logo":{}}
    """#

    // MARK: decoding

    func testDecodesAFullResolvedDesign() {
        let d = AtlasDesign(resolved: json(fullResolved))
        XCTAssertEqual(d.colorScheme, .dark)
        XCTAssertEqual(d.palette[.primary], "#0f766e") // normalised to lower case
        XCTAssertEqual(d.paletteDark[.primaryInk], "#042f2e")
        XCTAssertEqual(d.typography.font, "source-serif")
        XCTAssertEqual(d.typography.headingFont, "playfair-display")
        XCTAssertEqual(d.typography.baseSize, 17)
        XCTAssertEqual(d.typography.headingWeight, 700)
        XCTAssertEqual(d.typography.bodyWeight, 300)
        XCTAssertEqual(d.typography.letterCase, .uppercase)
        XCTAssertEqual(d.typography.headingSize, 17 * 1.618, accuracy: 0.001)
        XCTAssertEqual(d.shape.radius, 20)
        XCTAssertTrue(d.shape.isPill)
        XCTAssertEqual(d.shape.borderWidth, 2)
        XCTAssertEqual(d.cardShadow, .xl)
        XCTAssertEqual(d.density, .spacious)
        XCTAssertEqual(d.spacing.control, 46)
        XCTAssertEqual(d.card.style, .glass)
        XCTAssertEqual(d.cardMaxWidth, 460)
        XCTAssertEqual(d.logoHeight, 64)
        XCTAssertEqual(d.buttonStyle, .gradient)
        XCTAssertEqual(d.socialLayout, .icons)
        XCTAssertEqual(d.inputStyle, .underline)
    }

    func testPartialDesignFillsDefaultsAndIgnoresUnknownKeys() {
        let d = AtlasDesign(resolved: json(#"""
        {"palette":{"primary":"#123456","bogus":"#ffffff"},
         "typography":{"font":"roboto","baseSize":99,"letterCase":"shouty"},
         "shape":{"radius":"12px"},"buttons":{"style":"neon"},"futureSection":{"x":1}}
        """#))
        XCTAssertEqual(d.palette[.primary], "#123456")
        XCTAssertEqual(d.palette[.surface], AtlasDesign.defaults.palette[.surface])
        XCTAssertEqual(d.paletteDark, AtlasDesign.defaults.paletteDark)
        XCTAssertEqual(d.typography.font, "roboto")
        XCTAssertEqual(d.typography.headingFont, "roboto", "heading follows the body font when unset")
        XCTAssertEqual(d.typography.baseSize, 15, "out of range → default")
        XCTAssertEqual(d.typography.letterCase, .none, "unknown enum → default")
        XCTAssertEqual(d.shape.radius, 12, "wrong type → default")
        XCTAssertEqual(d.buttonStyle, .solid)
        XCTAssertEqual(d.colorScheme, .auto)
    }

    func testEmptyResolvedIsTheDefaults() {
        XCTAssertEqual(AtlasDesign(resolved: [:]), AtlasDesign.defaults)
    }

    func testNullDesignDecodesToNil() {
        let info = AtlasAppearanceInfo(json: json(#"{"object":"appearance","design":null,"providers":["google","github"]}"#))
        XCTAssertNil(info.design)
        XCTAssertEqual(info.providers, ["google", "github"])
        XCTAssertNil(AtlasAppearanceInfo(json: json(#"{"object":"appearance"}"#)).design)
    }

    func testBundleCarriesLogoUrls() {
        let d = AtlasDesign(bundle: json(#"""
        {"scope":".atlas-root","css":"","resolved":{"colorScheme":"auto"},
         "logo_url":"https://cdn.example.com/l.png","logo_dark_url":"https://cdn.example.com/d.png"}
        """#))
        XCTAssertEqual(d?.logo(systemIsDark: false)?.absoluteString, "https://cdn.example.com/l.png")
        XCTAssertEqual(d?.logo(systemIsDark: true)?.absoluteString, "https://cdn.example.com/d.png")
    }

    // MARK: colours + dark mode

    func testAutoSchemeFollowsTheSystem() {
        let d = AtlasDesign(resolved: json(##"{"palette":{"primary":"#111111"},"paletteDark":{"primary":"#eeeeee"}}"##))
        XCTAssertEqual(d.activePalette(systemIsDark: false)[.primary], "#111111")
        XCTAssertEqual(d.activePalette(systemIsDark: true)[.primary], "#eeeeee")
    }

    func testForcedSchemeIgnoresTheSystem() {
        var d = AtlasDesign.defaults
        d.colorScheme = .dark
        XCTAssertEqual(d.activePalette(systemIsDark: false), d.paletteDark)
        d.colorScheme = .light
        XCTAssertEqual(d.activePalette(systemIsDark: true), d.palette)
    }

    func testHexParsing() {
        let rgb = AtlasHex.rgb("#ff8000")
        XCTAssertEqual(rgb?.0 ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(rgb?.1 ?? -1, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(rgb?.2 ?? -1, 0, accuracy: 0.001)
        XCTAssertNil(AtlasHex.rgb("red"))
        XCTAssertNil(AtlasHex.rgb("#fff"))
        XCTAssertEqual(AtlasHex.readableOn("#ffffff"), "#111827")
        XCTAssertEqual(AtlasHex.readableOn("#18181b"), "#ffffff")
    }

    func testShadowAndBorderFollowCardStyle() {
        var d = AtlasDesign.defaults
        XCTAssertEqual(d.shadow?.y, 12)
        d.card.style = .outline
        XCTAssertNil(d.shadow)
        XCTAssertEqual(d.cardBorderWidth, 1)
        d.card.style = .none
        XCTAssertEqual(d.cardBorderWidth, 0)
    }

    func testFontCatalog() {
        XCTAssertEqual(AtlasFontCatalog.family(for: "source-serif"), "Source Serif 4")
        XCTAssertNil(AtlasFontCatalog.family(for: "system"))
        XCTAssertEqual(AtlasFontCatalog.category(for: "jetbrains-mono"), .monospace)
        XCTAssertEqual(AtlasFontCatalog.category(for: "unknown"), .sansSerif)
    }

    // MARK: precedence

    func testNoDesignAndNoOverrideMeansTheUnchangedLook() {
        XCTAssertNil(AtlasDesign.resolve(dashboard: nil, appearance: nil))
        XCTAssertNil(AtlasDesign.resolve(dashboard: nil, appearance: AtlasAppearance()))
    }

    func testDashboardDesignAppliesWhenNoOverride() {
        let dash = AtlasDesign(resolved: json(fullResolved))
        XCTAssertEqual(AtlasDesign.resolve(dashboard: dash, appearance: nil), dash)
        XCTAssertEqual(AtlasDesign.resolve(dashboard: dash, appearance: AtlasAppearance()), dash)
    }

    func testCodeOverrideWinsOverTheDashboard() {
        let dash = AtlasDesign(resolved: json(fullResolved))
        var look = AtlasAppearance()
        look.palette[.primary] = "#FF0000"
        look.controlRadius = 4
        look.buttonStyle = .outline
        look.colorScheme = .light
        let d = AtlasDesign.resolve(dashboard: dash, appearance: look)!
        XCTAssertEqual(d.palette[.primary], "#ff0000")
        XCTAssertEqual(d.palette[.primaryInk], "#111827", "ink recomputed for the new primary")
        XCTAssertEqual(d.paletteDark[.primary], "#ff0000", "brand colour carries into dark")
        XCTAssertEqual(d.shape.controlRadius, 4)
        XCTAssertEqual(d.buttonStyle, .outline)
        XCTAssertEqual(d.colorScheme, .light)
        // Untouched tokens keep the dashboard's values.
        XCTAssertEqual(d.typography.font, "source-serif")
        XCTAssertEqual(d.inputStyle, .underline)
    }

    func testOverrideAloneLayersOverTheDefaults() {
        var look = AtlasAppearance()
        look.density = .compact
        let d = AtlasDesign.resolve(dashboard: nil, appearance: look)!
        XCTAssertEqual(d.density, .compact)
        XCTAssertEqual(d.palette, AtlasDesign.defaults.palette)
    }

    func testOptingOutOfTheDashboardDesign() {
        let dash = AtlasDesign(resolved: json(fullResolved))
        var look = AtlasAppearance()
        look.applyDashboardDesign = false
        XCTAssertNil(AtlasDesign.resolve(dashboard: dash, appearance: look))
        look.inputStyle = .filled
        XCTAssertEqual(AtlasDesign.resolve(dashboard: dash, appearance: look)?.palette, AtlasDesign.defaults.palette)
    }

    func testInvalidOverrideValuesAreIgnored() {
        var look = AtlasAppearance()
        look.palette[.primary] = "blue"
        look.baseSize = 400
        look.font = "comic-sans"
        let d = AtlasDesign.resolve(dashboard: nil, appearance: look)!
        XCTAssertEqual(d.palette[.primary], AtlasDesign.defaults.palette[.primary])
        XCTAssertEqual(d.typography.baseSize, 15)
        XCTAssertEqual(d.typography.font, "inter")
    }

    // MARK: fetching

    private func makeClient() -> AtlasClient {
        AtlasClient(publishableKey: "pk_test_123", frontendApi: "clerk.example.com",
                    tokenStore: InMemoryTokenStore(), urlSession: MockURLProtocol.makeSession())
    }

    func testFetchesAppearanceWithThePublishableKey() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"appearance","design":{"resolved":{"buttons":{"style":"soft"}},"logo_url":null},"providers":["google"]}"#)
        let info = try await makeClient().appearance(organization: "acme co")
        let request = try XCTUnwrap(MockURLProtocol.recorded.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/appearance")
        XCTAssertEqual(request.url?.query, "org=acme%20co")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-publishable-key"), "pk_test_123")
        XCTAssertEqual(info.design?.buttonStyle, .soft)
        XCTAssertNil(info.design?.logoURL)
        XCTAssertEqual(info.providers, ["google"])
    }

    func testFetchWithNullDesign() async throws {
        MockURLProtocol.enqueue(status: 200, json: #"{"object":"appearance","design":null,"providers":[]}"#)
        let info = try await makeClient().appearance()
        XCTAssertNil(info.design)
        XCTAssertEqual(MockURLProtocol.recorded.first?.url?.absoluteString, "https://clerk.example.com/v1/appearance")
    }

    // MARK: EMAIL_DELIVERY_NOT_CONFIGURED

    private let undeliverable = #"{"errors":[{"code":"EMAIL_DELIVERY_NOT_CONFIGURED","message":"This app can't send email right now. Try another sign-in method or contact the app owner.","meta":{"fix":"Configure an email provider first."}}]}"#

    func testEmailDeliveryErrorIsTyped() {
        let error = parseErrorEnvelope(status: 422, data: Data(undeliverable.utf8))
        XCTAssertEqual(error.status, 422)
        XCTAssertEqual(error.knownCode, .emailDeliveryNotConfigured)
        XCTAssertTrue(error.isEmailDeliveryNotConfigured)
        XCTAssertEqual(error.message, "This app can't send email right now. Try another sign-in method or contact the app owner.")
        XCTAssertNil(parseErrorEnvelope(status: 400, data: Data(#"{"errors":[{"code":"SOMETHING_NEW","message":"x"}]}"#.utf8)).knownCode)
    }

    @available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
    @MainActor
    func testSignInShowsTheServerMessageAndStopsOfferingEmail() async throws {
        MockURLProtocol.enqueue(status: 201, json: #"{"id":"sia_1","status":"needs_first_factor"}"#)
        MockURLProtocol.enqueue(status: 422, json: undeliverable)
        let session = AtlasAuthSession(client: makeClient())
        let model = SignInModel(session: session, appearanceInfo: AtlasAppearanceInfo(design: nil))
        model.identifier = "a@example.com"
        await model.start()
        XCTAssertNil(model.errorMessage)
        await model.sendEmailCode()
        XCTAssertEqual(model.errorMessage, "This app can't send email right now. Try another sign-in method or contact the app owner.")
        XCTAssertEqual(model.errorCode, .emailDeliveryNotConfigured)
        XCTAssertTrue(model.emailUnavailable)
        XCTAssertFalse(model.busy)
    }

    @available(iOS 15.0, macOS 12.0, tvOS 17.0, watchOS 10.0, *)
    @MainActor
    func testSignInModelLoadsAppearanceOnceAndToleratesFailure() async {
        let session = AtlasAuthSession(client: makeClient())
        let model = SignInModel(session: session)
        await model.loadAppearance() // no stub queued → transport failure
        XCTAssertNil(model.appearanceInfo)
        XCTAssertNil(model.errorMessage, "a failed appearance fetch is not a user-facing error")
        await model.loadAppearance()
        XCTAssertEqual(MockURLProtocol.recorded.count, 1, "fetched once")
    }
}
