import AppKit

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum Palette {
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    static let warning = dynamic(light: 0xB4540A, dark: 0xF2A33A)
    static let critical = dynamic(light: 0x9F1D1D, dark: 0xFF6B6B)
    static let warningText = dynamic(light: 0x8A3F06, dark: 0xF2A33A)

    /// Bars use the service color until a limit is close.
    static func fill(_ service: ServiceID, _ level: UsageLevel) -> NSColor {
        switch level {
        case .normal: return service.color
        case .warning: return warning
        case .critical: return critical
        }
    }

    static func text(for level: UsageLevel) -> NSColor {
        switch level {
        case .normal: return .labelColor
        case .warning: return warningText
        case .critical: return critical
        }
    }
}

enum Icons {
    /// Nested rings, one per service, outermost first. Up to three.
    static func rings(_ items: [(percent: Double, color: NSColor)], size: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let count = max(1, min(items.count, 3))
            let line: CGFloat = count == 1 ? 2.5 : (count == 2 ? 1.6 : 1.3)
            let gap: CGFloat = count == 3 ? 1.1 : 1.6
            let center = NSPoint(x: size / 2, y: size / 2)
            var radius = size / 2 - line / 2 - 0.5
            for item in items.prefix(3) {
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = line
                NSColor.tertiaryLabelColor.setStroke()
                track.stroke()
                if item.percent > 0 {
                    let arc = NSBezierPath()
                    let end = 90 - 360 * CGFloat(min(item.percent, 100)) / 100
                    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: end, clockwise: true)
                    arc.lineWidth = line
                    arc.lineCapStyle = .round
                    item.color.setStroke()
                    arc.stroke()
                }
                radius -= line + gap
            }
            return true
        }
        image.cacheMode = .never
        return image
    }

    static func dashedRing(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: NSRect(x: 2.25, y: 2.25, width: 11.5, height: 11.5))
            circle.lineWidth = 2.5
            let pattern: [CGFloat] = [2.5, 2.5]
            circle.setLineDash(pattern, count: 2, phase: 0)
            color.setStroke()
            circle.stroke()
            return true
        }
        image.cacheMode = .never
        return image
    }

    static func clock(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: NSRect(x: 2.25, y: 2.25, width: 11.5, height: 11.5))
            circle.lineWidth = 2.5
            color.setStroke()
            circle.stroke()
            let hands = NSBezierPath()
            hands.move(to: NSPoint(x: 8, y: 11))
            hands.line(to: NSPoint(x: 8, y: 8))
            hands.line(to: NSPoint(x: 10, y: 6.8))
            hands.lineWidth = 1.6
            hands.lineCapStyle = .round
            hands.lineJoinStyle = .round
            hands.stroke()
            return true
        }
        image.cacheMode = .never
        return image
    }

    static func dot(_ color: NSColor, filled: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: 7, height: 7), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: filled ? 0 : 0.75, dy: filled ? 0 : 0.75))
            if filled {
                color.setFill()
                path.fill()
            } else {
                path.lineWidth = 1.5
                color.setStroke()
                path.stroke()
            }
            return true
        }
        image.cacheMode = .never
        return image
    }

    /// Rounded-corner mask for the dropdown's blurred background.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
