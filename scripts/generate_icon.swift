#!/usr/bin/env swift

import AppKit
import Foundation

// Renders the macOS .icns from a custom VitaPet glyph so the dock icon and the
// menu bar mark share the same visual language.
//
// Usage: generate_icon.swift [emoji-ignored] [output.icns]
//   Run from the VitaPet repository root (as build_app.sh does).

let outputPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "AppIcon.icns"

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

func drawGlyph(in rect: NSRect, fillColor: NSColor, cutoutEyes: Bool) {
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        return
    }

    let gw = rect.width
    let gh = rect.height
    let gx = rect.minX
    let gy = rect.minY
    let bubbleRect = NSRect(
        x: gx + gw * 0.08,
        y: gy + gh * 0.10,
        width: gw * 0.8,
        height: gh * 0.62
    )

    fillColor.setFill()

    let leftEar = NSBezierPath()
    leftEar.move(to: NSPoint(x: gx + gw * 0.24, y: gy + gh * 0.66))
    leftEar.line(to: NSPoint(x: gx + gw * 0.36, y: gy + gh * 0.96))
    leftEar.line(to: NSPoint(x: gx + gw * 0.48, y: gy + gh * 0.66))
    leftEar.close()
    leftEar.fill()

    let rightEar = NSBezierPath()
    rightEar.move(to: NSPoint(x: gx + gw * 0.76, y: gy + gh * 0.66))
    rightEar.line(to: NSPoint(x: gx + gw * 0.64, y: gy + gh * 0.96))
    rightEar.line(to: NSPoint(x: gx + gw * 0.52, y: gy + gh * 0.66))
    rightEar.close()
    rightEar.fill()

    let bubble = NSBezierPath(
        roundedRect: bubbleRect,
        xRadius: bubbleRect.width * 0.26,
        yRadius: bubbleRect.height * 0.26
    )
    bubble.fill()

    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: bubbleRect.minX + bubbleRect.width * 0.2, y: bubbleRect.minY + bubbleRect.height * 0.08))
    tail.line(to: NSPoint(x: bubbleRect.minX + bubbleRect.width * 0.05, y: bubbleRect.minY - gh * 0.04))
    tail.line(to: NSPoint(x: bubbleRect.minX + bubbleRect.width * 0.3, y: bubbleRect.minY + bubbleRect.height * 0.02))
    tail.close()
    tail.fill()

    guard cutoutEyes else {
        return
    }

    ctx.saveGState()
    ctx.setBlendMode(.clear)

    let eyeWidth = gw * 0.09
    let eyeHeight = gh * 0.14
    let eyeY = gy + gh * 0.36
    let eyeOffset = gw * 0.15
    let leftEye = NSBezierPath(
        roundedRect: NSRect(
            x: gx + gw * 0.5 - eyeOffset - eyeWidth * 0.5,
            y: eyeY,
            width: eyeWidth,
            height: eyeHeight
        ),
        xRadius: eyeWidth * 0.5,
        yRadius: eyeHeight * 0.5
    )
    leftEye.fill()

    let rightEye = NSBezierPath(
        roundedRect: NSRect(
            x: gx + gw * 0.5 + eyeOffset - eyeWidth * 0.5,
            y: eyeY,
            width: eyeWidth,
            height: eyeHeight
        ),
        xRadius: eyeWidth * 0.5,
        yRadius: eyeHeight * 0.5
    )
    rightEye.fill()

    let nose = NSBezierPath()
    nose.move(to: NSPoint(x: gx + gw * 0.5, y: gy + gh * 0.25))
    nose.line(to: NSPoint(x: gx + gw * 0.448, y: gy + gh * 0.31))
    nose.line(to: NSPoint(x: gx + gw * 0.552, y: gy + gh * 0.31))
    nose.close()
    nose.fill()

    ctx.restoreGState()
}

func render(size: Int) -> Data? {
    let dim = CGFloat(size)
    let image = NSImage(size: NSSize(width: dim, height: dim), flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

        let cornerRadius = dim * 0.224
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

        ctx.saveGState()
        bgPath.addClip()

        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0),
            NSColor(calibratedRed: 0.21, green: 0.24, blue: 0.30, alpha: 1.0),
        ])
        gradient?.draw(in: bgPath, angle: -72)

        if let topGlow = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.2),
            NSColor.white.withAlphaComponent(0.0),
        ]) {
            let center = NSPoint(x: dim * 0.32, y: dim * 0.8)
            topGlow.draw(fromCenter: center, radius: 0, toCenter: center, radius: dim * 0.58, options: [])
        }

        let innerPanel = NSBezierPath(
            roundedRect: rect.insetBy(dx: dim * 0.11, dy: dim * 0.11),
            xRadius: dim * 0.15,
            yRadius: dim * 0.15
        )
        NSColor.white.withAlphaComponent(0.04).setFill()
        innerPanel.fill()

        let glyphRect = NSRect(
            x: dim * 0.19,
            y: dim * 0.16,
            width: dim * 0.62,
            height: dim * 0.68
        )

        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -dim * 0.018),
            blur: dim * 0.05,
            color: NSColor.black.withAlphaComponent(0.34).cgColor
        )
        drawGlyph(
            in: glyphRect,
            fillColor: NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.91, alpha: 1.0),
            cutoutEyes: dim >= 64
        )
        ctx.restoreGState()

        if let accent = NSGradient(colors: [
            NSColor(calibratedRed: 0.94, green: 0.62, blue: 0.31, alpha: 0.22),
            NSColor(calibratedRed: 0.94, green: 0.62, blue: 0.31, alpha: 0.0),
        ]) {
            let center = NSPoint(x: dim * 0.74, y: dim * 0.32)
            accent.draw(fromCenter: center, radius: 0, toCenter: center, radius: dim * 0.34, options: [])
        }

        ctx.restoreGState()

        let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: cornerRadius - 0.5,
                                  yRadius: cornerRadius - 0.5)
        NSColor.black.withAlphaComponent(0.08).setStroke()
        stroke.lineWidth = 1.0
        stroke.stroke()

        return true
    }

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        return nil
    }
    return png
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
