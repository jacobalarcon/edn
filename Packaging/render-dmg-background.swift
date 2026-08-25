#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-dmg-background.swift OUTPUT.png\n".utf8))
    exit(64)
}

let canvasSize = NSSize(width: 660, height: 400)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }

bitmap.size = canvasSize
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

NSColor(calibratedRed: 0.955, green: 0.950, blue: 0.930, alpha: 1).setFill()
NSRect(origin: .zero, size: canvasSize).fill()

let title = NSAttributedString(
    string: "Install EDN",
    attributes: [
        .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)
    ]
)
let titleSize = title.size()
title.draw(at: NSPoint(x: (canvasSize.width - titleSize.width) / 2, y: 337))

let instruction = NSAttributedString(
    string: "Drag EDN to Applications, then open it there.",
    attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1)
    ]
)
let instructionSize = instruction.size()
instruction.draw(at: NSPoint(x: (canvasSize.width - instructionSize.width) / 2, y: 309))

let arrowColor = NSColor(calibratedWhite: 0.31, alpha: 0.72)
arrowColor.setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 273, y: 180))
arrow.line(to: NSPoint(x: 380, y: 180))
arrow.move(to: NSPoint(x: 366, y: 192))
arrow.line(to: NSPoint(x: 380, y: 180))
arrow.line(to: NSPoint(x: 366, y: 168))
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
