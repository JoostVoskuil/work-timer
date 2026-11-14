import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/WorkTimer.iconset")
let output = root.appendingPathComponent("Sources/WorkTimerApp/Resources/WorkTimer.icns")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

func render(size: Int, filename: String) throws {
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 225, yRadius: 225)
    NSGradient(starting: NSColor(calibratedRed: 0.06, green: 0.36, blue: 0.36, alpha: 1),
               ending: NSColor(calibratedRed: 0.05, green: 0.60, blue: 0.50, alpha: 1))!.draw(in: background, angle: -55)

    let dial = NSBezierPath(ovalIn: NSRect(x: 210, y: 210, width: 604, height: 604))
    NSColor.white.withAlphaComponent(0.13).setStroke()
    dial.lineWidth = 28
    dial.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 302, startAngle: 90, endAngle: -110, clockwise: true)
    arc.lineWidth = 28
    arc.lineCapStyle = .round
    NSColor(calibratedRed: 0.73, green: 0.95, blue: 0.81, alpha: 1).setStroke()
    arc.stroke()

    let hands = NSBezierPath()
    hands.move(to: NSPoint(x: 512, y: 690))
    hands.line(to: NSPoint(x: 512, y: 512))
    hands.line(to: NSPoint(x: 642, y: 430))
    hands.lineWidth = 45
    hands.lineCapStyle = .round
    hands.lineJoinStyle = .round
    NSColor.white.setStroke()
    hands.stroke()
    image.unlockFocus()

    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: NSRect(x: 0, y: 0, width: 1024, height: 1024), operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon PNG")
    }
    try png.write(to: iconset.appendingPathComponent(filename))
}

for size in [16, 32, 128, 256, 512] {
    try render(size: size, filename: "icon_\(size)x\(size).png")
    try render(size: size * 2, filename: "icon_\(size)x\(size)@2x.png")
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Created \(output.path)")
