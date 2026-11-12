import AppKit
import RedactCore
import SwiftUI

// Redact design system. Every color, size, radius and spacing value in the app comes from here.
//
// Direction: a quiet native Mac tool. Tinted neutrals that follow the system appearance, one lime
// "signal" accent (primary action, current environment, safe state), monospaced names and values,
// and one signature: the redaction bar.

// MARK: - Color

/// Converts OKLCH to an sRGB NSColor (tokens are written in OKLCH so lightness steps are even).
private func oklch(_ l: Double, _ c: Double, _ h: Double, _ alpha: Double = 1) -> NSColor {
    let hr = h * .pi / 180
    let a = c * cos(hr), b = c * sin(hr)
    let l_ = l + 0.3963377774 * a + 0.2158037573 * b
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b
    let (L, M, S) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
    func gamma(_ x: Double) -> CGFloat {
        let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return CGFloat(min(max(v, 0), 1))
    }
    return NSColor(srgbRed: gamma(4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S),
                   green: gamma(-1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S),
                   blue: gamma(-0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S),
                   alpha: CGFloat(alpha))
}

private func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
}

enum Palette {
    /// Anchor hue for the neutrals' tint and the accent.
    private static let hue = 128.0

    static let canvas = adaptive(light: oklch(0.985, 0.004, hue), dark: oklch(0.225, 0.006, hue))
    static let surface = adaptive(light: oklch(0.997, 0.002, hue), dark: oklch(0.258, 0.007, hue))
    static let sunken = adaptive(light: oklch(0.958, 0.005, hue), dark: oklch(0.195, 0.006, hue))
    static let hover = adaptive(light: oklch(0, 0, 0, 0.045), dark: oklch(1, 0, 0, 0.06))
    static let selected = adaptive(light: oklch(0, 0, 0, 0.075), dark: oklch(1, 0, 0, 0.1))
    static let rule = adaptive(light: oklch(0, 0, 0, 0.08), dark: oklch(1, 0, 0, 0.085))

    static let ink = adaptive(light: oklch(0.22, 0.01, hue), dark: oklch(0.95, 0.006, hue))
    static let ink2 = adaptive(light: oklch(0.46, 0.012, hue), dark: oklch(0.75, 0.008, hue))
    /// Icons and placeholders only; never body text.
    static let ink3 = adaptive(light: oklch(0.6, 0.01, hue), dark: oklch(0.58, 0.008, hue))

    /// Lime signal. Fill only, always with `accentInk` on top.
    static let accent = adaptive(light: oklch(0.88, 0.19, hue), dark: oklch(0.87, 0.19, hue))
    /// The asterisk on the lime mark (near-black in both appearances).
    static let markInk = Color(nsColor: oklch(0.13, 0.02, hue))
    static let markInkTop = Color(nsColor: oklch(0.34, 0.03, hue))
    static let markLimeTop = Color(nsColor: oklch(0.93, 0.17, 125))
    static let markLimeBottom = Color(nsColor: oklch(0.80, 0.19, 132))
    static let accentInk = adaptive(light: oklch(0.27, 0.07, hue), dark: oklch(0.24, 0.06, hue))
    /// The accent as text or an icon on canvas/surface (contrast-safe in both appearances).
    static let accentText = adaptive(light: oklch(0.5, 0.14, 135), dark: oklch(0.86, 0.17, hue))
    static let accentSoft = adaptive(light: oklch(0.88, 0.19, hue, 0.28), dark: oklch(0.87, 0.19, hue, 0.14))

    static let danger = adaptive(light: oklch(0.54, 0.19, 27), dark: oklch(0.72, 0.16, 25))
    static let warning = adaptive(light: oklch(0.56, 0.12, 65), dark: oklch(0.82, 0.14, 78))
    static let ok = adaptive(light: oklch(0.52, 0.13, 150), dark: oklch(0.8, 0.15, 150))

    static func soft(_ tone: Color) -> Color { tone.opacity(0.14) }

