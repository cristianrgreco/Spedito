#!/usr/bin/env swift

import AppKit
import Foundation

private let canvasWidth = 660
private let canvasHeight = 440
private let scaleFactors = [1, 2]

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(
    Data("Usage: generate_dmg_background.swift <output.tiff>\n".utf8)
  )
  exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let logicalSize = NSSize(width: canvasWidth, height: canvasHeight)

func color(_ red: Int, _ green: Int, _ blue: Int, alpha: CGFloat = 1) -> NSColor {
  NSColor(
    calibratedRed: CGFloat(red) / 255,
    green: CGFloat(green) / 255,
    blue: CGFloat(blue) / 255,
    alpha: alpha
  )
}

func drawCenteredText(
  _ text: String,
  in rect: NSRect,
  font: NSFont,
  foregroundColor: NSColor,
  tracking: CGFloat = 0
) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.alignment = .center
  text.draw(
    in: rect,
    withAttributes: [
      .font: font,
      .foregroundColor: foregroundColor,
      .paragraphStyle: paragraph,
      .kern: tracking,
    ]
  )
}

func drawBackground() {
  let bounds = NSRect(origin: .zero, size: logicalSize)
  color(243, 248, 251).setFill()
  bounds.fill()

  NSGradient(
    starting: color(247, 251, 253),
    ending: color(218, 241, 252)
  )?.draw(in: bounds, angle: -90)

  let upperGlow = NSBezierPath(ovalIn: NSRect(x: -95, y: 250, width: 410, height: 300))
  color(46, 149, 204, alpha: 0.09).setFill()
  upperGlow.fill()

  let lowerGlow = NSBezierPath(ovalIn: NSRect(x: 440, y: -120, width: 320, height: 280))
  color(116, 82, 200, alpha: 0.07).setFill()
  lowerGlow.fill()

  let innerPanel = NSBezierPath(
    roundedRect: NSRect(x: 22, y: 22, width: 616, height: 396),
    xRadius: 26,
    yRadius: 26
  )
  color(255, 255, 255, alpha: 0.52).setFill()
  innerPanel.fill()
  color(23, 101, 143, alpha: 0.12).setStroke()
  innerPanel.lineWidth = 1
  innerPanel.stroke()

  drawCenteredText(
    "Spedito",
    in: NSRect(x: 40, y: 358, width: 580, height: 40),
    font: .systemFont(ofSize: 29, weight: .bold),
    foregroundColor: color(23, 38, 48),
    tracking: -0.8
  )

  drawCenteredText(
    "Drag to Applications to install",
    in: NSRect(x: 40, y: 333, width: 580, height: 24),
    font: .systemFont(ofSize: 14, weight: .medium),
    foregroundColor: color(91, 106, 116)
  )

  let arrowBackground = NSBezierPath(
    roundedRect: NSRect(x: 270, y: 173, width: 120, height: 54),
    xRadius: 27,
    yRadius: 27
  )
  color(255, 255, 255, alpha: 0.78).setFill()
  arrowBackground.fill()
  color(46, 149, 204, alpha: 0.12).setStroke()
  arrowBackground.lineWidth = 1
  arrowBackground.stroke()

  let arrow = NSBezierPath()
  arrow.move(to: NSPoint(x: 289, y: 200))
  arrow.line(to: NSPoint(x: 366, y: 200))
  arrow.move(to: NSPoint(x: 353, y: 213))
  arrow.line(to: NSPoint(x: 367, y: 200))
  arrow.line(to: NSPoint(x: 353, y: 187))
  arrow.lineWidth = 4
  arrow.lineCapStyle = .round
  arrow.lineJoinStyle = .round
  color(46, 149, 204).setStroke()
  arrow.stroke()

  for (point, radius, opacity) in [
    (NSPoint(x: 74, y: 77), CGFloat(4), CGFloat(0.34)),
    (NSPoint(x: 92, y: 62), CGFloat(2.5), CGFloat(0.24)),
    (NSPoint(x: 579, y: 84), CGFloat(4), CGFloat(0.28)),
    (NSPoint(x: 596, y: 70), CGFloat(2.5), CGFloat(0.20)),
  ] {
    let dot = NSBezierPath(
      ovalIn: NSRect(
        x: point.x - radius,
        y: point.y - radius,
        width: radius * 2,
        height: radius * 2
      )
    )
    color(46, 149, 204, alpha: opacity).setFill()
    dot.fill()
  }

  drawCenteredText(
    "Local-first · Apple Silicon",
    in: NSRect(x: 40, y: 42, width: 580, height: 18),
    font: .systemFont(ofSize: 11, weight: .medium),
    foregroundColor: color(91, 106, 116, alpha: 0.82),
    tracking: 0.15
  )
}

let image = NSImage(size: logicalSize)
for scaleFactor in scaleFactors {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: canvasWidth * scaleFactor,
      pixelsHigh: canvasHeight * scaleFactor,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else {
    FileHandle.standardError.write(Data("Could not create the background canvas.\n".utf8))
    exit(70)
  }

  bitmap.size = logicalSize
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.cgContext.scaleBy(x: CGFloat(scaleFactor), y: CGFloat(scaleFactor))
  drawBackground()
  context.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()
  image.addRepresentation(bitmap)
}

guard
  let tiffData = image.tiffRepresentation(
    using: .lzw,
    factor: 1
  )
else {
  FileHandle.standardError.write(Data("Could not encode the background TIFF.\n".utf8))
  exit(70)
}

do {
  try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try tiffData.write(to: outputURL, options: .atomic)
} catch {
  FileHandle.standardError.write(Data("Could not write \(outputURL.path): \(error)\n".utf8))
  exit(74)
}
