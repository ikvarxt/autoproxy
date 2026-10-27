#!/usr/bin/env swift
import AppKit

// 应用图标：一部手机，一根线从左边插进去。跟菜单栏图标同一套语言 ——
// 那边是 18pt 的单色线稿，这边是 1024 的实心版本，看的是同一件事。
//
// 各尺寸都矢量重画而不是缩放大图：16pt 上一条 2px 的线缩出来会糊成灰带。

/// Big Sur 规范：1024 画布里图形只占居中的 824，四周留白是系统排版的一部分。
/// 圆角占底板宽的 22.5%。
let plateRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat = 185.4 / 824.0

func draw(side: CGFloat) {
    // 16/32 上一条 0.5px 的描边会直接糊没，只剩一团灰。那两档换一套画法：
    // 实心机身、更粗的线、更满的构图 —— 糊掉的精致不如看得清的笨。
    let tiny = side <= 32
    let plate = tiny ? 0.92 : plateRatio
    let inset = side * (1 - plate) / 2
    let board = NSRect(x: inset, y: inset, width: side * plate, height: side * plate)

    NSBezierPath(roundedRect: board,
                 xRadius: board.width * cornerRatio,
                 yRadius: board.width * cornerRatio).addClip()
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.24, blue: 0.30, alpha: 1),
               ending: NSColor(srgbRed: 0.09, green: 0.11, blue: 0.15, alpha: 1))?
        .draw(in: board, angle: -90)

    let u = side / 1024  // 下面的数都按 1024 画布量，乘它换算到当前尺寸
    let flow = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)

    let phone = tiny ? NSRect(x: 556 * u, y: 196 * u, width: 384 * u, height: 632 * u)
                     : NSRect(x: 500 * u, y: 250 * u, width: 348 * u, height: 524 * u)
    let shell = NSBezierPath(roundedRect: phone,
                             xRadius: (tiny ? 70 : 60) * u,
                             yRadius: (tiny ? 70 : 60) * u)
    NSColor.white.set()
    if tiny {
        shell.fill()
    } else {
        shell.lineWidth = 34 * u
        shell.stroke()
    }

    // 屏幕染成线的那个绿：流量正穿过它，这是这个工具唯一在做的事
    let screen = tiny ? phone.insetBy(dx: 76 * u, dy: 104 * u)
                      : phone.insetBy(dx: 82 * u, dy: 96 * u)
    flow.withAlphaComponent(0.9).setFill()
    NSBezierPath(roundedRect: screen, xRadius: (tiny ? 26 : 22) * u, yRadius: (tiny ? 26 : 22) * u).fill()

    // 线。绿色 = 通着，跟菜单栏 active 态同一个意思
    let y = phone.midY
    let cable = NSBezierPath()
    cable.lineWidth = (tiny ? 96 : 34) * u
    cable.lineCapStyle = .round
    cable.move(to: NSPoint(x: (tiny ? 196 : 212) * u, y: y))
    cable.line(to: NSPoint(x: phone.minX - (tiny ? 4 : 12) * u, y: y))
    flow.setStroke()
    cable.stroke()

    // 线头那个点。没有它，线像是从画布外面被裁断的
    let plugSize: CGFloat = tiny ? 196 : 108
    let plug = NSRect(x: (tiny ? 98 : 136) * u, y: y - plugSize / 2 * u,
                      width: plugSize * u, height: plugSize * u)
    flow.setFill()
    NSBezierPath(ovalIn: plug).fill()
}

func png(side: Int) -> Data {
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
        draw(side: CGFloat(side))
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AutoProxy.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (point, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                       (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(point)x\(point).png" : "icon_\(point)x\(point)@2x.png"
    try png(side: point * scale).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
print(out)
