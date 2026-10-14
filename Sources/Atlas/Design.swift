import Foundation

// MARK: - The dashboard design, as a native app sees it
//
// `GET /v1/appearance` returns `design` — `null` until the app owner saves a
// design in the dashboard — whose `resolved` member is the fully-resolved design
// the hosted pages and web components render. This file is the platform-neutral
// half: the model, a TOLERANT decoder (unknown keys ignored, missing or invalid
// values fall back to the Atlas defaults), the code-level override
// (``AtlasAppearance``) and the precedence rules. `DesignUI.swift` maps the
// result onto SwiftUI.

/// `auto` follows the system appearance; `light` / `dark` force one.
public enum AtlasColorScheme: String, CaseIterable, Sendable { case auto, light, dark }
public enum AtlasLetterCase: String, CaseIterable, Sendable { case none, uppercase }
public enum AtlasCardShadow: String, CaseIterable, Sendable { case none, sm, md, lg, xl }
public enum AtlasDensity: String, CaseIterable, Sendable { case compact, comfortable, spacious }
public enum AtlasCardStyle: String, CaseIterable, Sendable { case solid, glass, outline, none }
public enum AtlasCardWidth: String, CaseIterable, Sendable { case narrow, normal, wide }
public enum AtlasLogoSize: String, CaseIterable, Sendable { case sm, md, lg }
public enum AtlasButtonStyleKind: String, CaseIterable, Sendable { case solid, outline, soft, gradient }
public enum AtlasSocialLayout: String, CaseIterable, Sendable { case list, grid, icons }
public enum AtlasInputStyle: String, CaseIterable, Sendable { case outline, filled, underline }

/// The twelve palette slots, in the same order as the dashboard editor.
public enum AtlasPaletteSlot: String, CaseIterable, Sendable {
    case primary, primaryInk, accent, background, surface, text, muted, border, danger, success
    case inputBackground, inputText

    /// Brand slots set in the light palette carry into dark mode (as on the web).
    static let brand: [AtlasPaletteSlot] = [.primary, .accent, .danger, .success]
}

/// One colour mode's palette: every slot is a `#rrggbb` hex string.
public struct AtlasPalette: Equatable, Sendable {
    public private(set) var colors: [AtlasPaletteSlot: String]

    public subscript(slot: AtlasPaletteSlot) -> String {
        get { colors[slot] ?? "#000000" }
        set { if AtlasHex.isValid(newValue) { colors[slot] = newValue.lowercased() } }
    }

    /// Compact form: twelve space-separated hex colours in slot order.
    init(_ spec: String) {
        let parts = spec.split(separator: " ").map(String.init)
        var out: [AtlasPaletteSlot: String] = [:]
        for (slot, value) in zip(AtlasPaletteSlot.allCases, parts) { out[slot] = value }
        colors = out
    }

    /// Tolerant: each valid `#rrggbb` slot in `json` replaces the fallback's.
    init(json: Any?, fallback: AtlasPalette) {
        self = fallback
        guard let dict = json as? [String: Any] else { return }
        for slot in AtlasPaletteSlot.allCases {
            if let v = dict[slot.rawValue] as? String, AtlasHex.isValid(v) { colors[slot] = v.lowercased() }
        }
    }
}

/// The curated font catalog (ids → family names), mirroring the dashboard's
/// list. A native app renders a family only if it BUNDLES it; otherwise the
/// system font of the same category is used, at the design's weight.
public enum AtlasFontCatalog {
    public enum Category: String, Sendable { case sansSerif, serif, monospace }

    public static let families: [String: (family: String?, category: Category)] = [
        "system": (nil, .sansSerif),
        "system-serif": (nil, .serif),
        "system-mono": (nil, .monospace),
        "inter": ("Inter", .sansSerif),
        "roboto": ("Roboto", .sansSerif),
        "open-sans": ("Open Sans", .sansSerif),
        "lato": ("Lato", .sansSerif),
        "montserrat": ("Montserrat", .sansSerif),
        "poppins": ("Poppins", .sansSerif),
        "nunito": ("Nunito", .sansSerif),
        "work-sans": ("Work Sans", .sansSerif),
        "dm-sans": ("DM Sans", .sansSerif),
        "manrope": ("Manrope", .sansSerif),
        "source-serif": ("Source Serif 4", .serif),
        "merriweather": ("Merriweather", .serif),
        "playfair-display": ("Playfair Display", .serif),
        "jetbrains-mono": ("JetBrains Mono", .monospace),
        "ibm-plex-mono": ("IBM Plex Mono", .monospace),
    ]

