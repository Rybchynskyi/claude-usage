import AppKit

/// Claude's starburst, drawn as tapered rays so it stays crisp at menu bar size.
enum ClaudeMark {
    /// Pass `color: nil` for a template image that follows the menu bar's own colour.
    /// `badge: true` adds the dot that marks "sleep is being held off".
    static func image(size: CGFloat = 15, color: NSColor? = Brand.clay,
                      badge: Bool = false) -> NSImage {
        // Ray lengths alternate long/short, the way the Claude mark does.
        let lengths: [CGFloat] = [1.0, 0.78, 0.93, 0.72, 1.0, 0.75, 0.9, 0.72, 0.97, 0.76, 0.88]
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            (color ?? .labelColor).setFill()
            // The badge needs a corner, so the star shrinks to make room for it.
            let center = badge
                ? CGPoint(x: rect.midX - rect.width * 0.08, y: rect.midY - rect.height * 0.08)
                : CGPoint(x: rect.midX, y: rect.midY)
            let outer = (rect.width / 2 - 0.5) * (badge ? 0.84 : 1)
            let inner: CGFloat = 0          // rays meet in the middle, no hole
            let baseHalf = outer * 0.15
            let tipHalf = outer * 0.045

            for (index, length) in lengths.enumerated() {
                let angle = CGFloat(index) / CGFloat(lengths.count) * 2 * .pi + .pi / 2
                let along = CGPoint(x: cos(angle), y: sin(angle))
                let across = CGPoint(x: -along.y, y: along.x)
                let tipDistance = outer * length

                func point(_ distance: CGFloat, _ offset: CGFloat) -> CGPoint {
                    CGPoint(x: center.x + along.x * distance + across.x * offset,
                            y: center.y + along.y * distance + across.y * offset)
                }

                let path = NSBezierPath()
                path.move(to: point(inner, -baseHalf))
                path.line(to: point(inner, baseHalf))
                path.line(to: point(tipDistance, tipHalf))
                path.line(to: point(tipDistance, -tipHalf))
                path.close()
                path.fill()
            }

            if badge {
                let diameter = rect.width * 0.30
                let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter,
                                 width: diameter, height: diameter)
                // Punch a gap first, so the dot reads as separate from the rays.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.2, dy: -1.2)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                (color ?? .labelColor).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = (color == nil)
        return image
    }
}

/// The whole dropdown panel — header, limit meters and the credits line — drawn
/// as one card. A single view rather than a stack of menu items, because AppKit
/// dims text inside non-clickable menu items and leaves no room for a layout.
final class UsagePanelView: NSView {
    struct Row {
        let name: String
        let primary: String      // percentage left
        let secondary: String
        let fraction: Double     // used, 0...1
        let severity: Severity
    }

    struct Footer {
        let title: String
        let detail: String
        let trailing: String
    }

    private let badge: String?
    private let rows: [Row]
    private let footer: Footer?
    private let message: String?

    // Layout constants, shared by `height(…)` and `draw(_:)`.
    private static let width: CGFloat = 304
    private static let margin: CGFloat = 6        // gap between card and menu edge
    // The menu adds its own padding above the first item, so the card's own top
    // inset is trimmed to keep the gap visually equal to the sides.
    private static let topMargin: CGFloat = 1
    private static let padding: CGFloat = 16      // card's inner padding
    private static let headerHeight: CGFloat = 22
    private static let headerGap: CGFloat = 15
    private static let rowHeight: CGFloat = 50
    private static let rowGap: CGFloat = 15
    private static let footerHeight: CGFloat = 34

