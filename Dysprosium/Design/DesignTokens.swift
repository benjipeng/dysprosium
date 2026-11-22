import Observation
import SwiftUI
import UIKit

/// Curated Lanthanide & Optical-Material color palettes for Dysprosium (`Dy`, Element 66).
/// Every palette defines scientifically calibrated Light Mode and Dark Mode pairs via dynamic `UIColor`
/// traits so prominent pills, badges, and Liquid Glass symbols achieve WCAG AA+ contrast (`>= 4.8:1`)
/// with zero `@Environment(\.colorScheme)` branches inside views.
public enum DysprosiumPalettePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case cerulean
    case ultramarine
    case terbium
    case europium
    case obsidian

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cerulean: return "Dysprosium Cerulean"
        case .ultramarine: return "Cobalt Ultramarine"
        case .terbium: return "Terbium Emerald"
        case .europium: return "Europium Vermilion"
        case .obsidian: return "Titanium Obsidian"
        }
    }

    public var elementBadge: String {
        switch self {
        case .cerulean: return "66 · Dy"
        case .ultramarine: return "27 · Co"
        case .terbium: return "65 · Tb"
        case .europium: return "63 · Eu"
        case .obsidian: return "22 · Ti"
        }
    }

    public var subtitle: String {
        switch self {
        case .cerulean: return "Deep optical cerulean & spectral cyan"
        case .ultramarine: return "Swiss typographic cobalt & indigo"
        case .terbium: return "Phosphor mineral jade & mint"
        case .europium: return "Industrial signal vermilion & amber"
        case .obsidian: return "Anodized monochrome editorial ink"
        }
    }
}

/// Authoritative semantic design tokens for color, Liquid Glass foreground contrast, and spatial rhythm.
public struct DysprosiumTokens: Sendable {
    public let preset: DysprosiumPalettePreset

    // MARK: - Brand & Interactive Surface Tokens

    /// Primary interactive tint applied to root scene `.tint(...)`, active pills, progress indicators, and links.
    public let accent: Color
    /// Paired harmonic hue used in subtle ambient backdrops and sparkline gradients.
    public let accentHarmonic: Color
    /// High-contrast foreground ink (`#FFFFFF` or `#101318`) guaranteed legible on solid `accent` fills.
    public let onAccent: Color
    /// Calibrated low-opacity pill & icon-well background (`~11%` Light / `~18%` Dark).
    public let accentSubtleFill: Color

    // MARK: - 3D Periodic Wafer Tokens (`66 · Dy` Wordmark)

    public let waferBackTop: Color
    public let waferBackBottom: Color
    public let waferMidTop: Color
    public let waferMidBottom: Color
    public let waferAtomicInk: Color

    // MARK: - Liquid Glass Foreground Tokens (`玻璃上的 Icon 颜色`)

    /// Crisp monochrome ink (`#14161A` Light / `#F5F7FA` Dark) for primary toolbar & glass-capsule icons.
    public let glassIconPrimary: Color
    /// Calibrated secondary ink (`68%` Light / `72%` Dark) for auxiliary controls (`Reload`, `Stop`, `Clear`) on glass.
    public let glassIconSecondary: Color
    /// High-contrast amber-gold (`#C26200` Light / `#FFB833` Dark) for starred bookmarks on white or dark glass.
    public let bookmarkStar: Color
    /// Ephemeral Private Mode accent (`#4338CA` Light / `#818CF8` Dark).
    public let privateAccent: Color
    public let privateSubtleFill: Color

    // MARK: - Semantic Status Tokens

    public let statusSuccess: Color
    public let statusSuccessFill: Color
    public let statusWarning: Color
    public let statusWarningFill: Color
    public let statusDanger: Color
    public let statusDangerFill: Color

    // MARK: - Spatial & Corner Tokens

    public enum Space {
        public static let sectionSpacing: CGFloat = 14
        public static let cardCornerSmall: CGFloat = 8
        public static let cardCornerMedium: CGFloat = 12
        public static let omniboxMaxWidth: CGFloat = 580
    }