    // Brand tiles (fixed in both appearances, white monogram on top).
    static func brand(_ l: Double, _ c: Double, _ h: Double) -> Color { Color(nsColor: oklch(l, c, h)) }
}

// MARK: - Space, radius, type

/// 4px scale. Gap between groups ≥ 2× gap within a group.
enum Space {
    static let hairline: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

/// One radius per nesting level; nested radii are concentric (outer = inner + padding).
enum Radius {
    static let card: CGFloat = 10
    static let control: CGFloat = 6
    static let chip: CGFloat = 5
    static let tile: CGFloat = 7
}

/// macOS density: 13pt body, ratio ≈ 1.15.
enum TextStyle {
    static let display = Font.system(size: 26, weight: .semibold)
    static let title = Font.system(size: 20, weight: .semibold)
    static let heading = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .medium)
    static let small = Font.system(size: 12)
    static let smallStrong = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11)
    static let captionStrong = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let monoStrong = Font.system(size: 12.5, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let monoLarge = Font.system(size: 15, design: .monospaced)
}

enum Motion {
    /// House UI ease-out.
    static let easeOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.15)
    static let crossfade = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.3)
    static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
}

// MARK: - Surfaces

struct CardModifier: ViewModifier {
    var padding: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 2, y: 1)
    }
}

extension View {
    /// A surface on the canvas. Never nest one card inside another.
    func card(padding: CGFloat = 0) -> some View { modifier(CardModifier(padding: padding)) }

