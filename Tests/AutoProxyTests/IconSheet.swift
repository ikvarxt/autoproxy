import AppKit
import XCTest
@testable import AutoProxy

/// 图标改版时用来肉眼比对：把七个状态拼成一张放大图，浅色/深色菜单栏各一行。
/// 不设 ICON_SHEET_DIR 就直接跳过，平时不产生任何副作用。
///
///     ICON_SHEET_DIR=/tmp swift test --filter IconSheet
final class IconSheet: XCTestCase {
    func testDumpSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["ICON_SHEET_DIR"] else { return }

        let phone = Device(serial: "S", model: "SM_S9110", state: "device")
        let states: [CaptureState] = [
            .capturing(phone),
            .ready(phone, portListening: true),
            .ready(phone, portListening: false),
            .brokenLink(phone, reason: ""),
            .offlineStranded(model: "SM_S9110", port: 9000),
            .unauthorized(phone),
            .noDevice,
        ]

        let scale: CGFloat = 8
        let cell = NSSize(width: StatusIcon.size.width * scale, height: StatusIcon.size.height * scale)
        let pad: CGFloat = 12
        let sheet = NSImage(size: NSSize(
            width: (cell.width + pad) * CGFloat(states.count) + pad,
            height: (cell.height + pad) * 2 + pad
        ))

        sheet.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        for (row, background) in [NSColor.white, NSColor(white: 0.18, alpha: 1)].enumerated() {
            let y = pad + (cell.height + pad) * CGFloat(row)
            background.setFill()
            NSRect(x: 0, y: y - pad / 2, width: sheet.size.width, height: cell.height + pad).fill()
            for (column, state) in states.enumerated() {
                let image = StatusIcon.image(for: state.icon)
                let tinted = image.isTemplate ? tint(image, row == 0 ? .black : .white) : image
                tinted.draw(in: NSRect(x: pad + (cell.width + pad) * CGFloat(column), y: y,
                                       width: cell.width, height: cell.height))
            }
        }
        sheet.unlockFocus()

        let url = URL(fileURLWithPath: dir).appendingPathComponent("icons.png")
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private func tint(_ image: NSImage, _ color: NSColor) -> NSImage {
        let copy = NSImage(size: image.size)
        copy.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }
}