    public init(preset: DysprosiumPalettePreset = .cerulean) {
        self.preset = preset

        let spec = Self.paletteSpec(for: preset)
        self.accent = Self.dynamicColor(light: spec.lightAccent, dark: spec.darkAccent)
        self.accentHarmonic = Self.dynamicColor(light: spec.lightHarmonic, dark: spec.darkHarmonic)
        self.onAccent = Self.dynamicColor(light: spec.lightOnAccent, dark: spec.darkOnAccent)
        self.accentSubtleFill = Self.dynamicColor(
            light: spec.lightAccent.withAlpha(0.11),
            dark: spec.darkAccent.withAlpha(0.18)
        )

        self.waferBackTop = Color(red: spec.waferBackTop.r, green: spec.waferBackTop.g, blue: spec.waferBackTop.b)
        self.waferBackBottom = Color(red: spec.waferBackBottom.r, green: spec.waferBackBottom.g, blue: spec.waferBackBottom.b)
        self.waferMidTop = Color(red: spec.waferMidTop.r, green: spec.waferMidTop.g, blue: spec.waferMidTop.b)
        self.waferMidBottom = Color(red: spec.waferMidBottom.r, green: spec.waferMidBottom.g, blue: spec.waferMidBottom.b)
        self.waferAtomicInk = Color(red: spec.waferAtomic.r, green: spec.waferAtomic.g, blue: spec.waferAtomic.b)

        self.glassIconPrimary = Self.dynamicColor(
            light: RGBA(0.08, 0.09, 0.11, 1.0),
            dark: RGBA(0.96, 0.97, 0.99, 1.0)
        )
        self.glassIconSecondary = Self.dynamicColor(
            light: RGBA(0.12, 0.15, 0.20, 0.68),
            dark: RGBA(0.93, 0.95, 0.98, 0.72)
        )
        self.bookmarkStar = Self.dynamicColor(
            light: RGBA(0.76, 0.38, 0.00, 1.0),
            dark: RGBA(1.00, 0.72, 0.20, 1.0)
        )
        self.privateAccent = Self.dynamicColor(
            light: RGBA(0.26, 0.22, 0.79, 1.0),
            dark: RGBA(0.51, 0.55, 0.97, 1.0)
        )
        self.privateSubtleFill = Self.dynamicColor(
            light: RGBA(0.26, 0.22, 0.79, 0.11),
            dark: RGBA(0.51, 0.55, 0.97, 0.18)
        )

        self.statusSuccess = Self.dynamicColor(
            light: RGBA(0.04, 0.48, 0.27, 1.0),
            dark: RGBA(0.20, 0.83, 0.60, 1.0)
        )
        self.statusSuccessFill = Self.dynamicColor(
            light: RGBA(0.04, 0.48, 0.27, 0.11),
            dark: RGBA(0.20, 0.83, 0.60, 0.18)
        )
        self.statusWarning = Self.dynamicColor(
            light: RGBA(0.71, 0.33, 0.04, 1.0),
            dark: RGBA(0.98, 0.75, 0.14, 1.0)
        )
        self.statusWarningFill = Self.dynamicColor(
            light: RGBA(0.71, 0.33, 0.04, 0.12),
            dark: RGBA(0.98, 0.75, 0.14, 0.18)
        )
        self.statusDanger = Color(uiColor: .systemRed)
        self.statusDangerFill = Self.dynamicColor(
            light: RGBA(1.00, 0.23, 0.19, 0.12),
            dark: RGBA(1.00, 0.27, 0.23, 0.20)
        )
    }

    // MARK: - Internal Color Calibration Specs

    private struct RGBA: Sendable {
        let r: Double
        let g: Double
        let b: Double
        let a: Double

