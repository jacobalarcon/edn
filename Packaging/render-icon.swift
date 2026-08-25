#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift OUTPUT.png\n".utf8))
    exit(64)
}

let size = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }

bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

let tileRect = NSRect(x: 64, y: 64, width: 896, height: 896)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 205, yRadius: 205)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.105, green: 0.115, blue: 0.105, alpha: 1),
    ending: NSColor(calibratedRed: 0.035, green: 0.040, blue: 0.036, alpha: 1)
)!
gradient.draw(in: tile, angle: -90)

let labels = ["1", "2", "3"]
let activeIndex = 1
let pillSize = NSSize(width: 210, height: 236)
let gap: CGFloat = 32
let totalWidth = pillSize.width * 3 + gap * 2
let originX = (size.width - totalWidth) / 2
let originY = (size.height - pillSize.height) / 2

for index in labels.indices {
    let rect = NSRect(
        x: originX + CGFloat(index) * (pillSize.width + gap),
        y: originY,
        width: pillSize.width,
        height: pillSize.height
    )
    let path = NSBezierPath(roundedRect: rect, xRadius: 62, yRadius: 62)
    if index == activeIndex {
        NSColor(calibratedRed: 0.80, green: 0.90, blue: 0.76, alpha: 1).setFill()
        path.fill()
    } else {
        NSColor(calibratedWhite: 0.72, alpha: 0.52).setStroke()
        path.lineWidth = 12
        path.stroke()
    }

    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 92, weight: .semibold),
        .foregroundColor: index == activeIndex
            ? NSColor(calibratedWhite: 0.08, alpha: 1)
            : NSColor(calibratedWhite: 0.82, alpha: 1)
    ]
    let text = NSAttributedString(string: labels[index], attributes: attributes)
    let textSize = text.size()
    text.draw(at: NSPoint(
        x: rect.midX - textSize.width / 2,
        y: rect.midY - textSize.height / 2
    ))
}

NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
