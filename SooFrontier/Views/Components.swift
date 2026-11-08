import SwiftUI

/// SooFrontier's editorial design language: serif headlines, small-caps labels, one ink accent.
/// SooFrontier's editorial design language, adjustable in Settings → Appearance.
@MainActor enum Theme {
    static var accent: Color { Appearance.current.accent.color }
    static let readingWidth: CGFloat = 680
    static var design: Font.Design { Appearance.current.font == .serif ? .serif : .default }

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        // Scales with the chosen text size (fixed point sizes don't follow Dynamic Type on their own).
        .system(size: size * Appearance.current.textSize.scale, weight: weight, design: design)
    }

    #if os(macOS)
    // macOS has no Dynamic Type, so reading text scales by hand.
    static var headline: Font { .system(size: 16 * Appearance.current.textSize.scale, weight: .semibold, design: design) }
    static var body: Font { .system(size: 14 * Appearance.current.textSize.scale, design: design) }
    #else
    static var headline: Font { .system(.title3, design: design, weight: .semibold) }
    static var body: Font { .system(.body, design: design) }
    #endif
}

extension View {
    /// Small-caps style label used above headlines and sections.
    func eyebrow(_ color: Color = .secondary) -> some View {
        font(.caption2.weight(.semibold)).tracking(1.1).textCase(.uppercase).foregroundStyle(color)
    }

    @ViewBuilder func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// Section heading: label + hairline rule.
struct SectionRule: View {
    var title: String
    var trailing: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).eyebrow(.primary)
                Spacer()
                if let trailing { Text(trailing).eyebrow() }
            }
            Rectangle().fill(.primary.opacity(0.85)).frame(height: 1.5)
        }
    }
}

/// Lightweight block Markdown: headings, bullets, numbered lists, and inline styling.
struct MarkdownText: View {
    var text: String
    var serif = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw)
            }
        }
        .font(serif ? Theme.body : .body)
        .lineSpacing(serif ? 3 : 1)
        .textSelection(.enabled)
    }

    @ViewBuilder private func line(_ raw: String) -> some View {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            Spacer().frame(height: 2)
        } else if t.hasPrefix("#") {
            inline(t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                .font(Theme.headline).padding(.top, 6)
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("—").foregroundStyle(.tertiary)
                inline(String(t.dropFirst(2)))
            }
            .padding(.leading, raw.hasPrefix("  ") ? 18 : 0)
        } else {
            inline(t)
        }
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s))
    }
}