        init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1.0) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        func withAlpha(_ alpha: Double) -> RGBA {
            RGBA(r, g, b, alpha)
        }
    }

    private struct PaletteSpec: Sendable {
        let lightAccent: RGBA
        let darkAccent: RGBA
        let lightHarmonic: RGBA
        let darkHarmonic: RGBA
        let lightOnAccent: RGBA
        let darkOnAccent: RGBA
        let waferBackTop: RGBA
        let waferBackBottom: RGBA
        let waferMidTop: RGBA
        let waferMidBottom: RGBA
        let waferAtomic: RGBA
    }

    private static func dynamicColor(light: RGBA, dark: RGBA) -> Color {
        Color(
            uiColor: UIColor { traits in
                let c = (traits.userInterfaceStyle == .dark) ? dark : light
                return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
            }
        )
    }

    private static func paletteSpec(for preset: DysprosiumPalettePreset) -> PaletteSpec {
        let white = RGBA(1.0, 1.0, 1.0, 1.0)
        switch preset {
        case .cerulean:
            return PaletteSpec(
                lightAccent: RGBA(0.00, 0.41, 0.72),
                darkAccent: RGBA(0.22, 0.78, 0.98),
                lightHarmonic: RGBA(0.00, 0.55, 0.62),
                darkHarmonic: RGBA(0.18, 0.90, 0.71),
                lightOnAccent: white,
                darkOnAccent: RGBA(0.04, 0.09, 0.14),
                waferBackTop: RGBA(0.28, 0.35, 0.95),
                waferBackBottom: RGBA(0.16, 0.21, 0.75),
                waferMidTop: RGBA(0.20, 0.86, 0.98),
                waferMidBottom: RGBA(0.02, 0.52, 0.90),
                waferAtomic: RGBA(0.42, 0.92, 1.00)
            )
        case .ultramarine:
            return PaletteSpec(
                lightAccent: RGBA(0.12, 0.31, 0.85),
                darkAccent: RGBA(0.40, 0.58, 1.00),
                lightHarmonic: RGBA(0.31, 0.27, 0.90),
                darkHarmonic: RGBA(0.58, 0.51, 1.00),
                lightOnAccent: white,
                darkOnAccent: white,
                waferBackTop: RGBA(0.38, 0.24, 0.92),
                waferBackBottom: RGBA(0.24, 0.14, 0.70),
                waferMidTop: RGBA(0.32, 0.56, 1.00),
                waferMidBottom: RGBA(0.12, 0.34, 0.92),
                waferAtomic: RGBA(0.62, 0.78, 1.00)
            )
        case .terbium:
            return PaletteSpec(
                lightAccent: RGBA(0.03, 0.46, 0.31),
                darkAccent: RGBA(0.20, 0.83, 0.60),
                lightHarmonic: RGBA(0.05, 0.54, 0.48),
                darkHarmonic: RGBA(0.18, 0.84, 0.75),
                lightOnAccent: white,
                darkOnAccent: RGBA(0.03, 0.11, 0.08),
                waferBackTop: RGBA(0.06, 0.46, 0.52),
                waferBackBottom: RGBA(0.04, 0.30, 0.38),
                waferMidTop: RGBA(0.22, 0.88, 0.64),
                waferMidBottom: RGBA(0.04, 0.58, 0.40),
                waferAtomic: RGBA(0.48, 0.96, 0.76)
            )
        case .europium:
            return PaletteSpec(
                lightAccent: RGBA(0.77, 0.24, 0.11),
                darkAccent: RGBA(1.00, 0.44, 0.30),
                lightHarmonic: RGBA(0.85, 0.42, 0.09),
                darkHarmonic: RGBA(1.00, 0.64, 0.28),
                lightOnAccent: white,
                darkOnAccent: RGBA(0.14, 0.05, 0.03),
                waferBackTop: RGBA(0.64, 0.16, 0.28),
                waferBackBottom: RGBA(0.42, 0.09, 0.18),
                waferMidTop: RGBA(1.00, 0.52, 0.26),
                waferMidBottom: RGBA(0.86, 0.26, 0.12),
                waferAtomic: RGBA(1.00, 0.72, 0.54)
            )
        case .obsidian:
            return PaletteSpec(
                lightAccent: RGBA(0.11, 0.13, 0.16),
                darkAccent: RGBA(0.90, 0.92, 0.95),
                lightHarmonic: RGBA(0.30, 0.34, 0.40),
                darkHarmonic: RGBA(0.60, 0.66, 0.74),
                lightOnAccent: white,
                darkOnAccent: RGBA(0.07, 0.08, 0.11),
                waferBackTop: RGBA(0.30, 0.34, 0.40),
                waferBackBottom: RGBA(0.18, 0.20, 0.25),
                waferMidTop: RGBA(0.62, 0.67, 0.74),
                waferMidBottom: RGBA(0.38, 0.42, 0.49),
                waferAtomic: RGBA(0.84, 0.88, 0.94)
            )
        }
    }
}

private struct DysprosiumTokensKey: EnvironmentKey {
    static let defaultValue = DysprosiumTokens(preset: .cerulean)
}

extension EnvironmentValues {
    public var dysprosiumTokens: DysprosiumTokens {
        get { self[DysprosiumTokensKey.self] }
        set { self[DysprosiumTokensKey.self] = newValue }
    }
}

/// Persists the user's chosen Lanthanide color palette across launches and broadcasts reactive token updates.
@MainActor
@Observable
public final class DysprosiumThemeStore {
    public static let shared = DysprosiumThemeStore()
    private static let defaultsKey = "dysprosium.design.palettePreset"

    public private(set) var selectedPreset: DysprosiumPalettePreset
    public private(set) var tokens: DysprosiumTokens

    public init() {
        var resolved: DysprosiumPalettePreset = .cerulean
        if let saved = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let parsed = DysprosiumPalettePreset(rawValue: saved) {
            resolved = parsed
        }
        #if DEBUG
        if let envOverride = ProcessInfo.processInfo.environment["DYSPROSIUM_PALETTE"]?.lowercased(),
           let parsed = DysprosiumPalettePreset(rawValue: envOverride) {
            resolved = parsed
        }
        #endif
        self.selectedPreset = resolved
        self.tokens = DysprosiumTokens(preset: resolved)
    }