    init(badge: String?, rows: [Row], footer: Footer?, message: String? = nil) {
        self.badge = badge
        self.rows = rows
        self.footer = footer
        self.message = message
        let height = Self.height(rows: rows.count, hasFooter: footer != nil, hasMessage: message != nil)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private static func height(rows: Int, hasFooter: Bool, hasMessage: Bool) -> CGFloat {
        var height = topMargin + margin + padding * 2 + headerHeight
        if rows > 0 {
            height += headerGap + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap
        }
        if hasMessage { height += headerGap + 34 }
        if hasFooter { height += rowGap + footerHeight }
        return height
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSRect(x: Self.margin, y: Self.topMargin,
                          width: bounds.width - Self.margin * 2,
                          height: bounds.height - Self.topMargin - Self.margin)
        let shape = NSBezierPath(roundedRect: card, xRadius: 11, yRadius: 11)
        Brand.card.setFill()
        shape.fill()
        Brand.cardStroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let left = card.minX + Self.padding
        let right = card.maxX - Self.padding
        var y = card.minY + Self.padding

        drawHeader(left: left, right: right, y: y)
        y += Self.headerHeight

        if let message {
            y += Self.headerGap
            draw(message, font: .systemFont(ofSize: 12), color: Brand.inkSubtle,
                 at: NSPoint(x: left, y: y), width: right - left)
            return
        }

        for row in rows {
            y += Self.rowGap
            draw(row: row, left: left, right: right, y: y)
            y += Self.rowHeight
        }
        // The first row sits closer to the header than rows sit to each other.
        // (headerGap and rowGap are the same, so nothing to correct here.)

        if let footer {
            y += Self.rowGap - 6
            Brand.hairline.setFill()
            NSRect(x: left, y: y, width: right - left, height: 1).fill()
            y += 11
            draw(footer.title, font: .systemFont(ofSize: 12, weight: .medium),
                 color: Brand.ink, at: NSPoint(x: left, y: y))
            let trailing = NSAttributedString(string: footer.trailing, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: Brand.inkSubtle,
            ])
            trailing.draw(at: NSPoint(x: right - trailing.size().width, y: y - 1))
            draw(footer.detail, font: .systemFont(ofSize: 10.5), color: Brand.inkSubtle,
                 at: NSPoint(x: left, y: y + 16))
        }
    }

    private func drawHeader(left: CGFloat, right: CGFloat, y: CGFloat) {
        let mark = ClaudeMark.image(size: 17, color: Brand.clay)
        mark.draw(in: NSRect(x: left, y: y + 1, width: 17, height: 17))

        let title = NSAttributedString(string: "Claude Code", attributes: [
            .font: Brand.serif(15, .semibold),
            .foregroundColor: Brand.ink,
            .kern: 0.2,
        ])
        title.draw(at: NSPoint(x: left + 24, y: y))

        guard let badge else { return }
        let text = NSAttributedString(string: badge.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: Brand.clay,
            .kern: 0.8,
        ])
        let size = text.size()
        let pill = NSRect(x: right - size.width - 14, y: y + 3,
                          width: size.width + 14, height: 16)
        Brand.clay.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        text.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 2))
    }

    private func draw(row: Row, left: CGFloat, right: CGFloat, y: CGFloat) {
        let percent = NSAttributedString(string: row.primary, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .bold),
            .foregroundColor: row.severity.textColor,
        ])
        let percentSize = percent.size()
        percent.draw(at: NSPoint(x: right - percentSize.width, y: y - 2))

        draw(row.name, font: .systemFont(ofSize: 12.5, weight: .medium), color: Brand.ink,
             at: NSPoint(x: left, y: y + 4))

        let track = NSRect(x: left, y: y + 26, width: right - left, height: 7)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5)
        Brand.track.setFill()
        trackPath.fill()

        if row.fraction > 0 {
            // Keep a visible sliver even at 1%, so "barely used" still reads as used.
            let filled = NSRect(x: track.minX, y: track.minY,
                                width: max(7, track.width * min(1, row.fraction)),
                                height: track.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: filled, xRadius: 3.5, yRadius: 3.5).addClip()
            let (start, end) = row.severity.gradient
            NSGradient(starting: start, ending: end)?.draw(in: filled, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }

        draw(row.secondary, font: .systemFont(ofSize: 10.5), color: Brand.inkSubtle,
             at: NSPoint(x: left, y: y + 37))
    }

    @discardableResult
    private func draw(_ string: String, font: NSFont, color: NSColor,
                      at point: NSPoint, width: CGFloat? = nil) -> NSSize {
        let text = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color,
        ])
        if let width {
            text.draw(with: NSRect(x: point.x, y: point.y, width: width, height: 40),
                      options: [.usesLineFragmentOrigin])
        } else {
            text.draw(at: point)
        }
        return text.size()
    }
}

/// A compact two-column row, used for the weekly breakdown submenu.
final class InfoRowView: NSView {
    private let title: String
    private let trailing: String
    private let secondary: Bool

    init(title: String, trailing: String, secondary: Bool = false, width: CGFloat = 230) {
        self.title = title
        self.trailing = trailing
        self.secondary = secondary
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: secondary ? 20 : 24))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let content = bounds.insetBy(dx: 16, dy: 0)
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: secondary ? 10.5 : 12),
            .foregroundColor: secondary ? Brand.inkSubtle : NSColor.labelColor,
        ]).draw(at: NSPoint(x: content.minX, y: secondary ? 3 : 4))

        let value = NSAttributedString(string: trailing, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: Brand.dynamic(light: NSColor(hex: 0xB05B38),
                                            dark: NSColor(hex: 0xE2957A)),
        ])
        value.draw(at: NSPoint(x: content.maxX - value.size().width, y: 3))
    }
}