    /// The family name for a catalog id (nil for the system stacks / unknown ids).
    public static func family(for id: String) -> String? { families[id]?.family ?? nil }
    public static func category(for id: String) -> Category { families[id]?.category ?? .sansSerif }
}

/// Modular type scales: heading size = base × ratio.
enum AtlasTypeScale {
    static let ratios: [String: Double] = [
        "minor-second": 1.067, "major-second": 1.125, "minor-third": 1.2, "major-third": 1.25,
        "perfect-fourth": 1.333, "augmented-fourth": 1.414, "perfect-fifth": 1.5, "golden": 1.618,
        "minor-seventh": 1.778, "octave": 2,
    ]
}

enum AtlasHex {
    static func isValid(_ s: String) -> Bool {
        guard s.count == 7, s.first == "#" else { return false }
        return s.dropFirst().allSatisfy { $0.isHexDigit }
    }

    /// `(r, g, b)` in 0…1, or nil when not a `#rrggbb` string.
    static func rgb(_ s: String) -> (Double, Double, Double)? {
        guard isValid(s), let n = UInt32(s.dropFirst(), radix: 16) else { return nil }
        return (Double((n >> 16) & 0xff) / 255, Double((n >> 8) & 0xff) / 255, Double(n & 0xff) / 255)
    }

    /// Near-black or white, whichever reads on `hex` (the WCAG 0.179 split) —
    /// the same rule the dashboard uses for an unset `primaryInk`.
    static func readableOn(_ hex: String) -> String {
        guard let (r, g, b) = rgb(hex) else { return "#ffffff" }
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return l > 0.179 ? "#111827" : "#ffffff"
    }
}

/// A fully-resolved design: every token has a value.
public struct AtlasDesign: Equatable, Sendable {
    public struct Typography: Equatable, Sendable {
        public var font: String
        public var headingFont: String
        /// Body text size in points (12…20).
        public var baseSize: Int
        public var headingWeight: Int
        public var bodyWeight: Int
        /// Letter case of BUTTON labels.
        public var letterCase: AtlasLetterCase
        public var scale: String

        /// Heading size = base × the type-scale ratio.
        public var headingSize: Double { Double(baseSize) * (AtlasTypeScale.ratios[scale] ?? 1.333) }
        public var smallSize: Double { (Double(baseSize) * 0.867 * 10).rounded() / 10 }
    }

    public struct Shape: Equatable, Sendable {
        /// Card corner radius (0…32).
        public var radius: Int
        /// Button + input corner radius; 999 = pill / capsule.
        public var controlRadius: Int
        public var borderWidth: Int
        public var isPill: Bool { controlRadius >= 999 }
    }

    public struct Card: Equatable, Sendable {
        public var style: AtlasCardStyle
        public var blur: Int
        public var width: AtlasCardWidth
    }

    public var colorScheme: AtlasColorScheme
    public var palette: AtlasPalette
    public var paletteDark: AtlasPalette
    public var typography: Typography
    public var shape: Shape
    public var cardShadow: AtlasCardShadow
    public var density: AtlasDensity
    public var card: Card
    public var logoSize: AtlasLogoSize
    public var buttonStyle: AtlasButtonStyleKind
    public var socialLayout: AtlasSocialLayout
    public var inputStyle: AtlasInputStyle
    public var logoURL: URL?
    public var logoDarkURL: URL?

    /// The Atlas baseline (the `minimal` preset) — what a missing key resolves to.
    public static let defaults = AtlasDesign(
        colorScheme: .auto,
        palette: AtlasPalette("#18181b #ffffff #4f46e5 #fafafa #ffffff #18181b #71717a #e4e4e7 #dc2626 #15803d #ffffff #18181b"),
        paletteDark: AtlasPalette("#fafafa #18181b #818cf8 #09090b #18181b #fafafa #a1a1aa #3f3f46 #f87171 #4ade80 #09090b #fafafa"),
        typography: Typography(font: "inter", headingFont: "inter", baseSize: 15, headingWeight: 600,
                               bodyWeight: 400, letterCase: .none, scale: "perfect-fourth"),
        shape: Shape(radius: 12, controlRadius: 8, borderWidth: 1),
        cardShadow: .md,
        density: .comfortable,
        card: Card(style: .solid, blur: 16, width: .normal),
        logoSize: .md,
        buttonStyle: .solid,
        socialLayout: .list,
        inputStyle: .outline,
        logoURL: nil,
        logoDarkURL: nil
    )