/// Quiet agent mark with a soft pulse while the agent works.
struct AgentBadge: View {
    var kind: AgentKind
    var status: AgentStatus
    var size: CGFloat = 34
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(kind.color.opacity(0.12))
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(kind.color)
            if status.isWorking {
                Circle().stroke(kind.color.opacity(0.6), lineWidth: 1.5)
                    .scaleEffect(pulse ? 1.35 : 1).opacity(pulse ? 0 : 1)
                    .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
                    .onDisappear { pulse = false }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Verdict + a slim signal-vs-hype rule.
struct SignalMeter: View {
    var assessment: Assessment

    private var position: CGFloat { CGFloat(max(0.03, min(0.97, 0.5 + (assessment.signal - assessment.hype) / 2))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(assessment.verdict).font(Theme.headline)
                Spacer()
                Text("Signal \(Int(assessment.signal * 100))  ·  Hype \(Int(assessment.hype * 100))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 3)
                    Capsule().fill(assessment.verdictColor).frame(width: g.size.width * position, height: 3)
                    Circle().fill(assessment.verdictColor).frame(width: 9, height: 9)
                        .offset(x: g.size.width * position - 4.5)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)
            HStack {
                Text("Hype").eyebrow()
                Spacer()
                Text("Signal").eyebrow()
            }
        }
    }
}

/// Lane + source line shown above every headline.
struct ItemEyebrow: View {
    var item: FrontierItem
    var showLane = true

    private var label: String {
        var parts: [String] = []
        if showLane { parts.append(item.category.title) }
        if item.category == .voices, let name = item.author, !name.isEmpty { parts.append(name) }
        parts.append(item.source)
        if item.category == .voices, let role = item.tags.first { parts.append(role) }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(item.category.tint).frame(width: 6, height: 6)
            Text(label).eyebrow()
                .lineLimit(1)
        }
    }
}

struct ItemRow: View {
    var item: FrontierItem
    var saved: Bool
    var showLane = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                ItemEyebrow(item: item, showLane: showLane)
                Spacer(minLength: 8)
                if let d = item.date {
                    Text(d, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(item.title)
                .font(Theme.headline)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                if let t = item.tractionLabel { Text(t).monospacedDigit() }
                if let a = item.assessment {
                    HStack(spacing: 4) {
                        Circle().fill(a.verdictColor).frame(width: 5, height: 5)
                        Text(a.verdict)
                    }
                }
                Spacer(minLength: 0)
                if saved { Image(systemName: "bookmark.fill").foregroundStyle(Theme.accent) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(.vertical, 10)
    }
}

/// Renders content in SooFrontier's house structure: TL;DR, Takeaways, Potential opportunities.
/// Falls back to plain Markdown for text that doesn't follow it (for example, older cached briefs).
struct StructuredText: View {
    var text: String

    var body: some View {
        if let p = Structure.parse(text) {
            StructuredSections(tldr: Text(markdown: p.tldr), takeaways: p.takeaways.map { Text(markdown: $0) },
                               math: p.math, opportunities: p.opportunities.map { Text(markdown: $0) })
        } else {
            MarkdownText(text: text, serif: true)
        }
    }
}

/// The three-part layout, usable with generated or locally assembled content.
struct StructuredSections<Extra: View>: View {
    var tldr: Text
    var takeaways: [Text]
    var math: [String]
    var opportunities: [Text]
    var opportunitiesLoading = false
    var takeawaysHeader: Extra

    init(tldr: Text, takeaways: [Text], math: [String] = [], opportunities: [Text], opportunitiesLoading: Bool = false,
         @ViewBuilder takeawaysHeader: () -> Extra = { EmptyView() }) {
        self.opportunitiesLoading = opportunitiesLoading
        self.tldr = tldr
        self.takeaways = takeaways
        self.math = math
        self.opportunities = opportunities
        self.takeawaysHeader = takeawaysHeader()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TL;DR").eyebrow(Theme.accent)
                tldr
                    .font(.system(.title3, design: Theme.design, weight: .medium))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3) }

            if !takeaways.isEmpty || !(takeawaysHeader is EmptyView) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionRule(title: "Takeaways")
                    takeawaysHeader
                    ForEach(Array(takeaways.enumerated()), id: \.offset) { i, t in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(String(format: "%02d", i + 1))
                                .font(Theme.display(15, weight: .regular)).foregroundStyle(.tertiary).monospacedDigit()
                            t.font(Theme.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !math.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionRule(title: "Mathematical analysis")
                    ForEach(Array(math.enumerated()), id: \.offset) { _, line in MathLine(text: line) }
                }
            }

            if opportunitiesLoading {
                VStack(alignment: .leading, spacing: 12) {
                    SectionRule(title: "Potential opportunities")
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Writing ideas for this story (about 30 s)").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            if !opportunities.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionRule(title: "Potential opportunities")
                    ForEach(Array(opportunities.enumerated()), id: \.offset) { _, u in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "lightbulb").font(.callout).foregroundStyle(Theme.accent)
                            u.font(Theme.body).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}

extension Text {
    /// Inline Markdown (bold, italics, links) for a single line.
    init(markdown s: String) {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        self.init((try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s))
    }
}

/// One line of the Mathematical analysis: a display equation when the whole line is `in backticks`, prose otherwise.
struct MathLine: View {
    var text: String

    private var equation: String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count > 2, t.hasPrefix("`"), t.hasSuffix("`"), t.dropFirst().dropLast().contains("`") == false else { return nil }
        return Self.tidy(String(t.dropFirst().dropLast()))
    }

    /// Turns leftover LaTeX-style subscripts (E_{x~p}, E_c) into readable small text.
    static func tidy(_ eq: String) -> String {
        var out = eq.replacingOccurrences(of: "_\\{([^}]*)\\}", with: "[$1]", options: .regularExpression)
        let sub: [Character: Character] = ["0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇",
                                           "8": "₈", "9": "₉", "a": "ₐ", "c": "꜀", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "t": "ₜ",
                                           "x": "ₓ", "n": "ₙ", "m": "ₘ", "r": "ᵣ", "s": "ₛ", "p": "ₚ", "o": "ₒ", "l": "ₗ"]
        while let r = out.range(of: "_[0-9aceijktxnmrspol](?![A-Za-z0-9])", options: .regularExpression) {
            let c = out[out.index(after: r.lowerBound)]
            out.replaceSubrange(r, with: String(sub[c] ?? c))
        }
        return out
    }

    var body: some View {
        if let equation {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(equation)
                    .font(.system(.body, design: Theme.design).italic())
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .textSelection(.enabled)
        } else {
            Text(markdown: text)
                .font(Theme.body).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "SooFrontier <Tab>" in the icon's own colors: ivory "Soo", gold "Frontier", on the icon's navy.
struct BrandMark: View {
    var section: String

    static let navy = LinearGradient(colors: [Color(red: 0.06, green: 0.12, blue: 0.21), Color(red: 0.09, green: 0.24, blue: 0.29)],
                                     startPoint: .leading, endPoint: .trailing)
    static let ivory = Color(red: 0xE8 / 255, green: 0xDB / 255, blue: 0xCE / 255)
    static let gold = LinearGradient(colors: [Color(red: 0xE8 / 255, green: 0xC1 / 255, blue: 0x8B / 255),
                                              Color(red: 0xE2 / 255, green: 0xB4 / 255, blue: 0x74 / 255)],
                                     startPoint: .leading, endPoint: .trailing)

    var body: some View {
        HStack(spacing: 8) {
            Image("BrandMark")
                .resizable()
                .scaledToFill()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 0) {
                Text("Soo").foregroundStyle(Self.ivory)
                Text("Frontier").foregroundStyle(Self.gold)
                Text(" " + section).foregroundStyle(.white)
            }
            .font(.system(.headline, design: Theme.design, weight: .semibold))
            .fixedSize()
        }
        .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 4)
        .background(Self.navy, in: Capsule())
        .overlay(Capsule().stroke(Self.ivory.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("SooFrontier \(section)")
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Shows "SooFrontier <Tab>" in the top bar in place of the plain title.
    func brandToolbar(_ section: String) -> some View {
        modifier(BrandTitle(section: section))
    }
}

private struct BrandTitle: ViewModifier {
    var section: String
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { BrandMark(section: section) }
                // On iPhone, Settings lives here instead of the tab bar.
                if sizeClass == .compact && section != "Settings" {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
                    }
                }
                // Hide the plain inline title; the brand mark replaces it.
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            }
        #else
        content.toolbar { ToolbarItem(placement: .navigation) { BrandMark(section: section) } }
        #endif
    }
}