    /// Inset well for code, values and inputs.
    func sunken(radius: CGFloat = Radius.control) -> some View {
        background(Palette.sunken, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
    }

    func canvas() -> some View { background(Palette.canvas) }
}

/// Hairline between rows inside a card.
struct Rule: View {
    var inset: CGFloat = 0
    var body: some View { Rectangle().fill(Palette.rule).frame(height: 1).padding(.leading, inset) }
}

// MARK: - Buttons

enum ButtonTone { case primary, secondary, quiet, danger }

struct RedactButtonStyle: ButtonStyle {
    var tone: ButtonTone = .secondary
    var large = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? TextStyle.bodyStrong : TextStyle.smallStrong)
            .labelStyle(TightLabelStyle())
            .padding(.horizontal, tone == .quiet ? Space.s : (large ? Space.l : Space.m))
            .frame(minHeight: large ? 36 : 28)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay {
                if tone == .secondary {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.97 : 1)
            .animation(Motion.easeOut, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch tone {
        case .primary: Palette.accentInk
        case .secondary: Palette.ink
        case .quiet: Palette.ink2
        case .danger: Palette.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        let active = isEnabled && (hovering || pressed)
        switch tone {
        case .primary: return Palette.accent.opacity(active ? 0.86 : 1)
        case .secondary: return active ? Palette.selected : Palette.surface
        case .quiet, .danger: return active ? Palette.hover : .clear
        }
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == RedactButtonStyle {
    static var primary: RedactButtonStyle { RedactButtonStyle(tone: .primary) }
    static var secondary: RedactButtonStyle { RedactButtonStyle(tone: .secondary) }
    static var quiet: RedactButtonStyle { RedactButtonStyle(tone: .quiet) }
    static var danger: RedactButtonStyle { RedactButtonStyle(tone: .danger) }
    static var primaryLarge: RedactButtonStyle { RedactButtonStyle(tone: .primary, large: true) }
}

/// Square icon-only button (reveal, copy, more).
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Palette.ink2
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Pills

enum Tone { case neutral, accent, ok, warning, danger }

struct Pill: View {
    let text: String
    var symbol: String?
    var tone: Tone = .neutral
    var mono = false

    var body: some View {
        HStack(spacing: Space.xs) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(mono ? TextStyle.monoSmall : TextStyle.captionStrong).monospacedDigit()
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .foregroundStyle(foreground)
        .background(background, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }

    private var foreground: Color {
        switch tone {
        case .neutral: Palette.ink2
        case .accent: Palette.accentText
        case .ok: Palette.ok
        case .warning: Palette.warning
        case .danger: Palette.danger
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: Palette.hover
        case .accent: Palette.accentSoft
        case .ok: Palette.soft(Palette.ok)
        case .warning: Palette.soft(Palette.warning)
        case .danger: Palette.soft(Palette.danger)
        }
    }
}

// MARK: - Brand tiles

/// A provider's tile (Slinky-style): its real mark on its brand color, so a key is recognizable before its name is read.
struct Brand: Equatable {
    let name: String
    let monogram: String
    let color: Color
    /// Key into `BrandIconData.icons`; nil falls back to the monogram.
    var icon: String?
    /// Light brand colors (e.g. Hugging Face yellow) get a dark mark.
    var darkMark = false

    static let generic = Brand(name: "Key", monogram: "", color: Palette.brand(0.5, 0.01, 128))

    private static func real(_ name: String, _ icon: String) -> Brand {
        let hex = BrandIconData.icons[icon]?.hex ?? 0x666666
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return Brand(name: name, monogram: String(name.prefix(1)), color: Color(.sRGB, red: r, green: g, blue: b),
                     icon: icon, darkMark: luminance > 0.7)
    }

    static func named(_ raw: String) -> Brand {
        let name = raw.replacingOccurrences(of: " (likely)", with: "")
        switch name.lowercased() {
        case "cloudflare": return real("Cloudflare", "cloudflare")
        case "stripe": return real("Stripe", "stripe")
        case "github": return real("GitHub", "github")
        case "openai": return real("OpenAI", "openai")
        case "anthropic": return real("Anthropic", "anthropic")
        case "vercel": return real("Vercel", "vercel")
        case "supabase": return real("Supabase", "supabase")
        case "aws": return real("AWS", "aws")
        case "postgres", "postgresql": return real("Postgres", "postgres")
        case "mysql": return real("MySQL", "mysql")
        case "mongodb": return real("MongoDB", "mongodb")
        case "redis": return real("Redis", "redis")
        case "google": return real("Google", "google")
        case "slack": return real("Slack", "slack")
        case "resend": return real("Resend", "resend")
        case "gitlab": return real("GitLab", "gitlab")
        case "hugging face": return real("Hugging Face", "huggingface")
        case "npm": return real("npm", "npm")
        case "sendgrid": return real("SendGrid", "sendgrid")
        case "jwt": return real("JWT", "jwt")
        default: return Brand(name: name, monogram: String(name.prefix(1)).uppercased(), color: Palette.brand(0.5, 0.01, 128))
        }
    }

    static func of(_ provider: Identity.Provider) -> Brand { named(provider.displayName) }

    /// Best guess from tags, the value's shape, then the name.
    static func of(_ item: Item) -> Brand {
        for tag in item.tags { if let provider = Identity.Provider(rawValue: tag) { return of(provider) } }
        if let guess = SecretDetector.guess(item.value), guess.kind == .apiKey, guess.provider != "Env", guess.provider != "JWT" {
            return named(guess.provider)
        }
        let lower = item.name.lowercased()
        for known in ["cloudflare", "stripe", "github", "openai", "anthropic", "vercel", "supabase", "aws", "google", "slack", "resend", "gitlab"]
            where lower.contains(known) {
            return named(known)
        }
        return .generic
    }

    static func ofAgent(_ name: String?) -> Brand {
        guard let name else { return Brand(name: "You", monogram: "", color: Palette.brand(0.5, 0.01, 128)) }
        switch name.lowercased() {
        case let n where n.contains("claude"): return real(name, "claude")
        case let n where n.contains("cursor"): return real(name, "cursor")
        case let n where n.contains("codex"): return real(name, "openai")
        default: return Brand(name: name, monogram: String(name.prefix(1)).uppercased(), color: Palette.brand(0.5, 0.03, 260))
        }
    }
}

/// Renders Simple Icons paths through NSImage's SVG support, cached per icon and mark color.
@MainActor
enum BrandMark {
    private static var cache: [String: NSImage] = [:]

    static func image(_ key: String, dark: Bool) -> NSImage? {
        let cacheKey = key + (dark ? "-d" : "-l")
        if let hit = cache[cacheKey] { return hit }
        guard let icon = BrandIconData.icons[key] else { return nil }
        let fill = dark ? "#1a1a1a" : "#ffffff"
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="48" height="48"><path fill=""# + fill + #"" d=""# + icon.path + #""/></svg>"#
        let image = NSImage(data: Data(svg.utf8))
        cache[cacheKey] = image
        return image
    }
}

struct BrandTile: View {
    let brand: Brand
    var size: CGFloat = 28
    var symbol = "key.fill"

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(brand.color)
            .overlay {
                if let key = brand.icon, let mark = BrandMark.image(key, dark: brand.darkMark) {
                    Image(nsImage: mark).resizable().interpolation(.high).scaledToFit().frame(width: size * 0.56, height: size * 0.56)
                } else if brand.monogram.isEmpty {
                    Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Text(brand.monogram)
                        .font(.system(size: size * (brand.monogram.count > 2 ? 0.3 : 0.38), weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(.white)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Signature: the redaction bar

/// Redact's mark: a raised near-black asterisk with an open centre on the lit lime tile. Same geometry as
/// the app icon (scripts/make-icon.swift).
struct RedactMark: View {
    var size: CGFloat = 56

    var body: some View {
        let small = size <= 24
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Palette.markLimeTop, Palette.markLimeBottom], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                                        lineWidth: max(1, size / 64)))
            .overlay {
                AsteriskShape(inner: small ? 0 : 0.06, width: small ? 0.13 : 0.112)
                    .fill(LinearGradient(colors: [Palette.markInkTop, Palette.markInk], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Palette.markInk.opacity(small ? 0 : 0.35), radius: size * 0.03, y: size * 0.025)
            }
            .shadow(color: .black.opacity(small ? 0 : 0.18), radius: size * 0.04, y: size * 0.015)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Six separate rounded arms around an open centre. Fractions are of the tile width.
struct AsteriskShape: Shape {
    var outer: CGFloat = 0.335
    var inner: CGFloat = 0.06
    var width: CGFloat = 0.112

    func path(in rect: CGRect) -> Path {
        let tile = min(rect.width, rect.height)
        let (outer, inner, width) = (tile * outer, tile * inner, tile * width)
        var path = Path()
        for angle in [90.0, 30.0, -30.0, -90.0, -150.0, 150.0] {
            let arm = Path(roundedRect: CGRect(x: inner, y: -width / 2, width: outer - inner, height: width), cornerRadius: width / 2)
            path.addPath(arm, transform: CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: angle * .pi / 180))
        }
        return path
    }
}

/// How a secret looks when it's hidden: the public prefix, the redaction bar, the last four.
enum Redaction {
    static func preview(_ value: String) -> String {
        let single = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard single.count >= 16 else { return String(repeating: "•", count: 10) }
        let prefixEnd = single.prefix(8).lastIndex { $0 == "_" || $0 == "-" || $0 == ":" }
        let prefix = prefixEnd.map { String(single[...$0]) } ?? ""
        return prefix + String(repeating: "•", count: 8) + String(single.suffix(4))
    }
}

// MARK: - Secret value

/// A secret in a row: masked preview, reveal, copy (with a static "Copied" cue).
struct SecretValue: View {
    let value: String
    var compact = false
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(revealed ? value : Redaction.preview(value))
                .font(TextStyle.mono)
                .foregroundStyle(revealed ? Palette.ink : Palette.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, Space.s)
                .frame(height: 24)
                .frame(minWidth: compact ? 0 : 200, maxWidth: compact ? 260 : .infinity, alignment: .leading)
                .sunken(radius: Radius.chip)
            IconButton(symbol: revealed ? "eye.slash" : "eye", help: revealed ? "Hide" : "Reveal") { revealed.toggle() }
            IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy (clears in 60 s)",
                       tint: copied ? Palette.accentText : Palette.ink2) {
                Clipboard.copy(value)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
        }
        .onChange(of: value) { revealed = false }
    }
}

// MARK: - Layout helpers

/// Folder path in mono, abbreviated with ~ and truncated in the middle; full path on hover.
struct PathLabel: View {
    let path: String
    var font: Font = TextStyle.monoSmall

    var body: some View {
        Label {
            Text(abbreviate(path)).font(font).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: "folder").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.ink3)
        }
        .labelStyle(TightLabelStyle())
        .foregroundStyle(Palette.ink2)
        .help(path)
    }
}

/// Page header: title, one line of explanation, trailing actions.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(TextStyle.title).foregroundStyle(Palette.ink)
                if let subtitle {
                    Text(LocalizedStringKey(subtitle)).font(TextStyle.body).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 620, alignment: .leading)
                }
            }
            Spacer(minLength: Space.l)
            HStack(spacing: Space.s) { trailing }
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Group label above a card.
struct GroupLabel<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(TextStyle.smallStrong).foregroundStyle(Palette.ink2)
            Spacer()
            trailing
        }
        .padding(.horizontal, Space.xs)
    }
}