    init(colorScheme: AtlasColorScheme, palette: AtlasPalette, paletteDark: AtlasPalette,
         typography: Typography, shape: Shape, cardShadow: AtlasCardShadow, density: AtlasDensity,
         card: Card, logoSize: AtlasLogoSize, buttonStyle: AtlasButtonStyleKind,
         socialLayout: AtlasSocialLayout, inputStyle: AtlasInputStyle, logoURL: URL?, logoDarkURL: URL?) {
        self.colorScheme = colorScheme; self.palette = palette; self.paletteDark = paletteDark
        self.typography = typography; self.shape = shape; self.cardShadow = cardShadow
        self.density = density; self.card = card; self.logoSize = logoSize
        self.buttonStyle = buttonStyle; self.socialLayout = socialLayout; self.inputStyle = inputStyle
        self.logoURL = logoURL; self.logoDarkURL = logoDarkURL
    }

    /// Decode the `design.resolved` object TOLERANTLY: unknown keys are ignored,
    /// and a missing, mistyped or out-of-range value falls back to
    /// ``defaults`` — a newer server never breaks an older app.
    public init(resolved json: [String: Any], logoURL: URL? = nil, logoDarkURL: URL? = nil) {
        let d = AtlasDesign.defaults
        func section(_ key: String) -> [String: Any] { json[key] as? [String: Any] ?? [:] }
        func int(_ dict: [String: Any], _ key: String, _ range: ClosedRange<Int>, _ dflt: Int) -> Int {
            guard let n = dict[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return dflt }
            let v = n.doubleValue
            guard v == v.rounded(), range.contains(Int(v)) else { return dflt }
            return Int(v)
        }
        func pick<E: RawRepresentable>(_ dict: [String: Any], _ key: String, _ dflt: E) -> E where E.RawValue == String {
            (dict[key] as? String).flatMap(E.init(rawValue:)) ?? dflt
        }
        func font(_ dict: [String: Any], _ key: String, _ dflt: String) -> String {
            guard let s = dict[key] as? String, AtlasFontCatalog.families[s] != nil else { return dflt }
            return s
        }

        colorScheme = pick(json, "colorScheme", d.colorScheme)
        palette = AtlasPalette(json: json["palette"], fallback: d.palette)
        paletteDark = AtlasPalette(json: json["paletteDark"], fallback: d.paletteDark)

        let t = section("typography")
        let bodyFont = font(t, "font", d.typography.font)
        // A design that sets `font` but no `headingFont` uses the same font for headings.
        let headingFont = font(t, "headingFont", t["font"] != nil ? bodyFont : d.typography.headingFont)
        let scale = (t["scale"] as? String).flatMap { AtlasTypeScale.ratios[$0] != nil ? $0 : nil } ?? d.typography.scale
        typography = Typography(
            font: bodyFont,
            headingFont: headingFont,
            baseSize: int(t, "baseSize", 12...20, d.typography.baseSize),
            headingWeight: int(t, "headingWeight", 300...900, d.typography.headingWeight),
            bodyWeight: int(t, "bodyWeight", 100...900, d.typography.bodyWeight),
            letterCase: pick(t, "letterCase", d.typography.letterCase),
            scale: scale
        )

        let s = section("shape")
        shape = Shape(radius: int(s, "radius", 0...32, d.shape.radius),
                      controlRadius: int(s, "controlRadius", 0...999, d.shape.controlRadius),
                      borderWidth: int(s, "borderWidth", 0...3, d.shape.borderWidth))
        cardShadow = pick(section("elevation"), "cardShadow", d.cardShadow)
        density = pick(section("spacing"), "density", d.density)
        let c = section("card")
        card = Card(style: pick(c, "style", d.card.style), blur: int(c, "blur", 0...40, d.card.blur),
                    width: pick(c, "width", d.card.width))
        logoSize = pick(section("layout"), "logoSize", d.logoSize)
        let b = section("buttons")
        buttonStyle = pick(b, "style", d.buttonStyle)
        socialLayout = pick(b, "socialLayout", d.socialLayout)
        inputStyle = pick(section("inputs"), "style", d.inputStyle)
        self.logoURL = logoURL
        self.logoDarkURL = logoDarkURL
    }

    /// Decode the whole `design` member of `GET /v1/appearance`; nil for `null`
    /// (no design saved) or a non-object.
    public init?(bundle: Any?) {
        guard let bundle = bundle as? [String: Any] else { return nil }
        let url: (String) -> URL? = { key in (bundle[key] as? String).flatMap(URL.init(string:)) }
        self.init(resolved: bundle["resolved"] as? [String: Any] ?? [:],
                  logoURL: url("logo_url"), logoDarkURL: url("logo_dark_url"))
    }

    // MARK: derived values

