import AppKit

/// 把 IconStyle 画成菜单栏图标。
enum StatusIcon {
    static let size = NSSize(width: 18, height: 14)

    static func image(for style: IconStyle) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(style)
            return true
        }
        // 中性色交给系统着色：菜单栏的深浅跟随壁纸，写死颜色会在浅色壁纸上糊掉。
        // template 用 alpha 当蒙版，所以下面那个 0.35 的黑画出来就是 35% 的菜单栏前景色。
        image.isTemplate = style.tint == .neutral || style.tint == .dimmed
        return image
    }

    private static func draw(_ style: IconStyle) {
        color(for: style.tint).set()

        let stroke: CGFloat = 1.3
        let body = NSRect(x: 8.4, y: 0.7, width: 8.2, height: 12.6)
        let phone = NSBezierPath(roundedRect: body, xRadius: 2.2, yRadius: 2.2)
        phone.lineWidth = stroke

        if style.capturing {
            phone.fill()
        } else {
            if !style.devicePresent { phone.setLineDash([2.6, 2.0], count: 2, phase: 1.3) }
            phone.stroke()
        }

        guard style.cable != .absent else { return }
        let y = body.midY
        let cable = NSBezierPath()
        cable.lineWidth = stroke
        cable.lineCapStyle = .round
        switch style.cable {
        case .connected:
            cable.move(to: NSPoint(x: 1.2, y: y))
            cable.line(to: NSPoint(x: body.minX - 0.6, y: y))
        case .broken:
            cable.move(to: NSPoint(x: 1.2, y: y))
            cable.line(to: NSPoint(x: 3.6, y: y))
            cable.move(to: NSPoint(x: 6.2, y: y))
            cable.line(to: NSPoint(x: body.minX - 0.6, y: y))
        case .absent:
            break
        }
        cable.stroke()
    }

    private static func color(for tint: IconStyle.Tint) -> NSColor {
        switch tint {
        case .neutral: return NSColor.black.withAlphaComponent(0.9)
        case .dimmed: return NSColor.black.withAlphaComponent(0.45)
        case .active: return .systemGreen
        case .warning: return .systemOrange
        case .alert: return .systemRed
        }
    }
}
