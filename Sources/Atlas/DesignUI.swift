#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Mapping an AtlasDesign onto SwiftUI
//
// Used by `SignIn` when a design applies (a dashboard design was saved, or the
// app passed an `AtlasAppearance`). With no design the views keep their
// original plain styling, untouched.

extension Color {
    /// A colour from `#rrggbb`; clear when the string is not a hex colour.
    init(atlasHex hex: String) {
        if let (r, g, b) = AtlasHex.rgb(hex) {
            self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
        } else {
            self = .clear
        }
    }
}

extension AtlasPalette {
    func color(_ slot: AtlasPaletteSlot) -> Color { Color(atlasHex: self[slot]) }
}

/// Font resolution: the catalog family when the APP bundles it (see the README's
/// "Bundling a font"), else the system font of the same category, always at the
/// design's weight and size.
enum AtlasFontResolver {
    static func isAvailable(_ family: String) -> Bool {
        #if canImport(UIKit)
        return UIFont.familyNames.contains(family)
        #elseif canImport(AppKit)
        return NSFontManager.shared.availableFontFamilies.contains(family)
        #else
        return false
        #endif
    }

    static func weight(_ w: Int) -> Font.Weight {
        switch w {
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }

    @available(iOS 15.0, macOS 12.0, *)
    static func font(id: String, size: Double, weight w: Int) -> Font {
        if let family = AtlasFontCatalog.family(for: id), isAvailable(family) {
            return Font.custom(family, size: size).weight(weight(w))
        }
        let design: Font.Design
        switch AtlasFontCatalog.category(for: id) {
        case .serif: design = .serif
        case .monospace: design = .monospaced
        case .sansSerif: design = .default
        }
        return Font.system(size: size, weight: weight(w), design: design)
    }
}

/// Everything a view needs to draw one design in one colour mode.
@available(iOS 15.0, macOS 12.0, *)
struct AtlasStyle {
    let design: AtlasDesign
    let palette: AtlasPalette

    init(design: AtlasDesign, systemIsDark: Bool) {
        self.design = design
        self.palette = design.activePalette(systemIsDark: systemIsDark)
    }

    var t: AtlasDesign.Typography { design.typography }
    var bodyFont: Font { AtlasFontResolver.font(id: t.font, size: Double(t.baseSize), weight: t.bodyWeight) }
    var smallFont: Font { AtlasFontResolver.font(id: t.font, size: t.smallSize, weight: t.bodyWeight) }
    var headingFont: Font { AtlasFontResolver.font(id: t.headingFont, size: t.headingSize, weight: t.headingWeight) }
    var buttonFont: Font { AtlasFontResolver.font(id: t.font, size: Double(t.baseSize), weight: max(500, t.bodyWeight)) }
    var controlHeight: Double { design.spacing.control }
    /// Corner radius for a control; a pill (999) becomes half the control height.
    var controlRadius: Double { min(Double(design.shape.controlRadius), controlHeight / 2) }
    var borderWidth: Double { Double(design.shape.borderWidth) }
}

/// The primary call-to-action button, in the design's button style.
@available(iOS 15.0, macOS 12.0, *)
struct AtlasPrimaryButtonStyle: ButtonStyle {
    let style: AtlasStyle

    func makeBody(configuration: Configuration) -> some View {
        let p = style.palette
        let shape = RoundedRectangle(cornerRadius: style.controlRadius, style: .continuous)
        let kind = style.design.buttonStyle
        let foreground: Color = (kind == .outline || kind == .soft) ? p.color(.primary) : p.color(.primaryInk)
        return configuration.label
            .font(style.buttonFont)
            .textCase(style.t.letterCase == .uppercase ? .uppercase : nil)
            .modifier(AtlasTracking(value: style.t.letterCase == .uppercase ? Double(style.t.baseSize) * 0.04 : 0))
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity, minHeight: style.controlHeight)
            .background(background(kind, p).clipShape(shape))
            .overlay(kind == .outline
                     ? shape.strokeBorder(p.color(.primary), lineWidth: max(1, style.borderWidth))
                     : nil)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }

