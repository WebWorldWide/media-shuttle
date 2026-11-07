import AppKit
import SwiftUI

// MARK: - Palette

/// Design tokens taken from the Media Shuttle design document. The mock is
/// dark-only; each token carries a light counterpart so the appearance setting
/// keeps working. Geometry is deliberately square — the design uses 1px
/// hairlines and hard corners throughout, not rounded cards.
enum Theme {
    static let windowBackground = adaptive(light: 0xF0F0F2, dark: 0x0B0B0C)
    static let chromeBackground = adaptive(light: 0xE8E8EA, dark: 0x101012)
    static let contentBackground = adaptive(light: 0xFFFFFF, dark: 0x161618)
    static let sidebarBackground = adaptive(light: 0xF7F7F8, dark: 0x121214)
    static let panelBackground = adaptive(light: 0xFBFBFC, dark: 0x1A1A1D)
    static let panelFooterBackground = adaptive(light: 0xF4F4F6, dark: 0x17171A)

    static let textPrimary = adaptive(light: 0x1B1B1E, dark: 0xF0F1F2)
    static let textBright = adaptive(light: 0x2A2C30, dark: 0xD6DADE)
    static let textSecondary = adaptive(light: 0x4A4E54, dark: 0xB9BEC4)
    static let textMuted = adaptive(light: 0x6D7279, dark: 0x8B9198)
    static let textLabel = adaptive(light: 0x6D7279, dark: 0x949AA1)

    /// The app mark's palette. The card stays in the dark family in both themes —
    /// lightened for dark chrome rather than inverted to white, which would turn the
    /// logo inside out. Glass and rims never change: the glass always sits on the
    /// yellow body, the rims always on the tyre.
    static let shuttleYellow = adaptive(light: 0xF0B800, dark: 0xFFD016)
    static let shuttleCard = adaptive(light: 0x14161B, dark: 0x3E4450)
    static let shuttleTyre = adaptive(light: 0x0E1015, dark: 0x2F353F)
    static let shuttleGlass = adaptive(light: 0x12151C, dark: 0x12151C)
    static let shuttleRim = adaptive(light: 0xC9CED6, dark: 0xC9CED6)

    static let accent = adaptive(light: 0xD32F26, dark: 0xE8433A)
    static let accentBright = adaptive(light: 0xC42B1C, dark: 0xFF6A5E)
    static let verified = adaptive(light: 0x2F9E5F, dark: 0x5FD08A)
    static let caution = adaptive(light: 0xB7791F, dark: 0xE0A340)

    static let hairline = Color.primary.opacity(0.12)
    static let hairlineSoft = Color.primary.opacity(0.07)
    static let fill = Color.primary.opacity(0.04)
    static let fillStrong = Color.primary.opacity(0.09)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * 1.3, weight: weight, design: .monospaced)
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

extension AppStatusTone {
    var color: Color {
        switch self {
        case .neutral: Theme.textMuted
        case .active: Theme.textBright
        case .verified: Theme.verified
        case .warning: Theme.caution
        case .error: Theme.accent
        }
    }
}

extension BannerTone {
    var color: Color {
        switch self {
        case .info: Theme.textBright
        case .success: Theme.verified
        case .warning: Theme.caution
        case .error: Theme.accent
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }
}

// MARK: - Primitives

/// Small letterspaced monospace caps used to head every region of the layout.
struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.mono(9.5, .semibold))
            .tracking(1.3)
            .foregroundStyle(Theme.textLabel)
    }
}

/// A 1px rule. `Divider()` carries its own inset and color on macOS, which
/// reads too heavy against this palette.
struct Hairline: View {
    var color: Color = Theme.hairline

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
    }
}

/// Flat bordered surface — the design's only container treatment.
struct PanelBox: ViewModifier {
    var background: Color = Theme.panelBackground
    var border: Color = Theme.hairline

    func body(content: Content) -> some View {
        content
            .background(background)
            .overlay(Rectangle().strokeBorder(border, lineWidth: 1))
    }
}

extension View {
    func panelBox(background: Color = Theme.panelBackground, border: Color = Theme.hairline) -> some View {
        modifier(PanelBox(background: background, border: border))
    }
}

// MARK: - Buttons

enum ShuttleButtonKind {
    case secondary
    case primary
    case destructive
}