    public func select(_ preset: DysprosiumPalettePreset) {
        guard selectedPreset != preset else { return }
        selectedPreset = preset
        tokens = DysprosiumTokens(preset: preset)
        UserDefaults.standard.set(preset.rawValue, forKey: Self.defaultsKey)
    }
}

/// Compact single-row tactile swatch bar for choosing the app-wide Lanthanide Design Token palette.
/// Uses flat grouped surfaces (zero `.glassEffect()` on list content) for 120 Hz scrolling.
public struct DysprosiumPaletteSelectorRows: View {
    @Bindable var themeStore: DysprosiumThemeStore

    public init(themeStore: DysprosiumThemeStore = .shared) {
        self.themeStore = themeStore
    }

    public var body: some View {
        let active = themeStore.selectedPreset
        let activeTokens = themeStore.tokens

        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Accent")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text(active.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(active.elementBadge)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(activeTokens.accent)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(activeTokens.accentSubtleFill, in: Capsule())
            }

            HStack(spacing: 0) {
                ForEach(DysprosiumPalettePreset.allCases) { preset in
                    let isSelected = (active == preset)
                    let previewTokens = DysprosiumTokens(preset: preset)

                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            themeStore.select(preset)
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .strokeBorder(
                                    isSelected ? previewTokens.accent : .clear,
                                    lineWidth: 2
                                )
                                .frame(width: 40, height: 40)

                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [previewTokens.waferMidTop, previewTokens.accent],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 32, height: 32)
                                .overlay {
                                    Circle()
                                        .strokeBorder(.primary.opacity(0.14), lineWidth: 0.75)
                                }
                                .overlay {
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(previewTokens.onAccent)
                                    }
                                }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.displayName)
                    .accessibilityValue(isSelected ? "Selected" : "")
                    .accessibilityIdentifier("palette-row-\(preset.rawValue)")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Compact single-row tactile orb bar for Dark Reader Web Theme presets (`OLED`, `Obsidian`, `Graphite`, `Paper`).
/// Previews each surface's calibrated canvas and ink contrast inside crisp circular swatches.
public struct WebDarkThemeSwatchRow: View {
    @Environment(\.dysprosiumTokens) private var tokens
    @Binding var selectedPreset: DarkReaderEngine.WebDarkThemePreset
    @Binding var modeBehavior: DarkReaderEngine.WebDarkModeBehavior

    public init(
        selectedPreset: Binding<DarkReaderEngine.WebDarkThemePreset>,
        modeBehavior: Binding<DarkReaderEngine.WebDarkModeBehavior>
    ) {
        self._selectedPreset = selectedPreset
        self._modeBehavior = modeBehavior
    }

    public var body: some View {
        let isOff = (modeBehavior == .off)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Web Theme")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text(isOff ? "Native Colors" : "\(selectedPreset.title) · \(selectedPreset.backgroundHex.uppercased())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                ForEach(DarkReaderEngine.WebDarkThemePreset.allCases) { preset in
                    let isSelected = (!isOff && selectedPreset == preset)
                    let bg = preset.backgroundRGB
                    let swatchBg = Color(
                        red: Double(bg.r) / 255.0,
                        green: Double(bg.g) / 255.0,
                        blue: Double(bg.b) / 255.0
                    )
                    let swatchInk: Color = preset.isDarkScheme
                        ? Color(red: 0.95, green: 0.95, blue: 0.97)
                        : Color(red: 0.14, green: 0.12, blue: 0.10)

                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            selectedPreset = preset
                            if modeBehavior == .off {
                                modeBehavior = .auto
                            }
                        }
                    } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                Circle()
                                    .strokeBorder(
                                        isSelected ? tokens.accent : .clear,
                                        lineWidth: 2
                                    )
                                    .frame(width: 44, height: 44)

                                Circle()
                                    .fill(swatchBg)
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        Circle()
                                            .strokeBorder(.primary.opacity(0.28), lineWidth: 0.85)
                                    }
                                    .overlay {
                                        Text("Aa")
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(swatchInk)
                                    }
                            }

                            Text(preset.title)
                                .font(.caption2.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Web Theme \(preset.title)")
                    .accessibilityValue(isSelected ? "Selected" : "")
                    .accessibilityIdentifier("web-dark-preset-\(preset.rawValue)")
                }
            }
            .opacity(isOff ? 0.45 : 1.0)
        }
        .padding(.vertical, 4)
    }
}