extension GroupLabel where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// What belongs here, and the one action that fills it.
struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(Palette.ink3)
            VStack(spacing: Space.xs) {
                Text(title).font(TextStyle.heading).foregroundStyle(Palette.ink)
                Text(message).font(TextStyle.body).foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyState where Action == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// Inline notice (warning or info) with an optional action.
struct Notice<Action: View>: View {
    let symbol: String
    let text: String
    var tone: Tone = .warning
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: Space.s) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            Text(text).font(TextStyle.small).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            action
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Palette.soft(color), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private var color: Color {
        switch tone {
        case .warning: Palette.warning
        case .danger: Palette.danger
        case .ok: Palette.ok
        case .accent: Palette.accentText
        case .neutral: Palette.ink2
        }
    }
}

extension Notice where Action == EmptyView {
    init(symbol: String, text: String, tone: Tone = .warning) {
        self.init(symbol: symbol, text: text, tone: tone) { EmptyView() }
    }
}

/// Label/value row inside an info card (Slinky-style inspector).
struct InfoRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.l) {
            Text(label).font(TextStyle.body).foregroundStyle(Palette.ink2).frame(width: 96, alignment: .leading)
            value.font(TextStyle.body).foregroundStyle(Palette.ink).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 10)
    }
}

/// Text field in the app's style.
struct Field: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var mono = false

    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain)
        .font(mono ? TextStyle.mono : TextStyle.body)
        .padding(.horizontal, Space.s)
        .frame(height: 28)
        .sunken()
    }
}

/// Relative time ("5 min ago").
enum Ago {
    static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func text(_ date: Date) -> String { formatter.localizedString(for: date, relativeTo: Date()) }
}

/// Environment tabs (dotsafe-style): the current one is filled with the accent; production is marked.
struct EnvironmentTabs: View {
    let environments: [String]
    @Binding var selection: String
    let count: (String) -> Int

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(environments, id: \.self) { env in
                let isOn = env == selection
                Button { selection = env } label: {
                    HStack(spacing: 6) {
                        if env == "production" {
                            Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(isOn ? Palette.accentInk : Palette.warning)
                        }
                        Text(env).font(TextStyle.smallStrong)
                        Text("\(count(env))").font(TextStyle.caption).monospacedDigit()
                            .foregroundStyle(isOn ? Palette.accentInk.opacity(0.7) : Palette.ink3)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .foregroundStyle(isOn ? Palette.accentInk : Palette.ink2)
                    .background(isOn ? Palette.accent : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(Space.hairline)
        .background(Palette.hover, in: Capsule())
    }
}
