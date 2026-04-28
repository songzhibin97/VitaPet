#!/usr/bin/env swift

import AppKit
import Foundation

// Renders the macOS .icns from a custom VitaPet glyph so the dock icon and the
// menu bar mark share the same visual language.
//
// Usage: generate_icon.swift [emoji-ignored] [output.icns]
//   Run from the VitaPet repository root (as build_app.sh does).

let outputPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "App/Resources/AppIcon.icns"

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("VitaPetIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func drawGlyph(in rect: NSRect, strokeColor: NSColor, strokeWidth: CGFloat) {
    guard NSGraphicsContext.current?.cgContext != nil else {
        return
    }

    let gw = rect.width
    let gh = rect.height
    let gx = rect.minX
    let gy = rect.minY

    // ── Cat face: line-art stroke style ──────────────────────────────────
    let cx  = gx + gw * 0.50
    let fr  = gw * 0.40        // face radius
    let fcy = gy + gh * 0.40   // face centre Y

    let head = NSBezierPath()
    head.lineJoinStyle = .miter
    head.lineCapStyle  = .round
    head.lineWidth     = strokeWidth

    // bottom → right quarter-circle
    head.move(to: NSPoint(x: cx,       y: fcy - fr))
    head.curve(to: NSPoint(x: cx + fr, y: fcy),
               controlPoint1: NSPoint(x: cx + fr * 0.552, y: fcy - fr),
               controlPoint2: NSPoint(x: cx + fr,         y: fcy - fr * 0.552))
    // right side → right-ear outer-base
    head.curve(to: NSPoint(x: cx + fr * 0.70, y: fcy + fr * 0.70),
               controlPoint1: NSPoint(x: cx + fr,          y: fcy + fr * 0.35),
               controlPoint2: NSPoint(x: cx + fr * 0.88,   y: fcy + fr * 0.58))
    // right ear: outer-base → soft rounded arch → inner-base
    head.curve(to: NSPoint(x: cx + fr * 0.22, y: fcy + fr * 0.88),
               controlPoint1: NSPoint(x: cx + fr * 0.72, y: fcy + fr * 1.22),
               controlPoint2: NSPoint(x: cx + fr * 0.20, y: fcy + fr * 1.22))
    // forehead dip
    head.curve(to: NSPoint(x: cx - fr * 0.22, y: fcy + fr * 0.88),
               controlPoint1: NSPoint(x: cx + fr * 0.10, y: fcy + fr * 0.72),
               controlPoint2: NSPoint(x: cx - fr * 0.10, y: fcy + fr * 0.72))
    // left ear: inner-base → soft rounded arch → outer-base
    head.curve(to: NSPoint(x: cx - fr * 0.70, y: fcy + fr * 0.70),
               controlPoint1: NSPoint(x: cx - fr * 0.20, y: fcy + fr * 1.22),
               controlPoint2: NSPoint(x: cx - fr * 0.72, y: fcy + fr * 1.22))
    // left side → bottom
    head.curve(to: NSPoint(x: cx - fr, y: fcy),
               controlPoint1: NSPoint(x: cx - fr * 0.88,   y: fcy + fr * 0.58),
               controlPoint2: NSPoint(x: cx - fr,           y: fcy + fr * 0.35))
    head.curve(to: NSPoint(x: cx,      y: fcy - fr),
               controlPoint1: NSPoint(x: cx - fr,           y: fcy - fr * 0.552),
               controlPoint2: NSPoint(x: cx - fr * 0.552,   y: fcy - fr))
    head.close()
    strokeColor.setStroke()
    head.stroke()

    // Eyes: filled circles
    let eyeR  = fr * 0.13
    let eyeY  = fcy + fr * 0.12
    let eyeOX = fr * 0.38
    strokeColor.setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - eyeOX - eyeR, y: eyeY - eyeR,
                                width: eyeR * 2, height: eyeR * 2)).fill()
    NSBezierPath(ovalIn: NSRect(x: cx + eyeOX - eyeR, y: eyeY - eyeR,
                                width: eyeR * 2, height: eyeR * 2)).fill()

    // Nose: small filled inverted triangle
    let noseY = fcy - fr * 0.10
    let ns    = fr * 0.10
    let nose  = NSBezierPath()
    nose.move(to: NSPoint(x: cx - ns, y: noseY + ns * 0.65))
    nose.line(to: NSPoint(x: cx + ns, y: noseY + ns * 0.65))
    nose.line(to: NSPoint(x: cx,      y: noseY - ns * 0.65))
    nose.close()
    nose.fill()
}

func drawBadge(in rect: NSRect) {
    guard let cgContext = NSGraphicsContext.current?.cgContext else {
        return
    }

    let radius = rect.width * 0.225
    let badgePath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    cgContext.saveGState()
    cgContext.setShadow(
        offset: CGSize(width: 0, height: -rect.height * 0.016),
        blur: rect.width * 0.028,
        color: NSColor.black.withAlphaComponent(0.18).cgColor
    )
    NSColor(calibratedWhite: 0.98, alpha: 1.0).setFill()
    badgePath.fill()
    cgContext.restoreGState()

    NSColor.black.withAlphaComponent(0.08).setStroke()
    badgePath.lineWidth = max(1.0, rect.width * 0.006)
    badgePath.stroke()
}

func makeBitmapRep(size: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
}

func render(size: Int) -> Data? {
    let supersample = size <= 64 ? 8 : 4
    let workingSize = size * supersample

    guard let workingRep = makeBitmapRep(size: workingSize),
          let workingContext = NSGraphicsContext(bitmapImageRep: workingRep) else {
        return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = workingContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    let workingCG = workingContext.cgContext

    let workingDim = CGFloat(workingSize)
    workingCG.setShouldAntialias(true)
    workingCG.setAllowsAntialiasing(true)
    workingCG.interpolationQuality = .high
    workingCG.clear(CGRect(x: 0, y: 0, width: workingDim, height: workingDim))

    let badgeInset = workingDim * 0.05
    let badgeRect = NSRect(
        x: badgeInset,
        y: badgeInset,
        width: workingDim - badgeInset * 2,
        height: workingDim - badgeInset * 2
    )
    drawBadge(in: badgeRect)

    let glyphRect = badgeRect.insetBy(dx: badgeRect.width * 0.16, dy: badgeRect.height * 0.06)

    drawGlyph(
        in: glyphRect,
        strokeColor: NSColor.black,
        strokeWidth: glyphRect.width * 0.105
    )

    guard let outputRep = makeBitmapRep(size: size),
          let outputContext = NSGraphicsContext(bitmapImageRep: outputRep),
          let workingImage = workingRep.cgImage else {
        return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = outputContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    let outputCG = outputContext.cgContext

    let outputDim = CGFloat(size)
    outputCG.setShouldAntialias(true)
    outputCG.setAllowsAntialiasing(true)
    outputCG.interpolationQuality = .high
    outputCG.clear(CGRect(x: 0, y: 0, width: outputDim, height: outputDim))
    outputCG.draw(workingImage, in: CGRect(x: 0, y: 0, width: outputDim, height: outputDim))

    return outputRep.representation(using: .png, properties: [:])
}

for (px, name) in sizes {
    guard let data = render(size: px) else {
        FileHandle.standardError.write(Data("failed to render \(px)\n".utf8))
        exit(1)
    }
    try data.write(to: tmp.appendingPathComponent(name))
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", tmp.path, "-o", outputPath]
try task.run()
task.waitUntilExit()
if task.terminationStatus != 0 {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(Int32(task.terminationStatus))
}
print("Wrote \(outputPath)")