    @ViewBuilder private func background(_ kind: AtlasButtonStyleKind, _ p: AtlasPalette) -> some View {
        switch kind {
        case .solid: p.color(.primary)
        case .outline: Color.clear
        case .soft: p.color(.primary).opacity(0.14)
        case .gradient:
            LinearGradient(colors: [p.color(.primary), p.color(.accent)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// Letter spacing for uppercase labels; view-level tracking needs iOS 16 / macOS 13.
@available(iOS 15.0, macOS 12.0, *)
struct AtlasTracking: ViewModifier {
    let value: Double

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            content.tracking(value)
        } else {
            content
        }
    }
}

/// A secondary (bordered, text-coloured) button — "Email me a code", social buttons.
@available(iOS 15.0, macOS 12.0, *)
struct AtlasSecondaryButtonStyle: ButtonStyle {
    let style: AtlasStyle
    var fillWidth = true

    func makeBody(configuration: Configuration) -> some View {
        let p = style.palette
        let shape = RoundedRectangle(cornerRadius: style.controlRadius, style: .continuous)
        return configuration.label
            .font(style.smallFont.weight(.medium))
            .textCase(style.t.letterCase == .uppercase ? .uppercase : nil)
            .foregroundColor(p.color(.text))
            .frame(maxWidth: fillWidth ? .infinity : nil, minHeight: style.controlHeight)
            .padding(.horizontal, fillWidth ? 0 : style.design.spacing.unit * 3)
            .background(p.color(.surface).clipShape(shape))
            .overlay(shape.strokeBorder(p.color(.border), lineWidth: max(1, style.borderWidth)))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Input chrome for the design's input style (outline / filled / underline).
@available(iOS 15.0, macOS 12.0, *)
struct AtlasInputModifier: ViewModifier {
    let style: AtlasStyle

    func body(content: Content) -> some View {
        let p = style.palette
        let shape = RoundedRectangle(cornerRadius: style.controlRadius, style: .continuous)
        let field = content
            .textFieldStyle(.plain)
            .font(style.bodyFont)
            .foregroundColor(p.color(.inputText))
            .frame(minHeight: style.controlHeight)
        switch style.design.inputStyle {
        case .outline:
            return AnyView(field
                .padding(.horizontal, style.design.spacing.unit * 3)
                .background(p.color(.inputBackground).clipShape(shape))
                .overlay(shape.strokeBorder(p.color(.border), lineWidth: style.borderWidth)))
        case .filled:
            // Text colour washed 6% over the input background, no border (as on the web).
            return AnyView(field
                .padding(.horizontal, style.design.spacing.unit * 3)
                .background(ZStack { p.color(.inputBackground); p.color(.text).opacity(0.06) }.clipShape(shape)))
        case .underline:
            return AnyView(field
                .overlay(Rectangle().fill(p.color(.border)).frame(height: max(1, style.borderWidth)),
                         alignment: .bottom))
        }
    }
}

/// The card around the sign-in form: surface, radius, border, shadow, padding, width.
@available(iOS 15.0, macOS 12.0, *)
struct AtlasCardModifier: ViewModifier {
    let style: AtlasStyle
    let systemIsDark: Bool

    func body(content: Content) -> some View {
        let d = style.design
        let p = style.palette
        let shape = RoundedRectangle(cornerRadius: Double(d.shape.radius), style: .continuous)
        let surface: AnyView = {
            switch d.card.style {
            case .none: return AnyView(Color.clear)
            case .glass:
                return AnyView(ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    p.color(.surface).opacity(systemIsDark ? 0.6 : 0.72)
                })
            case .solid, .outline: return AnyView(p.color(.surface))
            }
        }()
        let shadow = d.shadow
        return content
            .padding(d.card.style == .none ? 0 : d.spacing.card)
            .frame(maxWidth: d.cardMaxWidth)
            .background(surface.clipShape(shape))
            .overlay(d.cardBorderWidth > 0
                     ? shape.strokeBorder(p.color(.border), lineWidth: Double(d.cardBorderWidth))
                     : nil)
            .shadow(color: Color.black.opacity(shadow?.opacity ?? 0),
                    radius: (shadow?.radius ?? 0) / 2, x: 0, y: shadow?.y ?? 0)
    }
}

/// Social sign-in buttons laid out per the design (`list` / `grid` / `icons`).
///
/// The view only reports the tapped provider id; start the OAuth flow yourself
/// (``AtlasClient/oauthAuthorizeURL(provider:redirectURI:)`` +
/// `ASWebAuthenticationSession`).
@available(iOS 15.0, macOS 12.0, *)
public struct AtlasSocialButtons: View {
    let providers: [String]
    let design: AtlasDesign
    let onSelect: (String) -> Void
    @Environment(\.colorScheme) private var systemScheme

    public init(providers: [String], design: AtlasDesign = .defaults, onSelect: @escaping (String) -> Void) {
        self.providers = providers
        self.design = design
        self.onSelect = onSelect
    }

    public var body: some View {
        let style = AtlasStyle(design: design, systemIsDark: systemScheme == .dark)
        let gap = design.spacing.unit * 2
        switch design.socialLayout {
        case .list:
            VStack(spacing: gap) {
                ForEach(providers, id: \.self) { id in
                    Button("Continue with \(AtlasProviderNames.name(id))") { onSelect(id) }
                        .buttonStyle(AtlasSecondaryButtonStyle(style: style))
                }
            }
        case .grid:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: gap), GridItem(.flexible(), spacing: gap)],
                      spacing: gap) {
                ForEach(providers, id: \.self) { id in
                    Button(AtlasProviderNames.name(id)) { onSelect(id) }
                        .buttonStyle(AtlasSecondaryButtonStyle(style: style))
                }
            }
        case .icons:
            HStack(spacing: gap) {
                ForEach(providers, id: \.self) { id in
                    Button(String(AtlasProviderNames.name(id).prefix(1))) { onSelect(id) }
                        .buttonStyle(AtlasSecondaryButtonStyle(style: style, fillWidth: false))
                        .accessibilityLabel("Continue with \(AtlasProviderNames.name(id))")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Display names for provider ids.
public enum AtlasProviderNames {
    static let known: [String: String] = [
        "github": "GitHub", "gitlab": "GitLab", "linkedin": "LinkedIn", "linkedin_oidc": "LinkedIn",
        "x": "X", "twitter": "X", "tiktok": "TikTok", "hubspot": "HubSpot", "huggingface": "Hugging Face",
        "microsoft": "Microsoft", "apple": "Apple", "google": "Google", "facebook": "Facebook",
    ]

    public static func name(_ id: String) -> String {
        if let n = known[id] { return n }
        return id.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
#endif