    /// Whether the dark palette applies, given the system appearance.
    public func usesDark(systemIsDark: Bool) -> Bool {
        switch colorScheme {
        case .dark: return true
        case .light: return false
        case .auto: return systemIsDark
        }
    }

    /// The palette for the current system appearance (honouring a forced scheme).
    public func activePalette(systemIsDark: Bool) -> AtlasPalette {
        usesDark(systemIsDark: systemIsDark) ? paletteDark : palette
    }

    /// The logo for the current appearance: the dark upload in dark mode, else the light one.
    public func logo(systemIsDark: Bool) -> URL? {
        usesDark(systemIsDark: systemIsDark) ? (logoDarkURL ?? logoURL) : (logoURL ?? logoDarkURL)
    }

    /// Spacing for the density: base unit, card padding, gap between rows, control height.
    public var spacing: (unit: Double, card: Double, gap: Double, control: Double) {
        switch density {
        case .compact: return (3, 20, 10, 36)
        case .comfortable: return (4, 28, 14, 40)
        case .spacious: return (5, 36, 18, 46)
        }
    }

    public var cardMaxWidth: Double {
        switch card.width { case .narrow: return 340; case .normal: return 380; case .wide: return 460 }
    }

    public var logoHeight: Double {
        switch logoSize { case .sm: return 32; case .md: return 48; case .lg: return 64 }
    }

    /// The card's drop shadow — `(opacity, blur radius, y offset)`, nil for none.
    /// An `outline` / `none` card never casts one (as on the web).
    public var shadow: (opacity: Double, radius: Double, y: Double)? {
        if card.style == .outline || card.style == .none { return nil }
        switch cardShadow {
        case .none: return nil
        case .sm: return (0.05, 1, 1)
        case .md: return (0.12, 20, 12)
        case .lg: return (0.14, 24, 16)
        case .xl: return (0.24, 40, 32)
        }
    }

    /// The card border: `outline` cards always get one, `none` cards never do.
    public var cardBorderWidth: Int {
        switch card.style {
        case .none: return 0
        case .outline: return max(1, shape.borderWidth)
        default: return shape.borderWidth
        }
    }

    // MARK: precedence

    /// The design the native UI renders. Precedence, lowest first: Atlas
    /// defaults < the dashboard design < the code-level `appearance`.
    ///
    /// Returns nil — meaning "render exactly the pre-design look" — when there is
    /// no dashboard design (or `applyDashboardDesign` is false) AND no code override.
    public static func resolve(dashboard: AtlasDesign?, appearance: AtlasAppearance?) -> AtlasDesign? {
        let base = appearance?.applyDashboardDesign == false ? nil : dashboard
        guard let appearance, !appearance.isEmpty else { return base }
        var out = base ?? .defaults
        appearance.apply(to: &out)
        return out
    }
}

/// Code-level design overrides — the same tokens as the dashboard's design
/// editor. Every field is optional; a set field wins over the dashboard design.
///
/// ```swift
/// var look = AtlasAppearance()
/// look.palette[.primary] = "#0f766e"
/// look.controlRadius = 999            // pill buttons + inputs
/// look.buttonStyle = .soft
/// SignIn(session: session, appearance: look)
/// ```
public struct AtlasAppearance: Sendable {
    /// Apply the design saved in the Atlas dashboard (default `true`). With
    /// `false` only these code overrides apply (over the Atlas defaults).
    public var applyDashboardDesign: Bool = true
    public var colorScheme: AtlasColorScheme?
    /// Light-mode slot overrides (`#rrggbb`). Brand slots (primary, accent,
    /// danger, success) also apply in dark mode unless `paletteDark` sets them.
    public var palette: [AtlasPaletteSlot: String] = [:]
    public var paletteDark: [AtlasPaletteSlot: String] = [:]
    /// A font catalog id (`inter`, `source-serif`, `system-mono`, …).
    public var font: String?
    public var headingFont: String?
    public var baseSize: Int?
    public var headingWeight: Int?
    public var bodyWeight: Int?
    public var letterCase: AtlasLetterCase?
    public var scale: String?
    public var radius: Int?
    public var controlRadius: Int?
    public var borderWidth: Int?
    public var cardShadow: AtlasCardShadow?
    public var density: AtlasDensity?
    public var cardStyle: AtlasCardStyle?
    public var cardWidth: AtlasCardWidth?
    public var logoSize: AtlasLogoSize?
    public var buttonStyle: AtlasButtonStyleKind?
    public var socialLayout: AtlasSocialLayout?
    public var inputStyle: AtlasInputStyle?
    public var logoURL: URL?
    public var logoDarkURL: URL?

    public init() {}

