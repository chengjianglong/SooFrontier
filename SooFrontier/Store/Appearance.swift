import SwiftUI

/// Reading appearance: text size, light/dark theme, accent colour, and reading font.
@MainActor @Observable
final class Appearance {
    /// The live settings, read by `Theme` while views are drawn.
    static let current = Appearance()

    enum TextSize: String, CaseIterable, Identifiable {
        case small, medium, large, xLarge, xxLarge
        var id: String { rawValue }
        var label: String {
            switch self {
            case .small: "Small"
            case .medium: "Default"
            case .large: "Large"
            case .xLarge: "Extra large"
            case .xxLarge: "Huge"
            }
        }
        var dynamicType: DynamicTypeSize {
            switch self {
            case .small: .small
            case .medium: .large
            case .large: .xLarge
            case .xLarge: .xxLarge
            case .xxLarge: .xxxLarge
            }
        }
        /// For fixed-size headlines and for macOS, which has no Dynamic Type.
        var scale: CGFloat {
            switch self {
            case .small: 0.9
            case .medium: 1
            case .large: 1.12
            case .xLarge: 1.25
            case .xxLarge: 1.4
            }
        }
    }

    enum ColorTheme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var scheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum Accent: String, CaseIterable, Identifiable {
        case ink, teal, gold, rose
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        /// Each accent has a deeper tone for light backgrounds and a brighter one for dark.
        var color: Color {
            switch self {
            case .ink: .adaptive(light: (0.23, 0.26, 0.60), dark: (0.56, 0.62, 0.98))
            case .teal: .adaptive(light: (0.06, 0.45, 0.45), dark: (0.45, 0.85, 0.80))
            case .gold: .adaptive(light: (0.62, 0.43, 0.10), dark: (0.91, 0.76, 0.48))
            case .rose: .adaptive(light: (0.68, 0.20, 0.32), dark: (0.98, 0.56, 0.64))
            }
        }
    }

    enum ReadingFont: String, CaseIterable, Identifiable {
        case serif, sans
        var id: String { rawValue }
        var label: String { self == .serif ? "Serif" : "Sans serif" }
    }

    var textSize: TextSize { didSet { save() } }
    var theme: ColorTheme { didSet { save() } }
    var accent: Accent { didSet { save() } }
    var font: ReadingFont { didSet { save() } }

    /// Changes whenever a setting that `Theme` reads changes, so the view tree can refresh.
    var signature: String { "\(textSize.rawValue)-\(accent.rawValue)-\(font.rawValue)" }

    private init() {
        let d = UserDefaults.standard
        textSize = d.string(forKey: "appearance.textSize").flatMap(TextSize.init) ?? .medium
        theme = d.string(forKey: "appearance.theme").flatMap(ColorTheme.init) ?? .system
        accent = d.string(forKey: "appearance.accent").flatMap(Accent.init) ?? .ink
        font = d.string(forKey: "appearance.font").flatMap(ReadingFont.init) ?? .serif
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(textSize.rawValue, forKey: "appearance.textSize")
        d.set(theme.rawValue, forKey: "appearance.theme")
        d.set(accent.rawValue, forKey: "appearance.accent")
        d.set(font.rawValue, forKey: "appearance.font")
    }
}

extension Color {
    /// A colour with separate light- and dark-mode values.
    static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if os(iOS)
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1)
            : UIColor(red: light.0, green: light.1, blue: light.2, alpha: 1) })
        #else
        Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1)
            : NSColor(red: light.0, green: light.1, blue: light.2, alpha: 1) })
        #endif
    }
}

extension View {
    /// Applies the chosen theme, text size, and accent to everything below.
    func appearance(_ a: Appearance) -> some View {
        self
            .preferredColorScheme(a.theme.scheme)
            .tint(a.accent.color)
            #if os(iOS)
            .dynamicTypeSize(a.textSize.dynamicType)
            #endif
            // Theme's colour and fonts are read while drawing; rebuild the tree when they change.
            .id(a.signature)
    }
}

/// Wraps the app so it redraws with the current appearance whenever a setting changes.
struct Themed<Content: View>: View {
    @ViewBuilder var content: Content
    private var a = Appearance.current

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View { content.appearance(a) }
}

/// Settings → Appearance.
struct AppearanceSection: View {
    @Bindable private var a = Appearance.current

    var body: some View {
        Section {
            Picker("Text size", selection: $a.textSize) {
                ForEach(Appearance.TextSize.allCases) { Text($0.label).tag($0) }
            }
            Picker("Theme", selection: $a.theme) {
                ForEach(Appearance.ColorTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Accent colour", selection: $a.accent) {
                ForEach(Appearance.Accent.allCases) { accent in
                    Label { Text(accent.label) } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(accent.color)
                    }
                    .tag(accent)
                }
            }
            Picker("Reading font", selection: $a.font) {
                ForEach(Appearance.ReadingFont.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview").eyebrow(Theme.accent)
                Text("Intrinsic Distribution Matching").font(Theme.headline)
                Text("One-step and few-step text-to-image generation must accurately render the details in the prompt.")
                    .font(Theme.body).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Label("Appearance", systemImage: "textformat.size")
        }
    }
}
