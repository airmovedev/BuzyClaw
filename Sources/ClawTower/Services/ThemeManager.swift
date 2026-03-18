import SwiftUI

// MARK: - ThemeManager

@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    /// Default theme color: #E8845C (warm coral)
    static let defaultColor = Color(red: 232 / 255, green: 132 / 255, blue: 92 / 255)

    /// Preset swatches for the color picker
    static let presets: [Color] = [
        Color(red: 232 / 255, green: 132 / 255, blue: 92 / 255),  // #E8845C coral (default)
        Color(red: 0.0, green: 0.48, blue: 1.0),                   // system blue
        Color(red: 0.67, green: 0.33, blue: 0.85),                 // purple
        Color(red: 0.2, green: 0.78, blue: 0.35),                  // green
        Color(red: 1.0, green: 0.58, blue: 0.0),                   // orange
        Color(red: 0.95, green: 0.26, blue: 0.36),                 // red/pink
        Color(red: 0.0, green: 0.74, blue: 0.68),                  // teal
    ]

    var themeColor: Color {
        didSet { persistColor(themeColor) }
    }

    private init() {
        self.themeColor = Self.loadPersistedColor() ?? Self.defaultColor
    }

    func reset() {
        themeColor = Self.defaultColor
    }

    // MARK: - Persistence

    private func persistColor(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else { return }
        r = nsColor.redComponent
        g = nsColor.greenComponent
        b = nsColor.blueComponent
        a = nsColor.alphaComponent
        #else
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        UserDefaults.standard.set([r, g, b, a] as [CGFloat], forKey: "themeColorComponents")
    }

    private static func loadPersistedColor() -> Color? {
        guard let components = UserDefaults.standard.array(forKey: "themeColorComponents") as? [CGFloat],
              components.count == 4 else { return nil }
        return Color(red: components[0], green: components[1], blue: components[2], opacity: components[3])
    }
}

// MARK: - Environment Key

private struct ThemeColorKey: EnvironmentKey {
    // Use literal color to avoid referencing @MainActor ThemeManager from nonisolated context
    static let defaultValue: Color = Color(red: 232 / 255, green: 132 / 255, blue: 92 / 255)
}

extension EnvironmentValues {
    var themeColor: Color {
        get { self[ThemeColorKey.self] }
        set { self[ThemeColorKey.self] = newValue }
    }
}