/// Square, compact buttons with an explicit hover state, matching the mock's
/// `style-hover` rules. macOS's stock button shapes are too tall and too round
/// for this layout.
struct ShuttleButtonStyle: ButtonStyle {
    var kind: ShuttleButtonKind = .secondary
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, kind: kind, fullWidth: fullWidth)
    }

    private struct Surface: View {
        let configuration: Configuration
        let kind: ShuttleButtonKind
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        private var isActive: Bool { isHovering && isEnabled }

        private var foreground: Color {
            switch kind {
            case .secondary:
                Theme.textBright
            case .primary:
                Theme.contentBackground
            case .destructive:
                isActive ? .white : Theme.accentBright
            }
        }

        private var background: Color {
            switch kind {
            case .secondary:
                isActive ? Theme.fillStrong : Theme.fill
            case .primary:
                isActive ? Theme.textPrimary : Theme.textBright
            case .destructive:
                isActive ? Theme.accent : Theme.accent.opacity(0.1)
            }
        }

        private var border: Color {
            switch kind {
            case .secondary:
                isActive ? Theme.primaryBorderStrong : Theme.primaryBorder
            case .primary:
                .clear
            case .destructive:
                Theme.accent.opacity(isActive ? 1 : 0.5)
            }
        }

        var body: some View {
            configuration.label
                .font(Theme.mono(10.5, kind == .secondary ? .regular : .semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(background)
                .overlay(Rectangle().strokeBorder(border, lineWidth: 1))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isActive)
        }
    }
}

extension Theme {
    static let primaryBorder = Color.primary.opacity(0.18)
    static let primaryBorderStrong = Color.primary.opacity(0.3)
}

// MARK: - Toggles

/// The app's switch: a square track and square knob in the button palette. On is the primary
/// button's light fill, off is the secondary button's tint, so a switch reads as the same family
/// as every button beside it. The stock rounded switch was the one control in the window that
/// did not.
struct ShuttleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            HStack(spacing: 10) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                ShuttleSwitch(isOn: configuration.isOn, isHovering: isHovering && isEnabled)
            }
            .contentShape(Rectangle())
            .onTapGesture { configuration.isOn.toggle() }
            .onHover { isHovering = $0 }
            .opacity(isEnabled ? 1 : 0.38)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

struct ShuttleSwitch: View {
    let isOn: Bool
    var isHovering = false

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Rectangle()
                .fill(isOn ? Theme.textBright : (isHovering ? Theme.fillStrong : Theme.fill))
            Rectangle()
                .fill(isOn ? Theme.contentBackground : Theme.textMuted)
                .frame(width: 10, height: 10)
                .padding(3)
        }
        .frame(width: 32, height: 16)
        .overlay(
            Rectangle().strokeBorder(
                isOn ? Color.clear : (isHovering ? Theme.primaryBorderStrong : Theme.primaryBorder),
                lineWidth: 1
            )
        )
        .animation(.easeOut(duration: 0.12), value: isOn)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Square checkbox in the same palette, with the success banner's check mark.
struct ShuttleCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            ZStack {
                Rectangle()
                    .fill(configuration.isOn ? Theme.textBright : Theme.fill)
                Rectangle()
                    .strokeBorder(configuration.isOn ? Color.clear : Theme.primaryBorder, lineWidth: 1)
                if configuration.isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(Theme.contentBackground)
                }
            }
            .frame(width: 14, height: 14)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            configuration.label
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// Segmented choice built from the button palette: the selected segment takes the primary fill.
struct ShuttleSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.value == selection
                Button(option.title) { selection = option.value }
                    .buttonStyle(Segment(selected: selected))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                if index < options.count - 1 {
                    Rectangle().fill(Theme.primaryBorder).frame(width: 1)
                }
            }
        }
        .frame(height: 28)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(Rectangle().strokeBorder(Theme.primaryBorder, lineWidth: 1))
    }

    private struct Segment: ButtonStyle {
        let selected: Bool

        func makeBody(configuration: Configuration) -> some View {
            Surface(configuration: configuration, selected: selected)
        }

        private struct Surface: View {
            let configuration: Configuration
            let selected: Bool
            @State private var isHovering = false

            var body: some View {
                configuration.label
                    .font(Theme.mono(10, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.contentBackground : Theme.textBright)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(selected ? Theme.textBright : (isHovering ? Theme.fillStrong : Theme.fill))
                    .contentShape(Rectangle())
                    .onHover { isHovering = $0 }
                    .opacity(configuration.isPressed ? 0.75 : 1)
            }
        }
    }
}

extension Bundle {
    /// True only when running from a real .app bundle. `swift run` produces a
    /// bare executable, where Info.plist keys such as `CFBundleIconFile` are
    /// inert and `UNUserNotificationCenter.current()` raises
    /// `NSInternalInconsistencyException` rather than returning a center.
    static var isPackagedApp: Bool {
        main.bundleIdentifier != nil
    }
}

extension ByteCountFormatter {
    /// Shared formatter. The default spells zero as "Zero KB", which reads as a
    /// glitch in the metric row.
    @MainActor
    private static let shuttle: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    @MainActor
    static func shuttleString(_ bytes: Int64) -> String {
        shuttle.string(fromByteCount: max(0, bytes))
    }
}

/// Borderless square icon button for the window chrome.
struct ChromeIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 15))
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textMuted)
                .frame(width: 32, height: 32)
                .background(isHovering ? Theme.fillStrong : .clear)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { isHovering = $0 }
        }
    }
}
