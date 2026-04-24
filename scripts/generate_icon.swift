#!/usr/bin/env swift

import AppKit
import Foundation

let emoji = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "🐱"
let outputPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "AppIcon.icns"

let sizes: [(px: Int, name: String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("VitaPetIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func render(emoji: String, size: Int) -> Data? {
    let dim = CGFloat(size)
    let image = NSImage(size: NSSize(width: dim, height: dim), flipped: false) { rect in
        let bg = NSGradient(colors: [
            NSColor(calibratedRed: 1.00, green: 0.85, blue: 0.70, alpha: 1.0),
            NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.55, alpha: 1.0),
        ])
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: dim * 0.22,
                                yRadius: dim * 0.22)
        bg?.draw(in: path, angle: -90)

        let fontSize = dim * 0.72
        let font = NSFont(name: "Apple Color Emoji", size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let str = emoji as NSString
        let textSize = str.size(withAttributes: attrs)
        let origin = NSPoint(
            x: (dim - textSize.width) / 2,
            y: (dim - textSize.height) / 2 - dim * 0.02
        )
        str.draw(at: origin, withAttributes: attrs)
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
    guard let data = render(emoji: emoji, size: px) else {
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
