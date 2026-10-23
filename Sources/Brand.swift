import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Anthropic's warm palette: book cloth, kraft, manilla and friends.
enum Brand {
    static let clay = NSColor(hex: 0xD97757)       // Claude's accent
    static let bookCloth = NSColor(hex: 0xCC785C)
    static let kraft = NSColor(hex: 0xD4A27F)
    static let manilla = NSColor(hex: 0xEBDBBC)

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static let card = dynamic(light: NSColor(hex: 0xF4F1E8), dark: NSColor(hex: 0x2B2522))
    static let cardStroke = dynamic(light: NSColor(hex: 0xE0D8C5), dark: NSColor(hex: 0x3C332D))
    static let track = dynamic(light: NSColor(hex: 0xE4DCC8), dark: NSColor(hex: 0x3E342E))
    static let hairline = dynamic(light: NSColor(hex: 0xE0D8C5), dark: NSColor(hex: 0x3C332D))
    static let ink = dynamic(light: NSColor(hex: 0x241F1B), dark: NSColor(hex: 0xF2EEE7))
    static let inkSubtle = dynamic(light: NSColor(hex: 0x8B8170), dark: NSColor(hex: 0xA79B8C))

    /// Serif face (New York) for the headline and the big numbers — the
    /// typographic half of Anthropic's look.
    static func serif(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif),
              let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }
}

/// How much headroom is left, and the warm colours that go with it.
enum Severity {
    case normal, low, critical

    init(percentLeft: Double) {
        if percentLeft <= 5 { self = .critical }
        else if percentLeft <= 20 { self = .low }
        else { self = .normal }
    }

    /// Meter fill, drawn as a gradient from the lighter to the deeper tone.
    var gradient: (NSColor, NSColor) {
        switch self {
        case .normal: return (Brand.kraft, Brand.bookCloth)
        case .low: return (NSColor(hex: 0xE7B45A), NSColor(hex: 0xD9892B))
        case .critical: return (NSColor(hex: 0xD2573F), NSColor(hex: 0xB3322A))
        }
    }

    /// Colour of the big percentage.
    var textColor: NSColor {
        switch self {
        case .normal: return Brand.dynamic(light: NSColor(hex: 0xB05B38), dark: NSColor(hex: 0xE2957A))
        case .low: return Brand.dynamic(light: NSColor(hex: 0x95600F), dark: NSColor(hex: 0xE8AE5E))
        case .critical: return Brand.dynamic(light: NSColor(hex: 0xA62D1D), dark: NSColor(hex: 0xF08A72))
        }
    }

    /// The menu bar sits on its own background, so these are fixed mid-tones
    /// that stay legible on a light or a dark bar.
    var menuBarColor: NSColor {
        switch self {
        case .normal: return Brand.clay
        case .low: return NSColor(hex: 0xD9892B)
        case .critical: return NSColor(hex: 0xC8402C)
        }
    }
}