    /// True when no token is overridden (`applyDashboardDesign` is not a token).
    public var isEmpty: Bool {
        palette.isEmpty && paletteDark.isEmpty && colorScheme == nil && font == nil && headingFont == nil
            && baseSize == nil && headingWeight == nil && bodyWeight == nil && letterCase == nil && scale == nil
            && radius == nil && controlRadius == nil && borderWidth == nil && cardShadow == nil && density == nil
            && cardStyle == nil && cardWidth == nil && logoSize == nil && buttonStyle == nil
            && socialLayout == nil && inputStyle == nil && logoURL == nil && logoDarkURL == nil
    }

    func apply(to d: inout AtlasDesign) {
        if let v = colorScheme { d.colorScheme = v }
        let light = palette.filter { AtlasHex.isValid($0.value) }
        let dark = paletteDark.filter { AtlasHex.isValid($0.value) }
        for (slot, v) in light { d.palette[slot] = v }
        if let p = light[.primary], light[.primaryInk] == nil { d.palette[.primaryInk] = AtlasHex.readableOn(p) }
        var darkOver = dark
        for slot in AtlasPaletteSlot.brand where darkOver[slot] == nil { if let v = light[slot] { darkOver[slot] = v } }
        if darkOver[.primary] != nil, darkOver[.primaryInk] == nil {
            darkOver[.primaryInk] = light[.primaryInk] ?? AtlasHex.readableOn(darkOver[.primary]!)
        }
        for (slot, v) in darkOver { d.paletteDark[slot] = v }

        if let v = font, AtlasFontCatalog.families[v] != nil {
            d.typography.font = v
            if headingFont == nil { d.typography.headingFont = v }
        }
        if let v = headingFont, AtlasFontCatalog.families[v] != nil { d.typography.headingFont = v }
        if let v = baseSize, (12...20).contains(v) { d.typography.baseSize = v }
        if let v = headingWeight, (300...900).contains(v) { d.typography.headingWeight = v }
        if let v = bodyWeight, (100...900).contains(v) { d.typography.bodyWeight = v }
        if let v = letterCase { d.typography.letterCase = v }
        if let v = scale, AtlasTypeScale.ratios[v] != nil { d.typography.scale = v }
        if let v = radius, (0...32).contains(v) { d.shape.radius = v }
        if let v = controlRadius, (0...999).contains(v) { d.shape.controlRadius = v }
        if let v = borderWidth, (0...3).contains(v) { d.shape.borderWidth = v }
        if let v = cardShadow { d.cardShadow = v }
        if let v = density { d.density = v }
        if let v = cardStyle { d.card.style = v }
        if let v = cardWidth { d.card.width = v }
        if let v = logoSize { d.logoSize = v }
        if let v = buttonStyle { d.buttonStyle = v }
        if let v = socialLayout { d.socialLayout = v }
        if let v = inputStyle { d.inputStyle = v }
        if let v = logoURL { d.logoURL = v }
        if let v = logoDarkURL { d.logoDarkURL = v }
    }
}

/// The public appearance of an instance (`GET /v1/appearance`), as far as the
/// native UI uses it.
public struct AtlasAppearanceInfo: Sendable {
    /// The dashboard design, or nil when none has been saved.
    public let design: AtlasDesign?
    /// Enabled social provider ids (`google`, `github`, …).
    public let providers: [String]
    /// The application's display name, when set.
    public let applicationName: String?

    public init(design: AtlasDesign?, providers: [String] = [], applicationName: String? = nil) {
        self.design = design
        self.providers = providers
        self.applicationName = applicationName
    }

    /// Decode a `GET /v1/appearance` body tolerantly.
    public init(json: [String: Any]) {
        design = AtlasDesign(bundle: json["design"])
        providers = (json["providers"] as? [Any])?.compactMap { $0 as? String } ?? []
        applicationName = (json["appearance"] as? [String: Any])?["applicationName"] as? String
    }
}

extension AtlasClient {
    /// The instance's public appearance (`GET /v1/appearance`): the dashboard
    /// design (nil until one is saved) and the enabled social providers.
    ///
    /// - Parameter organization: optional org id/slug to theme to that org's brand.
    public func appearance(organization: String? = nil) async throws -> AtlasAppearanceInfo {
        var path = "/v1/appearance"
        if let organization, let q = organization.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?org=\(q)"
        }
        let (data, response) = try await sendJSON("GET", path, json: nil, refreshCookie: nil)
        try throwIfError(status: response.statusCode, data: data)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AtlasError.decoding("Could not decode the appearance response.")
        }
        return AtlasAppearanceInfo(json: json)
    }
}
